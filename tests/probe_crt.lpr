{******************************************************************************
  probe_crt -- a Pascal test of the keyboard decision the suite cannot reach

  Everything about `getkey$` needs a real console: a console handle, raw mode, a
  live keypress. The headless suite therefore never ran a line of the code that
  turns a key event into a string -- and a missing begin/end sat in it, reporting
  EVERY key as an extended one and writing a byte past the end of a one-byte
  string while doing so. `examples/crt_keys.bas` could not be quit with 'q',
  because 'q' never came back as "q".

  A path that cannot be reached without a human at a keyboard is a path that will
  break unwatched. So the DECISION is separated from the I/O -- CrtKeyFromEvent
  takes the two fields a console INPUT_RECORD carries -- and this probe calls it
  with no console anywhere.

  Prints "ok: N" / "fail: M" and exits non-zero on any failure. Run with --fail to
  corrupt one expectation and confirm the check can fail.
******************************************************************************}
program probe_crt;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  SysUtils, PhosphorValue, PhosphorCrtLib;

var
  Ok: Integer = 0;
  Failed: Integer = 0;
  ProveFail: Boolean = False;

procedure Report(Pass: Boolean; const Name: String);
begin
  if Pass then Inc(Ok)
  else begin Inc(Failed); Writeln(StdErr, 'FAIL: ', Name); end;
end;

{$IFNDEF WINDOWS}
{ A scripted byte source: the bytes the terminal would have had waiting. Fed
  counts what was actually taken, so a test can assert that a decision did NOT
  consume the byte after the key it returned. }
var
  Script: String = '';
  Fed: Integer = 0;

function Feed(out AByte: Byte): Boolean;
begin
  AByte := 0;
  if Script = '' then Exit(False);
  AByte := Byte(Script[1]);
  Delete(Script, 1, 1);
  Inc(Fed);
  Result := True;
end;

function Hex(const S: String): String;
var i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
    Result := Result + IntToHex(Byte(S[i]), 2) + ' ';
  Result := Trim(Result);
end;

function SameBytes(const A, B: String): Boolean;
var i: Integer;
begin
  Result := Length(A) = Length(B);
  if not Result then Exit;
  for i := 1 to Length(A) do
    if A[i] <> B[i] then Exit(False);
end;

var
  Leftover: Integer = -1;

procedure Key(const AName: String; AFirst: Byte; ANext: TCrtByteSource; const AWant: String);
var got: String;
begin
  Fed := 0;
  got := CrtAssembleKey(AFirst, ANext, Leftover);
  Report(SameBytes(got, AWant),
         AName + ' (wanted [' + Hex(AWant) + '], got [' + Hex(got) + '])');
end;
{$ENDIF}

{$IFDEF WINDOWS}
const
  VK_LEFT_  = 37;
  VK_F1_    = 112;
  VK_OEM_1_ = 186;   // a code >= 128: the byte must survive, not be re-encoded

function Hex(const S: String): String;
var i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
    Result := Result + IntToHex(Byte(S[i]), 2) + ' ';
  Result := Trim(Result);
end;

{ Compared as BYTES. Two strings can hold the same bytes and still differ under
  '=', because AnsiString comparison CONVERTS when the code pages differ -- which
  is the very thing this file exists to pin. So the expectation is built by index
  too, and the check is byte-for-byte. }
function SameBytes(const A, B: String): Boolean;
var i: Integer;
begin
  Result := Length(A) = Length(B);
  if not Result then Exit;
  for i := 1 to Length(A) do
    if A[i] <> B[i] then Exit(False);
end;

{ chr(0) + a virtual-key code, built the safe way, as the expectation. }
function Extended(AVk: Byte): String;
begin
  SetLength(Result, 2);
  Result[1] := #0;
  Result[2] := Chr(AVk);
  SetCodePage(RawByteString(Result), CP_UTF8, False);
end;

procedure Key(const AName: String; AChar: WideChar; AVk: Word; const AWant: String);
var got: String;
begin
  got := CrtKeyFromEvent(AChar, AVk);
  Report(SameBytes(got, AWant),
         AName + ' (wanted [' + Hex(AWant) + '], got [' + Hex(got) + '])');
end;

var
  PairUsed: Boolean;

