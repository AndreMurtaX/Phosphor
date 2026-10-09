{******************************************************************************
  Phosphor BASIC -- lexer

  MIT License. Copyright (c) 2026 Andre Murta.

  Tokenizes UTF-8 source. Numbers carry their kind (an integer literal lexes to
  tkInt, a decimal to tkDouble), so the value model's int%/Double distinction
  starts at the very first stage. String literals are sliced as raw UTF-8 bytes
  with no transcoding. A doubled quote "" inside a literal yields one quote, AND a
  backslash escape set is accepted as well -- \n \t \r \0 \a \b \f \v \\ \" -- which the
  scanner below implements and tests/suite/46_string_escapes.bas is the authority
  for. THIS PARAGRAPH SAID THE OPPOSITE UNTIL 2026-09-08: it claimed the doubled
  quote was the only escape, "since '\' is now integer division". That was the
  frozen decision, and the oracle import SUPERSEDED it on 2026-09-02 -- see
  docs/decisions.md#what-this-language-refuses-that-plan9basic-accepts, which records the supersession the comment never got.
  Outside a string literal '\' is still integer division, which is why a Windows
  path written as a literal needs its separators doubled. Identifiers carry an optional
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
    tkEQ, tkNE, tkLT, tkLE, tkGT, tkGE,
    tkHash    // '#' -- a file number in classic I/O (PRINT #1, INPUT #1, CLOSE #1)
  );

  TToken = record
    Kind: TTokenKind;
    IntVal: Int64;
    DblVal: Double;
    StrVal: String;   // string literal contents, or the (lowercased) identifier
    { An identifier AS WRITTEN (ledger r3). StrVal is folded because the
      language is case-insensitive, and every comparison the compiler makes
      is on StrVal; this is the spelling a person gave the name, kept only so
      a debugger can show it back. Empty for every other kind of token. }
    Raw: String;
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
    function EofToken: TToken;   // the answer when there is no token to answer with
  public
    constructor Create(const ASource: String);
    function Cur: TToken;
    function Peek: TToken;   // one past Cur
    procedure Advance;
    function Mark: Integer;             // current token position, for re-parsing
    procedure Reset(APos: Integer);     // rewind to a position from Mark
    function Ok: Boolean;
    { The as-written spelling of identifier AName (already folded): the nearest
      token at or BEHIND the cursor that carries it, '' when none does.

      THERE IS NO WINDOW, and the first version had one. It looked back 64
      tokens on the belief that a table entry is created while its token is
      being consumed. Measured over all 183 .bas files git knows, that is false
      for the commonest statement there is: `z = <expr>` creates the global
      AFTER the right-hand side is parsed, so the distance is the length of the
      expression -- 54 tokens in tests/suite/50_robustness.bas, and unbounded
      in principle. A window would have dropped the spelling of a long
      assignment in silence. The scan still costs no more than the statement:
      the entry is created once, by a token inside the statement being parsed,
      so the walk stops at or before that statement's first token. Nothing was
      ever found AHEAD of the cursor (0 of 2615 hits), so it never looks
      there. }
    function SpellingNear(const AName: String): String;
    property ErrorMessage: String read FErr;
    property ErrorLine: Integer read FErrLine;
  end;

implementation

uses
  Math,           // IsNan/IsInfinite: the finiteness check on a numeric literal, below
  PhosphorValue;  // ReadNumberText: the engine's one reader of number text

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

