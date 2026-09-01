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
    procedure Push(const V: TValue);
    function Pop: TValue;
  public
    OnOutput: TPhosphorOutputProc;
    Registry: TPhosphorRegistry;
    LastError: TPhosphorError;
    ErrorLine: Integer;
    constructor Create;
    function Run(AProg: TProgram): Boolean;  // False on error (LastError/ErrorLine set)
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
  pc, i, argc, ufi: Integer;
  ins: TInstr;
  a, b, r, v: TValue;
  e: TPhosphorError;
  args: array of TValue;
  kinds: array of TValueKind;
  fn: TPhosphorFunc;
  lt: TVarType;

  function Bin(AErr: TPhosphorError; const AResult: TValue): Boolean;
  begin
    if IsError(AErr) then
    begin
      LastError := AErr;
      ErrorLine := ins.Line;
      Exit(False);
    end;
    Push(AResult);
    Result := True;
  end;

begin
  args := nil;
  kinds := nil;
  FSP := 0;
  FCSP := 0;
  FFrameSP := 0;
  FDataPtr := 0;
  LastError := NoError;
  ErrorLine := 0;
  SetLength(FVars, AProg.VarCount);
  for i := 0 to AProg.VarCount - 1 do
    FVars[i] := DefaultValue(AProg.VarTypes[i]);
  pc := 0;
  while pc < AProg.Count do
  begin
    ins := AProg.Instr(pc);
    case ins.Op of
      opNop: ;
      opPushConst: Push(AProg.Consts.Get(ins.A));
      opPop: Pop;
      opPrint:
        begin
          v := Pop;
          if Assigned(OnOutput) then OnOutput(ValToStr(v));
        end;
      opPrintLn:
        begin
          v := Pop;
          if Assigned(OnOutput) then OnOutput(ValToStr(v) + #10);
        end;
      opNeg:
        begin
          a := Pop;
          e := Negate(a, r);
          if not Bin(e, r) then Exit(False);
        end;
      opAdd:     begin b := Pop; a := Pop; if not Bin(ValAdd(a, b, r), r) then Exit(False); end;
      opSub:     begin b := Pop; a := Pop; if not Bin(ValSub(a, b, r), r) then Exit(False); end;
      opMul:     begin b := Pop; a := Pop; if not Bin(ValMul(a, b, r), r) then Exit(False); end;
      opDivReal: begin b := Pop; a := Pop; if not Bin(ValDivReal(a, b, r), r) then Exit(False); end;
      opDivInt:  begin b := Pop; a := Pop; if not Bin(ValDivInt(a, b, r), r) then Exit(False); end;
      opPow:     begin b := Pop; a := Pop; if not Bin(ValPow(a, b, r), r) then Exit(False); end;
      opMod:     begin b := Pop; a := Pop; if not Bin(ValMod(a, b, r), r) then Exit(False); end;
      opEQ:      begin b := Pop; a := Pop; if not Bin(ValCompare(coEQ, a, b, r), r) then Exit(False); end;
      opNE:      begin b := Pop; a := Pop; if not Bin(ValCompare(coNE, a, b, r), r) then Exit(False); end;
      opLT:      begin b := Pop; a := Pop; if not Bin(ValCompare(coLT, a, b, r), r) then Exit(False); end;
      opLE:      begin b := Pop; a := Pop; if not Bin(ValCompare(coLE, a, b, r), r) then Exit(False); end;
      opGT:      begin b := Pop; a := Pop; if not Bin(ValCompare(coGT, a, b, r), r) then Exit(False); end;
      opGE:      begin b := Pop; a := Pop; if not Bin(ValCompare(coGE, a, b, r), r) then Exit(False); end;
      opAnd:     begin b := Pop; a := Pop; if not Bin(ValAnd(a, b, r), r) then Exit(False); end;
      opOr:      begin b := Pop; a := Pop; if not Bin(ValOr(a, b, r), r) then Exit(False); end;
      opNot:     begin a := Pop; if not Bin(ValNot(a, r), r) then Exit(False); end;
      opLoadVar: Push(FVars[ins.A]);
      opStoreVar:
        begin
          v := Pop;
          if CanStore(AProg.VarTypes[ins.A], v, r) then
            FVars[ins.A] := r
          else
          begin
            LastError := MakeError(peTypeMismatch, 'cannot store ' + KindName(v.Kind) +
              ' into ' + VarTypeName(AProg.VarTypes[ins.A]) + ' variable');
            ErrorLine := ins.Line;
            Exit(False);
          end;
        end;
      opJumpIfFalse:
        begin
          v := Pop;
          if v.Kind <> vkBool then
          begin
            LastError := MakeError(peTypeMismatch, 'condition is not a boolean');
            ErrorLine := ins.Line;
            Exit(False);
          end;
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
          if FDataPtr >= AProg.DataCount then
          begin
            LastError := MakeError(peRuntime, 'out of DATA');
            ErrorLine := ins.Line;
            Exit(False);
          end;
          Push(AProg.DataPool[FDataPtr]);
          Inc(FDataPtr);
        end;
      opRestore: FDataPtr := 0;
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
          begin
            LastError := MakeError(peRuntime, 'RETURN without GOSUB');
            ErrorLine := ins.Line;
            Exit(False);
          end;
          Dec(FCSP);
          pc := FCallStack[FCSP];
          Continue;
        end;
      opLoadLocal: Push(FFrames[FFrameSP - 1].Locals[ins.A]);
      opStoreLocal:
        begin
          v := Pop;
          lt := AProg.UserFuncs[FFrames[FFrameSP - 1].FuncIndex].LocalTypes[ins.A];
          if CanStore(lt, v, r) then
            FFrames[FFrameSP - 1].Locals[ins.A] := r
          else
          begin
            LastError := MakeError(peTypeMismatch, 'cannot store ' + KindName(v.Kind) +
              ' into ' + VarTypeName(lt) + ' local');
            ErrorLine := ins.Line;
            Exit(False);
          end;
        end;
      opRetFunc:
        begin
          if FFrameSP = 0 then
          begin
            LastError := MakeError(peRuntime, 'return outside a function');
            ErrorLine := ins.Line;
            Exit(False);
          end;
          pc := FFrames[FFrameSP - 1].ReturnAddr;  // value stays on the stack
          Dec(FFrameSP);
          Continue;
        end;
      opCall:
        begin
          argc := ins.B;
          // A user function shadows the library registry for the same name+arity.
          ufi := AProg.FindUserFunc(AProg.Consts.Get(ins.A).Str, argc);
          if ufi >= 0 then
          begin
            if FFrameSP = Length(FFrames) then
              SetLength(FFrames, (FFrameSP + 1) * 2);
            SetLength(FFrames[FFrameSP].Locals, Length(AProg.UserFuncs[ufi].LocalTypes));
            for i := argc - 1 downto 0 do
              FFrames[FFrameSP].Locals[i] := Pop;
            for i := argc to High(AProg.UserFuncs[ufi].LocalTypes) do
              FFrames[FFrameSP].Locals[i] := DefaultValue(AProg.UserFuncs[ufi].LocalTypes[i]);
            FFrames[FFrameSP].FuncIndex := ufi;
            FFrames[FFrameSP].ReturnAddr := pc + 1;
            Inc(FFrameSP);
            pc := AProg.UserFuncs[ufi].Entry;
            Continue;
          end;
          // library call
          SetLength(args, argc);
          SetLength(kinds, argc);
          for i := argc - 1 downto 0 do
            args[i] := Pop;
          for i := 0 to argc - 1 do
            kinds[i] := args[i].Kind;
          if not Registry.Resolve(AProg.Consts.Get(ins.A).Str, kinds, fn) then
          begin
            LastError := MakeError(peUnknownFunction,
              'no function ' + SignatureOf(AProg.Consts.Get(ins.A).Str, args));
            ErrorLine := ins.Line;
            Exit(False);
          end;
          e := NoError;
          r := fn(args, e);
          if IsError(e) then
          begin
            LastError := e;
            ErrorLine := ins.Line;
            Exit(False);
          end;
          Push(r);
        end;
    else
      LastError := MakeError(peRuntime, 'bad opcode ' + IntToStr(Ord(ins.Op)));
      ErrorLine := ins.Line;
      Exit(False);
    end;
    Inc(pc);
  end;
  Result := True;
end;

end.
