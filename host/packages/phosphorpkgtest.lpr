{******************************************************************************
  phosphorpkgtest -- the headless runner for the opt-in host packages

  MIT License. Copyright (c) 2026 Andre Murta.

  Like phosphortest, but it also registers the OPT-IN packages under host/packages/
  (base64, zip, ...) -- the ones a real host would choose to include -- and runs a
  .bas file that exercises them, reporting the assertion tally byte-exact. The
  engine itself is unchanged and unaware; these packages plug in through the same
  registry, from outside the engine.
******************************************************************************}
program phosphorpkgtest;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  SysUtils, Classes,
  PhosphorEngine, PhosphorTestLib,
  PhosphorBase64Lib, PhosphorZipLib, PhosphorGzipLib, PhosphorSqliteLib, PhosphorCrtLib;

function ReadSource(const APath: String): String;
var fs: TFileStream; len: Int64;
begin
  Result := '';
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    len := fs.Size;
    SetLength(Result, len);
    if len > 0 then fs.ReadBuffer(Result[1], len);
  finally
    fs.Free;
  end;
  if (Length(Result) >= 3) and (Result[1] = #$EF) and
     (Result[2] = #$BB) and (Result[3] = #$BF) then
    Delete(Result, 1, 3);
end;

procedure WriteSummary;
var s: String;
begin
  s := 'passed: ' + IntToStr(AssertsPassed) + #10 +
       'failed: ' + IntToStr(AssertsFailed) + #10;
  FileWrite(StdOutputHandle, s[1], Length(s));
end;

var
  eng: TPhosphorEngine;
  path: String;
  rc, i: Integer;
begin
  if ParamCount < 1 then
  begin
    Writeln(StdErr, 'usage: phosphorpkgtest <file.bas>');
    Halt(2);
  end;
  path := ParamStr(1);
  if not FileExists(path) then
  begin
    Writeln(StdErr, 'phosphorpkgtest: file not found: ', path);
    Halt(2);
  end;

  eng := TPhosphorEngine.Create();
  try
    RegisterTestFuncs(eng.Registry);
    RegisterBase64Funcs(eng.Registry);
    RegisterZipFuncs(eng.Registry);
    RegisterGzipFuncs(eng.Registry);
    RegisterSqliteFuncs(eng.Registry);
    RegisterCrtFuncs(eng.Registry);
    ResetTestState();
    rc := eng.Run(ReadSource(path));
    if rc <> 0 then
    begin
      Writeln(StdErr, Format('phosphorpkgtest: %s:%d: %s', [path, eng.ErrorLine, eng.ErrorMessage]));
      WriteSummary();
      Halt(2);
    end;
    for i := 0 to Failures.Count - 1 do
      Writeln(StdErr, '  FAIL ', Failures[i]);
    WriteSummary();
    if AssertsFailed = 0 then Halt(0) else Halt(1);
  finally
    eng.Free;
  end;
end.
