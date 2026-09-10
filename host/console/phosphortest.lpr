{******************************************************************************
  phosphortest -- the headless suite runner (a second host for the engine)

  MIT License. Copyright (c) 2026 Andre Murta.

  Registers PhosphorTestLib into the engine, runs one .bas test file, and reports
  the assertion tally. The summary goes to stdout as raw LF-terminated bytes (so
  the golden compare is byte-exact and platform-independent); failure detail and
  engine errors go to stderr. Exit code: 0 all passed, 1 assertions failed,
  2 the file did not compile/run, 3 THIS BINARY IS OLDER THAN THE ENGINE and
  refuses to answer (see RefuseIfStale).

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

{ THE TRAP THIS CLOSES, which is the most expensive one in the project.

  scripts/build.ps1 builds phosphor.exe. It does NOT build this binary -- the TEST
  RUNNERS do. So "I built" is not true of the file you are about to run, and
  running it after an engine edit runs OLD CODE and answers confidently with it.
  CLAUDE.md has warned about this since it fired four times in one session and
  produced a wrong conclusion every time; on 2026-09-10 it fired again, on the
  author of that warning, and cost twenty minutes of investigating a "hang" that
  was a fix already working in a binary nobody had rebuilt.

  A rule written in prose that has already failed six times is not a rule. So the
  binary answers the question itself: if any source it is built from is newer than
  the binary, it REFUSES rather than reports. A silent wrong answer becomes a loud
  one, which is the whole trade.

  Three details worth keeping:

  - The comparison errs toward RUNNING. FileAge is a DOS timestamp with two-second
    granularity, and only strictly-newer counts, so a source saved in the same
    tick as the build reads as equal and is allowed. The trap is minutes wide;
    seconds do not matter, and a guard that refuses a fresh binary would be worse
    than the defect.
  - It says nothing when it cannot tell. A binary somewhere other than <root>/bin,
    or a checkout with no engine/ beside it, is not this repository and gets no
    opinion.
  - It is not in phosphor.exe. That one ships, and a shipped interpreter has no
    business reading a source tree that is not there. This runner never ships. }
function NewestIn(const ADir, AMask: String; var ANewest: LongInt; var AWho: String): Boolean;
var
  sr: TSearchRec;
  full: String;
  age: LongInt;
begin
  Result := False;
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + AMask, faAnyFile, sr) <> 0 then Exit;
  try
    repeat
      if (sr.Attr and faDirectory) = 0 then
      begin
        full := IncludeTrailingPathDelimiter(ADir) + sr.Name;
        age := FileAge(full);
        if age > ANewest then
        begin
          ANewest := age;
          AWho := full;
          Result := True;
        end;
      end;
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
end;

procedure RefuseIfStale;
var
  exe, root, who: String;
  exeAge, newest: LongInt;
begin
  exe := ParamStr(0);
  exeAge := FileAge(exe);
  if exeAge < 0 then Exit;                    // cannot tell: say nothing
  root := ExtractFilePath(ExcludeTrailingPathDelimiter(ExtractFilePath(exe)));
  if root = '' then Exit;
  if not DirectoryExists(root + 'engine') then Exit;   // not this repository
  newest := -1;
  who := '';
  NewestIn(root + 'engine', '*.pas', newest, who);
  NewestIn(root + 'engine' + PathDelim + 'libs', '*.pas', newest, who);
  NewestIn(root + 'tests', '*.pas', newest, who);
  NewestIn(root + 'host' + PathDelim + 'console', '*.lpr', newest, who);
  if newest <= exeAge then Exit;
  Writeln(StdErr, 'phosphortest: this runner is OLDER than the engine it was built from.');
  Writeln(StdErr, '  runner : ', exe, '  (', DateTimeToStr(FileDateToDateTime(exeAge)), ')');
  Writeln(StdErr, '  newer  : ', who, '  (', DateTimeToStr(FileDateToDateTime(newest)), ')');
  Writeln(StdErr, '  scripts/build.ps1 does not build this binary -- the test runners do.');
  Writeln(StdErr, '  Run the suite instead: scripts/test-suite.ps1  (or .sh on Linux).');
  Writeln(StdErr, '  Refusing to answer with code nobody rebuilt.');
  Halt(3);
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
  RefuseIfStale();
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
