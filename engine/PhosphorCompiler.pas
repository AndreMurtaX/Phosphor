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
    procedure ParseJsonLiteral;   // [ ... ] / { ... } assigned to a handle
    procedure ParseOnGoto;        // on <expr> goto/gosub label1, label2, ...
    procedure ParseOnError;       // on error goto <label> | on error goto 0
    procedure ParseCall(const AName: String; ALine: Integer);
    procedure ParseCondition;
    procedure ParseBlockUntil(const ATerms: array of String);
    procedure ParseIf;
    procedure ParseSignedPrimary;
    procedure ParseInlineStatements;
    procedure ParseWhile;
    procedure ParseDo;
    procedure ParseRepeat;
    procedure ParseFor;
    procedure ParseSelect;
    procedure ParseTrace;         // trace <expr>
    procedure ParseBreakpoint;    // breakpoint <msg> [, <expr>]*
    procedure ParseInput(AIsLine: Boolean);  // input / line input (console or #file)
    procedure ParseOpen;          // open <path> for input|output|append as #n
    procedure ParseClose;         // close [#n [, #n]...]  (bare = close all)
    procedure ParseSeek;          // seek #n, <1-based position>
    procedure ParseSwap;          // swap <lvalue>, <lvalue>
    procedure ParsePrintFile(AAddNewline: Boolean);   // print #n [, item[; item...]]
    procedure ParsePrintUsing(AAddNewline: Boolean);  // print using fmt$; args
    procedure EmitReadTarget(APos: Integer);   // SWAP: emit code that reads an lvalue
    procedure EmitWriteTarget(APos, ATempVar: Integer); // SWAP: assign a temp into an lvalue
    procedure SkipTarget;         // SWAP: advance the lexer past one lvalue
    function  InputTypeCode(const AName: String): Integer;
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
  if FLex.Cur().Kind <> AKind then
    Fail('expected ' + AWhat, FLex.Cur().Line)
  else
    FLex.Advance();
end;

function TPhosphorCompiler.IsKeyword(const AKw: String): Boolean;
begin
  Result := (FLex.Cur().Kind = tkIdent) and (FLex.Cur().StrVal = AKw);
end;

function TPhosphorCompiler.CurIsTerm(const ATerms: array of String): Boolean;
var i: Integer;
begin
  Result := False;
  if FLex.Cur().Kind <> tkIdent then Exit;
  for i := 0 to High(ATerms) do
    if FLex.Cur().StrVal = ATerms[i] then Exit(True);
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
  // A name declared `const' is a fixed value, not a slot -- writing to it (by
  // '=', a compound op, READ, or a FOR variable) is a compile error, so a const
  // and a like-named variable can never quietly coexist.
  if ConstIndex(AName) >= 0 then
  begin
    Fail('cannot assign to constant ' + AName, ALine);
    Exit;
  end;
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
    'trace', 'breakpoint',
    // The classic I/O and standard-BASIC statements, added with them and never
    // added HERE -- which is why `close : rem done` became a label named "close"
    // and the file was never closed. Only words that can BEGIN a statement belong
    // in this list: `as`, `output` and `using` appear inside one and can still be
    // used as label names without ambiguity.
    'input', 'open', 'close', 'seek', 'swap', 'line', 'on', 'resume',
    'and', 'or', 'not', 'mod', 'true', 'false':
      Result := True;
  else
    Result := False;
  end;
end;

procedure TPhosphorCompiler.ParseFunction;
var
  ln, entry, jOver, paramCount, i, ufIdx: Integer;
  funcName: String;
  retType: TVarType;
  ltypes: array of TVarType;
begin
  ltypes := nil;
  if FInFunction then begin Fail('nested functions are not supported', FLex.Cur().Line); Exit; end;
  ln := FLex.Cur().Line;
  FLex.Advance(); // 'function'
  if FLex.Cur().Kind <> tkIdent then begin Fail('expected a function name', FLex.Cur().Line); Exit; end;
  funcName := FLex.Cur().StrVal;
  // eof/lof/loc/input$ are parsed as special forms because they take a #channel.
  // A function with one of those names used to compile cleanly and then never be
  // called: every call site was rewritten into the file opcode instead. Silently
  // unreachable code is worse than a rejected name.
  if (funcName = 'eof') or (funcName = 'lof') or (funcName = 'loc') or
     (funcName = 'input$') then
  begin
    Fail('"' + funcName + '" is a file function built into the language and ' +
         'cannot be redefined', FLex.Cur().Line);
    Exit;
  end;
  retType := VarTypeOf(funcName);
  FLex.Advance();
  Expect(tkLParen, '''(''');
  if FFailed then Exit;
  FLocalCount := 0;
  paramCount := 0;
  if FLex.Cur().Kind <> tkRParen then
    while not FFailed do
    begin
      if FLex.Cur().Kind <> tkIdent then begin Fail('expected a parameter name', FLex.Cur().Line); Exit; end;
      AddLocal(FLex.Cur().StrVal);
      Inc(paramCount);
      FLex.Advance();
      if FLex.Cur().Kind = tkComma then FLex.Advance() else Break;
    end;
  Expect(tkRParen, ''')''');
  if FFailed then Exit;
  if IsKeyword('local') then
  begin
    FLex.Advance();
    while not FFailed do
    begin
      if FLex.Cur().Kind <> tkIdent then begin Fail('expected a local variable name', FLex.Cur().Line); Exit; end;
      AddLocal(FLex.Cur().StrVal);
      FLex.Advance();
      if FLex.Cur().Kind = tkComma then FLex.Advance() else Break;
    end;
  end;

  FInFunction := True;
  FRetType := retType;
  jOver := FProg.Emit(opJump, 0, 0, ln);   // skip the body in normal flow
  entry := FProg.Count;
  SetLength(ltypes, FLocalCount);
  for i := 0 to FLocalCount - 1 do ltypes[i] := FLocalTypes[i];
  ufIdx := FProg.AddUserFunc(funcName, entry, paramCount, ltypes, retType);

  ParseBlockUntil(['endfunction']);
  if FFailed then Exit;
  // The body can ADD locals -- a FOR bound is one -- and the type table was taken
  // before the body was parsed, so those slots were missing from it. The frame is
  // sized from this table, so an index past its end read a garbage type ("cannot
  // store int into ? local") and then walked off the frame. Rewritten with what the
  // body actually needs.
  SetLength(ltypes, FLocalCount);
  for i := 0 to FLocalCount - 1 do ltypes[i] := FLocalTypes[i];
  FProg.SetUserFuncLocals(ufIdx, ltypes);
  // fall-through default return
  FProg.Emit(opPushConst, FProg.Consts.Add(DefaultValue(retType)), 0, ln);
  FProg.Emit(opRetFunc, 0, 0, ln);
  FProg.Patch(jOver, FProg.Count);
  if not IsKeyword('endfunction') then begin Fail('expected ''endfunction''', FLex.Cur().Line); Exit; end;
  FLex.Advance();
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
  FLex.Advance(); // '('
  argc := 0;
  if FLex.Cur().Kind <> tkRParen then
  begin
    ParseExpr();
    Inc(argc);
    while (not FFailed) and (FLex.Cur().Kind = tkComma) do
    begin
      FLex.Advance();
      ParseExpr();
      Inc(argc);
    end;
  end;
  Expect(tkRParen, '")"');
  if FFailed then Exit;
  FProg.Emit(opCall, FProg.Consts.Add(ValStr(AName)), argc, ALine);
  FBool := False;
end;

