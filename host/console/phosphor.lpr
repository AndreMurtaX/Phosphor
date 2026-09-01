{******************************************************************************
  Phosphor BASIC -- console host (the library's first consumer)

  MIT License. Copyright (c) 2026 Andre Murta.

  The engine is host-agnostic; this program is one host. It wires the engine's
  OnOutput callback to a byte stream and offers two ways in: run a .bas file, or
  a line-at-a-time REPL. It is deliberately small -- the point of a host is that
  it is small.

  Usage:
    phosphor <file.bas>              run a file, output to stdout
    phosphor run <file.bas>          same, explicit verb
    phosphor run <file.bas> --out F  run a file, output bytes to F (used by tests)
    phosphor                         REPL
    phosphor --version | --help

  UTF-8: output goes to the OS stdout handle as raw bytes, so the golden test is
  byte-exact regardless of the console codepage. On Windows we still switch the
  console to UTF-8 (65001) so interactive glyphs render.
******************************************************************************}
program phosphor;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  SysUtils, Classes, PhosphorEngine;

type
  { The whole host side of the boundary: give the engine somewhere to put its
    output. The target is either the real stdout or a file (--out). }
  TConsoleHost = class
  private
    FTarget: TStream;
    FOwnsTarget: Boolean;
  public
    constructor Create(const AOutPath: String);
    destructor Destroy; override;
    procedure Output(const AText: String); // matches TPhosphorOutputProc
  end;

constructor TConsoleHost.Create(const AOutPath: String);
begin
  inherited Create;
  if AOutPath <> '' then
  begin
    FTarget := TFileStream.Create(AOutPath, fmCreate);
    FOwnsTarget := True;
  end
  else
  begin
    { Write raw bytes straight to the stdout handle (fd 1 on Unix, the console
      handle on Windows). We do not own it, so we must not free it. }
    FTarget := THandleStream.Create(StdOutputHandle);
    FOwnsTarget := False;
  end;
end;

destructor TConsoleHost.Destroy;
begin
  if FOwnsTarget then
    FTarget.Free;
  inherited Destroy;
end;

procedure TConsoleHost.Output(const AText: String);
begin
  if Length(AText) > 0 then
    FTarget.WriteBuffer(AText[1], Length(AText));
end;

procedure SetupConsoleUTF8;
begin
  {$IFDEF WINDOWS}
  SetConsoleOutputCP(CP_UTF8);
  SetConsoleCP(CP_UTF8);
  {$ENDIF}
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
    Writeln('Phosphor BASIC ', PhosphorVersion, ' -- skeleton REPL (PRINT/PRINTLN only). Ctrl+Z / Ctrl+D to quit.');
    while True do
    begin
      Write('phosphor> ');
      if EOF(Input) then
      begin
        Writeln;
        Break;
      end;
      ReadLn(line);
      if eng.Run(line) <> 0 then
        Writeln(StdErr, 'error: ', eng.ErrorMessage);
    end;
    Result := 0;
  finally
    eng.Free;
    host.Free;
  end;
end;

var
  i: Integer;
  arg, filePath, outPath: String;
begin
  SetupConsoleUTF8;

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
      Writeln('       phosphor --version');
      Halt(0);
    end
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
