{******************************************************************************
  Phosphor BASIC -- CRT / console control (an OPT-IN host package)

  MIT License. Copyright (c) 2026 Andre Murta.

  Classic-BASIC screen control for a terminal: clear, cursor positioning, colour,
  text attributes, and key input. An opt-in package (host/packages/, RegisterCrtFuncs)
  -- terminal control is host-specific, so it stays OUT of the host-agnostic engine.

  OUTPUT is done the host-agnostic way: the screen-control functions RETURN the ANSI
  escape sequence, and the program emits it with `print` (which, unlike `println`,
  adds no newline). So a control string composes with ordinary output:

      print cls$();
      print at$(3, 10); color$(11); "Hello"; reset$();
      println

  That keeps the engine's single output seam (OnOutput) the only way anything reaches
  the terminal, and makes every sequence byte-exact testable by its return value.
  ANSI is understood by Unix terminals and by the Windows console once VT processing
  is on -- call crt_init() once at startup to enable it (a no-op elsewhere).

    Screen : cls$()  clreol$()  clreos$()
    Cursor : home$()  at$(row,col)  moveup$(n) movedown$(n) moveleft$(n) moveright$(n)
             hidecursor$()  showcursor$()  savepos$()  restorepos$()
    Attrs  : reset$()  bold$()  faint$()  italic$()  underline$()  blink$()  inverse$()
    Colour : color$(fg)  color$(fg,bg)  bg$(bg)     -- 0..7 normal, 8..15 bright
             (0 black 1 red 2 green 3 yellow 4 blue 5 magenta 6 cyan 7 white)
    Input  : inkey$()  getkey$()  keypressed()      -- read the keyboard (raw mode)
    Setup  : crt_init()  crt_done()                 -- enable ANSI / restore terminal

  INPUT reads the keyboard directly (no FPC crt unit -- it hangs on a non-interactive
  stdin). It puts the terminal in raw/cbreak mode on first use -- keys arrive one at a
  time, unechoed -- via termios on Unix and the console API on Windows, and restores it
  at crt_done() or unit finalization. inkey$ is non-blocking ("" when nothing waits);
  getkey$ blocks for one key; keypressed() reports whether one is waiting. A normal key
  comes back as its character; an arrow / function key as chr$(0) followed by a code
  byte (a VK code on Windows, the raw escape sequence on Unix). When stdin is not a
  terminal (a pipe, a redirect) there is no keyboard, so inkey$/getkey$ return "" and
  keypressed() returns 0 without blocking.
******************************************************************************}
unit PhosphorCrtLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils,
  {$IFDEF WINDOWS}Windows,{$ELSE}BaseUnix, Unix, termio,{$ENDIF}
  PhosphorValue, PhosphorErrors, PhosphorRegistry;

procedure RegisterCrtFuncs(Reg: TPhosphorRegistry);

type
  { Where the rest of a multi-byte key comes from. False means nothing is waiting.
    A plain procedural type, not a method pointer: the unit hands it a reader that
    touches the terminal, the probe hands it a scripted array. }
  TCrtByteSource = function(out AByte: Byte): Boolean;

{$IFNDEF WINDOWS}
{ The Unix keyboard DECISION, lifted out of the keyboard I/O so it can be tested.
  A terminal hands over bytes; deciding where one KEY ends is the whole content of
  this path, and it is decided here, with no terminal in sight. Two shapes are
  more than one byte: an escape sequence (arrows, function keys) and a UTF-8
  character -- and the second was not handled at all, so a typed accented letter
  answered its first byte and left the rest for the next call, while Windows
  answered the whole character. }
function CrtAssembleKey(AFirst: Byte; ANext: TCrtByteSource): String;
{$ENDIF}

{$IFDEF WINDOWS}
{ The keyboard DECISION, lifted out of the keyboard I/O so it can be tested.
  Everything else on this path needs a real console -- a console handle, raw mode,
  a live keypress -- so the headless suite never ran a line of it, and a missing
  begin/end sat in it reporting every key as an extended one. This takes the two
  fields an INPUT_RECORD carries and answers what the key is; tests/probe_crt.lpr
  calls it with no console in sight. }
