{******************************************************************************
  Phosphor BASIC -- console host (the library's first consumer)

  MIT License. Copyright (c) 2026 Andre Murta.

  The engine is host-agnostic; this program is one host. It wires the engine's
  OnOutput callback to output, and offers two ways in: run a .bas file, or a
  line-at-a-time REPL.

  Usage (kept in step with the --help text below; it listed four of the seven
  verbs this file implements, so `compile`, `pack` and `--gui` were invisible to
  anyone reading the source rather than running it):
    phosphor <file.bas|file.pbc>     run a file, output to stdout
    phosphor run <file> [--out F]    same, explicit verb; --out writes bytes to F
    phosphor --sandbox <dir> <file>  confine every path the script names to <dir>
    phosphor debug [--stop-at-entry] [--break N,N] <file.bas>   step through it
    phosphor compile [--check] <in.bas> <out.pbc>   compile to portable bytecode
    phosphor pack <in.pbc> <out>     make a standalone executable (stub + payload).
                                     Takes COMPILED bytecode, not source: compile
                                     once, pack as often as you like
    phosphor run <gui-app.bas>       a GUI program needs no flag: this binary
                                     brings the widgetset up when a session is
                                     reachable, and runs as a plain console
                                     interpreter when it is not
    phosphor                         REPL
    phosphor --diag                  print console detection + a known UTF-8 line
    phosphor --version | --help

  UTF-8 on Windows -- the subtlety this host exists to get right:

    Writing raw UTF-8 bytes to a *console* handle (WriteFile), or reading it with
    ReadLn under code page 65001, is unreliable for non-ASCII: it renders as
    mojibake. The robust path is the console's native Unicode: WriteConsoleW /
    ReadConsoleW (UTF-16). So when a handle is an interactive console we go
    through those; when it is redirected to a file or pipe we write/read raw
    UTF-8 bytes, which keeps file output byte-exact (and is what the golden test
    checks). On Linux the terminal is UTF-8 natively, so raw bytes are correct
    there too.
******************************************************************************}
program phosphor;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  { cthreads FIRST, and on Unix only. The debug protocol reads its socket on a
    thread, and FPC on Linux refuses at RUNTIME rather than at compile time if no
    thread driver was linked: "This binary has no thread support compiled in",
    runtime error 232, before a line of the program runs. Windows has it built in,
    so this is invisible there -- which is why it took the cross-OS half of the
    bar to find. It must precede every unit that uses threads. }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  {$IFDEF UNIX}BaseUnix,{$ENDIF}
  // The LCL, named by its PARTS. Deliberately NOT `Interfaces`: that unit's only
  // content is a CreateWidgetset call in its initialization section, and on gtk2
  // that call opens the X display -- before main, so a binary that merely listed
  // it died on any machine without a session. Naming the widgetset unit directly
  // links the same code and leaves the call to us, to make when a session is
  // actually there. This is the whole reason one binary can do both jobs.
  Forms, Clipbrd, LCLType, InterfaceBase,
  {$IFDEF WINDOWS}Win32Int,{$ELSE}Gtk2Int,{$ENDIF}
  SysUtils, Classes, PhosphorEngine, PhosphorValue, PhosphorCompiler, PhosphorOpcodes,
  { PhosphorVM for the debug state window only: DebugVM answers one, and the
    stack and variable readers below take it as a parameter. The host reaching
    into an engine unit is the allowed direction -- the boundary check is that
    engine/ must not reach a HOST unit. }
  PhosphorVM,
  { fpjson is ALREADY in this binary -- engine/libs/PhosphorJsonLib links it for
    the json_* built-ins -- so the debug protocol costs no new dependency and no
    binary size, and it is the SAME encoder the editor's udebugproto.pas uses, so
    the two ends cannot disagree about escaping. ssockets is likewise already
    here, through host/packages/PhosphorHttpLib. }
  fpjson, jsonparser, ssockets, sockets, syncobjs,
  PhosphorBytecode, PhosphorRegistry,
  // the GUI function packages -- registered only when a widgetset is up
  PhosphorGuiCore, PhosphorControlLib, PhosphorFormLib, PhosphorButtonLib,
  PhosphorLabelLib, PhosphorEditLib, PhosphorChoiceLib,
  PhosphorContainerLib, PhosphorRangeLib, PhosphorMenuLib, PhosphorTimerLib,
  PhosphorImageLib, PhosphorGridLib, PhosphorTreeListLib, PhosphorCanvasLib,
  PhosphorDialogLib, PhosphorMiscLib,
  // This host opts into EVERY shipped function package, so a program run, compiled
  // or packed by `phosphor` can reach the whole library surface (~700 built-ins).
  // The external-dependency packages (sqlite, http) load their libraries lazily,
  // so the binary builds and runs everywhere; only an actually-called function
  // whose library is absent reports an error, and the rest keep working.
  PhosphorCrtLib, PhosphorBase64Lib, PhosphorZipLib, PhosphorGzipLib,
  PhosphorHttpLib, PhosphorSqliteLib;

var
  { --no-console: hide the console window at startup, when this process owns one.
    A console shared with a terminal is never touched -- see CrtHideOwnConsole. }
  GHideConsole: Boolean = False;

  { --sandbox <dir>: the root every path this run may touch. '' (the default) is
    no sandbox, which is what a trusted script wants and what this host always
    did. Set once from the command line and applied to every engine the run
    creates, so `run`, the REPL and an embedded payload are bounded alike. }
  GSandboxDir: String = '';

  { WHETHER --sandbox WAS GIVEN, which is not the same fact as what it said.

    '' is the encoding for "no sandbox was asked for" AND the value an operator
    hands over when they write `phosphor --sandbox "$RUNDIR" untrusted.bas` with
    RUNDIR unset -- the commonest shell mistake there is. BindSandbox read the
    VALUE to decide whether the flag had been given, so those two meanings were
    indistinguishable and the empty argument ran completely unconfined, silently,
    exit 0. `--sandbox "   "` was refused correctly the whole time, because
    whitespace survives to SetSandboxRoot and comes back '' from there instead:
    two spellings of one intent, opposite answers.

    Presence is its own fact, so it is recorded as one rather than inferred from
    a value that cannot carry it. }
  GSandboxGiven: Boolean = False;

{ Defined further down, beside the crash guard; declared here because all three
  places that build an engine come before it. }
procedure BindSandbox(AEng: TPhosphorEngine); forward;

type
  { The whole host side of the boundary: give the engine somewhere to put its
    output, (for the REPL) a way to read a line, and somewhere for a BREAKPOINT
    to report to. }
  TConsoleHost = class
  private
    FOutFile: TStream;       // non-nil only in --out file mode
    FSourceName: String;     // what a diagnostic calls the running program; '' = unnamed
    {$IFDEF WINDOWS}
    FStdOut, FStdIn, FStdErr: THandle;
    FOutIsConsole: Boolean;  // stdout is an interactive console (not redirected)
    FInIsConsole: Boolean;   // stdin  is an interactive console
    FErrIsConsole: Boolean;  // stderr is an interactive console
    {$ENDIF}
    procedure WriteStdErr(const AText: String);
  public
    constructor Create(const AOutPath: String);
    destructor Destroy; override;
    procedure Output(const AText: String); // matches TPhosphorOutputProc
    function ReadLine(out ALine: String): Boolean; // False at end of input
    procedure Breakpoint(const AMessage: String; ALine: Integer;
                         const AOperands: array of TValue); // TPhosphorBreakpointProc
    function StdoutIsConsole: Boolean;
    function StdinIsConsole: Boolean;
    function StderrIsConsole: Boolean;
    { The name a breakpoint line gives the running program. BindHostSeams sets it
      and every engine-building door goes through BindHostSeams, so there is no
      path that reports a frame without having said what it belongs to. }
    property SourceName: String read FSourceName write FSourceName;
  end;

{ THREE NAMED CEILINGS, BECAUSE THE SCRIPT DECIDES HOW MUCH WORK THIS LINE IS.

  A breakpoint's operand COUNT and every operand's LENGTH come from the program
  being debugged, and the seam fires inside one VM instruction -- so MaxSteps and
  TimeoutMs, which are tested between instructions, are tested before this line
  and after it and never during it. MaxOutputBytes now bounds the PAYLOAD the VM
  hands over -- the message plus each operand's size, charged at opBreakpoint --
  but not what this host then writes, and in any case this host installs no output
  ceiling. So the count of reports is bounded by the engine and the SIZE of each
  one is bounded here. (When this comment was first written the payload was
  charged to nothing at all, and it said so; the engine closed that half
  afterwards.) That is the project's own named class, "a loop or an allocation over
  a script-supplied count", and it landed here where scripts/check-budget.py
  could not see it: the gate scanned engine/libs and host/packages only, and its
  file walk yielded .pas alone, so this file was invisible twice over. Measured
  on the unbounded version, ONE `breakpoint` statement, operands all the same
  10 000-byte string, from a 32 065-byte source, with the engine holding one
  10 KB string:

      1000 operands  exit 0     396 ms   10 009 047 bytes on stderr
      2000 operands  exit 0   2 110 ms   20 019 047
      4000 operands  exit 0  10 472 ms   40 039 047
      8000 operands  exit 0  65 011 ms   80 079 047

  -- superlinear in the count, because `s := s + ...` recopies the line it has
  so far, and linear in each operand on top of that. Nothing refused it: this
  host installs no ceilings for it to defeat, which is precisely why the ceiling
  has to be here.

  SO EVERY LENGTH ON THIS LINE IS NAMED, and a cut is always DECLARED -- the
  count of bytes that did not fit, or the count of operands that did. A silent
  truncation is a lie about the program's state, which is the one thing a
  debugger must never tell. The message and each operand are cut BEFORE they are
  escaped, so the ceiling bounds the WORK and not only the output; the line
  ceiling is tested before each operand is rendered, so an operand nobody will
  print is never built.

  THE SOURCE PATH IS DELIBERATELY NOT CAPPED. It is host-supplied -- the argv
  the operator typed -- not script-supplied, so it is not in the class these
  ceilings exist for, and truncating it would throw away the file name, the one
  part of the frame a reader needs to find the line. The honest bound is
  therefore BP_MAX_LINE_BYTES plus one operand's rendering plus the marker, plus
  whatever path the operator named; at the packed and REPL doors there is no
  path and the bound is closed. }
const
  { A label a person wrote. 1 KB is far past any legible one and still a ceiling. }
  BP_MAX_MESSAGE_BYTES = 1024;
  { One value. Enough to recognise a string, short enough that sixteen of them
    still read as one line. }
  BP_MAX_OPERAND_BYTES = 256;
  { The whole frame. The operand loop stops once the line has reached this. }
  BP_MAX_LINE_BYTES    = 8192;

{ A BYTE CEILING THAT NEVER CUTS A CHARACTER IN HALF.
  Copy(S, 1, N) alone would split a multi-byte UTF-8 character at the limit and
  put a lone continuation byte on the diagnostic stream. The engine already owns
  that boundary question -- Utf8Left and Utf8Len, in PhosphorValue -- so the cut
  is made with them rather than with a second opinion that could disagree with
  the one left$ and mid$ use.

  IT IS APPLIED TO A BOUNDED PREFIX AND NEVER TO THE WHOLE VALUE, which is the
  whole point: Utf8Left builds one Int64 per input BYTE, so asking it about a
  4 MB operand would commit 32 MB to answer a question about the first 256. One
  byte past the ceiling is taken and then the last character of that prefix --
  the one the cut may have landed inside -- is dropped, which lands on a
  character boundary whether or not the boundary and the ceiling coincided. }
function CapUtf8Bytes(const S: String; AMaxBytes: Integer): String;
var
  head: String;
begin
  if Length(S) <= AMaxBytes then
    Exit(S);
  head := Copy(S, 1, AMaxBytes + 1);
  Result := Utf8Left(head, Utf8Len(head) - 1);
end;

{ THE LANGUAGE'S OWN ESCAPE SET, TAKEN FROM THE LEXER AND NOT FROM TASTE.
  engine/PhosphorLexer.pas:10 lists what a source literal accepts -- \n \t \r \0
  \a \b \f \v \\ \" -- and tests/suite/46_string_escapes.bas is its authority. A
  breakpoint message and a string operand are arbitrary RUNTIME text, so rendering
  them with exactly that set means the diagnostic reads back as the literal that
  would produce it, and means a message or an operand carrying a newline cannot
  split the host's one-line-per-breakpoint report into two. A control character
  OUTSIDE the set (say Chr(1)) has no spelling in this language and is passed
  through unchanged; inventing one would print something the lexer could not
  read back.

  WHAT THIS DOES NOT COVER, SAID PLAINLY RATHER THAN LEFT TO BE DISCOVERED: the
  SOURCE PATH in the frame is not escaped. It is not script-supplied -- it is
  the argv the operator typed -- and every other diagnostic in this file
  interpolates that same text raw (see the two `phosphor: %s:%d: %s` sites), so
  escaping it here would print a different name for the same file one line
  apart, and would double every backslash of every Windows path to guard against
  a file name a script cannot create. On Linux a file name MAY contain 0x0A, and
  such a name splits this frame exactly as it already splits this host's other
  diagnostics; that is a host-wide property of the `phosphor: ...` shape, not a
  property of breakpoints, and a framed protocol (B2/B3) carries its own length
  rather than trusting a newline.

  StringReplace rather than a character loop on purpose: every unit here sets the
  UTF8 codepage directive, and appending a Char to such a string re-encodes it,
  which is the class scripts/check-codepage.py exists to catch. Replacing String
  with String never touches the bytes >= 128 of a UTF-8 message. }
function EscapeForDiag(const S: String): String;
begin
  { THE BACKSLASH FIRST, and the order is the whole correctness argument: every
    substitution below introduces backslashes of its own, so a backslash pass run
    after them would double what they had just written. }
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '\n', [rfReplaceAll]);
  Result := StringReplace(Result, #13, '\r', [rfReplaceAll]);
  Result := StringReplace(Result, #9,  '\t', [rfReplaceAll]);
  Result := StringReplace(Result, #0,  '\0', [rfReplaceAll]);
  Result := StringReplace(Result, #7,  '\a', [rfReplaceAll]);
  Result := StringReplace(Result, #8,  '\b', [rfReplaceAll]);
  Result := StringReplace(Result, #12, '\f', [rfReplaceAll]);
  Result := StringReplace(Result, #11, '\v', [rfReplaceAll]);
end;

{ KIND-AWARE, BECAUSE ValToStr IS NOT -- AND THAT IS THE ONLY THING MISSING.
  The renderer itself already exists and is locale-independent: ValToStr, declared
  in the interface of PhosphorValue.pas, is what the engine uses everywhere and
  what this host must keep using, so a Double reads the same in a breakpoint line
  as it does in str$. What ValToStr cannot do is SAY WHICH KIND it rendered: it
  returns a vkString as bare text, so `breakpoint "m", 5` and `breakpoint "m", "5"`
  come out identical, and the first question anyone debugging a BASIC program asks
  is whether the thing is a number or the text of one. Quoting the string answers
  it, and costs nothing anywhere else.

  THE CAP GOES ON THE RAW VALUE, BEFORE THE ESCAPE, for two separate reasons and
  each on its own is sufficient. It bounds the WORK: escaping a 4 MB operand in
  order to throw all but 256 bytes of it away is exactly the cost the ceiling
  exists to refuse, and EscapeForDiag makes ten passes over what it is given. And
  it cannot land inside an escape: a cut made after escaping could fall between a
  backslash and the character it escapes, leaving a dangling backslash that no
  longer reads back as the literal it came from -- the one property this whole
  rendering rests on. Cutting first means there is no escape to split.

  A CUT IS ALWAYS DECLARED, with the value's TRUE length in bytes, so the reader
  is never told a short string where the program holds a long one. Every other
  kind renders to a fixed handful of characters -- an Int64, a Double through
  FloatToStr, true/false, '@' and a handle number -- so no ceiling can bite
  there; the line ceiling in Breakpoint is the backstop that bounds the frame
  whatever a future kind decides to render. }
function RenderOperand(const V: TValue): String;
var
  raw: String;
begin
  if V.Kind <> vkString then
    Exit(ValToStr(V));
  raw := CapUtf8Bytes(V.Str, BP_MAX_OPERAND_BYTES);
  Result := '"' + EscapeForDiag(raw) + '"';
  if Length(raw) < Length(V.Str) then
    Result := Result + Format('...(%d bytes)', [Length(V.Str)]);
end;

constructor TConsoleHost.Create(const AOutPath: String);
{$IFDEF WINDOWS}
var
  mode: DWORD;
{$ENDIF}
begin
  inherited Create();
  FOutFile := nil;
  FSourceName := '';
  if AOutPath <> '' then
    FOutFile := TFileStream.Create(AOutPath, fmCreate);
  {$IFDEF WINDOWS}
  mode := 0;
  FStdOut := StdOutputHandle;
  FStdIn := StdInputHandle;
  FStdErr := StdErrorHandle;
  { GetConsoleMode succeeds only on a real console handle; a file/pipe fails it. }
  FOutIsConsole := (FOutFile = nil) and GetConsoleMode(FStdOut, mode);
  FInIsConsole := GetConsoleMode(FStdIn, mode);
  { --out redirects STDOUT and says nothing about stderr, so FErrIsConsole asks
    its own handle rather than borrowing FOutIsConsole's answer. The two are
    genuinely independent: `phosphor run f.bas --out log.txt` on a terminal has a
    file for stdout and a console for stderr. }
  FErrIsConsole := GetConsoleMode(FStdErr, mode);
  {$ENDIF}
end;

destructor TConsoleHost.Destroy;
begin
  FOutFile.Free; // nil-safe
  inherited Destroy();
end;

function TConsoleHost.StdoutIsConsole: Boolean;
begin
  {$IFDEF WINDOWS}
  Result := FOutIsConsole;
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

function TConsoleHost.StdinIsConsole: Boolean;
begin
  {$IFDEF WINDOWS}
  Result := FInIsConsole;
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

{ Reported by --diag for a reason the other two already have: the UTF-16 console
  branch of WriteStdErr is the one path here that no automated test can reach,
  because it needs a real terminal, and --diag is how this host lets a person
  check by hand what it decided about its own handles. False on Unix, like its
  two neighbours -- there is no second encoding to choose there. }
function TConsoleHost.StderrIsConsole: Boolean;
begin
  {$IFDEF WINDOWS}
  Result := FErrIsConsole;
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

procedure TConsoleHost.Output(const AText: String);
{$IFDEF WINDOWS}
var
  w: WideString;
  written: DWORD;
{$ENDIF}
begin
  if Length(AText) = 0 then
    Exit;
  if FOutFile <> nil then
  begin
    FOutFile.WriteBuffer(AText[1], Length(AText));
    Exit;
  end;
  {$IFDEF WINDOWS}
  if FOutIsConsole then
  begin
    written := 0;
    w := UTF8Decode(AText);           // UTF-8 bytes -> UTF-16 for the console
    if Length(w) > 0 then
      WriteConsoleW(FStdOut, PWideChar(w), Length(w), written, nil);
    Exit;
  end;
  {$ENDIF}
  { Redirected (pipe/file) or non-Windows: raw UTF-8 bytes, byte-exact. }
  FileWrite(StdOutputHandle, AText[1], Length(AText));
end;

function TConsoleHost.ReadLine(out ALine: String): Boolean;
{$IFDEF WINDOWS}
var
  wbuf: array[0..8191] of WideChar;
  numRead: DWORD;
  w: WideString;
  z: Integer;
  hadEOF: Boolean;
{$ENDIF}
begin
  ALine := '';
  {$IFDEF WINDOWS}
  if FInIsConsole then
  begin
    w := '';
    numRead := 0;
    if not ReadConsoleW(FStdIn, @wbuf[0], Length(wbuf), numRead, nil) then
      Exit(False);
    if numRead = 0 then
      Exit(False);                    // Ctrl+Z at line start -> EOF
    SetLength(w, numRead);
    Move(wbuf[0], w[1], numRead * SizeOf(WideChar));
    { A Ctrl+Z (#26) anywhere ends input; keep any text before it. }
    hadEOF := False;
    z := Pos(WideChar($1A), w);
    if z > 0 then
    begin
      SetLength(w, z - 1);
      hadEOF := True;
    end;
    while (Length(w) > 0) and ((w[Length(w)] = #10) or (w[Length(w)] = #13)) do
      SetLength(w, Length(w) - 1);
    ALine := UTF8Encode(w);           // UTF-16 -> UTF-8 bytes for the engine
    if hadEOF and (Length(ALine) = 0) then
      Exit(False);
    Exit(True);
  end;
  {$ENDIF}
  { Redirected stdin or non-Windows: standard line read (raw bytes). }
  if EOF(Input) then
    Exit(False);
  ReadLn(ALine);
  Result := True;
end;

{ ONE HOST DIAGNOSTIC, ON STDERR, WITH THE CARE Output ALREADY TAKES WITH STDOUT.
  Named WriteStdErr and not Diag because a unit-level `function Diag: Integer` --
  the --diag command -- already exists further down, and Pascal is
  case-insensitive: a method with that name would resolve ahead of it inside this
  class and read as the same routine to anyone scanning the file.
  Every other diagnostic in this file is `Writeln(StdErr, ...)`, which is right
  for them and wrong here, for two reasons that only apply to script-supplied text:

    1. Writeln bypasses the WriteConsoleW path this file's header exists to
       justify. A breakpoint message is arbitrary program text and may be
       non-ASCII; written as raw bytes it is correct in a file or a pipe and
       mojibake on an interactive Windows console. The fix is the one Output
       already uses -- UTF-16 to a console handle, UTF-8 bytes to anything else.
    2. Writeln on a text file ends a line with CRLF on Windows and LF on Linux.
       A caller supplying its own #10 gets the SAME BYTES on both machines, which
       is what lets a cross-platform test compare this stream at all.

  The caller supplies the terminator, so this routine never invents one. }
procedure TConsoleHost.WriteStdErr(const AText: String);
{$IFDEF WINDOWS}
var
  w: WideString;
  written: DWORD;
{$ENDIF}
begin
  if Length(AText) = 0 then
    Exit;
  {$IFDEF WINDOWS}
  if FErrIsConsole then
  begin
    written := 0;
    w := UTF8Decode(AText);           // UTF-8 bytes -> UTF-16 for the console
    if Length(w) > 0 then
      WriteConsoleW(FStdErr, PWideChar(w), Length(w), written, nil);
    Exit;
  end;
  {$ENDIF}
  { Redirected (pipe/file) or non-Windows: raw UTF-8 bytes, byte-exact. }
  FileWrite(StdErrorHandle, AText[1], Length(AText));
end;

{ WHAT A BREAKPOINT NOW DOES IN THIS HOST: ONE LINE, ON STDERR, AND KEEP GOING.
  The engine has always offered the seam and this host has always left it nil, so
  the only debugging statement the language has did nothing at all here while
  docs/language-reference.md said it reported a frame to a host debugger. It now
  reports, in the diagnostic shape the rest of the file already uses:

      phosphor: <path>:<line>: breakpoint: <message> [1]=<v> [2]=<v>
      phosphor: <line>: breakpoint: <message>            (a run with no path)

  STDERR AND NEVER STDOUT. A program's output is its own: every byte-exact golden
  in this tree is a comparison of stdout, and a debugger that wrote there would
  corrupt all of them at once. The path-or-no-path pair is not a new shape either
  -- it is exactly what the error diagnostics at the file and embedded doors
  already print, so a reader has one shape to learn rather than two.

  THE OPERAND LIST IS POSITIONAL BECAUSE NO NAMES REACH HERE. The compiled program
  carries no variable names, so `breakpoint "m", x, x*2` arrives as two values and
  nothing else -- and half of them are expressions that never had a name to carry.
  Indices are BASE-1, like every other index a program in this language sees. The
  shape leaves the slot between `]` and `=` free on purpose: when a name table
  lands, `[1]=5` becomes `[1]x=5` and every other character of the line a user has
  learned to read stays where it was.

  NEVER BLOCKS. The seam is a report, not a wait -- the engine offers no way to
  answer it, tests/suite/15_breakpoint_degrade pins that a host which installs
  nothing simply continues, and a host that parked here would deadlock a program
  whose only console is a pipe. Writing a line and returning is the whole job.

  AND NEVER RUNS LONG. Everything on this line is sized by the program being
  debugged, so all three lengths are capped by name -- see the BP_MAX_* block
  above for the numbers and for the 80 MB report that is the reason. Block P of
  scripts/test.ps1 and of its bash twin measures the bound; the exemption in
  scripts/check-budget.py points at that measurement rather than replacing it. }
procedure TConsoleHost.Breakpoint(const AMessage: String; ALine: Integer;
  const AOperands: array of TValue);
var
  s, msg: String;
  i: Integer;
begin
  msg := CapUtf8Bytes(AMessage, BP_MAX_MESSAGE_BYTES);
  if Length(msg) < Length(AMessage) then
    msg := EscapeForDiag(msg) + Format('...(%d bytes)', [Length(AMessage)])
  else
    msg := EscapeForDiag(msg);
  if FSourceName <> '' then
    s := Format('phosphor: %s:%d: breakpoint: %s', [FSourceName, ALine, msg])
  else
    s := Format('phosphor: %d: breakpoint: %s', [ALine, msg]);
  { INDEXED IN PLACE. AOperands is an OPEN ARRAY parameter, not a dynamic array,
    and FPC refuses to assign one to the other -- so the host reads it where it
    lies rather than keeping it. It is also only valid for this call.

    THE LINE CEILING IS TESTED BEFORE THE OPERAND IS RENDERED, never after. The
    work is in the rendering, so an operand that will not be printed must not be
    built first -- testing afterwards would still escape and copy every one of
    eight thousand 10 KB operands before discarding all but the first few. What
    stops is DECLARED: how many operands the program passed that this line does
    not show. }
  for i := 0 to High(AOperands) do
  begin
    if Length(s) >= BP_MAX_LINE_BYTES then
    begin
      s := s + Format(' ...(%d more)', [Length(AOperands) - i]);
      Break;
    end;
    s := s + Format(' [%d]=%s', [i + 1, RenderOperand(AOperands[i])]);
  end;
  WriteStdErr(s + #10);
end;

{ EVERY SEAM, AT EVERY DOOR, FROM ONE PLACE -- AND THAT IS THE POINT OF IT.
  This host builds an engine at three independent doors: RunFile, RunEmbedded and
  Repl. Each used to assign OnOutput and OnInput itself, which made filling a new
  seam a three-site edit that nothing checks: scripts/check-seams.py asks its
  question once per FILE, so a single `eng.OnBreakpoint := ...` anywhere in here
  turns the gate green while two of the three doors stay silent. That is the
  instance-instead-of-the-class failure written into the build, so the wiring
  moves here and the doors call it. A fourth door, or a fifth seam, is then one
  edit in one place.

  ASourceName HAS NO DEFAULT DELIBERATELY. '' is the value that means "no name to
  report", which is right for the packed and REPL doors and WRONG for a file --
  so a default of '' would let a door that forgot the argument quietly report
  frames belonging to nothing. Required, and the omission is a compile error. }
procedure BindHostSeams(AEng: TPhosphorEngine; AHost: TConsoleHost;
                        const ASourceName: String);
begin
  AHost.SourceName := ASourceName;
  AEng.OnOutput := @AHost.Output;
  AEng.OnInput := @AHost.ReadLine;
  AEng.OnBreakpoint := @AHost.Breakpoint;
end;

{ The six opt-in packages, and the seventeen GUI ones. Separate routines because
  a CHECK needs every name this binary can ever provide, GUI included, without
  bringing a widgetset up -- and on a headless machine the running registry has no
  GUI names at all, while the executable being packed will register them wherever
  it finds a session. }
procedure RegisterOptInPackages(Reg: TPhosphorRegistry);
begin
  RegisterCrtFuncs(Reg);
  RegisterBase64Funcs(Reg);
  RegisterZipFuncs(Reg);
  RegisterGzipFuncs(Reg);
  RegisterHttpFuncs(Reg);
  RegisterSqliteFuncs(Reg);
end;

procedure RegisterGuiPackages(Reg: TPhosphorRegistry);
begin
  RegisterGuiCoreFuncs(Reg);
  RegisterControlFuncs(Reg);
  RegisterFormFuncs(Reg);
  RegisterButtonFuncs(Reg);
  RegisterLabelFuncs(Reg);
  RegisterEditFuncs(Reg);
  RegisterChoiceFuncs(Reg);
  RegisterContainerFuncs(Reg);
  RegisterRangeFuncs(Reg);
  RegisterMenuFuncs(Reg);
  RegisterTimerFuncs(Reg);
  RegisterImageFuncs(Reg);
  RegisterGridFuncs(Reg);
  RegisterTreeListFuncs(Reg);
  RegisterCanvasFuncs(Reg);
  RegisterDialogFuncs(Reg);
  RegisterMiscFuncs(Reg);
end;

{ Every function name this BINARY can ever provide -- both halves, no widgetset.
  The caller frees the engine. }
function EverythingThisBinaryProvides: TPhosphorEngine;
begin
  Result := TPhosphorEngine.Create();     // the engine's own libraries register here
  RegisterOptInPackages(Result.Registry);
  RegisterGuiPackages(Result.Registry);
end;

{ Names this program calls that no host built from this binary could satisfy.
  Answers the count and leaves a printable list in AReport. }
function NamesThisBinaryCannotProvide(AProg: TProgram; out AReport: String): Integer;
var
  eng: TPhosphorEngine;
begin
  eng := EverythingThisBinaryProvides();
  try
    Result := UnresolvedCalls(AProg, eng.Registry, AReport);
  finally
    eng.Free;
  end;
end;

{ Is a graphical session reachable?

  Windows: always. The win32 widgetset draws through USER32 and needs no display
  server, so a console binary can bring it up and nothing is lost when it does.

  Unix: only with a session to connect to. gtk2's CreateWidgetset opens the X
  display and there is no way to ask it to fail politely, so the question has to
  be answered BEFORE the call rather than after it. }
function GuiPossible: Boolean;
begin
  {$IFDEF WINDOWS}
  Result := True;
  {$ELSE}
  Result := (GetEnvironmentVariable('DISPLAY') <> '') or
            (GetEnvironmentVariable('WAYLAND_DISPLAY') <> '');
  {$ENDIF}
end;

type
  { The host services a windowed program needs: an event pump and the clipboard.
    The engine only ever offers the seam; this is a host filling it. }
  TGuiServices = class
    function Pump: Integer;
    function PumpOne: Integer;
    function ClipCopy(const AText: String): Boolean;
    function ClipPaste(out AText: String): Boolean;
  end;

var
  GGuiUp: Boolean = False;       // the widgetset has been created
  GGuiSvc: TGuiServices = nil;

function TGuiServices.Pump: Integer;
begin
  Application.ProcessMessages;
  Result := 1;
end;

function TGuiServices.PumpOne: Integer;
begin
  Application.HandleMessage;
  Result := 1;
end;

{ The clipboard is a contended OS resource: every access opens and closes it, and
  another process holding it at that instant makes the attempt fail. A single try
  is a coin flip a script would have to code around. The write is also not
  synchronous -- a paste issued straight after a copy read the PREVIOUS contents
  -- so the copy confirms before it answers, and storing '' means CLEARING, which
  assigning '' to AsText does not do. }
function ClipRetryCopy(const AText: String): Boolean;
var i: Integer;
begin
  for i := 1 to 6 do
  begin
    try
      if AText = '' then
      begin
        Clipboard.Clear;
        if not Clipboard.HasFormat(CF_Text()) then Exit(True);
      end
      else
      begin
        Clipboard.AsText := AText;
        if Clipboard.HasFormat(CF_Text()) and
           (Clipboard.AsText = AText) then Exit(True);
      end;
    except
      on Exception do ;
    end;
    Sleep(15);
  end;
  Result := False;
end;

function ClipRetryPaste(out AText: String): Boolean;
var i: Integer; threw: Boolean;
begin
  AText := '';
  threw := False;
  for i := 1 to 3 do
  begin
    try
      if Clipboard.HasFormat(CF_Text()) then
      begin
        AText := Clipboard.AsText;
        Exit(True);
      end;
    except
      on Exception do threw := True;
    end;
    Sleep(15);
  end;
  // No text after three tries: either the clipboard genuinely holds none --
  // readable, and '' is the true answer -- or every attempt failed, which is not
  // the same thing. Told apart by persistence, and the bound is stated.
  Result := not threw;
end;

function TGuiServices.ClipCopy(const AText: String): Boolean;
begin
  Result := ClipRetryCopy(AText);
end;

function TGuiServices.ClipPaste(out AText: String): Boolean;
begin
  Result := ClipRetryPaste(AText);
end;

{ Bring the widgetset up. This is what `uses Interfaces` would have done in its
  initialization section, done here instead: once, on purpose, and only when
  GuiPossible has already said there is something to connect to. }
procedure StartGui;
begin
  if GGuiUp then Exit;
  {$IFDEF WINDOWS}
  CreateWidgetset(TWin32WidgetSet);
  {$ELSE}
  CreateWidgetset(TGtk2WidgetSet);
  {$ENDIF}
  Application.Initialize;
  GGuiUp := True;
end;

{ Register every shipped function package, so a program run, compiled or packed
  by this host can reach the whole library surface -- INCLUDING the GUI, when a
  session is there to draw on. Where it is not, the GUI names are simply not
  registered and a program that calls one is told so; everything else works. }
procedure RegisterAllPackages(AEng: TPhosphorEngine);
var
  Reg: TPhosphorRegistry;
  svc: THostServices;
begin
  Reg := AEng.Registry;
  RegisterOptInPackages(Reg);

  if not GuiPossible then Exit;

  StartGui;
  RegisterGuiPackages(Reg);
  if GGuiSvc = nil then GGuiSvc := TGuiServices.Create();
  svc.ProcessMessages := @GGuiSvc.Pump;
  svc.HandleMessage := @GGuiSvc.PumpOne;
  svc.ClipboardCopy := @GGuiSvc.ClipCopy;
  svc.ClipboardPaste := @GGuiSvc.ClipPaste;
  AEng.HostServices := svc;
end;

{ Reads a whole file as raw bytes and strips a leading UTF-8 BOM if present, so
  a BOM-saved source never trips the first keyword. }
function ReadSource(const APath: String): String;
var
  fs: TFileStream;
  len: Int64;
begin
  Result := '';
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    len := fs.Size;
    SetLength(Result, len);
    if len > 0 then
      fs.ReadBuffer(Result[1], len);
  finally
    fs.Free;
  end;
  if (Length(Result) >= 3) and (Result[1] = #$EF) and
     (Result[2] = #$BB) and (Result[3] = #$BF) then
    Delete(Result, 1, 3);
end;

{ Compile a .bas source to a .pbc bytecode file.

  BOTH file operations answer for themselves. `compile` promises exactly one
  artifact, and the two ways it can fail to produce one -- the source will not
  open, the output will not -- used to raise an exception that escaped the verb
  altogether and ended the process with exit 0 and not one byte on either
  stream. (Why silence and why zero: see the net around the program body.) A
  build script that checked the exit code was told the compile had succeeded
  when nothing whatever had been written, and the next step then packed or ran a
  stale .pbc. Exit 2 and a sentence naming the path -- the same answer `run
  --out` has always given the very same failure. }
function CompileFile(const AInPath, AOutPath: String; ACheck: Boolean): Integer;
var
  comp: TPhosphorCompiler;
  prog: TProgram;
  fs: TFileStream;
  missing: Integer;
  report, source: String;
begin
  if not FileExists(AInPath) then
  begin
    Writeln(StdErr, 'phosphor: file not found: ', AInPath);
    Exit(2);
  end;
  { FileExists answered "it is there"; whether it will OPEN is a different
    question -- another process holding it, a permission, a device that went
    away between the two calls. }
  try
    source := ReadSource(AInPath);
  except
    on Ex: Exception do
    begin
      Writeln(StdErr, 'phosphor: cannot read ', AInPath, ': ', Ex.Message);
      Exit(2);
    end;
  end;
  comp := TPhosphorCompiler.Create();
  try
    if not comp.Compile(source, prog) then
    begin
      Writeln(StdErr, Format('phosphor: %s:%d: %s', [AInPath, comp.ErrorLine, comp.ErrorMessage]));
      Exit(1);
    end;
  finally
    comp.Free;
  end;
  try
    { ONLY the write is inside this guard. Widening it to cover the --check pass
      below would report an unrelated failure as "cannot write to", which is one
      wrong answer traded for another. }
    try
      fs := TFileStream.Create(AOutPath, fmCreate);
      try WriteProgram(fs, prog); finally fs.Free; end;
    except
      on Ex: Exception do
      begin
        Writeln(StdErr, 'phosphor: cannot write to ', AOutPath, ': ', Ex.Message);
        Exit(2);          // the outer finally still frees prog
      end;
    end;
    // A WARNING, never a failure. A name this host does not have is not
    // necessarily a mistake: the file may be meant for a host that does have it,
    // which is the whole reason names resolve late. So the .pbc is written and
    // the exit code stays 0 -- what changes is that a typo is now visible at the
    // moment it is cheapest to fix, instead of on the day someone runs it.
    if ACheck then
    begin
      missing := NamesThisBinaryCannotProvide(prog, report);
      if missing > 0 then
      begin
        Writeln(StdErr, 'phosphor: warning: ', missing,
                ' function name(s) this host does not provide:');
        Write(StdErr, report);
        Writeln(StdErr, '  Fine if the program is meant for a host that registers them.');
        Writeln(StdErr, '  `phosphor pack` refuses them, because a packed program has');
        Writeln(StdErr, '  only the host packed with it.');
      end;
    end;
    Result := 0;
  finally
    prog.Free;
  end;
end;

{ A file is bytecode if it starts with the WHOLE .pbc header, and that header is
  longer than the three letters of PBC_MAGIC: PhosphorBytecode writes the magic
  and then a VERSION BYTE (engine/PhosphorBytecode.pas, WriteProgram), and that
  byte is 1 -- a control character, which is the part no text file carries there.

  Sniffing the three ASCII letters alone made every source file whose first line
  begins with an uppercase identifier starting PBC into a false positive.
  `PBCount = 3` was refused with "unsupported .pbc format version 111" -- 111 is
  the code point of the fourth SOURCE character, 'o', reported as a format
  version -- and `PBC$ = "hello"` gave version 36. The same file compiled through
  `phosphor compile` and the resulting .pbc ran, and phosphortest, which never
  sniffs, ran the source directly, so the two shipped hosts disagreed about one
  file. `phosphor pack` was hit at the same door and lost its own helpful refusal
  for the same nonsense message.

  AND THE FOURTH BYTE MUST NOT BE ONE OF THE THREE THAT SPACE TEXT. "a control
  character" alone was measured to be not enough: `PBC<TAB>= 3` and a line that
  is just `PBC` are both valid BASIC -- the identical files written with the name
  XBC run and exit 0 -- and TAB, LF and CR are 9, 10 and 13, so all three would
  still be refused as bytecode. They are excluded here. The price is a version
  number this format would have to REACH before a genuine .pbc could be read as
  source, and PBC_VERSION is 1. }
function IsBytecode(const APath: String): Boolean;
var fs: TFileStream; buf: array[0..3] of Char;
begin
  Result := False;
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    if fs.Size >= 4 then
    begin
      fs.ReadBuffer(buf[0], 4);
      Result := (buf[0] = 'P') and (buf[1] = 'B') and (buf[2] = 'C') and
                (Ord(buf[3]) < 32) and
                (buf[3] <> #9) and (buf[3] <> #10) and (buf[3] <> #13);
    end;
  finally
    fs.Free;
  end;
end;

function RunFile(const APath, AOutPath: String): Integer;
var
  host: TConsoleHost;
  eng: TPhosphorEngine;
  fs: TFileStream;
  line: Integer;
  isPbc: Boolean;
  source: String;
begin
  if not FileExists(APath) then
  begin
    Writeln(StdErr, 'phosphor: file not found: ', APath);
    Exit(2);
  end;
  { --out THAT CANNOT BE OPENED IS A FAILURE, not a quiet nothing. This used to
    leave the program unrun, print not one character, and exit 0 -- so a script
    that redirected its output to an unwritable path reported success and produced
    no output, which is indistinguishable from a program that ran and printed
    nothing. }
  try
    host := TConsoleHost.Create(AOutPath);
  except
    on Ex: Exception do
    begin
      Writeln(StdErr, 'phosphor: cannot write to ', AOutPath, ': ', Ex.Message);
      Exit(2);
    end;
  end;
  eng := TPhosphorEngine.Create();
  BindSandbox(eng);   // '' = unbounded; a root that will not bind is fatal
  try
    BindHostSeams(eng, host, APath);   // a file run has a path; a breakpoint names it
    RegisterAllPackages(eng);
    { OPENING the input is guarded; RUNNING it is deliberately not. An engine
      crash reported as "cannot read" would be the same wrong answer wearing a
      different message, so the two are separated: everything that touches the
      filesystem happens here, and the interpreter runs below, where the net
      around the program body is the one that answers for it. }
    try
      isPbc := IsBytecode(APath);
      if isPbc then
        // a precompiled .pbc: run it without the lexer/compiler
        fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone)
      else
        source := ReadSource(APath);
    except
      on Ex: Exception do
      begin
        Writeln(StdErr, 'phosphor: cannot read ', APath, ': ', Ex.Message);
        Exit(2);
      end;
    end;
    if isPbc then
    begin
      try line := eng.RunBytecode(fs); finally fs.Free; end;
    end
    else
      line := eng.Run(source);
    if line <> 0 then
    begin
      Writeln(StdErr, Format('phosphor: %s:%d: %s', [APath, line, eng.ErrorMessage]));
      Exit(1);
    end;
    Result := 0;
  finally
    eng.Free;
    host.Free;
  end;
end;

{ --- `phosphor debug --port N` : the Phosphor Debug Protocol ------------------

  The host end of docs/debug-protocol.md in PhosphorIDE. The EDITOR listens on
  127.0.0.1 and passes its port; this end connects, waits for `initialize`, and
  speaks one JSON object per line terminated by a single #10.

  CONCURRENCY, WHICH IS THE WHOLE DESIGN. The spec says `pause` is valid only
  while running and `setBreakpoints` "may be sent at any time, including while
  the program is running". A loop that reads the socket only at a stop can serve
  neither. So a reader thread owns the socket's read side and queues raw lines;
  the VM thread drains that queue at every statement boundary it is already
  visiting. The reader thread touches exactly one engine field, through
  TPhosphorVM.InterruptDebug, which B2 made interlocked for this and says so.

  WRITING IS THE VM THREAD'S ALONE. Nothing but the drain loop sends a frame, so
  there is no interleaving to guard: the reader queues, the runner answers.

  SET-BREAKPOINTS WHILE RUNNING NEEDS A BOUNDARY, and arming is not thread-safe.
  So a set that arrives while running is queued AND the VM is interrupted: it
  stops at the next boundary, the new set is armed there, and the program resumes
  without a `stopped` event, because the editor did not ask to stop. }

type
  TDbgState = (dbgConnected, dbgInitialized, dbgRunning, dbgStopped, dbgDone);

  TDebugProto = class;

  { The socket's read side. It parses nothing: it splits on #10 and queues the
    raw line, so fpjson is only ever entered from the VM thread. }
  TDbgReader = class(TThread)
  private
    FOwner: TDebugProto;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TDebugProto);
  end;

  TDebugProto = class
  private
    FSock: TInetSocket;
    FEng: TPhosphorEngine;
    FPath: String;          // the file as this host knows it
    FState: TDbgState;
    FLock: TCriticalSection;
    FInbox: TStringList;    // raw lines, written by the reader, read by the VM
    FReader: TDbgReader;
    FClosed: Boolean;
    FExitCode: Integer;
    FStopAtEntry: Boolean;
    FBreaks: array of Integer;
    FAction: TPhosphorDebugAction;
    FDisconnected: Boolean;
    FLaunched: Boolean;     // `launch` seen: the program may start
    FPendingArm: Boolean;   // a set arrived while running; arm at the next boundary
    procedure CloseTransport;
    procedure SendJSON(AObj: TJSONObject);
    procedure SendEvent(const AName: String; AExtra: TJSONObject);
    procedure SendError(ASeq: Integer; const AText: String);
    function TakeLine(out ALine: String): Boolean;
    procedure DoStackTrace(ASeq, ALine, ADepth: Integer);
    procedure DoVariables(ASeq, AFrameIx, ADepth: Integer);
    function Handle(const ARaw: String; ALine, ADepth: Integer): Boolean;
  public
    constructor Create(AEng: TPhosphorEngine; const APath: String);
    destructor Destroy; override;
    function Connect(APort: Integer): Boolean;
    procedure Push(const ALine: String);
    procedure InterruptVM;
    procedure SetInitial(const ABreaks: array of Integer; ACount: Integer;
                         AStopAtEntry: Boolean);
    procedure Arm;
    procedure SendStopped(AExtra: TJSONObject);
    procedure SendExited(AExtra: TJSONObject);
    function Finished: Boolean;
    function Session: Integer;
    function OnStop(AReason: TPhosphorStopReason; ALine: Integer;
                    ADepth: Integer): TPhosphorDebugAction;
  end;

constructor TDbgReader.Create(AOwner: TDebugProto);
begin
  FOwner := AOwner;
  FreeOnTerminate := False;
  inherited Create(False);
end;

{ Byte runs, not characters. The first version of this accumulated with
  `acc := acc + buf[i]`, which concatenates a Char into a code-page string and
  destroys every byte >= 128 -- in a UTF-8 protocol, in the routine that reads it.
  A variable value or a path with an accented character would have arrived
  corrupted, and the spec says the editor answers an unparseable frame by
  disconnecting. check-codepage.py caught it before it shipped, which is what that
  gate is for. Moving whole runs is also O(bytes) rather than a reallocation per
  character. }
procedure TDbgReader.Execute;
const
  { The editor is on loopback and is trusted, but trusted is not unbounded: a peer
    that never sends a #10 would otherwise grow this string until the process
    died. A protocol frame is a few hundred bytes; a megabyte is far past any
    honest one and short of anything that hurts. }
  DBG_MAX_FRAME = 1024 * 1024;
var
  buf: array[0..4095] of Byte;
  { NOT `start`: TThread has a method by that name and Pascal is case-insensitive,
    so the local shadowed it and the compiler refused. }
  got, i, runFrom: Integer;
  acc, chunk, line: String;

  procedure TakeRun(AFrom, ATo: Integer);   // [AFrom, ATo)
  begin
    if ATo <= AFrom then Exit;
    SetLength(chunk, ATo - AFrom);
    Move(buf[AFrom], chunk[1], ATo - AFrom);
    acc := acc + chunk;                     // String + String: no Char anywhere
  end;

begin
  acc := '';
  while not Terminated do
  begin
    got := 0;
    try
      got := FOwner.FSock.Read(buf, SizeOf(buf));
    except
      on Exception do got := 0;
    end;
    if got <= 0 then
    begin
      { A closed socket IS a disconnect; the spec says the editor treats it that
        way and so does this end. Queue the sentinel so the VM thread leaves its
        stop instead of waiting for a frame that will never come. }
      FOwner.Push(#0);
      Break;
    end;
    runFrom := 0;
    for i := 0 to got - 1 do
      if buf[i] = 10 then
      begin
        TakeRun(runFrom, i);
        runFrom := i + 1;
        line := acc;
        acc := '';
        { A #13 before the #10 is tolerated on input and never produced on
          output -- the spec's words. }
        if (Length(line) > 0) and (line[Length(line)] = #13) then
          SetLength(line, Length(line) - 1);
        if line <> '' then FOwner.Push(line);
      end;
    TakeRun(runFrom, got);
    if Length(acc) > DBG_MAX_FRAME then
    begin
      FOwner.Push(#0);
      Break;
    end;
  end;
end;

constructor TDebugProto.Create(AEng: TPhosphorEngine; const APath: String);
begin
  inherited Create();
  FEng := AEng;
  FPath := APath;
  FState := dbgConnected;
  FLock := TCriticalSection.Create();
  FInbox := TStringList.Create();
  FExitCode := 0;
  FAction := daRun;
end;

{ UNBLOCK THE READER BEFORE FREEING ANYTHING. The thread is parked in a blocking
  read; on Windows the free happens to wake it and on Linux it does not, so the
  first version hung after the program had finished, with every assertion in the
  session already passed. shutdown() is the portable way to tell a socket somebody
  else is blocked on that no more traffic is coming: the read returns 0, the
  thread pushes its disconnect sentinel and leaves, and only then is it safe to
  free the socket it was reading. }
procedure TDebugProto.CloseTransport;
begin
  if FSock = nil then Exit;
  FClosed := True;
  try
    fpShutdown(FSock.Handle, 2);   // 2 = SHUT_RDWR on both systems
  except
    on Exception do ;
  end;
end;

destructor TDebugProto.Destroy;
begin
  { BOTH, AND IN THIS ORDER. shutdown() is what returns a blocked read on Linux;
    closing the handle is what does it on Windows. Doing only one moves the hang
    across the boundary instead of closing it, which is what the first repair of
    this did -- Linux went green and Windows went red in the same commit. The
    thread's own read is inside a try/except, so a handle freed under it ends the
    loop rather than the process. }
  if FReader <> nil then FReader.Terminate();
  CloseTransport();
  if FSock <> nil then
    try FSock.Free; FSock := nil; except on Exception do ; end;
  if FReader <> nil then
  begin
    FReader.WaitFor();
    FReader.Free();
    FReader := nil;
  end;
  FInbox.Free();
  FLock.Free();
  inherited Destroy();
end;

function TDebugProto.Connect(APort: Integer): Boolean;
begin
  Result := False;
  try
    { LOOPBACK ONLY, and that is a requirement rather than a default: this channel
      accepts commands that read the debuggee's whole state. }
    FSock := TInetSocket.Create('127.0.0.1', APort);
  except
    on Exception do
    begin
      FSock := nil;
      Exit(False);
    end;
  end;
  FReader := TDbgReader.Create(Self);
  Result := True;
end;

procedure TDebugProto.Push(const ALine: String);
begin
  FLock.Enter();
  try
    FInbox.Add(ALine);
  finally
    FLock.Leave();
  end;
end;

function TDebugProto.TakeLine(out ALine: String): Boolean;
begin
  ALine := '';
  FLock.Enter();
  try
    if FInbox.Count = 0 then Exit(False);
    ALine := FInbox[0];
    FInbox.Delete(0);
  finally
    FLock.Leave();
  end;
  Result := True;
end;

procedure TDebugProto.InterruptVM;
begin
  if FEng.DebugVM <> nil then FEng.DebugVM.InterruptDebug();
end;

{ ONE WRITER, AND IT IS THE VM THREAD. AsJSON is fpjson's own encoder, the same
  one the editor's udebugproto.pas uses, so a value holding chr(10) or a quote
  cannot split a frame -- and the terminator is ours to add, because AsJSON does
  not carry one and a host that forgets leaves the editor buffering for ever. }
procedure TDebugProto.SendJSON(AObj: TJSONObject);
var
  line: String;
begin
  try
    line := AObj.AsJSON + #10;
    if (FSock <> nil) and (not FClosed) then
      FSock.Write(line[1], Length(line));
  except
    on Exception do FClosed := True;
  end;
  AObj.Free();
end;

procedure TDebugProto.SendEvent(const AName: String; AExtra: TJSONObject);
var
  o: TJSONObject;
  i: Integer;
begin
  o := TJSONObject.Create();
  o.Add('event', AName);
  if AExtra <> nil then
  begin
    for i := 0 to AExtra.Count - 1 do
      o.Add(AExtra.Names[i], AExtra.Items[i].Clone);
    AExtra.Free();
  end;
  SendJSON(o);
end;

procedure TDebugProto.SendError(ASeq: Integer; const AText: String);
var
  o: TJSONObject;
begin
  o := TJSONObject.Create();
  o.Add('seq', ASeq);
  o.Add('ok', False);
  o.Add('error', AText);
  SendJSON(o);
end;

procedure TDebugProto.SetInitial(const ABreaks: array of Integer; ACount: Integer;
                                 AStopAtEntry: Boolean);
var
  i: Integer;
begin
  SetLength(FBreaks, ACount);
  for i := 0 to ACount - 1 do FBreaks[i] := ABreaks[i];
  FStopAtEntry := AStopAtEntry;
end;

procedure TDebugProto.SendStopped(AExtra: TJSONObject);
begin
  SendEvent('stopped', AExtra);
end;

procedure TDebugProto.SendExited(AExtra: TJSONObject);
begin
  SendEvent('exited', AExtra);
end;

function TDebugProto.Finished: Boolean;
begin
  Result := FDisconnected or FClosed;
end;

procedure TDebugProto.Arm;
var
  i: Integer;
  lines: array of Integer;
begin
  SetLength(lines, Length(FBreaks));
  for i := 0 to High(FBreaks) do lines[i] := FBreaks[i];
  { ArmDebug REPLACES the set, which is what the protocol's whole-set semantics
    want -- and it is also why this never calls DisarmDebug first: B2 records
    that disarming from inside a stop erases the re-entrancy guard with the set. }
  FEng.ArmDebug(lines, FStopAtEntry);
end;

{ A frame's name, as the protocol wants it: the user function, or `(main)` for
  the outermost. NOTE FOR THE EDITOR'S SIDE: TProgram lowercases a function name
  at registration, so a source that spells it `Greet` is reported as `greet`. The
  compiler has the as-written spelling and TProgram does not; making the two
  agree is a change to the name table, not to this. }
function DbgFrameName(AProg: TProgram; AVM: TPhosphorVM; AFrame: Integer): String;
var
  fn: Integer;
begin
  if AFrame < 0 then Exit('(main)');
  fn := AVM.DbgFrameFunc(AFrame);
  if (AProg <> nil) and (fn >= 0) and (fn < AProg.UserFuncCount) then
    Result := AProg.UserFuncs[fn].Name
  else
    Result := '(frame)';
end;

function DbgKindName(const V: TValue): String;
begin
  if V.Kind = vkInt then Result := 'int'
  else if V.Kind = vkString then Result := 'string'
  else if V.Kind = vkBool then Result := 'bool'
  else if V.Kind = vkHandle then Result := 'handle'
  else Result := 'number';
end;

procedure TDebugProto.DoStackTrace(ASeq, ALine, ADepth: Integer);
const
  { An editor paints a stack pane; nobody reads 262144 rows of one. }
  DBG_MAX_FRAMES = 200;
var
  o, f: TJSONObject;
  arr: TJSONArray;
  vm: TPhosphorVM;
  prog: TProgram;
  i, ix: Integer;
begin
  vm := FEng.DebugVM;
  prog := nil;
  if vm <> nil then prog := vm.DbgProgram();
  arr := TJSONArray.Create();
  ix := 0;
  { Innermost first. GOSUB return addresses are NOT frames and do not appear --
    a GOSUB creates no scope, and the spec says so explicitly. Capped for the
    reason the terminal debugger's `w` is: the SCRIPT chooses the depth and the
    frame ceiling is 262144, so an unbounded walk would build a quarter of a
    million objects into one frame and the editor would have to read it. }
  for i := ADepth - 1 downto -1 do
  begin
    if ix >= DBG_MAX_FRAMES then Break;
    f := TJSONObject.Create();
    f.Add('index', ix);
    f.Add('name', DbgFrameName(prog, vm, i));
    f.Add('path', FPath);
    { Only the innermost frame has a line this host can name: the VM keeps the
      boundary it stopped at, not a return line per frame. An outer frame reports
      0, which the editor reads as "no line" rather than as line zero. }
    if ix = 0 then f.Add('line', ALine) else f.Add('line', 0);
    arr.Add(f);
    Inc(ix);
  end;
  o := TJSONObject.Create();
  o.Add('seq', ASeq);
  o.Add('ok', True);
  o.Add('frames', arr);
  SendJSON(o);
end;

procedure TDebugProto.DoVariables(ASeq, AFrameIx, ADepth: Integer);
var
  o, v: TJSONObject;
  arr: TJSONArray;
  vm: TPhosphorVM;
  prog: TProgram;
  i, fn, vmFrame, n: Integer;
  val: TValue;
begin
  vm := FEng.DebugVM;
  if vm = nil then
  begin
    SendError(ASeq, 'no program is executing');
    Exit;
  end;
  prog := vm.DbgProgram();
  if (prog = nil) or (not prog.HasNames) then
  begin
    SendError(ASeq, 'this program carries no variable names (it came from a .pbc)');
    Exit;
  end;
  { Frame 0 is innermost; the VM numbers them the other way. }
  vmFrame := ADepth - 1 - AFrameIx;
  if (AFrameIx < 0) or (vmFrame < -1) then
  begin
    SendError(ASeq, Format('no frame %d', [AFrameIx]));
    Exit;
  end;

  arr := TJSONArray.Create();
  if vmFrame >= 0 then
  begin
    fn := vm.DbgFrameFunc(vmFrame);
    n := vm.DbgFrameLocalCount(vmFrame);
    for i := 0 to n - 1 do
    begin
      val := vm.DbgLocal(vmFrame, i);
      v := TJSONObject.Create();
      v.Add('name', prog.LocalName(fn, i));
      v.Add('value', ValToStr(val));
      v.Add('kind', DbgKindName(val));
      v.Add('scope', 'local');
      arr.Add(v);
    end;
  end;
  { BOTH SCOPES, because in this language an undeclared name inside a function IS
    a global -- a pane that hid them would hide most of what a function touches.
    The compiler's own temporaries are filtered: they are globals too, and they
    would bury the names the person wrote. }
  for i := 0 to vm.DbgGlobalCount() - 1 do
  begin
    if prog.GlobalIsTemporary(i) then Continue;
    val := vm.DbgGlobal(i);
    v := TJSONObject.Create();
    v.Add('name', prog.GlobalName(i));
    v.Add('value', ValToStr(val));
    v.Add('kind', DbgKindName(val));
    v.Add('scope', 'global');
    arr.Add(v);
  end;

  o := TJSONObject.Create();
  o.Add('seq', ASeq);
  o.Add('ok', True);
  o.Add('variables', arr);
  SendJSON(o);
end;

{ One request. Returns True when the answer resumes the program, so the stop loop
  knows to leave. ALine/ADepth are where the VM is; they are -1/0 while running. }
function TDebugProto.Handle(const ARaw: String; ALine, ADepth: Integer): Boolean;
var
  d: TJSONData;
  o, res, caps: TJSONObject;
  arr: TJSONData;
  cmd: String;
  seq, i: Integer;
  stopped: Boolean;
begin
  Result := False;
  stopped := (FState = dbgStopped);

  if ARaw = #0 then
  begin
    { The socket closed. Detach and let the program finish, which is the same
      thing `disconnect terminate:false` asks for. }
    FClosed := True;
    FDisconnected := True;
    FAction := daRun;
    Exit(True);
  end;

  d := nil;
  try
    try
      d := GetJSON(ARaw);
    except
      on Exception do d := nil;
    end;
    { A line that does not parse is a protocol error and the session ends. It is
      not skipped: a stream that produced one unreadable frame has no claim to be
      understood from the next. }
    if (d = nil) or (not (d is TJSONObject)) then
    begin
      SendEvent('error', nil);
      FClosed := True;
      FDisconnected := True;
      FAction := daRun;
      Exit(True);
    end;
    o := TJSONObject(d);
    seq := o.Get('seq', 0);
    cmd := o.Get('cmd', '');

    if cmd = 'initialize' then
    begin
      caps := TJSONObject.Create();
      caps.Add('stepOut', True);
      caps.Add('pause', True);
      { FALSE, AND NOT BECAUSE IT WOULD BE UNSAFE: there is no side-effect-free
        expression entry point in this engine at all. The spec says a host that
        cannot guarantee an evaluation changes nothing must say false rather than
        offer a half-safe one. }
      caps.Add('evaluate', False);
      caps.Add('setVariable', False);
      caps.Add('conditionalBreakpoints', False);
      res := TJSONObject.Create();
      res.Add('seq', seq);
      res.Add('ok', True);
      res.Add('protocol', 1);
      res.Add('capabilities', caps);
      SendJSON(res);
      if FState = dbgConnected then FState := dbgInitialized;
      Exit(False);
    end;

    if cmd = 'setBreakpoints' then
    begin
      { Whole-set replacement for one file, which makes the editor's view
        authoritative by construction. A path this host does not know matches
        nothing and is not an error. }
      SetLength(FBreaks, 0);
      arr := o.Find('lines');
      if (arr <> nil) and (arr is TJSONArray) then
      begin
        SetLength(FBreaks, TJSONArray(arr).Count);
        for i := 0 to TJSONArray(arr).Count - 1 do
          FBreaks[i] := TJSONArray(arr).Integers[i];
      end;
      if stopped or (FState = dbgInitialized) then
        Arm()
      else
      begin
        { While RUNNING, arming is not safe from here: mark it and interrupt, and
          the VM arms at the boundary it stops on -- without a `stopped` event,
          because the editor did not ask to stop. }
        FPendingArm := True;
        InterruptVM();
      end;
      res := TJSONObject.Create();
      res.Add('seq', seq);
      res.Add('ok', True);
      res.Add('lines', arr.Clone);
      SendJSON(res);
      Exit(False);
    end;

    if cmd = 'launch' then
    begin
      FStopAtEntry := o.Get('stopAtEntry', False);
      FLaunched := True;
      res := TJSONObject.Create();
      res.Add('seq', seq);
      res.Add('ok', True);
      { The acknowledgement is the START, not the finish -- the program's progress
        arrives as events, and an editor that reads this as a stop repaints its
        current-line marker before there is a line to paint. }
      SendJSON(res);
      Exit(False);
    end;

    if cmd = 'disconnect' then
    begin
      res := TJSONObject.Create();
      res.Add('seq', seq);
      res.Add('ok', True);
      SendJSON(res);
      FDisconnected := True;
      if o.Get('terminate', False) then FAction := daStop else FAction := daRun;
      FClosed := True;
      Exit(True);
    end;

    { --- the four that only make sense while stopped --- }
    if (cmd = 'continue') or (cmd = 'stepOver') or (cmd = 'stepInto') or
       (cmd = 'stepOut') then
    begin
      if not stopped then
      begin
        SendError(seq, Format('%s is not valid while running', [cmd]));
        Exit(False);
      end;
      res := TJSONObject.Create();
      res.Add('seq', seq);
      res.Add('ok', True);
      SendJSON(res);
      if cmd = 'continue' then FAction := daRun
      else if cmd = 'stepOver' then FAction := daStepOver
      else if cmd = 'stepInto' then FAction := daStepInto
      else FAction := daStepOut;
      Exit(True);
    end;

    if cmd = 'pause' then
    begin
      if stopped then
      begin
        SendError(seq, 'pause is not valid while stopped');
        Exit(False);
      end;
      res := TJSONObject.Create();
      res.Add('seq', seq);
      res.Add('ok', True);
      SendJSON(res);
      InterruptVM();
      Exit(False);
    end;

    if cmd = 'stackTrace' then
    begin
      if not stopped then SendError(seq, 'stackTrace is valid only while stopped')
      else DoStackTrace(seq, ALine, ADepth);
      Exit(False);
    end;

    if cmd = 'variables' then
    begin
      if not stopped then SendError(seq, 'variables is valid only while stopped')
      else DoVariables(seq, o.Get('frame', 0), ADepth);
      Exit(False);
    end;

    if cmd = 'evaluate' then
    begin
      SendError(seq, 'evaluate is not offered: capabilities.evaluate is false');
      Exit(False);
    end;

    SendError(seq, Format('unknown command "%s"', [cmd]));
  finally
    d.Free();
  end;
end;

function TDebugProto.OnStop(AReason: TPhosphorStopReason; ALine: Integer;
                            ADepth: Integer): TPhosphorDebugAction;
var
  raw, why: String;
  ev: TJSONObject;
  silent: Boolean;
begin
  { A boundary reached only because setBreakpoints interrupted us is not a stop
    the editor asked for, so it gets no `stopped` event: arm and carry on. }
  silent := (AReason = srPause) and (FState = dbgRunning) and FPendingArm;
  if silent then
  begin
    FPendingArm := False;
    Arm();
    Exit(daRun);
  end;

  FState := dbgStopped;
  if AReason = srEntry then why := 'entry'
  else if AReason = srBreakpoint then why := 'breakpoint'
  else if AReason = srStep then why := 'step'
  else why := 'pause';
  ev := TJSONObject.Create();
  ev.Add('reason', why);
  ev.Add('path', FPath);
  ev.Add('line', ALine);
  SendEvent('stopped', ev);

  FAction := daRun;
  while True do
  begin
    if FClosed then Break;
    if TakeLine(raw) then
    begin
      if Handle(raw, ALine, ADepth) then Break;
    end
    else
      Sleep(5);   { the VM thread is parked here on purpose: this seam MAY block }
  end;
  FState := dbgRunning;
  Result := FAction;
end;

function TDebugProto.Session: Integer;
var
  raw: String;
begin
  { Nothing is answered before `initialize`, and nothing runs before `launch`. }
  while (FState <> dbgInitialized) or (not FLaunched) do
  begin
    if FClosed then Exit(2);
    if TakeLine(raw) then
    begin
      if raw = #0 then Exit(2);
      Handle(raw, -1, 0);
      if FDisconnected then Exit(0);
    end
    else
      Sleep(5);
  end;
  Exit(0);
end;

function DebugProtocol(const APath: String; APort: Integer;
                      const ABreaks: array of Integer; ABreakCount: Integer;
                      AStopAtEntry: Boolean): Integer;
var
  host: TConsoleHost;
  eng: TPhosphorEngine;
  proto: TDebugProto;
  source: String;
  line, code: Integer;
  ev: TJSONObject;
begin
  if not FileExists(APath) then
  begin
    Writeln(StdErr, 'phosphor: file not found: ', APath);
    Exit(2);
  end;
  if IsBytecode(APath) then
  begin
    Writeln(StdErr, 'phosphor: ', APath, ' is bytecode.');
    Writeln(StdErr, '  A .pbc carries no source and no variable names; debug the .bas it came from.');
    Exit(2);
  end;

  host := TConsoleHost.Create('');
  eng := TPhosphorEngine.Create();
  BindSandbox(eng);
  proto := nil;
  try
    BindHostSeams(eng, host, APath);
    RegisterAllPackages(eng);
    try
      source := ReadSource(APath);
    except
      on Ex: Exception do
      begin
        Writeln(StdErr, 'phosphor: cannot read ', APath, ': ', Ex.Message);
        Exit(2);
      end;
    end;

    proto := TDebugProto.Create(eng, APath);
    { A PROGRAM LAUNCHED UNDER A DEBUGGER THAT SILENTLY RUNS UNDEBUGGED IS WORSE
      THAN ONE THAT REFUSES, so a connection that cannot be made is exit 2 and the
      program does not run. The spec fixes this message's shape. }
    if not proto.Connect(APort) then
    begin
      Writeln(StdErr, Format('phosphor: cannot connect to the debugger on port %d', [APort]));
      Exit(2);
    end;

    { Whatever the command line asked for is the starting set; `setBreakpoints`
      before `launch` replaces it, which is what an editor actually does. }
    proto.SetInitial(ABreaks, ABreakCount, AStopAtEntry);

    { Nothing is answered before `initialize` and nothing runs before `launch`. }
    code := proto.Session();
    if code <> 0 then Exit(code);
    if proto.Finished then Exit(0);

    eng.OnDebug := @proto.OnStop;
    proto.Arm();

    line := eng.Run(source);
    if line <> 0 then
    begin
      { An engine fault is a `stopped` with reason `exception` carrying the text,
        and the `exited` below follows once this end has cleaned up. }
      ev := TJSONObject.Create();
      ev.Add('reason', 'exception');
      ev.Add('path', APath);
      ev.Add('line', line);
      ev.Add('text', eng.ErrorMessage);
      proto.SendStopped(ev);
      Writeln(StdErr, Format('phosphor: %s:%d: %s', [APath, line, eng.ErrorMessage]));
      Result := 1;
    end
    else
      Result := 0;

    ev := TJSONObject.Create();
    ev.Add('exitCode', Result);
    proto.SendExited(ev);
  finally
    proto.Free;
    eng.Free;
    host.Free;
  end;
end;

{ --- `phosphor debug` : a terminal debugger ---------------------------------

  B2 gave the engine a seam that may BLOCK: the VM asks at a statement boundary
  and does what the answer says. This is the smallest host that answers it with a
  person. The work order's B3 answers it with a socket and a protocol so an editor
  can drive; that is a strictly larger thing and this is not it.

  THE ONE HAZARD WORTH NAMING AT THE TOP: this seam may block, and blocking on a
  read means blocking on somebody typing. When stdin is not a terminal -- a pipe,
  a redirect from the null device, a test runner -- there is nobody to type, and a
  debugger that waits anyway is the REPL trap wearing a different hat. So the
  first stop with no input available answers "continue", says so once on stderr,
  and never asks again. `phosphor debug x.bas < /dev/null` runs the program. }

type
  TDebugSession = class
  private
    FEng: TPhosphorEngine;
    FPath: String;
    FSrc: TStringList;
    FSilent: Boolean;        // stdin gave EOF: answer daRun and stop asking
    FLastCmd: String;        // bare Enter repeats the last command, as gdb does
    procedure Banner(AReason: TPhosphorStopReason; ALine, ADepth: Integer);
    procedure ShowList(ALine: Integer);
    procedure ShowStack(AVM: TPhosphorVM; ALine, ADepth: Integer);
    procedure ShowVars(AVM: TPhosphorVM; ADepth: Integer);
    procedure ShowHelp;
  public
    constructor Create(AEng: TPhosphorEngine; const APath: String;
                       const ASource: String);
    destructor Destroy; override;
    function OnStop(AReason: TPhosphorStopReason; ALine: Integer;
                    ADepth: Integer): TPhosphorDebugAction;
  end;

constructor TDebugSession.Create(AEng: TPhosphorEngine; const APath: String;
                                 const ASource: String);
begin
  inherited Create();
  FEng := AEng;
  FPath := APath;
  FSrc := TStringList.Create();
  FSrc.Text := ASource;
  FSilent := False;
  FLastCmd := '';
end;

destructor TDebugSession.Destroy;
begin
  FSrc.Free;
  inherited Destroy();
end;

procedure TDebugSession.Banner(AReason: TPhosphorStopReason; ALine, ADepth: Integer);
var
  why: String;
begin
  if AReason = srEntry then why := 'entry'
  else if AReason = srBreakpoint then why := 'breakpoint'
  else if AReason = srStep then why := 'step'
  else why := 'pause';
  Writeln(StdErr, '');
  Writeln(StdErr, Format('-- %s at %s:%d  (depth %d)',
                         [why, ExtractFileName(FPath), ALine, ADepth]));
  if (ALine >= 1) and (ALine <= FSrc.Count) then
    Writeln(StdErr, Format('%5d | %s', [ALine, FSrc[ALine - 1]]));
end;

procedure TDebugSession.ShowList(ALine: Integer);
var
  i, lo, hi: Integer;
  mark: String;
begin
  lo := ALine - 4; if lo < 1 then lo := 1;
  hi := ALine + 4; if hi > FSrc.Count then hi := FSrc.Count;
  for i := lo to hi do
  begin
    if i = ALine then mark := '>' else mark := ' ';
    Writeln(StdErr, Format('%s%5d | %s', [mark, i, FSrc[i - 1]]));
  end;
end;

{ One frame's label. AFrame = -1 means the top level, which is what lies under
  every frame and is a real place to name rather than an absence to skip. }
function FrameLabel(AProg: TProgram; AVM: TPhosphorVM; AFrame: Integer): String;
var
  fn: Integer;
begin
  if AFrame < 0 then Exit('<top level>');
  fn := AVM.DbgFrameFunc(AFrame);
  if (AProg <> nil) and (fn >= 0) and (fn < AProg.UserFuncCount) then
    Result := AProg.UserFuncs[fn].Name + '()'
  else
    Result := Format('<frame %d>', [AFrame]);
end;

{ THE STACK IS READ THROUGH FrameCount AND Frame(i), NOT THROUGH A Caller LINK.
  Lyra refuses a Caller accessor for the reason that applies here too: it invites
  a recursive walk over a depth the SCRIPT chooses, and a debugger that overflows
  on a deep program is worse than one that prints a number. This loop is flat. }
procedure TDebugSession.ShowStack(AVM: TPhosphorVM; ALine, ADepth: Integer);
const
  { A person reads the innermost frames; a runaway recursion has 262144 of them. }
  DBG_STACK_MAX = 200;
var
  i, shown: Integer;
  prog: TProgram;
begin
  prog := AVM.DbgProgram();

  { FRAME 0 IS WHERE EXECUTION IS, and its name comes from the innermost frame --
    DbgFrameFunc(ADepth - 1) -- not from a separate accessor. At depth 0 there is
    no frame and the answer is the top level, which is a place and not a gap. }
  Writeln(StdErr, Format('#0  %s   line %d',
                         [FrameLabel(prog, AVM, ADepth - 1), ALine]));

  { Outward, one line per live frame. Flat on purpose -- no recursion over a depth
    the SCRIPT chooses -- and CAPPED for the same reason: the frame ceiling is
    262144, so `w` inside a runaway recursion would otherwise print a quarter of a
    million lines into a terminal somebody is trying to read. The cap is named, and
    what it hides is counted rather than dropped silently. }
  shown := 0;
  for i := ADepth - 2 downto -1 do
  begin
    if shown >= DBG_STACK_MAX then
    begin
      Writeln(StdErr, Format('     ... %d more frame(s); the innermost %d are shown',
                             [ADepth - 1 - shown, DBG_STACK_MAX + 1]));
      Break;
    end;
    Writeln(StdErr, Format('#%d  %s', [ADepth - 1 - i, FrameLabel(prog, AVM, i)]));
    Inc(shown);
  end;
end;

{ READING NEVER EXECUTES. Every value below comes out of the state window B1 and
  B2 opened -- DbgGlobal, DbgLocal -- and nothing here calls back into the engine.
  That is Lyra's rule and it is the difference between inspecting a stopped
  program and running more of it by accident. }
procedure TDebugSession.ShowVars(AVM: TPhosphorVM; ADepth: Integer);
var
  prog: TProgram;
  i, fn, n, shown: Integer;
begin
  prog := AVM.DbgProgram();
  if prog = nil then
  begin
    Writeln(StdErr, '   (no program)');
    Exit;
  end;
  if not prog.HasNames then
  begin
    Writeln(StdErr, '   this program came from a .pbc and carries no names,');
    Writeln(StdErr, '   so there is nothing to show rather than nothing to see.');
    Exit;
  end;

  if ADepth > 0 then
  begin
    fn := AVM.DbgFrameFunc(ADepth - 1);
    n := AVM.DbgFrameLocalCount(ADepth - 1);
    if (fn >= 0) and (fn < prog.UserFuncCount) then
      Writeln(StdErr, Format('locals of %s()', [prog.UserFuncs[fn].Name]))
    else
      Writeln(StdErr, 'locals');
    for i := 0 to n - 1 do
      Writeln(StdErr, Format('   %-20s %s',
                             [prog.LocalName(fn, i), RenderOperand(AVM.DbgLocal(ADepth - 1, i))]));
    if n = 0 then Writeln(StdErr, '   (none)');
  end;

  Writeln(StdErr, 'globals');
  shown := 0;
  for i := 0 to AVM.DbgGlobalCount() - 1 do
  begin
    { The compiler makes temporaries and they are globals like any other. A
      debugger that lists them buries the three names the person wrote. }
    if prog.GlobalIsTemporary(i) then Continue;
    Writeln(StdErr, Format('   %-20s %s',
                           [prog.GlobalName(i), RenderOperand(AVM.DbgGlobal(i))]));
    Inc(shown);
  end;
  if shown = 0 then Writeln(StdErr, '   (none)');
end;

procedure TDebugSession.ShowHelp;
begin
  Writeln(StdErr, '  s, step    step into the next statement');
  Writeln(StdErr, '  n, next    step over a call');
  Writeln(StdErr, '  o, out     run until this function returns');
  Writeln(StdErr, '  c, cont    continue to the next armed line');
  Writeln(StdErr, '  w, where   the call stack');
  Writeln(StdErr, '  v, vars    locals of this frame, then globals');
  Writeln(StdErr, '  l, list    source around here');
  Writeln(StdErr, '  q, quit    stop the program (a clean stop, like END)');
  Writeln(StdErr, '  h, ?       this');
  Writeln(StdErr, '  <Enter>    repeat the last command');
end;

function TDebugSession.OnStop(AReason: TPhosphorStopReason; ALine: Integer;
                              ADepth: Integer): TPhosphorDebugAction;
var
  cmd: String;
  vm: TPhosphorVM;
  atEof: Boolean;
begin
  if FSilent then Exit(daRun);
  Banner(AReason, ALine, ADepth);

  { DebugVM answers the VM that is executing, and nil at every other moment. It
    is read here rather than held, because the engine's own doc block says a host
    takes it at its stop and does not carry it across calls. }
  vm := FEng.DebugVM;

  while True do
  begin
    Write(StdErr, '(dbg) ');
    Flush(StdErr);
    atEof := False;
    try
      atEof := Eof(Input);
    except
      on Exception do atEof := True;
    end;
    if atEof then
    begin
      { NOBODY IS THERE. Answer the question and stop asking -- see the hazard at
        the top of this section. Said once, on stderr, so a redirected run still
        explains itself without touching the program's own output. }
      Writeln(StdErr, '');
      Writeln(StdErr, 'phosphor debug: stdin is not a terminal; continuing without stopping.');
      FSilent := True;
      Exit(daRun);
    end;
    ReadLn(Input, cmd);
    cmd := LowerCase(Trim(cmd));
    if cmd = '' then cmd := FLastCmd else FLastCmd := cmd;

    if (cmd = 's') or (cmd = 'step') then Exit(daStepInto);
    if (cmd = 'n') or (cmd = 'next') then Exit(daStepOver);
    if (cmd = 'o') or (cmd = 'out') then Exit(daStepOut);
    if (cmd = 'c') or (cmd = 'cont') or (cmd = 'continue') then Exit(daRun);
    if (cmd = 'q') or (cmd = 'quit') then Exit(daStop);
    if (cmd = 'w') or (cmd = 'where') or (cmd = 'bt') then ShowStack(vm, ALine, ADepth)
    else if (cmd = 'v') or (cmd = 'vars') then ShowVars(vm, ADepth)
    else if (cmd = 'l') or (cmd = 'list') then ShowList(ALine)
    else if (cmd = 'h') or (cmd = '?') or (cmd = 'help') then ShowHelp()
    else
      Writeln(StdErr, Format('phosphor debug: unknown command "%s" -- h for help', [cmd]));
  end;
end;

{ Parse `--break 3,11,42` into the armed set. A line that no statement starts on
  can be asked for and simply never fires; StoppableLines would let this refuse
  it, but the program is not compiled yet at flag-parsing time, and refusing a
  line late is worse than a breakpoint that never hits. }
function ParseBreakList(const AText: String; out ALines: array of Integer;
                        out ACount: Integer): Boolean;
var
  i, v, e: Integer;
  part: String;
  rest: String;
begin
  ACount := 0;
  rest := AText;
  while rest <> '' do
  begin
    i := Pos(',', rest);
    if i = 0 then
    begin
      part := Trim(rest);
      rest := '';
    end
    else
    begin
      part := Trim(Copy(rest, 1, i - 1));
      rest := Copy(rest, i + 1, Length(rest));
    end;
    if part = '' then Continue;
    Val(part, v, e);
    if (e <> 0) or (v < 1) then
    begin
      Writeln(StdErr, Format('phosphor debug: --break wants line numbers, got "%s"', [part]));
      Exit(False);
    end;
    if ACount > High(ALines) then
    begin
      Writeln(StdErr, 'phosphor debug: too many --break lines');
      Exit(False);
    end;
    ALines[ACount] := v;
    Inc(ACount);
  end;
  Result := True;
end;

function DebugFile(const APath: String; const ABreaks: array of Integer;
                   ABreakCount: Integer; AStopAtEntry: Boolean): Integer;
var
  host: TConsoleHost;
  eng: TPhosphorEngine;
  sess: TDebugSession;
  source: String;
  line, i: Integer;
  armed: array of Integer;
begin
  if not FileExists(APath) then
  begin
    Writeln(StdErr, 'phosphor debug: file not found: ', APath);
    Exit(2);
  end;
  if IsBytecode(APath) then
  begin
    { A .pbc carries no names and no source, so every stop would print a line
      number into a file the debugger cannot show and a variable list it cannot
      name. Refused with the reason rather than run half-blind. }
    Writeln(StdErr, 'phosphor debug: ', APath, ' is bytecode.');
    Writeln(StdErr, '  A .pbc carries no source and no variable names; debug the .bas it came from.');
    Exit(2);
  end;

  host := TConsoleHost.Create('');
  eng := TPhosphorEngine.Create();
  BindSandbox(eng);
  sess := nil;
  try
    BindHostSeams(eng, host, APath);
    RegisterAllPackages(eng);
    try
      source := ReadSource(APath);
    except
      on Ex: Exception do
      begin
        Writeln(StdErr, 'phosphor debug: cannot read ', APath, ': ', Ex.Message);
        Exit(2);
      end;
    end;

    sess := TDebugSession.Create(eng, APath, source);
    eng.OnDebug := @sess.OnStop;
    SetLength(armed, ABreakCount);
    for i := 0 to ABreakCount - 1 do armed[i] := ABreaks[i];
    eng.ArmDebug(armed, AStopAtEntry);

    Writeln(StdErr, Format('phosphor debug: %s -- h for help', [ExtractFileName(APath)]));
    line := eng.Run(source);
    if line <> 0 then
    begin
      Writeln(StdErr, Format('phosphor: %s:%d: %s', [APath, line, eng.ErrorMessage]));
      Exit(1);
    end;
    Result := 0;
  finally
    sess.Free;
    eng.Free;
    host.Free;
  end;
end;

// --- self-extracting deployment (phosphor pack) ------------------------------
// A packed application is this stub binary with a .pbc payload appended, behind a
// fixed trailer at the very end (PE and ELF both ignore trailing bytes). The stub
// reads its own tail at startup; if the trailer's magic is there, it runs the
// embedded payload. Same phosphor binary: bare it is the CLI, packed it is an app.
//
// AND IT ALSO CARRIES A MARK IN ITS MIDDLE, because the tail alone was not enough
// to answer "am I a packed application?". See GPackMark below.

const
  { The magic IS the version. A packed file carries the stub that made it, so a v1
    file always meets a v1 reader in practice -- and the reader below handles both
    anyway, because "that cannot happen" is how a format break ends up being
    executed as the wrong bytes. }
  PACK_MAGIC_V1 = 'PHOSPBC1';      // offset + size + checksum + magic
  PACK_MAGIC_V2 = 'PHOSPBC2';      // ...and a flags word before the magic
  PACK_TRAILER_V1 = 8 + 8 + 4 + 8;
  PACK_TRAILER_V2 = 8 + 8 + 4 + 4 + 8;
  { Flags in a v2 trailer. }
  PACK_FLAG_NOCONSOLE = 1;         // let go of the console this process owns
  { Every flag bit this build knows how to honour. A trailer carrying a bit
    outside this mask is asking for behaviour this stub cannot deliver, and
    running the program anyway while quietly ignoring what the file asked for is
    the same silence the reader below exists to end. The mask is stated once,
    here, so adding a flag cannot leave the check behind. }
  PACK_FLAGS_KNOWN: LongWord = PACK_FLAG_NOCONSOLE;

  { THE STUB'S SELF-MARK, and why a trailer could not do this job.
------------------------------------------------------------------------------
    Everything that said "this file is a packed application" lived in the last
    32 bytes. Truncation -- an interrupted copy or download, a partial write, an
    antivirus that cuts a file short -- removes exactly those bytes, so the
    reader found no magic, answered "a bare stub", and RunCommandLine fell
    through to `Halt(Repl())`: a damaged MyApp.exe opened an interactive BASIC
    prompt that runs whatever is typed into it and never ends by itself, while
    any script that shipped it saw exit 0. That is word for word the outcome the
    esCorrupt branch was added to refuse; it covered a bad offset, a bad size, an
    unknown flag bit and a checksum mismatch -- every corruption that leaves the
    TAIL intact -- and truncation is the commonest corruption there is.

    THREE CHEAPER ANSWERS WERE MEASURED FIRST, and all three are false:

      * "something in the stub already says packed". It did not. `pack` copies
        the running binary byte for byte, and the whole stub region of a packed
        application compared byte-identical to bin/phosphor.exe. There was
        nothing to read.
      * "refuse the REPL when stdin is not a terminal". It closes nothing and
        breaks what works: the harm case is a damaged app double-clicked or
        started by a service, where stdin IS a console, so the prompt still
        opens; while `phosphor < NUL` and `echo 'println 6*7' | phosphor` are
        both live, tested CLI uses that it would refuse. And StdinIsConsole is a
        hard-coded False on every non-Windows build (see above), so the rule
        would refuse the REPL on every Linux machine.
      * "compare the size on disk with a size the packer recorded". Right idea,
        nowhere to put it: everything the packer wrote past the payload was the
        trailer, at the very end, which is the part truncation takes. It becomes
        true only once there is somewhere in the MIDDLE to record it -- which is
        this mark, so the size is recorded here and the comparison is made.

    HOW IT WORKS. GPackMark is initialised DATA, so it is present in the built
    binary at a fixed offset that the loader maps verbatim. `pack` copies the
    stub, finds those 16 bytes in the copy (searching for the bytes the RUNNING
    process holds, so no second compiled-in copy of the bare tag exists to be
    found twice), and overwrites them with PACK_MARK_PACKED followed by the
    finished file's length. At startup the stub reads its own global -- no file
    access, nothing that can be cut off -- and a binary that finds the packed tag
    knows it is an application before it has looked at one byte of its tail. A
    missing or overwritten trailer is then esCorrupt, and falling through to the
    REPL needs an UNMARKED binary, which is the only file that is genuinely a
    bare stub.

    Bytes, not a string literal: the codepage UTF8 directive at the top of this
    file would re-encode every byte >= 128 in a literal. A Byte array is immune,
    and scripts/check-codepage.py has nothing to object to here. }
  PACK_MARK_TAG_LEN = 16;          // the tag
  PACK_MARK_LEN     = 24;          // ...and an LE64 total file size behind it
  { $A7 $3C $D9 $5E "Pack" "edAp" $17 $B4 $6D $E2 -- readable in a hex editor,
    high-entropy at both ends so it cannot turn up in the binary by accident. }
  PACK_MARK_PACKED: array[0..PACK_MARK_TAG_LEN - 1] of Byte =
    ($A7, $3C, $D9, $5E, $50, $61, $63, $6B, $65, $64, $41, $70, $17, $B4, $6D, $E2);

var
  { NOT a const: a typed constant under the J- directive is read-only data the
    compiler may place wherever it likes, and this has to be an addressable,
    initialised global that lands in the image as bytes. The value is the BARE
    tag -- $A7 $3C $D9 $5E "Phos" "Stub" $17 $B4 $6D $E2 -- plus eight zero bytes
    where the packer writes the finished length. A binary carrying THIS is a bare
    stub and the CLI is what it should be. }
  GPackMark: array[0..PACK_MARK_LEN - 1] of Byte =
    ($A7, $3C, $D9, $5E, $50, $68, $6F, $73, $53, $74, $75, $62, $17, $B4, $6D, $E2,
     0, 0, 0, 0, 0, 0, 0, 0);

{ What this binary knows about itself WITHOUT reading its own tail: was it packed,
  and if so how long did the packer say the finished file would be? }
function StubWasPacked(out ATotal: Int64): Boolean;
var i: Integer;
begin
  ATotal := 0;
  Result := CompareByte(GPackMark[0], PACK_MARK_PACKED[0], PACK_MARK_TAG_LEN) = 0;
  if not Result then Exit;
  for i := 7 downto 0 do
    ATotal := (ATotal shl 8) or GPackMark[PACK_MARK_TAG_LEN + i];   // little-endian
end;

{ Where the running process's own mark sits inside a copy of that same process's
  file. Negative when it is not there EXACTLY once: none means the mark did not
  survive into the image and a packed file could never identify itself, twice
  means the packer cannot know which copy the loader will map, and writing an
  application that might not be able to tell it had been damaged is the defect
  this whole mark exists to close. Both are refusals, not warnings -- but they
  are DIFFERENT refusals to read, so they are different answers: -1 not found,
  -2 found more than once. Telling an operator "cannot find" about a mark that
  was found twice is a false sentence, and the only thing this path gives them
  is that sentence. }
function FindPackMark(const ABytes; ACount: Int64): Int64;
var p: PByte; i: Int64;
begin
  Result := -1;
  if ACount < PACK_MARK_LEN then Exit;
  p := @ABytes;
  for i := 0 to ACount - PACK_MARK_LEN do
    if (p[i] = GPackMark[0]) and
       (CompareByte(p[i], GPackMark[0], PACK_MARK_TAG_LEN) = 0) then
    begin
      if Result >= 0 then Exit(-2);      // twice is as bad as never
      Result := i;
    end;
end;

function SelfExePath: String;
{$IFDEF WINDOWS}
var buf: array[0..1023] of WideChar; n: DWORD; ws: WideString;
begin
  n := GetModuleFileNameW(0, @buf[0], Length(buf));
  SetLength(ws, n);
  if n > 0 then Move(buf[0], ws[1], n * SizeOf(WideChar));
  Result := UTF8Encode(ws);
end;
{$ELSE}
begin
  Result := fpReadLink('/proc/self/exe');
end;
{$ENDIF}

function PayloadChecksum(const ABytes; ACount: Int64): LongWord;
var p: PByte; i: Int64;
begin
  Result := LongWord(2166136261);   // FNV-1a, enough to catch corruption
  p := @ABytes;
  for i := 0 to ACount - 1 do
  begin
    Result := (Result xor p^) * LongWord(16777619);
    Inc(p);
  end;
end;

procedure WLE64(S: TStream; V: Int64);    begin V := NtoLE(V); S.WriteBuffer(V, 8); end;
function  RLE64(S: TStream): Int64;        begin S.ReadBuffer(Result, 8); Result := LEToN(Result); end;
procedure WLE32(S: TStream; V: LongWord);  begin V := NtoLE(V); S.WriteBuffer(V, 4); end;
function  RLE32(S: TStream): LongWord;     begin S.ReadBuffer(Result, 4); Result := LEToN(Result); end;

{ Compile AInBas, copy this running binary (the stub) to AOutExe, and append the
  .pbc payload plus the trailer -- a standalone executable that needs no install. }
function PackFile(const AInPbc, AOutExe: String; AFlags: LongWord): Integer;
var
  prog: TProgram;
  payload, stub: TBytesStream;
  src, dst: TFileStream;
  off, markAt, finished: Int64;
  pbcErr, missingReport: String;
  missing: Integer;
  isPbc: Boolean;
begin
  if not FileExists(AInPbc) then begin Writeln(StdErr, 'phosphor: file not found: ', AInPbc); Exit(2); end;

  // PACK TAKES BYTECODE, NOT SOURCE. One verb, one job: `compile` turns source
  // into a .pbc and `pack` turns a .pbc into an executable. Compiling inside pack
  // made a command whose work is copying bytes able to fail with a syntax error,
  // and hid a step that is worth doing once and packing many times.
  try
    isPbc := IsBytecode(AInPbc);
  except
    on Ex: Exception do
    begin
      Writeln(StdErr, 'phosphor: cannot read ', AInPbc, ': ', Ex.Message);
      Exit(2);
    end;
  end;
  if not isPbc then
  begin
    Writeln(StdErr, 'phosphor: pack takes compiled bytecode, and this is not a .pbc: ', AInPbc);
    Writeln(StdErr, '  compile it first, then pack what comes out:');
    Writeln(StdErr, '      phosphor compile ', AInPbc, ' app.pbc');
    Writeln(StdErr, '      phosphor pack app.pbc ', AOutExe);
    Exit(2);
  end;

  payload := TBytesStream.Create();
  try
    try
      src := TFileStream.Create(AInPbc, fmOpenRead or fmShareDenyNone);
      try payload.CopyFrom(src, 0); finally src.Free; end;
    except
      on Ex: Exception do
      begin
        Writeln(StdErr, 'phosphor: cannot read ', AInPbc, ': ', Ex.Message);
        Exit(2);          // the outer finally still frees payload
      end;
    end;
    // Read it back before embedding it. A .pbc from a different build is refused
    // by the loader at run time; refusing it HERE puts the failure in front of
    // the person who can fix it, instead of whoever is handed the executable.
    payload.Position := 0;
    if not ReadProgram(payload, prog, pbcErr) then
    begin
      Writeln(StdErr, 'phosphor: ', AInPbc, ': ', pbcErr);
      Exit(1);
    end;
    // AND REFUSE WHAT CANNOT RUN. A packed executable carries this binary as its
    // stub, so the host is known exactly here: a name this binary cannot provide
    // will never resolve in the file being written. The compiler could not have
    // said this -- it has no registry, and that is what lets one .pbc run on
    // hosts with different packages -- but pack has given that portability up on
    // purpose, and gets certainty in exchange.
    missing := NamesThisBinaryCannotProvide(prog, missingReport);
    prog.Free;
    if missing > 0 then
    begin
      Writeln(StdErr, 'phosphor: ', AInPbc, ': ', missing,
              ' function name(s) this binary cannot provide:');
      Write(StdErr, missingReport);
      Writeln(StdErr, '  A packed program has only the host packed with it. This .pbc');
      Writeln(StdErr, '  may still run under a host that registers them -- the test');
      Writeln(StdErr, '  runners register the assertion library, for instance.');
      Exit(1);
    end;
    payload.Position := 0;
    { BOTH streams are opened INSIDE the try/finally now. They used to be created
      on the two lines above it, so a failure to create the output leaked the
      stub's handle -- and there was no `except` anywhere on the path, so the
      failure itself was never reported at all: exit 0, nothing printed, no
      executable written. }
    src := nil;
    dst := nil;
    stub := nil;
    try
      try
        src := TFileStream.Create(SelfExePath(), fmOpenRead or fmShareDenyNone);
        { The stub goes through MEMORY rather than straight down the copy, because
          the mark has to be located in it and a scan wants the bytes in one
          piece. It is this executable: a few megabytes, once, in a verb whose
          whole job is copying a few megabytes. }
        stub := TBytesStream.Create();
        stub.CopyFrom(src, 0);
      except
        on Ex: Exception do
        begin
          Writeln(StdErr, 'phosphor: cannot read the stub ', SelfExePath(), ': ', Ex.Message);
          Exit(2);
        end;
      end;
      { LOCATED BEFORE THE OUTPUT EXISTS. A stub whose mark cannot be found writes
        no file at all, rather than a half-made application on disk that would
        have been unable to tell it had been damaged. }
      markAt := FindPackMark(stub.Memory^, stub.Size);
      if markAt < 0 then
      begin
        if markAt = -2 then
          Writeln(StdErr, 'phosphor: this binary''s own pack mark appears more than once in the stub:')
        else
          Writeln(StdErr, 'phosphor: cannot find this binary''s own pack mark in the stub:');
        Writeln(StdErr, '  ', SelfExePath());
        Writeln(StdErr, '  refusing to write an application that could not tell it had been truncated.');
        Exit(2);
      end;
      try
        dst := TFileStream.Create(AOutExe, fmCreate);
        if stub.Size > 0 then dst.WriteBuffer(stub.Memory^, stub.Size);  // the whole stub binary
        off := dst.Position;                  // the payload starts here
        if payload.Size > 0 then dst.WriteBuffer(payload.Memory^, payload.Size);
        WLE64(dst, off);
        WLE64(dst, payload.Size);
        WLE32(dst, PayloadChecksum(payload.Memory^, payload.Size));
        WLE32(dst, AFlags);
        dst.WriteBuffer(PACK_MAGIC_V2[1], 8);
        { THE MARK IS STAMPED LAST, because half of what it records is the
          finished LENGTH -- the fact that tells a truncated copy from an intact
          one. Seeking back overwrites 24 bytes in the middle of a file whose
          size is already settled, and the trailer's checksum covers the payload
          only, so nothing written above is disturbed. }
        finished := dst.Position;
        dst.Position := markAt;
        dst.WriteBuffer(PACK_MARK_PACKED[0], PACK_MARK_TAG_LEN);
        WLE64(dst, finished);
      except
        on Ex: Exception do
        begin
          Writeln(StdErr, 'phosphor: cannot write to ', AOutExe, ': ', Ex.Message);
          Exit(2);
        end;
      end;
    finally
      src.Free; dst.Free; stub.Free;         // nil-safe, and now reached either way
    end;
  finally
    payload.Free;
  end;
  {$IFDEF UNIX} FpChmod(AOutExe, &755); {$ENDIF}   // make it runnable
  Result := 0;
end;

type
  { What the tail of THIS executable says about itself. Three answers, where
    there used to be two -- and collapsing the last two into one bare `Exit` is
    what turned a damaged application into an interactive BASIC prompt.

      esNone     nothing identifies this file as packed -- no mark in its middle
                 and no magic in its tail. A bare stub: be the CLI. This is the
                 one case where falling through is right, and it stays.
      esOk       a trailer, and a payload behind it that verifies. Run it.
      esCorrupt  the file has positively identified itself as a packed
                 application -- through the magic in its tail, which is how the
                 offset, size and checksum were located in the first place, OR
                 through the compiled-in mark in its middle, which is how a file
                 whose tail is GONE still says what it is -- and what it carries
                 will not verify. There is nothing to run, and nothing to fall
                 back TO: the CLI with no arguments is a prompt that executes
                 whatever is typed and never ends on its own. }
  TEmbeddedState = (esNone, esOk, esCorrupt);

{ What THIS binary carries in its tail. AWhy is the sentence to print when the
  answer is esCorrupt. }
function TryReadEmbeddedPayload(out APayload: TBytesStream; out AFlags: LongWord;
  out AWhy: String): TEmbeddedState;
var
  fs: TFileStream;
  total, off, siz, wantTotal: Int64;
  ck: LongWord;
  trailer: Int64;
  marked: Boolean;
  magic: array[0..7] of Char;
begin
  Result := esNone;
  APayload := nil;
  AFlags := 0;
  AWhy := '';
  { ASKED BEFORE ANYTHING IS READ FROM DISK, because the answer is compiled in.
    See GPackMark: a packed application carries the packed tag and the
    length the packer finished with, and a bare stub carries neither. Nothing
    below can take that away from it. }
  marked := StubWasPacked(wantTotal);
  try
    fs := TFileStream.Create(SelfExePath(), fmOpenRead or fmShareDenyNone);
  except
    { A stub that cannot open its own file has nothing to run either way -- but
      only a MARKED one is an application, and an application that cannot reach
      its own program must not answer with a prompt. }
    if marked then
    begin
      AWhy := 'this application cannot open its own file to reach the program inside it';
      Exit(esCorrupt);
    end;
    Exit;   // nothing has claimed to be packed -> just be the CLI
  end;
  try
    total := fs.Size;
    { THE LENGTH THE PACKER RECORDED, checked before one byte of the tail is
      trusted. This is the whole truncation case: an interrupted copy, a partial
      write or an antivirus that cut the file short leaves a file that is exactly
      this binary and exactly this program, and shorter than the packer said. The
      tail cannot answer for that, because the tail is what went missing. }
    if marked and (total <> wantTotal) then
    begin
      if total < wantTotal then
        AWhy := Format('the file has been truncated: %d bytes, where the application packed here is %d',
                       [total, wantTotal])
      else
        AWhy := Format('the file has grown since it was packed: %d bytes, where the application packed here is %d',
                       [total, wantTotal]);
      Exit(esCorrupt);
    end;
    if total < PACK_TRAILER_V1 then Exit;   // marked cannot reach here: the length matched
    // The magic is the last 8 bytes whichever version this is, so it is read
    // FIRST and decides how much trailer to read back.
    fs.Position := total - 8;
    fs.ReadBuffer(magic[0], 8);
    if magic = PACK_MAGIC_V2 then trailer := PACK_TRAILER_V2
    else if magic = PACK_MAGIC_V1 then trailer := PACK_TRAILER_V1
    else if marked then
    begin
      { Right length, right mark, no magic: the tail was overwritten in place
        rather than cut off. Same answer -- there is a program here and the file
        no longer says where. }
      AWhy := 'the trailer that records where its program lives has been overwritten';
      Exit(esCorrupt);
    end
    else Exit;                                                 // a bare stub -> CLI

    { PAST THIS LINE THE FILE HAS SAID WHAT IT IS, so every remaining failure is
      a damaged packed application and never a bare stub. Not one of them may
      return esNone. decisions.md asks for a version that is "checked and
      refused out loud"; a payload behind a magic that WAS recognised was the
      one case that went unrefused -- and a file whose magic was CUT OFF was the
      next, which is why the mark above is asked first. }
    if total < trailer then
    begin
      AWhy := 'the file is shorter than the trailer it claims to carry';
      Exit(esCorrupt);
    end;
    fs.Position := total - trailer;
    off := RLE64(fs); siz := RLE64(fs); ck := RLE32(fs);
    if trailer = PACK_TRAILER_V2 then AFlags := RLE32(fs);
    if (off < 0) or (siz <= 0) or (off + siz > total - trailer) then
    begin
      AWhy := Format('the trailer places a %d-byte program at offset %d, which does not fit a %d-byte file',
                     [siz, off, total]);
      Exit(esCorrupt);
    end;
    if (AFlags and not PACK_FLAGS_KNOWN) <> 0 then
    begin
      AWhy := 'the trailer asks for options this build does not know ($' +
              IntToHex(AFlags, 8) + ')';
      Exit(esCorrupt);
    end;
    APayload := TBytesStream.Create();
    APayload.Size := siz;
    fs.Position := off;
    fs.ReadBuffer(APayload.Memory^, siz);
    if PayloadChecksum(APayload.Memory^, siz) <> ck then
    begin
      APayload.Free;
      APayload := nil;
      AWhy := 'the embedded program does not match the checksum stored with it';
      Exit(esCorrupt);
    end;
    APayload.Position := 0;
    Result := esOk;
  finally
    fs.Free;
  end;
end;

{ Run an embedded payload; a packed app ignores its CLI arguments. }
function RunEmbedded(APayload: TBytesStream): Integer;
var host: TConsoleHost; eng: TPhosphorEngine; line: Integer;
begin
  host := TConsoleHost.Create('');
  eng := TPhosphorEngine.Create();
  BindSandbox(eng);   // '' = unbounded; a root that will not bind is fatal
  try
    { '' because a packed application HAS no source path -- the program rides
      inside this binary. That is why the error diagnostic one line down prints
      a bare line number too; a breakpoint now matches it. }
    BindHostSeams(eng, host, '');
    RegisterAllPackages(eng);
    line := eng.RunBytecode(APayload);
    if line <> 0 then begin Writeln(StdErr, Format('phosphor: %d: %s', [line, eng.ErrorMessage])); Exit(1); end;
    Result := 0;
  finally
    eng.Free; host.Free;
  end;
end;

{ THIS HOST USED TO CLASSIFY THE COMPILER'S ERRORS BY READING THEM.

  A function here compared eng.ErrorMessage with nine string literals -- "expected
  'endif'", "expected 'next'", and seven more -- to decide whether the REPL should
  keep reading. Three things were wrong with that. The list was written from
  memory, so `next` was missing and a FOR loop, the one block a person is most
  likely to type at a prompt, was thrown away while the banner promised it would
  wait. The list could not be verified by anything: no compiler error, no gate and
  no golden connects a literal here to the Fail that produces it, so the compiler
  could be reworded and this host would go quiet and wrong. And it asked the
  question in the wrong place: whether a block is unfinished is something the
  PARSER knows and a reader of English is guessing at.

  The compiler now records it -- ErrorUnterminatedBlock -- and the guess is gone.
  ErrorAtEndOfInput is still the second half of the test, for the reason the
  comment at the call site gives. }
function Repl: Integer;
var
  host: TConsoleHost;
  eng: TPhosphorEngine;
  line, pending, waitingFor: String;
begin
  host := TConsoleHost.Create('');
  eng := TPhosphorEngine.Create();
  BindSandbox(eng);   // '' = unbounded; a root that will not bind is fatal
  try
    { '' because a line typed at a prompt has no file to name. Note that `trace 1`
      PERSISTS across REPL lines where it does not across file runs: the VM resets
      FTrace in Run and not in RunFrom, which is what the REPL uses. }
    BindHostSeams(eng, host, '');
    RegisterAllPackages(eng);
    host.Output('Phosphor BASIC ' + PhosphorVersion +
                ' -- REPL. Variables and functions persist across lines.'#10 +
                'Type a multi-line block and it waits for the terminator. ' +
                'Ctrl+Z then Enter to quit.'#10);
    pending := '';
    waitingFor := '';
    while True do
    begin
      if pending = '' then host.Output('phosphor> ') else host.Output('     ...> ');
      if not host.ReadLine(line) then
      begin
        host.Output(#10);
        { Input ended. If something was still open, SAY SO and fail: discarding it
          and answering 0 told anything that piped us a truncated file that the
          whole file had run. A person at a keyboard sees their own half-typed
          loop vanish; a script sees success. "Block or literal" rather than
          "block" because a multi-line JSON literal continues here too, and
          waitingFor then names a bracket rather than a keyword. }
        if pending <> '' then
        begin
          Writeln(StdErr, 'error: input ended inside an unfinished block or ',
                  'literal (', waitingFor, ')');
          Result := 2;
          Exit;
        end;
        Break;
      end;
      if pending <> '' then line := pending + #10 + line;
      if eng.ReplRun(line) <> 0 then
      begin
        { BOTH conditions, and they are different facts. The first says the failure
          is something opened and never closed -- a block, or a JSON literal spread
          over lines. The second says the input ran out rather than a wrong token
          turning up where the terminator belonged.

          THE FIRST IS THE ONE THAT ANSWERS, and that is worth stating plainly
          because an earlier draft of this comment justified the pair with `csae 2`
          for `case 2` and that justification is false: a misspelled case label
          reports False here, which tests/probe_limits.lpr now pins, so the second
          condition is not what saves the prompt from it.

          The second is the BELT. Fail infers it from the token the parser was
          actually looking at, for every failure the parser raises -- so a
          construct added to the compiler later that records "unterminated" at a
          REAL token cannot make this prompt wait for a continuation that can never
          arrive. That is the 2026-09-06 defect's shape, and it costs one `and` to
          keep shut. (It says False for a failure raised after the parse has read
          the whole line, such as a `goto` to a label that does not exist, because
          the lexer is parked at the end by then and the input did not run out.) }
        if eng.ErrorUnterminatedBlock and eng.ErrorAtEndOfInput then
        begin
          pending := line;              // not wrong, just unfinished -- read on
          waitingFor := eng.ErrorMessage;
          Continue;
        end;
        Writeln(StdErr, 'error: ', eng.ErrorMessage);
      end;
      pending := '';
      waitingFor := '';
    end;
    Result := 0;
  finally
    eng.Free;
    host.Free;
  end;
end;

{ A deterministic thing to run in a real terminal: reports whether the handles
  are consoles, then prints a known UTF-8 line through the same path the engine
  uses. On a fixed console it must render "Ola -- cafe -- acucar -- coffee --
  pi" with the proper accents and symbols. }
{ Bind the sandbox the command line asked for, and REFUSE TO RUN if it did not
  take.

  SetSandboxRoot answers '' when the root cannot be made -- and '' is also what it
  answers for "no sandbox was requested", so the two were indistinguishable and
  the property setter discarded the answer either way. A script the operator had
  explicitly confined with `--sandbox` then ran completely unconfined, silently,
  and exited 0. A security boundary that cannot be established must be a hard
  failure: the whole point of asking for it is that the run is not trusted.

  Reading the root back is what makes this checkable -- the engine reports the
  root actually in force, so "asked for one, got none" is a state the host can
  see.

  AND THE QUESTION IS "WAS THE FLAG GIVEN", NOT "IS THE VALUE NON-EMPTY". This
  line used to ask `GSandboxDir <> ''`, which reads the value to decide whether
  the operator asked for anything -- and '' is also how "no sandbox" is spelled,
  so `--sandbox ""` (an unset shell variable) skipped the check entirely and got
  exactly the unconfined, silent, exit-0 run this routine exists to prevent,
  while `--sandbox "   "` was refused. GSandboxGiven carries the fact the value
  could not. }
procedure BindSandbox(AEng: TPhosphorEngine);
begin
  AEng.SandboxRoot := GSandboxDir;
  if GSandboxGiven and (AEng.SandboxRoot = '') then
  begin
    Writeln(StdErr, 'phosphor: cannot establish the sandbox root ', GSandboxDir,
                    ' -- refusing to run unconfined');
    Flush(StdErr);
    Halt(2);
  end;
end;

{ An exception that escapes anywhere in this program.

  THIS BINARY LINKS THE LCL, and that alone is enough: the `Forms` unit routes
  unhandled exceptions to Application.HandleException, whose default is a MODAL
  DIALOG -- in a console run, with no window and no message loop, on a machine
  with nobody watching. It was seen on 2026-09-06: `phosphor f1_bad.pbc` on a
  corrupted bytecode file opened "Access violation. Press OK to ignore and risk
  data corruption." and sat there, holding a lock on its own executable, until
  someone clicked it.

  phosphorguitest has had this guard since the day a suite hung on it. When round
  31 merged the two hosts into one, the guard did not come along -- the merge
  moved the LCL into a binary that had never needed protecting from it.

  A crash must be a MESSAGE and an EXIT CODE. 3, distinct from a runtime error (1)
  and a compile error (2), so a script can tell an interpreter bug from a program
  that was wrong. The report itself is wrapped: after --no-console the standard
  handles may be closed, and a handler that raises while reporting a raise leaves
  the user with nothing at all.

  AND HANGING IT ON Application.OnException WAS NOT ENOUGH -- it is reached only
  through Application.HandleException, and that routine, twenty lines before it
  ever consults OnException, calls GetCapture: that is `WidgetSet.GetCapture`
  (lcl/include/winapi.inc:329), and WidgetSet is nil until CreateWidgetset has
  run. So on any path with no widgetset the guard itself faults, the LCL takes
  its re-entry break -- `HaltingProgram := true; Halt;` in
  TApplication.HandleException -- and a bare Halt exits with ExitCode, which is
  ZERO. `compile` and `pack` never create a widgetset; on a headless Linux box
  GuiPossible is False and NOTHING does. The guard covered exactly the paths
  that needed it least, and every other failure was a silent success.

  So Report is also called directly, from a try/except wrapped round the whole
  program body, where the exception never reaches the LCL at all. Both entries
  print the same sentence and Halt(3); the OnException one stays because a GUI
  program's exceptions arrive through the message loop instead. }
type
  TCrashGuard = class
    class procedure Report(Sender: TObject; E: Exception);
  end;

class procedure TCrashGuard.Report(Sender: TObject; E: Exception);
begin
  try
    Writeln(StdErr, 'phosphor: unhandled ', E.ClassName, ': ', E.Message);
    Flush(StdErr);
  except
    // nowhere left to say it; the exit code still carries the news
  end;
  Halt(3);   // never a dialog, never a wait
end;

function Diag: Integer;
var
  host: TConsoleHost;
begin
  host := TConsoleHost.Create('');
  try
    Writeln(StdErr, 'stdout is console: ', host.StdoutIsConsole());
    Writeln(StdErr, 'stdin  is console: ', host.StdinIsConsole());
    Writeln(StdErr, 'stderr is console: ', host.StderrIsConsole());
    Flush(StdErr);
    host.Output('UTF-8 check: Olá — café — açúcar — ☕ — π ≈ 3.14159'#10);
    Result := 0;
  finally
    host.Free;
  end;
end;

{ The whole command line, in a routine rather than in the program body, so the
  body can be nothing but the crash net wrapped round a single call. Every path
  out of here is a Halt; it does not return. }
procedure RunCommandLine;
var
  i, code: Integer;
  arg, filePath, outPath, packIn, packOut: String;
  packFlags: LongWord;
  packArgs: Integer;
  payload: TBytesStream;
  embFlags: LongWord;
  embState: TEmbeddedState;
  embWhy: String;
  { `phosphor debug`. The armed set is a fixed array rather than a dynamic one
    because it is filled by a flag parser that runs before anything is compiled,
    and 256 breakpoints is far past what a person types on a command line. }
  dbgLines: array[0..255] of Integer;
  dbgCount: Integer;
  dbgPort, dbgErr: Integer;
  dbgEntry: Boolean;
  dbgPath: String;
begin
  // A packed application: run the embedded .pbc and stop, ignoring CLI arguments.
  embState := TryReadEmbeddedPayload(payload, embFlags, embWhy);

  if embState = esCorrupt then
  begin
    { THE MAGIC WAS THERE, so this file has said out loud that it is a packed
      application -- and what it carries will not verify. Falling through to the
      CLI used to mean that a corrupted or tampered MyApp.exe, double-clicked by
      an end user or started by a service, opened an interactive BASIC prompt
      that runs whatever is typed into it and never ends by itself, while any
      script that shipped it saw exit 0.

      THE MAGIC IS NO LONGER THE ONLY WAY IT CAN SAY SO. A file truncated past
      its own trailer has lost the magic with everything else, and it used to
      answer "bare stub" for exactly that reason -- so the commonest corruption
      there is walked through the guard written for corruption. The compiled-in
      mark (see GPackMark) is in the middle of the file, where truncation
      cannot reach it, and a marked binary whose length or tail is wrong arrives
      here too.

      REFUSING means three things, and it has to mean all three. Say what
      happened. Do not wait -- no prompt, and never the LCL's modal dialog,
      because there may be no console and nobody watching. And leave an exit
      code a caller can act on: 2, which is what this host already answers when
      it will not run because what it was handed is wrong (a missing file, an
      output it cannot write, a sandbox root that will not bind). Not 1: that
      means the BASIC program failed, and this one never started.

      The report is wrapped for the same reason TCrashGuard's is -- a packed
      --no-console application may have no standard handles left. }
    try
      Writeln(StdErr, 'phosphor: this application''s embedded program is corrupt: ', embWhy);
      Writeln(StdErr, '  ', SelfExePath());
      Writeln(StdErr, '  refusing to run. Reinstall it, or repack it from the .pbc it was built from.');
      Flush(StdErr);
    except
      // nowhere left to say it; the exit code still carries the news
    end;
    Halt(2);
  end;

  if embState = esOk then
  begin
    // Asked for BEFORE the program runs, so a windowed application launched from
    // a file manager never flashes a console. Anything the program prints then
    // goes to the null device -- which is what "no console" means, and why the
    // flag is opt-in. Output redirected to a file or a pipe still lands.
    if (embFlags and PACK_FLAG_NOCONSOLE) <> 0 then CrtHideOwnConsole();
    code := RunEmbedded(payload);
    payload.Free;
    Halt(code);
  end;
  { esNone falls through on purpose: no mark and no magic, so this is a bare stub
    and the CLI below is the whole point of the binary. }

  // `phosphor debug [--port N] [--stop-at-entry] [--break N,N] <file.bas>`
  // With --port it speaks the Phosphor Debug Protocol to an editor listening on
  // loopback; without it, the terminal debugger below.
  if (ParamCount >= 1) and (ParamStr(1) = 'debug') then
  begin
    dbgPort := 0;
    dbgCount := 0;
    dbgEntry := True;    // the useful default: with no --break, stop on line one
    dbgPath := '';
    i := 2;
    while i <= ParamCount do
    begin
      arg := ParamStr(i);
      if arg = '--stop-at-entry' then
        dbgEntry := True
      else if arg = '--no-stop-at-entry' then
        dbgEntry := False
      else if arg = '--port' then
      begin
        Inc(i);
        if i > ParamCount then
        begin
          Writeln(StdErr, 'phosphor debug: --port needs a port number');
          Halt(2);
        end;
        Val(ParamStr(i), dbgPort, dbgErr);
        if (dbgErr <> 0) or (dbgPort < 1) or (dbgPort > 65535) then
        begin
          Writeln(StdErr, 'phosphor debug: --port wants 1..65535, got ', ParamStr(i));
          Halt(2);
        end;
      end
      else if arg = '--break' then
      begin
        Inc(i);
        if i > ParamCount then
        begin
          Writeln(StdErr, 'phosphor debug: --break needs one or more line numbers');
          Halt(2);
        end;
        if not ParseBreakList(ParamStr(i), dbgLines, dbgCount) then Halt(2);
        { An explicit --break means the person said where to stop, so entry is no
          longer implied. --stop-at-entry after it says both, and is honoured. }
        dbgEntry := False;
      end
      else if (Length(arg) > 0) and (arg[1] = '-') then
      begin
        Writeln(StdErr, 'phosphor debug: unknown option ', arg);
        Halt(2);
      end
      else if dbgPath = '' then
        dbgPath := arg
      else
      begin
        Writeln(StdErr, 'phosphor debug: one file at a time, got ', arg);
        Halt(2);
      end;
      Inc(i);
    end;
    if dbgPath = '' then
    begin
      Writeln(StdErr, 'phosphor debug: which file?');
      Writeln(StdErr, '  phosphor debug [--stop-at-entry] [--break N,N] <file.bas>');
      Halt(2);
    end;
    if dbgPort > 0 then
      Halt(DebugProtocol(dbgPath, dbgPort, dbgLines, dbgCount, dbgEntry))
    else
      Halt(DebugFile(dbgPath, dbgLines, dbgCount, dbgEntry));
  end;

  // `phosphor compile [--check] <in.bas> <out.pbc>` -- compile to bytecode and stop.
  if (ParamCount >= 1) and (ParamStr(1) = 'compile') then
  begin
    packFlags := 0;   // reused as "--check was given"
    packArgs := 0;
    packIn := '';
    packOut := '';
    for i := 2 to ParamCount do
    begin
      arg := ParamStr(i);
      if arg = '--check' then
        packFlags := 1
      else
      begin
        Inc(packArgs);
        if packArgs = 1 then packIn := arg
        else if packArgs = 2 then packOut := arg
        else
        begin
          Writeln(StdErr, 'phosphor: compile: unexpected argument: ', arg);
          Halt(2);
        end;
      end;
    end;
    if packArgs < 2 then
    begin
      Writeln(StdErr, 'usage: phosphor compile [--check] <in.bas> <out.pbc>');
      Halt(2);
    end;
    Halt(CompileFile(packIn, packOut, packFlags <> 0));
  end;

  // `phosphor pack [--no-console] <in.bas> <out.exe>` -- make a standalone
  // executable and stop. The flag is BAKED IN because a packed application ignores
  // its command line by design: the choice has to travel with the file.
  if (ParamCount >= 1) and (ParamStr(1) = 'pack') then
  begin
    packFlags := 0;
    packArgs := 0;
    packIn := '';
    packOut := '';
    for i := 2 to ParamCount do
    begin
      arg := ParamStr(i);
      if arg = '--no-console' then
        packFlags := packFlags or PACK_FLAG_NOCONSOLE
      else
      begin
        Inc(packArgs);
        if packArgs = 1 then packIn := arg
        else if packArgs = 2 then packOut := arg
        else
        begin
          Writeln(StdErr, 'phosphor: pack: unexpected argument: ', arg);
          Halt(2);
        end;
      end;
    end;
    if packArgs < 2 then
    begin
      Writeln(StdErr, 'usage: phosphor pack [--no-console] <in.pbc> <out' +
              {$IFDEF WINDOWS}'.exe>'{$ELSE}'>'{$ENDIF});
      Halt(2);
    end;
    Halt(PackFile(packIn, packOut, packFlags));
  end;

  filePath := '';
  outPath := '';
  i := 1;
  while i <= ParamCount do
  begin
    arg := ParamStr(i);
    if (arg = '--version') or (arg = '-v') then
    begin
      Writeln('Phosphor BASIC ', PhosphorVersion);
      Halt(0);
    end
    else if (arg = '--help') or (arg = '-h') then
    begin
      Writeln('usage: phosphor [run] <file.bas|file.pbc> [--out <path>]');
      Writeln('       phosphor debug [--stop-at-entry] [--break N,N] <file.bas>');
      Writeln('              stop and step: s step into, n step over, o step out,');
      Writeln('              c continue, w call stack, v variables, l list, q quit');
      Writeln('              with no --break it stops on the first statement; the');
      Writeln('              session is on stderr, so the program''s own output');
      Writeln('              stays clean and can still be redirected');
      Writeln('       phosphor compile [--check] <in.bas> <out.pbc>');
      Writeln('              --check warns about function names this host does not');
      Writeln('              have; it never fails, because the file may be meant');
      Writeln('              for a host that has them');
      Writeln('       phosphor pack [--no-console] <in.pbc> <out>   (standalone executable)');
      Writeln('              pack takes COMPILED bytecode: compile first, then pack');
      Writeln('              --no-console is baked into the file: a packed program');
      Writeln('              ignores its command line, so the choice travels with it');
      Writeln('       phosphor --no-console <file.bas>');
      Writeln('              hide the console window when this process owns one');
      Writeln('              (a terminal''s console is never touched); a packed');
      Writeln('              program calls crt_hideconsole() for the same effect');
      Writeln('       phosphor --sandbox <dir> <file.bas>');
      Writeln('              confine the script to <dir>: every file, directory and');
      Writeln('              channel it names must resolve inside, or it is refused');
      Writeln('              a GUI program needs no flag: this binary brings the');
      Writeln('              widgetset up when a graphical session is reachable');
      Writeln('       phosphor            (REPL)');
      Writeln('       phosphor --diag     (console/UTF-8 self-check)');
      Writeln('       phosphor --version');
      Halt(0);
    end
    else if arg = '--diag' then
      Halt(Diag())
    else if arg = '--gui' then
      // Accepted, and answered. It used to hand this file to a second binary;
      // there is only one binary now and it brings the GUI up by itself when a
      // session is there. Kept working rather than removed, and said out loud
      // rather than ignored -- a flag that quietly does nothing is worse than one
      // that is refused.
      Writeln(StdErr, 'phosphor: --gui is no longer needed; this binary runs GUI ' +
                      'programs directly (the flag is accepted and ignored)')
    else if arg = 'run' then
      { optional verb; ignore }
    else if arg = '--no-console' then
      // Hidden at STARTUP, before a line of the program runs, so a GUI program
      // launched from Explorer never flashes a console. It is a flag rather than
      // a default because a console is where PRINT goes, and a developer
      // debugging a windowed program wants it: the default keeps it.
      // A PACKED application ignores its command line, so a program that wants
      // this baked in calls crt_hideconsole() itself -- the same one rule.
      GHideConsole := True
    else if arg = '--sandbox' then
    begin
      Inc(i);
      if i > ParamCount then
      begin
        Writeln(StdErr, 'phosphor: --sandbox needs a directory');
        Halt(2);
      end;
      GSandboxDir := ParamStr(i);
      { RECORDED HERE, where the flag is actually seen. Whatever ParamStr gives
        back -- a directory, whitespace, or the empty string an unset shell
        variable expands to -- the operator asked to be confined, and BindSandbox
        answers for whether that took. }
      GSandboxGiven := True;
    end
    else if arg = '--out' then
    begin
      Inc(i);
      if i > ParamCount then
      begin
        Writeln(StdErr, 'phosphor: --out needs a path');
        Halt(2);
      end;
      outPath := ParamStr(i);
      { THE SAME SHAPE AS --sandbox ABOVE, ONE BRANCH DOWN, and it had the same
        hole: TConsoleHost.Create guards with `if AOutPath <> ''`, so '' is the
        encoding for "no --out was asked for" as well as what `--out "$LOG"`
        hands over when LOG is unset. The flag vanished and the program's output
        went to the terminal, at exit 0, with nothing said -- while `--out "   "`
        was refused on Windows and honoured on Linux: three answers to one intent.
        REFUSED HERE rather than carried down on a presence flag, because unlike
        a sandbox root there is nothing an empty path could ever open: the
        operator did not give a path, which is exactly what the branch above
        already says when --out is last on the line. }
      if outPath = '' then
      begin
        Writeln(StdErr, 'phosphor: --out needs a path');
        Halt(2);
      end;
    end
    else if filePath = '' then
      filePath := arg
    else
    begin
      Writeln(StdErr, 'phosphor: unexpected argument: ', arg);
      Halt(2);
    end;
    Inc(i);
  end;

  // Asked for AFTER the arguments are read and BEFORE the program runs, so a
  // windowed program launched from Explorer never flashes a console. The answer
  // is discarded on purpose: "there was no console of mine to hide" is not a
  // failure of the run, and the REPL below would have nowhere to print if it
  // were treated as one. crt_hideconsole() is the same act with an answer, for a
  // program that wants to know.
  if GHideConsole then CrtHideOwnConsole();

  if filePath <> '' then
    Halt(RunFile(filePath, outPath))
  else
    Halt(Repl());
end;

begin
  // FIRST, before anything can raise: take the LCL's modal crash dialog out of
  // the picture. See TCrashGuard above -- linking Forms is what puts it there,
  // and this binary links Forms whether or not a window is ever opened. This
  // entry catches what arrives through the message loop of a GUI program.
  Application.OnException := @TCrashGuard.Report;
  try
    RunCommandLine();
  except
    { AND THIS ENTRY CATCHES EVERYTHING ELSE, which is most of it. The one above
      is reached through Application.HandleException, which dereferences a nil
      WidgetSet on any path that never created one -- so `compile` and `pack`,
      and on a headless machine the entire program, used to die here with no
      message on either stream and an exit code of 0. A build script was told
      the artifact had been produced. See TCrashGuard for the whole mechanism.

      Catching the exception HERE means it never reaches the LCL: same sentence,
      same exit code 3, on every path and on every platform. }
    on E: Exception do TCrashGuard.Report(nil, E);
  end;
end.
