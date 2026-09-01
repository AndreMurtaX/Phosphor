{******************************************************************************
  Phosphor BASIC -- compiler (source -> TInstr stream)

  MIT License. Copyright (c) 2026 Andre Murta.

  A recursive-descent parser that emits a TProgram (a TInstr stream over an
  indexable constant pool). It is purely syntactic: it does NOT infer static
  types for call dispatch. A call emits opCall with the function NAME and the
  argument count, and the VM resolves the overload from the ACTUAL runtime kinds
  of the arguments (PhosphorRegistry) -- so the dispatch itself is the type
  assertion, and dynamic typing (a later step) needs no change here.

  Increment-1 grammar: expression statements and PRINT/PRINTLN. Variables are a
  later step; a bare identifier that is not a call is rejected.
******************************************************************************}
unit PhosphorCompiler;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, PhosphorValue, PhosphorOpcodes, PhosphorLexer;

type
  TPhosphorCompiler = class
  private
    FLex: TLexer;
    FProg: TProgram;
    FFailed: Boolean;
    FErr: String;
    FErrLine: Integer;
    procedure Fail(const AMsg: String; ALine: Integer);
    procedure Expect(AKind: TTokenKind; const AWhat: String);
    procedure ParseStatement;
    procedure ParseExpr;
    procedure ParseComparison;
    procedure ParseAdditive;
    procedure ParseMultiplicative;
    procedure ParsePower;
    procedure ParseUnary;
    procedure ParsePrimary;
    procedure ParseCall(const AName: String; ALine: Integer);
  public
    function Compile(const ASource: String; out AProg: TProgram): Boolean;
    property ErrorMessage: String read FErr;
    property ErrorLine: Integer read FErrLine;
  end;

implementation

procedure TPhosphorCompiler.Fail(const AMsg: String; ALine: Integer);
begin
  if FFailed then Exit;
  FFailed := True;
  FErr := AMsg;
  FErrLine := ALine;
end;

procedure TPhosphorCompiler.Expect(AKind: TTokenKind; const AWhat: String);
begin
  if FFailed then Exit;
  if FLex.Cur.Kind <> AKind then
    Fail('expected ' + AWhat, FLex.Cur.Line)
  else
    FLex.Advance;
end;

procedure TPhosphorCompiler.ParseCall(const AName: String; ALine: Integer);
var
  argc: Integer;
begin
  FLex.Advance; // '('
  argc := 0;
  if FLex.Cur.Kind <> tkRParen then
  begin
    ParseExpr;
    Inc(argc);
    while (not FFailed) and (FLex.Cur.Kind = tkComma) do
    begin
      FLex.Advance;
      ParseExpr;
      Inc(argc);
    end;
  end;
  Expect(tkRParen, '")"');
  if FFailed then Exit;
  FProg.Emit(opCall, FProg.Consts.Add(ValStr(AName)), argc, ALine);
end;

procedure TPhosphorCompiler.ParsePrimary;
var
  t: TToken;
begin
  if FFailed then Exit;
  t := FLex.Cur;
  case t.Kind of
    tkInt:
      begin
        FProg.Emit(opPushConst, FProg.Consts.Add(ValInt(t.IntVal)), 0, t.Line);
        FLex.Advance;
      end;
    tkDouble:
      begin
        FProg.Emit(opPushConst, FProg.Consts.Add(ValDouble(t.DblVal)), 0, t.Line);
        FLex.Advance;
      end;
    tkString:
      begin
        FProg.Emit(opPushConst, FProg.Consts.Add(ValStr(t.StrVal)), 0, t.Line);
        FLex.Advance;
      end;
    tkLParen:
      begin
        FLex.Advance;
        ParseExpr;
        Expect(tkRParen, '")"');
      end;
    tkIdent:
      begin
        if FLex.Peek.Kind = tkLParen then
        begin
          FLex.Advance; // the name
          ParseCall(t.StrVal, t.Line);
        end
        else
          Fail('variables are not available yet (increment 1): ' + t.StrVal, t.Line);
      end;
  else
    Fail('unexpected token in expression', t.Line);
  end;
end;

procedure TPhosphorCompiler.ParseUnary;
var
  ln: Integer;
begin
  if FFailed then Exit;
  if FLex.Cur.Kind = tkMinus then
  begin
    ln := FLex.Cur.Line;
    FLex.Advance;
    ParseUnary;
    FProg.Emit(opNeg, 0, 0, ln);
  end
  else if FLex.Cur.Kind = tkPlus then
  begin
    FLex.Advance;   // unary plus: a no-op
    ParseUnary;
  end
  else
    ParsePrimary;
end;

procedure TPhosphorCompiler.ParsePower;
var
  ln: Integer;
