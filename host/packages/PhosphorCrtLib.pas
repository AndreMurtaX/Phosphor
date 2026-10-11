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
  getkey$ blocks for one key; keypressed() reports whether one is waiting -- the three
  read ONE queue, so keypressed() = 1 means inkey$ answers a key. A normal key
  comes back as its character (a whole UTF-8 one; what is not a character is U+FFFD);
  an arrow / function key as chr$(0) followed by a code byte (a VK code on Windows,
  the raw escape sequence on Unix). A modifier or lock key alone is not a key, a
  held key's repeats are each a key, and Alt+numpad entry is its composed character
  (CrtEventKey has the model). INPUT reads a line in LINE mode even while raw mode
  is on (CrtLineModeBegin). When stdin is not a
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
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorStdIO
  {$IFDEF WINDOWS}, PhosphorSysLib{$ENDIF};

procedure RegisterCrtFuncs(Reg: TPhosphorRegistry);

{ Hide / show the console window THIS PROCESS OWNS, answering whether there was
  one to act on. A console shared with a terminal is never touched. Public
  because the host offers the same thing as a startup flag (--no-console), and
  the two must not become two implementations of one rule. Always False on Unix,
  where the terminal belongs to the user rather than to the program. }
function CrtHideOwnConsole: Boolean;
function CrtShowOwnConsole: Boolean;

{ ---- THE UNIX KEYBOARD, as decisions with no terminal in them ---------------
  Compiled on EVERY system, although only the Unix reader uses it, so that
  tests/probe_crt.lpr runs it on both: a decision only one machine can test is
  a decision half the test runs never see. }

