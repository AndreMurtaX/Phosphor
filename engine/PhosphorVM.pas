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
  TPhosphorVM = class
  private
    FStack: array of TValue;
    FSP: Integer;    // points one past the top
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
  pc, i, argc: Integer;
  ins: TInstr;
  a, b, r, v: TValue;
  e: TPhosphorError;
  args: array of TValue;
  kinds: array of TValueKind;
  fn: TPhosphorFunc;

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
  LastError := NoError;
  ErrorLine := 0;
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
      opCall:
        begin
          argc := ins.B;
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
