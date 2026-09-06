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

procedure Key(const AName: String; AFirst: Byte; ANext: TCrtByteSource; const AWant: String);
var got: String;
begin
  Fed := 0;
  got := CrtAssembleKey(AFirst, ANext);
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
  {$ELSE}
  // A NORMAL KEY IS ONE BYTE, and nothing else is consumed after it.
  Key('a printable key is its own byte', Ord('q'), @Feed, 'q');
  Report(Fed = 0, 'and nothing after it was taken from the stream');

  // A UTF-8 CHARACTER IS ONE KEY. This is what the old code got wrong: it
  // answered the lead byte and left the continuation for the next call, so a
  // typed accented letter arrived in two pieces here and in one on Windows.
  Script := #$C3#$A9;                      // 'e-acute', two bytes
  Key('an accented character comes back whole', $C3, @Feed, #$C3#$A9);
  Script := #$E2#$82#$AC;                  // euro sign, three bytes
  Key('and a three-byte character too', $E2, @Feed, #$E2#$82#$AC);
  Script := #$F0#$9F#$92#$A1;              // an astral codepoint, four bytes
  Key('and a four-byte one', $F0, @Feed, #$F0#$9F#$92#$A1);

  // A BROKEN STREAM MUST NOT EAT THE NEXT KEY. A lead byte followed by something
  // that is not a continuation stops there, leaving that byte for the next read.
  Script := 'X';
  Key('a lead byte with no continuation stops', $C3, @Feed, #$C3);
  Report(Fed = 0, 'without swallowing the byte that followed');

  // AN ESCAPE SEQUENCE is whatever is already waiting behind the ESC.
  Script := '[A';
  Key('an arrow key is ESC plus what is buffered', 27, @Feed, #27'[A');
  Script := '';
  Key('and ESC alone is a key on its own', 27, @Feed, #27);

  // THE TAG, for the same reason as the Windows side: the engine's strings are
  // UTF-8, and a key tagged with the system code page is converted on the way in.
  Script := #$C3#$A9;
  Report(StringCodePage(CrtAssembleKey($C3, @Feed)) = CP_UTF8,
         'the key is tagged with the engine code page');
  Script := #$C3#$A9;
  Report(Length(ValStr(CrtAssembleKey($C3, @Feed)).Str) = 2,
         'and is still two bytes after crossing into a TValue');
  {$ENDIF}

  if ProveFail then
    Report(False, 'deliberate failure (--fail)');

  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed > 0 then Halt(1) else Halt(0);
end.
