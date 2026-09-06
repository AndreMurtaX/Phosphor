{******************************************************************************
  probe_sandbox -- a Pascal test of the filesystem ceiling (phase-3 step 6)

  The sandbox root is a HOST-facing feature, like the three execution ceilings:
  the embedder sets it on TPhosphorEngine before Run, so it is tested here from
  Pascal, the way a host uses it -- not from a .bas file, which cannot set it and
  (deliberately) has no way to.

  WHY THE TEST LOOKS LIKE THIS. A guard whose job is to stop a deletion cannot be
  proven by running the deletion on anything that matters. So this probe MAKES its
  own victim tree, in the platform temp directory, OUTSIDE the root it then sets --
  and asserts the tree is still there afterwards. If the guard ever breaks, what
  the test destroys is the directory the test itself created, and nothing else.
  That is the whole reason the check exists in this form; see
  docs/dev-agent-playbook.md, "a destructive defect is verified by reading".

  Prints "ok: N" / "fail: M" and exits non-zero on any failure. Run with --fail to
  corrupt one expectation and confirm the check can fail.
******************************************************************************}
program probe_sandbox;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  SysUtils, PhosphorEngine, PhosphorSandbox;

type
  { OnOutput is a method pointer, so the collector needs an instance to belong to. }
  TSink = class
    procedure Take(const S: String);
  end;

var
  Sink: TSink;
  Ok: Integer = 0;
  Failed: Integer = 0;
  ProveFail: Boolean = False;
  RootDir: String;      // the sandbox root
  OutDir: String;       // the victim tree, outside it
  Answer: String;       // whatever the last script PRINTed

procedure Report(Pass: Boolean; const Name: String);
begin
  if Pass then Inc(Ok)
  else begin Inc(Failed); Writeln(StdErr, 'FAIL: ', Name); end;
end;

procedure TSink.Take(const S: String);
begin
  Answer := Answer + S;
end;

