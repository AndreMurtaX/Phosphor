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
    phosphor compile <in.bas> <out.pbc>   compile to portable bytecode
    phosphor pack <in.bas> <out>     make a standalone executable (stub + payload)
    phosphor --gui <file.bas>        run a GUI program (hands over to phosphorgui)
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
  SysUtils, Classes, PhosphorEngine, PhosphorCompiler, PhosphorOpcodes, PhosphorBytecode,
  PhosphorRegistry,
  // This host opts into EVERY shipped function package, so a program run, compiled
  // or packed by `phosphor` can reach the whole library surface (~700 built-ins).
  // The external-dependency packages (sqlite, http) load their libraries lazily,
  // so the binary builds and runs everywhere; only an actually-called function
  // whose library is absent reports an error, and the rest keep working.
  PhosphorCrtLib, PhosphorBase64Lib, PhosphorZipLib, PhosphorGzipLib,
  PhosphorHttpLib, PhosphorSqliteLib;

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

{ Register every shipped function package into a registry, so a program run,
  compiled or packed by this host can reach the whole library surface. }
procedure RegisterAllPackages(Reg: TPhosphorRegistry);
begin
  RegisterCrtFuncs(Reg);
  RegisterBase64Funcs(Reg);
  RegisterZipFuncs(Reg);
  RegisterGzipFuncs(Reg);
  RegisterHttpFuncs(Reg);
  RegisterSqliteFuncs(Reg);
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
function CompileFile(const AInPath, AOutPath: String): Integer;
var
  comp: TPhosphorCompiler;
  prog: TProgram;
  fs: TFileStream;
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
  try
    eng.OnOutput := @host.Output;
    eng.OnInput := @host.ReadLine;
    RegisterAllPackages(eng.Registry);
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
  PACK_MAGIC   = 'PHOSPBC1';       // 8 bytes at the very end of a packed file
  PACK_TRAILER = 8 + 8 + 4 + 8;    // offset(i64) + size(i64) + checksum(u32) + magic(8)

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
function PackFile(const AInBas, AOutExe: String): Integer;
var
  comp: TPhosphorCompiler;
  prog: TProgram;
  payload: TBytesStream;
  src, dst: TFileStream;
  off: Int64;
begin
  if not FileExists(AInBas) then begin Writeln(StdErr, 'phosphor: file not found: ', AInBas); Exit(2); end;
  comp := TPhosphorCompiler.Create();
  try
    if not comp.Compile(ReadSource(AInBas), prog) then
    begin
      Writeln(StdErr, Format('phosphor: %s:%d: %s', [AInBas, comp.ErrorLine, comp.ErrorMessage]));
      Exit(1);
    end;
  finally
    comp.Free;
  end;

  payload := TBytesStream.Create();
  try
    WriteProgram(payload, prog);
    prog.Free;
    src := TFileStream.Create(SelfExePath(), fmOpenRead or fmShareDenyNone);
    dst := TFileStream.Create(AOutExe, fmCreate);
    try
      dst.CopyFrom(src, 0);                 // the whole stub binary
      off := dst.Position;                  // the payload starts here
      if payload.Size > 0 then dst.WriteBuffer(payload.Memory^, payload.Size);
      WLE64(dst, off);
      WLE64(dst, payload.Size);
      WLE32(dst, PayloadChecksum(payload.Memory^, payload.Size));
      dst.WriteBuffer(PACK_MAGIC[1], 8);
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
function TryReadEmbeddedPayload(out APayload: TBytesStream): Boolean;
var
  fs: TFileStream;
  total, off, siz: Int64;
  ck: LongWord;
  magic: array[0..7] of Char;
begin
  Result := False;
  APayload := nil;
  try
    fs := TFileStream.Create(SelfExePath(), fmOpenRead or fmShareDenyNone);
  except
    Exit;   // cannot read our own file -> just be the CLI
  end;
  try
    total := fs.Size;
    if total < PACK_TRAILER then Exit;
    fs.Position := total - PACK_TRAILER;
    off := RLE64(fs); siz := RLE64(fs); ck := RLE32(fs); fs.ReadBuffer(magic[0], 8);
    if magic <> PACK_MAGIC then Exit;                          // a bare stub -> CLI
    if (off < 0) or (siz <= 0) or (off + siz > total - PACK_TRAILER) then Exit;
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
  try
    eng.OnOutput := @host.Output;
    eng.OnInput := @host.ReadLine;
    RegisterAllPackages(eng.Registry);
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
  Result := (AMsg = 'expected ''endif''') or
            (AMsg = 'expected ''endwhile'' or ''wend''') or
            (AMsg = 'expected ''endfunction''') or
            (AMsg = 'expected ''endselect''') or
            (AMsg = 'expected ''loop''') or
            (AMsg = 'expected ''until''');
end;

