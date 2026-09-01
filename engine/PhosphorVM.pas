{******************************************************************************
  Phosphor BASIC -- the stack VM

  MIT License. Copyright (c) 2026 Andre Murta.

  Executes a TProgram over a stack of TValue. Calls are resolved from the actual
  runtime kinds of their arguments through the registry (int% widens to an 'n'
  slot, an exact '%' slot is preferred). Arithmetic and call errors are RETURNED
  as engine error state, never raised. All output leaves through OnOutput.
******************************************************************************}
unit PhosphorVM;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, PhosphorValue, PhosphorErrors, PhosphorOpcodes, PhosphorRegistry;

type
  { One activation of a user function: its local frame (parameters first, then
    declared locals), the function it belongs to, and where to resume. }
  TCallFrame = record
    Locals: array of TValue;
    FuncIndex: Integer;
    ReturnAddr: Integer;
  end;

  TPhosphorVM = class
  private
    FStack: array of TValue;
    FSP: Integer;    // points one past the top
    FVars: array of TValue;
    FCallStack: array of Integer;   // GOSUB return addresses
    FCSP: Integer;
    FFrames: array of TCallFrame;   // user-function activation frames
    FFrameSP: Integer;
    FDataPtr: Integer;              // READ position in the DATA pool
    FProg: TProgram;                // the running program (reachable during a call)
    // ON ERROR state. FErrHandler is the handler pc, or -1 when none is installed.
    // opStmt keeps FStmt* pointing at the current clean statement boundary; on a
    // caught error those are copied to FErrStmt* (the resume point) before the
    // handler runs and moves FStmt* on. FInHandler blocks re-entry until a resume.
    FErrHandler: Integer;
    FErrHandlerSP, FErrHandlerFrameSP: Integer;
    FErrHandlerMode: Integer;    // 0 = goto a label, 1 = call a function
    FErrHandlerFuncIdx: Integer; // const-pool index of the function name (call mode)
    FInHandler: Boolean;
    FErrCode: Integer;              // last caught error: code / message / line
    FErrMsg: String;
    FErrLine: Integer;
    FStmtPC, FStmtSP, FStmtFrameSP: Integer;          // current statement boundary
    FErrStmtPC, FErrStmtSP, FErrStmtFrameSP: Integer; // the failing statement, for resume
    // Execution limits (set from the engine before Run; 0 = unlimited). Counters
    // are reset per Run. A limit is FATAL -- it aborts with peLimit and cannot be
    // caught by ON ERROR, so a script cannot escape its own ceiling.
    FSteps: Int64;
    FOutputBytes: Int64;
    FStartTick: QWord;
    procedure Push(const V: TValue);
    function Pop: TValue;
    { The fetch-decode-execute loop. Runs from AStartPC until the program halts
      (or its instructions run out) OR a user-function return brings the frame
      stack back down to AStopFrameSP -- the bound that lets CallUserFunc invoke
      one BASIC routine re-entrantly and hand control back. The top-level Run uses
      AStopFrameSP = -1, a level the frame stack never reaches, so it runs to end. }
    function ExecFrom(AStartPC, AStopFrameSP: Integer): Boolean;
  public
    OnOutput: TPhosphorOutputProc;
    Registry: TPhosphorRegistry;
    LastError: TPhosphorError;
    ErrorLine: Integer;
    // Host-set execution ceilings; 0 = unlimited (the default, zero cost).
    MaxSteps: Int64;        // instruction budget (the answer to an infinite loop)
    MaxOutputBytes: Int64;  // total bytes emitted through OnOutput
    TimeoutMs: Int64;       // wall-clock ceiling in milliseconds
    constructor Create;
    function Run(AProg: TProgram): Boolean;  // False on error (LastError/ErrorLine set)
    { Call a BASIC user function by name, re-entrantly, over the SAME globals and
      handles as the running program. This is the host callback seam: an event
      dispatcher (or the callfunc primitive) runs a BASIC routine and gets its
      return value back. Err is set (and the result is a default value) if the
      function is unknown or the routine fails. }
    function CallUserFunc(const AName: String; const Args: array of TValue;
                          out Err: TPhosphorError): TValue;
    { The last error caught by an ON ERROR handler -- what err()/errmsg$()/erl()
      read. Set on each fault; persists until the next fault. }
    property ErrCode: Integer read FErrCode;
    property ErrMessage: String read FErrMsg;
    property ErrLine: Integer read FErrLine;
    procedure ClearError;   // reset err()/errmsg$()/erl() to "no error"
  end;

