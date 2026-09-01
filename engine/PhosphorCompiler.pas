{******************************************************************************
  Phosphor BASIC -- compiler (source -> TInstr stream)

  MIT License. Copyright (c) 2026 Andre Murta.

  Recursive-descent parser emitting a TProgram. Calls resolve on the actual
  runtime kinds of their arguments (dispatch is the type assertion). Variables
  are typed by their name suffix; the store is type-checked at run time.

  Strict boolean (decisions.md): a comparison is a value everywhere, but a bare
  value is NOT a condition. Enforced structurally via FBool (did the last
  expression's top come from a comparison or a logical operator).

  Control flow (increment 4) is compiled to jumps and backpatched:
    * block and inline IF / ELSE / ENDIF
    * WHILE/ENDWHILE, DO WHILE/LOOP, REPEAT/UNTIL, FOR/NEXT (+STEP)
    * BREAK / CONTINUE (per innermost loop)
    * SELECT CASE / CASE / CASE ELSE / ENDSELECT
    * GOTO / GOSUB / RETURN / END with numeric line labels (forward references
      resolved after the whole program is parsed).
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
    FBool: Boolean;
    FVarNames: array of String;
    FVarTypes: array of TVarType;
    FVarCount: Integer;
    FHidden: Integer;
    // compile-time named constants (const NAME = literal), case-insensitive
    FConstNames: array of String;
    FConstVals: array of TValue;
    FConstCount: Integer;
    // current-function scope (params + locals live in a frame, not the globals)
    FInFunction: Boolean;
    FLocalNames: array of String;
    FLocalTypes: array of TVarType;
    FLocalCount: Integer;
    FRetType: TVarType;
    // loop context stack (for BREAK / CONTINUE)
    FLoopBreaks: array of array of Integer;
    FLoopConts: array of array of Integer;
    FLoopDepth: Integer;
    // labels and the GOTO/GOSUB sites that reference them. Keyed by name:
    // a numeric line label is stored as its digits (IntToStr), a named label
    // as its (lowercased) identifier -- the two can never collide because an
    // identifier cannot begin with a digit.
    FLabelName: array of String;
    FLabelPos: array of Integer;
    FLabelCount: Integer;
    FGotoInstr: array of Integer;
    FGotoName: array of String;
    FGotoCount: Integer;
    procedure Fail(const AMsg: String; ALine: Integer);
    procedure Expect(AKind: TTokenKind; const AWhat: String);
    function IsKeyword(const AKw: String): Boolean;
    function CurIsTerm(const ATerms: array of String): Boolean;
    function VarIndex(const AName: String): Integer;
    function NewHiddenVar(AType: TVarType): Integer;
    function LocalIndex(const AName: String): Integer;
    function ConstIndex(const AName: String): Integer;
    procedure AddLocal(const AName: String);
    procedure EmitLoadVar(const AName: String; ALine: Integer);
    procedure EmitStoreVar(const AName: String; ALine: Integer);
    function CompoundOp(K: TTokenKind): TOpcode;
    function IsReservedWord(const S: String): Boolean;
    procedure ParseFunction;
    procedure PushLoop;
    procedure PopLoop;
    procedure AddBreak(AInstr: Integer);
    procedure AddCont(AInstr: Integer);
    procedure PatchBreaks(ATarget: Integer);
    procedure PatchConts(ATarget: Integer);
    procedure RecordLabel(const AName: String; APos: Integer);
    procedure AddGoto(AInstr: Integer; const AName: String);
    procedure ResolveGotos;
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
    procedure ParseBlockUntil(const ATerms: array of String);
    procedure ParseIf;
    procedure ParseWhile;
    procedure ParseDo;
    procedure ParseRepeat;
    procedure ParseFor;
    procedure ParseSelect;
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

function TPhosphorCompiler.CurIsTerm(const ATerms: array of String): Boolean;
var i: Integer;
begin
  Result := False;
  if FLex.Cur.Kind <> tkIdent then Exit;
  for i := 0 to High(ATerms) do
    if FLex.Cur.StrVal = ATerms[i] then Exit(True);
end;

function TPhosphorCompiler.VarIndex(const AName: String): Integer;
var i: Integer;
begin
  for i := 0 to FVarCount - 1 do
    if FVarNames[i] = AName then Exit(i);
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

function TPhosphorCompiler.NewHiddenVar(AType: TVarType): Integer;
var name: String;
begin
  name := '__h' + IntToStr(FHidden);
  Inc(FHidden);
  Result := VarIndex(name);
  FVarTypes[Result] := AType;   // override the suffix-derived type
end;

function TPhosphorCompiler.LocalIndex(const AName: String): Integer;
var i: Integer;
begin
  Result := -1;
  if not FInFunction then Exit;
  for i := 0 to FLocalCount - 1 do
    if FLocalNames[i] = AName then Exit(i);
end;

function TPhosphorCompiler.ConstIndex(const AName: String): Integer;
var i: Integer;
begin
  Result := -1;
  for i := 0 to FConstCount - 1 do
    if FConstNames[i] = AName then Exit(i);
end;

procedure TPhosphorCompiler.AddLocal(const AName: String);
begin
  if FLocalCount = Length(FLocalNames) then
  begin
    SetLength(FLocalNames, (FLocalCount + 1) * 2);
    SetLength(FLocalTypes, (FLocalCount + 1) * 2);
  end;
  FLocalNames[FLocalCount] := AName;
  FLocalTypes[FLocalCount] := VarTypeOf(AName);
  Inc(FLocalCount);
end;

{ A name that is a parameter/local of the current function refers to a frame
  slot; any other name is a global. }
procedure TPhosphorCompiler.EmitLoadVar(const AName: String; ALine: Integer);
var li: Integer;
begin
  li := LocalIndex(AName);
  if li >= 0 then FProg.Emit(opLoadLocal, li, 0, ALine)
  else FProg.Emit(opLoadVar, VarIndex(AName), 0, ALine);
end;

procedure TPhosphorCompiler.EmitStoreVar(const AName: String; ALine: Integer);
var li: Integer;
begin
  li := LocalIndex(AName);
  if li >= 0 then FProg.Emit(opStoreLocal, li, 0, ALine)
  else FProg.Emit(opStoreVar, VarIndex(AName), 0, ALine);
end;

function TPhosphorCompiler.CompoundOp(K: TTokenKind): TOpcode;
begin
  case K of
    tkMinusEq: Result := opSub;
    tkStarEq:  Result := opMul;
    tkSlashEq: Result := opDivReal;
  else
    Result := opAdd;   // tkPlusEq
  end;
end;

{ True for the words that begin (or are) a statement or block token. A `name:'
  is a named label only when name is NOT one of these -- so a keyword statement
  followed by a ':' separator (`return :', `break :') is never read as a label.
  `const'/`elseif' stay here too: they work as variables via assignment, not as
  label names. }
function TPhosphorCompiler.IsReservedWord(const S: String): Boolean;
begin
  case S of
    'if', 'then', 'else', 'elseif', 'endif',
    'while', 'endwhile', 'wend', 'do', 'loop', 'repeat', 'until',
    'for', 'to', 'step', 'next',
    'select', 'case', 'endselect',
    'function', 'endfunction', 'return', 'local',
    'gosub', 'goto', 'break', 'continue', 'end',
    'let', 'const', 'data', 'read', 'restore',
    'print', 'println', 'dim',
    'and', 'or', 'not', 'mod', 'true', 'false':
      Result := True;
  else
    Result := False;
  end;
end;

procedure TPhosphorCompiler.ParseFunction;
var
  ln, entry, jOver, paramCount, i: Integer;
  funcName: String;
  retType: TVarType;
  ltypes: array of TVarType;
begin
  ltypes := nil;
  if FInFunction then begin Fail('nested functions are not supported', FLex.Cur.Line); Exit; end;
  ln := FLex.Cur.Line;
  FLex.Advance; // 'function'
  if FLex.Cur.Kind <> tkIdent then begin Fail('expected a function name', FLex.Cur.Line); Exit; end;
  funcName := FLex.Cur.StrVal;
  retType := VarTypeOf(funcName);
  FLex.Advance;
  Expect(tkLParen, '''(''');
  if FFailed then Exit;
  FLocalCount := 0;
  paramCount := 0;
  if FLex.Cur.Kind <> tkRParen then
    while not FFailed do
    begin
      if FLex.Cur.Kind <> tkIdent then begin Fail('expected a parameter name', FLex.Cur.Line); Exit; end;
      AddLocal(FLex.Cur.StrVal);
      Inc(paramCount);
      FLex.Advance;
      if FLex.Cur.Kind = tkComma then FLex.Advance else Break;
    end;
  Expect(tkRParen, ''')''');
  if FFailed then Exit;
  if IsKeyword('local') then
  begin
    FLex.Advance;
    while not FFailed do
    begin
      if FLex.Cur.Kind <> tkIdent then begin Fail('expected a local variable name', FLex.Cur.Line); Exit; end;
      AddLocal(FLex.Cur.StrVal);
      FLex.Advance;
      if FLex.Cur.Kind = tkComma then FLex.Advance else Break;
    end;
  end;

  FInFunction := True;
  FRetType := retType;
  jOver := FProg.Emit(opJump, 0, 0, ln);   // skip the body in normal flow
  entry := FProg.Count;
  SetLength(ltypes, FLocalCount);
  for i := 0 to FLocalCount - 1 do ltypes[i] := FLocalTypes[i];
  FProg.AddUserFunc(funcName, entry, paramCount, ltypes, retType);

  ParseBlockUntil(['endfunction']);
  if FFailed then Exit;
  // fall-through default return
  FProg.Emit(opPushConst, FProg.Consts.Add(DefaultValue(retType)), 0, ln);
  FProg.Emit(opRetFunc, 0, 0, ln);
  FProg.Patch(jOver, FProg.Count);
  if not IsKeyword('endfunction') then begin Fail('expected ''endfunction''', FLex.Cur.Line); Exit; end;
  FLex.Advance;
  FInFunction := False;
  FLocalCount := 0;
end;

procedure TPhosphorCompiler.PushLoop;
begin
  if FLoopDepth = Length(FLoopBreaks) then
  begin
    SetLength(FLoopBreaks, (FLoopDepth + 1) * 2);
    SetLength(FLoopConts, (FLoopDepth + 1) * 2);
  end;
  FLoopBreaks[FLoopDepth] := nil;
  FLoopConts[FLoopDepth] := nil;
  Inc(FLoopDepth);
end;

procedure TPhosphorCompiler.PopLoop;
begin
  if FLoopDepth > 0 then Dec(FLoopDepth);
end;

procedure TPhosphorCompiler.AddBreak(AInstr: Integer);
var n: Integer;
begin
  n := Length(FLoopBreaks[FLoopDepth - 1]);
  SetLength(FLoopBreaks[FLoopDepth - 1], n + 1);
  FLoopBreaks[FLoopDepth - 1][n] := AInstr;
end;

procedure TPhosphorCompiler.AddCont(AInstr: Integer);
var n: Integer;
begin
  n := Length(FLoopConts[FLoopDepth - 1]);
  SetLength(FLoopConts[FLoopDepth - 1], n + 1);
  FLoopConts[FLoopDepth - 1][n] := AInstr;
end;

procedure TPhosphorCompiler.PatchBreaks(ATarget: Integer);
var i: Integer;
begin
  for i := 0 to High(FLoopBreaks[FLoopDepth - 1]) do
    FProg.Patch(FLoopBreaks[FLoopDepth - 1][i], ATarget);
end;

procedure TPhosphorCompiler.PatchConts(ATarget: Integer);
var i: Integer;
begin
  for i := 0 to High(FLoopConts[FLoopDepth - 1]) do
    FProg.Patch(FLoopConts[FLoopDepth - 1][i], ATarget);
end;

procedure TPhosphorCompiler.RecordLabel(const AName: String; APos: Integer);
var l: Integer;
begin
  for l := 0 to FLabelCount - 1 do
    if FLabelName[l] = AName then
    begin
      Fail('duplicate label ' + AName, 0);
      Exit;
    end;
  if FLabelCount = Length(FLabelName) then
  begin
    SetLength(FLabelName, (FLabelCount + 1) * 2);
    SetLength(FLabelPos, (FLabelCount + 1) * 2);
  end;
  FLabelName[FLabelCount] := AName;
  FLabelPos[FLabelCount] := APos;
  Inc(FLabelCount);
end;

procedure TPhosphorCompiler.AddGoto(AInstr: Integer; const AName: String);
begin
  if FGotoCount = Length(FGotoInstr) then
  begin
    SetLength(FGotoInstr, (FGotoCount + 1) * 2);
    SetLength(FGotoName, (FGotoCount + 1) * 2);
  end;
  FGotoInstr[FGotoCount] := AInstr;
  FGotoName[FGotoCount] := AName;
  Inc(FGotoCount);
end;

procedure TPhosphorCompiler.ResolveGotos;
var g, l, pos: Integer;
begin
  for g := 0 to FGotoCount - 1 do
  begin
    pos := -1;
    for l := 0 to FLabelCount - 1 do
      if FLabelName[l] = FGotoName[g] then begin pos := FLabelPos[l]; Break; end;
    if pos < 0 then
    begin
      Fail('undefined label ' + FGotoName[g], 0);
      Exit;
    end;
    FProg.Patch(FGotoInstr[g], pos);
  end;
end;

// --- expressions ------------------------------------------------------------
procedure TPhosphorCompiler.ParseCall(const AName: String; ALine: Integer);
var argc: Integer;
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
  FBool := False;
end;

procedure TPhosphorCompiler.ParsePrimary;
var t: TToken;
begin
  if FFailed then Exit;
  FBool := False;
  t := FLex.Cur;
  case t.Kind of
    tkInt:    begin FProg.Emit(opPushConst, FProg.Consts.Add(ValInt(t.IntVal)), 0, t.Line); FLex.Advance; end;
    tkDouble: begin FProg.Emit(opPushConst, FProg.Consts.Add(ValDouble(t.DblVal)), 0, t.Line); FLex.Advance; end;
    tkString: begin FProg.Emit(opPushConst, FProg.Consts.Add(ValStr(t.StrVal)), 0, t.Line); FLex.Advance; end;
    tkLParen:
      begin
        FLex.Advance;
        ParseExpr;
        Expect(tkRParen, '")"');
      end;
    tkIdent:
      begin
        if t.StrVal = 'true' then begin FProg.Emit(opPushConst, FProg.Consts.Add(ValBool(True)), 0, t.Line); FLex.Advance; end
        else if t.StrVal = 'false' then begin FProg.Emit(opPushConst, FProg.Consts.Add(ValBool(False)), 0, t.Line); FLex.Advance; end
        else if FLex.Peek.Kind = tkLParen then begin FLex.Advance; ParseCall(t.StrVal, t.Line); end
        else if ConstIndex(t.StrVal) >= 0 then
        begin
          FProg.Emit(opPushConst, FProg.Consts.Add(FConstVals[ConstIndex(t.StrVal)]), 0, t.Line);
          FLex.Advance;
        end
        else
        begin
          EmitLoadVar(t.StrVal, t.Line);
          FLex.Advance;
          // bracket sugar: a@[i] -> array element; s$[n] -> line n; s$[[n]] -> char n
          if FLex.Cur.Kind = tkLBracket then
          begin
            if VarTypeOf(t.StrVal) = vtHandle then
            begin
              FLex.Advance;
              ParseExpr;
              Expect(tkRBracket, ''']''');
              FProg.Emit(opCall, FProg.Consts.Add(ValStr('arr_get')), 2, t.Line);
            end
            else if VarTypeOf(t.StrVal) = vtString then
            begin
              if FLex.Peek.Kind = tkLBracket then
              begin
                // s$[[n]] -> strchar$(s$, n)  (character, base-1 by codepoint)
                FLex.Advance; FLex.Advance;   // '[' '['
                ParseExpr;
                Expect(tkRBracket, ''']''');
                Expect(tkRBracket, ''']''');
                FProg.Emit(opCall, FProg.Consts.Add(ValStr('strchar$')), 2, t.Line);
              end
              else
              begin
                // s$[n] -> strline$(s$, n)  (line, base-1)
                FLex.Advance;
                ParseExpr;
                Expect(tkRBracket, ''']''');
                FProg.Emit(opCall, FProg.Consts.Add(ValStr('strline$')), 2, t.Line);
              end;
            end
            else
            begin
              Fail('[] indexing needs a handle (@) or string ($) variable', t.Line);
              Exit;
            end;
            FBool := False;
          end;
        end;
      end;
  else
    Fail('unexpected token in expression', t.Line);
  end;
end;

procedure TPhosphorCompiler.ParseUnary;
var ln: Integer;
begin
  if FFailed then Exit;
  if FLex.Cur.Kind = tkMinus then
  begin
    ln := FLex.Cur.Line; FLex.Advance; ParseUnary;
    FProg.Emit(opNeg, 0, 0, ln); FBool := False;
  end
  else if FLex.Cur.Kind = tkPlus then begin FLex.Advance; ParseUnary; end
  else ParsePrimary;
end;

procedure TPhosphorCompiler.ParsePower;
var ln: Integer;
begin
  ParseUnary;
  while (not FFailed) and (FLex.Cur.Kind = tkCaret) do
  begin
    ln := FLex.Cur.Line; FLex.Advance; ParseUnary;
    FProg.Emit(opPow, 0, 0, ln); FBool := False;
  end;
end;

procedure TPhosphorCompiler.ParseMultiplicative;
var k: TTokenKind; ln: Integer;
begin
  ParsePower;
  while (not FFailed) and (FLex.Cur.Kind in [tkStar, tkSlash, tkBackslash, tkMod]) do
  begin
    k := FLex.Cur.Kind; ln := FLex.Cur.Line; FLex.Advance; ParsePower;
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
var k: TTokenKind; ln: Integer;
begin
  ParseMultiplicative;
  while (not FFailed) and (FLex.Cur.Kind in [tkPlus, tkMinus]) do
  begin
    k := FLex.Cur.Kind; ln := FLex.Cur.Line; FLex.Advance; ParseMultiplicative;
    if k = tkPlus then FProg.Emit(opAdd, 0, 0, ln) else FProg.Emit(opSub, 0, 0, ln);
    FBool := False;
  end;
end;

procedure TPhosphorCompiler.ParseComparison;
var k: TTokenKind; ln: Integer;
begin
  ParseAdditive;
  if (not FFailed) and (FLex.Cur.Kind in [tkEQ, tkNE, tkLT, tkLE, tkGT, tkGE]) then
  begin
    k := FLex.Cur.Kind; ln := FLex.Cur.Line; FLex.Advance; ParseAdditive;
    case k of
      tkEQ: FProg.Emit(opEQ, 0, 0, ln);
      tkNE: FProg.Emit(opNE, 0, 0, ln);
      tkLT: FProg.Emit(opLT, 0, 0, ln);
      tkLE: FProg.Emit(opLE, 0, 0, ln);
      tkGT: FProg.Emit(opGT, 0, 0, ln);
      tkGE: FProg.Emit(opGE, 0, 0, ln);
    end;
    FBool := True;
  end;
end;

procedure TPhosphorCompiler.ParseNot;
var ln: Integer;
begin
  if IsKeyword('not') then
  begin
    ln := FLex.Cur.Line; FLex.Advance; ParseNot;
    FProg.Emit(opNot, 0, 0, ln); FBool := True;
  end
  else ParseComparison;
end;

procedure TPhosphorCompiler.ParseAnd;
var ln: Integer;
begin
  ParseNot;
  while (not FFailed) and IsKeyword('and') do
  begin
    ln := FLex.Cur.Line; FLex.Advance; ParseNot;
    FProg.Emit(opAnd, 0, 0, ln); FBool := True;
  end;
end;

procedure TPhosphorCompiler.ParseOr;
var ln: Integer;
begin
  ParseAnd;
  while (not FFailed) and IsKeyword('or') do
  begin
    ln := FLex.Cur.Line; FLex.Advance; ParseAnd;
    FProg.Emit(opOr, 0, 0, ln); FBool := True;
  end;
end;

procedure TPhosphorCompiler.ParseExpr;
begin
  ParseOr;
end;

procedure TPhosphorCompiler.ParseCondition;
var ln: Integer;
begin
  ln := FLex.Cur.Line;
  ParseExpr;
  if (not FFailed) and (not FBool) then
    Fail('a bare value is not a condition; use a comparison or a logical ' +
         'expression (and/or/not)', ln);
end;

// --- statement blocks -------------------------------------------------------
procedure TPhosphorCompiler.ParseBlockUntil(const ATerms: array of String);
begin
  while not FFailed do
  begin
    while FLex.Cur.Kind = tkEOL do FLex.Advance;
    if FLex.Cur.Kind = tkEOF then Exit;
    if CurIsTerm(ATerms) then Exit;
    ParseStatement;
    if FFailed then Exit;
    if (FLex.Cur.Kind = tkEOL) or (FLex.Cur.Kind = tkColon) then FLex.Advance  // ':' separates statements
    else if (FLex.Cur.Kind <> tkEOF) and not CurIsTerm(ATerms) then
      Fail('expected end of line', FLex.Cur.Line);
  end;
end;

procedure TPhosphorCompiler.ParseIf;
var
  ln, jFalse, jEnd, i: Integer;
  endJumps: array of Integer;
begin
  endJumps := nil;
  ln := FLex.Cur.Line;
  FLex.Advance; // 'if'
  ParseCondition;
  if FFailed then Exit;
  if not IsKeyword('then') then begin Fail('expected ''then''', FLex.Cur.Line); Exit; end;
  FLex.Advance; // 'then'
  if (FLex.Cur.Kind = tkEOL) or (FLex.Cur.Kind = tkEOF) then
  begin
    // block IF [ELSEIF ...] [ELSE] ENDIF
    jFalse := FProg.Emit(opJumpIfFalse, 0, 0, ln);
    ParseBlockUntil(['else', 'elseif', 'endif']);
    if FFailed then Exit;
    while IsKeyword('elseif') do
    begin
      FLex.Advance;
      SetLength(endJumps, Length(endJumps) + 1);          // taken branch -> jump to end
      endJumps[High(endJumps)] := FProg.Emit(opJump, 0, 0, ln);
      FProg.Patch(jFalse, FProg.Count);                    // prev cond false lands here
      ParseCondition;
      if FFailed then Exit;
      if not IsKeyword('then') then begin Fail('expected ''then''', FLex.Cur.Line); Exit; end;
      FLex.Advance;
      jFalse := FProg.Emit(opJumpIfFalse, 0, 0, ln);
      ParseBlockUntil(['else', 'elseif', 'endif']);
      if FFailed then Exit;
    end;
    if IsKeyword('else') then
    begin
      FLex.Advance;
      SetLength(endJumps, Length(endJumps) + 1);
      endJumps[High(endJumps)] := FProg.Emit(opJump, 0, 0, ln);
      FProg.Patch(jFalse, FProg.Count);
      ParseBlockUntil(['endif']);
      if FFailed then Exit;
    end
    else
      FProg.Patch(jFalse, FProg.Count);
    if not IsKeyword('endif') then begin Fail('expected ''endif''', FLex.Cur.Line); Exit; end;
    FLex.Advance;
    for i := 0 to High(endJumps) do
      FProg.Patch(endJumps[i], FProg.Count);
  end
  else
  begin
    // inline IF [ELSE]
    jFalse := FProg.Emit(opJumpIfFalse, 0, 0, ln);
    ParseStatement;
    if FFailed then Exit;
    if IsKeyword('else') then
    begin
      FLex.Advance;
      jEnd := FProg.Emit(opJump, 0, 0, ln);
      FProg.Patch(jFalse, FProg.Count);
      ParseStatement;
      if not FFailed then FProg.Patch(jEnd, FProg.Count);
    end
    else
      FProg.Patch(jFalse, FProg.Count);
  end;
end;

procedure TPhosphorCompiler.ParseWhile;
var ln, condStart, jFalse, afterLoop: Integer;
begin
  ln := FLex.Cur.Line;
  FLex.Advance; // 'while'
  PushLoop;
  condStart := FProg.Count;
  ParseCondition;
  if FFailed then Exit;
  jFalse := FProg.Emit(opJumpIfFalse, 0, 0, ln);
  ParseBlockUntil(['endwhile']);
  if FFailed then Exit;
  FProg.Emit(opJump, condStart, 0, ln);
  afterLoop := FProg.Count;
  FProg.Patch(jFalse, afterLoop);
  PatchBreaks(afterLoop);
  PatchConts(condStart);
  PopLoop;
  if not IsKeyword('endwhile') then begin Fail('expected ''endwhile''', FLex.Cur.Line); Exit; end;
  FLex.Advance;
end;

procedure TPhosphorCompiler.ParseDo;
var ln, condStart, jFalse, afterLoop: Integer;
begin
  ln := FLex.Cur.Line;
  FLex.Advance; // 'do'
  if not IsKeyword('while') then begin Fail('only ''do while <cond> ... loop'' is supported', FLex.Cur.Line); Exit; end;
  FLex.Advance; // 'while'
  PushLoop;
  condStart := FProg.Count;
  ParseCondition;
  if FFailed then Exit;
  jFalse := FProg.Emit(opJumpIfFalse, 0, 0, ln);
  ParseBlockUntil(['loop']);
  if FFailed then Exit;
  FProg.Emit(opJump, condStart, 0, ln);
  afterLoop := FProg.Count;
  FProg.Patch(jFalse, afterLoop);
  PatchBreaks(afterLoop);
  PatchConts(condStart);
  PopLoop;
  if not IsKeyword('loop') then begin Fail('expected ''loop''', FLex.Cur.Line); Exit; end;
  FLex.Advance;
end;

procedure TPhosphorCompiler.ParseRepeat;
var ln, bodyStart, contTarget, afterLoop: Integer;
begin
  ln := FLex.Cur.Line;
  FLex.Advance; // 'repeat'
  PushLoop;
  bodyStart := FProg.Count;
  ParseBlockUntil(['until']);
  if FFailed then Exit;
  contTarget := FProg.Count;   // continue re-checks the until condition
  if not IsKeyword('until') then begin Fail('expected ''until''', FLex.Cur.Line); Exit; end;
  FLex.Advance;
  ParseCondition;
  if FFailed then Exit;
  FProg.Emit(opJumpIfFalse, bodyStart, 0, ln);  // loop back while condition is false
  afterLoop := FProg.Count;
  PatchBreaks(afterLoop);
  PatchConts(contTarget);
  PopLoop;
end;

procedure TPhosphorCompiler.ParseFor;
var
  ln, endVar, condStart, jFalse, incPoint, afterLoop: Integer;
  step: TValue;
  down: Boolean;
  neg: Boolean;
  vname: String;
begin
  ln := FLex.Cur.Line;
  FLex.Advance; // 'for'
  if FLex.Cur.Kind <> tkIdent then begin Fail('expected a loop variable after ''for''', FLex.Cur.Line); Exit; end;
  vname := FLex.Cur.StrVal;   // resolved through the scope (local inside a function, else global)
  FLex.Advance;
  Expect(tkEQ, '''=''');
  if FFailed then Exit;
  ParseExpr;                                    // start value
  EmitStoreVar(vname, ln);
  if not IsKeyword('to') then begin Fail('expected ''to''', FLex.Cur.Line); Exit; end;
  FLex.Advance;
  endVar := NewHiddenVar(vtNumber);
  ParseExpr;                                     // end value
  FProg.Emit(opStoreVar, endVar, 0, ln);

  // STEP: optional numeric literal (possibly negative); default +1
  step := ValInt(1);
  down := False;
  if IsKeyword('step') then
  begin
    FLex.Advance;
    neg := False;
    if FLex.Cur.Kind = tkMinus then begin neg := True; FLex.Advance; end
    else if FLex.Cur.Kind = tkPlus then FLex.Advance;
    if FLex.Cur.Kind = tkInt then
    begin
      if neg then step := ValInt(-FLex.Cur.IntVal) else step := ValInt(FLex.Cur.IntVal);
      FLex.Advance;
    end
    else if FLex.Cur.Kind = tkDouble then
    begin
      if neg then step := ValDouble(-FLex.Cur.DblVal) else step := ValDouble(FLex.Cur.DblVal);
      FLex.Advance;
    end
    else begin Fail('for step must be a numeric literal', FLex.Cur.Line); Exit; end;
    down := AsDouble(step) < 0;
  end;

  PushLoop;
  condStart := FProg.Count;
  EmitLoadVar(vname, ln);
  FProg.Emit(opLoadVar, endVar, 0, ln);
  if down then FProg.Emit(opGE, 0, 0, ln) else FProg.Emit(opLE, 0, 0, ln);
  jFalse := FProg.Emit(opJumpIfFalse, 0, 0, ln);
  ParseBlockUntil(['next']);
  if FFailed then Exit;
  incPoint := FProg.Count;                       // continue jumps to the increment
  EmitLoadVar(vname, ln);
  FProg.Emit(opPushConst, FProg.Consts.Add(step), 0, ln);
  FProg.Emit(opAdd, 0, 0, ln);
  EmitStoreVar(vname, ln);
  FProg.Emit(opJump, condStart, 0, ln);
  afterLoop := FProg.Count;
  FProg.Patch(jFalse, afterLoop);
  PatchBreaks(afterLoop);
  PatchConts(incPoint);
  PopLoop;
  if not IsKeyword('next') then begin Fail('expected ''next''', FLex.Cur.Line); Exit; end;
  FLex.Advance;
end;

procedure TPhosphorCompiler.ParseSelect;
var
  ln, selVar, jNext, endTarget, i: Integer;
  endFixups: array of Integer;
begin
  ln := FLex.Cur.Line;
  FLex.Advance; // 'select'
  if not IsKeyword('case') then begin Fail('expected ''case'' after ''select''', FLex.Cur.Line); Exit; end;
  FLex.Advance; // 'case'
  selVar := NewHiddenVar(vtAny);
  ParseExpr;                                 // the subject
  FProg.Emit(opStoreVar, selVar, 0, ln);
  endFixups := nil;

  while not FFailed do
  begin
    while FLex.Cur.Kind = tkEOL do FLex.Advance;
    if IsKeyword('endselect') then Break;
    if not IsKeyword('case') then begin Fail('expected ''case'' or ''endselect''', FLex.Cur.Line); Exit; end;
    FLex.Advance; // 'case'
    if IsKeyword('else') then
    begin
      FLex.Advance;
      ParseBlockUntil(['endselect']);
      Break;
    end;
    // case <value>
    FProg.Emit(opLoadVar, selVar, 0, ln);
    ParseExpr;
    FProg.Emit(opEQ, 0, 0, ln);
    jNext := FProg.Emit(opJumpIfFalse, 0, 0, ln);
    ParseBlockUntil(['case', 'endselect']);
    if FFailed then Exit;
    SetLength(endFixups, Length(endFixups) + 1);
    endFixups[High(endFixups)] := FProg.Emit(opJump, 0, 0, ln);
    FProg.Patch(jNext, FProg.Count);
  end;
  if FFailed then Exit;
  if not IsKeyword('endselect') then begin Fail('expected ''endselect''', FLex.Cur.Line); Exit; end;
  FLex.Advance;
  endTarget := FProg.Count;
  for i := 0 to High(endFixups) do
    FProg.Patch(endFixups[i], endTarget);
end;

procedure TPhosphorCompiler.ParseStatement;
var
  t: TToken;
  i: Integer;
  cname: String;
  cval: TValue;
  neg: Boolean;
  k: TTokenKind;
begin
  t := FLex.Cur;
  if t.Kind = tkIdent then
  begin
    if t.StrVal = 'function' then begin ParseFunction; Exit; end;
    if t.StrVal = 'if' then begin ParseIf; Exit; end;
    if t.StrVal = 'while' then begin ParseWhile; Exit; end;
    if t.StrVal = 'do' then begin ParseDo; Exit; end;
    if t.StrVal = 'repeat' then begin ParseRepeat; Exit; end;
    if t.StrVal = 'for' then begin ParseFor; Exit; end;
    if t.StrVal = 'select' then begin ParseSelect; Exit; end;
    if t.StrVal = 'break' then
    begin
      FLex.Advance;
      if FLoopDepth = 0 then Fail('''break'' outside a loop', t.Line)
      else AddBreak(FProg.Emit(opJump, 0, 0, t.Line));
      Exit;
    end;
    if t.StrVal = 'continue' then
    begin
      FLex.Advance;
      if FLoopDepth = 0 then Fail('''continue'' outside a loop', t.Line)
      else AddCont(FProg.Emit(opJump, 0, 0, t.Line));
      Exit;
    end;
    if t.StrVal = 'goto' then
    begin
      FLex.Advance;
      if FLex.Cur.Kind = tkInt then
        begin i := FProg.Emit(opJump, 0, 0, t.Line); AddGoto(i, IntToStr(FLex.Cur.IntVal)); FLex.Advance; end
      else if FLex.Cur.Kind = tkIdent then
        begin i := FProg.Emit(opJump, 0, 0, t.Line); AddGoto(i, FLex.Cur.StrVal); FLex.Advance; end
      else Fail('''goto'' needs a line number or a label', FLex.Cur.Line);
      Exit;
    end;
    if t.StrVal = 'gosub' then
    begin
      FLex.Advance;
      if FLex.Cur.Kind = tkInt then
        begin i := FProg.Emit(opGosub, 0, 0, t.Line); AddGoto(i, IntToStr(FLex.Cur.IntVal)); FLex.Advance; end
      else if FLex.Cur.Kind = tkIdent then
        begin i := FProg.Emit(opGosub, 0, 0, t.Line); AddGoto(i, FLex.Cur.StrVal); FLex.Advance; end
      else Fail('''gosub'' needs a line number or a label', FLex.Cur.Line);
      Exit;
    end;
    if t.StrVal = 'return' then
    begin
      FLex.Advance;
      if FInFunction then
      begin
        // a function return carries a value (default of the return type if bare:
        // at end of line, before a ':' separator, or at end of input)
        if (FLex.Cur.Kind = tkEOL) or (FLex.Cur.Kind = tkEOF) or (FLex.Cur.Kind = tkColon) then
          FProg.Emit(opPushConst, FProg.Consts.Add(DefaultValue(FRetType)), 0, t.Line)
        else
          ParseExpr;
        FProg.Emit(opRetFunc, 0, 0, t.Line);
      end
      else
        FProg.Emit(opReturn, 0, 0, t.Line);   // GOSUB return
      Exit;
    end;
    if t.StrVal = 'end' then begin FLex.Advance; FProg.Emit(opHalt, 0, 0, t.Line); Exit; end;
    if t.StrVal = 'data' then
    begin
      FLex.Advance;
      while not FFailed do
      begin
        // one DATA constant: optional sign, then a number or a string
        if FLex.Cur.Kind = tkMinus then
        begin
          FLex.Advance;
          if FLex.Cur.Kind = tkInt then FProg.AddData(ValInt(-FLex.Cur.IntVal))
          else if FLex.Cur.Kind = tkDouble then FProg.AddData(ValDouble(-FLex.Cur.DblVal))
          else begin Fail('DATA expects a number after ''-''', FLex.Cur.Line); Exit; end;
          FLex.Advance;
        end
        else
        begin
          if FLex.Cur.Kind = tkPlus then FLex.Advance;
          case FLex.Cur.Kind of
            tkInt:    begin FProg.AddData(ValInt(FLex.Cur.IntVal)); FLex.Advance; end;
            tkDouble: begin FProg.AddData(ValDouble(FLex.Cur.DblVal)); FLex.Advance; end;
            tkString: begin FProg.AddData(ValStr(FLex.Cur.StrVal)); FLex.Advance; end;
          else
            Fail('DATA item must be a number or a string', FLex.Cur.Line); Exit;
          end;
        end;
        if FLex.Cur.Kind = tkComma then FLex.Advance else Break;
      end;
      Exit;
    end;
    if t.StrVal = 'read' then
    begin
      FLex.Advance;
      while not FFailed do
      begin
        if FLex.Cur.Kind <> tkIdent then begin Fail('READ needs a variable', FLex.Cur.Line); Exit; end;
        t := FLex.Cur;
        FLex.Advance;
        FProg.Emit(opReadData, 0, 0, t.Line);
        EmitStoreVar(t.StrVal, t.Line);
        if FLex.Cur.Kind = tkComma then FLex.Advance else Break;
      end;
      Exit;
    end;
    if t.StrVal = 'restore' then begin FLex.Advance; FProg.Emit(opRestore, 0, 0, t.Line); Exit; end;
    // indexed handle: a@[i] = <expr>  (set), or a@[i] alone (expression stmt)
    if (VarTypeOf(t.StrVal) = vtHandle) and (FLex.Peek.Kind = tkLBracket) then
    begin
      EmitLoadVar(t.StrVal, t.Line);   // the handle
      FLex.Advance;                    // the name
      FLex.Advance;                    // '['
      ParseExpr;                       // the index
      Expect(tkRBracket, ''']''');
      if FFailed then Exit;
      if FLex.Cur.Kind = tkEQ then
      begin
        FLex.Advance;
        ParseExpr;                     // the value
        FProg.Emit(opCall, FProg.Consts.Add(ValStr('arr_set')), 3, t.Line);
      end
      else if FLex.Cur.Kind in [tkPlusEq, tkMinusEq, tkStarEq, tkSlashEq] then
      begin
        // a@[i] op= x  ==  a@[i] = a@[i] op x, index evaluated once
        k := FLex.Cur.Kind;
        FLex.Advance;
        FProg.Emit(opDup2, 0, 0, t.Line);                                    // [h,i,h,i]
        FProg.Emit(opCall, FProg.Consts.Add(ValStr('arr_get')), 2, t.Line);  // [h,i,elem]
        ParseExpr;                                                            // [h,i,elem,rhs]
        FProg.Emit(CompoundOp(k), 0, 0, t.Line);                             // [h,i,newval]
        FProg.Emit(opCall, FProg.Consts.Add(ValStr('arr_set')), 3, t.Line);
      end
      else
        FProg.Emit(opCall, FProg.Consts.Add(ValStr('arr_get')), 2, t.Line);
      FProg.Emit(opPop, 0, 0, t.Line);  // statement: discard the call result
      Exit;
    end;
    if (t.StrVal = 'print') or (t.StrVal = 'println') then
    begin
      FLex.Advance;
      // `;`-separated items, printed adjacent (no separator); PRINTLN adds a
      // trailing newline, PRINT does not.
      if (FLex.Cur.Kind <> tkEOL) and (FLex.Cur.Kind <> tkEOF) then
      begin
        ParseExpr;
        FProg.Emit(opPrint, 0, 0, t.Line);
        while (not FFailed) and (FLex.Cur.Kind = tkSemicolon) do
        begin
          FLex.Advance;
          if (FLex.Cur.Kind = tkEOL) or (FLex.Cur.Kind = tkEOF) then Break;
          ParseExpr;
          FProg.Emit(opPrint, 0, 0, t.Line);
        end;
      end;
      if (not FFailed) and (t.StrVal = 'println') then
      begin
        FProg.Emit(opPushConst, FProg.Consts.Add(ValStr('')), 0, t.Line);
        FProg.Emit(opPrintLn, 0, 0, t.Line);
      end;
      Exit;
    end;
    // `const` is contextual: `const NAME = literal` declares a constant, but
    // `const = ...` (or `const` alone) is an ordinary variable named "const".
    if (t.StrVal = 'const') and (FLex.Peek.Kind = tkIdent) then
    begin
      FLex.Advance;
      cname := FLex.Cur.StrVal;
      FLex.Advance;
      Expect(tkEQ, '''=''');
      if FFailed then Exit;
      neg := False;
      if FLex.Cur.Kind = tkMinus then begin neg := True; FLex.Advance; end
      else if FLex.Cur.Kind = tkPlus then FLex.Advance;
      case FLex.Cur.Kind of
        tkInt:    if neg then cval := ValInt(-FLex.Cur.IntVal) else cval := ValInt(FLex.Cur.IntVal);
        tkDouble: if neg then cval := ValDouble(-FLex.Cur.DblVal) else cval := ValDouble(FLex.Cur.DblVal);
        tkString: cval := ValStr(FLex.Cur.StrVal);
      else
        Fail('const value must be a number or a string literal', FLex.Cur.Line); Exit;
      end;
      FLex.Advance;
      if FConstCount = Length(FConstNames) then
      begin
        SetLength(FConstNames, (FConstCount + 1) * 2);
        SetLength(FConstVals, (FConstCount + 1) * 2);
      end;
      FConstNames[FConstCount] := cname;
      FConstVals[FConstCount] := cval;
      Inc(FConstCount);
      Exit;
    end;
    if t.StrVal = 'let' then
    begin
      FLex.Advance;
      if FLex.Cur.Kind <> tkIdent then begin Fail('expected a variable name after ''let''', FLex.Cur.Line); Exit; end;
      t := FLex.Cur;
      FLex.Advance;
      if FLex.Cur.Kind = tkEQ then
      begin
        FLex.Advance;
        ParseExpr;
        if not FFailed then EmitStoreVar(t.StrVal, t.Line);
      end
      else
      begin
        // let <var>[, <var>...] -- declare only; the VM default-initializes them
        VarIndex(t.StrVal);
        while (not FFailed) and (FLex.Cur.Kind = tkComma) do
        begin
          FLex.Advance;
          if FLex.Cur.Kind <> tkIdent then begin Fail('expected a variable name', FLex.Cur.Line); Exit; end;
          VarIndex(FLex.Cur.StrVal);
          FLex.Advance;
        end;
      end;
      Exit;
    end;
    if (t.StrVal <> 'true') and (t.StrVal <> 'false') and (FLex.Peek.Kind = tkEQ) then
    begin
      FLex.Advance;  // name
      FLex.Advance;  // '='
      ParseExpr;
      if not FFailed then EmitStoreVar(t.StrVal, t.Line);
      Exit;
    end;
    // compound assignment: <var> op= <expr>  ==  <var> = <var> op <expr>
    if (t.StrVal <> 'true') and (t.StrVal <> 'false') and
       (FLex.Peek.Kind in [tkPlusEq, tkMinusEq, tkStarEq, tkSlashEq]) then
    begin
      k := FLex.Peek.Kind;
      FLex.Advance;  // name
      FLex.Advance;  // compound op
      EmitLoadVar(t.StrVal, t.Line);
      ParseExpr;
      if not FFailed then
      begin
        FProg.Emit(CompoundOp(k), 0, 0, t.Line);
        EmitStoreVar(t.StrVal, t.Line);
      end;
      Exit;
    end;
  end;
  // expression statement
  ParseExpr;
  if not FFailed then FProg.Emit(opPop, 0, 0, t.Line);
end;

function TPhosphorCompiler.Compile(const ASource: String; out AProg: TProgram): Boolean;
var i: Integer;
begin
  FFailed := False; FErr := ''; FErrLine := 0;
  FVarCount := 0; FHidden := 0; FLoopDepth := 0;
  FLabelCount := 0; FGotoCount := 0; FBool := False;
  FInFunction := False; FLocalCount := 0; FRetType := vtNumber;
  FConstCount := 0;
  FProg := TProgram.Create;
  FLex := TLexer.Create(ASource);
  try
    if not FLex.Ok then Fail(FLex.ErrorMessage, FLex.ErrorLine);
    while (not FFailed) and (FLex.Cur.Kind <> tkEOF) do
    begin
      if FLex.Cur.Kind = tkEOL then begin FLex.Advance; Continue; end;
      // a leading line number is a label
      if FLex.Cur.Kind = tkInt then
      begin
        RecordLabel(IntToStr(FLex.Cur.IntVal), FProg.Count);
        FLex.Advance;
        if (FLex.Cur.Kind = tkEOL) or (FLex.Cur.Kind = tkEOF) then
        begin
          if FLex.Cur.Kind = tkEOL then FLex.Advance;
          Continue;
        end;
      end;
      // a leading `name:` is a named label. An identifier alone is never a
      // statement, so `ident :' at the start of one can only be a label --
      // except a keyword, which may be a statement with a ':' separator after.
      if (FLex.Cur.Kind = tkIdent) and (FLex.Peek.Kind = tkColon) and
         (not IsReservedWord(FLex.Cur.StrVal)) then
      begin
        RecordLabel(FLex.Cur.StrVal, FProg.Count);
        FLex.Advance;   // name
        FLex.Advance;   // ':'
        Continue;
      end;
      ParseStatement;
      if FFailed then Break;
      if FLex.Cur.Kind = tkColon then
        FLex.Advance                                     // ':' separates statements on a line
      else if (FLex.Cur.Kind <> tkEOL) and (FLex.Cur.Kind <> tkEOF) then
        Fail('expected end of line', FLex.Cur.Line)
      else if FLex.Cur.Kind = tkEOL then
        FLex.Advance;
    end;
    if not FFailed then ResolveGotos;
  finally
    FLex.Free;
  end;
  if FFailed then
  begin
    FProg.Free; AProg := nil; Result := False;
  end
  else
  begin
    FProg.VarCount := FVarCount;
    SetLength(FProg.VarTypes, FVarCount);
    for i := 0 to FVarCount - 1 do FProg.VarTypes[i] := FVarTypes[i];
    AProg := FProg; Result := True;
  end;
end;

end.
