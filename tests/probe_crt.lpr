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

  THE UNIX DECISIONS RUN ON BOTH SYSTEMS (round 9, 2026-10-11). Where a key ends
  in a terminal's bytes (CrtAssembleKey), when a reader waits for the rest of
  one (CrtReaderKey, driven here by a scripted terminal with its own clock),
  and how a line typed ahead is edited (CrtEditLine) are compiled on every
  system, so this half of the probe is no longer one only Linux ever ran.
  Round 8's only Unix-only case was itself wrong for a day, and nobody on the
  machine the work was done on could have seen it.

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

function Hex(const S: RawByteString): String;
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
function SameBytes(const A, B: RawByteString): Boolean;
var i: Integer;
begin
  Result := Length(A) = Length(B);
  if not Result then Exit;
  for i := 1 to Length(A) do
    if A[i] <> B[i] then Exit(False);
end;

{ Bytes, built by index: never a literal mixing #$xx with a quoted string,
  which under codepage UTF8 compiles a byte >= 80 as TWO (CLAUDE.md, the
  binary-literal trap -- round 8's Unix case was exactly that). }
function B(const A: array of Byte): RawByteString;
var i: Integer;
begin
  SetLength(Result, Length(A));
  for i := 0 to High(A) do Result[i + 1] := Chr(A[i]);
end;

{ ASCII text as bytes, the same way. }
function T(const S: String): RawByteString;
var i: Integer;
begin
  SetLength(Result, Length(S));
  for i := 1 to Length(S) do Result[i] := S[i];
end;

{ Joined by copying, for the same reason. }
function J(const X, Y: RawByteString): RawByteString;
begin
  SetLength(Result, Length(X) + Length(Y));
  if X <> '' then Move(X[1], Result[1], Length(X));
  if Y <> '' then Move(Y[1], Result[Length(X) + 1], Length(Y));
end;

const
  ESC = 27;
  CSI_UP: array[0..2] of Byte = (27, Ord('['), Ord('A'));

function Fffd: RawByteString;
begin
  Result := B([$EF, $BF, $BD]);
end;

{ ---- where a key ends: CrtAssembleKey ---------------------------------------- }

procedure Assemble(const AName: String; const ABytes: RawByteString; AFinal: Boolean;
                   const AWant: RawByteString; AWantTaken, AWantWait: Integer);
var got: String; taken, wait: Integer;
begin
  got := CrtAssembleKey(ABytes, AFinal, taken, wait);
  Report(SameBytes(got, AWant) and (taken = AWantTaken) and (wait = AWantWait),
         AName + ' (wanted [' + Hex(AWant) + '] taking ' + IntToStr(AWantTaken) + ' wait ' +
         IntToStr(AWantWait) + ', got [' + Hex(got) + '] taking ' + IntToStr(taken) +
         ' wait ' + IntToStr(wait) + ')');
end;

{ ---- a scripted terminal, with its own clock -------------------------------- }
{ Bytes arrive at set times; a wait advances the clock to the next arrival or
  by its whole length. A read takes everything that has arrived, as a read()
  of a terminal does. Nothing here sleeps, so a 500 ms wait costs nothing. }
var
  EvAt: array of QWord;
  EvData: array of RawByteString;
  NextEv: Integer;
  FakeNow: QWord;
  R: TCrtKeyReader;

function FakeClock: QWord;
begin
  Result := FakeNow;
end;

function FakeFill(var ABuf: RawByteString; AWaitMs: Integer): Integer;
begin
  Result := 0;
  if (NextEv > High(EvAt)) then
  begin
    if AWaitMs < 0 then Exit(-1);          // nothing will ever come: the end
    Inc(FakeNow, AWaitMs);
    Exit;
  end;
  if EvAt[NextEv] > FakeNow then
  begin
    if AWaitMs = 0 then Exit;
    if (AWaitMs > 0) and (EvAt[NextEv] > FakeNow + QWord(AWaitMs)) then
    begin
      Inc(FakeNow, AWaitMs);
      Exit;
    end;
    FakeNow := EvAt[NextEv];
  end;
  while (NextEv <= High(EvAt)) and (EvAt[NextEv] <= FakeNow) do
  begin
    Inc(Result, Length(EvData[NextEv]));
    ABuf := J(ABuf, EvData[NextEv]);
    Inc(NextEv);
  end;
end;

procedure Script;
begin
  SetLength(EvAt, 0);
  SetLength(EvData, 0);
  NextEv := 0;
  FakeNow := 0;
  R.Buf := '';
  R.Arrived := 0;
  R.Fill := @FakeFill;
  R.Clock := @FakeClock;
end;

procedure At(AMs: QWord; const AData: RawByteString);
var n: Integer;
begin
  n := Length(EvAt);
  SetLength(EvAt, n + 1);
  SetLength(EvData, n + 1);
  EvAt[n] := AMs;
  EvData[n] := AData;
end;

{ getkey$ (ABlock) or inkey$, as the reader answers it. }
procedure ReadKey(const AName: String; ABlock: Boolean; const AWant: RawByteString);
var got: String;
begin
  got := CrtReaderKey(R, ABlock);
  Report(SameBytes(got, AWant),
         AName + ' (wanted [' + Hex(AWant) + '], got [' + Hex(got) + '] at ' +
         IntToStr(FakeNow) + ' ms)');
end;

{ ---- a line typed ahead: CrtEditLine ----------------------------------------- }

{ Feed AInput a byte at a time; the line and the echo it ends with. }
procedure Edit(const AName: String; const AInput: RawByteString; const AKeys: TCrtEditKeys;
               AWantStep: TCrtEditStep; const AWantLine, AWantEcho: RawByteString);
var line, echo: String; all: RawByteString; lit: Boolean; i: Integer; step: TCrtEditStep;
begin
  line := '';
  all := '';
  lit := False;
  step := cesMore;
  for i := 1 to Length(AInput) do
  begin
    step := CrtEditLine(line, lit, Byte(AInput[i]), AKeys, echo);
    all := J(all, echo);
    if step <> cesMore then Break;
  end;
  Report((step = AWantStep) and SameBytes(line, AWantLine) and SameBytes(all, AWantEcho),
         AName + ' (wanted ' + IntToStr(Ord(AWantStep)) + ' [' + Hex(AWantLine) + '] echo [' +
         Hex(AWantEcho) + '], got ' + IntToStr(Ord(step)) + ' [' + Hex(line) + '] echo [' +
         Hex(all) + '])');
end;

{$IFDEF WINDOWS}
const
  VK_LEFT_  = 37;
  VK_F1_    = 112;
  VK_OEM_1_ = 186;   // a code >= 128: the byte must survive, not be re-encoded

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

var
  Sane, K: TCrtEditKeys;
  i, taken, wait: Integer;
  Long: RawByteString;
  Rub: RawByteString;
  Bt: Byte;

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
  Key('an accented character is its UTF-8 bytes', #$00E7, 186, B([$C3, $A7]));   // 'c-cedilla'

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
          B([$F0, $9F, $98, $80]), True);
  PairKey('a high half with nothing waiting is U+FFFD', #$D83D, False, #0, Fffd, False);
  PairKey('a high half before a plain key is U+FFFD, and the key is left',
          #$D83D, True, 'q', Fffd, False);
  PairKey('a plain key never takes the event after it', 'q', True, #$DE00, 'q', False);
  Key('a high half alone is U+FFFD, not nothing', #$D83D, 0, Fffd);
  Key('and so is a low half alone', #$DE00, 0, Fffd);
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
  EventKey('the Alt key-up carries the composed character', False, #$00E9, $12, $38, 0, B([$C3, $A9]));
  EventKey('an Alt key-up with no character is not a key', False, #0, $12, $38, 0, '');
  EventKey('any other key-up is not a key', False, 'a', $41, $1E, 0, '');
  {$ENDIF}

  // ======== THE UNIX KEYBOARD, on every system ===============================

  // ---- where one key ends (CrtAssembleKey) ----
  // A NORMAL KEY IS ONE BYTE, and nothing after it is part of it.
  Assemble('a printable key is its own byte', T('qz'), False, T('q'), 1, 0);
  // A UTF-8 CHARACTER IS ONE KEY: its lead and exactly its continuations.
  Assemble('an accented character is whole', B([$C3, $A9, Ord('q')]), False, B([$C3, $A9]), 2, 0);
  Assemble('and a three-byte one', B([$E2, $82, $AC]), False, B([$E2, $82, $AC]), 3, 0);
  Assemble('and a four-byte one', B([$F0, $9F, $92, $A1, $F0]), False, B([$F0, $9F, $92, $A1]), 4, 0);
  // WHAT IS NOT A CHARACTER IS U+FFFD, one per maximal ill-formed subpart (the
  // Unicode Standard 3.9, Table 3-7), and the byte that broke it is the NEXT
  // key's: it is not taken.
  Assemble('C3 then X: U+FFFD for the C3 alone', B([$C3, Ord('X')]), False, Fffd, 1, 0);
  Assemble('a continuation byte first is U+FFFD', B([$80, Ord('X')]), False, Fffd, 1, 0);
  Assemble('a Latin-1 e-acute (E9) before a q is U+FFFD', B([$E9, Ord('q')]), False, Fffd, 1, 0);
  Assemble('an overlong lead (E0 80) is U+FFFD at the lead', B([$E0, $80]), False, Fffd, 1, 0);
  Assemble('a surrogate (ED A0 80) is U+FFFD at the lead', B([$ED, $A0, $80]), False, Fffd, 1, 0);
  Assemble('past U+10FFFF (F4 90) is U+FFFD at the lead', B([$F4, $90, $80, $80]), False, Fffd, 1, 0);
  Assemble('C0 begins nothing, even before a continuation', B([$C0, $A9]), False, Fffd, 1, 0);
  Assemble('F4 8F BF BF, U+10FFFF, is whole', B([$F4, $8F, $BF, $BF]), False,
           B([$F4, $8F, $BF, $BF]), 4, 0);
  // A CHARACTER NOT ALL HERE YET is waited for -- and when nothing more is
  // coming, it is ONE U+FFFD, its arrived part taken with it.
  Assemble('a lead and part of its character: wait for the rest',
           B([$F0, $9F]), False, '', 0, CRT_UTF8_WAIT_MS);
  Assemble('and with nothing more coming, one U+FFFD for both bytes',
           B([$F0, $9F]), True, Fffd, 2, 0);
  Assemble('a lone lead with nothing more coming', B([$C3]), True, Fffd, 1, 0);

  // AN ESCAPE SEQUENCE ENDS AT ITS FINAL BYTE (round 9). It used to be ESC and
  // EVERY byte already waiting, so the keys queued behind an arrow were part of it.
  Assemble('an arrow is ESC [ A, and not what follows it',
           J(B(CSI_UP), T('q')), False, B(CSI_UP), 3, 0);
  Assemble('three arrows queued: the first is three bytes',
           J(J(B(CSI_UP), B(CSI_UP)), B(CSI_UP)), False, B(CSI_UP), 3, 0);
  Assemble('a modified key: ESC [ 1 ; 5 C is one key',
           J(B([ESC]), T('[1;5Cq')), False, J(B([ESC]), T('[1;5C')), 6, 0);
  Assemble('ESC [ 2 0 0 ~ is one key', J(B([ESC]), T('[200~x')), False, J(B([ESC]), T('[200~')), 6, 0);
  Assemble('SS3: ESC O P is F1', J(B([ESC]), T('OPq')), False, J(B([ESC]), T('OP')), 3, 0);
  Assemble('the Linux console''s F1: ESC [ [ A', J(B([ESC]), T('[[Aq')), False,
           J(B([ESC]), T('[[A')), 4, 0);
  // ESCAPE ON ITS OWN, and the next key is the next key.
  Assemble('ESC then q is Escape, and q is left', J(B([ESC]), T('qr')), False, B([ESC]), 1, 0);
  Assemble('ESC then ESC: the first Escape alone', B([ESC, ESC, Ord('['), Ord('A')]), False,
           B([ESC]), 1, 0);
  Assemble('ESC O and a digit is no SS3: Escape alone', J(B([ESC]), T('O1')), False, B([ESC]), 1, 0);
  Assemble('a sequence broken by ESC is Escape alone', J(B([ESC, Ord('['), ESC]), T('[A')), False,
           B([ESC]), 1, 0);
  Assemble('a sequence broken by a UTF-8 byte is Escape alone', B([ESC, Ord('['), $C3, $A9]), False,
           B([ESC]), 1, 0);
  // NOT ALL HERE YET: ESC, ESC [, ESC [ 1 ; and ESC O wait for the rest; with
  // nothing more coming, each is Escape alone.
  Assemble('a lone ESC waits', B([ESC]), False, '', 0, CRT_ESC_WAIT_MS);
  Assemble('and alone for good is Escape', B([ESC]), True, B([ESC]), 1, 0);
  Assemble('ESC [ waits', B([ESC, Ord('[')]), False, '', 0, CRT_ESC_WAIT_MS);
  Assemble('ESC [ 1 ; waits', J(B([ESC]), T('[1;')), False, '', 0, CRT_ESC_WAIT_MS);
  Assemble('and cut off for good is Escape alone', J(B([ESC]), T('[1;')), True, B([ESC]), 1, 0);
  Assemble('ESC O waits', B([ESC, Ord('O')]), False, '', 0, CRT_ESC_WAIT_MS);
  Assemble('ESC [ [ waits', B([ESC, Ord('['), Ord('[')]), False, '', 0, CRT_ESC_WAIT_MS);
  // A SEQUENCE THAT NEVER ENDS is not waited on forever: past CRT_SEQ_MAX bytes
  // it is Escape alone.
  Long := B([ESC, Ord('[')]);
  for i := 1 to CRT_SEQ_MAX do Long := J(Long, T('1'));
  Assemble('a sequence longer than CRT_SEQ_MAX is Escape alone', Long, False, B([ESC]), 1, 0);
  Assemble('nothing buffered is no key', '', False, '', 0, 0);

  // THE TAG, for the same reason as the Windows side: the engine's strings are
  // UTF-8, and a key tagged with the system code page is converted on the way in.
  Report(StringCodePage(CrtAssembleKey(B([$C3, $A9]), False, taken, wait)) = CP_UTF8,
         'the key is tagged with the engine code page');
  Report(Length(ValStr(CrtAssembleKey(B([$C3, $A9]), False, taken, wait)).Str) = 2,
         'and is still two bytes after crossing into a TValue');
  Report(Length(ValStr(CrtAssembleKey(B([$EF, $BF, $BD]), False, taken, wait)).Str) = 3,
         'and so is U+FFFD');

  // ---- the reader: keys typed while the program was busy (round 9) ----
  // All already queued when the program reads: ONE key per read, as Windows
  // answers them (it answered three arrows as one, and Esc q r as one).
  Script; At(0, J(J(B(CSI_UP), B(CSI_UP)), B(CSI_UP)));
  ReadKey('a held arrow, queued: the first press', True, B(CSI_UP));
  ReadKey('the second', True, B(CSI_UP));
  ReadKey('the third', True, B(CSI_UP));
  ReadKey('and then the input has ended: getkey$ answers ""', True, '');
  Script; At(0, J(B([ESC]), T('qr')));
  ReadKey('Esc, q and r queued: Escape', True, B([ESC]));
  ReadKey('then q', True, T('q'));
  ReadKey('then r', True, T('r'));
  Script; At(0, J(J(B(CSI_UP), B([ESC, Ord('['), Ord('B')])), T('q')));
  ReadKey('up, down and q in one burst: up', True, B(CSI_UP));
  ReadKey('down', True, B([ESC, Ord('['), Ord('B')]));
  ReadKey('q -- which the program would otherwise wait for forever', True, T('q'));

  // ---- a key whose bytes arrive in two reads: getkey$ waits for the rest ----
  Script; At(0, B([ESC])); At(20, T('[A')); At(30, T('q'));
  ReadKey('ESC, then [A 20 ms later: one arrow', True, B(CSI_UP));
  Report(FakeNow = 20, 'read the moment its last byte came (at ' + IntToStr(FakeNow) + ' ms)');
  ReadKey('and q is the next key', True, T('q'));
  Script; At(0, B([$C3])); At(10, B([$A9])); At(20, T('q'));
  ReadKey('C3, then A9 10 ms later: one e-acute', True, B([$C3, $A9]));
  ReadKey('and q after it', True, T('q'));
  Script; At(0, B([$F0, $9F])); At(10, B([$98, $80]));
  ReadKey('an emoji in two reads is one key', True, B([$F0, $9F, $98, $80]));
  // Escape on its own is decided when its wait runs out, CRT_ESC_WAIT_MS after
  // it arrived, and not before.
  Script; At(0, B([ESC])); At(1000, T('q'));
  ReadKey('a lone Escape', True, B([ESC]));
  Report(FakeNow = CRT_ESC_WAIT_MS, 'decided after CRT_ESC_WAIT_MS (at ' + IntToStr(FakeNow) + ' ms)');
  ReadKey('and the q a second later is its own key', True, T('q'));
  // A character whose rest never comes: U+FFFD after CRT_UTF8_WAIT_MS, and
  // the keys after it are theirs.
  Script; At(0, B([$F0, $9F])); At(600, T('qr'));
  ReadKey('a cut-off character is U+FFFD', True, Fffd);
  Report(FakeNow = CRT_UTF8_WAIT_MS, 'decided after CRT_UTF8_WAIT_MS (at ' + IntToStr(FakeNow) + ' ms)');
  ReadKey('then q', True, T('q'));
  ReadKey('then r', True, T('r'));
  // The input ends in the middle of a sequence: what is there is decided.
  Script; At(0, B([ESC, Ord('[')]));
  ReadKey('ESC [ and then the end: Escape', True, B([ESC]));
  ReadKey('then [', True, T('['));
  ReadKey('then nothing', True, '');

  // ---- inkey$ NEVER WAITS, and keypressed() agrees with it ----
  Script; At(0, B([ESC])); At(20, T('[A'));
  ReadKey('inkey$ with half an arrow there: "" -- no whole key yet', False, '');
  Report(FakeNow = 0, 'and it did not wait (clock at ' + IntToStr(FakeNow) + ' ms)');
  Report(not CrtReaderReady(R), 'keypressed() says no key either');
  FakeNow := 20;
  ReadKey('the rest arrives: inkey$ answers the arrow', False, B(CSI_UP));
  Script; At(0, B([ESC]));
  ReadKey('a lone Escape, just arrived: inkey$ says ""', False, '');
  FakeNow := CRT_ESC_WAIT_MS - 1;
  Report(not CrtReaderReady(R), 'keypressed() is 0 until its wait has run out');
  FakeNow := CRT_ESC_WAIT_MS;
  Report(CrtReaderReady(R), 'and 1 once it has');
  ReadKey('then inkey$ answers Escape', False, B([ESC]));
  ReadKey('and nothing after it', False, '');
  Script; At(0, J(B(CSI_UP), T('q')));
  Report(CrtReaderReady(R), 'a whole arrow waiting: keypressed() is 1');
  ReadKey('inkey$ answers it', False, B(CSI_UP));
  ReadKey('and q', False, T('q'));
  Report(not CrtReaderReady(R), 'then nothing waits');

  // ---- the line reader's bytes: the buffered ones first ----
  Script; At(0, T('ab')); At(5, T('c'));
  Report(CrtReaderKey(R, True) = 'a', 'a key function takes the first key');
  Report(CrtReaderByte(R, Bt) and (Bt = Ord('b')), 'the line reader the byte after it');
  Report(CrtReaderByte(R, Bt) and (Bt = Ord('c')), 'and then the terminal''s');
  Report(not CrtReaderByte(R, Bt), 'and false at the end of input');

  // ---- a line typed ahead, edited as the line discipline edits (round 9) ----
  // Expected from Linux's n_tty (drivers/tty/n_tty.c): ECHOE rubs out a
  // character as BS SP BS; a control character under ECHOCTL is shown ^X and
  // takes two; the kill character under ECHOKE rubs out the line; word erase
  // takes trailing non-alphanumerics, then alphanumerics; end of file on an
  // empty line ends input; the Enter is not in the line and echoes a newline.
  Sane := CrtSaneEditKeys();
  Rub := B([8, 32, 8]);
  Edit('helo DEL lo Enter is hello -- the round-9 repro', J(T('helo'), J(B([$7F]), J(T('lo'), B([13])))),
       Sane, cesLine, T('hello'), J(J(T('helo'), Rub), J(T('lo'), B([10]))));
  Edit('a line feed ends it too', J(T('ok'), B([10])), Sane, cesLine, T('ok'), J(T('ok'), B([10])));
  Edit('the kill character rubs the line out', J(T('abc'), J(B([$15]), J(T('x'), B([13])))),
       Sane, cesLine, T('x'), J(J(T('abc'), J(Rub, J(Rub, Rub))), J(T('x'), B([10]))));
  Edit('word erase takes the trailing blanks, then the word', J(T('foo bar  '), B([$17])),
       Sane, cesMore, T('foo '), J(T('foo bar  '), J(Rub, J(Rub, J(Rub, J(Rub, Rub))))));
  Edit('and stops at what is not alphanumeric', J(T('foo-bar'), B([$17])),
       Sane, cesMore, T('foo-'), J(T('foo-bar'), J(Rub, J(Rub, Rub))));
  Edit('Ctrl+D on an empty line is the end of input', B([4]), Sane, cesEnd, '', '');
  Edit('Ctrl+D on a line with text is not', J(T('a'), B([4])), Sane, cesMore, T('a'), T('a'));
  Edit('erase takes a whole UTF-8 character, one rub-out', B([$C3, $A9, $7F]), Sane, cesMore, '',
       J(B([$C3, $A9]), Rub));
  Edit('a control character shows as ^[ and takes two rub-outs', B([ESC, $7F]), Sane, cesMore, '',
       J(T('^['), J(Rub, Rub)));
  Edit('literal-next makes the kill character text', B([$16, $15]), Sane, cesMore, B([$15]),
       J(B([Ord('^'), 8]), T('^U')));
  Edit('erase on an empty line shows nothing', B([$7F]), Sane, cesMore, '', '');
  K := Sane; K.EchoOn := False;
  Edit('without echo the line is still edited, and nothing shows',
       J(T('helo'), J(B([$7F]), J(T('lo'), B([13])))), K, cesLine, T('hello'), '');
  K := Sane; K.EchoErase := False;
  Edit('without ECHOE erase shows the erase character', J(T('ab'), B([$7F])), K, cesMore, T('a'),
       J(T('ab'), T('^?')));
  K := Sane; K.EchoKillErase := False;
  Edit('without ECHOKE kill shows ^U and a newline (ECHOK)', J(T('ab'), B([$15])), K, cesMore, '',
       J(T('ab'), J(T('^U'), B([10]))));
  K := Sane; K.CrIsNl := False;
  Edit('without ICRNL a CR is a character, and LF ends the line', J(T('a'), B([13, 10])), K, cesLine,
       J(T('a'), B([13])), J(T('a'), J(T('^M'), B([10]))));
  K := Sane; K.IgnoreCr := True;
  Edit('with IGNCR a CR is dropped', J(T('a'), B([13, 10])), K, cesLine, T('a'), J(T('a'), B([10])));
  K := Sane; K.KWErase := -1;
  Edit('a switched-off key is a character', J(T('a'), B([$17])), K, cesMore, B([Ord('a'), $17]),
       J(T('a'), T('^W')));
  Edit('a tab erased at the start goes back eight columns', B([9, $7F]), Sane, cesMore, '',
       B([9, 8, 8, 8, 8, 8, 8, 8, 8]));

  if ProveFail then
    Report(False, 'deliberate failure (--fail)');

  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed > 0 then Halt(1) else Halt(0);
end.
