{******************************************************************************
  Phosphor BASIC -- console host (the library's first consumer)

  MIT License. Copyright (c) 2026 Andre Murta.

  The engine is host-agnostic; this program is one host. It wires the engine's
  OnOutput callback to output, and offers two ways in: run a .bas file, or a
  line-at-a-time REPL.

  Usage:
    phosphor <file.bas>              run a file, output to stdout
    phosphor run <file.bas>          same, explicit verb
    phosphor run <file.bas> --out F  run a file, output bytes to F (used by tests)
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
  SysUtils, Classes, PhosphorEngine;

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
  inherited Create;
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
  inherited Destroy;
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

function RunFile(const APath, AOutPath: String): Integer;
var
  host: TConsoleHost;
  eng: TPhosphorEngine;
  line: Integer;
begin
  if not FileExists(APath) then
  begin
    Writeln(StdErr, 'phosphor: file not found: ', APath);
    Exit(2);
  end;
  host := TConsoleHost.Create(AOutPath);
  eng := TPhosphorEngine.Create;
  try
    eng.OnOutput := @host.Output;
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

function Repl: Integer;
var
  host: TConsoleHost;
  eng: TPhosphorEngine;
  line: String;
begin
  host := TConsoleHost.Create('');
  eng := TPhosphorEngine.Create;
  try
    eng.OnOutput := @host.Output;
    host.Output('Phosphor BASIC ' + PhosphorVersion +
                ' -- skeleton REPL (PRINT/PRINTLN only). Ctrl+Z then Enter to quit.'#10);
    while True do
    begin
      host.Output('phosphor> ');
      if not host.ReadLine(line) then
      begin
        host.Output(#10);
        Break;
      end;
      if eng.Run(line) <> 0 then
        Writeln(StdErr, 'error: ', eng.ErrorMessage);
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
    Writeln(StdErr, 'stdout is console: ', host.StdoutIsConsole);
    Writeln(StdErr, 'stdin  is console: ', host.StdinIsConsole);
    Flush(StdErr);
    host.Output('UTF-8 check: Olá — café — açúcar — ☕ — π ≈ 3.14159'#10);
    Result := 0;
  finally
    host.Free;
  end;
end;

var
  i: Integer;
  arg, filePath, outPath: String;
begin
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
      Writeln('usage: phosphor [run] <file.bas> [--out <path>]');
      Writeln('       phosphor            (REPL)');
      Writeln('       phosphor --diag     (console/UTF-8 self-check)');
      Writeln('       phosphor --version');
      Halt(0);
    end
    else if arg = '--diag' then
      Halt(Diag)
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

  if filePath <> '' then
    Halt(RunFile(filePath, outPath))
  else
    Halt(Repl);
end.