{ The pair decision: the key, AND whether the next event was taken for it. }
procedure PairKey(const AName: String; AFirst: WideChar; AHave: Boolean; ANext: WideChar;
                  const AWant: String; AWantUsed: Boolean);
var got: String; used: Boolean;
begin
  got := CrtKeyFromPair(AFirst, AHave, ANext, used);
  Report(SameBytes(got, AWant) and (used = AWantUsed),
         AName + ' (wanted [' + Hex(AWant) + '] ' + BoolToStr(AWantUsed, True) +
         ', got [' + Hex(got) + '] ' + BoolToStr(used, True) + ')');
end;

{ The model's decision on one event: the key, '' for an event that is none. }
procedure EventKey(const AName: String; ADown: Boolean; AChar: WideChar; AVk, AScan: Word;
                   AState: LongWord; const AWant: String);
var got: String;
begin
  got := CrtEventKey(ADown, AChar, AVk, AScan, AState);
  Report(SameBytes(got, AWant),
         AName + ' (wanted [' + Hex(AWant) + '], got [' + Hex(got) + '])');
end;
{$ENDIF}

begin
  ProveFail := (ParamCount >= 1) and (ParamStr(1) = '--fail');

  {$IFDEF WINDOWS}
  // A PRINTABLE KEY IS ITSELF. This is the assertion the bug failed: 'q' came
  // back as one byte of value 0, so `if k$ = "q"` was never true.
  Key('a printable key is its own character', 'q', 81, 'q');
  Report(Length(CrtKeyFromEvent('q', 81)) = 1,
         'and is exactly one byte long (the overrun wrote a second)');
  Key('a digit likewise', '7', 55, '7');
  Key('a space is a character, not an extended key', ' ', 32, ' ');

  // A non-ASCII key must arrive as its UTF-8 bytes, not as one mangled one.
  Key('an accented character is its UTF-8 bytes', #$00E7, 186, #$C3#$A7);   // 'c-cedilla'

  // Only a key with NO character is extended, and then it is chr(0) + the VK code.
  Key('an arrow key is chr(0) + its virtual-key code', #0, VK_LEFT_, Extended(VK_LEFT_));
  Key('so is a function key', #0, VK_F1_, Extended(VK_F1_));
  Report(Length(CrtKeyFromEvent(#0, VK_LEFT_)) = 2, 'and is two bytes long');

  // A virtual-key code >= 128 must survive as one byte. Built by index rather
  // than concatenated for exactly this reason: under the unit's UTF8 codepage,
  // appending a Char >= 128 to a String re-encodes it into two bytes.
  Key('a virtual-key code >= 128 stays one byte', #0, VK_OEM_1_, Extended(VK_OEM_1_));
  Report(Length(CrtKeyFromEvent(#0, VK_OEM_1_)) = 2,
         'and does not become three through re-encoding');

  // THE TAG, not just the bytes. SetLength stamps a fresh string with the SYSTEM
  // code page, and the engine's strings are UTF-8: a mismatched tag means the two
  // bytes are CONVERTED on the way in, silently, and the program sees three.
  Report(StringCodePage(CrtKeyFromEvent(#0, VK_OEM_1_)) = CP_UTF8,
         'the key is tagged with the engine code page, not the system one');
  Report(Length(ValStr(CrtKeyFromEvent(#0, VK_OEM_1_)).Str) = 2,
         'so it is still two bytes after crossing into a TValue');
  Report(Byte(ValStr(CrtKeyFromEvent(#0, VK_OEM_1_)).Str[2]) = VK_OEM_1_,
         'and the second byte is the virtual-key code the program will read');

  // A CHARACTER OUTSIDE THE BMP (round 7, 2026-10-11). An INPUT_RECORD holds one
  // UTF-16 unit, so U+1F600 arrives as two key events, D83D then DE00; each was
  // converted alone by UTF8Encode, which drops a lone surrogate, so both halves
  // answered '' -- "not a key" -- and the keystroke vanished. Expected, from the
  // Unicode Standard (not from a run): D83D DE00 is 10000 + (3D shl 10) + 200 =
  // U+1F600, whose UTF-8 is F0 9F 98 80; a half with no partner is U+FFFD, EF BF
  // BD -- the answer WideToUtf8 gives, and never the empty string.
  PairKey('a high half then a low half is ONE key', #$D83D, True, #$DE00,
          #$F0#$9F#$98#$80, True);
  PairKey('a high half with nothing waiting is U+FFFD', #$D83D, False, #0,
          #$EF#$BF#$BD, False);
  PairKey('a high half before a plain key is U+FFFD, and the key is left',
          #$D83D, True, 'q', #$EF#$BF#$BD, False);
  PairKey('a plain key never takes the event after it', 'q', True, #$DE00, 'q', False);
  Key('a high half alone is U+FFFD, not nothing', #$D83D, 0, #$EF#$BF#$BD);
  Key('and so is a low half alone', #$DE00, 0, #$EF#$BF#$BD);
  Report(StringCodePage(CrtKeyFromPair(#$D83D, True, #$DE00, PairUsed)) = CP_UTF8,
         'the pair is tagged with the engine code page');
  Report(Length(ValStr(CrtKeyFromPair(#$D83D, True, #$DE00, PairUsed)).Str) = 4,
         'and is still four bytes after crossing into a TValue');

  // THE KEYBOARD MODEL (round 8, 2026-10-11): which events are keys at all.
  // Every key-down with no character was chr(0) + its VK code, so Shift alone
  // was chr(0)+chr(16) ahead of every capital letter, and Alt+numpad entry
  // answered the Alt key and the digits, never the character. The codes are
  // winuser.h's (VK_SHIFT 10, VK_CONTROL 11, VK_MENU 12, VK_CAPITAL 14,
  // VK_LWIN 5B, VK_NUMPAD2 62, VK_NUMLOCK 90, VK_LSHIFT A0, VK_RMENU A5) and
  // wincon.h's flags (RIGHT_ALT 1, LEFT_ALT 2, LEFT_CTRL 8, SHIFT 10,
  // ENHANCED_KEY 100); a Unix terminal sends no byte for a modifier alone.
  EventKey('Shift alone is not a key', True, #0, $10, $2A, $10, '');
  EventKey('nor Ctrl', True, #0, $11, $1D, $08, '');
  EventKey('nor Alt', True, #0, $12, $38, $02, '');
  EventKey('nor Caps Lock', True, #0, $14, $3A, 0, '');
  EventKey('nor Num Lock', True, #0, $90, $45, 0, '');
  EventKey('nor a left-or-right Shift', True, #0, $A0, $2A, $10, '');
  EventKey('nor AltGr''s right Alt', True, #0, $A5, $38, $101, '');
  EventKey('nor a Windows key', True, #0, $5B, $5B, $100, '');
  EventKey('a capital typed with Shift is the capital', True, 'A', $41, $1E, $10, 'A');
  EventKey('Ctrl+A is chr(1), as a terminal sends it', True, #1, $41, $1E, $08, #1);
  EventKey('an arrow is still a key', True, #0, VK_LEFT_, $4B, $100, Extended(VK_LEFT_));
  EventKey('and Alt+arrow on the dedicated cluster too', True, #0, $26, $48, $102, Extended($26));
  EventKey('a numpad digit without Alt is a key', True, #0, $62, $50, 0, Extended($62));
  EventKey('with Alt held it is Alt+numpad entry, not a key', True, #0, $62, $50, $02, '');
  EventKey('and so with Num Lock off (scan code, not enhanced)', True, #0, $28, $50, $02, '');
  EventKey('the Alt key-up carries the composed character', False, #$00E9, $12, $38, 0, #$C3#$A9);
  EventKey('an Alt key-up with no character is not a key', False, #0, $12, $38, 0, '');
  EventKey('any other key-up is not a key', False, 'a', $41, $1E, 0, '');
  {$ELSE}
  // A NORMAL KEY IS ONE BYTE, and nothing else is consumed after it.
  Key('a printable key is its own byte', Ord('q'), @Feed, 'q');
  Report(Fed = 0, 'and nothing after it was taken from the stream');

  // A UTF-8 CHARACTER IS ONE KEY. This is what the old code got wrong: it
  // answered the lead byte and left the continuation for the next call, so a
  // typed accented letter arrived in two pieces here and in one on Windows.
  // The first byte is the ARGUMENT; the script holds only what follows it.
  Script := #$A9;                          // 'e-acute' = C3 A9
  Key('an accented character comes back whole', $C3, @Feed, #$C3#$A9);
  Script := #$82#$AC;                      // euro sign = E2 82 AC
  Key('and a three-byte character too', $E2, @Feed, #$E2#$82#$AC);
  Script := #$9F#$92#$A1;                  // an astral codepoint = F0 9F 92 A1
  Key('and a four-byte one', $F0, @Feed, #$F0#$9F#$92#$A1);
  Report(Leftover = -1, 'and a whole character leaves nothing over');

  // A BROKEN STREAM MUST NOT EAT THE NEXT KEY. A lead byte followed by something
  // that is not a continuation stops there -- and because a source cannot peek,
  // that byte has already been read, so it is HANDED BACK rather than lost. On a
  // terminal it is the first byte of the next key.
  // AND WHAT IT STOPPED ON IS U+FFFD (round 8, 2026-10-11), EF BF BD: one per
  // maximal ill-formed subpart (the Unicode Standard, 3.9, Table 3-7), the rule
  // environ$ keeps, and Windows' answer for a lone surrogate. This expectation
  // used to be the raw C3 -- written in 2026-09, before that rule existed.
  Script := 'X';
  Key('a lead byte with no continuation is U+FFFD', $C3, @Feed, #$EF#$BF#$BD);
  Report(Leftover = Ord('X'), 'and hands back the byte that followed, unswallowed');
  Script := 'X';
  Key('a continuation byte first is U+FFFD', $80, @Feed, #$EF#$BF#$BD);
  Report((Fed = 0) and (Leftover = -1), 'and takes nothing after it');
  Script := '';
  Key('a character cut short is ONE U+FFFD', $F0, @Feed, #$EF#$BF#$BD);
  Script := #$9F;
  Key('however much of it arrived', $F0, @Feed, #$EF#$BF#$BD);
  Report(Leftover = -1, 'and its arrived part is not handed back');
  Script := #$E9'q';
  Key('a Latin-1 e-acute (E9) before a q is U+FFFD', $E9, @Feed, #$EF#$BF#$BD);
  Report(Leftover = Ord('q'), 'and the q is the next key');
  Script := #$80;
  Key('an overlong lead (E0 80) is U+FFFD at the lead', $E0, @Feed, #$EF#$BF#$BD);
  Report(Leftover = $80, 'and the 80 is handed back, to be its own U+FFFD');
  Script := #$A0#$80;
  Key('a surrogate (ED A0 80) is U+FFFD at the lead', $ED, @Feed, #$EF#$BF#$BD);
  Report(Leftover = $A0, 'and A0 is handed back');
  Script := #$90#$80#$80;
  Key('past U+10FFFF (F4 90) is U+FFFD at the lead', $F4, @Feed, #$EF#$BF#$BD);
  Script := #$A9;
  Key('C0 begins nothing, even before a continuation', $C0, @Feed, #$EF#$BF#$BD);
  Report(Fed = 0, 'and takes nothing');
  Script := #$8F#$BF#$BF;
  Key('and F4 8F BF BF, U+10FFFF, is whole', $F4, @Feed, #$F4#$8F#$BF#$BF);

  // AN ESCAPE SEQUENCE is whatever is already waiting behind the ESC.
  Script := '[A';
  Key('an arrow key is ESC plus what is buffered', 27, @Feed, #27'[A');
  Script := '';
  Key('and ESC alone is a key on its own', 27, @Feed, #27);

  // THE TAG, for the same reason as the Windows side: the engine's strings are
  // UTF-8, and a key tagged with the system code page is converted on the way in.
  Script := #$A9;
  Report(StringCodePage(CrtAssembleKey($C3, @Feed, Leftover)) = CP_UTF8,
         'the key is tagged with the engine code page');
  Script := #$A9;
  Report(Length(ValStr(CrtAssembleKey($C3, @Feed, Leftover)).Str) = 2,
         'and is still two bytes after crossing into a TValue');
  {$ENDIF}

  if ProveFail then
    Report(False, 'deliberate failure (--fail)');

  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed > 0 then Halt(1) else Halt(0);
end.