begin
  ParseUnary;
  while (not FFailed) and (FLex.Cur.Kind = tkCaret) do
  begin
    ln := FLex.Cur.Line;
    FLex.Advance;
    ParseUnary;
    FProg.Emit(opPow, 0, 0, ln);
  end;
end;

procedure TPhosphorCompiler.ParseMultiplicative;
var
  k: TTokenKind;
  ln: Integer;
begin
  ParsePower;
  while (not FFailed) and (FLex.Cur.Kind in [tkStar, tkSlash, tkBackslash, tkMod]) do
  begin
    k := FLex.Cur.Kind;
    ln := FLex.Cur.Line;
    FLex.Advance;
    ParsePower;
    case k of
      tkStar:      FProg.Emit(opMul, 0, 0, ln);
      tkSlash:     FProg.Emit(opDivReal, 0, 0, ln);
      tkBackslash: FProg.Emit(opDivInt, 0, 0, ln);
      tkMod:       FProg.Emit(opMod, 0, 0, ln);
    end;
  end;
end;

procedure TPhosphorCompiler.ParseAdditive;
var
  k: TTokenKind;
  ln: Integer;
begin
  ParseMultiplicative;
  while (not FFailed) and (FLex.Cur.Kind in [tkPlus, tkMinus]) do
  begin
    k := FLex.Cur.Kind;
    ln := FLex.Cur.Line;
    FLex.Advance;
    ParseMultiplicative;
    if k = tkPlus then FProg.Emit(opAdd, 0, 0, ln)
    else FProg.Emit(opSub, 0, 0, ln);
  end;
end;

procedure TPhosphorCompiler.ParseComparison;
var
  k: TTokenKind;
  ln: Integer;
begin
  ParseAdditive;
  while (not FFailed) and (FLex.Cur.Kind in [tkEQ, tkNE, tkLT, tkLE, tkGT, tkGE]) do
  begin
    k := FLex.Cur.Kind;
    ln := FLex.Cur.Line;
    FLex.Advance;
    ParseAdditive;
    case k of
      tkEQ: FProg.Emit(opEQ, 0, 0, ln);
      tkNE: FProg.Emit(opNE, 0, 0, ln);
      tkLT: FProg.Emit(opLT, 0, 0, ln);
      tkLE: FProg.Emit(opLE, 0, 0, ln);
      tkGT: FProg.Emit(opGT, 0, 0, ln);
      tkGE: FProg.Emit(opGE, 0, 0, ln);
    end;
  end;
end;

procedure TPhosphorCompiler.ParseExpr;
begin
  ParseComparison;
end;

procedure TPhosphorCompiler.ParseStatement;
var
  t: TToken;
begin
  t := FLex.Cur;
  // PRINT / PRINTLN statements
  if (t.Kind = tkIdent) and ((t.StrVal = 'print') or (t.StrVal = 'println')) then
  begin
    FLex.Advance;
    if (FLex.Cur.Kind = tkEOL) or (FLex.Cur.Kind = tkEOF) then
    begin
      // bare PRINTLN prints just a newline; bare PRINT prints nothing
      if t.StrVal = 'println' then
      begin
        FProg.Emit(opPushConst, FProg.Consts.Add(ValStr('')), 0, t.Line);
        FProg.Emit(opPrintLn, 0, 0, t.Line);
      end;
    end
    else
    begin
      ParseExpr;
      if t.StrVal = 'println' then
        FProg.Emit(opPrintLn, 0, 0, t.Line)
      else
        FProg.Emit(opPrint, 0, 0, t.Line);
    end;
    Exit;
  end;
  // expression statement: evaluate and discard the result
  ParseExpr;
  if not FFailed then
    FProg.Emit(opPop, 0, 0, t.Line);
end;

function TPhosphorCompiler.Compile(const ASource: String; out AProg: TProgram): Boolean;
begin
  FFailed := False;
  FErr := '';
  FErrLine := 0;
  FProg := TProgram.Create;
  FLex := TLexer.Create(ASource);
  try
    if not FLex.Ok then
      Fail(FLex.ErrorMessage, FLex.ErrorLine);
    while (not FFailed) and (FLex.Cur.Kind <> tkEOF) do
    begin
      if FLex.Cur.Kind = tkEOL then
      begin
        FLex.Advance;
        Continue;
      end;
      ParseStatement;
      if FFailed then Break;
      if (FLex.Cur.Kind <> tkEOL) and (FLex.Cur.Kind <> tkEOF) then
        Fail('expected end of line', FLex.Cur.Line)
      else if FLex.Cur.Kind = tkEOL then
        FLex.Advance;
    end;
  finally
    FLex.Free;
  end;
  if FFailed then
  begin
    FProg.Free;
    AProg := nil;
    Result := False;
  end
  else
  begin
    AProg := FProg;
    Result := True;
  end;
end;

end.
