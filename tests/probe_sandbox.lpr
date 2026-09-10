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

{ The two halves of the perilous-path sweep. Both ASK IsPerilousPath, which is a
  pure predicate over a string -- no path named below is ever handed to anything
  that acts. The spelling is quoted into the failure message so a regression says
  WHICH spelling got through. }
procedure Peril(const APath, AWhy: String);
begin
  Report(IsPerilousPath(APath), 'perilous: ' + AWhy + ' -- "' + APath + '"');
end;

procedure Ordinary(const APath, AWhy: String);
begin
  Report(not IsPerilousPath(APath),
         'NOT perilous: ' + AWhy + ' -- "' + APath + '"');
end;

const
  LF = #10;

var
  survived: Boolean;
  SavedCwd: String;   // restored immediately; see the relative-spelling block
  RootCwd: String;
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
    IsPerilousPath is a pure predicate over a string -- ExpandFileName reads the
    process's own current directory and nothing else (see the header comment in
    engine/PhosphorSandbox.pas) -- so every one of these can be asked without a
    filesystem anywhere near it. That matters more here than anywhere else in
    this probe: the thing being tested is the guard in front of a recursive
    delete, and the way NOT to test it is to run one.

    THE RANGE, NOT A LIST. The rule has lost to a new SPELLING of a drive root
    three times: "C:/" (ExcludeTrailingPathDelimiter strips PathDelim, and on
    Windows that is the backslash alone), "C:\\" (it strips exactly one), and the
    UNC share root (the separator count was wrong). Each fix pinned the spelling
    that had been found, so the next one walked through -- and the next one was a
    whole family: everything that reaches a root through '.' and '..'. What is
    swept below is therefore the RANGE of spellings, not the ones that happened
    to be reported: both separators and mixed, doubled and trailing, a dot or a
    dot-dot segment at every position, a climb from one level and from six, UNC
    and extended-length and device prefixes, case, a trailing space, a long path,
    and the relative forms further down. If a spelling nobody has written yet
    reaches a root, the structural rule these pin is what has to catch it. }
  Peril('', 'the empty path');
  Peril('   ', 'whitespace only');
  {$IFDEF WINDOWS}
  // the volume named with no directory in it
  Peril('C:', 'a bare drive letter');
  Peril('C:\', 'a drive root with a backslash');
  Peril('C:/', 'a drive root with a FORWARD slash');
  Peril('C:\\', 'a drive root with two backslashes');
  Peril('C://', 'a drive root with two forward slashes');
  Peril('C:\/', 'a drive root with one of each');
  Peril('c:\', 'a lower-case drive letter');
  Peril('C:\ ', 'a drive root with a trailing space');
  Peril(' C:/ ', 'a drive root with spaces around it');
  Peril('\', 'a bare separator');
  Peril('/', 'a bare forward slash');
  // the same places reached through '.'
  Peril('C:\.', 'a drive root as a dot segment');
  Peril('C:/.', 'the same with a forward slash');
  Peril('C:\.\', 'a dot segment with a trailing separator');
  Peril('C:\.\\', 'a dot segment with two trailing separators');
  Peril('C:\.\.', 'two dot segments');
  Peril('\.', 'a dot segment off the current drive');
  Peril('\.\', 'the same with a trailing separator');
  // and through '..', from every depth
  Peril('C:\..', 'a drive root climbed past');
  Peril('C:/..', 'the same with a forward slash');
  Peril('C:\..\', 'the same with a trailing separator');
  Peril('C:\..\..', 'climbing twice past a drive root');
  Peril('\..', 'climbing past the root of the current drive');
  Peril('/..', 'the same with a forward slash');
  Peril('C:\dir\..', 'one directory, climbed out of');
  Peril('C:/dir\..', 'the same with mixed separators');
  Peril('C:\dir/..', 'mixed the other way');
  Peril('C:\dir\..\', 'and with a trailing separator');
  Peril('C:\dir\..\.', 'climbed out of, then a dot segment');
  Peril('\dir\..', 'the same off the current drive');
  Peril('C:\Windows\..', 'a real directory, climbed out of');
  Peril('C:\a\b\..\..', 'two levels climbed out of');
  Peril('C:\a\b\..\..\..', 'more climbs than there are levels');
  Peril('C:\a\b\c\d\e\f\..\..\..\..\..\..', 'six levels climbed out of');
  Peril('C:\Program Files\Common Files\..\..', 'names with spaces in them');
  Peril('C:\' + StringOfChar('a', 200) + '\..', 'a long name climbed out of');
  // a share, a server, and the extended and device spellings of a volume
  Peril('\\server\share', 'a UNC share root');
  Peril('//server/share', 'a UNC share root, forward slashes');
  Peril('\\server\share\', 'a UNC share root with a trailing separator');
  Peril('\\server\share\.', 'a UNC share root as a dot segment');
  Peril('\\server\share\..', 'a UNC share root climbed past');
  Peril('\\server\share\dir\..', 'a folder on a share, climbed out of');
  Peril('\\server\share\a\b\..\..', 'two levels on a share, climbed out of');
  Peril('\\server', 'a UNC server with no share');
  Peril('\\server\', 'the same with a trailing separator');
  Peril('\\?\C:', 'an extended-length drive');
  Peril('\\?\C:\', 'an extended-length drive root');
  Peril('\\?\C:\.', 'an extended-length drive root as a dot segment');
  Peril('\\?\C:\..', 'an extended-length drive root climbed past');
  Peril('\\?\C:\dir\..', 'a folder under one, climbed out of');
  Peril('\\?\UNC\server\share', 'an extended-length UNC share root');
  Peril('\\?\UNC\server\share\..', 'the same, climbed past');
  Peril('\\.\C:', 'a device-path drive');
  Peril('\\.\C:\', 'a device-path drive root');

  { --- AND THE MIRROR. A guard that refuses legitimate work is as useless as
    one that lets everything through, and a structural rule is exactly the kind
    that over-reaches: every path below is one a real program writes, and every
    one of them must still be accepted. }
  Ordinary('C:\Users\someone', 'an ordinary absolute path');
  Ordinary('C:/Users/someone', 'the same with forward slashes');
  Ordinary('C:\Users\someone\', 'an ordinary path with a trailing separator');
  Ordinary('C:\Users\someone\\', 'and with two');
  Ordinary('C:\a\report.v1.txt', 'a file with dots in its NAME');
  Ordinary('C:\Users\me\.hidden', 'a name that begins with a dot');
  Ordinary('C:\Users\me\..hidden', 'a name that begins with two');
  Ordinary('C:\Users\me\a..b', 'a name with two dots inside it');
  Ordinary('C:\a\...', 'a directory named "..."');
  Ordinary('C:\...', 'one of those at the top level');
  Ordinary('report.v1.txt', 'a bare relative filename');
  Ordinary('sub\file.txt', 'a relative path');
  Ordinary('sub/file.txt', 'the same with a forward slash');
  Ordinary('.\sub\file.txt', 'a relative path that starts with a dot');
  Ordinary('..\sibling\file.txt', 'one that starts by climbing');
  Ordinary('C:\a\..\b', 'a path that climbs and comes back down');
  Ordinary('C:\a\b\..\..\c', 'one that climbs twice and comes back');
  Ordinary('C:\..\a', 'one that climbs past the root and comes back');
  Ordinary('\\server\share\folder', 'a folder on a share');
  Ordinary('\\server\share\folder\', 'the same with a trailing separator');
  Ordinary('\\server\share\folder\..\sub', 'a sideways move on a share');
  Ordinary('\\?\C:\Users\me', 'an extended-length ordinary path');
  Ordinary('\\?\UNC\server\share\folder', 'an extended-length folder on a share');
  Ordinary('C:\' + StringOfChar('d', 200) + '\leaf.txt', 'a long path');
  {$ELSE}
  Peril('/', 'the filesystem root');
  Peril('//', 'the root, doubled');
  Peril('///', 'the root, tripled');
  Peril(' / ', 'the root with spaces around it');
  Peril('/ ', 'the root with a trailing space');
  Peril('/.', 'the root as a dot segment');
  Peril('/./', 'the same with a trailing separator');
  Peril('/./.', 'two dot segments');
  Peril('/..', 'the root climbed past');
  Peril('/../..', 'climbed past twice');
  Peril('/home/..', 'a real directory, climbed out of');
  Peril('/home/../', 'the same with a trailing separator');
  Peril('/a/b/../..', 'two levels climbed out of');
  Peril('/a/b/../../..', 'more climbs than there are levels');
  Peril('/a/b/c/d/e/f/../../../../../..', 'six levels climbed out of');
  Peril('/' + StringOfChar('a', 200) + '/..', 'a long name climbed out of');

  { --- AND THE MIRROR: everything a real program writes must still be accepted. }
  Ordinary('/home/someone', 'an ordinary absolute path');
  Ordinary('/home/someone/', 'one with a trailing slash');
  Ordinary('/home/a/report.v1.txt', 'a file with dots in its NAME');
  Ordinary('/home/me/.hidden', 'a name that begins with a dot');
  Ordinary('/home/me/a..b', 'a name with two dots inside it');
  Ordinary('/home/...', 'a directory named "..."');
  Ordinary('report.v1.txt', 'a bare relative filename');
  Ordinary('sub/file.txt', 'a relative path');
  Ordinary('./sub/file.txt', 'a relative path that starts with a dot');
  Ordinary('../sibling/file.txt', 'one that starts by climbing');
  Ordinary('/home/a/../b', 'a path that climbs and comes back down');
  Ordinary('/a/b/../../c', 'one that climbs twice and comes back');
  Ordinary('/' + StringOfChar('d', 200) + '/leaf.txt', 'a long path');
  { A BACKSLASH IS AN ORDINARY FILENAME CHARACTER HERE, and the structural rule
    resolves with ExpandFileName, which treats it as a separator on Unix too --
    rtl/unix/sysunixh.inc:35 declares AllowDirectorySeparators as ['\','/'] on
    EVERY platform. So a name made of backslashes and dots reduced to '/' and
    became perilous: a file literally called '\' stopped being writable. These
    four are the deviation, and they only fail on the platform where they matter,
    which is why the Windows-only sweep that preceded them saw nothing. }
  Ordinary('\', 'a file named with one backslash');
  Ordinary('..\', 'a backslash after two dots');
  Ordinary('\..', 'a backslash before two dots');
  Ordinary('/home/a\b', 'a backslash inside a component');
  {$ENDIF}

  { --- the relative spellings, which only a RESOLVED rule can see -------------
    '.' is the drive root when the working directory is the drive root, and a
    textual rule cannot know that. Proven by moving this process's own working
    directory -- a per-process setting, restored two lines later, that creates,
    writes and removes nothing -- and then asking the predicate.

    A failure to chdir is reported, not skipped: a skip nobody sees is a pass. }
  SavedCwd := GetCurrentDir;
  {$IFDEF WINDOWS}
  RootCwd := ExtractFileDrive(SavedCwd) + PathDelim;
  {$ELSE}
  RootCwd := '/';
  {$ENDIF}
  if not SetCurrentDir(RootCwd) then
    Report(False, 'the probe could not enter ' + RootCwd + ' to test relative spellings')
  else
  begin
    Peril('.', 'a dot, from a working directory that IS a root');
    Peril('..', 'a dot-dot, from the same');
    Peril('.' + PathDelim, 'a dot with a trailing separator, from the same');
    Peril('.' + PathDelim + '.', 'two dot segments, from the same');
    Peril('..' + PathDelim + '..', 'two climbs, from the same');
    Ordinary('sub', 'while a plain name under that root is not');
    Ordinary('a.txt', 'nor a file in it');
    Ordinary('sub' + PathDelim + 'a.txt', 'nor a file one level down');
    SetCurrentDir(SavedCwd);
    Report(SameText(GetCurrentDir, SavedCwd),
           'and the working directory is put back (now "' + GetCurrentDir + '")');
  end;

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
  { A JUNCTION, WHICH IS THE WINDOWS SHAPE OF THE SAME ATTACK.

    This used to be a skip, with the reason that creating a SYMLINK on Windows
    needs SeCreateSymbolicLink and this machine does not grant it. That reason is
    true and it was the wrong conclusion, because a symlink is not the only door:
    a DIRECTORY JUNCTION redirects a directory just as well, `mklink /J` creates
    one with NO special privilege, and it is therefore the form a confined script
    or a careless user is actually able to make.

    So the strongest claim the sandbox makes -- that a link planted INSIDE the
    root and pointing out of it is refused, because every component of the path
    as WRITTEN is inside and only resolving it shows otherwise -- is now asserted
    on Windows too, against the link Windows lets anyone create.

    Measured before this was written, with bin\phosphor.exe --sandbox over a
    junction: read answered empty, write answered 0, listing answered empty, and
    nothing appeared in the target directory. The behaviour was already right;
    nothing on this platform said so.

    If mklink fails anyway -- a policy, a different volume, a filesystem without
    reparse points -- it is still a SKIP with the reason, never a silent pass. }
  if ExecuteProcess(GetEnvironmentVariable('ComSpec'),
                    ['/c', 'mklink', '/J',
                     RootDir + PathDelim + 'door', OutDir]) <> 0 then
    Writeln('skip: junction escape (mklink /J refused; no reparse point to test)')
  else if not DirectoryExists(RootDir + PathDelim + 'door') then
    Report(False, 'mklink reported success but planted no junction')
  else
  begin
    Check('a read through a junction out of the root is refused',
          'print file_readalltext$("' + Slash(RootDir) + '/door/victim.txt")' + LF, '');
    Check('a write through a junction out of the root is refused',
          'print file_writealltext("' + Slash(RootDir) + '/door/through.txt", "x")' + LF, '0');
    Report(not FileExists(OutDir + PathDelim + 'through.txt'),
           'and nothing was written through it');
    Check('a listing through a junction out of the root is refused',
          'print dir_getfiles$("' + Slash(RootDir) + '/door")' + LF, '');
    Report(FileExists(OutDir + PathDelim + 'victim.txt'),
           'and the tree the junction points at is untouched');
    { RemoveDir on a junction removes the LINK, not the directory it names --
      that is what makes it safe to undo here. The target is asserted intact
      immediately above, so a reader can see the difference was checked rather
      than assumed. }
    RemoveDir(RootDir + PathDelim + 'door');
    Report(DirectoryExists(OutDir),
           'and removing the junction left the target directory alone');
  end;
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
  { The spellings that got through. The gate, not just the predicate: these are
    the answers dir_delete acts on, and with no --sandbox they are the ONLY thing
    between a script and the drive root. Asked, never attempted. }
  Report(not SandboxAllows({$IFDEF WINDOWS}'C:\.'{$ELSE}'/.'{$ENDIF}, puDelete),
         'and the dot-segment spelling of it');
  Report(not SandboxAllows({$IFDEF WINDOWS}'C:\dir\..'{$ELSE}'/dir/..'{$ENDIF}, puDelete),
         'and the spelling that climbs out of a directory into it');
  Report(not SandboxAllows({$IFDEF WINDOWS}'C:\a\b\..\..'{$ELSE}'/a/b/../..'{$ENDIF}, puDelete),
         'and the one that climbs two levels into it');
  {$IFDEF WINDOWS}
  Report(not SandboxAllows('\\server\share\..', puDelete),
         'and a share root reached by climbing');
  Report(not SandboxAllows('\\?\C:\..', puDelete),
         'and an extended-length drive root reached by climbing');
  {$ENDIF}
  Report(not SandboxAllows({$IFDEF WINDOWS}'C:\.'{$ELSE}'/.'{$ENDIF}, puWrite),
         'a write to one is refused too, not only a delete');
  Report(SandboxAllows({$IFDEF WINDOWS}'C:\.'{$ELSE}'/.'{$ENDIF}, puRead),
         'while READING a drive root is still allowed: listing one destroys nothing');
  Report(SandboxAllows(OutDir, puDelete),
         'while an ordinary directory is allowed, so the rule is not refusing everything');
  Report(SandboxAllows(OutDir + PathDelim + 'sub' + PathDelim + '..' + PathDelim +
                       'report.v1.txt', puWrite),
         'and so is a path that climbs and comes back down to a dotted filename');

  { --- THE MIRROR, with a root set: everything a real program does inside it --
    A rule that resolves paths is exactly the kind that over-reaches, and the
    cost of over-reaching is a sandbox that refuses the work it was installed to
    permit. Each of these is a path an ordinary script writes. }
  SetSandboxRoot(RootDir);
  Report(SandboxActive, 'a root is set for these');
  Report(SandboxAllows(RealPathOf(RootDir), puWrite),
         'the root itself is writable');
  Report(SandboxAllows(IncludeTrailingPathDelimiter(RealPathOf(RootDir)), puWrite),
         'and with a trailing separator');
  Report(SandboxAllows(RealPathOf(RootDir) + PathDelim + 'sub', puWrite),
         'a subdirectory of it is writable');
  Report(SandboxAllows(RealPathOf(RootDir) + PathDelim + 'report.v1.txt', puWrite),
         'a file with dots in its name is writable');
  Report(SandboxAllows(RealPathOf(RootDir) + PathDelim + 'a' + PathDelim + '..' +
                       PathDelim + 'b', puWrite),
         'and a path that climbs and comes back inside');
  Report(not SandboxAllows(RealPathOf(RootDir) + PathDelim + '..', puWrite),
         'while one that climbs OUT of the root is still refused');
  SetSandboxRoot('');

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