{ Run ASource with the root set (or cleared, when ARoot is ''), and leave what it
  printed in Answer. Returns the engine's exit code. }
function RunUnder(const ARoot, ASource: String): Integer;
var
  eng: TPhosphorEngine;
begin
  Answer := '';
  eng := TPhosphorEngine.Create();
  try
    eng.OnOutput := @Sink.Take;
    eng.SandboxRoot := ARoot;
    Result := eng.Run(ASource);
    if Result <> 0 then
      Answer := Answer + '<error:' + eng.ErrorMessage + '>';
  finally
    eng.Free;
    // Leave no root behind: the setting is process-wide, and a later probe in the
    // same binary would otherwise inherit it.
    SetSandboxRoot('');
  end;
end;

{ Assert on what a one-line script answered. }
procedure Check(const AName, ASource, AWant: String);
begin
  RunUnder(RootDir, ASource);
  Report(Answer = AWant, AName + ' (wanted "' + AWant + '", got "' + Answer + '")');
end;

procedure WriteFile(const APath, AContent: String);
var
  f: TextFile;
begin
  AssignFile(f, APath);
  Rewrite(f);
  Write(f, AContent);
  CloseFile(f);
end;

function Slash(const S: String): String;
begin
  // Phosphor accepts '/' as a separator on every platform, which keeps the
  // generated BASIC free of backslash-doubling.
  Result := StringReplace(S, '\', '/', [rfReplaceAll]);
end;

const
  LF = #10;

var
  survived: Boolean;
begin
  ProveFail := (ParamCount >= 1) and (ParamStr(1) = '--fail');
  Sink := TSink.Create();

  RootDir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'phosphor_probe_root';
  OutDir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'phosphor_probe_outside';

  // START FROM NOTHING. A previous run that FAILED left files behind -- that is
  // what a failure here means -- and a test whose next run inherits them reports
  // the old damage instead of today's state. Cleared through Pascal, by name.
  DeleteFile(IncludeTrailingPathDelimiter(GetTempDir(False)) + 'escaped.txt');
  DeleteFile(OutDir + PathDelim + 'chan.txt');
  DeleteFile(OutDir + PathDelim + 'new.txt');
  DeleteFile(OutDir + PathDelim + 'unbounded.txt');
  RemoveDir(OutDir + PathDelim + 'made');

  // Build the victim tree OUTSIDE the root. Everything destroyed if a guard fails
  // is something this probe just made.
  ForceDirectories(RootDir);
  ForceDirectories(OutDir + PathDelim + 'sub');
  WriteFile(OutDir + PathDelim + 'victim.txt', 'still here');
  WriteFile(OutDir + PathDelim + 'sub' + PathDelim + 'deep.txt', 'still here too');

  // --- the root is what the host asked for, and the script can read it --------
  RunUnder(RootDir, 'print sandboxroot$()' + LF);
  Report(SameText(Answer, RealPathOf(RootDir)),
         'sandboxroot$ reports the resolved root (got "' + Answer + '")');

  // --- inside the root, everything works as before ---------------------------
  Check('a write inside the root succeeds',
        'print file_writealltext("' + Slash(RootDir) + '/inside.txt", "hello")' + LF, '1');
  Report(FileExists(RootDir + PathDelim + 'inside.txt'),
         'and the file is really there');
  Check('and reads back',
        'print file_readalltext$("' + Slash(RootDir) + '/inside.txt")' + LF, 'hello');

  // --- outside the root, nothing does ----------------------------------------
  Check('a write outside the root is refused',
        'print file_writealltext("' + Slash(OutDir) + '/new.txt", "x")' + LF, '0');
  Report(not FileExists(OutDir + PathDelim + 'new.txt'),
         'and no file was made outside');

  Check('a read outside the root answers empty',
        'print file_readalltext$("' + Slash(OutDir) + '/victim.txt")' + LF, '');
  Report(FileExists(OutDir + PathDelim + 'victim.txt'),
         'while the file it refused to read is still there');

  Check('file_delete outside the root is refused',
        'print file_delete("' + Slash(OutDir) + '/victim.txt")' + LF, '0');
  Report(FileExists(OutDir + PathDelim + 'victim.txt'),
         'and the file survived the refusal');

  // THE ONE THAT MATTERS. A recursive delete aimed outside the root, answered 0
  // and carried out on nothing.
  Check('a recursive dir_delete outside the root is refused',
        'print dir_delete("' + Slash(OutDir) + '", 1)' + LF, '0');
  survived := FileExists(OutDir + PathDelim + 'victim.txt') and
              FileExists(OutDir + PathDelim + 'sub' + PathDelim + 'deep.txt');
  Report(survived, 'and the whole tree outside the root is still standing');

  Check('dir_create outside the root is refused',
        'print dir_create("' + Slash(OutDir) + '/made")' + LF, '0');
  Report(not DirectoryExists(OutDir + PathDelim + 'made'),
         'and no directory was made outside');

  // --- the ways out that are not an absolute path ----------------------------
  Check('a relative escape with .. is refused',
        'print file_writealltext("' + Slash(RootDir) + '/../escaped.txt", "x")' + LF, '0');
  Report(not FileExists(IncludeTrailingPathDelimiter(GetTempDir(False)) + 'escaped.txt'),
         'and nothing was written beside the root');

  Check('a listing outside the root answers empty',
        'print dir_getfiles$("' + Slash(OutDir) + '")' + LF, '');

  Check('moving the working directory outside the root is refused',
        'print dir_setcurrent("' + Slash(OutDir) + '")' + LF, '0');

  // A channel is the other way to the filesystem; it is bounded by the same root.
  Report(RunUnder(RootDir,
           'open "' + Slash(OutDir) + '/chan.txt" for output as #1' + LF +
           'print #1, "x"' + LF + 'close #1' + LF) <> 0,
         'OPEN FOR OUTPUT outside the root fails the run');
  Report(not FileExists(OutDir + PathDelim + 'chan.txt'),
         'and no channel file was made outside');

  // --- the scratch places answer inside the root ------------------------------
  RunUnder(RootDir, 'print temppath$()' + LF);
  Report(Pos(LowerCase(RealPathOf(RootDir)), LowerCase(Answer)) = 1,
         'temppath$ answers inside the root (got "' + Answer + '")');

  // --- rule 1 holds with NO sandbox at all -----------------------------------
  RunUnder('', 'print dir_delete("", 1)' + LF);
  Report(Answer = '0', 'an empty path is refused even with no root set');
  RunUnder('', 'print dir_delete("' + {$IFDEF WINDOWS}'C:/'{$ELSE}'/'{$ENDIF} + '", 1)' + LF);
  Report(Answer = '0', 'and so is a drive root');

  // --- and with no root, the ceiling costs nothing ----------------------------
  RunUnder('', 'print file_writealltext("' + Slash(OutDir) + '/unbounded.txt", "x")' + LF);
  Report((Answer = '1') and FileExists(OutDir + PathDelim + 'unbounded.txt'),
         'with no root set, the same write outside succeeds (the ceiling is opt-in)');

  if ProveFail then
    Report(False, 'deliberate failure (--fail)');

  // Clean up what the probe made, through Pascal -- not through the engine.
  DeleteFile(OutDir + PathDelim + 'unbounded.txt');
  DeleteFile(OutDir + PathDelim + 'victim.txt');
  DeleteFile(OutDir + PathDelim + 'sub' + PathDelim + 'deep.txt');
  RemoveDir(OutDir + PathDelim + 'sub');
  RemoveDir(OutDir);
  DeleteFile(RootDir + PathDelim + 'inside.txt');

  Sink.Free;

  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed > 0 then Halt(1) else Halt(0);
end.