const
  { How long the rest of a key is waited for, from the moment its last byte
    arrived. An escape sequence: 100 ms, vim's ttimeoutlen in defaults.vim --
    long enough for a terminal or an ssh link that delivers ESC and its '[A'
    in two reads, short enough that Escape pressed on its own still feels like
    a key. A UTF-8 character: 500 ms, the bound Windows gives the second half
    of a surrogate pair (PAIR_WAIT_MS), and only ever spent on a lead byte
    whose continuation never comes, which no UTF-8 keyboard sends. }
  CRT_ESC_WAIT_MS = 100;
  CRT_UTF8_WAIT_MS = 500;
  { The longest escape sequence taken as one key. Real keys are under a dozen
    bytes (ESC [ 1 ; 5 ~ is six); a stream that never reaches its final byte is
    not a key, and is not waited on forever. }
  CRT_SEQ_MAX = 32;
  { termios' IUTF8 flag (c_iflag). FPC 3.2.2's termio unit declares it for some
    targets and not for x86_64-linux, where the build failed on it (round 10,
    found by the first Linux compile); the value is the kernel's, octal 0040000
    (include/uapi/asm-generic/termbits.h), which macOS and the BSDs share. }
  CRT_IUTF8 = &0040000;

{ WHERE ONE KEY ENDS, given the bytes a terminal has handed over (round 9,
  2026-10-11). ABytes is what is buffered, the next key first. Answers the key
  and ATaken, how many bytes of ABytes it is; ATaken = 0 means the bytes so far
  are the START of a key whose rest has not arrived, and AWaitMs is how long
  to wait for it (CRT_ESC_WAIT_MS or CRT_UTF8_WAIT_MS). AFinal says nothing
  more is coming: the key is then decided from what there is. The grammar:
    * ESC '[' parameters (30..3F) intermediates (20..2F) and ONE final byte
      (40..7E) -- a control sequence, ECMA-48 5.4 -- is one key: an arrow, a
      function key, Home, a modified key. So is ESC '[' '[' and one letter, the
      Linux console's F1..F5;
    * ESC 'O' and one byte 40..7E (SS3, ECMA-48 8.3.125) is one key: an arrow
      in application mode, F1..F4;
    * ESC followed by anything else, or by a sequence that never reaches its
      final byte, is Escape ON ITS OWN, and what follows is the next key;
    * a UTF-8 lead byte and exactly its continuation bytes are one key, and
      what is not well-formed UTF-8 is U+FFFD, one per maximal ill-formed
      subpart (the Unicode Standard 3.9, Table 3-7);
    * any other byte is a key by itself (a letter, Enter, a Ctrl chord).
  Until round 9 the ESC branch took EVERY byte already waiting, so three
  arrow presses made while the program was busy were one key, and Escape, 'q'
  and 'r' were one key; and nothing waited for the rest of a key, so an arrow
  or a character split across two reads was several keys. }
function CrtAssembleKey(const ABytes: RawByteString; AFinal: Boolean;
                        out ATaken, AWaitMs: Integer): String; overload;
{ The same, of the bytes of ABytes from AFrom on, without copying them: the
  reader's queue answers a key from where its front is. }
function CrtAssembleKey(const ABytes: RawByteString; AFrom: Integer; AFinal: Boolean;
                        out ATaken, AWaitMs: Integer): String; overload;

type
  { How a reader gets bytes: wait up to AWaitMs ms (0 polls, -1 waits for as
    long as it takes) for whatever arrives, and APPEND it to ABuf. Answers how
    many bytes arrived, 0 for none in that time, -1 when the input has ended.
    The terminal on Unix; a script with its own clock in the probe. }
  TCrtFill = function(var ABuf: RawByteString; AWaitMs: Integer): Integer;
  TCrtClock = function: QWord;
  { THE ONE QUEUE getkey$, inkey$, keypressed() and the line reader share:
    the bytes read from the terminal and not answered yet -- Buf from Head + 1
    on; what is in front of that was answered -- and when the last of them
    arrived.
    A KEY COSTS THE SAME HOWEVER MUCH IS QUEUED (round 10, 2026-10-11). Each
    answered key was cut off the front of Buf with Delete, which moves
    everything behind it, and every read first took up to 4096 more bytes from
    the terminal, so a paste grew the queue to its whole length: a megabyte
    pasted into a getkey$ loop took 21 s, two took 77. The front is now an
    index (Head), the answered bytes are dropped only when they are at least
    as many as the ones still waiting (so each byte is moved at most once on
    average; Moved counts them, for tests/probe_crt.lpr), and the terminal is
    read only when fewer than CRT_SEQ_MAX bytes wait -- with that many, any
    key is already decidable (CrtAssembleKey). }
  TCrtKeyReader = record
    Buf: RawByteString;
    Head: Integer;
    Moved: QWord;
    Arrived: QWord;
    Fill: TCrtFill;
    Clock: TCrtClock;
  end;

{ An empty queue that reads through AFill on AClock. }
procedure CrtReaderInit(out R: TCrtKeyReader; AFill: TCrtFill; AClock: TCrtClock);
{ How many bytes wait in R, read and not answered. }
function CrtReaderPending(const R: TCrtKeyReader): Integer;

{ The next key, taken from R. ABlock (getkey$) waits for one; otherwise
  (inkey$) it answers '' when no WHOLE key is there yet -- including the start
  of one whose rest may still be coming, which is left where it is, so inkey$
  never waits. A key still incomplete once its wait has run out is decided as
  it stands (CrtAssembleKey's AFinal). '' with ABlock: the input has ended. }
function CrtReaderKey(var R: TCrtKeyReader; ABlock: Boolean): String;
{ keypressed(): would CrtReaderKey(R, False) answer a key? }
function CrtReaderReady(var R: TCrtKeyReader): Boolean;
{ One byte for the line reader, the buffered ones first; waits for the
  terminal when there are none. False when the input has ended. }
function CrtReaderByte(var R: TCrtKeyReader; out AByte: Byte): Boolean;

type
  { The editing a terminal's line discipline does, as the termios it was in
    when the program found it says: the characters (-1 for one switched off)
    and the echo flags. Linux's n_tty is the definition (drivers/tty/n_tty.c,
    eraser() and n_tty_receive_char_special()). }
  { ALL OF THE TERMINAL'S SETTINGS THAT DECIDE AN EDIT (round 10, 2026-10-11):
    Canon is ICANON -- off, the line discipline edits nothing, and every key
    but the line's end is a character; Utf8 is IUTF8 -- off, a character is a
    byte, and erase takes one; EchoNl is ECHONL, NlIsCr INLCR. Round 9's
    editor read neither ICANON nor IUTF8, so with `stty -icanon` DEL still
    erased, and with `stty -iutf8` erase still took a whole UTF-8 character:
    the same keys answered one line typed ahead and another typed live. }
  TCrtEditKeys = record
    KErase, KWErase, KKill, KEof, KLNext: Integer;
    EchoOn, EchoErase, EchoKill, EchoKillErase, EchoCtl, EchoNl: Boolean;
    CrIsNl, IgnoreCr, NlIsCr, Canon, Utf8: Boolean;
  end;
  TCrtEditStep = (cesMore, cesLine, cesEnd);
  { A line being edited: the line so far, whether the last byte was
    literal-next, the terminal's column as n_tty counts it (ldata->column),
    and the column the line's first character went to (canon_column) -- a
    Tab is rubbed out by the columns it took FROM THERE. }
  TCrtEditState = record
    Line: String;
    Literal: Boolean;
    Column, CanonColumn: Integer;
  end;

{ A terminal in the state `stty sane` leaves it, with IUTF8 as a UTF-8
  terminal sets it: canonical; erase DEL, kill Ctrl+U, word erase Ctrl+W, end
  of file Ctrl+D, literal next Ctrl+V; echo, ECHOE, ECHOK, ECHOKE, ECHOCTL,
  ICRNL. }
function CrtSaneEditKeys: TCrtEditKeys;
{ An empty line, begun with the cursor at AColumn: where the prompt left it. }
procedure CrtEditStart(out S: TCrtEditState; AColumn: Integer);
{ ONE BYTE OF A LINE BEING EDITED, as the line discipline would edit it
  (round 9, 2026-10-11). Answers cesLine when AByte ended the line (the
  newline is not in it), cesEnd for end of file on an empty line, cesMore
  otherwise; AEcho is what the terminal shows for it -- the character, its
  ^X form, or the backspaces that rub out what was erased. This is how keys
  typed while a key function held the terminal raw are edited and shown when
  INPUT reads them: Linux's line discipline does NOT re-read bytes that
  arrived raw when canonical mode is turned back on, and handed them over as
  they were -- a DEL inside the line, and nothing on the screen. The
  definition is Linux's n_tty (drivers/tty/n_tty.c): eraser(),
  n_tty_receive_char_special() and _canon(), echo_char(), and the column
  counting of __process_echoes() and do_output_char(). ECHOPRT, EOL and EOL2
  are not modelled. }
function CrtEditLine(var S: TCrtEditState; AByte: Byte; const AKeys: TCrtEditKeys;
                     out AEcho: String): TCrtEditStep;
{ THE TERMINAL'S COLUMN after ABytes are written at column ACol, counted as
  n_tty's do_output_char() counts it under OPOST and ONLCR: a newline or a
  carriage return goes to 0, a Tab to the next multiple of 8, a backspace one
  back (never below 0), a control character nowhere, a UTF-8 continuation
  byte nowhere when AUtf8 (IUTF8), and every other byte one on -- the bytes
  of an escape sequence after its ESC included, as the kernel counts them. }
function CrtColumnAfter(ACol: Integer; const ABytes: RawByteString; AUtf8: Boolean): Integer;

{ WHAT A JOB-CONTROL SIGNAL DOES TO THE TERMINAL (round 10, 2026-10-11).
  Ctrl+Z stopped a program in getkey$ with the terminal raw: dash left it so
  while the shell prompted (the 'fg' typed there was not echoed), and bash
  put its own modes back and did not re-apply the job's on fg, so getkey$
  then waited for Enter, and the key came back echoed. The convention every
  raw-mode program keeps (vim, less, readline): on the stop signal put the
  program's own modes back (ctaRestore), on continuing apply raw mode again
  (ctaRaw) -- only while a key function owns raw mode, and only from the
  terminal's foreground: a background job that touches the terminal is
  stopped for it (SIGTTOU), and is continued again when brought forward. }
type
  TCrtTermAction = (ctaNone, ctaRestore, ctaRaw);
function CrtJobSignalAction(AStopping, ARawOn, AForeground: Boolean): TCrtTermAction;

{$IFNDEF WINDOWS}
{ The line reader's half of the Unix keyboard. After CrtLineModeBegin:
  CrtTypedAhead answers whether keys typed while the terminal was raw are
  held -- in which case the terminal was LEFT raw, and the host reads the line
  through CrtReadHeldByte and CrtEditLine, with CrtTerminalEditKeys, showing
  each echo with CrtEcho. Otherwise the terminal is in line mode and the
  host reads it as it always did. }
function CrtTypedAhead: Boolean;
function CrtReadHeldByte(out AByte: Byte): Boolean;
function CrtTerminalEditKeys: TCrtEditKeys;
procedure CrtEcho(const ABytes: String);
{ THE COLUMN THE TERMINAL IS AT, kept as n_tty keeps it (CrtColumnAfter), so
  a line typed ahead begins where INPUT's prompt ended (round 10). The host
  reports what it writes to the terminal with CrtNoteOutput, and the end of a
  line the line discipline read itself (its echo is never seen here) with
  CrtNoteLineEnded. Output this host did not write -- another process, or
  stderr -- is not counted. }
procedure CrtNoteOutput(const ABytes: String);
procedure CrtNoteLineEnded;
function CrtOutputColumn: Integer;
{$ENDIF}

{$IFDEF WINDOWS}
{ The keyboard DECISION, lifted out of the keyboard I/O so it can be tested.
  Everything else on this path needs a real console -- a console handle, raw mode,
  a live keypress -- so the headless suite never ran a line of it, and a missing
  begin/end sat in it reporting every key as an extended one. This takes the two
  fields an INPUT_RECORD carries and answers what the key is; tests/probe_crt.lpr
  calls it with no console in sight. }
function CrtKeyFromEvent(AUnicodeChar: WideChar; AVirtualKey: Word): String;
{ A CHARACTER OUTSIDE THE BMP IS TWO KEY EVENTS (round 7, 2026-10-11). An
  INPUT_RECORD carries ONE UTF-16 unit, so an emoji arrives as a high surrogate
  and then a low one. CrtKeyFromEvent converted each with UTF8Encode, which
  DROPS a lone surrogate (rtl/inc/ustrings.inc, UnicodeToUtf8): both halves
  answered '', KbdRead took '' for "not a key", and the keystroke vanished --
  the program read the NEXT key in its place, where Linux (CrtAssembleKey)
  answers the whole character. This is the pair decision: AFirst is the key
  event's character, ANext the character of the next key-down event when one
  is already waiting (AHaveNext). A high half followed by a low half is ONE
  key, its UTF-8 bytes, and AUsedNext says the second event belongs to it.
  Anything else is AFirst alone -- a lone half being U+FFFD, the answer
  WideToUtf8 gives for one -- and the next event is left for the next read. }
function CrtKeyFromPair(AFirst: WideChar; AHaveNext: Boolean; ANext: WideChar;
                        out AUsedNext: Boolean): String;
{ THE KEYBOARD MODEL, one event at a time (round 8, 2026-10-11). Which console
  events are KEYS, decided from the fields an INPUT_RECORD's key event carries,
  and answered as the key ('' for an event that is not one). The model is the
  one a Unix terminal already keeps, because a terminal sends bytes only for a
  key that means something:
    * a key-down with a character is that character;
    * a key-down with no character is chr(0) + its virtual-key code -- an arrow,
      a function key, Insert, Home and the rest;
    * a MODIFIER OR LOCK KEY ALONE IS NOT A KEY: Shift, Ctrl, Alt, the Windows
      keys, Caps/Num/Scroll Lock. Every capital letter typed on a real keyboard
      used to cost an extra key, chr(0) + chr(16), ahead of it;
    * a numpad digit typed while Alt is held is ALT+NUMPAD ENTRY, not a key: the
      console delivers the composed character on the ALT KEY-UP, and that key-up
      is the key. It used to answer chr(0)+chr(18) and chr(0)+chr(98) and never
      the character;
    * every other key-up is not a key.
  How many times a key-down counts (wRepeatCount) is the reader's business, not
  this function's: a key is a key once here. }
function CrtEventKey(AKeyDown: Boolean; AUnicodeChar: WideChar; AVirtualKey, AScanCode: Word;
                     AControlState: LongWord): String;
{$ENDIF}

{ INPUT AND THE KEY FUNCTIONS READ ONE KEYBOARD (round 8, 2026-10-11). Raw mode
  is a KEY reader's state, and it lasted from the first getkey$/inkey$/
  keypressed() until crt_done(), INPUT included: on Windows a line read with
  line input off answered whatever keys had arrived -- 'h', and the next INPUT
  'ello' -- and on Linux the line read took every byte waiting, keys typed
  after the Enter too, where no key function could see them again. A line is
  read in LINE mode: the host's line reader brackets its read with these two,
  which put the terminal back the way the program found it (echo, line
  editing, the line discipline stopping at the Enter) and then return it to raw
  mode. CrtLineModeBegin answers whether raw mode was on; pass that to
  CrtLineModeEnd. No-ops when no key function ran. On Unix it first takes
  everything the terminal holds while it is still raw, and when that is
  anything at all it leaves the terminal RAW: see CrtTypedAhead. }
function CrtLineModeBegin: Boolean;
procedure CrtLineModeEnd(AWasRaw: Boolean);
{$IFDEF WINDOWS}
{ Keys the key functions took from the console and have not answered yet: the
  rest of a key-down whose repeat count was more than one. They were typed
  BEFORE whatever the console still holds, so a line read takes them first.
  True when they hold a whole line -- a held Enter: APrefix is that (empty)
  line, and the other presses stay for the next reads. False otherwise:
  APrefix is the start of the line (possibly ''), and they are all taken; the
  host SHOWS it and hands it to the console's line editor as text already
  typed, so it can be erased like the rest. Which presses those are is
  CrtPressIsLineText's. }
function CrtTakePendingLine(out APrefix: String): Boolean;
{ IS A PRESS OF THIS KEY TEXT AT THE START OF A LINE? (round 10, 2026-10-11)
  As the console's own cooked read answers it -- measured, three taps of each
  character before 'x' Enter on Windows 11's conhost, and the same held with
  a repeat count: every character is kept in the line, Tab and the Ctrl
  chords (^A..^Z, ^\ ^] ^^ ^_) included, but Backspace or Ctrl+H (08),
  Ctrl+J (0A) and Escape (1B), which edit a line and at its start have
  nothing to edit. (Ctrl+S could not be measured -- the console would not
  queue its events -- and is kept like the other chords; Ctrl+C and Enter
  never get here: a signal, and an empty line of its own.) A key
  with no character -- an arrow, a function key, chr(0) and a code -- is not
  text: in a line it would MOVE or RECALL (Up and F3 bring back an earlier
  line), which a press that came before the line cannot be made to do, so it
  is dropped. Round 9 kept only presses from ' ' up, and a held Tab or Ctrl
  chord lost its unanswered presses. }
function CrtPressIsLineText(const AKey: String): Boolean;
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

{ ---- the Unix keyboard's decisions (compiled everywhere; see the interface) -- }

{ How many bytes follow this UTF-8 lead byte. 0 for ASCII and for anything that is
  not a lead byte -- a continuation byte arriving first is a broken stream, and
  guessing a length for it would consume bytes belonging to the next key. The
  leads are the Unicode Standard's (Table 3-7): C0, C1 and F5..FF begin nothing. }
function Utf8Extra(AFirst: Byte): Integer;
begin
  if AFirst < $80 then Result := 0
  else if (AFirst >= $C2) and (AFirst <= $DF) then Result := 1
  else if (AFirst >= $E0) and (AFirst <= $EF) then Result := 2
  else if (AFirst >= $F0) and (AFirst <= $F4) then Result := 3
  else Result := 0;
end;

{ May B follow the lead byte ALead as the byte at position AIndex (1 = the
  first after the lead)? Table 3-7 narrows the first continuation after four
  leads -- that is what makes an overlong form, a surrogate or a code point
  past U+10FFFF ill-formed -- and every other is 80..BF. }
function Utf8Continues(ALead, B: Byte; AIndex: Integer): Boolean;
var lo, hi: Byte;
begin
  lo := $80; hi := $BF;
  if AIndex = 1 then
    case ALead of
      $E0: lo := $A0;
      $ED: hi := $9F;
      $F0: lo := $90;
      $F4: hi := $8F;
    end;
  Result := (B >= lo) and (B <= hi);
end;

{ U+FFFD, EF BF BD, built byte by byte: never concatenated (under this unit's
  UTF8 codepage a Char >= 128 appended to a String is re-encoded), and tagged
  UTF-8, the engine's code page, without converting. }
function Replacement: String;
begin
  SetLength(Result, 3);
  Result[1] := Chr($EF);
  Result[2] := Chr($BF);
  Result[3] := Chr($BD);
  SetCodePage(RawByteString(Result), CP_UTF8, False);
end;

function CrtAssembleKey(const ABytes: RawByteString; AFrom: Integer; AFinal: Boolean;
                        out ATaken, AWaitMs: Integer): String;
var n, i, want: Integer; b0, c: Byte; bad: Boolean;

  { the byte at position AAt of the key being assembled (1 = its first) }
  function At(AAt: Integer): Byte;
  begin
    Result := Byte(ABytes[AFrom + AAt - 1]);
  end;

begin
  Result := '';
  ATaken := 0;
  AWaitMs := 0;
  bad := False;
  n := Length(ABytes) - AFrom + 1;
  if n <= 0 then Exit;
  b0 := At(1);
  if b0 = 27 then
  begin
    ATaken := 1;                       // Escape alone, unless a sequence follows
    if n >= 2 then
    begin
      c := At(2);
      if c = Ord('[') then
      begin
        if (n >= 3) and (At(3) = Ord('[')) then
        begin
          // the Linux console's F1..F5: ESC [ [ and one letter
          if n >= 4 then
          begin
            if (At(4) >= $40) and (At(4) <= $7E) then ATaken := 4;
          end
          else if not AFinal then ATaken := 0;
        end
        else
        begin
          // a control sequence: parameters and intermediates up to ONE final
          // byte. A byte that can be none of these ends it as no sequence at
          // all, and so does running past CRT_SEQ_MAX.
          i := 3;
          while (i <= n) and (i <= CRT_SEQ_MAX) do
          begin
            c := At(i);
            if (c >= $40) and (c <= $7E) then begin ATaken := i; Break; end;
            if (c < $20) or (c > $3F) then Break;
            Inc(i);
          end;
          if (i > n) and (i <= CRT_SEQ_MAX) and not AFinal then ATaken := 0;
        end;
      end
      else if c = Ord('O') then
      begin
        if n >= 3 then
        begin
          if (At(3) >= $40) and (At(3) <= $7E) then ATaken := 3;
        end
        else if not AFinal then ATaken := 0;
      end;
    end
    else if not AFinal then ATaken := 0;
    if ATaken = 0 then AWaitMs := CRT_ESC_WAIT_MS;
  end
  else if b0 < $80 then
    ATaken := 1
  else
  begin
    // A UTF-8 character: exactly its continuation bytes, no more. Stopping at
    // the first byte that is not one leaves the buffer where the next key
    // begins. WHAT IS NOT A CHARACTER IS U+FFFD (round 8): one per maximal
    // ill-formed subpart, the rule environ$ and paramstr$ keep, and the
    // answer Windows gives for a lone surrogate.
    want := Utf8Extra(b0);
    ATaken := want + 1;
    bad := want = 0;
    i := 1;
    while (not bad) and (i <= want) do
    begin
      if i + 1 > n then
      begin
        // the lead and i - 1 continuations are here; the rest is not yet
        if AFinal then begin ATaken := i; bad := True; end
        else begin ATaken := 0; AWaitMs := CRT_UTF8_WAIT_MS; end;
        Break;
      end;
      if not Utf8Continues(b0, At(i + 1), i) then
      begin
        ATaken := i;
        bad := True;
      end;
      Inc(i);
    end;
  end;
  if ATaken = 0 then Exit;
  if bad then Exit(Replacement());
  // The key's own bytes: copied by index and tagged, as Replacement says.
  SetLength(Result, ATaken);
  Move(ABytes[AFrom], Result[1], ATaken);
  SetCodePage(RawByteString(Result), CP_UTF8, False);
end;

function CrtAssembleKey(const ABytes: RawByteString; AFinal: Boolean;
                        out ATaken, AWaitMs: Integer): String;
begin
  Result := CrtAssembleKey(ABytes, 1, AFinal, ATaken, AWaitMs);
end;

procedure CrtReaderInit(out R: TCrtKeyReader; AFill: TCrtFill; AClock: TCrtClock);
begin
  R.Buf := '';
  R.Head := 0;
  R.Moved := 0;
  R.Arrived := 0;
  R.Fill := AFill;
  R.Clock := AClock;
end;

function CrtReaderPending(const R: TCrtKeyReader): Integer;
begin
  Result := Length(R.Buf) - R.Head;
end;

const
  { The answered bytes kept in front of the queue before they are dropped:
    at least this many, and at least as many as still wait. }
  CRT_COMPACT_MIN = 4096;

{ The first ACount waiting bytes were answered. They are dropped from Buf only
  when that is cheap for the bytes answered (see TCrtKeyReader). }
procedure TakeFront(var R: TCrtKeyReader; ACount: Integer);
var rest: Integer;
begin
  Inc(R.Head, ACount);
  rest := Length(R.Buf) - R.Head;
  if rest <= 0 then
  begin
    R.Buf := '';
    R.Head := 0;
  end
  else if (R.Head >= CRT_COMPACT_MIN) and (R.Head >= rest) then
  begin
    Delete(R.Buf, 1, R.Head);
    Inc(R.Moved, QWord(rest));
    R.Head := 0;
  end;
end;

{ Whatever has already arrived, without waiting -- when it can matter: with
  CRT_SEQ_MAX bytes waiting the next key is decided by them alone. }
procedure Poll(var R: TCrtKeyReader);
begin
  if CrtReaderPending(R) >= CRT_SEQ_MAX then Exit;
  if R.Fill(R.Buf, 0) > 0 then R.Arrived := R.Clock();
end;

{ HOW MANY TIMES ONE KEY READ GOES ROUND: each turn either answers, or gets
  more of the key's bytes, or lets its wait run out -- and a key is decided by
  CRT_SEQ_MAX bytes at the latest. So this bound is never reached by a
  terminal; past it, what is there is decided as it stands. The loops spell
  it as the literal 128, which is what scripts/check-budget.py reads as a
  bound fixed by the unit and not by a script; the $if keeps the two equal. }
{$if 4 * CRT_SEQ_MAX <> 128}
  {$error the key readers' 128 turns must be 4 * CRT_SEQ_MAX}
{$endif}

function CrtReaderKey(var R: TCrtKeyReader; ABlock: Boolean): String;
var taken, wait, got, turn: Integer; spent: QWord;
begin
  Result := '';
  Poll(R);
  for turn := 1 to 128 do
  begin
    if CrtReaderPending(R) = 0 then
    begin
      if not ABlock then Exit;
      got := R.Fill(R.Buf, -1);
      if got < 0 then Exit;                  // the input has ended
      if got > 0 then R.Arrived := R.Clock();
      Continue;
    end;
    Result := CrtAssembleKey(R.Buf, R.Head + 1, False, taken, wait);
    if taken = 0 then
    begin
      // The start of a key. Its rest is waited for, from when its last byte
      // came -- by getkey$; inkey$ leaves it and answers that no key is
      // there yet, until the wait has run out.
      spent := R.Clock() - R.Arrived;
      if spent < QWord(wait) then
      begin
        if not ABlock then Exit('');
        got := R.Fill(R.Buf, wait - Integer(spent));
        if got > 0 then R.Arrived := R.Clock();
        if got >= 0 then Continue;
      end;
      Result := CrtAssembleKey(R.Buf, R.Head + 1, True, taken, wait);
    end;
    TakeFront(R, taken);
    Exit;
  end;
  Result := CrtAssembleKey(R.Buf, R.Head + 1, True, taken, wait);
  TakeFront(R, taken);
end;

function CrtReaderReady(var R: TCrtKeyReader): Boolean;
var taken, wait: Integer;
begin
  Poll(R);
  if CrtReaderPending(R) = 0 then Exit(False);
  CrtAssembleKey(R.Buf, R.Head + 1, False, taken, wait);
  Result := (taken > 0) or (R.Clock() - R.Arrived >= QWord(wait));
end;

function CrtReaderByte(var R: TCrtKeyReader; out AByte: Byte): Boolean;
var turn, got: Integer;
begin
  AByte := 0;
  // a wait a signal cut short (0) is waited again, as CrtReaderKey does
  for turn := 1 to 128 do
  begin
    if CrtReaderPending(R) > 0 then Break;
    got := R.Fill(R.Buf, -1);
    if got < 0 then Exit(False);
    if got > 0 then R.Arrived := R.Clock();
  end;
  if CrtReaderPending(R) = 0 then Exit(False);
  AByte := Byte(R.Buf[R.Head + 1]);
  TakeFront(R, 1);
  Result := True;
end;

function CrtSaneEditKeys: TCrtEditKeys;
begin
  Result.KErase := $7F;
  Result.KWErase := $17;
  Result.KKill := $15;
  Result.KEof := $04;
  Result.KLNext := $16;
  Result.EchoOn := True;
  Result.EchoErase := True;
  Result.EchoKill := True;
  Result.EchoKillErase := True;
  Result.EchoCtl := True;
  Result.EchoNl := False;
  Result.CrIsNl := True;
  Result.IgnoreCr := False;
  Result.NlIsCr := False;
  Result.Canon := True;
  Result.Utf8 := True;
end;

procedure CrtEditStart(out S: TCrtEditState; AColumn: Integer);
begin
  S.Line := '';
  S.Literal := False;
  S.Column := AColumn;
  S.CanonColumn := AColumn;
end;

{ A byte appended to a byte string, by index (see KeyBytes). }
procedure AddByte(var S: String; B: Byte);
var n: Integer;
begin
  n := Length(S) + 1;
  SetLength(S, n);
  S[n] := Chr(B);
end;

{ The kernel's iscntrl() (lib/ctype.c, _C): 00..1F and 7F. Its table is
  Latin-1, and there 80..9F are nothing at all -- not control characters. }
function IsCtl(B: Byte): Boolean;
begin
  Result := (B < $20) or (B = $7F);
end;

{ WHAT WORD ERASE TAKES FOR A WORD: the kernel's isalnum(), or '_' (eraser(),
  "Equivalent to BSD's ALTWERASE"). lib/ctype.c is Latin-1: C0..FF are
  letters (_U, _L) except D7 and F7 (_P), and 80..BF are not. Under IUTF8 the
  byte tested is a character's LEAD byte, so 'a-tilde' (C3 A3) is part of a
  word -- and so is everything led by C3..DF other than D7, or by E0..F4,
  quirks included: that is the definition the live line discipline applies.
  Round 9 tested ASCII alone, and 'nao-tilde' Ctrl+W typed ahead left 'na-tilde'
  where the same keys typed live erased the word. }
function IsWordByte(B: Byte): Boolean;
begin
  Result := (Chr(B) in ['0'..'9', 'A'..'Z', 'a'..'z', '_']) or
            ((B >= $C0) and (B <> $D7) and (B <> $F7));
end;

{ is_continuation(): a UTF-8 continuation byte, and only under IUTF8. }
function IsCont(B: Byte; const AKeys: TCrtEditKeys): Boolean;
begin
  Result := AKeys.Utf8 and ((B and $C0) = $80);
end;

{ How a byte is shown (echo_char()): as itself, or -- a control character
  under ECHOCTL, except Tab -- as ^ and the character 40 hex above it (DEL as
  ^?). }
procedure AddShown(var AEcho: String; B: Byte; AEchoCtl: Boolean);
begin
  if AEchoCtl and IsCtl(B) and (B <> 9) then
  begin
    AddByte(AEcho, Ord('^'));
    AddByte(AEcho, B xor $40);
  end
  else
    AddByte(AEcho, B);
end;

procedure AddRubout(var AEcho: String);
begin
  AddByte(AEcho, 8);
  AddByte(AEcho, Ord(' '));
  AddByte(AEcho, 8);
end;

function CrtColumnAfter(ACol: Integer; const ABytes: RawByteString; AUtf8: Boolean): Integer;
var i: Integer; b: Byte;
begin
  Result := ACol;
  for i := 1 to Length(ABytes) do
  begin
    b := Byte(ABytes[i]);
    if (b = 10) or (b = 13) then Result := 0
    else if b = 9 then Result := (Result or 7) + 1
    else if b = 8 then
    begin
      if Result > 0 then Dec(Result);
    end
    else if IsCtl(b) then                    // no column
    else if AUtf8 and ((b and $C0) = $80) then  // nor a continuation
    else Inc(Result);
  end;
end;

{ HOW MANY COLUMNS THE TAB AT ALine[AAt] TOOK, as eraser() and
  __process_echoes() count them: the columns of what stands between it and
  the Tab before it -- or, with none, the start of the line, which began at
  ACanonCol -- and the rest of that tab stop. A control character takes two
  columns under ECHOCTL (^X) and none without; a continuation byte none under
  IUTF8. Round 9 counted from column 0, taking every line to begin on a tab
  stop: after INPUT's prompt 'Name:' a Tab erased typed ahead backed the
  cursor six columns into the prompt, and the next key overwrote it ('Naxe:ab'
  on the screen, 'abx' answered). }
function TabWidth(const ALine: String; AAt, ACanonCol: Integer; const AKeys: TCrtEditKeys): Integer;
var i, cols: Integer; b: Byte; afterTab: Boolean;
begin
  cols := 0;
  afterTab := False;
  for i := Length(ALine) downto 1 do     // from the character before the Tab
  begin
    if i >= AAt then Continue;
    b := Byte(ALine[i]);
    if b = 9 then
    begin
      afterTab := True;
      Break;
    end;
    if IsCtl(b) then
    begin
      if AKeys.EchoCtl then Inc(cols, 2);
    end
    else if not IsCont(b, AKeys) then
      Inc(cols);
  end;
  if not afterTab then Inc(cols, ACanonCol);
  Result := 8 - (cols and 7);
end;

{ Erase backwards, as n_tty's eraser() does: one character (AKind 0), a word
  (1: trailing characters that are not word characters, then those that
  are), or the whole line (2). A character is, under IUTF8, a lead byte and
  its continuations, and without it one byte; a line that begins with a
  continuation byte is not erased into ("do not partially erase"). }
procedure EraseBack(var S: TCrtEditState; AKind: Integer; const AKeys: TCrtEditKeys;
                    var AEcho: String);
var head, k, alnums: Integer; c: Byte;
begin
  alnums := 0;
  while Length(S.Line) > 0 do           // each turn shortens the line, or stops
  begin
    head := Length(S.Line);
    while (head > 1) and IsCont(Byte(S.Line[head]), AKeys) do Dec(head);
    c := Byte(S.Line[head]);
    if IsCont(c, AKeys) then Break;
    if AKind = 1 then
    begin
      if IsWordByte(c) then Inc(alnums)
      else if alnums > 0 then Break;
    end;
    if AKeys.EchoOn then
    begin
      if (AKind = 0) and not AKeys.EchoErase then
        AddShown(AEcho, Byte(AKeys.KErase), AKeys.EchoCtl)
      else if c = 9 then
      begin
        for k := 1 to TabWidth(S.Line, head, S.CanonColumn, AKeys) do AddByte(AEcho, 8);
      end
      else
      begin
        if IsCtl(c) and AKeys.EchoCtl then AddRubout(AEcho);
        if (not IsCtl(c)) or AKeys.EchoCtl then AddRubout(AEcho);
      end;
    end;
    SetLength(S.Line, head - 1);
    if AKind = 0 then Break;
  end;
end;

{ A character into the line, and shown; the first of a line records the
  column the line began in (echo_set_canon_col(), under ECHO). }
procedure PutChar(var S: TCrtEditState; B: Byte; const AKeys: TCrtEditKeys; var AEcho: String);
begin
  if AKeys.EchoOn then
  begin
    if S.Line = '' then S.CanonColumn := S.Column;
    AddShown(AEcho, B, AKeys.EchoCtl);
  end;
  AddByte(S.Line, B);
end;

function EditByte(var S: TCrtEditState; AByte: Byte; const AKeys: TCrtEditKeys;
                  var AEcho: String): TCrtEditStep;
var c: Integer;
begin
  Result := cesMore;
  c := AByte;
  if S.Literal then
  begin
    // the byte after literal-next is a character, whatever it is, and is
    // shown over the '^' literal-next left under the cursor
    S.Literal := False;
    PutChar(S, AByte, AKeys, AEcho);
    Exit;
  end;
  // the input map runs whether or not the line discipline is canonical
  if c = 13 then
  begin
    if AKeys.IgnoreCr then Exit;
    if AKeys.CrIsNl then c := 10;
  end
  else if (c = 10) and AKeys.NlIsCr then
    c := 13;
  if c = 10 then
  begin
    // the line's end: shown as a raw newline -- canonical, under ECHO or
    // ECHONL; not canonical, under ECHO, and a newline typed as itself
    // (not mapped from a CR) as any other control character is
    if AKeys.Canon then
    begin
      if AKeys.EchoOn or AKeys.EchoNl then AddByte(AEcho, 10);
    end
    else if AKeys.EchoOn then
    begin
      if AByte = 13 then AddByte(AEcho, 10)
      else AddShown(AEcho, 10, AKeys.EchoCtl);
    end;
    Exit(cesLine);
  end;
  if not AKeys.Canon then
  begin
    // ICANON off: no erase, no kill, no end of file -- characters
    PutChar(S, c, AKeys, AEcho);
    Exit;
  end;
  if c = AKeys.KEof then
  begin
    // on an empty line it is the end of input; on a line with text in it the
    // read stops short, and the host's reader goes on reading the same line
    if S.Line = '' then Exit(cesEnd);
    Exit;
  end;
  if c = AKeys.KErase then
  begin
    EraseBack(S, 0, AKeys, AEcho);
    Exit;
  end;
  if c = AKeys.KWErase then
  begin
    EraseBack(S, 1, AKeys, AEcho);
    Exit;
  end;
  if c = AKeys.KKill then
  begin
    if S.Line = '' then Exit;
    if not AKeys.EchoOn then
    begin
      S.Line := '';                     // gone, and nothing shown
      Exit;
    end;
    if not (AKeys.EchoKill and AKeys.EchoKillErase and AKeys.EchoErase) then
    begin
      // shown, not rubbed out: the kill character, and a newline under ECHOK
      S.Line := '';
      AddShown(AEcho, Byte(c), AKeys.EchoCtl);
      if AKeys.EchoKill then AddByte(AEcho, 10);
      Exit;
    end;
    EraseBack(S, 2, AKeys, AEcho);
    Exit;
  end;
  if c = AKeys.KLNext then
  begin
    S.Literal := True;
    // '^' under the cursor -- only where ECHOCTL would show the next key so
    if AKeys.EchoOn and AKeys.EchoCtl then
    begin
      AddByte(AEcho, Ord('^'));
      AddByte(AEcho, 8);
    end;
    Exit;
  end;
  PutChar(S, c, AKeys, AEcho);
end;

function CrtEditLine(var S: TCrtEditState; AByte: Byte; const AKeys: TCrtEditKeys;
                     out AEcho: String): TCrtEditStep;
begin
  AEcho := '';
  Result := EditByte(S, AByte, AKeys, AEcho);
  S.Column := CrtColumnAfter(S.Column, AEcho, AKeys.Utf8);
end;

function CrtJobSignalAction(AStopping, ARawOn, AForeground: Boolean): TCrtTermAction;
begin
  Result := ctaNone;
  if not (ARawOn and AForeground) then Exit;
  if AStopping then Result := ctaRestore
  else Result := ctaRaw;
end;

{$IFDEF WINDOWS}
var
  gRawOn: Boolean = False;
  gOldMode: DWORD;
  gCtrlHandled: Boolean = False;

{ CTRL+C ENDS A KEY LOOP, AND THE CONSOLE IS PUT BACK FIRST (round 9,
  2026-10-11). Ctrl+C is the ordinary way out of a getkey$ loop, and the
  console's default handler ends the process with ExitProcess, past unit
  finalization -- so the console was left with line input and echo off
  (measured: 0x1F7 before, 0x1F1 after, exit C000013A), under any parent
  that does not reset it itself. This runs first, on the console's own
  thread: it restores the mode and answers FALSE, so the next handler, in the
  end the default one, still ends the process exactly as before. }
function KbdCtrlHandler(ACtrlType: DWORD): WINBOOL; stdcall;
begin
  if gRawOn then SetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), gOldMode);
  Result := False;
end;

procedure KbdEnterRaw;
var h: THandle;
begin
  if gRawOn then Exit;
  h := GetStdHandle(STD_INPUT_HANDLE);
  if GetConsoleMode(h, gOldMode) then
  begin
    if not gCtrlHandled then
      gCtrlHandled := SetConsoleCtrlHandler(@KbdCtrlHandler, True);
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
  begin
    // A normal key: its character, as UTF-8 bytes. WideToUtf8, not UTF8Encode:
    // a surrogate half on its own is U+FFFD, not '' (see CrtKeyFromPair). And
    // tagged, for the reason the extended branch gives below.
    Result := WideToUtf8(UnicodeString(AUnicodeChar));
    SetCodePage(RawByteString(Result), CP_UTF8, False);
  end
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

function IsHighHalf(C: WideChar): Boolean;
begin
  Result := (Word(C) >= $D800) and (Word(C) <= $DBFF);
end;

function CrtKeyFromPair(AFirst: WideChar; AHaveNext: Boolean; ANext: WideChar;
                        out AUsedNext: Boolean): String;
begin
  AUsedNext := IsHighHalf(AFirst) and AHaveNext and
               (Word(ANext) >= $DC00) and (Word(ANext) <= $DFFF);
  if AUsedNext then
  begin
    Result := WideToUtf8(UnicodeString(AFirst) + UnicodeString(ANext));
    SetCodePage(RawByteString(Result), CP_UTF8, False);
  end
  else
    Result := CrtKeyFromEvent(AFirst, 0);
end;

const
  { Virtual-key codes and control-key flags, as numbers: CrtEventKey is in the
    interface with plain types so the probe can call it, and these are the
    values winuser.h and wincon.h give. }
  VKC_SHIFT = $10; VKC_CONTROL = $11; VKC_MENU = $12; VKC_CAPITAL = $14;
  VKC_LWIN = $5B; VKC_RWIN = $5C; VKC_NUMPAD0 = $60; VKC_NUMPAD9 = $69;
  VKC_NUMLOCK = $90; VKC_SCROLL = $91; VKC_LSHIFT = $A0; VKC_RMENU = $A5;
  CKS_RIGHT_ALT = $0001; CKS_LEFT_ALT = $0002; CKS_ENHANCED = $0100;
  { How long a high surrogate waits for its low half. The two halves are two
    key events, and the console host writes each as its own event -- a reader
    blocked in getkey$ wakes on the FIRST, with the second not yet queued. The
    round-7 reader decided "nothing queued, so no partner is coming" and
    answered two U+FFFD for one emoji (7 runs in 8 with the halves written
    back to back). A partner arrives within microseconds; this bound is only
    ever spent on a half that has none, which no keyboard produces. }
  PAIR_WAIT_MS = 500;

function IsModifierVk(AVk: Word): Boolean;
begin
  Result := (AVk = VKC_SHIFT) or (AVk = VKC_CONTROL) or (AVk = VKC_MENU) or
            (AVk = VKC_CAPITAL) or (AVk = VKC_LWIN) or (AVk = VKC_RWIN) or
            (AVk = VKC_NUMLOCK) or (AVk = VKC_SCROLL) or
            ((AVk >= VKC_LSHIFT) and (AVk <= VKC_RMENU));
end;

{ A numpad digit key, by its virtual-key code (NumLock on) or, NumLock off, by
  its scan code on a key that is not one of the dedicated cluster's (those
  carry ENHANCED_KEY): 7 8 9 / 4 5 6 / 1 2 3 / 0 are scan codes 47 48 49 4B 4C
  4D 4F 50 51 52 -- the table FPC's own crt reads for the same composition. }
function IsNumpadDigit(AVk, AScan: Word; AState: LongWord): Boolean;
begin
  Result := (AVk >= VKC_NUMPAD0) and (AVk <= VKC_NUMPAD9);
  if (not Result) and ((AState and CKS_ENHANCED) = 0) then
    case AScan of
      $47, $48, $49, $4B, $4C, $4D, $4F, $50, $51, $52: Result := True;
    end;
end;

function CrtEventKey(AKeyDown: Boolean; AUnicodeChar: WideChar; AVirtualKey, AScanCode: Word;
                     AControlState: LongWord): String;
begin
  Result := '';
  if not AKeyDown then
  begin
    // Alt+numpad entry: the composed character arrives on the Alt key-up.
    if (AVirtualKey = VKC_MENU) and (AUnicodeChar <> #0) then
      Result := CrtKeyFromEvent(AUnicodeChar, 0);
    Exit;
  end;
  if AUnicodeChar = #0 then
  begin
    if IsModifierVk(AVirtualKey) then Exit;
    if ((AControlState and (CKS_LEFT_ALT or CKS_RIGHT_ALT)) <> 0) and
       IsNumpadDigit(AVirtualKey, AScanCode, AControlState) then Exit;
  end;
  Result := CrtKeyFromEvent(AUnicodeChar, AVirtualKey);
end;

{ One console event under the model: the key ('' for none), its UTF-16 unit
  (#0 for a key with no character) and how many presses it is. A key-down's
  wRepeatCount is presses: "a key held down may arrive as one event with this
  member equal to 5" (KEY_EVENT_RECORD's documentation), and the console host
  merges a held key's repeats exactly so when the reader is slow. It used to be
  read as one press, and a held arrow key lost its moves. }
function RecordKey(const ARec: INPUT_RECORD; out AUnit: WideChar; out ACount: Integer): String;
begin
  Result := '';
  AUnit := #0;
  ACount := 0;
  if ARec.EventType <> KEY_EVENT then Exit;
  Result := CrtEventKey(ARec.Event.KeyEvent.bKeyDown, ARec.Event.KeyEvent.UnicodeChar,
                        ARec.Event.KeyEvent.wVirtualKeyCode,
                        ARec.Event.KeyEvent.wVirtualScanCode,
                        ARec.Event.KeyEvent.dwControlKeyState);
  if Result = '' then Exit;
  AUnit := ARec.Event.KeyEvent.UnicodeChar;
  ACount := 1;
  if ARec.Event.KeyEvent.bKeyDown and (ARec.Event.KeyEvent.wRepeatCount > 1) then
    ACount := ARec.Event.KeyEvent.wRepeatCount;
end;

var
  { The presses of a repeated key-down not answered yet: gRepLeft more of
    gRepKey. Part of the keyboard queue, ahead of anything still in the
    console's -- keypressed() counts them and INPUT reads them first. }
  gRepKey: String = '';
  gRepLeft: Integer = 0;

{ THE ONE VIEW OF THE QUEUE that keypressed, inkey$ and getkey$ all take: wait
  up to ATimeout ms (0 polls, INFINITE blocks) until the event at the head of
  the console's queue is a key, and answer it there, NOT consumed. Events ahead
  of it that are not keys are consumed on the way, as reading always did; that
  is what keypressed() needed and did not do -- it peeked a fixed window of 32
  events and answered 0 forever once 32 non-keys (mouse moves, focus changes,
  stray key-ups) sat ahead of a key that inkey$ read at once. }
function HeadKey(ATimeout: DWORD; out ARec: INPUT_RECORD): Boolean;
var h: THandle; navail, nread, wait: DWORD; start, spent: QWord; u: WideChar; c: Integer;
begin
  Result := False;
  h := GetStdHandle(STD_INPUT_HANDLE);
  start := GetTickCount64();
  while True do
  begin
    navail := 0;
    if not GetNumberOfConsoleInputEvents(h, navail) then Exit;
    if navail = 0 then
    begin
      if ATimeout = 0 then Exit;
      if ATimeout = INFINITE then wait := INFINITE
      else
      begin
        spent := GetTickCount64() - start;
        if spent >= ATimeout then Exit;
        wait := ATimeout - DWORD(spent);
      end;
      // the console input handle is signalled while its queue holds an event
      if WaitForSingleObject(h, wait) <> WAIT_OBJECT_0 then Exit;
      Continue;
    end;
    nread := 0;
    if not PeekConsoleInputW(h, ARec, 1, nread) then Exit;
    if nread = 0 then Continue;
    if RecordKey(ARec, u, c) <> '' then Exit(True);
    if (not ReadConsoleInputW(h, ARec, 1, nread)) or (nread = 0) then Exit;   // not a key
  end;
end;

var
  { When a reader first found a high half at the head of the queue with no key
    behind it: its PAIR_WAIT_MS run from here. 0 when there is none. }
  gHalfSince: QWord = 0;

{ Is a KEY queued behind the event at the head? A window of the queue is
  peeked; nothing is consumed. }
function KeyBehindHead: Boolean;
var recs: array[0..63] of INPUT_RECORD; n, i: DWORD; u: WideChar; c: Integer;
begin
  Result := False;
  n := 0;
  if not PeekConsoleInputW(GetStdHandle(STD_INPUT_HANDLE), recs[0], Length(recs), n) then Exit;
  for i := 1 to High(recs) do
  begin
    if i >= n then Break;
    if RecordKey(recs[i], u, c) <> '' then Exit(True);
  end;
end;

{ Is the high half at the head of the queue SETTLED -- a key behind it to
  decide it, or its PAIR_WAIT_MS gone? }
function HalfSettled: Boolean;
begin
  if KeyBehindHead() then Exit(True);
  if gHalfSince = 0 then gHalfSince := GetTickCount64();
  Result := GetTickCount64() - gHalfSince >= PAIR_WAIT_MS;
end;

{ keypressed(): would inkey$ answer a key? A high half that is not settled
  is not a key YET (see KbdRead). }
function KbdKeyPressed: Boolean;
var rec: INPUT_RECORD; u: WideChar; c: Integer;
begin
  Result := gRepLeft > 0;
  if Result then Exit;
  if not HeadKey(0, rec) then Exit;
  RecordKey(rec, u, c);
  Result := (not IsHighHalf(u)) or HalfSettled();
end;

{ The next key, consumed. A HIGH SURROGATE is half of one: it is settled by the
  next KEY, whenever that comes within PAIR_WAIT_MS -- a low half completes the
  character; any other key leaves the high half alone, U+FFFD, and is not
  consumed, because it is the next key. Events that are not keys between them
  (the half's own key-up, a Shift pressed in between) are passed over as they
  are everywhere.
  INKEY$ DOES NOT WAIT FOR IT (round 9, 2026-10-11). The wait for the second
  half ran whether the read blocked or not, so inkey$ -- documented never to
  block -- stalled 500 ms on a lone half that keypressed() had just called a
  key. A half with nothing behind it is now LEFT at the head, unconsumed, and
  inkey$ answers "" -- the key is not whole yet -- until a key arrives behind
  it or its PAIR_WAIT_MS, counted from when a reader first saw it, has run
  out: then it is U+FFFD. The Unix reader keeps the same rule for the rest of
  an escape sequence or a UTF-8 character. }
function KbdRead(ABlock: Boolean): String;
var h: THandle; rec: INPUT_RECORD; nread, t: DWORD; used: Boolean; u, u2: WideChar;
    count, c2: Integer; spent: QWord;
begin
  Result := '';
  if gRepLeft > 0 then
  begin
    Dec(gRepLeft);
    Exit(gRepKey);
  end;
  if ABlock then t := INFINITE else t := 0;
  if not HeadKey(t, rec) then Exit;
  RecordKey(rec, u, count);
  if IsHighHalf(u) and (not ABlock) and (not HalfSettled()) then Exit;
  h := GetStdHandle(STD_INPUT_HANDLE);
  nread := 0;
  if (not ReadConsoleInputW(h, rec, 1, nread)) or (nread = 0) then Exit;
  Result := RecordKey(rec, u, count);
  if IsHighHalf(u) then
  begin
    count := 1;    // a pair is one key; no keyboard repeats half of one
    t := PAIR_WAIT_MS;
    if gHalfSince <> 0 then
    begin
      spent := GetTickCount64() - gHalfSince;
      if spent >= PAIR_WAIT_MS then t := 0 else t := PAIR_WAIT_MS - DWORD(spent);
    end;
    if HeadKey(t, rec) and (RecordKey(rec, u2, c2) <> '') then
    begin
      Result := CrtKeyFromPair(u, True, u2, used);
      if used then ReadConsoleInputW(h, rec, 1, nread);
    end
    else
      Result := CrtKeyFromPair(u, False, #0, used);
  end;
  gHalfSince := 0;
  if count > 1 then
  begin
    gRepKey := Result;
    gRepLeft := count - 1;
  end;
end;

function CrtTakePendingLine(out APrefix: String): Boolean;
var n, i: Integer;
begin
  APrefix := '';
  Result := False;
  if gRepLeft <= 0 then Exit;
  if (Length(gRepKey) = 1) and (gRepKey[1] = #13) then
  begin
    // an Enter, held: each press is an empty line, one per read
    Dec(gRepLeft);
    Exit(True);
  end;
  // The bytes, copied, never concatenated: the key is tagged UTF-8 and a
  // String concatenation would convert it to the system code page.
  n := Length(gRepKey);
  if CrtPressIsLineText(gRepKey) then
  begin
    SetLength(APrefix, n * gRepLeft);
    for i := 0 to gRepLeft - 1 do
      Move(gRepKey[1], APrefix[1 + i * n], n);
  end;
  gRepLeft := 0;   // taken: as text, or as presses a line has no place for
end;

function CrtPressIsLineText(const AKey: String): Boolean;
begin
  Result := (AKey <> '') and (AKey[1] <> #0) and
            not ((Length(AKey) = 1) and (AKey[1] in [#8, #10, #27]));
end;
{$ELSE}
var
  gRawOn: Boolean = False;
  gSavedTio: Termios;
  gRawTio: Termios;                    // what KbdEnterRaw set, to set again
  gSignalsHandled: Boolean = False;
  gOutColumn: Integer = 0;             // see CrtNoteOutput

{ CTRL+C ENDS A KEY LOOP, AND THE TERMINAL IS PUT BACK FIRST (round 9,
  2026-10-11). Signals stay on in raw mode -- Ctrl+C is the ordinary way out
  of a getkey$ loop -- and their default action ends the process past unit
  finalization, so the terminal was left with echo and line editing off
  (measured: ECHO=0 ICANON=0 after a SIGINT) under any parent that does not
  reset it itself: sh, a script, a program that started phosphor. This puts
  the program's own modes back (tcsetattr is async-signal-safe, POSIX.1
  2.4.3), then restores the default action and sends the signal again; it is
  blocked while this runs, so it arrives as this returns and ends the process
  exactly as it would have -- killed by that signal, which is what a shell
  reports. }
procedure KbdSignal(signal: longint; info: psiginfo; context: psigcontext); cdecl;
var dfl: SigActionRec;
begin
  if gRawOn then TCSetAttr(StdInputHandle, TCSANOW, gSavedTio);
  FillChar(dfl, SizeOf(dfl), 0);       // sa_handler nil: SIG_DFL
  FPSigAction(signal, @dfl, nil);
  FpKill(FpGetPid(), signal);
end;

{ Is this process's group the terminal's foreground one? Only then may it set
  the terminal's modes without being stopped for it (SIGTTOU). }
function TerminalIsForeground: Boolean;
var pg: cint;
begin
  pg := 0;
  Result := (TCGetPGrp(StdInputHandle, pg) >= 0) and (pg = FpGetpgrp());
end;

procedure ApplyTermAction(AAction: TCrtTermAction);
begin
  case AAction of
    ctaRestore: TCSetAttr(StdInputHandle, TCSANOW, gSavedTio);
    ctaRaw: TCSetAttr(StdInputHandle, TCSANOW, gRawTio);
    ctaNone: ;
  end;
end;

{ CTRL+Z, AND fg (round 10, 2026-10-11): see CrtJobSignalAction. On the stop
  signal the terminal is put back, the default action restored, the signal
  unblocked and sent again -- the process stops HERE -- and when it is
  continued this handler is installed again and raw mode re-applied. errno is
  kept: the stop lands in a select() that answers EINTR, which TerminalFill
  reads as "nothing yet" only if errno still says so. }
procedure KbdStop(signal: longint; info: psiginfo; context: psigcontext); cdecl;
var act: SigActionRec; mask: TSigSet; err: cint;
begin
  err := fpgeterrno;
  ApplyTermAction(CrtJobSignalAction(True, gRawOn, TerminalIsForeground()));
  FillChar(act, SizeOf(act), 0);       // SIG_DFL: stop
  FPSigAction(signal, @act, nil);
  FpSigEmptySet(mask);
  FpSigAddSet(mask, signal);
  FpSigProcMask(SIG_UNBLOCK, @mask, nil);
  FpKill(FpGetPid(), signal);          // stopped until SIGCONT
  FillChar(act, SizeOf(act), 0);
  act.sa_handler := @KbdStop;
  FPSigAction(signal, @act, nil);
  ApplyTermAction(CrtJobSignalAction(False, gRawOn, TerminalIsForeground()));
  fpseterrno(err);
end;

{ Continued however it was stopped (a SIGSTOP, a background read): raw mode
  again, if a key function owns it and the terminal is this job's. }
procedure KbdContinue(signal: longint; info: psiginfo; context: psigcontext); cdecl;
var err: cint;
begin
  err := fpgeterrno;
  ApplyTermAction(CrtJobSignalAction(False, gRawOn, TerminalIsForeground()));
  fpseterrno(err);
end;

{ The handler goes on the signals that end a process at a keyboard or a
  terminal's close, and on the job-control pair -- and only where the action
  is still the default: a signal the program was started with IGNORED (a
  background job's SIGINT) or one somebody else handles is left alone. }
procedure HandleSignals;
const
  SIGS: array[0..5] of cint = (SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGTSTP, SIGCONT);
var act, old: SigActionRec; i: Integer;
begin
  gSignalsHandled := True;
  for i := Low(SIGS) to High(SIGS) do
  begin
    FillChar(old, SizeOf(old), 0);
    if FPSigAction(SIGS[i], nil, @old) <> 0 then Continue;
    if Assigned(old.sa_handler) then Continue;   // ignored, or handled already
    FillChar(act, SizeOf(act), 0);
    if SIGS[i] = SIGTSTP then act.sa_handler := @KbdStop
    else if SIGS[i] = SIGCONT then act.sa_handler := @KbdContinue
    else act.sa_handler := @KbdSignal;
    FPSigAction(SIGS[i], @act, nil);
  end;
end;

procedure KbdEnterRaw;
var tio: Termios;
begin
  if gRawOn then Exit;
  if TCGetAttr(StdInputHandle, gSavedTio) <> 0 then Exit;
  if not gSignalsHandled then HandleSignals();
  tio := gSavedTio;
  { cbreak: characters delivered immediately and not echoed; signals (Ctrl+C) and
    output post-processing (so println newlines still translate) are left on. }
  tio.c_lflag := tio.c_lflag and not (ICANON or ECHO);
  tio.c_cc[VMIN] := 1;
  tio.c_cc[VTIME] := 0;
  gRawTio := tio;
  // owned BEFORE the switch, and given up before the switch back: a stop
  // signal between the two then finds the terminal it would put back
  gRawOn := True;
  if TCSetAttr(StdInputHandle, TCSANOW, tio) <> 0 then gRawOn := False;
end;

procedure KbdRestore;
begin
  if gRawOn then
  begin
    gRawOn := False;
    TCSetAttr(StdInputHandle, TCSANOW, gSavedTio);
  end;
end;

{ THE TERMINAL AS A TCrtFill: wait up to AWaitMs for stdin to be readable,
  then take what one read() hands over. In raw mode (VMIN 1, VTIME 0) a read
  of a readable terminal returns what is queued without waiting for more.
  FileRead (SysUtils), not fpRead: fpRead is `inline` and FPC declines to
  inline it here, which -vewn reports as a note. Into a byte array, never a
  Char-into-String: under this unit's UTF8 codepage that re-encodes every
  byte >= 128. A wait a signal handler cut short (EINTR) is not the end of
  input: it answers 0, nothing yet, and the caller waits again. }
function TerminalFill(var ABuf: RawByteString; AWaitMs: Integer): Integer;
var fds: TFDSet; tv: TTimeVal; ptv: PTimeVal; r, n, have: LongInt;
    chunk: array[0..4095] of Byte;
begin
  fpFD_ZERO(fds);
  fpFD_SET(StdInputHandle, fds);
  ptv := nil;
  if AWaitMs >= 0 then
  begin
    tv.tv_sec := AWaitMs div 1000;
    tv.tv_usec := (AWaitMs mod 1000) * 1000;
    ptv := @tv;
  end;
  r := fpSelect(StdInputHandle + 1, @fds, nil, nil, ptv);
  if r < 0 then
  begin
    if fpgeterrno = ESysEINTR then Exit(0);
    Exit(-1);
  end;
  if r = 0 then Exit(0);
  n := FileRead(StdInputHandle, chunk[0], SizeOf(chunk));
  if n <= 0 then Exit(-1);                   // readable and nothing: it has ended
  have := Length(ABuf);
  SetLength(ABuf, have + n);
  Move(chunk[0], ABuf[have + 1], n);
  Result := n;
end;

function MonoClock: QWord;
begin
  Result := GetTickCount64();
end;

var
  { The keyboard queue: every byte read from the terminal and not answered
    yet. A terminal has no ungetc, so what was read belongs here until a key
    function or a line takes it. }
  gReader: TCrtKeyReader;

function KbdKeyPressed: Boolean;
begin
  Result := CrtReaderReady(gReader);
end;

function KbdRead(ABlock: Boolean): String;
begin
  Result := CrtReaderKey(gReader, ABlock);
end;

function CrtTypedAhead: Boolean;
begin
  Result := gRawOn and (CrtReaderPending(gReader) > 0);
end;

function CrtReadHeldByte(out AByte: Byte): Boolean;
begin
  Result := CrtReaderByte(gReader, AByte);
end;

{ One terminal setting as an editing key: -1 when it is switched off
  (_POSIX_VDISABLE, which Linux spells 0). }
function CcKey(AValue: Byte; AOn: Boolean): Integer;
begin
  if AOn and (AValue <> 0) then Result := AValue else Result := -1;
end;

{ The editing the program's OWN terminal settings ask for -- the ones raw
  mode replaced, not raw mode's: ICANON and IUTF8 among them (round 10).
  Word erase and literal-next exist only under IEXTEN, as in the line
  discipline. }
function CrtTerminalEditKeys: TCrtEditKeys;
var lf, ifl: Cardinal; ext: Boolean;
begin
  if not gRawOn then
    if TCGetAttr(StdInputHandle, gSavedTio) <> 0 then Exit(CrtSaneEditKeys());
  lf := gSavedTio.c_lflag;
  ifl := gSavedTio.c_iflag;
  ext := (lf and IEXTEN) <> 0;
  Result.KErase := CcKey(gSavedTio.c_cc[VERASE], True);
  Result.KKill := CcKey(gSavedTio.c_cc[VKILL], True);
  Result.KEof := CcKey(gSavedTio.c_cc[VEOF], True);
  Result.KWErase := CcKey(gSavedTio.c_cc[VWERASE], ext);
  Result.KLNext := CcKey(gSavedTio.c_cc[VLNEXT], ext);
  Result.EchoOn := (lf and ECHO) <> 0;
  Result.EchoErase := (lf and ECHOE) <> 0;
  Result.EchoKill := (lf and ECHOK) <> 0;
  Result.EchoKillErase := (lf and ECHOKE) <> 0;
  Result.EchoCtl := (lf and ECHOCTL) <> 0;
  Result.EchoNl := (lf and ECHONL) <> 0;
  Result.Canon := (lf and ICANON) <> 0;
  Result.CrIsNl := (ifl and ICRNL) <> 0;
  Result.IgnoreCr := (ifl and IGNCR) <> 0;
  Result.NlIsCr := (ifl and INLCR) <> 0;
  Result.Utf8 := (ifl and CRT_IUTF8) <> 0;
end;

{ Shown where the line discipline shows its echo: on the terminal the keys
  came from -- stdin, opened read-write as a terminal always is -- and on
  stdout when that refuses a write and is the terminal too. }
procedure CrtEcho(const ABytes: String);
begin
  if ABytes = '' then Exit;
  CrtNoteOutput(ABytes);
  if FileWrite(StdInputHandle, ABytes[1], Length(ABytes)) < 0 then
    if IsATTY(StdOutputHandle) = 1 then
      FileWrite(StdOutputHandle, ABytes[1], Length(ABytes));
end;

{ Counted only when stdout IS a terminal: output to a file or a pipe moves no
  cursor. }
procedure CrtNoteOutput(const ABytes: String);
var tio: Termios;
begin
  if ABytes = '' then Exit;
  if TCGetAttr(StdOutputHandle, tio) <> 0 then Exit;
  gOutColumn := CrtColumnAfter(gOutColumn, ABytes, (tio.c_iflag and CRT_IUTF8) <> 0);
end;

{ A line the line discipline read and echoed: its Enter showed a newline
  when ECHO or ECHONL is on (n_tty_receive_char_canon()). }
procedure CrtNoteLineEnded;
var tio: Termios;
begin
  if TCGetAttr(StdInputHandle, tio) <> 0 then Exit;
  if (tio.c_lflag and (ECHO or ECHONL)) <> 0 then gOutColumn := 0;
end;

function CrtOutputColumn: Integer;
begin
  Result := gOutColumn;
end;
{$ENDIF}

{ KEYS TYPED AHEAD ARE A LINE'S KEYS (round 9, 2026-10-11). Keys typed while
  a key function holds the terminal raw are read raw -- by the key functions
  into their queue, or still queued in the terminal -- and Linux's line
  discipline does not re-read raw bytes when canonical mode is turned back on:
  it handed them over as they were, unedited and never shown. 'xhelo' DEL
  'lo' Enter typed during a getkey$ made INPUT answer 'helo' 7F 'lo', with
  nothing after its prompt; Windows' console kept the same keys and edited
  them. So on Unix, while the terminal is still raw, everything it holds is
  taken into the queue, and when the queue holds anything the terminal STAYS
  raw for this line: the host reads it from the queue, edited and echoed by
  CrtEditLine as the line discipline would have. With nothing typed ahead,
  line mode is the line discipline's own, as before. (A key landing in the
  microseconds between the last read and the switch is the one the kernel
  still holds raw.) Keys held after crt_done() -- read by an inkey$ poll and
  never answered -- were typed before anything the terminal holds now, so the
  terminal goes raw again for the line that takes them, and back after it. }
function CrtLineModeBegin: Boolean;
{$IFNDEF WINDOWS}
var i: Integer;
{$ENDIF}
begin
  Result := gRawOn;
  {$IFNDEF WINDOWS}
  if not Result then
  begin
    if CrtReaderPending(gReader) > 0 then KbdEnterRaw();
    Exit;
  end;
  for i := 1 to 256 do
    if gReader.Fill(gReader.Buf, 0) <= 0 then Break;
  if CrtReaderPending(gReader) > 0 then Exit;
  {$ELSE}
  if not Result then Exit;
  {$ENDIF}
  KbdRestore();
end;

procedure CrtLineModeEnd(AWasRaw: Boolean);
begin
  if AWasRaw then KbdEnterRaw()
  else KbdRestore();      // raw only for this line's held keys, if at all
end;

// --- the console this process owns (Windows only) ---------------------------
{ Is the console attached to this process ours alone?

  It is when exactly one process is attached to it. A console created for a
  double-clicked executable holds one process -- us; a console belonging to a
  terminal holds the shell as well, and detaching from that would take the
  terminal's client away from the person using it.

  Unix has no equivalent: the terminal is the user's, never the program's, so
  this answers False there and both verbs answer 0. }
function OwnsItsConsole: Boolean;
{$IFDEF WINDOWS}
var
  pids: array[0..7] of DWORD;
{$ENDIF}
begin
  Result := False;
  {$IFDEF WINDOWS}
  Result := GetConsoleProcessList(@pids[0], Length(pids)) = 1;
  {$ENDIF}
end;

{$IFDEF WINDOWS}
var
  gDetached: Boolean = False;   // we let go of a console and can make a new one

{ Was this standard handle a console, rather than a file or a pipe? Asked BEFORE
  detaching, because afterwards there is nothing left to ask. }
function HandleIsConsole(AStd: DWORD): Boolean;
var mode: DWORD;
begin
  Result := (GetFileType(GetStdHandle(AStd)) = FILE_TYPE_CHAR) and
            GetConsoleMode(GetStdHandle(AStd), mode);
end;

{ Point a standard text file at NUL. Without this, the first Writeln after
  FreeConsole raises EInOutError and takes the program with it -- measured, exit
  217. The close is guarded because the handle it would close is already dead. }
procedure SendToNul(var AText: Text);
begin
  {$push}{$I-}
  Close(AText);
  {$pop}
  if IOResult <> 0 then ;   // it was already gone; nothing to close
  Assign(AText, 'NUL');
  {$push}{$I-}
  Rewrite(AText);
  {$pop}
  if IOResult <> 0 then ;
end;

procedure PointAtConsole(var AText: Text; const ADev: String);
begin
  {$push}{$I-}
  Close(AText);
  {$pop}
  if IOResult <> 0 then ;
  Assign(AText, ADev);
  {$push}{$I-}
  Rewrite(AText);
  {$pop}
  if IOResult <> 0 then ;
end;

{ The READING twin of the two above: Reset, never Rewrite, because Input is
  opened for reading. ADev is 'NUL' (every read is end of input, which is what
  a program with no console should see) or 'CONIN$' (the new console's
  keyboard). }
procedure PointInputAt(const ADev: String);
begin
  {$push}{$I-}
  Close(Input);
  {$pop}
  if IOResult <> 0 then ;
  Assign(Input, ADev);
  {$push}{$I-}
  Reset(Input);
  {$pop}
  if IOResult <> 0 then ;
end;
{$ENDIF}

function CrtHideOwnConsole: Boolean;
{$IFDEF WINDOWS}
var outWasConsole, errWasConsole, inWasConsole: Boolean;
{$ENDIF}
begin
  Result := False;
  {$IFDEF WINDOWS}
  if not OwnsItsConsole() then Exit;      // it belongs to a terminal; leave it
  if GetConsoleWindow() = 0 then Exit;    // nothing attached to let go of
  outWasConsole := HandleIsConsole(STD_OUTPUT_HANDLE);
  errWasConsole := HandleIsConsole(STD_ERROR_HANDLE);
  inWasConsole := HandleIsConsole(STD_INPUT_HANDLE);
  Flush(Output);
  {$push}{$I-}
  Flush(StdErr);
  {$pop}
  if IOResult <> 0 then ;
  FreeConsole();
  // Only the handles that WERE consoles are rewired: a run redirected to a file
  // or a pipe keeps its redirection, which is how a windowed program still
  // writes a debug log with no window in sight.
  // FOUR TEXT FILES, NOT TWO. On win64 StdOut and StdErr are records of their
  // own, not aliases of Output and ErrOutput (systemh.inc: the alias exists only
  // under FPC_STDOUT_TRUE_ALIAS, which no desktop target defines), and every
  // host diagnostic is `Writeln(StdErr, ...)`. Rewiring ErrOutput alone left
  // all of them on the console this process had just let go of.
  if outWasConsole then
  begin
    SendToNul(Output);
    SendToNul(StdOut);
  end;
  if errWasConsole then
  begin
    SendToNul(ErrOutput);
    SendToNul(StdErr);
  end;
  // AND THE KEYBOARD. Input had been left on the released console, so after
  // crt_showconsole() an `input` still read the old one -- measured: the line
  // a harness typed into the NEW console came back empty. Redirected stdin, a
  // file or a pipe, keeps its redirection exactly like the two above.
  if inWasConsole then PointInputAt('NUL');
  // What every thread started from now on copies (host/packages/PhosphorStdIO).
  PublishStdIO();
  gDetached := True;
  Result := True;
  {$ENDIF}
end;

function CrtShowOwnConsole: Boolean;
begin
  Result := False;
  {$IFDEF WINDOWS}
  // Only meaningful after we let one go: this makes a NEW console, it does not
  // bring the old window back, and saying so is the difference between a verb
  // that works and one that looks like it did.
  if not gDetached then Exit;
  if not AllocConsole() then Exit;
  PointAtConsole(Output, 'CONOUT$');
  PointAtConsole(StdOut, 'CONOUT$');
  PointAtConsole(ErrOutput, 'CONOUT$');
  PointAtConsole(StdErr, 'CONOUT$');
  PointInputAt('CONIN$');
  PublishStdIO();   // and the new console is what every later thread gets
  gDetached := False;
  Result := True;
  {$ENDIF}
end;

{ crt_hideconsole() -- let go of the console window this program owns, if it owns
  one. Answers 1 when it did and 0 when there was none of its own to let go of,
  which is the honest answer for "you ran me from a terminal" and for Unix. }
function f_crt_hideconsole(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(Ord(CrtHideOwnConsole()));
end;

{ crt_showconsole() -- make a new console and print to it again. 0 unless this
  program had let one go. }
function f_crt_showconsole(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(Ord(CrtShowOwnConsole()));
end;

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
  Reg.Add('crt_hideconsole:', @f_crt_hideconsole);
  Reg.Add('crt_showconsole:', @f_crt_showconsole);
  Reg.Add('inkey$:',        @f_inkey);
  Reg.Add('getkey$:',       @f_getkey);
  Reg.Add('keypressed:',    @f_keypressed);
  Reg.Add('crt_init:',      @f_crt_init);
  Reg.Add('crt_done:',      @f_crt_done);
end;

initialization
  {$IFNDEF WINDOWS}
  CrtReaderInit(gReader, @TerminalFill, @MonoClock);
  {$ENDIF}

finalization
  { Never leave the user's terminal in raw mode, even if the program forgot crt_done. }
  KbdRestore();

end.
