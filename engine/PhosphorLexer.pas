{******************************************************************************
  Phosphor BASIC -- lexer

  MIT License. Copyright (c) 2026 Andre Murta.

  Tokenizes UTF-8 source. Numbers carry their kind (an integer literal lexes to
  tkInt, a decimal to tkDouble), so the value model's int%/Double distinction
  starts at the very first stage. String literals are sliced as raw UTF-8 bytes
  with no transcoding; a doubled quote "" inside a literal yields one quote (the
  only escape, since '\' is now integer division). Identifiers carry an optional
  trailing type suffix ($ % @ ?) as part of the name; names are case-insensitive.
******************************************************************************}
unit PhosphorLexer;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils;

type
  TTokenKind = (
    tkEOF, tkEOL,
    tkInt, tkDouble, tkString, tkIdent,
    tkComma, tkSemicolon, tkColon, tkLParen, tkRParen, tkLBracket, tkRBracket,
    tkLBrace, tkRBrace,
    tkPlus, tkMinus, tkStar, tkSlash, tkBackslash, tkCaret, tkMod,
    tkPlusEq, tkMinusEq, tkStarEq, tkSlashEq,
    tkEQ, tkNE, tkLT, tkLE, tkGT, tkGE
  );

  TToken = record
    Kind: TTokenKind;
    IntVal: Int64;
    DblVal: Double;
    StrVal: String;   // string literal contents, or the (lowercased) identifier
    Line: Integer;
  end;

  TLexer = class
  private
    FSrc: String;
    FPos: Integer;
    FLine: Integer;
    FTokens: array of TToken;
    FCount: Integer;
    FIndex: Integer;
    FErr: String;
    FErrLine: Integer;
    procedure Push(const T: TToken);
    procedure PushSimple(K: TTokenKind; ALine: Integer);
    procedure MergeCompoundKeywords;
    function Tokenize: Boolean;
  public
    constructor Create(const ASource: String);
    function Cur: TToken;
    function Peek: TToken;   // one past Cur
    procedure Advance;
    function Ok: Boolean;
    property ErrorMessage: String read FErr;
    property ErrorLine: Integer read FErrLine;
  end;

implementation

var
  LexFS: TFormatSettings;   // invariant: '.' as decimal separator

function IsDigit(C: Char): Boolean; inline;
begin
  Result := (C >= '0') and (C <= '9');
end;

function IsIdentStart(C: Char): Boolean; inline;
begin
  Result := ((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or (C = '_');
end;

function IsIdentChar(C: Char): Boolean; inline;
begin
  Result := IsIdentStart(C) or IsDigit(C);
end;

constructor TLexer.Create(const ASource: String);
begin
  inherited Create;
  FSrc := ASource;
  FPos := 1;
  FLine := 1;
  FCount := 0;
  FIndex := 0;
  FErr := '';
  FErrLine := 0;
  Tokenize;
end;

procedure TLexer.Push(const T: TToken);
begin
  if FCount = Length(FTokens) then
    SetLength(FTokens, (FCount + 1) * 2);
  FTokens[FCount] := T;
  Inc(FCount);
end;

procedure TLexer.PushSimple(K: TTokenKind; ALine: Integer);
var
  T: TToken;
begin
  T := Default(TToken);
  T.Kind := K;
  T.Line := ALine;
  Push(T);
end;

{ Accepts the two-word block terminators (`end if`, `end while`, `end select`,
  `end function`) as equivalents of the one-word forms, like Plan9Basic. Merges
  an `end` token immediately followed by one of those keywords into a single
  `endif`/`endwhile`/... identifier. A bare `end` (the END statement) is left
  alone, and `end` on its own line before `function` (a new definition) is never
  merged because an EOL token separates them. }
procedure TLexer.MergeCompoundKeywords;
var
  i, j: Integer;
  merged: String;
begin
  i := 0;
  j := 0;
  while i < FCount do
  begin
    merged := '';
    if (FTokens[i].Kind = tkIdent) and (i + 1 < FCount) and (FTokens[i + 1].Kind = tkIdent) then
    begin
      if FTokens[i].StrVal = 'end' then
        case FTokens[i + 1].StrVal of
          'if':       merged := 'endif';
          'while':    merged := 'endwhile';
          'select':   merged := 'endselect';
          'function': merged := 'endfunction';
        end
      else if (FTokens[i].StrVal = 'else') and (FTokens[i + 1].StrVal = 'if') then
        merged := 'elseif';   // `else if` is the same chain as `elseif`
    end;
    if merged <> '' then
    begin
      FTokens[j] := FTokens[i];      // keep 'end's line/position
      FTokens[j].StrVal := merged;
      Inc(i, 2);
    end
    else
    begin
      FTokens[j] := FTokens[i];
      Inc(i);
    end;
    Inc(j);
  end;
  FCount := j;
end;

function TLexer.Tokenize: Boolean;
var
  n, len, startLine, runStart: Integer;
  c, c2: Char;
  T: TToken;
  s: String;
  hasDot: Boolean;
  iv: Int64;
begin
  len := Length(FSrc);
  while FPos <= len do
  begin
    c := FSrc[FPos];

    // whitespace (a bare CR is treated as whitespace; LF ends a line)
    if (c = ' ') or (c = #9) or (c = #13) then
    begin
      Inc(FPos);
      Continue;
    end;
    if c = #10 then
    begin
      PushSimple(tkEOL, FLine);
      Inc(FLine);
      Inc(FPos);
      Continue;
    end;

    // ' comment to end of line
    if c = '''' then
    begin
      while (FPos <= len) and (FSrc[FPos] <> #10) do Inc(FPos);
      Continue;
    end;

    startLine := FLine;

    // number
    if IsDigit(c) then
    begin
      n := FPos;
      hasDot := False;
      while (FPos <= len) and IsDigit(FSrc[FPos]) do Inc(FPos);
      if (FPos <= len) and (FSrc[FPos] = '.') and (FPos < len) and IsDigit(FSrc[FPos + 1]) then
      begin
        hasDot := True;
        Inc(FPos); // '.'
        while (FPos <= len) and IsDigit(FSrc[FPos]) do Inc(FPos);
      end;
      s := Copy(FSrc, n, FPos - n);
      T := Default(TToken);
      T.Line := startLine;
      if (not hasDot) and TryStrToInt64(s, iv) then
      begin
        T.Kind := tkInt;
        T.IntVal := iv;
      end
      else
      begin
        T.Kind := tkDouble;
        T.DblVal := StrToFloat(s, LexFS);
      end;
      Push(T);
      Continue;
    end;

    // string literal, with doubled-quote escape. Accumulate runs with Copy
    // (String -> String preserves the UTF-8 bytes); appending a bare AnsiChar
    // would route each byte through the system codepage and corrupt multibyte
    // characters.
    if c = '"' then
    begin
      Inc(FPos); // opening quote
      s := '';
      runStart := FPos;
      while FPos <= len do
      begin
        if FSrc[FPos] = '"' then
        begin
          s := s + Copy(FSrc, runStart, FPos - runStart);
          if (FPos < len) and (FSrc[FPos + 1] = '"') then
          begin
            s := s + '"';
            Inc(FPos, 2);
            runStart := FPos;
          end
          else
          begin
            Inc(FPos); // closing quote
            Break;
          end;
        end
        else if FSrc[FPos] = #10 then
        begin
          FErr := 'unterminated string';
          FErrLine := startLine;
          Exit(False);
        end
        else
          Inc(FPos);
      end;
      T := Default(TToken);
      T.Kind := tkString;
      T.StrVal := s;
      T.Line := startLine;
      Push(T);
      Continue;
    end;

    // identifier (with optional trailing type suffix), or keyword
    if IsIdentStart(c) then
    begin
      n := FPos;
      while (FPos <= len) and IsIdentChar(FSrc[FPos]) do Inc(FPos);
      if (FPos <= len) and ((FSrc[FPos] = '$') or (FSrc[FPos] = '%') or
                            (FSrc[FPos] = '@') or (FSrc[FPos] = '?')) then
        Inc(FPos); // suffix is part of the name
      s := LowerCase(Copy(FSrc, n, FPos - n));
      if s = 'rem' then
      begin
        // comment to end of line
        while (FPos <= len) and (FSrc[FPos] <> #10) do Inc(FPos);
        Continue;
      end;
      if s = 'mod' then
        PushSimple(tkMod, startLine)
      else
      begin
        T := Default(TToken);
        T.Kind := tkIdent;
        T.StrVal := s;
        T.Line := startLine;
        Push(T);
      end;
      Continue;
    end;

    // operators and punctuation
    case c of
      '+':
        begin
          if (FPos < len) and (FSrc[FPos + 1] = '=') then begin PushSimple(tkPlusEq, startLine); Inc(FPos, 2); end
          else begin PushSimple(tkPlus, startLine); Inc(FPos); end;
        end;
      '-':
        begin
          if (FPos < len) and (FSrc[FPos + 1] = '=') then begin PushSimple(tkMinusEq, startLine); Inc(FPos, 2); end
          else begin PushSimple(tkMinus, startLine); Inc(FPos); end;
        end;
      '*':
        begin
          if (FPos < len) and (FSrc[FPos + 1] = '=') then begin PushSimple(tkStarEq, startLine); Inc(FPos, 2); end
          else begin PushSimple(tkStar, startLine); Inc(FPos); end;
        end;
      '/':
        begin
          if (FPos < len) and (FSrc[FPos + 1] = '=') then begin PushSimple(tkSlashEq, startLine); Inc(FPos, 2); end
          else begin PushSimple(tkSlash, startLine); Inc(FPos); end;
        end;
      '\': begin PushSimple(tkBackslash, startLine); Inc(FPos); end;
      '^': begin PushSimple(tkCaret, startLine); Inc(FPos); end;
      '(': begin PushSimple(tkLParen, startLine); Inc(FPos); end;
      ')': begin PushSimple(tkRParen, startLine); Inc(FPos); end;
      '[': begin PushSimple(tkLBracket, startLine); Inc(FPos); end;
      ']': begin PushSimple(tkRBracket, startLine); Inc(FPos); end;
      '{': begin PushSimple(tkLBrace, startLine); Inc(FPos); end;   // JSON object literal
      '}': begin PushSimple(tkRBrace, startLine); Inc(FPos); end;
      ',': begin PushSimple(tkComma, startLine); Inc(FPos); end;
      ';': begin PushSimple(tkSemicolon, startLine); Inc(FPos); end;
      ':': begin PushSimple(tkColon, startLine); Inc(FPos); end;
      '=': begin PushSimple(tkEQ, startLine); Inc(FPos); end;
      '<':
        begin
          if FPos < len then c2 := FSrc[FPos + 1] else c2 := #0;
          if c2 = '=' then begin PushSimple(tkLE, startLine); Inc(FPos, 2); end
          else if c2 = '>' then begin PushSimple(tkNE, startLine); Inc(FPos, 2); end
          else begin PushSimple(tkLT, startLine); Inc(FPos); end;
        end;
      '>':
        begin
          if FPos < len then c2 := FSrc[FPos + 1] else c2 := #0;
          if c2 = '=' then begin PushSimple(tkGE, startLine); Inc(FPos, 2); end
          else begin PushSimple(tkGT, startLine); Inc(FPos); end;
        end;
    else
      FErr := 'unexpected character ''' + c + '''';
      FErrLine := startLine;
      Exit(False);
    end;
  end;

  PushSimple(tkEOL, FLine);   // terminate the last statement
  PushSimple(tkEOF, FLine);
  MergeCompoundKeywords;
  Result := True;
end;

function TLexer.Cur: TToken;
begin
  if FIndex < FCount then
    Result := FTokens[FIndex]
  else
    Result := FTokens[FCount - 1]; // tkEOF
end;

function TLexer.Peek: TToken;
begin
  if FIndex + 1 < FCount then
    Result := FTokens[FIndex + 1]
  else
    Result := FTokens[FCount - 1];
end;

procedure TLexer.Advance;
begin
  if FIndex < FCount - 1 then
    Inc(FIndex);
end;

function TLexer.Ok: Boolean;
begin
  Result := FErr = '';
end;

initialization
  LexFS := DefaultFormatSettings;
  LexFS.DecimalSeparator := '.';
  LexFS.ThousandSeparator := #0;

end.