procedure TPhosphorCompiler.ParsePrimary;
var t: TToken; nidx: Integer;
begin
  if FFailed then Exit;
  FBool := False;
  t := FLex.Cur();
  case t.Kind of
    // A leading '[' or '{' at a value position opens a JSON literal. (A '[' that
    // follows an operand -- a@[i] -- is handled as a postfix in the tkIdent case,
    // so it never reaches here.)
    tkLBracket, tkLBrace: ParseJsonLiteral();
    tkInt:    begin FProg.Emit(opPushConst, FProg.Consts.Add(ValInt(t.IntVal)), 0, t.Line); FLex.Advance(); end;
    tkDouble: begin FProg.Emit(opPushConst, FProg.Consts.Add(ValDouble(t.DblVal)), 0, t.Line); FLex.Advance(); end;
    tkString: begin FProg.Emit(opPushConst, FProg.Consts.Add(ValStr(t.StrVal)), 0, t.Line); FLex.Advance(); end;
    tkLParen:
      begin
        FLex.Advance();
        ParseExpr();
        Expect(tkRParen, '")"');
      end;
    tkIdent:
      begin
        if t.StrVal = 'true' then begin FProg.Emit(opPushConst, FProg.Consts.Add(ValBool(True)), 0, t.Line); FLex.Advance(); end
        else if t.StrVal = 'false' then begin FProg.Emit(opPushConst, FProg.Consts.Add(ValBool(False)), 0, t.Line); FLex.Advance(); end
        // INPUT$(n) reads n console chars; INPUT$(n, #f) reads them from a file --
        // both need VM-side I/O state, so they are opcodes, not registry calls.
        else if (t.StrVal = 'input$') and (FLex.Peek().Kind = tkLParen) then
        begin
          FLex.Advance(); FLex.Advance();   // 'input$' '('
          ParseExpr();                    // the character count
          if FLex.Cur().Kind = tkComma then
          begin
            FLex.Advance();
            if FLex.Cur().Kind = tkHash then FLex.Advance();   // optional '#'
            ParseExpr();                  // the file number  -> stack [count, chan]
            Expect(tkRParen, '")"');
            FProg.Emit(opFileChars, 0, 0, t.Line);
          end
          else
          begin
            Expect(tkRParen, '")"');
            FProg.Emit(opInputChars, 0, 0, t.Line);
          end;
          FBool := False;
        end
        // EOF(#f)/LOF(#f)/LOC(#f): file-channel state, so opcodes over the VM table.
        else if ((t.StrVal = 'eof') or (t.StrVal = 'lof') or (t.StrVal = 'loc')) and
                (FLex.Peek().Kind = tkLParen) then
        begin
          FLex.Advance(); FLex.Advance();   // name '('
          if FLex.Cur().Kind = tkHash then FLex.Advance();   // optional '#'
          ParseExpr();                    // the file number
          Expect(tkRParen, '")"');
          if t.StrVal = 'eof' then FProg.Emit(opEofFile, 0, 0, t.Line)
          else if t.StrVal = 'lof' then FProg.Emit(opLofFile, 0, 0, t.Line)
          else FProg.Emit(opLocFile, 0, 0, t.Line);
          FBool := False;
        end
        else if FLex.Peek().Kind = tkLParen then begin FLex.Advance(); ParseCall(t.StrVal, t.Line); end
        else if ConstIndex(t.StrVal) >= 0 then
        begin
          FProg.Emit(opPushConst, FProg.Consts.Add(FConstVals[ConstIndex(t.StrVal)]), 0, t.Line);
          FLex.Advance();
        end
        else
        begin
          EmitLoadVar(t.StrVal, t.Line);
          FLex.Advance();
          // bracket sugar: a@[i] -> array element; s$[n] -> line n; s$[[n]] -> char n
          if FLex.Cur().Kind = tkLBracket then
          begin
            if VarTypeOf(t.StrVal) = vtHandle then
            begin
              // a@[i]  or  a@[i, j, ...] -- N comma-separated indices, one call.
              FLex.Advance();
              ParseExpr();
              nidx := 1;
              while (not FFailed) and (FLex.Cur().Kind = tkComma) do
              begin
                FLex.Advance();
                ParseExpr();
                Inc(nidx);
              end;
              Expect(tkRBracket, ''']''');
              FProg.Emit(opCall, FProg.Consts.Add(ValStr('arr_get')), 1 + nidx, t.Line);
            end
            else if VarTypeOf(t.StrVal) = vtString then
            begin
              if FLex.Peek().Kind = tkLBracket then
              begin
                // s$[[n]] -> strchar$(s$, n)  (character, base-1 by codepoint)
                FLex.Advance(); FLex.Advance();   // '[' '['
                ParseExpr();
                Expect(tkRBracket, ''']''');
                Expect(tkRBracket, ''']''');
                FProg.Emit(opCall, FProg.Consts.Add(ValStr('strchar$')), 2, t.Line);
              end
              else
              begin
                // s$[n] -> strline$(s$, n)  (line, base-1)
                FLex.Advance();
                ParseExpr();
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

{ A JSON literal builds its tree at run time through the JSON library, so element
  values can be any expression (a variable, a call), not just constants. The
  container handle stays on the stack: json_array@/json_object@ leave it there and
  every json_pushval@/json_setval@ returns it, so the literal's value is the handle
  once the closing bracket is reached. Newlines are ignored INSIDE a literal. }
procedure TPhosphorCompiler.ParseJsonLiteral;

  procedure SkipEols;
  begin
    while FLex.Cur().Kind = tkEOL do FLex.Advance();
  end;

var
  ln: Integer;
  key: String;
begin
  ln := FLex.Cur().Line;
  if FLex.Cur().Kind = tkLBracket then
  begin
    FLex.Advance();   // '['
    FProg.Emit(opCall, FProg.Consts.Add(ValStr('json_array@')), 0, ln);
    SkipEols();
    if FLex.Cur().Kind <> tkRBracket then
      repeat
        SkipEols();
        if (FLex.Cur().Kind = tkIdent) and (FLex.Cur().StrVal = 'null') then
        begin
          FLex.Advance();
          FProg.Emit(opCall, FProg.Consts.Add(ValStr('json_pushnull@')), 1, ln);
        end
        else
        begin
          ParseExpr();
          if FFailed then Exit;
          FProg.Emit(opCall, FProg.Consts.Add(ValStr('json_pushval@')), 2, ln);
        end;
        SkipEols();
        if FLex.Cur().Kind = tkComma then begin FLex.Advance(); SkipEols(); end else Break;
      until FFailed;
    SkipEols();
    Expect(tkRBracket, ''']''');
  end
  else
  begin
    FLex.Advance();   // '{'
    FProg.Emit(opCall, FProg.Consts.Add(ValStr('json_object@')), 0, ln);
    SkipEols();
    if FLex.Cur().Kind <> tkRBrace then
      repeat
        SkipEols();
        if FLex.Cur().Kind <> tkString then
        begin Fail('a JSON object key must be a string', FLex.Cur().Line); Exit; end;
        key := FLex.Cur().StrVal;
        FLex.Advance();
        Expect(tkColon, ''':''');
        if FFailed then Exit;
        SkipEols();
        FProg.Emit(opPushConst, FProg.Consts.Add(ValStr(key)), 0, ln);   // the key
        if (FLex.Cur().Kind = tkIdent) and (FLex.Cur().StrVal = 'null') then
        begin
          FLex.Advance();
          FProg.Emit(opCall, FProg.Consts.Add(ValStr('json_setnull@')), 2, ln);
        end
        else
        begin
          ParseExpr();
          if FFailed then Exit;
          FProg.Emit(opCall, FProg.Consts.Add(ValStr('json_setval@')), 3, ln);
        end;
        SkipEols();
        if FLex.Cur().Kind = tkComma then begin FLex.Advance(); SkipEols(); end else Break;
      until FFailed;
    SkipEols();
    Expect(tkRBrace, '''}''');
  end;
  FBool := False;
end;

{ Computed jump: the 1-based selector picks the Nth label. Compiled as a chain of
  equality tests -- if the selector equals i, take label i; an out-of-range value
  matches nothing and falls through. GOSUB branches return here and then skip to
  the end so the following labels are not re-tested. }
procedure TPhosphorCompiler.ParseOnGoto;
var
  ln, tmp, idx, jNext, j: Integer;
  isGosub: Boolean;
  labelName: String;
  endJumps: array of Integer;
