{******************************************************************************
  Phosphor BASIC -- compiler (source -> TInstr stream)

  MIT License. Copyright (c) 2026 Andre Murta.

  Recursive-descent parser emitting a TProgram. Calls resolve on the actual
  runtime kinds of their arguments (dispatch is the type assertion), so the
  compiler stays syntactic. Variables are typed by their name suffix (the suffix
  is part of the name); the store is type-checked at run time.

  Strict boolean (decisions.md): a comparison produces a value everywhere, but a
  bare value is NOT a condition. Enforced structurally: FBool tracks whether the
  last-parsed expression's top-level result came from a comparison or a logical
  operator (and/or/not). A condition that is a bare value -- a number, a bool
  literal, a variable -- leaves FBool false and is rejected. That removes a
  special case rather than adding one.

  Increment-3 grammar: expression statements, PRINT/PRINTLN, LET / assignment,
  and inline IF (`if <condition> then <statement>`). Block IF and loops later.
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
    FBool: Boolean;   // did the last-parsed expression's top come from a compare/logical op?
    FVarNames: array of String;
    FVarTypes: array of TVarType;
    FVarCount: Integer;
    procedure Fail(const AMsg: String; ALine: Integer);
    procedure Expect(AKind: TTokenKind; const AWhat: String);
    function IsKeyword(const AKw: String): Boolean;
    function VarIndex(const AName: String): Integer;
    procedure ParseExpr;
    procedure ParseOr;
    procedure ParseAnd;
    procedure ParseNot;
    procedure ParseComparison;
    procedure ParseAdditive;
    procedure ParseMultiplicative;
    procedure ParsePower;
    procedure ParseUnary;
    procedure ParsePrimary;
    procedure ParseCall(const AName: String; ALine: Integer);
    procedure ParseCondition;
    procedure ParseIf;
    procedure ParseStatement;
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

function TPhosphorCompiler.IsKeyword(const AKw: String): Boolean;
begin
  Result := (FLex.Cur.Kind = tkIdent) and (FLex.Cur.StrVal = AKw);
end;

function TPhosphorCompiler.VarIndex(const AName: String): Integer;
var
  i: Integer;
begin
  for i := 0 to FVarCount - 1 do
    if FVarNames[i] = AName then
      Exit(i);
  if FVarCount = Length(FVarNames) then
  begin
    SetLength(FVarNames, (FVarCount + 1) * 2);
    SetLength(FVarTypes, (FVarCount + 1) * 2);
  end;
  FVarNames[FVarCount] := AName;
  FVarTypes[FVarCount] := VarTypeOf(AName);
  Result := FVarCount;
  Inc(FVarCount);
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
  FBool := False;   // a call's result type is not statically a condition
end;

procedure TPhosphorCompiler.ParsePrimary;
var
  t: TToken;
begin
  if FFailed then Exit;
  FBool := False;
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
        ParseExpr;                 // a parenthesized condition stays a condition
        Expect(tkRParen, '")"');
      end;
    tkIdent:
      begin
        if t.StrVal = 'true' then
        begin
          FProg.Emit(opPushConst, FProg.Consts.Add(ValBool(True)), 0, t.Line);
          FLex.Advance;
        end
        else if t.StrVal = 'false' then
        begin
          FProg.Emit(opPushConst, FProg.Consts.Add(ValBool(False)), 0, t.Line);
          FLex.Advance;
        end
        else if FLex.Peek.Kind = tkLParen then
        begin
          FLex.Advance; // the name
          ParseCall(t.StrVal, t.Line);
        end
        else
        begin
          FProg.Emit(opLoadVar, VarIndex(t.StrVal), 0, t.Line);  // variable read
          FLex.Advance;
        end;
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
    FBool := False;
  end
  else if FLex.Cur.Kind = tkPlus then
  begin
    FLex.Advance;
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
    FBool := False;
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
    FBool := False;
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
    FBool := False;
  end;
end;

procedure TPhosphorCompiler.ParseComparison;
var
  k: TTokenKind;
  ln: Integer;
begin
  ParseAdditive;
  if (not FFailed) and (FLex.Cur.Kind in [tkEQ, tkNE, tkLT, tkLE, tkGT, tkGE]) then
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
    FBool := True;   // a comparison IS bool-producing
  end;
end;

procedure TPhosphorCompiler.ParseNot;
var
  ln: Integer;
begin
  if IsKeyword('not') then
  begin
    ln := FLex.Cur.Line;
    FLex.Advance;
    ParseNot;
    FProg.Emit(opNot, 0, 0, ln);
    FBool := True;
  end
  else
    ParseComparison;
end;

procedure TPhosphorCompiler.ParseAnd;
var
  ln: Integer;
begin
  ParseNot;
  while (not FFailed) and IsKeyword('and') do
  begin
    ln := FLex.Cur.Line;
    FLex.Advance;
    ParseNot;
    FProg.Emit(opAnd, 0, 0, ln);
    FBool := True;
  end;
end;

procedure TPhosphorCompiler.ParseOr;
var
  ln: Integer;
begin
  ParseAnd;
  while (not FFailed) and IsKeyword('or') do
  begin
    ln := FLex.Cur.Line;
    FLex.Advance;
    ParseAnd;
    FProg.Emit(opOr, 0, 0, ln);
    FBool := True;
  end;
end;

procedure TPhosphorCompiler.ParseExpr;
begin
  ParseOr;
end;

procedure TPhosphorCompiler.ParseCondition;
var
  ln: Integer;
begin
  ln := FLex.Cur.Line;
  ParseExpr;
  if (not FFailed) and (not FBool) then
    Fail('a bare value is not a condition; use a comparison or a logical ' +
         'expression (and/or/not)', ln);
end;

procedure TPhosphorCompiler.ParseIf;
var
  ln, jIdx: Integer;
begin
  ln := FLex.Cur.Line;
  FLex.Advance; // 'if'
  ParseCondition;
  if FFailed then Exit;
  if not IsKeyword('then') then
  begin
    Fail('expected ''then''', FLex.Cur.Line);
    Exit;
  end;
  FLex.Advance; // 'then'
  if (FLex.Cur.Kind = tkEOL) or (FLex.Cur.Kind = tkEOF) then
  begin
    Fail('block IF (then ... end if) is a later step; write an inline ' +
         '''if <condition> then <statement>''', ln);
    Exit;
  end;
  jIdx := FProg.Emit(opJumpIfFalse, 0, 0, ln);
  ParseStatement;                       // the single then-branch statement
  if not FFailed then
    FProg.Patch(jIdx, FProg.Count);     // if false, skip past the then-branch
end;

procedure TPhosphorCompiler.ParseStatement;
var
  t, nameTok: TToken;
begin
  t := FLex.Cur;
  if t.Kind = tkIdent then
  begin
    if t.StrVal = 'if' then
    begin
      ParseIf;
      Exit;
    end;
    if (t.StrVal = 'print') or (t.StrVal = 'println') then
    begin
      FLex.Advance;
      if (FLex.Cur.Kind = tkEOL) or (FLex.Cur.Kind = tkEOF) then
      begin
        if t.StrVal = 'println' then
        begin
          FProg.Emit(opPushConst, FProg.Consts.Add(ValStr('')), 0, t.Line);
          FProg.Emit(opPrintLn, 0, 0, t.Line);
        end;
      end
      else
      begin
        ParseExpr;
        if t.StrVal = 'println' then FProg.Emit(opPrintLn, 0, 0, t.Line)
        else FProg.Emit(opPrint, 0, 0, t.Line);
      end;
      Exit;
    end;
    if t.StrVal = 'let' then
    begin
      FLex.Advance;
      if FLex.Cur.Kind <> tkIdent then
      begin
        Fail('expected a variable name after ''let''', FLex.Cur.Line);
        Exit;
      end;
      nameTok := FLex.Cur;
      FLex.Advance;
      Expect(tkEQ, '''=''');
      if FFailed then Exit;
      ParseExpr;
      if not FFailed then
        FProg.Emit(opStoreVar, VarIndex(nameTok.StrVal), 0, nameTok.Line);
      Exit;
    end;
    // assignment: <ident> = <expr>
    if (t.StrVal <> 'true') and (t.StrVal <> 'false') and (FLex.Peek.Kind = tkEQ) then
    begin
      FLex.Advance;   // the name
      FLex.Advance;   // '='
      ParseExpr;
      if not FFailed then
        FProg.Emit(opStoreVar, VarIndex(t.StrVal), 0, t.Line);
      Exit;
    end;
  end;
  // expression statement: evaluate and discard the result
  ParseExpr;
  if not FFailed then
    FProg.Emit(opPop, 0, 0, t.Line);
end;

function TPhosphorCompiler.Compile(const ASource: String; out AProg: TProgram): Boolean;
var
  i: Integer;
begin
  FFailed := False;
  FErr := '';
  FErrLine := 0;
  FVarCount := 0;
  FBool := False;
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
    FProg.VarCount := FVarCount;
    SetLength(FProg.VarTypes, FVarCount);
    for i := 0 to FVarCount - 1 do
      FProg.VarTypes[i] := FVarTypes[i];
    AProg := FProg;
    Result := True;
  end;
end;

end.
