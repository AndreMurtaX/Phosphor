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

{ PLANT A LINK -- a POSIX symlink, a Windows directory junction. Two shapes of one
  thing, and the shape is what the sandbox cares about: a directory entry that
  names ANOTHER directory, which no amount of string arithmetic can see through.
  Both are creatable by an unprivileged process, which is what makes them the
  attack a confined script can actually mount (a Windows SYMLINK needs
  SeCreateSymbolicLink and is therefore NOT the interesting case).

  FileGetAttr, not DirectoryExists, decides whether it landed: DirectoryExists
  answers False for a junction whose target the RTL cannot stat -- a bare drive
  root, or a target that is not there -- and those are two of the four planted
  below. }
function PlantLink(const ALink, ATarget: String): Boolean;
begin
  {$IFDEF UNIX}
  FpSymlink(PChar(ATarget), PChar(ALink));
  {$ELSE}
  { The one-string form, so mklink's own chatter can be redirected: it prints a
    LOCALISED success line, and four of them in the middle of a probe's output is
    noise a reader has to learn to ignore. }
  ExecuteProcess(GetEnvironmentVariable('ComSpec'),
                 '/c mklink /J "' + ALink + '" "' + ATarget + '" >NUL 2>&1');
  {$ENDIF}
  Result := FileGetAttr(ALink) <> -1;
end;

{$IFDEF WINDOWS}
{ DOES FPC DECODE A TARGET FOR THIS ENTRY? Only for IO_REPARSE_TAG_MOUNT_POINT
  and IO_REPARSE_TAG_SYMLINK; every other tag answers slrNoSymLink, which is
  False here -- and FileGetSymLinkTarget RAISES when it cannot stat a target it
  did decode, which is why this is wrapped. }
function Decodable(const APath: String): Boolean;
var
  t: RawByteString;
begin
  t := '';
  try
    Result := FileGetSymLinkTarget(RawByteString(APath), t) and (t <> '');
  except
    Result := False;
  end;
end;
{$ENDIF}

{ Remove THE LINK and never what it names. RemoveDir on a junction removes the
  reparse point; FpUnlink removes the symlink. Every use below asserts the target
  is still standing afterwards, so the difference is checked and not assumed --
  and one of these links names a drive root. }
procedure PullLink(const ALink: String);
begin
  {$IFDEF UNIX}
  FpUnlink(PChar(ALink));
  {$ELSE}
  RemoveDir(ALink);
  {$ENDIF}
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
  linkPeril, linkGate: Boolean;   // read before the link is pulled, reported after
  volPeril, volWrite, volSub: Boolean;  // likewise, for the drive-root link in (g)
  SavedCwd: String;   // restored immediately; see the relative-spelling block
  RootCwd: String;
  seg, deep: String;  // the too-many-components sweep
  thru: String;       // a path spelled through a link
  i: Integer;
  {$IFDEF WINDOWS}
  wapps, odd: String;
  wsr: TSearchRec;
  {$ENDIF}
