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
  {$IFDEF UNIX}BaseUnix, Unix, TermIO,{$ENDIF}   // TermIO for IsATTY
  // The LCL, named by its PARTS. Deliberately NOT `Interfaces`: that unit's only
  // content is a CreateWidgetset call in its initialization section, and on gtk2
  // that call opens the X display -- before main, so a binary that merely listed
  // it died on any machine without a session. Naming the widgetset unit directly
  // links the same code and leaves the call to us, to make when a session is
  // actually there. This is the whole reason one binary can do both jobs.
  Forms, Clipbrd, LCLType, InterfaceBase,
  {$IFDEF WINDOWS}Win32Int,{$ELSE}Gtk2Int,{$ENDIF}
  SysUtils, Classes, PhosphorEngine, PhosphorValue, PhosphorCompiler, PhosphorOpcodes,
  { PhosphorHandles for ONE NUMBER: LiveHandleCount, read either side of an
    `evaluate` so the answer is refused if the evaluation created or freed a
    handle. The handle registry is process-wide (its own header says so), so it
    is the one piece of program state a fresh VM does NOT isolate -- which makes
    it the one worth asserting rather than arguing about. See DoEvaluate. }
  PhosphorHandles,
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
  interpolates that same text raw (see every `phosphor: %s:%d: %s` site), so
  escaping it here would print a different name for the same file one line
  apart, and would double every backslash of every Windows path to guard against
  a file name a script cannot create. On Linux a file name MAY contain 0x0A, and
  such a name splits this frame exactly as it already splits this host's other
  diagnostics; that is a host-wide property of the `phosphor: ...` shape, not a
  property of breakpoints.

  THE SENTENCE THAT USED TO END THIS PARAGRAPH WAS FALSE, and dangerously so: it
  said a framed protocol carries its own length rather than trusting a newline.
  PDBP does not. It is one JSON object per line terminated by a single #10 -- see
  the protocol host below, which writes `AObj.AsJSON + #10`, and
  ../PhosphorIDE/docs/debug-protocol.md, which says the same from the other end.
  A reader who treated this file's comments as the specification and made the CODE
  match would put a length header on every frame and break the editor instantly.
  The conclusion it was reaching for survives, with the right reason: what makes a
  0x0A inside a value harmless is that fpjson ESCAPES it, not a length prefix.

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
  This host builds an engine at every door that runs one. The count is not
  written here, because it has been wrong twice: grep for the calls.

  THE INVARIANT IS NOT "EVERY Create IS BOUND", WHICH IS FALSE -- and it was
  written that way for one day, in a file whose history is that a sentence like it
  becomes a gate. The grep it invites finds SIX creates and FIVE binds. The sixth
  is EverythingThisBinaryProvides below, which builds a registry to enumerate
  names for `compile --check` and `pack` and frees it again; it runs no program,
  has no host to answer for, and is correctly unbound. Anyone writing that gate
  from the old sentence would have failed a correct line, or "fixed" it by binding
  host seams onto an engine with nothing behind them.

  EVERY ENGINE THAT RUNS A PROGRAM IS BOUND HERE. That is the invariant, and it is
  still one grep.

  It said "three independent doors: RunFile, RunEmbedded and Repl" until
  2026-09-18, by which time the debug protocol host and the terminal debugger had
  each added one. Each used to assign OnOutput and OnInput itself, which made filling a new
  seam a three-site edit that nothing checks: scripts/check-seams.py asks its
  question once per FILE, so a single `eng.OnBreakpoint := ...` anywhere in here
  turns the gate green while two of the three doors stay silent. That is the
  instance-instead-of-the-class failure written into the build, so the wiring
  moves here and the doors call it. Another door, or another seam, is then one
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
    { THE CONDITION ON EACH OF THEM, parallel to FBreaks and built in the same
      loop as it, in the one place that writes either.

      PARALLEL AND NOT A RECORD, which is the opposite of what the editor does
      with the same pair, and the reason is FBreaks itself: the engine's ArmDebug
      wants an array of Integer and nothing else, so a record here would be
      unpacked into one on every arm. The safety this gives up is bought back by
      confinement -- these two are written at ONE site (the setBreakpoints arm)
      and the invariant is one line long: every path through that loop that
      appends to one appends to the other. An empty string is an unconditional
      breakpoint, so the common case needs nothing. }
    FBreakConds: array of String;
    { WHAT THE BASE SOURCE COMPILES TO, worked out once per session.

      Every evaluation needs three numbers about the program WITHOUT the appended
      line: where the chunk will start, how many globals existed before it, and a
      hidden name the program has not got. Getting them meant compiling the source
      a second time, on every single evaluation -- and a CONDITION evaluates once
      per hit of its breakpoint, so a loop paid for it two thousand times.

      They cannot change. FSource is written once, in Create, and nothing else
      assigns it; the compiler is deterministic. Measured on a 606-line program
      with a condition on a 2000-iteration loop: 4,3 ms per hit before this and
      2,2 ms after, which is the second compile going away and nothing else.

      THE OTHER HALF IS STILL THERE and is not addressed: the chunk itself is
      recompiled per hit. A cache keyed on the expression would take the hit to
      microseconds -- TProgram.Patch can re-point the prologue's opPushConst
      instructions at fresh constants so the kept program does not grow, measured
      at 0 instruction growth over 10000 correct evaluations -- and it is not
      built here. What is built is the half that is three fields and no
      invalidation rule. }
    FBaseKnown: Boolean;
    FBaseCount: Integer;
    FBaseVars: Integer;
    FBaseHidden: String;
    FAction: TPhosphorDebugAction;
    FDisconnected: Boolean;
    FLaunched: Boolean;     // `launch` seen: the program may start
    FPendingArm: Boolean;   // a set arrived while running; arm at the next boundary
    { THE SOURCE THE PROGRAM WAS COMPILED FROM, snapshotted at launch and not
      re-read afterwards.

      It matters for `evaluate`, which compiles this text again with one line
      appended. The file on disk is NOT the same question: an editor with unsaved
      changes, or one that saved between the launch and the watch, would have
      this host answering about a program that is not the one standing still. The
      running VM's globals are indexed by a table THIS text produced, so an
      answer derived from any other text is not wrong by a line number, it is
      wrong by a variable.

      EnsureStoppable used to read the file for itself and now reads this, which
      closes the same hole one question earlier: the set of lines a breakpoint can
      bind to describes the program that is going to RUN. }
    FSource: String;
    FStoppable: TPhosphorLines;   // lines a breakpoint can actually bind to
    FStoppableKnown: Boolean;     // the source has been compiled once to find out
    { THE RUNNING VM, taken at the first stop and owned by the socket thread.
      PhosphorEngine.pas:171-180 says why it may not simply read DebugVM: that
      field is written and nil'd by the VM thread, so reading it from here races
      an object that thread may be freeing. The engine's own comment names the
      remedy -- take it at a stop, where the VM thread is parked inside the seam
      and cannot be freeing anything -- and this is it. Nil'd again the moment Run
      returns, under the same lock the reader reads it under, so the window where
      the pointer is dead and still visible does not exist. }
    FRunVM: TPhosphorVM;
    FPauseWanted: Boolean;  // a `pause` frame arrived: this stop is the editor's
    { PARKED IN THE SEAM AND ALREADY READING. Guarded by FLock, because the VM
      thread writes it and the socket thread reads it.

      Without it the reader nudged the VM for EVERY frame, including the ones that
      arrive while the program is stopped -- and a stopped VM is sitting in the
      wait loop reading the inbox already. The nudge then fired at the next
      boundary after the resume, as a `pause` stop nobody asked for, and the drain
      resumed silently from it. Harmless when that boundary is an ordinary line,
      and NOT harmless when it is an armed one: the breakpoint stop was replaced
      by a silent resume and simply did not happen.

      Measured, because the shape is narrow enough to miss: a loop whose body is a
      SINGLE line lost one stop of three, in both `for` and `while`, while a
      two-line body was unaffected -- with a one-line body the boundary that
      consumes the interrupt IS the armed one. }
    FVMParked: Boolean;
    FEditorEntry: Boolean;  // the editor asked to stop at entry (it usually does not)
    procedure EnsureStoppable;
    function InstalledLines: TJSONArray;
    procedure CloseTransport;
    procedure SendJSON(AObj: TJSONObject);
    procedure SendEvent(const AName: String; AExtra: TJSONObject);
    procedure SendError(ASeq: Integer; const AText: String);
    function TakeLine(out ALine: String): Boolean;
    procedure DoStackTrace(ASeq, ALine, ADepth: Integer);
    procedure DoVariables(ASeq, AFrameIx, ADepth: Integer);
    function EvaluateExpr(AFrameIx, ADepth: Integer; const AExpr: String;
      ACompileOnly: Boolean; out AValue, AKind, AError: String): Boolean;
    procedure DoEvaluate(ASeq, AFrameIx, ADepth: Integer; const AExpr: String);
    function Handle(const ARaw: String; ALine, ADepth: Integer): Boolean;
  public
    constructor Create(AEng: TPhosphorEngine; const APath, ASource: String);
    destructor Destroy; override;
    function Connect(APort: Integer): Boolean;
    procedure Push(const ALine: String);
    procedure InterruptVM;
    procedure InterruptRun;   // safe from the socket thread; see FRunVM
    procedure ReleaseRunVM;   // call the moment Run returns
    procedure SetInitial(const ABreaks: array of Integer; ACount: Integer;
                         AStopAtEntry: Boolean);
    procedure Arm;
    function ArmedAt(ALine: Integer): Boolean;
    function ConditionAt(ALine: Integer): String;
    function ShouldStopAt(ALine: Integer; ADepth: Integer;
      out AWhy: String): Boolean;
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
        if line <> '' then
        begin
          FOwner.Push(line);
          { AND WAKE THE PROGRAM. Without this the frame sits in the inbox
            until the next breakpoint -- or for ever, which is exactly what
            `pause` did: advertised in the handshake, never answered, the
            next frame the editor saw was `exited`. }
          FOwner.InterruptRun();
        end;
      end;
    TakeRun(runFrom, got);
    if Length(acc) > DBG_MAX_FRAME then
    begin
      FOwner.Push(#0);
      Break;
    end;
  end;
end;

constructor TDebugProto.Create(AEng: TPhosphorEngine; const APath, ASource: String);
begin
  inherited Create();
  FEng := AEng;
  FPath := APath;
  FSource := ASource;
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

{ THE SAME NUDGE, FROM THE SOCKET THREAD. This is what makes `pause` exist.

  Before it, the reader pushed a frame into the inbox and nothing woke the VM, so
  while a program ran NOTHING READ THE SOCKET: a `pause` sent half a second into a
  loop was answered by `exited` two seconds later, and `pause` was advertised
  `true` in the handshake the whole time. A capability that lies is worse than one
  that is absent, because the editor builds a button on it.

  FRunVM rather than FEng.DebugVM, and under the lock: the engine's comment at
  PhosphorEngine.pas:171-180 is explicit that reading DebugVM from another thread
  races the VM thread's own write. Between the two, this pointer is only ever read
  while the lock is held, and ReleaseRunVM nils it under the same lock before the
  VM is freed. InterruptDebug itself is an InterlockedExchange and is safe to call
  from anywhere -- the hazard was never the call, it was finding the object. }
procedure TDebugProto.InterruptRun;
begin
  FLock.Acquire();
  try
    { A PARKED VM NEEDS NO NUDGE -- it is in the wait loop reading the inbox
      already, and nudging it sets an interrupt that fires at the first boundary
      AFTER it resumes, as a pause stop nobody asked for. See FVMParked. }
    if (FRunVM <> nil) and (not FVMParked) then FRunVM.InterruptDebug();
  finally
    FLock.Release();
  end;
end;

procedure TDebugProto.ReleaseRunVM;
begin
  FLock.Acquire();
  try
    FRunVM := nil;
  finally
    FLock.Release();
  end;
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
  FEditorEntry := AStopAtEntry;   // what was asked for
  FStopAtEntry := True;           // what we arm with; see FRunVM
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

{ THE SET A BREAKPOINT CAN ACTUALLY BIND TO, worked out once and kept.

  docs/debug-protocol.md (PhosphorIDE) says the `lines` in a setBreakpoints reply
  is the set the host ACTUALLY INSTALLED, which may be smaller than the one asked
  for: a line holding no executable statement -- a blank line, a comment, `endif`
  -- has nowhere to stop. The editor draws the difference, so a breakpoint that
  will never fire looks different from one that will. That difference is the whole
  point of the reply, and this host was answering with the request echoed back.

  The engine already knows the answer -- TProgram.StoppableLines -- but it only
  knows it once something has compiled the source, and nothing had: the program is
  not compiled until eng.Run, which happens after `launch`, which is long after the
  editor asks. Prepare is not the way round that (it RUNS the top level, which
  would execute the program before the editor said go) and Run discards any
  prepared state anyway. So this compiles the source once, on its own, purely to
  read the line set off it -- the same TPhosphorCompiler the `compile` command
  uses, a few milliseconds on a program a person is editing -- and throws the
  program away. eng.Run compiles it again for real, which is the honest trade: one
  extra compile of a small file against an editor that can tell the user the truth.

  A source that does not compile leaves the set EMPTY and known. That is not a
  refusal: nothing is stoppable in a program that cannot run, the reply says so by
  being empty, and the compile error still arrives the way it always did, when the
  editor sends `launch`. }
procedure TDebugProto.EnsureStoppable;
var
  comp: TPhosphorCompiler;
  prog: TProgram;
begin
  if FStoppableKnown then Exit;
  FStoppableKnown := True;
  SetLength(FStoppable, 0);
  prog := nil;
  comp := TPhosphorCompiler.Create();
  try
    if comp.Compile(FSource, prog) then
      FStoppable := prog.StoppableLines;
  finally
    comp.Free;
    prog.Free;
  end;
end;

{ The reply's `lines`: what was asked for, keeping only what can bind, in the
  order it was asked for and without duplicates.

  NEVER `arr.Clone`, which is what stood here. Two defects in one expression: it
  echoed the REQUEST rather than the installed set, and `arr` is nil whenever the
  frame carried no `lines` key at all -- TJSONData.Clone is `virtual; abstract`, so
  that was a virtual call through nil, and the exception escaped into the VM thread.
  A conformant frame with one optional key left out KILLED THE DEBUGGEE. }
function TDebugProto.InstalledLines: TJSONArray;
var
  i, j: Integer;
  keep, seen: Boolean;
begin
  EnsureStoppable();
  Result := TJSONArray.Create();
  for i := 0 to High(FBreaks) do
  begin
    keep := False;
    for j := 0 to High(FStoppable) do
      if FStoppable[j] = FBreaks[i] then begin keep := True; Break; end;
    if not keep then Continue;
    { `a = 1 : b = 2` emits two opStmt on one line, and so does the inline
      `if c then ...` form, so the engine's set can repeat a line. The editor is
      told about a line once. }
    seen := False;
    for j := 0 to i - 1 do
      if FBreaks[j] = FBreaks[i] then begin seen := True; Break; end;
    if not seen then Result.Add(FBreaks[i]);
  end;
end;

{ Is ALine one of the editor's breakpoints? Asked of FBreaks, the set as the
  editor sent it, and not of the VM: the VM's copy is sorted, de-duplicated and
  filtered, and none of that matters for a question with one answer per call at
  the one boundary that asks it. }
function TDebugProto.ArmedAt(ALine: Integer): Boolean;
var
  i: Integer;
begin
  Result := False;
  if ALine <= 0 then Exit;
  for i := 0 to High(FBreaks) do
    if FBreaks[i] = ALine then Exit(True);
end;

{ The condition on the breakpoint at ALine, or '' for one that has none and for a
  line that has no breakpoint. Asked once per stop, over a handful of numbers. }
function TDebugProto.ConditionAt(ALine: Integer): String;
var
  i: Integer;
begin
  Result := '';
  if ALine <= 0 then Exit;
  for i := 0 to High(FBreaks) do
    if FBreaks[i] = ALine then
    begin
      if i <= High(FBreakConds) then Result := FBreakConds[i];
      Exit;
    end;
end;

{ SHOULD THIS STOP BE REPORTED TO THE EDITOR? True for every breakpoint without a
  condition, which is the answer that costs nothing.

  A CONDITION THAT CANNOT BE EVALUATED STOPS THE PROGRAM. It is the one judgement
  call in here and it goes the way it does because the alternative is a breakpoint
  that silently does not fire: a typo in a condition would turn a mark the user
  set into a mark that never reports, with no error anywhere and nothing to see.
  Stopping on it puts the mistake in front of the person who made it, on the line
  they made it on, which is where they can fix it. AWhy carries the reason so the
  `stopped` event can say why it stopped for something that is not true.

  A condition that evaluates to something that is NOT A BOOLEAN is the same case,
  and for the same reason. Phosphor's `if` refuses a non-boolean outright
  (PhosphorCompiler.pas ParseCondition), so `i% + 1` as a condition is not a
  truthiness question this host gets to answer differently from the language. }
function TDebugProto.ShouldStopAt(ALine: Integer; ADepth: Integer;
  out AWhy: String): Boolean;
var
  cond, value, kind, err: String;
begin
  AWhy := '';
  cond := ConditionAt(ALine);
  if cond = '' then Exit(True);
  if not EvaluateExpr(0, ADepth, cond, False, value, kind, err) then
  begin
    AWhy := Format('the condition %s could not be evaluated: %s', [cond, err]);
    Exit(True);
  end;
  if kind <> 'bool' then
  begin
    AWhy := Format('the condition %s is %s, not a true or false', [cond, kind]);
    Exit(True);
  end;
  Result := value = 'true';
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
    that disarming from inside a stop erases the re-entrancy guard with the set.

    STOP-AT-ENTRY IS ASKED FOR ONCE, AND ONLY BEFORE THE PROGRAM STARTS. The VM
    stores it as FDbgEntryPending (set in TPhosphorVM.ArmDebug -- cited by NAME
    because the line number this used to carry had rotted into the middle of an
    unrelated function, and no gate reads a number) and every ArmDebug sets
    that flag afresh, so re-arming mid-run with True schedules ANOTHER entry stop
    -- at whatever boundary happens to be next, which is not an entry at all. It
    showed up the moment re-arming while stopped began to work: a three-pass loop
    reported four stops, and the extra one was this. FRunVM is nil exactly until
    the first stop, which makes it the honest test for "the program has not
    started", and the entry stop this asks for is the one that captures it. }
  FEng.ArmDebug(lines, FStopAtEntry and (FRunVM = nil));
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
  i, ix, ln: Integer;
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
    { THE LINE EACH FRAME IS STANDING ON, and it is off by one from where it
      looks. The innermost activation's line is the boundary the VM stopped at,
      which the seam handed us as ALine. Every other activation is parked in the
      middle of a call, and the line of that call is recorded on the frame it
      called INTO -- `i + 1`, not `i`, because a frame carries the line of its
      own CALLER. `(main)` is i = -1 and takes frame 0's.

      This used to report 0 for every frame but the innermost, on the grounds
      that the VM kept no return line per frame. It kept one all along:
      TCallFrame.CallerStmtPC has ridden on every activation since faults learned
      to resume in the caller, and DbgFrameCallerLine only reads it.

      A frame whose line still cannot be named reports 0, which the editor reads
      as "no line" and draws as an empty cell. It must never come to mean line
      zero. }
    if ix = 0 then
      f.Add('line', ALine)
    else if vm <> nil then
    begin
      ln := vm.DbgFrameCallerLine(i + 1);
      if ln > 0 then f.Add('line', ln) else f.Add('line', 0);
    end
    else
      f.Add('line', 0);
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

{ EVALUATE: AN EXPRESSION, A FRAME, AND A VALUE -- AND NOT ONE LINE OF NEW
  LANGUAGE.

  THE PROBLEM. docs/debug-protocol.md's `evaluate` section carries one sentence
  that decides the whole shape: "Evaluation must not change the program's state:
  no assignment, no call to a function with side effects that the host cannot
  undo. A host that cannot guarantee that must report evaluate:false rather than
  offering a half-safe one." Everything below is what it takes to be able to say
  "guarantee" honestly.

  WHAT IS NOT DONE, AND WHY EACH WAS REJECTED WITH A MEASUREMENT.

    * A SECOND EXPRESSION READER, in this file or in an engine unit beside the
      compiler. It works -- it was built and checked against the engine over 77
      expressions -- and it is a SECOND COPY OF THE LANGUAGE. Phosphor's
      precedence is not a table anything can share: it is eleven private
      procedures with the operator sets written inline at the site that consumes
      them (PhosphorCompiler.pas:148-157 declared, :916-1465 the bodies, the sets
      at :1353, :1370, :1382, :1342, and `not`/`and`/`or` as string comparisons
      because the lexer has no keyword table). Two of its irregularities are
      exactly what a re-implementation gets wrong: `^` is LEFT-associative with a
      primary base, so `-2^2` is -4 and `2^3^2` is 64 (:1331-1346); and
      ParseComparison is an `if` and not a `while`, so `a < b < c` does not chain
      (:1378-1398). The sibling repository has spent three roadmap items on rules
      that existed twice and drifted. This one does not add a fourth.

    * RUNNING THE EXPRESSION IN THE DEBUGGEE'S OWN VM. That needs every field a
      run moves saved and put back -- a list fifteen fields long, which is a
      SNAPSHOT of what ExecFrom touches and has no test that is not a second copy
      of itself. Add a counter to the VM, forget to add it there, and the result
      is a debugger that quietly perturbs the program it is watching: no error,
      no warning, and only the output to show it. A fresh VM has nothing to
      restore, which is not a smaller version of that problem but the absence of
      it.

    * ANSWERING ONLY A NAME. Measured against a live session: every name a
      `variables` response contains is answerable, and nothing else is -- both
      read the same two tables through the same accessors at the same stop. A
      capability that promises the editor information it is already holding is
      the wrong kind of lie to tell a program that greys out a menu on it.

  WHAT IS DONE, in five steps.

  1. COMPILE THE WHOLE SOURCE AGAIN, with one line appended:
     `<hidden> = (<expr>)`. The appended line can only ADD names and instructions;
     every earlier global index and every earlier instruction is bit-identical.
     That is the property TPhosphorEngine.ReplRun has rested on since the REPL
     existed (PhosphorEngine.pas:117-131) and it was checked for this rather than
     taken: over 154 real programs in the two repositories, the whole prefix --
     opcode, A, B and Line on every instruction, the global table, the function
     entries and their local counts -- is identical. It costs one compile, and a
     compile is 0,9 ms on the mean of 7558 .bas files here, 15,7 ms on the worst.

     The hidden name has to be one the LEXER accepts, so it is forgeable, so it
     is CHOSEN AGAINST THE PROGRAM rather than assumed free. The compiler's own
     temporaries begin with '#h' precisely because '#' cannot start an identifier
     -- which also means the compiler cannot PARSE one, since it makes those names
     through VarIndex and never by reading them. PhosphorCompiler.pas:437-447
     records what a forgeable temporary cost the last time: a script that wrote
     `__h0` was handed a SELECT subject's slot.

  2. REFUSE WHAT WAS EMITTED, not what was typed. This is the load-bearing
     decision and it is the opposite of the obvious one. A text rule cannot work:
     `expr` is a string an editor sends verbatim, and `total) : total = 99 :
     println (1` is a legal line whose middle statement writes a global. Most such
     smuggles happen to be refused by the compiler -- but BY ACCIDENT, on the
     trailing fragment failing to be a statement, not on the payload; balance the
     tail and the compiler accepts all of them. A comment defeats any scheme that
     neutralises the tail by appending a terminator, because a comment eats the
     terminator. None of that is visible to a text rule and all of it is obvious
     in the instruction stream, which is where the gate is: the chunk may contain
     only opcodes that compute, and exactly ONE store -- the last instruction,
     into the slot this host itself named. 39 hostile strings were measured
     against it, including the whole comment family; none passed.

     `=` INSIDE AN EXPRESSION IS A COMPARISON (opEQ), never a store, so the only
     opStoreVar an honest expression can produce is ours. And `and`/`or` emit
     opAnd/opOr over both operands rather than jumps (PhosphorCompiler.pas:1422-
     1442), so a legal expression has no control flow in it at all.

     opLoadLocal is DELIBERATELY not in the allowed set. The appended line is at
     the top level so the compiler cannot emit one for it, and the VM this runs on
     has no frames, so `FFrames[FFrameSP - 1]` would read past the bottom of the
     frame stack. An opcode that cannot legitimately appear should stop the
     request, not be made room for.

  3. THE THREE CALLS THAT ARE NOT CALLS. Every registered name is refused --
     `len`, `abs`, `mid$`, all 1145 of them -- because TPhosphorRegistry carries
     no notion of an effect (its whole answer is Found/IsHost/Func, and IsHost is
     orthogonal to purity), so this host cannot tell `len` from `kill` and must
     not guess. The exceptions are `arr_get`, `strline$` and `strchar$`, and they
     are not a purity judgement about the library: they are what the COMPILER'S
     OWN BRACKET SUGAR lowers to (PhosphorCompiler.pas:1035, :1046, :1056). A user
     who writes `a@[1]` has written no call. Refusing them would mean a debugger
     that renders an array as `@1` in the variables pane and then refuses to look
     inside it, which is the only door out of that pane.

     A USER FUNCTION SHADOWS A REGISTRY NAME AT THE SAME ARITY (opCall asks
     FindUserFunc first), so a program defining `function arr_get(a, b)` would
     turn the sugar into arbitrary code. Each of the three is allowed only when
     the program defines nothing of that name and arity.

  4. SEED A FRESH VM FROM THE STOPPED ONE. After the chunk, an opHalt (so the
     chunk's fall-through ends the run rather than re-entering the prologue), then
     a prologue of PushConst/StoreVar pairs -- every global as the stopped VM
     holds it, then the chosen frame's locals OVER the globals of the same name --
     and an opJump to the chunk. Seeding the locals last IS the language's own
     shadowing rule and not a second copy of it: the compiler resolved the name to
     the global's index because the appended line is at the top level, and
     overwriting that index with the local's value is what an inner binding means
     (PhosphorCompiler.pas:513-519, which asks the inner binding first in both
     directions). A `const` needs nothing at all: it never reaches runtime, and
     compiling the whole source means the compiler still has it in scope.

  5. RUN IT SOMEWHERE THAT CANNOT REACH THE PROGRAM. A VM created here, freed
     here, with no OnOutput, no OnInput, no OnBreakpoint and no OnDebug, and its
     own ceilings. It shares the process-wide handle registry, which is why step 3
     matters: a read through it is a read, and nothing else is allowed through.

  WHAT WAS MEASURED, from inside a real stop and not at the top level: a local, a
  local shadowing a global, the same name resolved at `(main)`, a parameter, a
  const, a global and a local in one expression, a name nobody has, a call, an
  injection and a fault -- and afterwards every global, every local of every
  frame, and err()/errmsg$()/erl() byte-identical. And the program RAN ON to the
  end under a step ceiling proven to bite it 6000 steps lower.

  WHAT IT STILL CANNOT DO, said plainly because the error string is the only other
  place it is said: it cannot call anything. `len(name$)` is refused. Widening it
  needs the registry to be able to answer whether a function has an effect, which
  is a different piece of work and is not scoped. }

const
  { EVERYTHING AN EXPRESSION NEEDS AND NOTHING THAT WRITES. opStmt is the
    statement marker the appended line itself emits; opPop cannot appear in an
    assignment and costs nothing to allow. The single store is counted
    separately -- see DoEvaluate. }
  DBG_EVAL_PURE = [opNop, opPushConst, opPop, opNeg, opAdd, opSub, opMul,
                   opDivReal, opDivInt, opPow, opMod, opEQ, opNE, opLT, opLE,
                   opGT, opGE, opLoadVar, opAnd, opOr, opNot, opStmt];

  { An evaluation is a handful of instructions plus two per global. These bound
    the pathological expression rather than the ordinary one: `a$ + a$ + a$ ...`
    is legal, allocates, and would otherwise be bounded by nothing at all,
    because the shipped host sets no budget on the debuggee either. }
  DBG_EVAL_MAX_STEPS = 2000000;
  DBG_EVAL_TIMEOUT_MS = 2000;
  DBG_EVAL_MAX_BYTES = 256 * 1024 * 1024;

{ Is this opCall one of the compiler's own bracket lowerings, and does the
  program leave the name alone? See step 3 above. }
function DbgEvalCallAllowed(AProg: TProgram; const AName: String;
                            AArgc: Integer): Boolean;
begin
  Result := False;
  if AProg.FindUserFunc(AName, AArgc) >= 0 then Exit;   // the program shadows it
  if (AName = 'arr_get') and (AArgc >= 2) and (AArgc <= 4) then Exit(True);
  if ((AName = 'strline$') or (AName = 'strchar$')) and (AArgc = 2) then Exit(True);
end;

{ A GLOBAL NAME THE PROGRAM HAS NOT GOT, in one pass over its table.

  THE FIRST CUT WAS A `repeat` THAT TRIED CANDIDATES until one was free, and
  scripts/check-budget.py refused it -- rightly. Its bound was real but it was an
  argument rather than a shape: a program declaring `__eval`, `__eval1` ...
  `__evalN` would have made it rescan the whole table once per candidate, a
  product where a sum will do. Written this way the bound is the table itself,
  which is what that gate reads as bounded, and no reasoning has to be trusted.

  THE PIGEONHOLE IS WHY THERE IS NO FAILURE ARM: there are VarCount globals and
  VarCount + 1 candidates (`__eval`, then `__eval1` .. `__evalVarCount`), so at
  least one is always free. The final Result exists to satisfy the compiler. }
function DbgEvalHiddenName(ABase: TProgram): String;
var
  i, n: Integer;
  taken: array of Boolean;
  nm: String;
begin
  SetLength(taken, ABase.VarCount + 1);
  for i := 0 to High(taken) do taken[i] := False;
  for i := 0 to ABase.VarCount - 1 do
  begin
    nm := ABase.GlobalName(i);
    if Copy(nm, 1, 6) <> '__eval' then Continue;
    if Length(nm) = 6 then
      taken[0] := True
    else if TryStrToInt(Copy(nm, 7, Length(nm)), n)
            and (n >= 1) and (n <= High(taken)) then
      taken[n] := True;
  end;
  for i := 0 to High(taken) do
    if not taken[i] then
    begin
      if i = 0 then Exit('__eval');
      Exit('__eval' + IntToStr(i));
    end;
  Result := '__eval';     // unreachable: see the pigeonhole above
end;

{ THE EVALUATOR ITSELF, with no protocol in it.

  IT WAS `DoEvaluate` AND IT ANSWERED IN JSON, which was right while `evaluate`
  was the only thing that wanted an answer. A CONDITION ON A BREAKPOINT WANTS THE
  SAME ANSWER AND NO FRAME: it asks at a stop, believes or disbelieves, and the
  editor is told nothing unless the program actually stops. Two callers, one of
  which must not send anything, is what splits this in half.

  The split is the whole point. There is ONE evaluator, so a condition and a watch
  cannot come to disagree about what an expression means -- which is the failure
  this pair of repositories has now spent five roadmap items avoiding. What is
  above this line is the argument for the gate and the fresh VM; it applies to
  both callers because there is only one of it.

  False with AError set, or True with AValue and AKind. AError is a sentence for a
  person, already the host's own wording, and never a code. }
function TDebugProto.EvaluateExpr(AFrameIx, ADepth: Integer; const AExpr: String;
  ACompileOnly: Boolean; out AValue, AKind, AError: String): Boolean;
var
  live, vm: TPhosphorVM;
  running, prog: TProgram;
  comp: TPhosphorCompiler;
  expr, hidden, nm, err: String;
  i, j, baseCount, baseVars, chunkStart, prologue, stores: Integer;
  slot, vmFrame, fn, nLocals, gi, handlesBefore: Integer;
  ins: TInstr;
  v: TValue;
  known: Boolean;

  { Every refusal in here used to be a `SendError` and is now this. The bodies
    below are unchanged apart from the verb, deliberately: the wording is what an
    editor shows a person, and a refactor is a poor moment to reword a diagnostic. }
  procedure Fail(const AText: String);
  begin
    AError := AText;
  end;

begin
  Result := False;
  AValue := '';
  AKind := '';
  AError := '';
  { COMPILE-ONLY NEEDS NO PROGRAM AND NO STOP, and that is the whole reason it
    exists. A CONDITION IS TYPED LONG BEFORE THE PROGRAM RUNS. The editor sets a
    breakpoint with one while nothing is executing, and the answer a person wants
    -- "that is not an expression" -- is available then: it is a compile and a walk
    over what the compile emitted, neither of which touches a VM.

    What it CANNOT answer then is whether a name is in scope, because scope is a
    frame and there is no frame yet. That refusal arrives at the first stop on
    that line and nowhere earlier; see the loop below, which is skipped here for
    exactly that reason. Promising more would be promising a check this host
    cannot make. }
  live := nil;
  running := nil;
  vmFrame := -1;
  if not ACompileOnly then
  begin
    live := FEng.DebugVM;
    if live = nil then
    begin
      Fail('no program is executing');
      Exit;
    end;
    running := live.DbgProgram();
    if (running = nil) or (not running.HasNames) then
    begin
      Fail('this program carries no variable names (it came from a .pbc)');
      Exit;
    end;
  end;
  { THE SAME FRAME MAPPING AND THE SAME REFUSAL AS `variables`, deliberately
    literally: frame 0 is innermost, the VM numbers them the other way, and
    vmFrame = -1 is the legal `(main)` activation rather than an error. Two
    answers about the same stop that disagreed about what `frame` means would be
    worse than either. }
  if not ACompileOnly then
  begin
    vmFrame := ADepth - 1 - AFrameIx;
    if (AFrameIx < 0) or (vmFrame < -1) then
    begin
      Fail(Format('no frame %d', [AFrameIx]));
      Exit;
    end;
  end;
  expr := Trim(AExpr);
  if expr = '' then
  begin
    Fail('evaluate needs an expression');
    Exit;
  end;

  { --- 1. THE BASE, COMPILED ALONE, says where the chunk begins and which names
          the program already has. It compiled once to run, so a failure here is
          not the user's expression and is reported as itself.

          ONCE PER SESSION, not once per evaluation: see FBaseKnown. ------- }
  if not FBaseKnown then
  begin
    prog := nil;
    comp := TPhosphorCompiler.Create();
    try
      if not comp.Compile(FSource, prog) then
      begin
        Fail(Format('the program no longer compiles: %s', [comp.ErrorMessage]));
        Exit;
      end;
    finally
      comp.Free;
    end;
    FBaseCount := prog.Count;
    FBaseVars := prog.VarCount;
    FBaseHidden := DbgEvalHiddenName(prog);
    FBaseKnown := True;
    prog.Free;
  end;
  baseCount := FBaseCount;
  baseVars := FBaseVars;
  hidden := FBaseHidden;

  prog := nil;
  comp := TPhosphorCompiler.Create();
  try
    if not comp.Compile(FSource + hidden + ' = (' + expr + ')'#10, prog) then
    begin
      { THE LINE NUMBER IS OURS, NOT THE USER'S. The appended line is one past the
        end of their file and a message naming it would send an editor to a line
        that is not there. }
      Fail(comp.ErrorMessage);
      Exit;
    end;
  finally
    comp.Free;
  end;

  try
    fn := -1;
    nLocals := 0;
    if vmFrame >= 0 then
    begin
      fn := live.DbgFrameFunc(vmFrame);
      nLocals := live.DbgFrameLocalCount(vmFrame);
    end;

    { --- 2. THE GATE, over what was emitted ----------------------------------- }
    chunkStart := baseCount;
    stores := 0;
    for i := chunkStart to prog.Count - 1 do
    begin
      ins := prog.Instr(i);
      if ins.Op in [opStoreVar, opStoreLocal] then
        Inc(stores)
      else if ins.Op = opCall then
      begin
        nm := ValToStr(prog.Consts.Get(ins.A));
        if not DbgEvalCallAllowed(prog, nm, ins.B) then
        begin
          Fail(Format('evaluate does not call functions, and "%s" is one. ' +
            'Only a@[i], s$[n] and s$[[n]] reach a call, because the compiler puts ' +
            'them there', [nm]));
          Exit;
        end;
      end
      else if not (ins.Op in DBG_EVAL_PURE) then
      begin
        Fail('evaluate computes a value and changes nothing; this does more');
        Exit;
      end;
    end;
    if (stores <> 1) or (prog.Instr(prog.Count - 1).Op <> opStoreVar)
       or (prog.GlobalName(prog.Instr(prog.Count - 1).A) <> hidden) then
    begin
      Fail('evaluate takes one expression, not a statement');
      Exit;
    end;
    slot := prog.Instr(prog.Count - 1).A;
    { THE HIDDEN SLOT TAKES ANY KIND. Its name carries no type suffix, so the
      compiler typed it vtNumber and `nome$` answered "cannot store string into
      number variable" -- this host's own scaffolding talking. vtAny is what the
      compiler gives its own temporaries for the same reason: a generated name has
      no suffix to derive a type from (PhosphorCompiler.pas:427-432). }
    prog.VarTypes[slot] := vtAny;

    { EVERYTHING PAST HERE NEEDS A STOP. The chunk has compiled and the gate has
      passed it, which is the whole of what can be decided about an expression
      without one. }
    if ACompileOnly then
    begin
      Result := True;
      Exit;
    end;

    { --- A NAME THAT IS NEITHER A GLOBAL NOR A LOCAL OF THIS FRAME -------------
      In this language an undeclared name is a global that reads as its default,
      so a typo would answer 0 and say nothing -- and a `const`, which reaches no
      table at runtime, would answer 0 while the program computes with 10. The
      chunk makes both visible for free: a global index at or past the base
      program's VarCount is a name the appended line INVENTED. It is legal only
      when the chosen frame has a local of that name, which is what the prologue
      below is about to supply. (A const does not reach here at all: the compiler
      folded it to an opPushConst.) }
    for i := chunkStart to prog.Count - 1 do
    begin
      ins := prog.Instr(i);
      if (ins.Op <> opLoadVar) or (ins.A < baseVars) then Continue;
      nm := prog.GlobalName(ins.A);
      known := False;
      for j := 0 to nLocals - 1 do
        if prog.LocalName(fn, j) = nm then
        begin
          known := True;
          Break;
        end;
      if not known then
      begin
        Fail(Format('no variable "%s" here', [nm]));
        Exit;
      end;
    end;

    { --- 4. THE PROLOGUE ------------------------------------------------------ }
    prog.Emit(opHalt, 0, 0, 0);
    prologue := prog.Count;
    for i := 0 to live.DbgGlobalCount() - 1 do
    begin
      if i >= prog.VarCount then Break;
      prog.Emit(opPushConst, prog.Consts.Add(live.DbgGlobal(i)), 0, 0);
      prog.Emit(opStoreVar, i, 0, 0);
    end;
    for j := 0 to nLocals - 1 do
    begin
      nm := prog.LocalName(fn, j);
      if nm = '' then Continue;
      gi := -1;
      for i := 0 to prog.VarCount - 1 do
        if prog.GlobalName(i) = nm then
        begin
          gi := i;
          Break;
        end;
      if gi < 0 then Continue;      // the expression never mentioned it
      prog.Emit(opPushConst, prog.Consts.Add(live.DbgLocal(vmFrame, j)), 0, 0);
      prog.Emit(opStoreVar, gi, 0, 0);
    end;
    prog.Emit(opJump, chunkStart, 0, 0);

    { --- 5. A VM THAT CANNOT REACH THE PROGRAM -------------------------------- }
    vm := TPhosphorVM.Create();
    try
      vm.Registry := FEng.Registry;   // arr_get and the two string lowerings
      vm.MaxSteps := DBG_EVAL_MAX_STEPS;
      vm.TimeoutMs := DBG_EVAL_TIMEOUT_MS;
      vm.MaxMemoryBytes := DBG_EVAL_MAX_BYTES;
      { THE ONE THING A FRESH VM DOES NOT ISOLATE. Variables, frames, the stack,
        the error state and the ceilings all belong to the VM object and are
        thrown away with it. The HANDLE REGISTRY does not: it is process-wide
        (PhosphorHandles.pas, its header), so the array a handle names is the
        program's own array and a call that created or freed one would be a
        change this design could not undo. Nothing allowed through the gate does
        -- arr_get is fifteen lines of read (PhosphorArrayLib.pas:245-260) -- and
        that is the sentence worth checking rather than repeating. }
      handlesBefore := LiveHandleCount();
      if not vm.RunFrom(prog, prologue) then
      begin
        err := vm.LastError.Message;
        if err = '' then err := 'the expression could not be evaluated';
        Fail(err);
        Exit;
      end;
      if LiveHandleCount() <> handlesBefore then
      begin
        { NO ANSWER IS SENT. An evaluation that moved the handle table changed the
          program, and the protocol's rule is that a host which cannot guarantee
          otherwise says so rather than offering the value anyway. }
        Fail(Format('evaluate changed the program (handles went from ' +
          '%d to %d) and the answer is withheld', [handlesBefore, LiveHandleCount()]));
        Exit;
      end;
      v := vm.DbgGlobal(slot);
      { RENDERED BY THE SAME TWO FUNCTIONS `variables` uses, because a second
        renderer is a second set of rules to keep in step -- and the protocol
        says the editor does not format values. }
      AValue := ValToStr(v);
      AKind := DbgKindName(v);
      Result := True;
    finally
      vm.Free;
    end;
  finally
    prog.Free;
  end;
end;

{ `evaluate`, the request: the evaluator above, rendered as one frame. }
procedure TDebugProto.DoEvaluate(ASeq, AFrameIx, ADepth: Integer;
                                 const AExpr: String);
var
  o: TJSONObject;
  value, kind, err: String;
begin
  if not EvaluateExpr(AFrameIx, ADepth, AExpr, False, value, kind, err) then
  begin
    SendError(ASeq, err);
    Exit;
  end;
  o := TJSONObject.Create();
  o.Add('seq', ASeq);
  o.Add('ok', True);
  o.Add('result', value);
  o.Add('kind', kind);
  SendJSON(o);
end;

{ One request. Returns True when the answer resumes the program, so the stop loop
  knows to leave. ALine/ADepth are where the VM is; they are -1/0 while running. }
function TDebugProto.Handle(const ARaw: String; ALine, ADepth: Integer): Boolean;
var
  d: TJSONData;
  o, res, caps: TJSONObject;
  arr, el, conds: TJSONData;
  rejected: TJSONArray;
  rej: TJSONObject;
  cmd, cond, evVal, evKind, evErr: String;
  seq, i, n: Integer;
  v: Int64;
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
      { TRUE SINCE 2026-09-17, AND TRUE FOR A REASON THAT CAN BE CHECKED rather
        than promised. The paragraph that stood here said there is no
        side-effect-free expression entry point in this engine, and there still
        is not: `evaluate` does not gain one, it borrows the whole compiler and
        then REFUSES what it emitted unless the instruction stream is incapable
        of changing anything. See DoEvaluate for the argument and for what it
        costs -- notably that `len(x$)` is refused along with every other
        registered name, because the registry carries no notion of an effect. }
      caps.Add('evaluate', True);
      { AND THE SECOND KEY, because `evaluate: true` alone would be a half-truth.
        What this host evaluates is NAMES, OPERATORS AND INDEXING -- it performs
        no call the user wrote, so `len(x$)` is refused and always will be until
        the registry can say whether a function has an effect. An editor building
        a watch pane wants to know that before it offers a box; finding out one
        refusal at a time is how a capability flag stops being worth having.

        `a@[i]`, `s$[n]` and `s$[[n]]` still answer. They reach a call, but not
        one the user wrote: the compiler lowers bracket syntax to arr_get /
        strline$ / strchar$ (PhosphorCompiler.pas:1035, :1046, :1056). The key is
        about what a person may TYPE. }
      caps.Add('evaluateCalls', False);
      caps.Add('setVariable', False);
      { TRUE SINCE 2026-09-17. A breakpoint carries an optional `condition` and it
        is evaluated HERE, at the boundary, by the same evaluator `evaluate` uses
        -- so a condition and a watch cannot come to disagree about what an
        expression means. A condition this host cannot read is refused in the
        `setBreakpoints` reply, where the editor can put the message beside the
        line it was typed on; one it cannot EVALUATE stops the program and says
        why, because a breakpoint that silently never fires is worse than one that
        stops for a reason you can read. }
      caps.Add('conditionalBreakpoints', True);
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
      { Whole-set replacement, which makes the editor's view authoritative by
        construction.

        `path` IS NOT READ, AND THIS COMMENT USED TO SAY IT WAS -- "a path this
        host does not know matches nothing and is not an error", which is a
        promise the handler below does not keep. It reads `lines` and
        `conditions` and nothing else, so a frame naming ANOTHER file replaces
        THIS file's whole set. An editor with several files open, arming them all
        at launch, installs the last one's marks against this one: measured, a
        stop on a line this file was never marked at and no stop on the line it
        was. Harmless while only one file could be in flight, and fbf74d4 --
        which taught the entry boundary to drain that queue -- is what newly
        exposes it at exactly the moment an editor arms.

        NOT REPAIRED HERE, DELIBERATELY. The obvious comparison is against FPath,
        and a strict one fails WORSE than the bug: an editor that spells the same
        file differently -- forward slashes, a relative path, a different case on
        a case-insensitive filesystem, a symlink -- would have every one of its
        breakpoints silently ignored, which is a dead debugger rather than a
        confused one. It wants a measurement of what real editors actually send,
        against a comparison built for that, and it is filed in
        docs/attack-plan.md rather than guessed at from here. }
      { EVERY ELEMENT IS CHECKED, not just the array. `lines` is optional, so a
        frame may leave it out entirely -- and when it IS there, fpjson's
        Integers[] CONVERTS: a string element raises EConvertError, a JSON null
        raises, and a nested array raises, each of them from inside this loop and
        each of them killing the debuggee over one malformed element in an
        otherwise conformant frame. An editor is a program and programs have bugs;
        the host must not die of someone else's.
        A non-integer element is DROPPED rather than refused, because the reply
        already says which lines were installed -- the editor learns that its
        element did not take by not seeing it come back, which is the same
        mechanism that reports a line no statement starts on. }
      { A CONDITION RIDES IN A SIBLING KEY, never inside `lines`.

        `conditions` is an array of strings the same length as `lines`, read BY
        THE SAME INDEX as the element it belongs to -- which is why it is read
        before anything is dropped. `lines` skips a non-integer element rather
        than refusing the frame, so its output index and its input index part
        company on the first bad element, and a condition taken from the OUTPUT
        index would then belong to the wrong breakpoint. Silently. This is the
        one place the two arrays can come apart and it is the one place that
        writes either.

        WHY NOT OBJECTS IN `lines`, which is the shape an editor reaches for
        first: because it would have killed this host as it first shipped.
        Before 2026-09-16 this loop read the array with Integers[i], which
        CONVERTS -- an object element raised inside the loop and took the
        debuggee down over one element of an otherwise conformant frame. The
        hardening that drops a non-integer instead is one commit old, and an
        editor cannot know which host it is talking to. A key an unaware host
        never looks for cannot hurt it. }
      SetLength(FBreaks, 0);
      SetLength(FBreakConds, 0);
      rejected := TJSONArray.Create();
      arr := o.Find('lines');
      conds := o.Find('conditions');
      if not ((conds <> nil) and (conds is TJSONArray)) then conds := nil;
      if (arr <> nil) and (arr is TJSONArray) then
      begin
        n := 0;
        SetLength(FBreaks, TJSONArray(arr).Count);
        SetLength(FBreakConds, TJSONArray(arr).Count);
        for i := 0 to TJSONArray(arr).Count - 1 do
        begin
          el := TJSONArray(arr).Items[i];
          if (el = nil) or (el.JSONType <> jtNumber) then Continue;
          v := el.AsInt64;
          if (v < 1) or (v > High(Integer)) then Continue;   // a line number, not an index
          cond := '';
          if (conds <> nil) and (i < TJSONArray(conds).Count) then
          begin
            el := TJSONArray(conds).Items[i];
            if (el <> nil) and (el.JSONType = jtString) then cond := Trim(el.AsString);
          end;
          { REFUSED NOW, WHERE IT WAS TYPED, or not at all. A condition is typed
            long before the program runs, and whether it is an EXPRESSION is
            decidable then: it is a compile and a walk over what the compile
            emitted. Whether its names are in scope is not, because scope is a
            frame -- that refusal can only arrive at the first stop on the line.
            A condition refused here is dropped and the breakpoint is installed
            UNCONDITIONAL, because the alternative is a mark the user can see and
            the program never honours. }
          if cond <> '' then
            if not EvaluateExpr(0, 0, cond, True, evVal, evKind, evErr) then
            begin
              rej := TJSONObject.Create();
              rej.Add('line', Integer(v));
              rej.Add('condition', cond);
              rej.Add('error', evErr);
              rejected.Add(rej);
              cond := '';
            end;
          FBreaks[n] := Integer(v);
          FBreakConds[n] := cond;
          Inc(n);
        end;
        SetLength(FBreaks, n);
        SetLength(FBreakConds, n);
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
      res.Add('lines', InstalledLines());
      { `rejected` IS OMITTED WHEN IT IS EMPTY, which is the ordinary case. An
        editor that has never heard of it sees the reply it always saw; one that
        has, sees nothing to draw unless there is something to draw. }
      if rejected.Count > 0 then res.Add('rejected', rejected)
      else rejected.Free;
      SendJSON(res);
      Exit(False);
    end;

    if cmd = 'launch' then
    begin
      { What the editor asked for, kept apart from what we arm with: arming
        always requests stop-at-entry so there is a safe moment to take the
        running VM (see FRunVM), and OnStop resumes silently from it when the
        editor did not want it. }
      FEditorEntry := o.Get('stopAtEntry', False);
      FStopAtEntry := True;
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
      { THIS is what tells OnStop's drain that the boundary it is standing on is a
        stop the editor asked for, rather than one taken only to read the socket. }
      FPauseWanted := True;
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
      if not stopped then SendError(seq, 'evaluate is valid only while stopped')
      else DoEvaluate(seq, o.Get('frame', 0), ADepth, o.Get('expr', ''));
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
  raw, why, condWhy: String;
  ev: TJSONObject;
  pending: Boolean;
  entryQuiet, stopHere: Boolean;
begin
  { FALSE AT EVERY BOUNDARY BUT THE FIRST, and said out loud because a local is
    not initialised here: only the FRunVM block below ever sets it True. }
  entryQuiet := False;
  { THE FIRST STOP IS WHERE THE SOCKET THREAD IS HANDED THE VM, and it is why
    arming always asks for stop-at-entry even when the editor did not. The engine
    offers no thread-safe way to find the running VM from outside (see FRunVM);
    the one safe moment is a stop, because the VM thread is parked in this seam
    and cannot be freeing anything. So: always stop at entry, take the pointer,
    and if the editor did not ask to stop here, resume without saying a word. }
  if FRunVM = nil then
  begin
    FLock.Acquire();
    try
      FRunVM := FEng.DebugVM;
    finally
      FLock.Release();
    end;
    { AN ENTRY BOUNDARY THE EDITOR DID NOT ASK FOR is this host's own invention:
      arming always requests stop-at-entry because a stop is the only thread-safe
      moment to take FRunVM. It is not a stop the editor is owed, so it is
      resolved below along with every other boundary, rather than resumed from
      here with its own private set of questions. }
    entryQuiet := (AReason = srEntry) and (not FEditorEntry);
    if entryQuiet then
    begin
      { FState MUST become dbgRunning here. It used to be set only on the way out
        of a real stop, so a silent entry resume left the session reading as
        `initialized` -- and the next `pause` was answered "pause is not valid
        while stopped" by a program that was plainly running. The state has to
        follow the program, not the last event the editor was sent. }
      FState := dbgRunning;
    end;
  end;

  { ONE DRAIN, AT EVERY BOUNDARY THE PROGRAM IS RUNNING AT, WHATEVER THE REASON.

    This was three drains with three different sets of post-drain questions --
    the entry one asked about FPendingArm and ArmedAt, the pause one asked about
    FPauseWanted, and the false-condition resume did not drain at all -- and
    every question one of them forgot to ask was a defect. All three were found
    on the same day, 2026-09-18, by three reviewers who were each looking at
    something else:

      * A frame arriving while the program stood on a line armed with a FALSE
        condition was consumed by the engine, never drained, never re-nudged, and
        sat unread in FInbox for the rest of the run. The editor's Pause button
        did nothing at all, and every frame queued behind it died with it.
        Measured: no ack, no `stopped`, program ran to completion, three runs of
        three, against a pre-95fb4fb build that answered in 0.00 s.
      * A `pause` arriving in the ENTRY queue was answered `ok:true` and then
        destroyed by the very interrupt it set, because the entry drain never
        looked at FPauseWanted and the next boundary's drain cleared it before
        asking. Measured: 42.66 s to exit, no `stopped`.
      * A `disconnect` with `terminate:true` in either queue was answered
        `ok:true` and its daStop thrown away -- `Exit(daRun)` on one path, and
        `FAction := daRun` below on the other. An editor that asked for the
        program to be killed was left holding a live process.

    THE DRAIN IS NO LONGER KEYED ON THE REASON, and that is the repair rather
    than three more branches. It was keyed on `AReason = srPause`, which was
    sound only while a consumed interrupt always produced srPause. That stopped
    being true when DebugPoll began reporting the most specific fact about a
    boundary instead of the first one in source order: an interrupt landing on an
    armed line is now a breakpoint, and the host was still asking about a pause.

    The set of boundaries the engine calls this seam at is exactly the set at
    which the interrupt flag can have been consumed. Draining at all of them is
    what makes "a frame is read at the next boundary" true without the host
    having to know why the boundary happened -- which is the fact it turned out
    not to be able to see. }
  if FState = dbgRunning then
  begin
    while TakeLine(raw) do
      if Handle(raw, ALine, ADepth) then Break;
    if FPendingArm then
    begin
      { Armed HERE rather than left for the next boundary: this is a safe point
        and the next boundary may be the one the editor asked about. }
      FPendingArm := False;
      Arm();
    end;
    { A FRAME THAT ENDED THE SESSION IS OBEYED, and obeyed HERE rather than at the
      bottom, where `FAction := daRun` would overwrite it. `disconnect` with
      `terminate:true` sets FAction := daStop and FClosed together; a plain
      disconnect sets daRun, which is the "close the socket and let it run" the
      protocol document describes. Both are the host's own answer, and neither is
      a stop the editor is told about. }
    if FClosed then Exit(FAction);
  end;

  { WHETHER THIS BOUNDARY STOPS, AND UNDER WHICH REASON -- asked after the drain,
    because a setBreakpoints in that queue may have armed this very line, which is
    the whole point of an editor sending one with `launch`.

    THE ORDER IS THE ENGINE'S ORDER, and for the engine's reason: a fact about
    WHERE THE PROGRAM IS beats the fact that the editor's queue had something in
    it. A `pause` that collides with a real breakpoint is reported as the
    breakpoint -- it was honoured, under a truer reason, and Handle answered its
    seq `ok:true` while the program was still running, so the editor no longer
    sees the "pause is not valid while stopped" refusal that collision produced
    for one day. }
  condWhy := '';
  if entryQuiet and (AReason = srEntry) and ArmedAt(ALine) then
  begin
    { THE USER ASKED TO STOP ON THIS VERY STATEMENT, which for a year was
      silently impossible: the engine tests entry before breakpoints, so at the
      FIRST boundary the reason is always srEntry and the armed set was never
      consulted there. It is the first EXECUTED STATEMENT and not line 1 -- a
      file opening with a `rem` loses line 2 instead, which is how it stayed
      invisible, because every fixture anyone wrote had a comment at the top.

      Reported as a breakpoint because that is what it is: the editor asked to
      stop here and did not ask to stop at entry. }
    AReason := srBreakpoint;
  end;

  if AReason = srEntry then
    { The editor asked for this one -- or, when entryQuiet, nobody did. }
    stopHere := not entryQuiet
  else if AReason = srBreakpoint then
    { A CONDITION DECIDES WHETHER A BREAKPOINT IS A STOP, and it is asked HERE,
      before the editor is told anything. The program has already halted at the
      boundary; what a false condition saves is the round trip, the event and the
      person's attention, not the halt itself.

      ONLY FOR srBreakpoint. A step that happens to land on a conditional
      breakpoint stops, because the user asked to step and the condition is not
      about them. So does an entry, a pause and an exception. }
    stopHere := ShouldStopAt(ALine, ADepth, condWhy)
  else if AReason = srStep then
    stopHere := True
  else
    { srPause ON ITS OWN IS A BOUNDARY TAKEN TO READ THE SOCKET, not the editor
      asking to stop. It stops only if something in the queue asked it to, which
      is the question below. }
    stopHere := False;

  if (not stopHere) and FPauseWanted then
  begin
    AReason := srPause;
    condWhy := '';
    stopHere := True;
  end;
  { CONSUMED WHATEVER HAPPENED: either it became this stop's reason, or a more
    specific reason took the stop it asked for. Left set, it would stop the
    program a second time at the next boundary for a request already answered. }
  FPauseWanted := False;

  if not stopHere then
  begin
    { THE PROGRAM CARRIES ON WITH NO `stopped` EVENT -- and carries on in the
      debug mode it was already in. daKeep, not daRun: none of the resumes that
      reach here is the user saying "continue". They are the host reading its
      socket or declining a hit, and daRun would cancel a step the user asked
      for. See TPhosphorDebugAction. }
    FState := dbgRunning;
    { The interrupt flag is consumed once per boundary by an InterlockedExchange,
      so a frame that landed while the drain ran would be seen but not woken for.
      Nudge again: the cost is one more boundary, and the alternative is a frame
      sitting unread until the next breakpoint, or for ever.
      Under the lock, because the reader thread writes FInbox. }
    FLock.Enter();
    try
      pending := FInbox.Count > 0;
    finally
      FLock.Leave();
    end;
    if pending then InterruptRun();
    Exit(daKeep);
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
  { A STOP THAT HAPPENED IN SPITE OF ITS CONDITION SAYS SO. `text` is the key an
    exception stop already uses for the same job -- here is why this one is in
    front of you -- and an editor that ignores it sees the stop it would have
    seen anyway. }
  if condWhy <> '' then ev.Add('text', condWhy);
  SendEvent('stopped', ev);

  FAction := daRun;
  FLock.Enter();
  try
    FVMParked := True;
  finally
    FLock.Leave();
  end;
  try
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
  finally
    FLock.Enter();
    try
      FVMParked := False;
    finally
      FLock.Leave();
    end;
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

    proto := TDebugProto.Create(eng, APath, source);
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
    { THE POINTER DIES HERE, BEFORE THE OBJECT DOES. Run has returned, so the VM
      the reader thread was allowed to nudge is about to be freed; nil it under
      the lock the reader reads it under, and the window in which a dead pointer
      is still reachable does not exist. The reader may still be parked in a read
      and may still deliver frames after this -- they queue harmlessly and wake
      nothing, which is correct: there is no longer a program to stop. }
    proto.ReleaseRunVM();
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
  i, shown, ln: Integer;
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
    { AND THE LINE IT IS PARKED ON, which this printed without for as long as it
      has existed -- `#0` had one and every caller was a bare name. The line of a
      frame that is mid-call is recorded on the frame it called INTO, so it is
      i + 1 and not i; DbgFrameCallerLine says the rest. A frame that still
      cannot be named keeps the bare form rather than printing `line 0`. }
    ln := AVM.DbgFrameCallerLine(i + 1);
    if ln > 0 then
      Writeln(StdErr, Format('#%d  %s   line %d',
                             [ADepth - 1 - i, FrameLabel(prog, AVM, i), ln]))
    else
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
      { FLUSHED BECAUSE THE PROCESS KEEPS RUNNING, which is the rule -- not
        because stderr is "usually unbuffered", which is a Windows accident.
        rtl/win/sysfile.inc:21-23 answers do_isdevice by comparing the handle to
        StdErrorHandle, an identity test redirection cannot see, so FlushFunc is
        installed on a console, a pipe and a file alike and every Writeln flushes.
        rtl/linux/sysos.inc:160 is a real tty test: down a pipe FlushFunc stays
        nil and the bytes wait for 256 of them (rtl/inc/textrec.inc) or for the
        process to end. This line is followed by the whole rest of the program,
        and FSilent means it is never said again -- so on Linux, read by an
        editor, it arrived only at exit, when SysFlushStdIO hands the buffer over
        (rtl/inc/system.inc) -- long after the line that caused it and long after
        it was any use. The prompt flush above is the same rule's other half:
        flush before a blocking read.

        GUARDED, AND THAT IS NOT DECORATION. Flush is [IOCheck] (rtl/inc/text.inc)
        and nothing in this file turns IO checking off, so a failed write RAISES.
        This is the first call at this site that can: before it, the bytes simply
        sat in the buffer and a dead stderr cost nothing. And the site is inside
        the engine's OnDebug seam, so an exception here unwinds through eng.Run
        and the net at the bottom of this file turns it into Halt(3) -- the code
        reserved for an interpreter bug -- with the BASIC program half-executed.
        The engine's own rule is that errors are values, not exceptions; the VM is
        not written to be unwound by a seam. Two lines above, the same author
        wrapped Eof(Input) in a try/except for exactly this reason.

        The shape is PhosphorCrtLib.SendToNul's. A diagnostic that cannot be
        delivered is not worth a fault. }
      {$push}{$I-}
      Flush(StdErr);
      {$pop}
      if IOResult <> 0 then ;    // nowhere left to say it
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
    { THE RULE, AT ITS FOURTH SITE: the next statement is the whole program. A
      person watching this banner arrive AFTER the program they were told they
      could type `h` at has already finished is watching the buffer, not the
      debugger. Guarded like the others -- see the notice in OnStop. }
    {$push}{$I-}
    Flush(StdErr);
    {$pop}
    if IOResult <> 0 then ;    // nowhere left to say it
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
        { THE DIAGNOSTIC THE SESSION CONTINUES AFTER -- which is what earns the
          flush, and not being the only one. The REPL has a second
          Writeln(StdErr,...) below; that one is followed by `Result := 2; Exit`,
          and the RTL flushes at exit, so it needs nothing.

          Same rule as the notice above: flush before the process keeps running.
          Invisible on Windows for the handle-identity reason, and on Linux an
          editor driving the REPL down a pipe saw the error at exit rather than
          after the line that caused it. Guarded for the reason written there. }
        {$push}{$I-}
        Flush(StdErr);
        {$pop}
        if IOResult <> 0 then ;    // nowhere left to say it
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
{ IS THIS STANDARD FILE A TERMINAL SOMEBODY IS LOOKING AT, as opposed to a pipe,
  a file or NUL? Asked of the handle inside the Text record, because that is the
  one that acts: --no-console re-points these files and GetStdHandle would then
  answer about something else. }
function TextIsTerminal(var AText: Text): Boolean;
{$IFDEF WINDOWS}
var
  h: THandle;
  mode: DWORD;
begin
  h := THandle(TextRec(AText).Handle);
  Result := (GetFileType(h) = FILE_TYPE_CHAR) and GetConsoleMode(h, mode);
end;
{$ELSE}
begin
  Result := IsATTY(TextRec(AText).Handle) = 1;
end;
{$ENDIF}

procedure GuiFlagNotice();
begin
  Writeln(StdErr, 'phosphor: --gui is no longer needed; this binary runs GUI ' +
                  'programs directly (the flag is accepted and ignored)');
  {$push}{$I-}
  Flush(StdErr);
  {$pop}
  if IOResult <> 0 then ;    // nowhere left to say it
end;

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
      Writeln('       phosphor debug --port <1..65535> <file.bas>   (for an editor)');
      Writeln('              the same session over a socket instead of the terminal:');
      Writeln('              THE EDITOR LISTENS AND THIS CONNECTS, one JSON object');
      Writeln('              per line, and the program keeps its own stdin, stdout');
      Writeln('              and stderr. docs/debugging.md and PhosphorIDE''s');
      Writeln('              docs/debug-protocol.md are the contract');
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
      { SAME RULE: this notice falls through the argument loop to the run at the
        bottom of this procedure, so the whole program stands between it and the
        exit that would otherwise deliver it. }
      GuiFlagNotice()
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
  { THIS HOST EMITS UTF-8, INCLUDING ITS DIAGNOSTICS, and until 2026-09-18 that
    was true of the program's output and false of everything this host said about
    it.

    The RTL stamps every output text file with the console's codepage at open
    time -- rtl/inc/text.inc:2644, `TextRec(f).CodePage :=
    GetStandardCodePageProc(scpConsoleOutput)`, which on Windows is
    GetConsoleOutputCP -- so every Writeln(StdErr, ...) is transcoded on the way
    out, whatever is in it. Not just a localised RTL message: argv, a path the
    script named, text sliced out of a source file.

    MEASURED, the same binary and the same argument, twice:

      chcp 65001   ... 63 61 66 c3 a9 2e 62 61 73    (e-acute, UTF-8)
      chcp 850     ... 63 61 66 82 2e 62 61 73       (e-acute, CP850)

    0x82 alone is not valid UTF-8, so an editor reading this stream and expecting
    UTF-8 -- which PhosphorIDE does, in writing -- renders whatever its widgetset
    makes of an invalid sequence, and a `file not found:` line no longer equals
    the path it sent. The bytes depend on the console the user happened to launch
    from, which is not a property this host should have.

    THE WRITE THIS HOST MAKES FOR THE PROGRAM IS UNAFFECTED: the program's own
    output leaves through FileWrite(StdOutputHandle, ...) at :404 as raw bytes and
    has never passed through a Text file. That is what every byte-exact golden in
    this tree compares, and it is why the five suites cannot tell the stderr half
    of this from a no-op -- see the case in tests/ that hexdumps stderr.

    IT IS NOT THE WHOLE JOURNEY, and saying it was is how the READ below went
    unfixed for a day. }

  { ...BUT ONLY WHERE UTF-8 IS WHAT THE READER WANTS, and that is a question
    about the HANDLE, not about the platform.

    Pinned unconditionally, this fixed the consumer and broke the person. A
    program reading this stream -- PhosphorIDE, a CI log, a shell pipeline --
    wants UTF-8 and says so in writing. A console wants the bytes it can render:
    on a Windows console left at its default codepage, 850 on the machine this
    was written on, raw UTF-8 is mojibake, which is exactly what this file's own
    header says at the top and what one unconditional call made true of every
    diagnostic in the host. Caught in review the same day it was written, before
    it reached anyone.

    ASKED OF THE HANDLE THE Text IS ACTUALLY BOUND TO, through TextRec, and not
    of GetStdHandle(STD_ERROR_HANDLE). Those are the same handle almost always
    and NOT after --no-console re-points a standard file at NUL; this project has
    lost three defects to judging one copy of a value while a different copy
    acted, and the one that acts is the one in the Text record.

    INPUT IS PINNED ON THE SAME RULE, and until 2026-09-18 it was not pinned at
    all -- so the PROGRAM'S OWN OUTPUT depended on the console its author
    happened to launch from. Same bytes in, same binary, stdout to a file:

      chcp 65001 -> 63 61 66 c3 a9               cafe-acute, correct
      chcp 850   -> 63 61 66 e2 94 9c c2 ae      U+251C U+00AE
      chcp 437   -> 63 61 66 e2 94 9c e2 8c 90   U+251C U+2310

    Three codepages, three different programs. The comment that used to sit here
    said the program's own output was unaffected; that was true of the WRITE,
    which leaves through FileWrite as raw bytes, and false end to end, because
    the bytes had already been mangled on the way IN. No test could see it: no
    file under tests/ or examples/ carries a byte >= 0x80. }
  if not TextIsTerminal(Output) then SetTextCodePage(Output, CP_UTF8);
  if not TextIsTerminal(StdErr) then SetTextCodePage(StdErr, CP_UTF8);
  if not TextIsTerminal(Input) then SetTextCodePage(Input, CP_UTF8);

  // Then, before anything can raise: take the LCL's modal crash dialog out of
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