begin
  ln := FLex.Cur().Line;
  FLex.Advance();                       // 'on'
  tmp := NewHiddenVar(vtNumber);
  ParseExpr();                          // the selector
  if FFailed then Exit;
  FProg.Emit(opStoreVar, tmp, 0, ln);
  if IsKeyword('gosub') then isGosub := True
  else if IsKeyword('goto') then isGosub := False
  else begin Fail('expected ''goto'' or ''gosub'' after ''on <expr>''', FLex.Cur().Line); Exit; end;
  FLex.Advance();                       // 'goto' / 'gosub'
  endJumps := nil;
  idx := 1;
  repeat
    if FLex.Cur().Kind = tkInt then labelName := IntToStr(FLex.Cur().IntVal)
    else if FLex.Cur().Kind = tkIdent then labelName := FLex.Cur().StrVal
    else begin Fail('''on'' needs a list of labels', FLex.Cur().Line); Exit; end;
    FLex.Advance();
    FProg.Emit(opLoadVar, tmp, 0, ln);
    FProg.Emit(opPushConst, FProg.Consts.Add(ValInt(idx)), 0, ln);
    FProg.Emit(opEQ, 0, 0, ln);
    jNext := FProg.Emit(opJumpIfFalse, 0, 0, ln);   // selector <> idx: next test
    if isGosub then
    begin
      j := FProg.Emit(opGosub, 0, 0, ln); AddGoto(j, labelName);
      SetLength(endJumps, Length(endJumps) + 1);
      endJumps[High(endJumps)] := FProg.Emit(opJump, 0, 0, ln);   // after return, jump to end
    end
    else
    begin
      j := FProg.Emit(opJump, 0, 0, ln); AddGoto(j, labelName);
    end;
    FProg.Patch(jNext, FProg.Count);
    Inc(idx);
    if FLex.Cur().Kind = tkComma then FLex.Advance() else Break;
  until FFailed;
  for j := 0 to High(endJumps) do FProg.Patch(endJumps[j], FProg.Count);
end;

procedure TPhosphorCompiler.ParseOnError;
var ln, j: Integer;
begin
  ln := FLex.Cur().Line;
  FLex.Advance();   // 'on'
  FLex.Advance();   // 'error'
  if IsKeyword('call') then
  begin
    FLex.Advance();   // 'call'
    if FLex.Cur().Kind <> tkIdent then begin Fail('''on error call'' needs a function name', FLex.Cur().Line); Exit; end;
    // B = 1 marks the call form; A = the const index of the function name. The VM
    // runs func(code%, msg$) on a fault and continues (return 0) or aborts (else).
    FProg.Emit(opSetErrHandler, FProg.Consts.Add(ValStr(FLex.Cur().StrVal)), 1, ln);
    FLex.Advance();   // the function name
    Exit;
  end;
  if not IsKeyword('goto') then begin Fail('expected ''goto'' or ''call'' after ''on error''', FLex.Cur().Line); Exit; end;
  FLex.Advance();   // 'goto'
  if (FLex.Cur().Kind = tkInt) and (FLex.Cur().IntVal = 0) then
  begin
    FProg.Emit(opSetErrHandler, -1, 0, ln);   // on error goto 0 -- disable the handler
    FLex.Advance();
  end
  else if FLex.Cur().Kind = tkInt then
    begin j := FProg.Emit(opSetErrHandler, 0, 0, ln); AddGoto(j, IntToStr(FLex.Cur().IntVal)); FLex.Advance(); end
  else if FLex.Cur().Kind = tkIdent then
    begin j := FProg.Emit(opSetErrHandler, 0, 0, ln); AddGoto(j, FLex.Cur().StrVal); FLex.Advance(); end
  else
    Fail('''on error goto'' needs a label or 0', FLex.Cur().Line);
end;

procedure TPhosphorCompiler.ParseUnary;
var ln: Integer;
begin
  if FFailed then Exit;
  if FLex.Cur().Kind = tkMinus then
  begin
    ln := FLex.Cur().Line; FLex.Advance(); ParseUnary();
    FProg.Emit(opNeg, 0, 0, ln); FBool := False;
  end
  else if FLex.Cur().Kind = tkPlus then begin FLex.Advance(); ParseUnary(); end
  else ParsePower();
end;

{ An exponent: any number of leading signs, then a primary. Deliberately NOT the
  full unary rule -- see ParsePower. }
procedure TPhosphorCompiler.ParseSignedPrimary;
var ln: Integer;
begin
  if FLex.Cur().Kind = tkMinus then
  begin
    ln := FLex.Cur().Line; FLex.Advance(); ParseSignedPrimary();
    FProg.Emit(opNeg, 0, 0, ln); FBool := False;
  end
  else if FLex.Cur().Kind = tkPlus then begin FLex.Advance(); ParseSignedPrimary(); end
  else ParsePrimary();
end;

procedure TPhosphorCompiler.ParsePower;
var ln: Integer;
begin
  // The BASE is a primary, not a unary: that is what puts '-' OUTSIDE the power, so
  // -2 ^ 2 is -(2 ^ 2) = -4 rather than (-2) ^ 2 = 4.
  //
  // The EXPONENT is a SIGNED PRIMARY, not a full unary. `2 ^ -1` must parse, but
  // recursing all the way back into the unary rule would also make '^' right-
  // associative and quietly turn 2 ^ 3 ^ 2 from 64 into 512. BASIC reads a power
  // chain left to right; this change is about the minus sign and nothing else.
  ParsePrimary();
  while (not FFailed) and (FLex.Cur().Kind = tkCaret) do
  begin
    ln := FLex.Cur().Line; FLex.Advance(); ParseSignedPrimary();
    FProg.Emit(opPow, 0, 0, ln); FBool := False;
  end;
end;

procedure TPhosphorCompiler.ParseMultiplicative;
var k: TTokenKind; ln: Integer;
begin
  ParseUnary();
  while (not FFailed) and (FLex.Cur().Kind in [tkStar, tkSlash, tkBackslash, tkMod]) do
  begin
    k := FLex.Cur().Kind; ln := FLex.Cur().Line; FLex.Advance(); ParseUnary();
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
  ParseMultiplicative();
  while (not FFailed) and (FLex.Cur().Kind in [tkPlus, tkMinus]) do
  begin
    k := FLex.Cur().Kind; ln := FLex.Cur().Line; FLex.Advance(); ParseMultiplicative();
    if k = tkPlus then FProg.Emit(opAdd, 0, 0, ln) else FProg.Emit(opSub, 0, 0, ln);
    FBool := False;
  end;
end;

procedure TPhosphorCompiler.ParseComparison;
var k: TTokenKind; ln: Integer;
begin
  ParseAdditive();
  if (not FFailed) and (FLex.Cur().Kind in [tkEQ, tkNE, tkLT, tkLE, tkGT, tkGE]) then
  begin
    k := FLex.Cur().Kind; ln := FLex.Cur().Line; FLex.Advance(); ParseAdditive();
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
    ln := FLex.Cur().Line; FLex.Advance(); ParseNot();
    FProg.Emit(opNot, 0, 0, ln); FBool := True;
  end
  else ParseComparison();
end;

procedure TPhosphorCompiler.ParseAnd;
var ln: Integer;
begin
  ParseNot();
  while (not FFailed) and IsKeyword('and') do
  begin
    ln := FLex.Cur().Line; FLex.Advance(); ParseNot();
    FProg.Emit(opAnd, 0, 0, ln); FBool := True;
  end;
end;

procedure TPhosphorCompiler.ParseOr;
var ln: Integer;
begin
  ParseAnd();
  while (not FFailed) and IsKeyword('or') do
  begin
    ln := FLex.Cur().Line; FLex.Advance(); ParseAnd();
    FProg.Emit(opOr, 0, 0, ln); FBool := True;
  end;
end;

procedure TPhosphorCompiler.ParseExpr;
begin
  ParseOr();
end;

procedure TPhosphorCompiler.ParseCondition;
var ln: Integer;
begin
  ln := FLex.Cur().Line;
  ParseExpr();
  if (not FFailed) and (not FBool) then
    Fail('a bare value is not a condition; use a comparison or a logical ' +
         'expression (and/or/not)', ln);
end;

// --- statement blocks -------------------------------------------------------
procedure TPhosphorCompiler.ParseBlockUntil(const ATerms: array of String);
begin
  while not FFailed do
  begin
    while FLex.Cur().Kind = tkEOL do FLex.Advance();
    if FLex.Cur().Kind = tkEOF then Exit;
    if CurIsTerm(ATerms) then Exit;
    ParseStatement();
    if FFailed then Exit;
    if (FLex.Cur().Kind = tkEOL) or (FLex.Cur().Kind = tkColon) then FLex.Advance()  // ':' separates statements
    else if (FLex.Cur().Kind <> tkEOF) and not CurIsTerm(ATerms) then
      Fail('expected end of line', FLex.Cur().Line);
  end;
end;

procedure TPhosphorCompiler.ParseIf;
var
  ln, jFalse, jEnd, i: Integer;
  endJumps: array of Integer;
begin
  endJumps := nil;
  ln := FLex.Cur().Line;
  FLex.Advance(); // 'if'
  ParseCondition();
  if FFailed then Exit;
  if not IsKeyword('then') then begin Fail('expected ''then''', FLex.Cur().Line); Exit; end;
  FLex.Advance(); // 'then'
  if (FLex.Cur().Kind = tkEOL) or (FLex.Cur().Kind = tkEOF) then
  begin
    // block IF [ELSEIF ...] [ELSE] ENDIF
    jFalse := FProg.Emit(opJumpIfFalse, 0, 0, ln);
    ParseBlockUntil(['else', 'elseif', 'endif']);
    if FFailed then Exit;
    while IsKeyword('elseif') do
    begin
      FLex.Advance();
      SetLength(endJumps, Length(endJumps) + 1);          // taken branch -> jump to end
      endJumps[High(endJumps)] := FProg.Emit(opJump, 0, 0, ln);
      FProg.Patch(jFalse, FProg.Count);                    // prev cond false lands here
      ParseCondition();
      if FFailed then Exit;
      if not IsKeyword('then') then begin Fail('expected ''then''', FLex.Cur().Line); Exit; end;
      FLex.Advance();
      jFalse := FProg.Emit(opJumpIfFalse, 0, 0, ln);
      ParseBlockUntil(['else', 'elseif', 'endif']);
      if FFailed then Exit;
    end;
    if IsKeyword('else') then
    begin
      FLex.Advance();
      SetLength(endJumps, Length(endJumps) + 1);
      endJumps[High(endJumps)] := FProg.Emit(opJump, 0, 0, ln);
      FProg.Patch(jFalse, FProg.Count);
      ParseBlockUntil(['endif']);
      if FFailed then Exit;
    end
    else
      FProg.Patch(jFalse, FProg.Count);
    if not IsKeyword('endif') then begin Fail('expected ''endif''', FLex.Cur().Line); Exit; end;
    FLex.Advance();
    for i := 0 to High(endJumps) do
      FProg.Patch(endJumps[i], FProg.Count);
  end
  else
  begin
    // inline IF [ELSE]. THE WHOLE REST OF THE LINE is guarded, not just the first
    // statement: `if c then a : b` runs neither when c is false. Parsing one
    // statement left b outside the jump, so it ran every time.
    jFalse := FProg.Emit(opJumpIfFalse, 0, 0, ln);
    ParseInlineStatements();
    if FFailed then Exit;
    if IsKeyword('else') then
    begin
      FLex.Advance();
      jEnd := FProg.Emit(opJump, 0, 0, ln);
      FProg.Patch(jFalse, FProg.Count);
      ParseInlineStatements();
      if not FFailed then FProg.Patch(jEnd, FProg.Count);
    end
    else
      FProg.Patch(jFalse, FProg.Count);
  end;
end;

{ The statements an inline IF (or its ELSE) governs: everything up to the end of
  the line, or up to an ELSE, with ':' between them. }
procedure TPhosphorCompiler.ParseInlineStatements;
begin
  ParseStatement();
  while (not FFailed) and (FLex.Cur().Kind = tkColon) do
  begin
    FLex.Advance();
    if FLex.Cur().Kind in [tkEOL, tkEOF] then Break;
    if IsKeyword('else') then Break;
    ParseStatement();
  end;
end;

procedure TPhosphorCompiler.ParseWhile;
var ln, condStart, jFalse, afterLoop: Integer;
begin
  ln := FLex.Cur().Line;
  FLex.Advance(); // 'while'
  PushLoop();
  condStart := FProg.Count;
  ParseCondition();
  if FFailed then Exit;
  jFalse := FProg.Emit(opJumpIfFalse, 0, 0, ln);
  ParseBlockUntil(['endwhile', 'wend']);   // `wend` is the classic terminator
  if FFailed then Exit;
  FProg.Emit(opJump, condStart, 0, ln);
  afterLoop := FProg.Count;
  FProg.Patch(jFalse, afterLoop);
  PatchBreaks(afterLoop);
  PatchConts(condStart);
  PopLoop();
  if not (IsKeyword('endwhile') or IsKeyword('wend')) then
  begin Fail('expected ''endwhile'' or ''wend''', FLex.Cur().Line); Exit; end;
  FLex.Advance();
end;

procedure TPhosphorCompiler.ParseDo;
var ln, condStart, jFalse, afterLoop: Integer;
begin
  ln := FLex.Cur().Line;
  FLex.Advance(); // 'do'
  if not IsKeyword('while') then begin Fail('only ''do while <cond> ... loop'' is supported', FLex.Cur().Line); Exit; end;
  FLex.Advance(); // 'while'
  PushLoop();
  condStart := FProg.Count;
  ParseCondition();
  if FFailed then Exit;
  jFalse := FProg.Emit(opJumpIfFalse, 0, 0, ln);
  ParseBlockUntil(['loop']);
  if FFailed then Exit;
  FProg.Emit(opJump, condStart, 0, ln);
  afterLoop := FProg.Count;
  FProg.Patch(jFalse, afterLoop);
  PatchBreaks(afterLoop);
  PatchConts(condStart);
  PopLoop();
  if not IsKeyword('loop') then begin Fail('expected ''loop''', FLex.Cur().Line); Exit; end;
  FLex.Advance();
end;

procedure TPhosphorCompiler.ParseRepeat;
var ln, bodyStart, contTarget, afterLoop: Integer;
begin
  ln := FLex.Cur().Line;
  FLex.Advance(); // 'repeat'
  PushLoop();
  bodyStart := FProg.Count;
  ParseBlockUntil(['until']);
  if FFailed then Exit;
  contTarget := FProg.Count;   // continue re-checks the until condition
  if not IsKeyword('until') then begin Fail('expected ''until''', FLex.Cur().Line); Exit; end;
  FLex.Advance();
  ParseCondition();
  if FFailed then Exit;
  FProg.Emit(opJumpIfFalse, bodyStart, 0, ln);  // loop back while condition is false
  afterLoop := FProg.Count;
  PatchBreaks(afterLoop);
  PatchConts(contTarget);
  PopLoop();
end;

procedure TPhosphorCompiler.ParseFor;
var
  ln, endVar, condStart, jFalse, incPoint, afterLoop: Integer;
  step: TValue;
  down: Boolean;
  neg: Boolean;
  endIsLocal: Boolean;
  vname, endName: String;
begin
  ln := FLex.Cur().Line;
  FLex.Advance(); // 'for'
  if FLex.Cur().Kind <> tkIdent then begin Fail('expected a loop variable after ''for''', FLex.Cur().Line); Exit; end;
  vname := FLex.Cur().StrVal;   // resolved through the scope (local inside a function, else global)
  FLex.Advance();
  Expect(tkEQ, '''=''');
  if FFailed then Exit;
  ParseExpr();                                    // start value
  EmitStoreVar(vname, ln);
  if not IsKeyword('to') then begin Fail('expected ''to''', FLex.Cur().Line); Exit; end;
  FLex.Advance();
  // The bound lives where the loop lives: a LOCAL slot inside a function, so a
  // recursive call gets its own, and a hidden global at top level, where nothing
  // can re-enter to overwrite it. See the note above this procedure.
  endIsLocal := FInFunction;
  if endIsLocal then
  begin
    endName := '__for' + IntToStr(FHidden);
    Inc(FHidden);
    AddLocal(endName);
    endVar := LocalIndex(endName);
  end
  else
    endVar := NewHiddenVar(vtNumber);
  ParseExpr();                                     // end value
  if endIsLocal then FProg.Emit(opStoreLocal, endVar, 0, ln)
  else FProg.Emit(opStoreVar, endVar, 0, ln);

  // STEP: optional numeric literal (possibly negative); default +1
  step := ValInt(1);
  down := False;
  if IsKeyword('step') then
  begin
    FLex.Advance();
    neg := False;
    if FLex.Cur().Kind = tkMinus then begin neg := True; FLex.Advance(); end
    else if FLex.Cur().Kind = tkPlus then FLex.Advance();
    if FLex.Cur().Kind = tkInt then
    begin
      if neg then step := ValInt(-FLex.Cur().IntVal) else step := ValInt(FLex.Cur().IntVal);
      FLex.Advance();
    end
    else if FLex.Cur().Kind = tkDouble then
    begin
      if neg then step := ValDouble(-FLex.Cur().DblVal) else step := ValDouble(FLex.Cur().DblVal);
      FLex.Advance();
    end
    else begin Fail('for step must be a numeric literal', FLex.Cur().Line); Exit; end;
    down := AsDouble(step) < 0;
  end;

  PushLoop();
  condStart := FProg.Count;
  EmitLoadVar(vname, ln);
  if endIsLocal then FProg.Emit(opLoadLocal, endVar, 0, ln)
  else FProg.Emit(opLoadVar, endVar, 0, ln);
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
  PopLoop();
  if not IsKeyword('next') then begin Fail('expected ''next''', FLex.Cur().Line); Exit; end;
  FLex.Advance();
end;

procedure TPhosphorCompiler.ParseSelect;
var
  ln, selVar, jNext, endTarget, i: Integer;
  endFixups: array of Integer;
begin
  ln := FLex.Cur().Line;
  FLex.Advance(); // 'select'
  if not IsKeyword('case') then begin Fail('expected ''case'' after ''select''', FLex.Cur().Line); Exit; end;
  FLex.Advance(); // 'case'
  selVar := NewHiddenVar(vtAny);
  ParseExpr();                                 // the subject
  FProg.Emit(opStoreVar, selVar, 0, ln);
  endFixups := nil;

  while not FFailed do
  begin
    while FLex.Cur().Kind = tkEOL do FLex.Advance();
    if IsKeyword('endselect') then Break;
    if not IsKeyword('case') then begin Fail('expected ''case'' or ''endselect''', FLex.Cur().Line); Exit; end;
    FLex.Advance(); // 'case'
    if IsKeyword('else') then
    begin
      FLex.Advance();
      ParseBlockUntil(['endselect']);
      Break;
    end;
    // case <value>
    FProg.Emit(opLoadVar, selVar, 0, ln);
    ParseExpr();
    FProg.Emit(opEQ, 0, 0, ln);
    jNext := FProg.Emit(opJumpIfFalse, 0, 0, ln);
    ParseBlockUntil(['case', 'endselect']);
    if FFailed then Exit;
    SetLength(endFixups, Length(endFixups) + 1);
    endFixups[High(endFixups)] := FProg.Emit(opJump, 0, 0, ln);
    FProg.Patch(jNext, FProg.Count);
  end;
  if FFailed then Exit;
  if not IsKeyword('endselect') then begin Fail('expected ''endselect''', FLex.Cur().Line); Exit; end;
  FLex.Advance();
  endTarget := FProg.Count;
  for i := 0 to High(endFixups) do
    FProg.Patch(endFixups[i], endTarget);
end;

{ trace <expr> -- turn tracing on (a non-zero value) or off (0). The value is any
  expression; the VM sets its trace flag from it (opTrace pops one value). }
procedure TPhosphorCompiler.ParseTrace;
var ln: Integer;
begin
  ln := FLex.Cur().Line;
  FLex.Advance();   // 'trace'
  if (FLex.Cur().Kind = tkEOL) or (FLex.Cur().Kind = tkEOF) or (FLex.Cur().Kind = tkColon) then
  begin Fail('''trace'' needs a value (0 turns tracing off)', ln); Exit; end;
  ParseExpr();
  if FFailed then Exit;
  FProg.Emit(opTrace, 0, 0, ln);
end;

{ breakpoint <msg-expr> [, <expr>]* -- a debug breakpoint carrying a message and
  zero or more operand VALUES. The message is pushed first, then each operand
  expression (its value, not a reference), and opBreakpoint(N) records the operand
  count. At run time it pops them all and continues: with tracing off it is a pure
  no-op, and with tracing on but no host confirm-callback (a headless host) it
  reports the frame and carries on. It never parks the VM. Because operands are
  passed by value, the source variables are left untouched. }
procedure TPhosphorCompiler.ParseBreakpoint;
var ln, nops: Integer;
begin
  ln := FLex.Cur().Line;
  FLex.Advance();   // 'breakpoint'
  if (FLex.Cur().Kind = tkEOL) or (FLex.Cur().Kind = tkEOF) or (FLex.Cur().Kind = tkColon) then
  begin Fail('''breakpoint'' needs a message', ln); Exit; end;
  ParseExpr();      // the message
  if FFailed then Exit;
  nops := 0;
  while (not FFailed) and (FLex.Cur().Kind = tkComma) do
  begin
    FLex.Advance();
    ParseExpr();    // an operand: its value is pushed
    Inc(nops);
  end;
  if FFailed then Exit;
  FProg.Emit(opBreakpoint, nops, 0, ln);
end;

{ The type code an INPUT field is coerced to: 0 number, 1 string, 2 int, 3 bool;
  -1 for a handle (which INPUT cannot fill). Read from the name suffix. }
function TPhosphorCompiler.InputTypeCode(const AName: String): Integer;
begin
  case VarTypeOf(AName) of
    vtString: Result := 1;
    vtInt:    Result := 2;
    vtBool:   Result := 3;
    vtHandle: Result := -1;
  else
    Result := 0;   // vtNumber
  end;
end;

{ INPUT / LINE INPUT, from the console or from a #file. Console INPUT prompts with
  "? " (a leading string prompt with ';' keeps it, ',' drops it); LINE INPUT does
  not prompt. File forms (`input #f, ...`) read the channel's buffer. }
procedure TPhosphorCompiler.ParseInput(AIsLine: Boolean);
var
  ln, chTmp, tc: Integer;
  vname: String;
  isFile, hasPrompt: Boolean;
begin
  ln := FLex.Cur().Line;
  FLex.Advance();   // past 'input'
  isFile := FLex.Cur().Kind = tkHash;
  if isFile then
  begin
    FLex.Advance();                       // '#'
    ParseExpr();                          // the file number
    if FFailed then Exit;
    chTmp := NewHiddenVar(vtNumber);
    FProg.Emit(opStoreVar, chTmp, 0, ln);
    Expect(tkComma, '","');
    if FFailed then Exit;
  end
  else
  begin
    chTmp := 0;
    hasPrompt := (FLex.Cur().Kind = tkString) and (FLex.Peek().Kind in [tkSemicolon, tkComma]);
    if hasPrompt then
    begin
      FProg.Emit(opPushConst, FProg.Consts.Add(ValStr(FLex.Cur().StrVal)), 0, ln);
      FProg.Emit(opPrint, 0, 0, ln);
      FLex.Advance();                     // the prompt string
      // A ';' after the prompt adds the "? " of a classic INPUT; LINE INPUT never
      // adds it. Either way ',' suppresses it.
      if (FLex.Cur().Kind = tkSemicolon) and (not AIsLine) then
      begin
        FProg.Emit(opPushConst, FProg.Consts.Add(ValStr('? ')), 0, ln);
        FProg.Emit(opPrint, 0, 0, ln);
      end;
      FLex.Advance();                     // the ';' or ','
    end
    else if not AIsLine then
    begin
      FProg.Emit(opPushConst, FProg.Consts.Add(ValStr('? ')), 0, ln);
      FProg.Emit(opPrint, 0, 0, ln);
    end;
    FProg.Emit(opInputLine, 0, 0, ln);
  end;

  repeat
    if FLex.Cur().Kind <> tkIdent then begin Fail('INPUT needs a variable', FLex.Cur().Line); Exit; end;
    vname := FLex.Cur().StrVal;
    tc := InputTypeCode(vname);
    if tc < 0 then begin Fail('cannot INPUT into a handle variable', FLex.Cur().Line); Exit; end;
    if AIsLine and (VarTypeOf(vname) <> vtString) then
    begin Fail('LINE INPUT needs a string ($) variable', FLex.Cur().Line); Exit; end;
    FLex.Advance();
    if isFile then
    begin
      FProg.Emit(opLoadVar, chTmp, 0, ln);
      if AIsLine then FProg.Emit(opFileLine, 0, 0, ln)
      else FProg.Emit(opFileField, tc, 0, ln);
    end
    else
    begin
      if AIsLine then FProg.Emit(opInputAll, 0, 0, ln)
      else FProg.Emit(opInputField, tc, 0, ln);
    end;
    EmitStoreVar(vname, ln);
    if FFailed then Exit;
    if AIsLine then Break;              // LINE INPUT fills exactly one variable
    if FLex.Cur().Kind = tkComma then FLex.Advance() else Break;
  until FFailed;
end;

{ OPEN <path> FOR input|output|append AS #n -- opens a classic file channel. }
procedure TPhosphorCompiler.ParseOpen;
var ln, modeCode: Integer; modeStr: String;
begin
  ln := FLex.Cur().Line;
  FLex.Advance();   // 'open'
  ParseExpr();      // the path (pushed first)
  if FFailed then Exit;
  if not ((FLex.Cur().Kind = tkIdent) and (FLex.Cur().StrVal = 'for')) then
  begin Fail('OPEN needs ''for''', FLex.Cur().Line); Exit; end;
  FLex.Advance();
  if FLex.Cur().Kind <> tkIdent then begin Fail('OPEN mode must be input, output, append or binary', FLex.Cur().Line); Exit; end;
  modeStr := FLex.Cur().StrVal;
  if modeStr = 'input' then modeCode := 0
  else if modeStr = 'output' then modeCode := 1
  else if modeStr = 'append' then modeCode := 2
  else if modeStr = 'binary' then modeCode := 3   // read/write, positionable
  else begin Fail('OPEN mode must be input, output, append or binary', FLex.Cur().Line); Exit; end;
  FLex.Advance();   // the mode
  if not ((FLex.Cur().Kind = tkIdent) and (FLex.Cur().StrVal = 'as')) then
  begin Fail('OPEN needs ''as''', FLex.Cur().Line); Exit; end;
  FLex.Advance();
  if FLex.Cur().Kind = tkHash then FLex.Advance();   // optional '#'
  ParseExpr();      // the file number (pushed second) -> [path, chan]
  if FFailed then Exit;
  FProg.Emit(opOpenFile, modeCode, 0, ln);
end;

{ CLOSE [#n [, #n]...] -- closes the named channels; bare CLOSE closes them all. }
procedure TPhosphorCompiler.ParseClose;
var ln: Integer;
begin
  ln := FLex.Cur().Line;
  FLex.Advance();   // 'close'
  if FLex.Cur().Kind in [tkEOL, tkEOF, tkColon] then
  begin FProg.Emit(opCloseFile, 1, 0, ln); Exit; end;   // close every channel
  repeat
    if FLex.Cur().Kind = tkHash then FLex.Advance();
    ParseExpr();
    if FFailed then Exit;
    FProg.Emit(opCloseFile, 0, 0, ln);
    if FLex.Cur().Kind = tkComma then FLex.Advance() else Break;
  until FFailed;
end;

{ SEEK #n, p -- move a channel's read/write cursor to the 1-based byte position p.
  Pairs with loc(n), which reports it, so `seek #n, loc(n)` changes nothing. }
procedure TPhosphorCompiler.ParseSeek;
var ln: Integer;
begin
  ln := FLex.Cur().Line;
  FLex.Advance();   // 'seek'
  if FLex.Cur().Kind = tkHash then FLex.Advance();   // optional '#'
  ParseExpr();      // the file number (pushed first)
  if FFailed then Exit;
  Expect(tkComma, '","');
  if FFailed then Exit;
  ParseExpr();      // the position (pushed second)
  if FFailed then Exit;
  FProg.Emit(opSeekFile, 0, 0, ln);
end;

{ PRINT #n [, item[(;|,) item]...] -- writes items to a file channel (';' adjacent,
  ',' a tab). PRINTLN #n adds a trailing newline; PRINT #n does not. }
procedure TPhosphorCompiler.ParsePrintFile(AAddNewline: Boolean);
var ln, chTmp: Integer;
begin
  ln := FLex.Cur().Line;   // Cur = '#'
  FLex.Advance();          // '#'
  ParseExpr();             // the file number
  if FFailed then Exit;
  chTmp := NewHiddenVar(vtNumber);
  FProg.Emit(opStoreVar, chTmp, 0, ln);
  if FLex.Cur().Kind = tkComma then FLex.Advance();   // the comma after #n
  while (not FFailed) and not (FLex.Cur().Kind in [tkEOL, tkEOF, tkColon]) do
  begin
    FProg.Emit(opLoadVar, chTmp, 0, ln);
    ParseExpr();
    if FFailed then Exit;
    FProg.Emit(opPrintFile, 0, 0, ln);
    if FLex.Cur().Kind = tkComma then
    begin
      FProg.Emit(opLoadVar, chTmp, 0, ln);
      FProg.Emit(opPushConst, FProg.Consts.Add(ValStr(#9)), 0, ln);
      FProg.Emit(opPrintFile, 0, 0, ln);
      FLex.Advance();
    end
    else if FLex.Cur().Kind = tkSemicolon then
      FLex.Advance()
    else
      Break;
  end;
  if AAddNewline then
  begin
    FProg.Emit(opLoadVar, chTmp, 0, ln);
    FProg.Emit(opPushConst, FProg.Consts.Add(ValStr(#10)), 0, ln);
    FProg.Emit(opPrintFile, 0, 0, ln);
  end;
end;

{ PRINT USING fmt$; a[; b...] -- emits the values through the format string. }
procedure TPhosphorCompiler.ParsePrintUsing(AAddNewline: Boolean);
var ln, argc: Integer;
begin
  ln := FLex.Cur().Line;
  ParseExpr();      // the format string (pushed first)
  if FFailed then Exit;
  if FLex.Cur().Kind in [tkSemicolon, tkComma] then FLex.Advance()
  else begin Fail('PRINT USING needs '';'' after the format', FLex.Cur().Line); Exit; end;
  argc := 0;
  if not (FLex.Cur().Kind in [tkEOL, tkEOF, tkColon]) then
  begin
    ParseExpr(); Inc(argc);
    while (not FFailed) and (FLex.Cur().Kind in [tkSemicolon, tkComma]) do
    begin
      FLex.Advance();
      if FLex.Cur().Kind in [tkEOL, tkEOF, tkColon] then Break;
      ParseExpr(); Inc(argc);
    end;
  end;
  if FFailed then Exit;
  FProg.Emit(opPrintUsing, argc, 0, ln);
  if AAddNewline then
  begin
    FProg.Emit(opPushConst, FProg.Consts.Add(ValStr('')), 0, ln);
    FProg.Emit(opPrintLn, 0, 0, ln);
  end;
end;

{ SWAP support. A target is a scalar variable or an @-array element. The two are
  read into hidden temporaries first, then cross-written, so aliasing is safe and
  the exchange is atomic in effect. Index expressions are re-parsed (via the lexer
  marks) for the read and the write; keep them side-effect free. }
procedure TPhosphorCompiler.SkipTarget;
var depth: Integer;
begin
  if FLex.Cur().Kind <> tkIdent then begin Fail('SWAP needs a variable', FLex.Cur().Line); Exit; end;
  FLex.Advance();   // the name
  if FLex.Cur().Kind = tkLBracket then
  begin
    depth := 0;
    repeat
      if FLex.Cur().Kind = tkLBracket then Inc(depth)
      else if FLex.Cur().Kind = tkRBracket then Dec(depth);
      if FLex.Cur().Kind in [tkEOL, tkEOF] then begin Fail('unterminated index in SWAP', FLex.Cur().Line); Exit; end;
      FLex.Advance();
    until depth = 0;
  end;
end;

procedure TPhosphorCompiler.EmitReadTarget(APos: Integer);
var name: String; ln, nidx: Integer;
begin
  FLex.Reset(APos);
  name := FLex.Cur().StrVal;
  ln := FLex.Cur().Line;
  if FLex.Peek().Kind = tkLBracket then
  begin
    if VarTypeOf(name) <> vtHandle then begin Fail('SWAP can index only a handle (@) variable', ln); Exit; end;
    EmitLoadVar(name, ln);      // the handle
    FLex.Advance(); FLex.Advance(); // the name, '['
    ParseExpr(); nidx := 1;
    while (not FFailed) and (FLex.Cur().Kind = tkComma) do
    begin FLex.Advance(); ParseExpr(); Inc(nidx); end;
    Expect(tkRBracket, ''']''');
    FProg.Emit(opCall, FProg.Consts.Add(ValStr('arr_get')), 1 + nidx, ln);
  end
  else
  begin
    EmitLoadVar(name, ln);
    FLex.Advance();               // the name
  end;
end;

procedure TPhosphorCompiler.EmitWriteTarget(APos, ATempVar: Integer);
var name: String; ln, nidx: Integer;
begin
  FLex.Reset(APos);
  name := FLex.Cur().StrVal;
  ln := FLex.Cur().Line;
  if FLex.Peek().Kind = tkLBracket then
  begin
    if VarTypeOf(name) <> vtHandle then begin Fail('SWAP can index only a handle (@) variable', ln); Exit; end;
    EmitLoadVar(name, ln);      // the handle
    FLex.Advance(); FLex.Advance(); // the name, '['
    ParseExpr(); nidx := 1;
    while (not FFailed) and (FLex.Cur().Kind = tkComma) do
    begin FLex.Advance(); ParseExpr(); Inc(nidx); end;
    Expect(tkRBracket, ''']''');
    FProg.Emit(opLoadVar, ATempVar, 0, ln);   // the value to store
    FProg.Emit(opCall, FProg.Consts.Add(ValStr('arr_set')), 1 + nidx + 1, ln);
    FProg.Emit(opPop, 0, 0, ln);              // discard arr_set's returned handle
  end
  else
  begin
    FProg.Emit(opLoadVar, ATempVar, 0, ln);
    FLex.Advance();               // the name
    EmitStoreVar(name, ln);
  end;
end;

procedure TPhosphorCompiler.ParseSwap;
var m1, m2, mEnd, t1, t2: Integer;
begin
  FLex.Advance();   // 'swap'
  m1 := FLex.Mark();
  SkipTarget();
  if FFailed then Exit;
  Expect(tkComma, '","');
  if FFailed then Exit;
  m2 := FLex.Mark();
  SkipTarget();
  if FFailed then Exit;
  mEnd := FLex.Mark();
  t1 := NewHiddenVar(vtAny);
  t2 := NewHiddenVar(vtAny);
  EmitReadTarget(m1);  if FFailed then Exit;
  FProg.Emit(opStoreVar, t1, 0, FLex.Cur().Line);
  EmitReadTarget(m2);  if FFailed then Exit;
  FProg.Emit(opStoreVar, t2, 0, FLex.Cur().Line);
  EmitWriteTarget(m1, t2);  if FFailed then Exit;
  EmitWriteTarget(m2, t1);  if FFailed then Exit;
  FLex.Reset(mEnd);
end;

procedure TPhosphorCompiler.ParseStatement;
var
  t: TToken;
  i: Integer;
  cname: String;
  cval: TValue;
  neg: Boolean;
  k: TTokenKind;
  nidx: Integer;
begin
  // Mark the statement boundary so a caught error can resume from a clean point.
  FProg.Emit(opStmt, 0, 0, FLex.Cur().Line);
  t := FLex.Cur();
  if t.Kind = tkIdent then
  begin
    if t.StrVal = 'function' then begin ParseFunction(); Exit; end;
    if t.StrVal = 'if' then begin ParseIf(); Exit; end;
    if t.StrVal = 'while' then begin ParseWhile(); Exit; end;
    if t.StrVal = 'do' then begin ParseDo(); Exit; end;
    if t.StrVal = 'repeat' then begin ParseRepeat(); Exit; end;
    if t.StrVal = 'for' then begin ParseFor(); Exit; end;
    if t.StrVal = 'select' then begin ParseSelect(); Exit; end;
    if t.StrVal = 'trace' then begin ParseTrace(); Exit; end;
    if t.StrVal = 'breakpoint' then begin ParseBreakpoint(); Exit; end;
    if t.StrVal = 'break' then
    begin
      FLex.Advance();
      if FLoopDepth = 0 then Fail('''break'' outside a loop', t.Line)
      else AddBreak(FProg.Emit(opJump, 0, 0, t.Line));
      Exit;
    end;
    if t.StrVal = 'continue' then
    begin
      FLex.Advance();
      if FLoopDepth = 0 then Fail('''continue'' outside a loop', t.Line)
      else AddCont(FProg.Emit(opJump, 0, 0, t.Line));
      Exit;
    end;
    // `on error goto ...` installs a runtime-error handler (a distinct form of
    // the contextual `on`; `error` here is the keyword, not a variable).
    if (t.StrVal = 'on') and (FLex.Peek().Kind = tkIdent) and (FLex.Peek().StrVal = 'error') then
    begin
      ParseOnError();
      Exit;
    end;
    // `on <expr> goto/gosub ...` -- but `on` is contextual: `on = 5` is still a
    // variable, so only a non-assignment follower opens the computed jump.
    if (t.StrVal = 'on') and
       not (FLex.Peek().Kind in [tkEQ, tkPlusEq, tkMinusEq, tkStarEq, tkSlashEq, tkLBracket]) then
    begin
      ParseOnGoto();
      Exit;
    end;
    // `resume` / `resume next` -- continue from a caught error; contextual, so
    // `resume = 5` stays a variable assignment.
    if (t.StrVal = 'resume') and
       not (FLex.Peek().Kind in [tkEQ, tkPlusEq, tkMinusEq, tkStarEq, tkSlashEq, tkLBracket]) then
    begin
      FLex.Advance();
      if (FLex.Cur().Kind = tkIdent) and (FLex.Cur().StrVal = 'next') then
        begin FLex.Advance(); FProg.Emit(opResume, 1, 0, t.Line); end
      else
        FProg.Emit(opResume, 0, 0, t.Line);
      Exit;
    end;
    if t.StrVal = 'goto' then
    begin
      FLex.Advance();
      if FLex.Cur().Kind = tkInt then
        begin i := FProg.Emit(opJump, 0, 0, t.Line); AddGoto(i, IntToStr(FLex.Cur().IntVal)); FLex.Advance(); end
      else if FLex.Cur().Kind = tkIdent then
        begin i := FProg.Emit(opJump, 0, 0, t.Line); AddGoto(i, FLex.Cur().StrVal); FLex.Advance(); end
      else Fail('''goto'' needs a line number or a label', FLex.Cur().Line);
      Exit;
    end;
    if t.StrVal = 'gosub' then
    begin
      FLex.Advance();
      if FLex.Cur().Kind = tkInt then
        begin i := FProg.Emit(opGosub, 0, 0, t.Line); AddGoto(i, IntToStr(FLex.Cur().IntVal)); FLex.Advance(); end
      else if FLex.Cur().Kind = tkIdent then
        begin i := FProg.Emit(opGosub, 0, 0, t.Line); AddGoto(i, FLex.Cur().StrVal); FLex.Advance(); end
      else Fail('''gosub'' needs a line number or a label', FLex.Cur().Line);
      Exit;
    end;
    if t.StrVal = 'return' then
    begin
      FLex.Advance();
      if FInFunction then
      begin
        // a function return carries a value (default of the return type if bare:
        // at end of line, before a ':' separator, or at end of input)
        if (FLex.Cur().Kind = tkEOL) or (FLex.Cur().Kind = tkEOF) or (FLex.Cur().Kind = tkColon) then
          FProg.Emit(opPushConst, FProg.Consts.Add(DefaultValue(FRetType)), 0, t.Line)
        else
          ParseExpr();
        FProg.Emit(opRetFunc, 0, 0, t.Line);
      end
      else
        FProg.Emit(opReturn, 0, 0, t.Line);   // GOSUB return
      Exit;
    end;
    if t.StrVal = 'end' then begin FLex.Advance(); FProg.Emit(opHalt, 0, 0, t.Line); Exit; end;
    if t.StrVal = 'data' then
    begin
      FLex.Advance();
      while not FFailed do
      begin
        // one DATA constant: optional sign, then a number or a string
        if FLex.Cur().Kind = tkMinus then
        begin
          FLex.Advance();
          if FLex.Cur().Kind = tkInt then FProg.AddData(ValInt(-FLex.Cur().IntVal))
          else if FLex.Cur().Kind = tkDouble then FProg.AddData(ValDouble(-FLex.Cur().DblVal))
          else begin Fail('DATA expects a number after ''-''', FLex.Cur().Line); Exit; end;
          FLex.Advance();
        end
        else
        begin
          if FLex.Cur().Kind = tkPlus then FLex.Advance();
          case FLex.Cur().Kind of
            tkInt:    begin FProg.AddData(ValInt(FLex.Cur().IntVal)); FLex.Advance(); end;
            tkDouble: begin FProg.AddData(ValDouble(FLex.Cur().DblVal)); FLex.Advance(); end;
            tkString: begin FProg.AddData(ValStr(FLex.Cur().StrVal)); FLex.Advance(); end;
          else
            Fail('DATA item must be a number or a string', FLex.Cur().Line); Exit;
          end;
        end;
        if FLex.Cur().Kind = tkComma then FLex.Advance() else Break;
      end;
      Exit;
    end;
    if t.StrVal = 'read' then
    begin
      FLex.Advance();
      while not FFailed do
      begin
        if FLex.Cur().Kind <> tkIdent then begin Fail('READ needs a variable', FLex.Cur().Line); Exit; end;
        t := FLex.Cur();
        FLex.Advance();
        FProg.Emit(opReadData, 0, 0, t.Line);
        EmitStoreVar(t.StrVal, t.Line);
        if FLex.Cur().Kind = tkComma then FLex.Advance() else Break;
      end;
      Exit;
    end;
    if t.StrVal = 'restore' then begin FLex.Advance(); FProg.Emit(opRestore, 0, 0, t.Line); Exit; end;
    // Classic console/file INPUT. `input` is contextual: a statement only when a
    // variable, string prompt or '#' follows (so `input = 5` stays an assignment).
    if (t.StrVal = 'input') and (FLex.Peek().Kind in [tkIdent, tkString, tkHash]) then
    begin ParseInput(False); Exit; end;
    // `line input ...` -- the two-word form; `line` alone stays an ordinary name.
    if (t.StrVal = 'line') and (FLex.Peek().Kind = tkIdent) and (FLex.Peek().StrVal = 'input') then
    begin FLex.Advance(); ParseInput(True); Exit; end;
    // `open <path> for input|output|append as #n` -- contextual like `on`.
    if (t.StrVal = 'open') and
       not (FLex.Peek().Kind in [tkEQ, tkPlusEq, tkMinusEq, tkStarEq, tkSlashEq, tkLBracket, tkEOL, tkEOF, tkColon]) then
    begin ParseOpen(); Exit; end;
    // `close [#n[, #n]...]` or bare `close` (every channel).
    if (t.StrVal = 'close') and
       not (FLex.Peek().Kind in [tkEQ, tkPlusEq, tkMinusEq, tkStarEq, tkSlashEq, tkLBracket]) then
    begin ParseClose(); Exit; end;
    // `seek #n, p` -- move a channel cursor; contextual, so `seek = 5` is a variable.
    if (t.StrVal = 'seek') and (FLex.Peek().Kind in [tkHash, tkInt, tkIdent, tkLParen]) then
    begin ParseSeek(); Exit; end;
    // `swap <var>, <var>` (scalars or @-array elements).
    if (t.StrVal = 'swap') and
       not (FLex.Peek().Kind in [tkEQ, tkPlusEq, tkMinusEq, tkStarEq, tkSlashEq, tkLBracket]) then
    begin ParseSwap(); Exit; end;
    // indexed handle: a@[i,...] = <expr> (set), a@[i,...] op= <expr> (compound),
    // or a@[i,...] alone (expression stmt). N comma-separated indices are allowed.
    if (VarTypeOf(t.StrVal) = vtHandle) and (FLex.Peek().Kind = tkLBracket) then
    begin
      EmitLoadVar(t.StrVal, t.Line);   // the handle
      FLex.Advance();                    // the name
      FLex.Advance();                    // '['
      ParseExpr();                       // the first index
      nidx := 1;
      while (not FFailed) and (FLex.Cur().Kind = tkComma) do
      begin
        FLex.Advance();
        ParseExpr();                     // a further index
        Inc(nidx);
      end;
      Expect(tkRBracket, ''']''');
      if FFailed then Exit;
      if FLex.Cur().Kind = tkEQ then
      begin
        FLex.Advance();
        ParseExpr();                     // the value
        FProg.Emit(opCall, FProg.Consts.Add(ValStr('arr_set')), 1 + nidx + 1, t.Line);
      end
      else if FLex.Cur().Kind in [tkPlusEq, tkMinusEq, tkStarEq, tkSlashEq] then
      begin
        // a@[i,...] op= x  ==  a@[i,...] = a@[i,...] op x, indices evaluated once.
        // opDupN copies the handle and all N indices so arr_get (read) and arr_set
        // (write) both see them without re-emitting the index expressions.
        k := FLex.Cur().Kind;
        FLex.Advance();
        FProg.Emit(opDupN, 1 + nidx, 0, t.Line);                                     // [h,i..,h,i..]
        FProg.Emit(opCall, FProg.Consts.Add(ValStr('arr_get')), 1 + nidx, t.Line);   // [h,i..,elem]
        ParseExpr();                                                                    // [h,i..,elem,rhs]
        FProg.Emit(CompoundOp(k), 0, 0, t.Line);                                     // [h,i..,newval]
        FProg.Emit(opCall, FProg.Consts.Add(ValStr('arr_set')), 1 + nidx + 1, t.Line);
      end
      else
        FProg.Emit(opCall, FProg.Consts.Add(ValStr('arr_get')), 1 + nidx, t.Line);
      FProg.Emit(opPop, 0, 0, t.Line);  // statement: discard the call result
      Exit;
    end;
    if (t.StrVal = 'print') or (t.StrVal = 'println') then
    begin
      FLex.Advance();
      // `print #n, ...` writes to a file channel; `print using fmt$; ...` formats.
      if FLex.Cur().Kind = tkHash then
      begin ParsePrintFile(t.StrVal = 'println'); Exit; end;
      if (FLex.Cur().Kind = tkIdent) and (FLex.Cur().StrVal = 'using') then
      begin FLex.Advance(); ParsePrintUsing(t.StrVal = 'println'); Exit; end;
      // Items separated by `;` (adjacent, no separator) or `,` (a tab to the
      // next zone). PRINTLN adds a trailing newline, PRINT does not.
      if (FLex.Cur().Kind <> tkEOL) and (FLex.Cur().Kind <> tkEOF) then
      begin
        ParseExpr();
        FProg.Emit(opPrint, 0, 0, t.Line);
        while (not FFailed) and ((FLex.Cur().Kind = tkSemicolon) or (FLex.Cur().Kind = tkComma)) do
        begin
          if FLex.Cur().Kind = tkComma then
          begin
            FProg.Emit(opPushConst, FProg.Consts.Add(ValStr(#9)), 0, t.Line);
            FProg.Emit(opPrint, 0, 0, t.Line);
          end;
          FLex.Advance();
          if (FLex.Cur().Kind = tkEOL) or (FLex.Cur().Kind = tkEOF) then Break;
          ParseExpr();
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
    if (t.StrVal = 'const') and (FLex.Peek().Kind = tkIdent) then
    begin
      FLex.Advance();
      cname := FLex.Cur().StrVal;
      FLex.Advance();
      Expect(tkEQ, '''=''');
      if FFailed then Exit;
      neg := False;
      if FLex.Cur().Kind = tkMinus then begin neg := True; FLex.Advance(); end
      else if FLex.Cur().Kind = tkPlus then FLex.Advance();
      case FLex.Cur().Kind of
        tkInt:    if neg then cval := ValInt(-FLex.Cur().IntVal) else cval := ValInt(FLex.Cur().IntVal);
        tkDouble: if neg then cval := ValDouble(-FLex.Cur().DblVal) else cval := ValDouble(FLex.Cur().DblVal);
        tkString: cval := ValStr(FLex.Cur().StrVal);
      else
        Fail('const value must be a number or a string literal', FLex.Cur().Line); Exit;
      end;
      FLex.Advance();
      // The value is a single literal, not an expression: anything other than
      // the end of the statement here (e.g. `const N = 2 + 3`) is rejected for
      // its own reason rather than a bare "expected end of line".
      if not (FLex.Cur().Kind in [tkEOL, tkEOF, tkColon]) then
      begin
        Fail('const value must be a single number or string literal, not an expression', FLex.Cur().Line); Exit;
      end;
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
      FLex.Advance();
      if FLex.Cur().Kind <> tkIdent then begin Fail('expected a variable name after ''let''', FLex.Cur().Line); Exit; end;
      t := FLex.Cur();
      FLex.Advance();
      if FLex.Cur().Kind = tkEQ then
      begin
        FLex.Advance();
        ParseExpr();
        if not FFailed then EmitStoreVar(t.StrVal, t.Line);
      end
      else
      begin
        // let <var>[, <var>...] -- declare only; the VM default-initializes them
        VarIndex(t.StrVal);
        while (not FFailed) and (FLex.Cur().Kind = tkComma) do
        begin
          FLex.Advance();
          if FLex.Cur().Kind <> tkIdent then begin Fail('expected a variable name', FLex.Cur().Line); Exit; end;
          VarIndex(FLex.Cur().StrVal);
          FLex.Advance();
        end;
        // `let a, b` declares names only; a value at the end (`let a, b = 5`) is
        // ambiguous (which name gets it?) and rejected for its own reason.
        if (not FFailed) and (FLex.Cur().Kind = tkEQ) then
        begin
          Fail('a ''let'' list declares names only; assign to one name at a time', t.Line); Exit;
        end;
      end;
      Exit;
    end;
    if (t.StrVal <> 'true') and (t.StrVal <> 'false') and (FLex.Peek().Kind = tkEQ) then
    begin
      FLex.Advance();  // name
      FLex.Advance();  // '='
      ParseExpr();
      if not FFailed then EmitStoreVar(t.StrVal, t.Line);
      Exit;
    end;
    // compound assignment: <var> op= <expr>  ==  <var> = <var> op <expr>
    if (t.StrVal <> 'true') and (t.StrVal <> 'false') and
       (FLex.Peek().Kind in [tkPlusEq, tkMinusEq, tkStarEq, tkSlashEq]) then
    begin
      k := FLex.Peek().Kind;
      FLex.Advance();  // name
      FLex.Advance();  // compound op
      EmitLoadVar(t.StrVal, t.Line);
      ParseExpr();
      if not FFailed then
      begin
        FProg.Emit(CompoundOp(k), 0, 0, t.Line);
        EmitStoreVar(t.StrVal, t.Line);
      end;
      Exit;
    end;
  end;
  // expression statement
  ParseExpr();
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
  FProg := TProgram.Create();
  FLex := TLexer.Create(ASource);
  try
    if not FLex.Ok() then Fail(FLex.ErrorMessage, FLex.ErrorLine);
    while (not FFailed) and (FLex.Cur().Kind <> tkEOF) do
    begin
      if FLex.Cur().Kind = tkEOL then begin FLex.Advance(); Continue; end;
      // a leading line number is a label
      if FLex.Cur().Kind = tkInt then
      begin
        RecordLabel(IntToStr(FLex.Cur().IntVal), FProg.Count);
        FLex.Advance();
        if (FLex.Cur().Kind = tkEOL) or (FLex.Cur().Kind = tkEOF) then
        begin
          if FLex.Cur().Kind = tkEOL then FLex.Advance();
          Continue;
        end;
      end;
      // a leading `name:` is a named label. An identifier alone is never a
      // statement, so `ident :' at the start of one can only be a label --
      // except a keyword, which may be a statement with a ':' separator after.
      if (FLex.Cur().Kind = tkIdent) and (FLex.Peek().Kind = tkColon) and
         (not IsReservedWord(FLex.Cur().StrVal)) then
      begin
        RecordLabel(FLex.Cur().StrVal, FProg.Count);
        FLex.Advance();   // name
        FLex.Advance();   // ':'
        Continue;
      end;
      ParseStatement();
      if FFailed then Break;
      if FLex.Cur().Kind = tkColon then
        FLex.Advance()                                     // ':' separates statements on a line
      else if (FLex.Cur().Kind <> tkEOL) and (FLex.Cur().Kind <> tkEOF) then
        Fail('expected end of line', FLex.Cur().Line)
      else if FLex.Cur().Kind = tkEOL then
        FLex.Advance();
    end;
    if not FFailed then ResolveGotos();
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
