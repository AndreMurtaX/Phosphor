{******************************************************************************
  phosphortest -- the headless suite runner (a second host for the engine)

  MIT License. Copyright (c) 2026 Andre Murta.

  Registers PhosphorTestLib into the engine, runs one .bas test file, and reports
  the assertion tally. The summary goes to stdout as raw LF-terminated bytes (so
  the golden compare is byte-exact and platform-independent); failure detail and
  engine errors go to stderr. Exit code: 0 all passed, 1 assertions failed,
  2 the file did not compile/run.

  Modelled on Plan9Basic's tests/Plan9BasicTest.dpr, but the engine here is the
  five-kind pipeline and the runner is deliberately minimal.
******************************************************************************}
program phosphortest;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  SysUtils, Classes,
  PhosphorEngine, PhosphorTestLib;

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
    if len > 0 then fs.ReadBuffer(Result[1], len);
  finally
    fs.Free;
  end;
  if (Length(Result) >= 3) and (Result[1] = #$EF) and
     (Result[2] = #$BB) and (Result[3] = #$BF) then
    Delete(Result, 1, 3);
end;

procedure WriteSummary;
var
  s: String;
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
    Writeln(StdErr, 'usage: phosphortest <file.bas>');
    Halt(2);
  end;
  path := ParamStr(1);
  if not FileExists(path) then
  begin
    Writeln(StdErr, 'phosphortest: file not found: ', path);
    Halt(2);
  end;

  eng := TPhosphorEngine.Create();
  // A TEST RUNNER IS ALWAYS SANDBOXED, with no flag to turn it off. The suite
  // exists to run code that is being changed, which is exactly the code most
  // likely to name a path it did not mean to; on 2026-09-05 an unbounded run of a
  // defective dir_delete erased thirteen projects outside this checkout. The
  // working directory is the root -- every test writes under bin/ , which is
  // inside it -- so nothing a test names can resolve outside the checkout.
  eng.SandboxRoot := GetCurrentDir;

  try
    RegisterTestFuncs(eng.Registry);
    ResetTestState();
    rc := eng.Run(ReadSource(path));
    if rc <> 0 then
    begin
      Writeln(StdErr, Format('phosphortest: %s:%d: %s', [path, eng.ErrorLine, eng.ErrorMessage]));
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
