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
  {$IFDEF UNIX}BaseUnix,{$ENDIF}
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
  DeleteFile(OutDir + PathDelim + 'through.txt');
  RemoveDir(OutDir + PathDelim + 'made');
  {$IFDEF UNIX}
  FpUnlink(PChar(RootDir + PathDelim + 'door'));
  {$ENDIF}

  // Build the victim tree OUTSIDE the root. Everything destroyed if a guard fails
  // is something this probe just made.
  ForceDirectories(RootDir);
  ForceDirectories(OutDir + PathDelim + 'sub');
  WriteFile(OutDir + PathDelim + 'victim.txt', 'still here');
  WriteFile(OutDir + PathDelim + 'sub' + PathDelim + 'deep.txt', 'still here too');

  { --- the perilous-path rule, asserted DIRECTLY ---------------------------
    IsPerilousPath is a pure function, so every one of these can be asked without
    a filesystem anywhere near it. That matters more here than anywhere else in
    this probe: the thing being tested is the guard in front of a recursive
    delete, and the way NOT to test it is to run one.

    'C:/' is the case that was open. ExcludeTrailingPathDelimiter strips PathDelim
    and nothing else, which on Windows is the backslash alone -- so "C:\" reduced
    to "C:" and was caught, while "C:/" stayed three characters and was not. The
    Windows API takes both, and this project's own documentation tells a reader to
    write the forward slash, because a backslash in a string literal is an escape.
    The rule was blind to the spelling it had taught people to use. }
  Report(IsPerilousPath(''), 'perilous: the empty path');
  Report(IsPerilousPath('   '), 'perilous: whitespace only');
  {$IFDEF WINDOWS}
  Report(IsPerilousPath('C:'), 'perilous: a bare drive letter');
  Report(IsPerilousPath('C:\'), 'perilous: a drive root with a backslash');
  Report(IsPerilousPath('C:/'), 'perilous: a drive root with a FORWARD slash');
  Report(IsPerilousPath('C:\\'), 'perilous: a drive root with two backslashes');
  Report(IsPerilousPath('C://'), 'perilous: a drive root with two forward slashes');
  Report(IsPerilousPath(' C:/ '), 'perilous: a drive root with spaces around it');
  Report(IsPerilousPath('\\server\share'), 'perilous: a UNC share root');
  Report(IsPerilousPath('//server/share'), 'perilous: a UNC share root, forward slashes');
  Report(not IsPerilousPath('C:\Users\someone'), 'and an ordinary path is not');
  Report(not IsPerilousPath('C:/Users/someone'), 'nor is it with forward slashes');
  Report(not IsPerilousPath('\\server\share\folder'), 'nor a folder on a share');
  {$ELSE}
  Report(IsPerilousPath('/'), 'perilous: the filesystem root');
  Report(IsPerilousPath('//'), 'perilous: the root, doubled');
  Report(IsPerilousPath(' / '), 'perilous: the root with spaces around it');
  Report(not IsPerilousPath('/home/someone'), 'and an ordinary path is not');
  Report(not IsPerilousPath('/home/someone/'), 'nor one with a trailing slash');
  {$ENDIF}

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

  // --- a door planted INSIDE the root, opening outside it ---------------------
  // The one escape a path-string check does not catch: every component of
  // '<root>/door/secret.txt' is inside the root as WRITTEN, and only resolving
  // the link shows where it really goes.
  {$IFDEF UNIX}
  FpSymlink(PChar(OutDir), PChar(RootDir + PathDelim + 'door'));
  if not DirectoryExists(RootDir + PathDelim + 'door') then
    Report(False, 'the probe could not plant a symlink to test with')
  else
  begin
    Check('a read through a symlink out of the root is refused',
          'print file_readalltext$("' + Slash(RootDir) + '/door/victim.txt")' + LF, '');
    Check('a write through a symlink out of the root is refused',
          'print file_writealltext("' + Slash(RootDir) + '/door/through.txt", "x")' + LF, '0');
    Report(not FileExists(OutDir + PathDelim + 'through.txt'),
           'and nothing was written through it');
    Check('a listing through a symlink out of the root is refused',
          'print dir_getfiles$("' + Slash(RootDir) + '/door")' + LF, '');
    Report(FileExists(OutDir + PathDelim + 'victim.txt'),
           'and the tree the link points at is untouched');
    FpUnlink(PChar(RootDir + PathDelim + 'door'));
  end;
  {$ELSE}
  // Not a silent skip: creating a symlink on Windows needs SeCreateSymbolicLink,
  // which this machine does not grant. It goes to STDOUT with a "skip:" prefix,
  // which the suite runners print alongside ok:/fail: -- a skip nobody sees is a
  // pass, and this one is not a pass.
  Writeln('skip: symlink escape (needs a symlink; Windows creation is privileged)');
  {$ENDIF}

  // --- the scratch places answer inside the root ------------------------------
  RunUnder(RootDir, 'print temppath$()' + LF);
  Report(Pos(LowerCase(RealPathOf(RootDir)), LowerCase(Answer)) = 1,
         'temppath$ answers inside the root (got "' + Answer + '")');

  { --- rule 1 holds with NO sandbox at all -----------------------------------

    ASKED, NOT ATTEMPTED. This block used to drive the engine's recursive
    directory-removal function, with no sandbox set, against the empty path and
    against a drive root, and assert the answer was 0. It always was -- the gate
    refused both before any removal was issued, on this version and on every
    version before it -- but a test file that CONTAINS that call spelled against a
    root is a loaded weapon lying on the bench. One editing slip, one guard that
    stops holding, and the assertion meant to prove safety is the thing that
    destroys the machine. This project has already lost thirteen working trees
    that way; every runner carries a comment about it. The call is not written
    here in any form, so there is nothing to copy and nothing to run by accident.

    SandboxAllows is the gate itself -- the function dir_delete asks before acting
    -- and it is a pure query returning True or False. Asking it proves exactly
    what the old lines proved, including that rule 1 applies when no root is set,
    with no code path from here to a deletion at all.

    The end-to-end chain, that dir_delete really does consult this gate, is proven
    above by 'a recursive dir_delete outside the root is refused', which names a
    temporary directory this probe created. }
  SetSandboxRoot('');
  Report(not SandboxActive, 'no root is set for these');
  Report(not SandboxAllows('', puDelete),
         'an empty path is refused even with no root set');
  Report(not SandboxAllows({$IFDEF WINDOWS}'C:/'{$ELSE}'/'{$ENDIF}, puDelete),
         'and so is a drive root');
  Report(not SandboxAllows({$IFDEF WINDOWS}'C:\'{$ELSE}'//'{$ENDIF}, puDelete),
         'and the other spelling of it');
  Report(SandboxAllows(OutDir, puDelete),
         'while an ordinary directory is allowed, so the rule is not refusing everything');

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