{ `phosphor --gui <file.bas>` hands over to phosphorgui, the COMPLETE runner (engine
  + every package + the LCL GUI libraries). It is a separate binary on purpose.

  Why a `--gui` flag cannot simply load the LCL in-process: on Linux the gtk2
  widgetset connects to the X display in the `Interfaces` unit's INITIALIZATION
  section -- before main runs. Measured on the project VM: an LCL-linked binary that
  never calls Application.Initialize still prints "cannot open display" and exits 1
  when no display is reachable, while the same binary runs fine (exit 0) with
  DISPLAY set to a live session. Linking is a compile-time decision, so no runtime
  flag can undo it.

  A display is often absent exactly where the console host is needed -- CI, a
  container, a headless server, and every plain `ssh` session (including the one this
  project's own Linux test runs arrive on, where DISPLAY is empty). Keeping the LCL
  out of THIS binary is what lets `phosphor run`, the REPL and the byte-exact tests
  work there. On Windows the win32 widgetset needs no display, so the split costs
  nothing; it is kept on both platforms so the two behave alike.

  Compiling needs neither host: the compiler is host-agnostic, so
  `phosphor compile <gui-app.bas> <out.pbc>` already works for GUI programs. }
function RunGui(const APath: String): Integer;
var gui: String;
begin
  {$IFDEF UNIX}
  // Check for a session BEFORE spawning the GUI binary: on Linux gtk2 opens the
  // display in a unit initialization, so launching it without one produces a bare
  // "cannot open display" that names neither Phosphor nor the remedy. (phosphorgui
  // carries the same guard for when it is invoked directly; this one saves the
  // process launch and keeps the message identical.) Windows needs no display.
  if (GetEnvironmentVariable('DISPLAY') = '') and
     (GetEnvironmentVariable('WAYLAND_DISPLAY') = '') then
  begin
    Writeln(StdErr, 'phosphor: --gui needs a graphical session, and neither DISPLAY');
    Writeln(StdErr, '  nor WAYLAND_DISPLAY is set here (a plain ssh session, a service');
    Writeln(StdErr, '  or a container usually has none).');
    Writeln(StdErr, '');
    Writeln(StdErr, '  Run it from a desktop session, or point it at one:');
    Writeln(StdErr, '      DISPLAY=:0 phosphor --gui ' + APath);
    Writeln(StdErr, '  A console program needs no display:');
    Writeln(StdErr, '      phosphor run ' + APath);
    Exit(3);
  end;
  {$ENDIF}
  gui := ExtractFilePath(SelfExePath()) + 'phosphorgui' +
         {$IFDEF WINDOWS}'.exe'{$ELSE}''{$ENDIF};
  if not FileExists(gui) then
  begin
    Writeln(StdErr, 'phosphor: --gui needs phosphorgui beside this binary:');
    Writeln(StdErr, '  ', gui);
    Writeln(StdErr, '  build it with scripts/build-gui.ps1 (Windows) or scripts/build-gui.sh (Linux)');
    Exit(2);
  end;
  Result := ExecuteProcess(gui, [APath]);
end;

function Repl: Integer;
var
  host: TConsoleHost;
  eng: TPhosphorEngine;
  line, pending: String;
begin
  host := TConsoleHost.Create('');
  eng := TPhosphorEngine.Create();
  try
    eng.OnOutput := @host.Output;
    eng.OnInput := @host.ReadLine;
    RegisterAllPackages(eng.Registry);
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
  arg, filePath, outPath: String;
  guiMode: Boolean;
  payload: TBytesStream;
begin
  // A packed application: run the embedded .pbc and stop, ignoring CLI arguments.
  if TryReadEmbeddedPayload(payload) then
  begin
    code := RunEmbedded(payload);
    payload.Free;
    Halt(code);
  end;

  // `phosphor compile <in.bas> <out.pbc>` -- compile to bytecode and stop.
  if (ParamCount >= 1) and (ParamStr(1) = 'compile') then
  begin
    if ParamCount < 3 then
    begin
      Writeln(StdErr, 'usage: phosphor compile <in.bas> <out.pbc>');
      Halt(2);
    end;
    Halt(CompileFile(ParamStr(2), ParamStr(3)));
  end;

  // `phosphor pack <in.bas> <out.exe>` -- make a standalone executable and stop.
  if (ParamCount >= 1) and (ParamStr(1) = 'pack') then
  begin
    if ParamCount < 3 then
    begin
      Writeln(StdErr, 'usage: phosphor pack <in.bas> <out' + {$IFDEF WINDOWS}'.exe>'{$ELSE}'>'{$ENDIF});
      Halt(2);
    end;
    Halt(PackFile(ParamStr(2), ParamStr(3)));
  end;

  filePath := '';
  outPath := '';
  guiMode := False;
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
      Writeln('       phosphor compile <in.bas> <out.pbc>');
      Writeln('       phosphor pack <in.bas> <out>   (standalone executable)');
      Writeln('       phosphor --gui <file.bas>     run a GUI program (via phosphorgui)');
      Writeln('       phosphor            (REPL)');
      Writeln('       phosphor --diag     (console/UTF-8 self-check)');
      Writeln('       phosphor --version');
      Halt(0);
    end
    else if arg = '--diag' then
      Halt(Diag())
    else if arg = '--gui' then
      guiMode := True
    else if arg = 'run' then
      { optional verb; ignore }
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

  if guiMode then
  begin
    if filePath = '' then
    begin
      Writeln(StdErr, 'phosphor: --gui needs a file to run');
      Halt(2);
    end;
    Halt(RunGui(filePath));
  end;

  if filePath <> '' then
    Halt(RunFile(filePath, outPath))
  else
    Halt(Repl());
end.