implementation

constructor TPhosphorVM.Create;
begin
  inherited Create;
  SetLength(FStack, 64);
  FSP := 0;
  LastError := NoError;
  ErrorLine := 0;
end;

procedure TPhosphorVM.Push(const V: TValue);
begin
  if FSP = Length(FStack) then
    SetLength(FStack, Length(FStack) * 2);
  FStack[FSP] := V;
  Inc(FSP);
end;

function TPhosphorVM.Pop: TValue;
begin
  if FSP = 0 then
  begin
    Result := Default(TValue);
    Exit;
  end;
  Dec(FSP);
  Result := FStack[FSP];
end;

function SignatureOf(const AName: String; const AArgs: array of TValue): String;
var
  i: Integer;
begin
  Result := AName + ':';
  for i := 0 to High(AArgs) do
    Result := Result + TPhosphorRegistry.CodeOf(AArgs[i].Kind);
end;

function TPhosphorVM.Run(AProg: TProgram): Boolean;
var
  i: Integer;
begin
  FProg := AProg;
  FSP := 0;
  FCSP := 0;
  FFrameSP := 0;
  FDataPtr := 0;
  LastError := NoError;
  ErrorLine := 0;
  FErrHandler := -1;
  FErrHandlerMode := 0;
  FErrHandlerFuncIdx := 0;
  FInHandler := False;
  FErrCode := 0; FErrMsg := ''; FErrLine := 0;
  FStmtPC := 0; FStmtSP := 0; FStmtFrameSP := 0;
  FErrStmtPC := 0; FErrStmtSP := 0; FErrStmtFrameSP := 0;
  FSteps := 0;
  FOutputBytes := 0;
  FStartTick := GetTickCount64;
  SetLength(FVars, AProg.VarCount);
  for i := 0 to AProg.VarCount - 1 do
    FVars[i] := DefaultValue(AProg.VarTypes[i]);
  Result := ExecFrom(0, -1);
end;

function TPhosphorVM.ExecFrom(AStartPC, AStopFrameSP: Integer): Boolean;
var
  pc, i, argc, ufi, savedRet: Integer;
  ins: TInstr;
  a, b, r, v: TValue;
  e: TPhosphorError;
  args: array of TValue;
  kinds: array of TValueKind;
  res: TResolvedFunc;
  lt: TVarType;

  { A runtime error. Returns True if an ON ERROR handler took it (pc now points at
    the handler; the caller should Continue), False to abort (LastError set; the
    caller should Exit(False)). The handler runs at the stack/frame level it was
    installed at; the failing statement is remembered for resume. }
  function Fault(const AErr: TPhosphorError): Boolean;
  var
    callErr: TPhosphorError;
    callRet: TValue;
  begin
    FErrCode := Ord(AErr.Code);
    FErrMsg := AErr.Message;
    FErrLine := ins.Line;
    if (FErrHandler >= 0) and (not FInHandler) then
    begin
      FErrStmtPC := FStmtPC; FErrStmtSP := FStmtSP; FErrStmtFrameSP := FStmtFrameSP;
      FSP := FErrHandlerSP; FFrameSP := FErrHandlerFrameSP;
      if FErrHandlerMode = 1 then
      begin
        // `on error call func`: run func(code%, msg$), then continue by its result
        // (return 0 = resume next; return non-zero = abort, re-raising the error).
        FInHandler := True;
        callRet := CallUserFunc(FProg.Consts.Get(FErrHandlerFuncIdx).Str,
                                [ValInt(FErrCode), ValStr(FErrMsg)], callErr);
        FInHandler := False;
        if IsError(callErr) then
        begin
          LastError := callErr; ErrorLine := FErrLine; Exit(False);
        end;
        if (callRet.Kind in [vkInt, vkDouble]) and (AsDouble(callRet) <> 0) then
        begin
          LastError := AErr; ErrorLine := FErrLine; Exit(False);   // handler said: abort
        end;
        FSP := FErrStmtSP; FFrameSP := FErrStmtFrameSP;             // resume next
        pc := FErrStmtPC + 1;
        while (pc < FProg.Count) and (FProg.Instr(pc).Op <> opStmt) do Inc(pc);
        Result := True;
      end
      else
      begin
        // `on error goto label`: jump to the handler
        FInHandler := True;
        pc := FErrHandler;
        Result := True;
      end;
    end
    else
    begin
      LastError := AErr;
      ErrorLine := ins.Line;
      Result := False;
    end;
  end;

  { For arithmetic/comparison ops. 0 = ok (result pushed, fall through to Inc pc),
    1 = a handler took the fault (Continue), 2 = abort (Exit False). }
  function Bin(AErr: TPhosphorError; const AResult: TValue): Integer;
  begin
    if IsError(AErr) then
    begin
      if Fault(AErr) then Result := 1 else Result := 2;
    end
    else
    begin
      Push(AResult);
      Result := 0;
    end;
  end;

  { Emit output, enforcing the output-byte ceiling. False = the ceiling was hit
    (a fatal peLimit is set; the caller must Exit(False)). }
  function EmitOutput(const S: String): Boolean;
  begin
    if (MaxOutputBytes > 0) and (FOutputBytes + Length(S) > MaxOutputBytes) then
    begin
      LastError := MakeError(peLimit, 'output limit exceeded (' + IntToStr(MaxOutputBytes) + ' bytes)');
      ErrorLine := ins.Line;
      Exit(False);
    end;
    Inc(FOutputBytes, Length(S));
    if Assigned(OnOutput) then OnOutput(S);
    Result := True;
  end;

