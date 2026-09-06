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

type
  { The whole host side of the boundary: give the engine somewhere to put its
    output, and (for the REPL) a way to read a line. }
  TConsoleHost = class
  private
    FOutFile: TStream;       // non-nil only in --out file mode
    {$IFDEF WINDOWS}
    FStdOut, FStdIn: THandle;
    FOutIsConsole: Boolean;  // stdout is an interactive console (not redirected)
    FInIsConsole: Boolean;   // stdin  is an interactive console
    {$ENDIF}
  public
    constructor Create(const AOutPath: String);
    destructor Destroy; override;
    procedure Output(const AText: String); // matches TPhosphorOutputProc
    function ReadLine(out ALine: String): Boolean; // False at end of input
    function StdoutIsConsole: Boolean;
    function StdinIsConsole: Boolean;
  end;

constructor TConsoleHost.Create(const AOutPath: String);
{$IFDEF WINDOWS}
var
  mode: DWORD;
{$ENDIF}
begin
  inherited Create();
  FOutFile := nil;
  if AOutPath <> '' then
    FOutFile := TFileStream.Create(AOutPath, fmCreate);
  {$IFDEF WINDOWS}
  mode := 0;
  FStdOut := StdOutputHandle;
  FStdIn := StdInputHandle;
  { GetConsoleMode succeeds only on a real console handle; a file/pipe fails it. }
  FOutIsConsole := (FOutFile = nil) and GetConsoleMode(FStdOut, mode);
  FInIsConsole := GetConsoleMode(FStdIn, mode);
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

{ Compile a .bas source to a .pbc bytecode file. }
function CompileFile(const AInPath, AOutPath: String; ACheck: Boolean): Integer;
var
  comp: TPhosphorCompiler;
  prog: TProgram;
  fs: TFileStream;
  missing: Integer;
  report: String;
begin
  if not FileExists(AInPath) then
  begin
    Writeln(StdErr, 'phosphor: file not found: ', AInPath);
    Exit(2);
  end;
  comp := TPhosphorCompiler.Create();
  try
    if not comp.Compile(ReadSource(AInPath), prog) then
    begin
      Writeln(StdErr, Format('phosphor: %s:%d: %s', [AInPath, comp.ErrorLine, comp.ErrorMessage]));
      Exit(1);
    end;
  finally
    comp.Free;
  end;
  try
    fs := TFileStream.Create(AOutPath, fmCreate);
    try WriteProgram(fs, prog); finally fs.Free; end;
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

{ A file is bytecode if it starts with the .pbc magic. }
function IsBytecode(const APath: String): Boolean;
var fs: TFileStream; buf: array[0..2] of Char;
begin
  Result := False;
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    if fs.Size >= 3 then
    begin
      fs.ReadBuffer(buf[0], 3);
      Result := (buf[0] = 'P') and (buf[1] = 'B') and (buf[2] = 'C');
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
begin
  if not FileExists(APath) then
  begin
    Writeln(StdErr, 'phosphor: file not found: ', APath);
    Exit(2);
  end;
  host := TConsoleHost.Create(AOutPath);
  eng := TPhosphorEngine.Create();
  eng.SandboxRoot := GSandboxDir;   // '' = unbounded, as before
  try
    eng.OnOutput := @host.Output;
    eng.OnInput := @host.ReadLine;
    RegisterAllPackages(eng);
    if IsBytecode(APath) then
    begin
      // a precompiled .pbc: run it without the lexer/compiler
      fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
      try line := eng.RunBytecode(fs); finally fs.Free; end;
    end
    else
      line := eng.Run(ReadSource(APath));
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

// --- self-extracting deployment (phosphor pack) ------------------------------
// A packed application is this stub binary with a .pbc payload appended, behind a
// fixed trailer at the very end (PE and ELF both ignore trailing bytes). The stub
// reads its own tail at startup; if the trailer's magic is there, it runs the
// embedded payload. Same phosphor binary: bare it is the CLI, packed it is an app.

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
  payload: TBytesStream;
  src, dst: TFileStream;
  off: Int64;
  pbcErr, missingReport: String;
  missing: Integer;