begin
  ProveFail := (ParamCount >= 1) and (ParamStr(1) = '--fail');
  Sink := TSink.Create();

  RootDir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'phosphor_probe_root';
  OutDir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'phosphor_probe_outside';

  // START FROM NOTHING. A previous run that FAILED left files behind -- that is
  // what a failure here means -- and a test whose next run inherits them reports
  // the old damage instead of today's state. Cleared through Pascal, by name.
  DeleteFile(IncludeTrailingPathDelimiter(GetTempDir(False)) + 'escaped.txt');
  DeleteFile(IncludeTrailingPathDelimiter(GetTempDir(False)) + 'linkesc.txt');
  DeleteFile(OutDir + PathDelim + 'chan.txt');
  DeleteFile(OutDir + PathDelim + 'new.txt');
  DeleteFile(OutDir + PathDelim + 'nul.txt');
  DeleteFile(OutDir + PathDelim + 'unbounded.txt');
  DeleteFile(OutDir + PathDelim + 'through.txt');
  DeleteFile(RootDir + PathDelim + 'ok.txt');
  DeleteFile(RootDir + PathDelim + 'linkesc.txt');
  RemoveDir(OutDir + PathDelim + 'made');
  { The links a FAILED run may have left behind. PullLink removes the link and
    never its target -- FpUnlink on a symlink, RemoveDir on a junction -- so this
    is safe to run against names that may be ordinary directories, links, or
    nothing at all, which is exactly what is not known here. }
  PullLink(RootDir + PathDelim + 'indoor');
  PullLink(RootDir + PathDelim + 'outdoor');
  PullLink(RootDir + PathDelim + 'nowhere');
  PullLink(RootDir + PathDelim + 'rootdoor');
  RemoveDir(RootDir + PathDelim + 'inner');
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

  { --- A NUL BYTE, WHICH ENDS THE PATH FOR THE KERNEL AND NOT FOR A STRING TEST
    FPC hands a path to CreateFileW and to fpOpen as a PChar, and both stop at
    the first #0, while every test in the unit measured the whole of the string.
    So 'C:\' + #0 + 'x' was measured as an ordinary directory named x and went
    through the guard that stands in front of the recursive remover, and with a
    root set '<outside>.txt' + #0 + '/../<root>/decoy' resolved back INSIDE the
    root here and opened OUTSIDE it there -- read, write and delete of a single
    file all escaped that way, measured end to end further down.

    Trim is no help and the two lines below say why: #0 <= ' ', so Trim strips
    one only at the ENDS. 'C:\' + #0 was therefore already refused while
    'C:\' + #0 + 'x' was not, which is the whole shape of the hole: a rule that
    happens to catch the spelling nobody would write and misses the one an
    attacker does. Pure predicates -- nothing named here is opened. }
  Peril(#0, 'a path that is nothing but a NUL');
  Peril('  ' + #0 + '  ', 'a NUL among spaces');
  Peril(RootDir + #0 + PathDelim + '..', 'a NUL in the middle of an ordinary path');
  {$IFDEF WINDOWS}
  Peril('C:\' + #0, 'a drive root with a NUL after it');
  Peril('C:\' + #0 + 'x', 'a drive root with a NUL and a NAME after it');
  Peril('C:\Windows' + #0, 'a real directory with a NUL after it');
  {$ELSE}
  Peril('/' + #0, 'the filesystem root with a NUL after it');
  Peril('/' + #0 + 'x', 'the filesystem root with a NUL and a NAME after it');
  Peril('/home' + #0, 'a real directory with a NUL after it');
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

  { --- THE SAME THREE, WITH A NUL WHERE THE KERNEL STOPS READING --------------
    Every path below is the SPELLING ABOVE, plus a NUL, plus a tail that walks
    back inside the root. The tail is what the gate used to resolve; the prefix
    is what CreateFileW and fpOpen open. The three assertions above and these
    three name the same three files, and before the fix these three answered the
    opposite of them: rc=1 with the byte landing outside, the outside file's
    contents read back through a sandboxed read, and the outside file deleted.

    THE TAIL HAS TO REACH ALL THE WAY BACK IN, and getting that wrong is how a
    test passes on both sides of the defect it was written for. The first draft
    of these three climbed ONE level -- '<outside>/nul.txt/../<root>/decoy.txt' --
    which lands in '<outside>/<root>', not in the root, so the gate refused them
    for the ordinary reason and all three passed against the UNFIXED unit. Two
    levels is what reaches the root; measured by removing the fix and watching
    them fail.

    chr$(0) is how a script builds one, and it is the only way it can -- a NUL
    cannot appear in a source literal. Nothing is aimed anywhere but this probe's
    own victim tree. }
  Check('a write whose path hides a NUL is refused',
        'z$ = chr$(0)' + LF +
        'print file_writealltext("' + Slash(OutDir) + '/nul.txt" + z$ + "/../../' +
        'phosphor_probe_root/decoy.txt", "PWNED")' + LF, '0');
  Report(not FileExists(OutDir + PathDelim + 'nul.txt'),
         'and no file was written at the part before the NUL');

  Check('a read whose path hides a NUL answers empty',
        'z$ = chr$(0)' + LF +
        'print file_readalltext$("' + Slash(OutDir) + '/victim.txt" + z$ + "/../../' +
        'phosphor_probe_root/decoy.txt")' + LF, '');
  Report(FileExists(OutDir + PathDelim + 'victim.txt'),
         'and the file it refused to read is still there');

  Check('file_delete whose path hides a NUL is refused',
        'z$ = chr$(0)' + LF +
        'print file_delete("' + Slash(OutDir) + '/victim.txt" + z$ + "/../../' +
        'phosphor_probe_root/x.txt")' + LF, '0');
  Report(FileExists(OutDir + PathDelim + 'victim.txt'),
         'and the file survived that refusal too');

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

  { --- WHAT '..' DOES AFTER A LINK, AND WHAT THE LINK ITSELF IS ---------------

    The block above proves a link out of the root is not a way through it. These
    four are the two things it took a link to find out, and both are one defect:
    THE GATE JUDGED A DIFFERENT PATH THAN THE KERNEL OPENS.

    1. '..' AFTER A LINK. Resolution used to call ExpandFileName first, and
       FExpand is string arithmetic over one GetDir -- it stats nothing. So
       '<root>/outdoor/..' was reduced to '<root>' BEFORE any link was consulted,
       the gate said "inside", and the Linux kernel (path_resolution(7), which
       applies '..' to the LINK TARGET's directory) put the byte one level above
       the target. Measured on the Linux VM against the unfixed unit: rc=1, and
       the file landed outside the root.

       Windows collapses '..' lexically too, so THERE the kernel would have kept
       that write inside the cage and this assertion is stricter than the
       platform. Deliberately: the rule this unit states is one rule on both
       machines -- a link planted inside the root is not a way out of it -- and
       the price of the stricter answer is a spelling nobody writes on purpose.
       The mirror below is what guards against paying more than that.

    2. A LINK THE PLATFORM WILL NOT FOLLOW. `mklink /J rootdoor "C:\"` needs no
       privilege and makes a directory that IS the drive root. FPC will not name
       its target: FileGetSymLinkTargetInt reads '\??\C:\' and then validates it
       with FindFirstFileExW, which fails on a bare root, so the target is thrown
       away and the answer is "not a link". Both string rules therefore called it
       an ordinary folder called rootdoor, and dir_delete would have handed it to
       a recursive remover that Windows walks straight through into C:\. A
       junction whose target is not there at all takes the same branch, so it is
       pinned beside it.

    NOTHING DESTRUCTIVE RUNS WHILE ANY OF THESE LINKS EXISTS. The drive-root one
    is measured with IsPerilousPath and SandboxAllows -- pure queries, which is
    the method CLAUDE.md prescribes for a guard in front of a recursive delete --
    it is pulled on the very next line, and the line after that asserts the root
    it named is still there. }
  ForceDirectories(RootDir + PathDelim + 'inner');

  { (a) THE MIRROR FIRST. A link that stays INSIDE the root, followed by '..',
    is ordinary work and must still be allowed. A walk that refuses this is the
    failure mode this project names before any other. }
  if not PlantLink(RootDir + PathDelim + 'indoor', RootDir + PathDelim + 'inner') then
    Writeln('skip: link inside the root (this platform would not plant one)')
  else
  begin
    SetSandboxRoot(RootDir);
    Report(SandboxAllows(RootDir + PathDelim + 'indoor' + PathDelim + '..' +
                         PathDelim + 'ok.txt', puWrite),
           'a link INSIDE the root, then "..", is still allowed');
    Report(not IsPerilousPath(RootDir + PathDelim + 'indoor'),
           'and an ordinary link is not perilous either');
    SetSandboxRoot('');
    Check('and a write through it succeeds',
          'print file_writealltext("' + Slash(RootDir) + '/indoor/../ok.txt", "x")' + LF, '1');
    Report(FileExists(RootDir + PathDelim + 'ok.txt'),
           'landing exactly where the kernel puts it');
    PullLink(RootDir + PathDelim + 'indoor');
    Report(DirectoryExists(RootDir + PathDelim + 'inner'),
           'and pulling that link left its target directory alone');
  end;

  { (b) the same shape, aimed OUT of the root }
  if not PlantLink(RootDir + PathDelim + 'outdoor', OutDir) then
    Writeln('skip: link out of the root (this platform would not plant one)')
  else
  begin
    Check('a write through a link and THEN ".." is refused',
          'print file_writealltext("' + Slash(RootDir) + '/outdoor/../linkesc.txt", "x")' + LF,
          '0');
    Report(not FileExists(IncludeTrailingPathDelimiter(GetTempDir(False)) + 'linkesc.txt'),
           'and nothing was written beside the link''s TARGET, where the kernel aims');
    Report(not FileExists(RootDir + PathDelim + 'linkesc.txt'),
           'nor inside the root, where collapsing the spelling used to aim');
    SetSandboxRoot(RootDir);
    Report(not SandboxAllows(RootDir + PathDelim + 'outdoor' + PathDelim + '..' +
                             PathDelim + 'linkesc.txt', puWrite),
           'and the gate itself says so, not only the run');
    SetSandboxRoot('');
    PullLink(RootDir + PathDelim + 'outdoor');
    Report(FileExists(OutDir + PathDelim + 'victim.txt'),
           'and pulling that link left the tree it named alone');
  end;

  { (c) a link whose target the platform will not name -- here because it does
    not exist. Same branch as the drive-root junction, with nothing at stake. }
  if not PlantLink(RootDir + PathDelim + 'nowhere',
                   OutDir + PathDelim + 'no_such_target_at_all') then
    Writeln('skip: dangling link (this platform would not plant one)')
  else
  begin
    { THE PERILOUS HALF IS A QUESTION ABOUT A DIRECTORY, and the two platforms
      disagree about whether this entry is one -- measured, not assumed. A
      Windows junction reports $410, directory AND reparse point, even when its
      target is missing, so the rule that guards the recursive remover must
      answer for it. A dangling POSIX symlink reports faSymLink and NOT
      faDirectory, because LinuxToWinAttr sets that bit from a stat of the
      TARGET (rtl/unix/sysutils.pp:633) -- and a link that is not a directory
      cannot be a volume root, so calling it perilous would only refuse the
      legitimate deletion of a broken link. The containment half below is what
      actually stops the write, and that is asserted on both. }
    {$IFDEF WINDOWS}
    Report(IsPerilousPath(RootDir + PathDelim + 'nowhere'),
           'a link the platform will not follow is not judged an ordinary directory');
    {$ENDIF}
    SetSandboxRoot(RootDir);
    Report(not SandboxAllows(RootDir + PathDelim + 'nowhere' + PathDelim + 'x.txt',
                             puWrite),
           'and nothing is written THROUGH one, because where it goes is unknown');
    SetSandboxRoot('');
    PullLink(RootDir + PathDelim + 'nowhere');
  end;

  { (d) THE FINDING ITSELF: a link whose target is a volume root. Queries only;
    the link is pulled before anything is reported, so the window in which it
    exists contains two predicate calls and nothing else. }
  if not PlantLink(RootDir + PathDelim + 'rootdoor',
                   {$IFDEF WINDOWS}'C:\'{$ELSE}'/'{$ENDIF}) then
    Writeln('skip: drive-root link (this platform would not plant one)')
  else
  begin
    linkPeril := IsPerilousPath(RootDir + PathDelim + 'rootdoor');
    linkGate := not SandboxAllows(RootDir + PathDelim + 'rootdoor', puDelete);
    PullLink(RootDir + PathDelim + 'rootdoor');
    Report(linkPeril, 'a link whose target is a VOLUME ROOT is perilous');
    Report(linkGate, 'and no destructive call may be handed it');
    Report(FileGetAttr(RootDir + PathDelim + 'rootdoor') = -1,
           'and the link itself is gone again');
    Report(DirectoryExists({$IFDEF WINDOWS}'C:\'{$ELSE}'/'{$ENDIF}),
           'while the root it named is exactly where it was');
  end;

  { (e) A COMPONENT NAME CONTAINING A BACKSLASH -- the second spelling of the
    '..'-counted-at-the-wrong-depth escape, and the one the ORDER fix did not
    close because it reused the splitter.

    On POSIX a backslash is an ordinary filename byte: 'a\b' is ONE directory to
    the kernel. The gate split on it anyway, on the grounds that
    rtl/unix/sysunixh.inc:35 has ExpandFileName doing so -- so the gate counted
    TWO components where the kernel counts one, and every '..' after it was
    applied one level too deep. Measured through the real host on the VM before
    the fix: '<root>/a\b/../../ESCAPED.txt' was judged INSIDE the root, and the
    byte landed in the root's parent.

    THE MIRROR IS ASSERTED FIRST AND ON BOTH PLATFORMS, because the two platforms
    disagree about what the same string MEANS and that is the whole point: on
    Windows a backslash IS a separator, so there '<root>\a\b\..\..' really is the
    root and must stay allowed. The escape half is POSIX-only for the same
    reason -- it is not an escape where the byte is a separator. }
  ForceDirectories(RootDir + PathDelim + 'a' + PathDelim + 'b');
  SetSandboxRoot(RootDir);
  Report(SandboxAllows(RootDir + PathDelim + 'a' + PathDelim + 'b' + PathDelim +
                       '..' + PathDelim + '..' + PathDelim + 'ok2.txt', puWrite),
         'two real components then two ".." lands back in the root');
  {$IFNDEF WINDOWS}
  { MADE WITH THE SYSCALL, NOT WITH ForceDirectories -- which is the finding in
    miniature. ForceDirectories reaches ExtractFilePath, which reads
    AllowDirectorySeparators, and rtl/unix/sysunixh.inc:35 declares that ['\','/']
    on Unix: so the RTL splits 'a\b' in two and makes a directory named 'a' with
    a 'b' in it, and the test would then have been measuring something else
    entirely. FpMkdir passes the bytes to the kernel, which is the only thing here
    that agrees with the kernel by construction. DirectoryExists does not munge
    separators (rtl/unix/sysutils.pp fpstat's the name as given), so it can be
    trusted to confirm it. }
  FpMkdir(PChar(RootDir + '/a\b'), &755);
  if not DirectoryExists(RootDir + '/a\b') then
    Writeln('skip: a directory named with a backslash (this platform would not make one)')
  else
  begin
    { The kernel sees ONE component, so two ".." leave the root. }
    Report(not SandboxAllows(RootDir + '/a\b/../../ESCAPED.txt', puWrite),
           'a component whose NAME holds a backslash is one component, not two');
    Report(not SandboxAllows(RootDir + '/a\b/../../secret.txt', puRead),
           'and a read through that shape does not leak either');
    Report(RealPathOf(RootDir + '/a\b/../../ESCAPED.txt') <>
           RealPathOf(RootDir + PathDelim + 'ESCAPED.txt'),
           'because the walk no longer resolves it to a path inside the root');
    { THE MIRROR, POSIX side: ONE ".." after that same name stays in the root and
      must still be ordinary work. }
    Report(SandboxAllows(RootDir + '/a\b/../ok3.txt', puWrite),
           'while ONE ".." after it is still inside the root, and allowed');
    Report(not IsPerilousPath(RootDir + '/a\b'),
           'and a directory whose name holds a backslash is not perilous');
    { ... but a name with a backslash that CLIMBS TO THE ROOT OF THE FILESYSTEM is,
      which the gate could not see while it was declining to resolve such names. }
    Report(IsPerilousPath(RootDir + '/a\b/../../../../../../../../../../../..'),
           'though one that climbs all the way to "/" is');
    FpRmdir(PChar(RootDir + '/a\b'));   // the syscall again, for the same reason
  end;
  {$ENDIF}
  SetSandboxRoot('');
  RemoveDir(RootDir + PathDelim + 'a' + PathDelim + 'b');
  RemoveDir(RootDir + PathDelim + 'a');

  { (f) AN ENTRY THAT EXISTS, CARRIES A REPARSE TAG, AND GOES NOWHERE ELSE.
    FPC decodes exactly two reparse tags (rtl/win/sysutils.pp:468-499,
    IO_REPARSE_TAG_MOUNT_POINT and IO_REPARSE_TAG_SYMLINK); for every other tag
    it answers slrNoSymLink, which the same RTL turns into "the entry exists"
    at :558-565. A Store app alias, a WOF-compressed file, a dehydrated OneDrive
    placeholder are all of that kind, and the kernel opens exactly the path the
    walk resolved -- there is nothing to guard against. Calling them unknown
    refused reading, writing and deleting perfectly ordinary files: measured at
    42 of the 62 entries in %LOCALAPPDATA%\Microsoft\WindowsApps.

    Nothing here is created: the probe LOOKS for such an entry on the machine and
    says so when it finds none. Every call is a query. }
  {$IFDEF WINDOWS}
  wapps := GetEnvironmentVariable('LOCALAPPDATA') + '\Microsoft\WindowsApps';
  odd := '';
  if DirectoryExists(wapps) then
    if FindFirst(wapps + '\*', faAnyFile, wsr) = 0 then
    begin
      repeat
        if (wsr.Name <> '.') and (wsr.Name <> '..') and (odd = '') and
           ((FileGetAttr(wapps + '\' + wsr.Name) and $400) <> 0) and
           FileExists(wapps + '\' + wsr.Name) and
           not Decodable(wapps + '\' + wsr.Name) then
          odd := wapps + '\' + wsr.Name;
      until FindNext(wsr) <> 0;
      FindClose(wsr);
    end;
  if odd = '' then
    Writeln('skip: no undecodable reparse point on this machine to ask about')
  else
  begin
    SetSandboxRoot(wapps);
    Report(SandboxAllows(odd, puRead),
           'an ordinary file carrying a tag FPC cannot decode is still readable');
    Report(SandboxAllows(odd, puWrite),
           'and writable, because the kernel opens the path the walk resolved');
    Report(not IsPerilousPath(odd), 'and it is not a volume root');
    Report(SameText(RealPathOf(odd), odd),
           'and the walk answered it unchanged, which is what the kernel does');
    SetSandboxRoot('');
  end;
  {$ENDIF}

  { (g) A ROOT REACHED THROUGH A LINK THE PLATFORM WILL NOT FOLLOW.
    The containment rule carries a written carve-out for this -- a link at or
    above the root is shared by both sides of the comparison, so refusing there
    would kill every write in a sandbox rooted under a volume mount point. The
    perilous rule runs FIRST and had no such carve-out, so it did exactly what
    that comment forbids.

    The link is a drive-root one again, and the root aimed through it is a
    directory THAT ALREADY EXISTS -- asserted on the line before, so
    SetSandboxRoot's ForceDirectories branch is never reached and nothing is
    created through it. Queries only; the link is pulled and its target checked. }
  if not PlantLink(OutDir + PathDelim + 'volgate',
                   {$IFDEF WINDOWS}'C:\'{$ELSE}'/'{$ENDIF}) then
    Writeln('skip: volume-root link for the root-under-a-mount-point case')
  else
  begin
    thru := OutDir + PathDelim + 'volgate' +
            Copy(RootDir, Length(ExtractFileDrive(RootDir)) + 1, Length(RootDir));
    if not DirectoryExists(thru) then
      Writeln('skip: the root is not reachable through that link on this machine')
    else
    begin
      SetSandboxRoot(thru);
      volPeril := IsPerilousPath(thru);
      volWrite := SandboxAllows(thru, puWrite);
      volSub := SandboxAllows(thru + PathDelim + 'inner', puWrite);
      SetSandboxRoot('');
      Report(not volPeril,
             'a root reached THROUGH an unfollowable link is not itself perilous');
      Report(volWrite, 'and the host may still write in the cage it installed');
      Report(volSub, 'including a directory that already exists inside it');
    end;
    PullLink(OutDir + PathDelim + 'volgate');
    Report(FileGetAttr(OutDir + PathDelim + 'volgate') = -1,
           'and that link is gone again too');
    Report(DirectoryExists({$IFDEF WINDOWS}'C:\'{$ELSE}'/'{$ENDIF}),
           'with the volume it named untouched');
  end;

  { (h) THE ROOT IS RESOLVED BY THE SAME RULE AS EVERY PATH JUDGED AGAINST IT.
    SetSandboxRoot used to make the root absolute with ExpandFileName -- the very
    textual '..'-collapse the walk was rebuilt to stop doing. An operator root
    spelled '<D>/lnk/..', where lnk points at '<D>/deep/jt', therefore installed
    '<D>' while every path was compared against it by a walk that says
    '<D>/deep': a cage one level WIDER than the operator named. }
  ForceDirectories(OutDir + PathDelim + 'deep' + PathDelim + 'jt');
  ForceDirectories(OutDir + PathDelim + 'sibling');
  if not PlantLink(OutDir + PathDelim + 'rolnk',
                   OutDir + PathDelim + 'deep' + PathDelim + 'jt') then
    Writeln('skip: link for the root-resolution-order case')
  else
  begin
    thru := OutDir + PathDelim + 'rolnk' + PathDelim + '..';
    Report(SameText(SetSandboxRoot(thru), RealPathOf(thru)),
           'the root installed is the one the walk answers, not the collapsed one');
    Report(not SandboxAllows(OutDir + PathDelim + 'sibling' + PathDelim + 'x.txt',
                             puWrite),
           'so a sibling of the link''s TARGET is outside the cage, as named');
    Report(SandboxAllows(OutDir + PathDelim + 'deep' + PathDelim + 'jt' +
                         PathDelim + 'x.txt', puWrite),
           'while the directory the operator did name is inside it');
    SetSandboxRoot('');
    PullLink(OutDir + PathDelim + 'rolnk');
    Report(DirectoryExists(OutDir + PathDelim + 'deep' + PathDelim + 'jt'),
           'and pulling that link left its target standing');
  end;

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

  { --- MORE COMPONENTS THAN THE WALK CAN HOLD ---------------------------------
    The resolver splits a path into a fixed array and used to DROP whatever did
    not fit, in silence -- so a path long enough resolved to a PREFIX of itself,
    the gate judged an ancestor of the file the kernel would open, and a '..' in
    the part that was dropped could climb anywhere. Same divergence as a NUL,
    further along the string. What cannot be judged is refused; what merely goes
    deep is not. }
  seg := PathDelim;
  seg := seg + 'd';
  deep := RealPathOf(RootDir);
  for i := 1 to 200 do deep := deep + seg;
  Report(SandboxAllows(deep + PathDelim + 'leaf.txt', puWrite),
         'a path 200 components deep inside the root is allowed');
  for i := 1 to 200 do deep := deep + seg;
  Report(not SandboxAllows(deep + PathDelim + 'leaf.txt', puWrite),
         'while one the walk cannot hold whole is refused rather than guessed at');

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
  RemoveDir(OutDir + PathDelim + 'sibling');
  RemoveDir(OutDir + PathDelim + 'deep' + PathDelim + 'jt');
  RemoveDir(OutDir + PathDelim + 'deep');
  RemoveDir(OutDir);
  DeleteFile(RootDir + PathDelim + 'inside.txt');
  DeleteFile(RootDir + PathDelim + 'ok.txt');
  RemoveDir(RootDir + PathDelim + 'inner');

  Sink.Free;

  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed > 0 then Halt(1) else Halt(0);
end.