begin
  args := nil;
  kinds := nil;
  pc := AStartPC;
  while pc < FProg.Count do
  begin
    ins := FProg.Instr(pc);
    Inc(FSteps);
    if (MaxSteps > 0) and (FSteps > MaxSteps) then
    begin
      LastError := MakeError(peLimit, 'step budget exceeded (' + IntToStr(MaxSteps) + ' instructions)');
      ErrorLine := ins.Line;
      Exit(False);
    end;
    if (TimeoutMs > 0) and ((FSteps and $FFF) = 0) and
       (GetTickCount64 - FStartTick > QWord(TimeoutMs)) then
    begin
      LastError := MakeError(peLimit, 'time limit exceeded (' + IntToStr(TimeoutMs) + ' ms)');
      ErrorLine := ins.Line;
      Exit(False);
    end;
    case ins.Op of
      opNop: ;
      opPushConst: Push(FProg.Consts.Get(ins.A));
      opPop: Pop;
      opPrint:
        begin
          v := Pop;
          if not EmitOutput(ValToStr(v)) then Exit(False);
        end;
      opPrintLn:
        begin
          v := Pop;
          if not EmitOutput(ValToStr(v) + #10) then Exit(False);
        end;
      opNeg:     begin a := Pop; case Bin(Negate(a, r), r) of 1: Continue; 2: Exit(False); end; end;
      opAdd:     begin b := Pop; a := Pop; case Bin(ValAdd(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opSub:     begin b := Pop; a := Pop; case Bin(ValSub(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opMul:     begin b := Pop; a := Pop; case Bin(ValMul(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opDivReal: begin b := Pop; a := Pop; case Bin(ValDivReal(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opDivInt:  begin b := Pop; a := Pop; case Bin(ValDivInt(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opPow:     begin b := Pop; a := Pop; case Bin(ValPow(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opMod:     begin b := Pop; a := Pop; case Bin(ValMod(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opEQ:      begin b := Pop; a := Pop; case Bin(ValCompare(coEQ, a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opNE:      begin b := Pop; a := Pop; case Bin(ValCompare(coNE, a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opLT:      begin b := Pop; a := Pop; case Bin(ValCompare(coLT, a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opLE:      begin b := Pop; a := Pop; case Bin(ValCompare(coLE, a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opGT:      begin b := Pop; a := Pop; case Bin(ValCompare(coGT, a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opGE:      begin b := Pop; a := Pop; case Bin(ValCompare(coGE, a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opAnd:     begin b := Pop; a := Pop; case Bin(ValAnd(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opOr:      begin b := Pop; a := Pop; case Bin(ValOr(a, b, r), r) of 1: Continue; 2: Exit(False); end; end;
      opNot:     begin a := Pop; case Bin(ValNot(a, r), r) of 1: Continue; 2: Exit(False); end; end;
      opLoadVar: Push(FVars[ins.A]);
      opStoreVar:
        begin
          v := Pop;
          if CanStore(FProg.VarTypes[ins.A], v, r) then
            FVars[ins.A] := r
          else
            if Fault(MakeError(peTypeMismatch, 'cannot store ' + KindName(v.Kind) +
              ' into ' + VarTypeName(FProg.VarTypes[ins.A]) + ' variable')) then Continue else Exit(False);
        end;
      opJumpIfFalse:
        begin
          v := Pop;
          if v.Kind <> vkBool then
            if Fault(MakeError(peTypeMismatch, 'condition is not a boolean')) then Continue else Exit(False);
          if not v.Bl then
          begin
            pc := ins.A;
            Continue;
          end;
        end;
      opJump:
        begin
          pc := ins.A;
          Continue;
        end;
      opReadData:
        begin
          if FDataPtr >= FProg.DataCount then
          begin
            if Fault(MakeError(peRuntime, 'out of DATA')) then Continue else Exit(False);
          end;
          Push(FProg.DataPool[FDataPtr]);
          Inc(FDataPtr);
        end;
      opRestore: FDataPtr := 0;
      opDup2:
        begin
          a := FStack[FSP - 2];
          b := FStack[FSP - 1];
          Push(a);
          Push(b);
        end;
      opStmt:
        begin
          // Mark this clean statement boundary; a fault resumes from here.
          FStmtPC := pc; FStmtSP := FSP; FStmtFrameSP := FFrameSP;
        end;
      opSetErrHandler:
        begin
          FErrHandlerMode := ins.B;   // 0 = goto a label (A = pc), 1 = call a func (A = name idx)
          if (ins.B = 0) and (ins.A < 0) then
            FErrHandler := -1         // on error goto 0 -- disable
          else
          begin
            FErrHandler := ins.A;     // installed (a pc for goto, a name index for call)
            if ins.B = 1 then FErrHandlerFuncIdx := ins.A;
            FErrHandlerSP := FSP; FErrHandlerFrameSP := FFrameSP;
          end;
          FInHandler := False;        // (re-)installing re-arms the handler
        end;
      opResume:
        begin
          if not FInHandler then
          begin
            LastError := MakeError(peRuntime, 'resume without an active error handler');
            ErrorLine := ins.Line;
            Exit(False);
          end;
          FInHandler := False;
          FSP := FErrStmtSP; FFrameSP := FErrStmtFrameSP;
          if ins.A = 1 then
          begin
            // resume next: continue at the statement after the one that failed
            pc := FErrStmtPC + 1;
            while (pc < FProg.Count) and (FProg.Instr(pc).Op <> opStmt) do Inc(pc);
          end
          else
            pc := FErrStmtPC;   // resume: retry the failing statement
          Continue;
        end;
      opHalt: Exit(True);
      opGosub:
        begin
          if FCSP = Length(FCallStack) then
            SetLength(FCallStack, (FCSP + 1) * 2);
          FCallStack[FCSP] := pc + 1;   // resume after the GOSUB
          Inc(FCSP);
          pc := ins.A;
          Continue;
        end;
      opReturn:
        begin
          if FCSP = 0 then
            if Fault(MakeError(peRuntime, 'RETURN without GOSUB')) then Continue else Exit(False);
          Dec(FCSP);
          pc := FCallStack[FCSP];
          Continue;
        end;
      opLoadLocal: Push(FFrames[FFrameSP - 1].Locals[ins.A]);
      opStoreLocal:
        begin
          v := Pop;
          lt := FProg.UserFuncs[FFrames[FFrameSP - 1].FuncIndex].LocalTypes[ins.A];
          if CanStore(lt, v, r) then
            FFrames[FFrameSP - 1].Locals[ins.A] := r
          else
            if Fault(MakeError(peTypeMismatch, 'cannot store ' + KindName(v.Kind) +
              ' into ' + VarTypeName(lt) + ' local')) then Continue else Exit(False);
        end;
      opRetFunc:
        begin
          if FFrameSP = 0 then
            if Fault(MakeError(peRuntime, 'return outside a function')) then Continue else Exit(False);
          savedRet := FFrames[FFrameSP - 1].ReturnAddr;  // value stays on the stack
          Dec(FFrameSP);
          // A re-entrant call (CallUserFunc) stops here, handing its return value
          // back to the host through the stack, when the frame it pushed unwinds.
          if FFrameSP = AStopFrameSP then Exit(True);
          pc := savedRet;
          Continue;
        end;
      opCall:
        begin
          argc := ins.B;
          // A user function shadows the library registry for the same name+arity.
          ufi := FProg.FindUserFunc(FProg.Consts.Get(ins.A).Str, argc);
          if ufi >= 0 then
          begin
            if FFrameSP = Length(FFrames) then
              SetLength(FFrames, (FFrameSP + 1) * 2);
            SetLength(FFrames[FFrameSP].Locals, Length(FProg.UserFuncs[ufi].LocalTypes));
            for i := argc - 1 downto 0 do
              FFrames[FFrameSP].Locals[i] := Pop;
            for i := argc to High(FProg.UserFuncs[ufi].LocalTypes) do
              FFrames[FFrameSP].Locals[i] := DefaultValue(FProg.UserFuncs[ufi].LocalTypes[i]);
            FFrames[FFrameSP].FuncIndex := ufi;
            FFrames[FFrameSP].ReturnAddr := pc + 1;
            Inc(FFrameSP);
            pc := FProg.UserFuncs[ufi].Entry;
            Continue;
          end;
          // library call (plain, or host-aware and given the VM to call back with)
          SetLength(args, argc);
          SetLength(kinds, argc);
          for i := argc - 1 downto 0 do
            args[i] := Pop;
          for i := 0 to argc - 1 do
            kinds[i] := args[i].Kind;
          res := Registry.Resolve(FProg.Consts.Get(ins.A).Str, kinds);
          if not res.Found then
          begin
            if Fault(MakeError(peUnknownFunction,
              'no function ' + SignatureOf(FProg.Consts.Get(ins.A).Str, args))) then Continue else Exit(False);
          end;
          e := NoError;
          if res.IsHost then
            r := res.HostFunc(Self, args, e)
          else
            r := res.Func(args, e);
          if IsError(e) then
          begin
            if Fault(e) then Continue else Exit(False);
          end;
          Push(r);
        end;
    else
      if Fault(MakeError(peRuntime, 'bad opcode ' + IntToStr(Ord(ins.Op)))) then Continue else Exit(False);
    end;
    Inc(pc);
  end;
  Result := True;
end;

procedure TPhosphorVM.ClearError;
begin
  FErrCode := 0;
  FErrMsg := '';
  FErrLine := 0;
end;

function TPhosphorVM.CallUserFunc(const AName: String; const Args: array of TValue;
  out Err: TPhosphorError): TValue;
var
  ufi, i, saved: Integer;
begin
  Result := Default(TValue);
  Err := NoError;
  if FProg = nil then
  begin
    Err := MakeError(peRuntime, 'no program is running');
    Exit;
  end;
  ufi := FProg.FindUserFunc(AName, Length(Args));
  if ufi < 0 then
  begin
    Err := MakeError(peUnknownFunction,
      'no BASIC function ' + AName + ' taking ' + IntToStr(Length(Args)) + ' argument(s)');
    Exit;
  end;
  // Push an activation frame, mirroring opCall's user-function path, then run the
  // body re-entrantly until it returns to this frame level. The stack, globals
  // and handle registry are shared with the running program on purpose: a callback
  // sees and mutates the same state, exactly like an in-line GOSUB would.
  saved := FFrameSP;
  if FFrameSP = Length(FFrames) then
    SetLength(FFrames, (FFrameSP + 1) * 2);
  SetLength(FFrames[FFrameSP].Locals, Length(FProg.UserFuncs[ufi].LocalTypes));
  for i := 0 to Length(Args) - 1 do
    FFrames[FFrameSP].Locals[i] := Args[i];
  for i := Length(Args) to High(FProg.UserFuncs[ufi].LocalTypes) do
    FFrames[FFrameSP].Locals[i] := DefaultValue(FProg.UserFuncs[ufi].LocalTypes[i]);
  FFrames[FFrameSP].FuncIndex := ufi;
  FFrames[FFrameSP].ReturnAddr := -1;   // unused: ExecFrom stops by frame level
  Inc(FFrameSP);
  if ExecFrom(FProg.UserFuncs[ufi].Entry, saved) then
    Result := Pop        // the routine's return value
  else
  begin
    Err := LastError;
    FFrameSP := saved;   // unwind on failure
  end;
end;

end.