{ THE OFFENDING BYTE, SPELLED SO THAT IT SURVIVES BEING SAID.

  This unit carries the codepage UTF8 directive, so appending a Char to a message
  RE-ENCODES it: every byte >= 128 came out as a literal '?'. That is not merely
  ugly -- it made `unexpected character '?'` byte-identical for a curly quote
  pasted from a browser (0xE2), a non-breaking space (0xA0), a lone Latin-1
  letter (0xE9) and a REAL question mark. Four different characters, one message,
  hex 27 3f 27 in all four; measured. And a single byte >= 128 is not valid UTF-8
  on its own, so no spelling that embeds the raw byte can work at any layer --
  Copy(FSrc, FPos, 1), the String slice this unit reaches for elsewhere, loses it
  just the same on the way to the console.

  So the byte is rendered NUMERICALLY when it cannot be shown, and shown as
  itself only when it is printable ASCII -- 33..126, where the encoding is the
  identity and there is a glyph the reader can find in the file. A space, a tab
  and every byte >= 128 take the numeric form, which is the half that matters:
  those are exactly the characters that are invisible in an editor, so a
  question mark told the reader nothing to search for.

  The quoted form is built from a one-character SLICE, never from a Char, so the
  rule scripts/check-codepage.py enforces holds here by construction rather than
  by an argument about which byte values are safe. }
function ByteHere(const ASrc: String; APos: Integer): String;
var
  b: Byte;