begin
  if not FileExists(AInPbc) then begin Writeln(StdErr, 'phosphor: file not found: ', AInPbc); Exit(2); end;

  // PACK TAKES BYTECODE, NOT SOURCE. One verb, one job: `compile` turns source
  // into a .pbc and `pack` turns a .pbc into an executable. Compiling inside pack
  // made a command whose work is copying bytes able to fail with a syntax error,
  // and hid a step that is worth doing once and packing many times.
  if not IsBytecode(AInPbc) then
  begin
    Writeln(StdErr, 'phosphor: pack takes compiled bytecode, and this is not a .pbc: ', AInPbc);
    Writeln(StdErr, '  compile it first, then pack what comes out:');
    Writeln(StdErr, '      phosphor compile ', AInPbc, ' app.pbc');
    Writeln(StdErr, '      phosphor pack app.pbc ', AOutExe);
    Exit(2);
  end;

  payload := TBytesStream.Create();
  try
    src := TFileStream.Create(AInPbc, fmOpenRead or fmShareDenyNone);
    try payload.CopyFrom(src, 0); finally src.Free; end;
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
    src := TFileStream.Create(SelfExePath(), fmOpenRead or fmShareDenyNone);
    dst := TFileStream.Create(AOutExe, fmCreate);
    try
      dst.CopyFrom(src, 0);                 // the whole stub binary
      off := dst.Position;                  // the payload starts here
      if payload.Size > 0 then dst.WriteBuffer(payload.Memory^, payload.Size);
      WLE64(dst, off);
      WLE64(dst, payload.Size);
      WLE32(dst, PayloadChecksum(payload.Memory^, payload.Size));
      WLE32(dst, AFlags);
      dst.WriteBuffer(PACK_MAGIC_V2[1], 8);
    finally
      src.Free; dst.Free;
    end;
  finally
    payload.Free;
  end;
  {$IFDEF UNIX} FpChmod(AOutExe, &755); {$ENDIF}   // make it runnable
  Result := 0;
end;

{ True if THIS binary carries an embedded .pbc payload (a valid trailer). }
function TryReadEmbeddedPayload(out APayload: TBytesStream; out AFlags: LongWord): Boolean;
var
  fs: TFileStream;
  total, off, siz: Int64;
  ck: LongWord;
  trailer: Int64;
  magic: array[0..7] of Char;
begin
  Result := False;
  APayload := nil;
  AFlags := 0;
  try
    fs := TFileStream.Create(SelfExePath(), fmOpenRead or fmShareDenyNone);
  except
    Exit;   // cannot read our own file -> just be the CLI
  end;
  try
    total := fs.Size;
    if total < PACK_TRAILER_V1 then Exit;
    // The magic is the last 8 bytes whichever version this is, so it is read
    // FIRST and decides how much trailer to read back.
    fs.Position := total - 8;
    fs.ReadBuffer(magic[0], 8);
    if magic = PACK_MAGIC_V2 then trailer := PACK_TRAILER_V2
    else if magic = PACK_MAGIC_V1 then trailer := PACK_TRAILER_V1
    else Exit;                                                 // a bare stub -> CLI
    if total < trailer then Exit;
    fs.Position := total - trailer;
    off := RLE64(fs); siz := RLE64(fs); ck := RLE32(fs);
    if trailer = PACK_TRAILER_V2 then AFlags := RLE32(fs);
    if (off < 0) or (siz <= 0) or (off + siz > total - trailer) then Exit;
    APayload := TBytesStream.Create();
    APayload.Size := siz;
    fs.Position := off;
    fs.ReadBuffer(APayload.Memory^, siz);
    if PayloadChecksum(APayload.Memory^, siz) <> ck then
    begin APayload.Free; APayload := nil; Exit; end;
    APayload.Position := 0;
    Result := True;
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
  eng.SandboxRoot := GSandboxDir;   // '' = unbounded, as before
  try
    eng.OnOutput := @host.Output;
    eng.OnInput := @host.ReadLine;
    RegisterAllPackages(eng);
    line := eng.RunBytecode(APayload);
    if line <> 0 then begin Writeln(StdErr, Format('phosphor: %d: %s', [line, eng.ErrorMessage])); Exit(1); end;
    Result := 0;
  finally
    eng.Free; host.Free;
  end;