function CrtKeyFromEvent(AUnicodeChar: WideChar; AVirtualKey: Word): String;
{$ENDIF}

implementation

const
  ESC = #27;

function Csi(const ABody: String): String;
begin
  Result := ESC + '[' + ABody;
end;

function NArg(const V: TValue): Integer;
begin
  Result := ArgI32(V);
end;

{ ANSI SGR code for a colour index: 0..7 -> normal, 8..15 -> bright; anything else is
  the terminal default. }
function FgCode(AColor: Integer): Integer;
begin
  if (AColor >= 0) and (AColor <= 7) then Result := 30 + AColor
  else if (AColor >= 8) and (AColor <= 15) then Result := 90 + (AColor - 8)
  else Result := 39;
end;

function BgCode(AColor: Integer): Integer;
begin
  if (AColor >= 0) and (AColor <= 7) then Result := 40 + AColor
  else if (AColor >= 8) and (AColor <= 15) then Result := 100 + (AColor - 8)
  else Result := 49;
end;

{ ---- screen ---------------------------------------------------------------- }

function f_cls(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValStr(Csi('2J') + Csi('H'));   // clear all, cursor home
end;

function f_clreol(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValStr(Csi('K'));
end;

function f_clreos(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValStr(Csi('J'));
end;

{ ---- cursor ---------------------------------------------------------------- }

function f_home(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValStr(Csi('H'));
end;

function f_at(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();   // row;col are 1-based, like ANSI and like Phosphor's own indices
  Result := ValStr(Csi(IntToStr(NArg(Args[0])) + ';' + IntToStr(NArg(Args[1])) + 'H'));
end;

function f_moveup(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValStr(Csi(IntToStr(NArg(Args[0])) + 'A'));
end;

function f_movedown(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValStr(Csi(IntToStr(NArg(Args[0])) + 'B'));
end;

function f_moveright(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValStr(Csi(IntToStr(NArg(Args[0])) + 'C'));
end;

function f_moveleft(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValStr(Csi(IntToStr(NArg(Args[0])) + 'D'));
end;

function f_hidecursor(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValStr(Csi('?25l'));
end;

function f_showcursor(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValStr(Csi('?25h'));
end;

function f_savepos(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValStr(ESC + '7');
end;

function f_restorepos(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValStr(ESC + '8');
end;

{ ---- attributes ------------------------------------------------------------ }

function f_reset(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValStr(Csi('0m'));
end;

function f_bold(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValStr(Csi('1m'));
end;

function f_faint(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValStr(Csi('2m'));
end;

function f_italic(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValStr(Csi('3m'));
end;

function f_underline(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValStr(Csi('4m'));
end;

function f_blink(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValStr(Csi('5m'));
end;

function f_inverse(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValStr(Csi('7m'));
end;

{ ---- colour ---------------------------------------------------------------- }

function f_color1(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValStr(Csi(IntToStr(FgCode(NArg(Args[0]))) + 'm'));
end;

function f_color2(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValStr(Csi(IntToStr(FgCode(NArg(Args[0]))) + ';' +
                       IntToStr(BgCode(NArg(Args[1]))) + 'm'));
end;

function f_bg(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValStr(Csi(IntToStr(BgCode(NArg(Args[0]))) + 'm'));
end;

{ ---- keyboard input (raw mode; no crt unit) -------------------------------- }

{ There is a keyboard only when stdin is a real terminal. When it is a pipe/file
  (the headless test, a redirect) the key functions answer "no key" WITHOUT touching
  the terminal at all -- which is both correct and what keeps a non-interactive run
  from blocking. (FPC's crt unit is avoided precisely because it spins on such stdin.) }
function StdinIsInteractive: Boolean;
begin
  {$IFDEF WINDOWS}
  Result := GetFileType(GetStdHandle(STD_INPUT_HANDLE)) = FILE_TYPE_CHAR;
  {$ELSE}
  Result := IsATTY(StdInputHandle) = 1;
  {$ENDIF}
end;

{$IFDEF WINDOWS}
var
  gRawOn: Boolean = False;
  gOldMode: DWORD;

procedure KbdEnterRaw;
var h: THandle;
begin
  if gRawOn then Exit;
  h := GetStdHandle(STD_INPUT_HANDLE);
  if GetConsoleMode(h, gOldMode) then
  begin
    { raw: no line buffering, no echo -- keys arrive one at a time, unseen. }
    SetConsoleMode(h, gOldMode and not DWORD(ENABLE_LINE_INPUT or ENABLE_ECHO_INPUT));
    gRawOn := True;
  end;
end;

procedure KbdRestore;
begin
  if gRawOn then
  begin
    SetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), gOldMode);
    gRawOn := False;
  end;
end;

function CrtKeyFromEvent(AUnicodeChar: WideChar; AVirtualKey: Word): String;
begin
  if AUnicodeChar <> #0 then
    // A normal key: its character, as UTF-8 bytes.
    Result := UTF8Encode(WideString(AUnicodeChar))
  else
  begin
    // An arrow or function key: chr$(0) + the virtual-key code.
    // The begin/end is not decoration. Without it only SetLength belonged to the
    // else, and the two assignments below ran for EVERY key -- overwriting byte 1
    // of a printable key with #0 and writing byte 2 one past the end of a
    // one-byte string. Every key then read as extended, and 'q' never equalled
    // "q", so a demo that quits on 'q' could not be quit.
    // Built by index, not by concatenation: under this unit's UTF8 codepage a
    // virtual-key code >= 128 (F-keys and the OEM range) would otherwise be
    // re-encoded and the key misreported.
    SetLength(Result, 2);
    Result[1] := #0;
    Result[2] := Chr(Byte(AVirtualKey));
    // AND TAG IT. SetLength on an empty string stamps the SYSTEM code page (1252
    // here), not this unit's UTF-8, so the two bytes would be CONVERTED on their
    // way into the engine -- a virtual-key code of $BA arriving as $C2 $BA, a
    // two-byte key three bytes long, asc() answering 194. These two bytes are a
    // protocol, not text; re-tag without converting so they reach the program as
    // written. (The indexed writes above are the other half of the same rule: see
    // scripts/check-codepage.py.)
    SetCodePage(RawByteString(Result), CP_UTF8, False);
  end;
end;

function EventToKey(const ARec: INPUT_RECORD): String;
begin
  Result := '';
  if (ARec.EventType = KEY_EVENT) and (ARec.Event.KeyEvent.bKeyDown) then
    Result := CrtKeyFromEvent(ARec.Event.KeyEvent.UnicodeChar,
                              ARec.Event.KeyEvent.wVirtualKeyCode);
end;

function KbdKeyPressed: Boolean;
var h: THandle; recs: array[0..31] of INPUT_RECORD; navail, nread: DWORD; i: Integer;
begin
  Result := False;
  h := GetStdHandle(STD_INPUT_HANDLE);
  navail := 0;
  if (not GetNumberOfConsoleInputEvents(h, navail)) or (navail = 0) then Exit;
  nread := 0;
  if not PeekConsoleInputW(h, recs[0], Length(recs), nread) then Exit;
  for i := 0 to Integer(nread) - 1 do
    if (recs[i].EventType = KEY_EVENT) and recs[i].Event.KeyEvent.bKeyDown then
      Exit(True);
end;

function KbdRead(ABlock: Boolean): String;
var h: THandle; rec: INPUT_RECORD; navail, nread: DWORD;
begin
  Result := '';
  h := GetStdHandle(STD_INPUT_HANDLE);
  while True do
  begin
    if not ABlock then
    begin
      navail := 0;
      if (not GetNumberOfConsoleInputEvents(h, navail)) or (navail = 0) then Exit;
    end;
    nread := 0;
    if (not ReadConsoleInputW(h, rec, 1, nread)) or (nread = 0) then Exit;
    Result := EventToKey(rec);
    if Result <> '' then Exit;             // skip key-up / mouse / focus events
  end;
end;
{$ELSE}
var
  gRawOn: Boolean = False;
  gSavedTio: Termios;

procedure KbdEnterRaw;
var tio: Termios;
begin
  if gRawOn then Exit;
  if TCGetAttr(StdInputHandle, gSavedTio) <> 0 then Exit;
  tio := gSavedTio;
  { cbreak: characters delivered immediately and not echoed; signals (Ctrl+C) and
    output post-processing (so println newlines still translate) are left on. }
  tio.c_lflag := tio.c_lflag and not (ICANON or ECHO);
  tio.c_cc[VMIN] := 1;
  tio.c_cc[VTIME] := 0;
  if TCSetAttr(StdInputHandle, TCSANOW, tio) = 0 then gRawOn := True;
end;

procedure KbdRestore;
begin
  if gRawOn then
  begin
    TCSetAttr(StdInputHandle, TCSANOW, gSavedTio);
    gRawOn := False;
  end;
end;

function ByteWaiting: Boolean;
var fds: TFDSet; tv: TTimeVal;
begin
  fpFD_ZERO(fds);
  fpFD_SET(StdInputHandle, fds);
  tv.tv_sec := 0; tv.tv_usec := 0;
  Result := fpSelect(StdInputHandle + 1, @fds, nil, nil, @tv) > 0;
end;

function ReadRawByte(out AByte: Byte): Boolean;
var c: Char;
begin
  { FileRead (SysUtils), not fpRead: fpRead is `inline` and FPC declines to inline it
    here, which -vewn reports as a note. FileRead is a plain function wrapping the same
    read, so the RTL owns that call and our unit stays note-clean.
    A BYTE, not a Char-into-String: assigning a Char to a String in this unit
    re-encodes it under {$codepage UTF8}, so every byte >= 128 a terminal sent --
    the second half of every accented character -- arrived as something else. }
  AByte := 0;
  Result := FileRead(StdInputHandle, c, 1) = 1;
  if Result then AByte := Byte(c);
end;

function NextWaitingByte(out AByte: Byte): Boolean;
begin
  AByte := 0;
  if not ByteWaiting() then Exit(False);
  Result := ReadRawByte(AByte);
end;

{ How many bytes follow this UTF-8 lead byte. 0 for ASCII and for anything that is
  not a lead byte -- a continuation byte arriving first is a broken stream, and
  guessing a length for it would consume bytes belonging to the next key. }
function Utf8Extra(AFirst: Byte): Integer;
begin
  if AFirst < $80 then Result := 0
  else if (AFirst >= $C0) and (AFirst <= $DF) then Result := 1
  else if (AFirst >= $E0) and (AFirst <= $EF) then Result := 2
  else if (AFirst >= $F0) and (AFirst <= $F7) then Result := 3
  else Result := 0;
end;

function CrtAssembleKey(AFirst: Byte; ANext: TCrtByteSource): String;
var b: Byte; want, i, n: Integer;
begin
  // Built by index and tagged, never by concatenating a Char: under this unit's
  // UTF8 codepage that re-encodes every byte >= 128, and these bytes are a key,
  // not text to be converted.
  SetLength(Result, 1);
  Result[1] := Chr(AFirst);
  if AFirst = 27 then
  begin
    // An escape sequence: take whatever is ALREADY waiting. Nothing waiting means
    // the user pressed Escape itself, which is a key on its own.
    while ANext(b) do
    begin
      n := Length(Result) + 1;
      SetLength(Result, n);
      Result[n] := Chr(b);
    end;
  end
  else
  begin
    // A UTF-8 character: take exactly its continuation bytes, no more. Stopping
    // at the first byte that is not a continuation leaves the stream where the
    // next key begins instead of eating it.
    want := Utf8Extra(AFirst);
    for i := 1 to want do
    begin
      if not ANext(b) then Break;
      if (b < $80) or (b > $BF) then Break;
      n := Length(Result) + 1;
      SetLength(Result, n);
      Result[n] := Chr(b);
    end;
  end;
  SetCodePage(RawByteString(Result), CP_UTF8, False);
end;

function KbdKeyPressed: Boolean;
begin
  Result := ByteWaiting();
end;

function KbdRead(ABlock: Boolean): String;
var first: Byte;
begin
  Result := '';
  if (not ABlock) and (not ByteWaiting()) then Exit;
  if not ReadRawByte(first) then Exit;
  Result := CrtAssembleKey(first, @NextWaitingByte);
end;
{$ENDIF}

function f_inkey(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if not StdinIsInteractive() then Exit(ValStr(''));
  KbdEnterRaw();
  Result := ValStr(KbdRead(False));
end;

function f_getkey(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if not StdinIsInteractive() then Exit(ValStr(''));   // no terminal -> nothing to wait for
  KbdEnterRaw();
  Result := ValStr(KbdRead(True));
end;

function f_keypressed(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if not StdinIsInteractive() then Exit(ValInt(0));
  KbdEnterRaw();
  Result := ValInt(Ord(KbdKeyPressed()));
end;

{ crt_done() -- put the terminal back the way it was (undo raw mode). A backstop also
  runs at unit finalization, but interactive programs should call this before exit. }
function f_crt_done(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  KbdRestore();
  // A NUMBER. The name carries no suffix and the reference says "-> num", but this
  // returned a string, so `x = crt_done()` failed with "cannot store string into
  // number variable" -- the documented shutdown call could not have its result
  // captured the way crt_init's can.
  Result := ValInt(0);
end;

{ ---- setup ----------------------------------------------------------------- }

{ Enable ANSI/VT escape processing so the sequences render. On Windows 10+ the console
  needs ENABLE_VIRTUAL_TERMINAL_PROCESSING turned on; elsewhere ANSI already works.
  Returns 1 if VT output is available, 0 if it could not be enabled. }
function f_crt_init(const Args: array of TValue; out Err: TPhosphorError): TValue;
{$IFDEF WINDOWS}
const
  ENABLE_VT = $0004;   // ENABLE_VIRTUAL_TERMINAL_PROCESSING
var
  h: THandle;
  mode: DWORD;
begin
  Err := NoError();
  Result := ValInt(0);
  h := GetStdHandle(STD_OUTPUT_HANDLE);
  if (h <> INVALID_HANDLE_VALUE) and GetConsoleMode(h, mode) then
    if SetConsoleMode(h, mode or ENABLE_VT) then
      Result := ValInt(1);
end;
{$ELSE}
begin
  Err := NoError(); Result := ValInt(1);   // ANSI already understood
end;
{$ENDIF}

procedure RegisterCrtFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('cls$:',          @f_cls);
  Reg.Add('clreol$:',       @f_clreol);
  Reg.Add('clreos$:',       @f_clreos);
  Reg.Add('home$:',         @f_home);
  Reg.Add('at$:nn',         @f_at);
  Reg.Add('moveup$:n',      @f_moveup);
  Reg.Add('movedown$:n',    @f_movedown);
  Reg.Add('moveright$:n',   @f_moveright);
  Reg.Add('moveleft$:n',    @f_moveleft);
  Reg.Add('hidecursor$:',   @f_hidecursor);
  Reg.Add('showcursor$:',   @f_showcursor);
  Reg.Add('savepos$:',      @f_savepos);
  Reg.Add('restorepos$:',   @f_restorepos);
  Reg.Add('reset$:',        @f_reset);
  Reg.Add('bold$:',         @f_bold);
  Reg.Add('faint$:',        @f_faint);
  Reg.Add('italic$:',       @f_italic);
  Reg.Add('underline$:',    @f_underline);
  Reg.Add('blink$:',        @f_blink);
  Reg.Add('inverse$:',      @f_inverse);
  Reg.Add('color$:n',       @f_color1);
  Reg.Add('color$:nn',      @f_color2);
  Reg.Add('bg$:n',          @f_bg);
  Reg.Add('inkey$:',        @f_inkey);
  Reg.Add('getkey$:',       @f_getkey);
  Reg.Add('keypressed:',    @f_keypressed);
  Reg.Add('crt_init:',      @f_crt_init);
  Reg.Add('crt_done:',      @f_crt_done);
end;

finalization
  { Never leave the user's terminal in raw mode, even if the program forgot crt_done. }
  KbdRestore();

end.