begin
  b := Ord(ASrc[APos]);
  if (b >= 33) and (b <= 126) then
    Result := '''' + Copy(ASrc, APos, 1) + ''' (#' + IntToStr(b) + ')'
  else
    Result := '#' + IntToStr(b) + ' (0x' + IntToHex(b, 2) + ')';
end;

{ WHERE THAT BYTE SITS ON ITS LINE, counting bytes from 1.

  The line number alone sends a reader to a line and no further, which is no help
  at all when the character is invisible: a non-breaking space between `x` and
  `=` looks exactly like a space in every editor. The lexer is the only layer
  that still holds the offset, so it is the only place the column exists.

  Counted in BYTES, not codepoints, deliberately -- the thing being reported IS a
  byte, and a codepoint count would be a different number from the one an editor
  or a hex dump shows for a file whose encoding has already gone wrong. }
function ColumnAt(const ASrc: String; APos: Integer): Integer;
var
  i: Integer;
begin
  i := APos;
  while (i > 1) and (ASrc[i - 1] <> #10) do Dec(i);
  Result := APos - i + 1;
end;

constructor TLexer.Create(const ASource: String);
begin
  inherited Create();
  FSrc := ASource;
  FPos := 1;
  FLine := 1;
  FCount := 0;
  FIndex := 0;
  FErr := '';
  FErrLine := 0;
  Tokenize();
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
  n, len, startLine, runStart, ex: Integer;
  c, c2: Char;
  T: TToken;
  s: String;
  hasDot: Boolean;
  strClosed: Boolean;
  num: TNumberText;
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
      // Exponent notation. It is not decoration: ValToStr PRINTS this form, so
      // without it the language could emit `1E200` and then refuse to read its own
      // output back -- `println 1E200` was a syntax error while `val("1E200")`
      // worked. Only consumed when a digit actually follows (optionally after a
      // sign), so an identifier butted against a number is still two tokens.
      if (FPos <= len) and ((FSrc[FPos] = 'e') or (FSrc[FPos] = 'E')) then
      begin
        ex := FPos + 1;
        if (ex <= len) and ((FSrc[ex] = '+') or (FSrc[ex] = '-')) then Inc(ex);
        if (ex <= len) and IsDigit(FSrc[ex]) then
        begin
          hasDot := True;                      // an exponent makes it a double
          FPos := ex;
          while (FPos <= len) and IsDigit(FSrc[FPos]) do Inc(FPos);
        end;
      end;
      s := Copy(FSrc, n, FPos - n);
      T := Default(TToken);
      T.Line := startLine;
      { READ BY THE ENGINE'S ONE NUMBER READER (PhosphorValue.ReadNumberText),
        correctly rounded, at any length. Until 2026-10-09 this was TryStrToInt64
        and TryStrToFloat -- FPC's Val, which read `1e126` one ulp off and refused
        a literal past 255 characters as "out of range" whatever its value. A
        plain digit run that fits an Int64 is still an int%, exactly; hasDot (set
        for a '.' or an exponent above) must agree with IsInt, and does, because
        IsInt is only ever true for a spelling with neither. }
      num := ReadNumberText(s);
      if (not hasDot) and num.IsInt then
      begin
        T.Kind := tkInt;
        T.IntVal := num.Int;
      end
      else
      begin
        T.Kind := tkDouble;
        T.DblVal := num.Value;
        // A NUMBER THE MACHINE CANNOT HOLD IS A SOURCE ERROR, and the user is told
        // which one. The reader answers a magnitude past the largest Double as
        // +Inf, and it must not reach the constant pool: that would falsify the
        // invariant FiniteD states in PhosphorValue -- "no TValue ever holds a
        // non-finite Double" -- which is the sole reason it is safe to leave the
        // invalid-operation trap unmasked while a program runs. Once, `x = 1e999`
        // printed +Inf and then `x - x` raised EInvalidOp and killed the process
        // at exit 3, past an `on error goto` already in force, taking any
        // embedding host with it; and before that an unguarded StrToFloat raised
        // EConvertError out of the lexer on a 400-digit integer. Both spellings
        // of an impossible number get the same message. (NaN cannot be spelled
        // as a literal -- a number token starts with a digit -- but it is checked
        // in the same breath, so the guarantee is the whole one FiniteD relies
        // on and not a corner of it. Not Ok cannot happen for a token this loop
        // built, and is refused the same way rather than trusted.) A literal
        // UNDER the smallest subnormal is not an error: it is the nearest
        // Double, which is zero, as for every other reader of number text.
        if (not num.Ok) or IsNan(T.DblVal) or IsInfinite(T.DblVal) then
        begin
          FErr := 'the number ' + s + ' is out of range';
          FErrLine := startLine;
          Exit(False);
        end;
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
      // WHETHER THE CLOSING QUOTE WAS EVER SEEN, tracked rather than inferred.
      // The loop below has three exits and only two of them used to be
      // examined: the `Break` after a closing quote, and the two error paths.
      // The THIRD is the loop condition simply going false -- the source ran
      // out while the literal was still open -- and it fell straight through to
      // the Push below and produced a perfectly ordinary tkString. Worse, the
      // pending run since `runStart` is flushed only AT a quote or an escape,
      // so the token's text was empty as well: the last statement of a
      // truncated file silently became `println ""`.
      //
      // It cannot be inferred from FPos afterwards, which is why it is a flag: a
      // literal whose closing quote is the final byte of the file also leaves
      // FPos = len + 1, and that one is correct.
      //
      // The bare-#10 path below already calls this same file an error, so the
      // only thing that decided between "unterminated string" and silent
      // success was whether the file happened to end with a newline.
      strClosed := False;
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
            strClosed := True;
            Break;
          end;
        end
        else if FSrc[FPos] = '\' then
        begin
          // C-style escape. Flush the run first (Copy preserves UTF-8 bytes),
          // then append the escape's byte. Every escape below is ASCII (< 128),
          // so a single-char append is codepage-safe. A quote can still be
          // doubled as well ("" ), so both spellings reach a quote.
          s := s + Copy(FSrc, runStart, FPos - runStart);
          if FPos = len then
          begin
            FErr := 'unterminated string';
            FErrLine := startLine;
            Exit(False);
          end;
          case FSrc[FPos + 1] of
            'n': s := s + #10;
            't': s := s + #9;
            'r': s := s + #13;
            '0': s := s + #0;
            'a': s := s + #7;
            'b': s := s + #8;
            'f': s := s + #12;
            'v': s := s + #11;
            '\': s := s + '\';
            '"': s := s + '"';
          else
            { The escaped byte is reported through ByteHere for the same reason
              the operator message below is: `"a\<0xE9>b"` used to say
              `unknown escape sequence '\?'`, which is what a real `"a\?b"` says
              -- the Copy here is a String slice and keeps the byte in FErr, but
              a lone byte >= 128 is not valid UTF-8 and does not survive being
              written out either. Measured: both spellings produced hex 5c 3f. }
            FErr := 'unknown escape sequence: a backslash followed by ' +
                    ByteHere(FSrc, FPos + 1) + ', at column ' +
                    IntToStr(ColumnAt(FSrc, FPos));
            FErrLine := startLine;
            Exit(False);
          end;
          Inc(FPos, 2);
          runStart := FPos;
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
      if not strClosed then
      begin
        FErr := 'unterminated string';
        FErrLine := startLine;
        Exit(False);
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
        T.Raw := Copy(FSrc, n, FPos - n);
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
      '#': begin PushSimple(tkHash, startLine); Inc(FPos); end;
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
      { NOT `+ c +`. See ByteHere: this is the site that made a curly quote, a
        non-breaking space, a Latin-1 letter and a real '?' all say the same
        twenty-three bytes. }
      FErr := 'unexpected character ' + ByteHere(FSrc, FPos) + ' at column ' +
              IntToStr(ColumnAt(FSrc, FPos));
      FErrLine := startLine;
      Exit(False);
    end;
  end;

  PushSimple(tkEOL, FLine);   // terminate the last statement
  PushSimple(tkEOF, FLine);
  MergeCompoundKeywords();
  Result := True;
end;

{ THE TOKEN ARRAY CAN BE EMPTY, and both readers below used to assume it never
  was. Tokenize gives up the moment it meets a character that cannot start a
  token, so when that character is the FIRST one not a single token was ever
  pushed: FCount is 0 and FTokens is still nil. The fallback `FTokens[FCount - 1]`
  is then FTokens[-1] -- a read from unallocated memory, and worse than a read,
  because copying a TToken also copies its StrVal: String field and increments a
  refcount through whatever pointer that garbage holds.

  The damage was not theoretical. TPhosphorCompiler.Fail asks `FLex.Cur().Kind`
  to record whether the input had run out, so EVERY lexical failure at offset 1
  came through here: `phosphor run` on a file starting with '@', '~' or a NUL byte
  died with an access violation instead of printing the syntax error the very same
  character prints on line 2, and a UTF-8 BOM -- which every Windows editor and
  `Set-Content -Encoding utf8` writes -- killed the REPL on the first line of a
  piped session.

  Answering with a synthesised EOF is the honest answer: there is no token, and
  the input is over. FLine is where the lexer stopped, so the line number is real
  rather than a zero. }
function TLexer.EofToken: TToken;
begin
  Result := Default(TToken);   // Kind = tkEOF: the first value of TTokenKind
  Result.Line := FLine;
end;

function TLexer.Cur: TToken;
begin
  if FIndex < FCount then
    Result := FTokens[FIndex]
  else if FCount > 0 then
    Result := FTokens[FCount - 1] // tkEOF
  else
    Result := EofToken();
end;

function TLexer.Peek: TToken;
begin
  if FIndex + 1 < FCount then
    Result := FTokens[FIndex + 1]
  else if FCount > 0 then
    Result := FTokens[FCount - 1]
  else
    Result := EofToken();
end;

procedure TLexer.Advance;
begin
  if FIndex < FCount - 1 then
    Inc(FIndex);
end;

function TLexer.Mark: Integer;
begin
  Result := FIndex;
end;

procedure TLexer.Reset(APos: Integer);
begin
  if (APos >= 0) and (APos < FCount) then
    FIndex := APos;
end;

function TLexer.SpellingNear(const AName: String): String;
var i, hi: Integer;
begin
  Result := '';
  hi := FIndex;
  if hi > FCount - 1 then hi := FCount - 1;
  for i := hi downto 0 do
    if (FTokens[i].Kind = tkIdent) and (FTokens[i].StrVal = AName) then
      Exit(FTokens[i].Raw);
end;

function TLexer.Ok: Boolean;
begin
  Result := FErr = '';
end;

end.