end;

{ True when a compile error means "the block is not finished yet" rather than "this
  is wrong" -- the compiler's own terminator messages. The REPL then keeps reading
  instead of rejecting the line, so a multi-line IF, loop or FUNCTION can be typed. }
function IsUnterminatedBlock(const AMsg: String): Boolean;
begin
  { EVERY terminator the compiler can ask for, taken from the compiler rather than
    remembered. `next` was missing, so a FOR loop -- the one block a person is most
    likely to type at a prompt -- answered "expected 'next'" and threw the line
    away, while the banner two lines above promised it would wait. The two `case`
    messages belong here for the same reason: a bare `select case v` is a block
    that has not been finished yet, not a mistake. }
  Result := (AMsg = 'expected ''endif''') or
            (AMsg = 'expected ''endwhile'' or ''wend''') or
            (AMsg = 'expected ''endfunction''') or
            (AMsg = 'expected ''endselect''') or
            (AMsg = 'expected ''loop''') or
            (AMsg = 'expected ''until''') or
            (AMsg = 'expected ''next''') or
            (AMsg = 'expected ''case'' after ''select''') or
            (AMsg = 'expected ''case'' or ''endselect''');
end;

function Repl: Integer;
var
  host: TConsoleHost;
  eng: TPhosphorEngine;
  line, pending: String;
begin
  host := TConsoleHost.Create('');
  eng := TPhosphorEngine.Create();
  eng.SandboxRoot := GSandboxDir;   // '' = unbounded, as before
  try
    eng.OnOutput := @host.Output;
    eng.OnInput := @host.ReadLine;
    RegisterAllPackages(eng);
    host.Output('Phosphor BASIC ' + PhosphorVersion +
                ' -- REPL. Variables and functions persist across lines.'#10 +
                'Type a multi-line block and it waits for the terminator. ' +
                'Ctrl+Z then Enter to quit.'#10);
    pending := '';
    while True do
    begin
      if pending = '' then host.Output('phosphor> ') else host.Output('     ...> ');
      if not host.ReadLine(line) then
      begin
        host.Output(#10);
        Break;
      end;
      if pending <> '' then line := pending + #10 + line;
      if eng.ReplRun(line) <> 0 then
      begin
        if IsUnterminatedBlock(eng.ErrorMessage) then
        begin
          pending := line;              // not wrong, just unfinished -- read on
          Continue;
        end;
        Writeln(StdErr, 'error: ', eng.ErrorMessage);
      end;
      pending := '';
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
function Diag: Integer;
var
  host: TConsoleHost;
begin
  host := TConsoleHost.Create('');
  try
    Writeln(StdErr, 'stdout is console: ', host.StdoutIsConsole());
    Writeln(StdErr, 'stdin  is console: ', host.StdinIsConsole());
    Flush(StdErr);
    host.Output('UTF-8 check: Olá — café — açúcar — ☕ — π ≈ 3.14159'#10);
    Result := 0;
  finally
    host.Free;
  end;
end;

var
  i, code: Integer;
  arg, filePath, outPath, packIn, packOut: String;
  packFlags: LongWord;
  packArgs: Integer;
  payload: TBytesStream;
  embFlags: LongWord;
begin
  // A packed application: run the embedded .pbc and stop, ignoring CLI arguments.
  if TryReadEmbeddedPayload(payload, embFlags) then
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
end.
