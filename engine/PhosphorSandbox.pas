{******************************************************************************
  Phosphor BASIC -- the filesystem sandbox (the fourth execution ceiling)

  MIT License. Copyright (c) 2026 Andre Murta.

  Phase 3 gave a host three ceilings for running a script it does not trust --
  MaxSteps, TimeoutMs, MaxOutputBytes. All three bound how LONG a script runs.
  None of them bounded WHERE it writes, so an embedder who set all three still
  handed the script the whole filesystem. This unit is the missing one.

  Two rules, and the first applies even with no sandbox set:

    1. A PERILOUS PATH is never written to or deleted. An empty string is the one
       that costs a disk: IncludeTrailingPathDelimiter('') answers the path
       delimiter, so a tree walk starting at '' starts at the ROOT OF THE CURRENT
       DRIVE. A bare root ('/', 'C:\', a UNC share) is refused for the same
       reason -- neither is a directory a program meant to name, and a program
       that computed one has a bug this must not carry out for it. The rule is on
       the DIRECTORY, not on the string that spells it: 'C:\.', 'C:\dir\..' and
       '.' from a working directory that is a root are the drive root too, and
       are refused with it. Reads are not refused: listing a drive root destroys
       nothing.

    2. WITH A ROOT SET, every path -- read, write or delete -- must resolve
       inside it. Resolution expands '.' and '..' and follows symlinks, so
       neither '..\..\..' nor a link planted inside the root escapes.

  BOTH RULES JUDGE THE PATH THE KERNEL WILL OPEN, NOT THE STRING AS WRITTEN, and
  four ways those two came apart have now been paid for:

    - a NUL byte. The gate read the whole string; CreateFileW and fpOpen stop at
      the first #0. '<outside>.txt' + #0 + '/../cage/x' was judged inside the
      root and opened outside it -- read, write and delete alike.
    - a '..' after a symlink, on Linux. Expansion collapsed it textually before
      any link was followed; path_resolution(7) applies it to the LINK TARGET's
      directory. '<root>/link/..' left the root while the gate said it had not.
      (Win32 collapses lexically too, which is why no Windows suite could see it.)
    - a BACKSLASH INSIDE A POSIX NAME. The RTL treats one as a separator on Unix
      (rtl/unix/sysunixh.inc:35) and the kernel does not, so a directory named
      'a\b' was two components to the gate and one to Linux, and every '..' after
      it was applied at the wrong depth. Same escape as the one above, arriving
      through the splitter instead of through the order -- and it survived the
      fix for that one, which is the whole reason this list is four items long
      rather than three: the class is "the gate and the kernel were handed the
      same string and read it differently", and each instance is only an instance.
    - a directory junction whose target is a drive root, on Windows. Neither
      expansion nor FPC's FileGetSymLinkTarget will name it, so the guard in
      front of the recursive remover measured "a directory called rootlink".

  So a path this unit cannot resolve to ONE directory is refused, not assumed to
  be an ordinary one. Unable to say is not permission -- but it is not licence to
  refuse either: an entry the platform resolves to the very path the walk already
  built (a Store app alias, a compressed or cloud-backed file, any reparse tag FPC
  declines to decode) is ORDINARY, and refusing to read it was this unit's own
  first over-refusal.

  The root is set by the HOST (TPhosphorEngine.SandboxRoot) and no registered
  function can change it, so a script cannot widen its own cage; sandboxroot$()
  only reports it. It is process-wide, not per-VM, because a library function is
  a plain callback with no VM to ask -- documented in docs/embedding.md rather
  than hidden.

  When a root is set the platform's scratch directories answer INSIDE it
  (temppath$, tempfilename$, homepath$, documentspath$), so a script that uses
  them keeps working and stays contained instead of being refused.
******************************************************************************}
unit PhosphorSandbox;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils;

type
  { What a call intends to do with the path. A read is refused only by the root;
    a write or a delete is refused by the perilous-path rule as well. }
  TPathUse = (puRead, puWrite, puDelete);

{ True for a path no destructive call may ever be handed, sandbox or no sandbox. }
function IsPerilousPath(const APath: String): Boolean;

{ The active root, '' when there is none. Always absolute, no trailing delimiter. }
function SandboxRoot: String;
function SandboxActive: Boolean;

{ Set (or clear, with '') the root. The directory is created if it does not
  exist, then resolved through symlinks, so later comparisons are against the
  real path. Answers the root actually installed -- '' if it could not be. }
function SetSandboxRoot(const APath: String): String;

{ The gate every filesystem-touching library function asks before acting. }
function SandboxAllows(const APath: String; AUse: TPathUse): Boolean;

{ A scratch directory inside the root, created on demand; '' when no root is
  set, in which case a caller uses the platform's own. }
function SandboxScratchPath: String;

{ Resolve to an absolute real path, IN ONE LEFT-TO-RIGHT WALK: each component's
  links are followed before the next component is applied, so a '..' comes off
  what the link resolved to and not off the spelling. Public because the sandbox
  probe asserts on it.

  It answers the path alone, which is all a caller outside this unit can use. The
  gate needs more than that -- whether the walk could resolve the path at all --
  and asks Resolve, which this is a wrapper over. }
function RealPathOf(const APath: String): String;

implementation

type
  { WHAT RESOLVING A PATH ANSWERED -- and how much of that answer is knowledge.

    A gate cannot act on the resolved path alone, because the two ways resolution
    can fall short are the two ways a script gets out:

      Path       the resolved absolute path: '.' and '..' applied in order,
                 links followed on every component that exists
      UnknownAt  '' when every component resolved. Otherwise the link the
                 platform would not name -- a Windows junction whose target is a
                 bare drive root is exactly this -- given as the path OF the link,
                 so a caller can ask where it sits relative to the root.
      Truncated  the path had more components than the walk can hold, so Path is
                 a PREFIX of what the kernel would open. That used to be dropped
                 in silence, which is the NUL divergence one order of magnitude
                 further along. }
  TResolution = record
    Path: String;
    UnknownAt: String;
    Truncated: Boolean;
  end;

{ Declared here because rule 1 needs it and is written first: the perilous rule
  reads best beside the history that shaped it. }
function Resolve(const APath: String): TResolution; forward;

var
  GRoot: String = '';   // '' = no sandbox; the process-wide setting

// --- rule 1: the paths a destructive call must never be handed ---------------
{ THE RULE IS STRUCTURAL, NOT TEXTUAL, AND IT TOOK THREE SPELLINGS TO LEARN IT.

  It began as a test on the raw string, and each time a new way of WRITING a
  drive root got through, the string test grew one more case. "C:/" got through
  because ExcludeTrailingPathDelimiter strips PathDelim and on Windows that is
  the backslash alone; "C:\\" got through because it strips exactly one; a UNC
  share root got through because the test counted separators wrongly. Three
  fixes, all the same shape -- one more pattern -- and so the next spelling got
  through as well. It did, and there were more of it than of all the others put
  together: "C:\.", "C:\dir\..", "C:\a\b\..\..", "\.", "\\server\share\..",
  "\\?\C:\.." and "." from a working directory that IS a root all name a drive
  or a share root, none of them LOOKS like one, and every one of them was handed
  to the recursive remover.

  Text cannot win that argument, because the number of ways to write a directory
  is unbounded. What is bounded is the directory. So the path is RESOLVED first
  and the test is then structural: with the dot segments collapsed, is what
  remains nothing but a volume -- a drive, a share, a server -- with no directory
  under it? "C:\a\b\..\.." and "C:\" get the same answer because they are the
  same place, and a spelling nobody has thought of yet gets that answer too.

  WHY ExpandFileName AND NOT RealPathOf, which this unit also owns. Read the RTL
  (rtl/objpas/sysutils/fina.inc, rtl/inc/fexpand.inc): ExpandFileName is
  DoDirSeparators plus FExpand, and FExpand is string arithmetic over ONE query
  of the process's own current directory (GetDirIO -> GetDir). It stats nothing,
  opens nothing, creates nothing. IsPerilousPath therefore stays a question that
  can be asked of any string without a filesystem anywhere near it -- which is
  the entire technique this project uses to test a guard standing in front of a
  recursive delete, and is not a property to trade away. Neither of the two tests
  below stats anything, and both may still be asked of any string.

  WHY THE TEXT TEST IS KEPT AS WELL, rather than replaced. ExpandFileName('C:')
  answers the current directory ON drive C:, not the root of it -- a bare drive
  letter is the one spelling that resolution makes LESS suspicious, and it is
  perilous. So the two are OR-ed: the text test refuses a string that names a
  volume and no directory in it, the structural test refuses every string that
  leads to one.

  AND WHY THERE IS NOW A THIRD, WHICH DOES TOUCH THE FILESYSTEM. This comment
  used to end by saying RealPathOf "would answer no differently, because
  FollowLinks returns a path unchanged when it is not a link". That sentence is
  exactly right about a path that is NOT a link and exactly wrong about the only
  case that matters: `mklink /J rootlink C:\` needs no privilege, makes a
  directory that IS the drive root, and both tests above call it an ordinary
  folder called rootlink. Neither text nor expansion can see through an entry
  that names another directory -- only the filesystem knows -- so the third test
  (IsDirectoryEntry plus ResolutionIsAVolumeRoot) asks it. It runs LAST, only when
  both cheap tests said no, and it stops at one FileGetAttr for anything that is
  not an existing directory, which is every ordinary write. The two pure tests
  keep their property; the third pays for what they cannot know. }

{ THE ONE SEPARATOR QUESTION, AND IT IS THE KERNEL'S. On Windows both slashes
  separate; on POSIX a backslash is an ordinary filename byte and nothing else.

  There used to be a second question -- an IsAnySep that answered "both" on both
  platforms -- and the resolution walk asked that one, on the grounds that
  rtl/unix/sysunixh.inc:35 declares AllowDirectorySeparators as ['\','/'] on Unix
  too, so ExpandFileName had always behaved that way there. Keeping the RTL's
  behaviour was the wrong goal: the gate is not measuring what ExpandFileName
  would say, it is measuring what the KERNEL will open, and Linux opens
  'a\b' as one directory. So the gate counted two components where the kernel
  counted one, and every '..' after it was applied at a different depth:

      mkdir '<root>/a\b'            (no privilege; a script can do it)
      file_writealltext('<root>/a\b/../../ESCAPED.txt', ...)

  gate: [root, a, b, .., ..] -> pops b, a -> still <root> -> INSIDE, allowed.
  kernel: 'a\b' is ONE directory, so the two '..' climb to the root's PARENT.
  Measured on the Linux VM through the real host: the byte landed outside the
  cage, and a read of the same shape leaked a file from outside it. Exactly the
  divergence the '..'-after-a-symlink fix closed, arriving through the splitter
  instead of through the order. One question, the kernel's answer. }
function IsPathSep(const AChar: Char): Boolean;
begin
  {$IFDEF WINDOWS}
  Result := (AChar = '\') or (AChar = '/');
  {$ELSE}
  Result := (AChar = '/');
  {$ENDIF}
end;

{ EVERY trailing separator, in every spelling -- not the one PathDelim that
  ExcludeTrailingPathDelimiter removes. Used on both sides of every comparison
  below, because ExpandFileName('C:\\') answers 'C:\\' (the doubled separator at
  a root is not collapsed) while ExtractFileDrive('\\server\') answers
  '\\server\' WITH its trailing separator: raw, those two would not match. }
function ChopTrailingSeps(const APath: String): String;
begin
  Result := APath;
  while (Length(Result) > 0) and IsPathSep(Result[Length(Result)]) do
    Delete(Result, Length(Result), 1);
end;

{ ONE COMPONENT OFF, AND JOINING ONE ON -- with the kernel's separator, which is
  why neither is ExtractFilePath nor IncludeTrailingPathDelimiter.

  Both of those read AllowDirectorySeparators, and rtl/unix/sysunixh.inc:35
  declares it ['\','/'] on Unix as well. So ExtractFilePath('/x/a\b') cuts at the
  BACKSLASH and answers '/x/a\', and popping a '..' off '<root>/a\b' landed on
  '<root>/a' instead of on '<root>'. That is the splitter defect a second time,
  in the routine that applies the '..' rather than the one that finds it -- and it
  was not caught by reading, it was caught by the POSIX assertion in
  tests/probe_sandbox.lpr failing WITH the splitter already fixed. }
function ParentOf(const APath: String): String;
var
  i: Integer;
begin
  Result := ChopTrailingSeps(APath);
  i := Length(Result);
  while (i > 0) and not IsPathSep(Result[i]) do Dec(i);
  if i = 0 then Exit('');
  Result := ChopTrailingSeps(Copy(Result, 1, i - 1));
end;

function JoinPath(const ADir, AName: String): String;
begin
  Result := ChopTrailingSeps(ADir) + PathDelim + AName;
end;

{$IFDEF WINDOWS}
{ The extended and device prefixes spell the same volumes differently: "\\?\C:\"
  IS "C:\", and "\\?\UNC\srv\shr" IS "\\srv\shr". ExtractFileDrive knows neither,
  and reports the volume of "\\?\UNC\srv\shr" as "\\?\UNC" -- so a share root
  read as a folder two levels inside one. Rewritten to the plain spelling before
  the volume is measured, because the point of this rule is that the same
  directory gets the same answer however it is written. }
function UnprefixDevice(const APath: String): String;
begin
  Result := APath;
  if SameText(Copy(Result, 1, 8), '\\?\UNC\') then
    Result := '\\' + Copy(Result, 9, Length(Result))
  else if ((Copy(Result, 1, 4) = '\\?\') or (Copy(Result, 1, 4) = '\\.\')) and
          (Length(Result) >= 6) and (Result[6] = ':') then
    Result := Copy(Result, 5, Length(Result));
end;
{$ENDIF}

{ A volume named with no directory in it: '', a bare separator, 'C:', a UNC
  server or share root. This is the old textual rule, and it is kept for exactly
  what resolution cannot see -- see the header comment on 'C:'. }
function NamesAVolumeOnly(const APath: String): Boolean;
var
  p: String;
  {$IFDEF WINDOWS}
  q: String;
  i, n: Integer;
  {$ENDIF}
begin
  p := Trim(APath);
  if p = '' then Exit(True);                       // '' -> the drive root
  {$IFDEF WINDOWS}
  { Both spellings, everywhere: the separator is normalised BEFORE anything is
    measured, so the rest of this function sees one form. }
  p := StringReplace(p, '/', '\', [rfReplaceAll]);
  {$ENDIF}
  p := ChopTrailingSeps(p);
  if p = '' then Exit(True);                       // '/' or '\' alone
  {$IFDEF WINDOWS}
  // 'C:', 'C:\', 'C:/' and 'C://' all reduce to two characters here
  if (Length(p) = 2) and (p[2] = ':') then Exit(True);
  { A UNC root, in either spelling: \\server and \\server\share alike. Two
    components after the slashes is still a root; three is a folder inside one. }
  if (Length(p) > 2) and (p[1] = '\') and (p[2] = '\') then
  begin
    q := Copy(p, 3, Length(p));
    n := 0;
    for i := 1 to Length(q) do
      if q[i] = '\' then Inc(n);
    if n <= 1 then Exit(True);
  end;
  {$ENDIF}
  Result := False;
end;

{ Resolve, then ask the structural question: is the whole of what is left the
  volume itself? }
function ResolvesToAVolumeRoot(const APath: String): Boolean;
var
  s: String;
  {$IFDEF WINDOWS}
  d: String;
  {$ENDIF}
begin
{$IFNDEF WINDOWS}
  { A BACKSLASH IS AN ORDINARY POSIX FILENAME CHARACTER, and IsPathSep says so --
    but ExpandFileName does not. It calls DoDirSeparators, which reads
    AllowDirectorySeparators, and rtl/unix/sysunixh.inc:35 declares that
    ['\','/'] on Unix TOO. So resolving a path containing a backslash
    mangles it, and every arrangement of backslashes and dots that reduces to '/'
    would be called a root: a file literally named '\' became unwritable, measured
    at 1 deviation in a 90-assertion POSIX sweep.

    The check that follows resolves, so it is the check that must decline. A name
    with a backslash in it cannot BE a POSIX root -- a root is '/' -- so answering
    False here loses nothing. The Windows arm is unaffected, where a backslash
    genuinely is a separator. }
  if Pos('\', APath) > 0 then Exit(False);
{$ENDIF}
  s := ChopTrailingSeps(ExpandFileName(APath));
  if s = '' then Exit(True);      // '/' where there are no drives to name
  {$IFDEF WINDOWS}
  s := ChopTrailingSeps(UnprefixDevice(s));
  if s = '' then Exit(True);
  // ExtractFileDrive answers 'C:', '\\server\share' or '\\server'. When that is
  // the ENTIRE path, the path is a root and nothing else.
  d := ChopTrailingSeps(ExtractFileDrive(s));
  if (d <> '') and SameText(d, s) then Exit(True);
  {$ENDIF}
  Result := False;
end;

{ The third question, and the one neither text nor expansion can answer: WHERE
  DOES THIS DIRECTORY ACTUALLY GO?

  A junction or a symlink is not a spelling of a path -- it is an entry that
  names another directory. `mklink /J rootlink "C:\"` requires no privilege, and
  it makes a directory that IS the drive root while spelling itself "rootlink".
  ExpandFileName leaves it alone, so both tests above call it ordinary, and the
  recursive remover then walks Windows straight through it into C:\.

  RealPathOf DOES NOT SAVE IT ON WINDOWS, and that was measured rather than
  assumed: FPC's FileGetSymLinkTargetInt (rtl/win/sysutils.pp:422-510) reads the
  mount point's target '\??\C:\' as 'C:\' and then validates it with
  FindFirstFileExW, which fails on a bare drive root -- so the target is discarded
  and the function reports "not a link". POSIX has the same shape in a symlink to
  '/', where readlink does answer, and resolution alone is enough.

  Hence two questions rather than one:
    - once links ARE followed, is what is left a volume root? (the POSIX case)
    - did the walk stop ON THIS DIRECTORY without being able to name it -- a link
      the platform will not follow -- or fail to hold the path at all? Then this
      unit cannot say which directory this is, and a guard standing in front of a
      recursive remover answers what it cannot name the way it answers a root.

  ON THIS DIRECTORY, AND NOT MERELY SOMEWHERE ABOVE IT. The first spelling of this
  test refused whenever the walk reported an unfollowable link ANYWHERE in the
  path, and SandboxAllows below carries a carefully written carve-out saying why
  that must not happen -- a root installed under a volume mount point is reached
  THROUGH such a link, so refusing there kills every write the sandbox was
  installed to permit. The carve-out was in the containment rule only, and this
  rule runs first, so it did exactly what that comment forbids: measured with a
  root at '<junction to C:\>\Users\...\cage', the root itself and every existing
  directory in it came back perilous, and dir_create, dir_delete and every write
  naming a directory were refused inside a cage the host had just installed. When
  the walk stops on the LAST component, Path and UnknownAt are the same string;
  when it stopped higher up, Path is longer. That is the whole distinction.

  THE COST IS PAID ONCE AND ONLY WHERE IT CAN MATTER. A file is not a volume
  root, and a path that does not exist yet carries no reparse point, so an
  ordinary write stops at the one FileGetAttr in IsDirectoryEntry -- and the walk
  itself is paid for ONCE per gate call, because SandboxAllows hands its own
  resolution to ResolutionIsAVolumeRoot instead of making it resolve again. }

{ THE FILTER IS FileGetAttr AND NOT DirectoryExists, and the difference is the
  whole case: DirectoryExists answers FALSE for a junction to a bare drive root
  (measured -- see IsLinkEntry and FollowLinks), which is the one directory this
  test exists to catch. FileGetAttr describes the entry itself, so the reparse
  point still reports as a directory. -1 is "not there": a path that does not
  exist yet is not a volume root, and neither is a plain file, so an ordinary
  write stops here on one call and never pays for a walk. }
function IsDirectoryEntry(const APath: String): Boolean;
var
  a: LongInt;
begin
  a := FileGetAttr(APath);
  Result := (a <> -1) and ((a and faDirectory) <> 0);
end;

{ The structural half, given a resolution the caller has already paid for. }
function ResolutionIsAVolumeRoot(const ARes: TResolution): Boolean;
begin
  if ARes.Truncated then Exit(True);
  if (ARes.UnknownAt <> '') and (ARes.UnknownAt = ARes.Path) then Exit(True);
  Result := NamesAVolumeOnly(ARes.Path) or ResolvesToAVolumeRoot(ARes.Path);
end;

{ The cheap half of the rule: the two string tests, over a string already
  trimmed. Neither touches a disk, so both callers keep answering the easy
  spellings without one. }
function PerilousByString(const ATrimmed: String): Boolean;
begin
  if ATrimmed = '' then Exit(True);
  Result := NamesAVolumeOnly(ATrimmed) or ResolvesToAVolumeRoot(ATrimmed);
end;

function IsPerilousPath(const APath: String): Boolean;
var
  p: String;
begin
  { A NUL ENDS THE PATH FOR THE KERNEL AND NOT FOR THIS UNIT. FPC hands a string
    to CreateFileW/fpOpen as a PChar and both stop at the first #0, while every
    test here reads the whole of it -- so 'C:\' + #0 + 'x' was measured as an
    ordinary directory named x, and the drive root went through the guard that
    exists to refuse it. Trim is no help: #0 <= ' ', so it strips one only at the
    ends, and 'C:\' + #0 was already refused while 'C:\' + #0 + 'x' was not.
    No caller can mean a name with a NUL in it, so this refuses rather than guess
    where to cut. }
  if Pos(#0, APath) > 0 then Exit(True);
  { Trimmed once, here, so both tests judge the same string: "C:\ " with a
    trailing space is the drive root, and only Trim makes it look like one. }
  p := Trim(APath);
  if PerilousByString(p) then Exit(True);
  if not IsDirectoryEntry(p) then Exit(False);
  Result := ResolutionIsAVolumeRoot(Resolve(p));
end;

// --- resolution --------------------------------------------------------------
{ Split the part of a path after the drive/root into its components, KEEPING the
  '.' and '..' segments -- applying those is the walk's job, and the ORDER it does
  it in is the whole of the symlink escape below. WHAT COUNTS AS A SEPARATOR is
  the other half of the same escape and is IsPathSep's to say, not this
  function's: it used to split on a backslash on POSIX as well, where the kernel
  does not, and that alone let a '..' be counted against the wrong depth. Written
  with Copy rather than character concatenation: under the UTF8 codepage directive
  this unit compiles with, appending a Char to a String re-encodes it and destroys
  every byte >= 128.

  ATRUNCATED SAYS THE PATH DID NOT FIT. It used to be dropped in silence: a path
  with more components than AParts holds resolved to a PREFIX of itself, so the
  gate judged an ancestor of the file the kernel would open -- and a '..' in the
  part that was dropped could climb anywhere. Same divergence as a NUL, further
  along the string. Nothing can be judged from a truncated walk, so it is
  reported and the callers refuse. }
procedure SplitComponents(const ARest: String; var AParts: array of String;
                          out ACount: Integer; out ATruncated: Boolean);
var
  i, start: Integer;
begin
  ACount := 0;
  ATruncated := False;
  start := 1;
  for i := 1 to Length(ARest) + 1 do
    if (i > Length(ARest)) or IsPathSep(ARest[i]) then
    begin
      if i > start then
      begin
        if ACount <= High(AParts) then
        begin
          AParts[ACount] := Copy(ARest, start, i - start);
          Inc(ACount);
        end
        else
          ATruncated := True;
      end;
      start := i + 1;
    end;
end;

{ Rooted, without the LCL's FilenameIsAbsolute -- the engine may not reach FileUtil.
  Asked of a symlink's TARGET, so it takes the kernel's separator too: a POSIX
  target spelled '\foo' is a relative name, not the absolute '/foo' that reading
  a backslash as a separator turned it into. }
function IsRootedPath(const APath: String): Boolean;
begin
  if APath = '' then Exit(False);
  if IsPathSep(APath[1]) then Exit(True);
  Result := ExtractFileDrive(APath) <> '';
end;

{ IS THIS ENTRY A LINK -- a POSIX symlink, or ANY Windows reparse point, a
  directory junction included? The question is separate from "where does it go",
  and it has to be, because the case that got through is a link whose target the
  platform will not report.

  faSymLink is $400 in both worlds (rtl/objpas/sysutils/filutilh.inc:141; on
  Win32 that is FILE_ATTRIBUTE_REPARSE_POINT). FileGetAttr describes the LINK and
  not what it points at on both -- Unix through FpLStat
  (rtl/unix/sysutils.pp:1067, and LinuxToWinAttr sets faSymLink at :629), Win32
  through GetFileAttributesW, which does not traverse a reparse point -- and
  answers -1 for a path that is not there. The constant is spelled out here
  rather than taken from SysUtils because faSymLink carries the `platform`
  modifier, and this project builds with -vewn. }
const
  ATTR_LINK = $00000400;

function IsLinkEntry(const APath: String): Boolean;
var
  a: LongInt;
begin
  a := FileGetAttr(APath);
  Result := (a <> -1) and ((a and ATTR_LINK) <> 0);
end;

{ Follow a symlink chain, bounded. Answers the path unchanged when it is not a
  link, so a failure here can only make the check STRICTER, never looser -- but
  "unchanged" is also what it used to answer for a link it could not FOLLOW, and
  a caller cannot tell those apart. That is the whole of the drive-root junction
  escape, so the two are now told apart: AUnknown is set to the path of the link
  that stopped the walk, and left alone otherwise. }
function FollowLinks(const APath: String; var AHops: Integer;
                     var AUnknown: String): String;
var
  target: RawByteString;   // the signature FileGetSymLinkTarget takes by var
  t: String;
begin
  Result := APath;
  while AHops < 40 do
  begin
    if not (FileExists(Result) or DirectoryExists(Result)) then
    begin
      { "NOTHING IS HERE" AND "A DOOR IS HERE THAT NOBODY CAN OPEN" ARRIVED AS THE
        SAME ANSWER, and the walk carried the path on unchanged for both.
        Measured: for `mklink /J rootlink "C:\"`, GetFileAttributesW reports $410
        -- directory AND reparse point -- while FileExists and DirectoryExists
        both answer False, because the RTL resolves the link and fails to stat a
        bare drive root. FileGetAttr describes the LINK, so it can tell the two
        apart. (The existence test is what keeps FileGetSymLinkTarget out of
        reach here: it RAISES EDirectoryNotFoundException on a target it cannot
        stat -- rtl/win/sysutils.pp:490, rtl/unix/sysutils.pp:649 -- which is
        precisely this case and a dangling symlink.) }
      if (AUnknown = '') and IsLinkEntry(Result) then AUnknown := Result;
      Exit;
    end;
    target := '';
    if (not FileGetSymLinkTarget(RawByteString(Result), target)) or (target = '') then
    begin
      { IT IS THERE AND FPC WILL NOT NAME A TARGET FOR IT. That reads like the
        branch above, and it is not, which cost this guard an over-refusal:

        This branch is only reached when FileExists or DirectoryExists ALREADY
        said the entry is there, and read the RTL for what that means when a
        reparse point is involved. FileGetSymLinkTargetInt
        (rtl/win/sysutils.pp:468-499) decodes exactly two tags,
        IO_REPARSE_TAG_MOUNT_POINT and IO_REPARSE_TAG_SYMLINK; for every other
        tag it leaves TargetName empty and answers slrNoSymLink. FileOrDirExists
        (rtl/win/sysutils.pp:558-565) turns that same slrNoSymLink into "the entry
        exists". So the entries that arrive here carrying $400 are the tags the
        platform resolves to THIS path and no other -- a Store app alias, a
        WOF-compressed file, a dehydrated OneDrive placeholder, a dedup stub.
        There is no divergence to guard against: the kernel opens exactly the path
        the walk has already built. Calling them unknown refused reading, writing
        and deleting perfectly ordinary files -- measured on eight of the ten
        entries in %LOCALAPPDATA%\Microsoft\WindowsApps.

        The link this walk cannot follow -- a junction to a bare drive root, a
        dangling one -- never reaches here: the RTL fails to stat its target, so
        FileExists and DirectoryExists both answer False and the branch above
        catches it. Unable to say is not permission; this is not a case of being
        unable to say. }
      Exit;
    end;
    Inc(AHops);
    t := String(target);
    if not IsRootedPath(t) then
      t := JoinPath(ParentOf(Result), t);
    Result := ChopTrailingSeps(ExpandFileName(t));
  end;
  { Forty hops and still a link: nobody meant a chain that deep, and where it
    ends is not known. }
  if AUnknown = '' then AUnknown := Result;
end;

{ ABSOLUTE, WITH EVERY '.' AND '..' STILL IN PLACE.

  ExpandFileName cannot be used for this, and that is the defect the walk below
  was rebuilt around. FExpand (rtl/inc/fexpand.inc) is string arithmetic: it
  collapses '..' before anything has looked at the disk. The Linux kernel does the
  opposite -- path_resolution(7) resolves a symlink and applies the REST of the
  path, '..' included, to the target's directory -- so '<root>/link/..' left the
  sandbox while the gate, judging the collapsed spelling, said it had not.

  ExpandFileName is still asked for the two anchors only IT knows, neither of
  which has a dot segment to lose: the process's own current directory, and the
  current directory ON a named drive for the Windows 'C:foo' spelling. }
function AnchorAbsolute(const APath: String): String;
{$IFDEF WINDOWS}
var
  d: String;
{$ENDIF}
begin
  Result := APath;
  if Result = '' then Exit(GetCurrentDir);
  {$IFDEF WINDOWS}
  d := ExtractFileDrive(Result);
  if d <> '' then
  begin
    // 'C:\x', '\\server\share\x', '\\?\C:\x' are anchored on their own volume.
    if (Length(Result) > Length(d)) and IsPathSep(Result[Length(d) + 1]) then Exit;
    // 'C:' and 'C:foo' are relative to the current directory ON drive C:, which
    // is a thing only the RTL can look up.
    if (Length(d) = 2) and (d[2] = ':') then
      Result := IncludeTrailingPathDelimiter(ExpandFileName(d)) +
                Copy(Result, Length(d) + 1, Length(Result));
    Exit;
  end;
  // '\x' is rooted, but on whichever drive the process is standing.
  if IsPathSep(Result[1]) then
    Exit(ChopTrailingSeps(ExtractFileDrive(GetCurrentDir)) + Result);
  {$ELSE}
  { '/x' is absolute. '\x' is NOT -- it is a relative name whose first byte is a
    backslash -- and asking IsPathSep rather than "either slash" is what says so. }
  if IsPathSep(Result[1]) then Exit;
  {$ENDIF}
  Result := JoinPath(GetCurrentDir, Result);
end;

{ ONE LEFT-TO-RIGHT WALK: for each component, follow the links in the prefix
  built so far and only then apply the component. '..' comes off the RESOLVED
  prefix, never off the textual one -- which is what the kernel does, and what
  expanding first did not. }
function Resolve(const APath: String): TResolution;
var
  full, rest, base, cand, vol: String;
  parts: array[0..255] of String;
  count, i, hops: Integer;
begin
  Result.Path := '';
  Result.UnknownAt := '';
  Result.Truncated := False;
  full := AnchorAbsolute(APath);           // absolute; dot segments UNTOUCHED
  base := ExtractFileDrive(full);          // 'C:' / '\\server\share' / '' on unix
  rest := Copy(full, Length(base) + 1, Length(full));
  SplitComponents(rest, parts, count, Result.Truncated);
  hops := 0;
  Result.Path := base + PathDelim;
  for i := 0 to count - 1 do
  begin
    if parts[i] = '.' then Continue;
    if parts[i] = '..' then
    begin
      { One component off the path the links have ALREADY been followed through.
        The volume is re-read from that path rather than taken from `base`,
        because a link may have moved the walk onto a different one; at the
        volume the climb stops, as it does on every filesystem. }
      vol := ExtractFileDrive(Result.Path);
      Result.Path := ParentOf(Result.Path);
      if Length(Result.Path) <= Length(vol) then Result.Path := vol + PathDelim;
      Continue;
    end;
    cand := JoinPath(Result.Path, parts[i]);
    // A link is replaced by its target, which may itself be a link; the target
    // is then the new prefix and the remaining components hang off it.
    Result.Path := ChopTrailingSeps(FollowLinks(cand, hops, Result.UnknownAt));
    if Result.Path = '' then Result.Path := base + PathDelim;
  end;
  Result.Path := ChopTrailingSeps(Result.Path);
  if Result.Path = '' then Result.Path := base + PathDelim;
end;

function RealPathOf(const APath: String): String;
begin
  Result := Resolve(APath).Path;
end;

// --- the root ----------------------------------------------------------------
function SandboxRoot: String;
begin
  Result := GRoot;
end;

function SandboxActive: Boolean;
begin
  Result := GRoot <> '';
end;

function SetSandboxRoot(const APath: String): String;
var
  p: String;
begin
  if Trim(APath) = '' then
  begin
    GRoot := '';
    Exit('');
  end;
  { BOTH SIDES OF THE CONTAINMENT TEST RESOLVE BY THE SAME RULE, and they did not.
    This line used to be ExcludeTrailingPathDelimiter(ExpandFileName(Trim(APath)))
    -- the very textual '..'-collapse the walk was rebuilt to stop doing, still
    being done to the ROOT while every path judged against it went through the
    walk. Measured on both OSes with an operator root of '<S>/lnk/..' where lnk
    points at '<S>/deep/jt': ExpandFileName answers '<S>', the walk answers
    '<S>/deep' -- what the kernel opens -- and the '<S>' one was installed, a cage
    one level WIDER than the operator named, with '<S>/sibling' inside it. So the
    root is resolved by the walk too, and Trim(APath) is handed to it whole: making
    it absolute is AnchorAbsolute's job now. }
  p := Trim(APath);
  // A root that does not exist yet is made, not refused: a host points at a
  // fresh scratch directory far more often than at an existing one.
  if not DirectoryExists(p) then
    if not ForceDirectories(p) then
    begin
      GRoot := '';
      Exit('');
    end;
  GRoot := RealPathOf(p);
  Result := GRoot;
end;

// --- the gate ----------------------------------------------------------------
{ Is AFull the root itself, or under it? The trailing delimiter matters: without
  it '/rootabc' would read as inside '/root'. }
function IsInsideRoot(const AFull: String): Boolean;
var
  r, f: String;
begin
  r := GRoot;
  f := ChopTrailingSeps(AFull);
  {$IFDEF WINDOWS}
  r := LowerCase(r);
  f := LowerCase(f);
  {$ENDIF}
  if f = r then Exit(True);
  Result := Copy(f, 1, Length(r) + 1) = r + PathDelim;
end;

{ Strictly UNDER the root: inside it, and not the root itself. The distinction
  matters in exactly one place -- a link the walk could not follow, in
  SandboxAllows -- and nowhere else. }
function IsBelowRoot(const AFull: String): Boolean;
var
  r, f: String;
begin
  r := GRoot;
  f := ChopTrailingSeps(AFull);
  {$IFDEF WINDOWS}
  r := LowerCase(r);
  f := LowerCase(f);
  {$ENDIF}
  Result := (f <> r) and (Copy(f, 1, Length(r) + 1) = r + PathDelim);
end;

function SandboxAllows(const APath: String; AUse: TPathUse): Boolean;
var
  r: TResolution;
  p: String;
  haveRes: Boolean;
begin
  { REFUSED BEFORE ANYTHING MEASURES IT, for both rules and for a read as well.
    Everything below reads the whole string; CreateFileW and fpOpen stop at the
    first #0. '<outside>.txt' + #0 + '/../cage/x' therefore resolved back inside
    the root here and opened outside it there, and read, write and delete of a
    single file all escaped that way. }
  if Pos(#0, APath) > 0 then Exit(False);
  p := Trim(APath);
  { THE PERILOUS RULE, INLINED FOR ITS PIECES RATHER THAN CALLED FOR ITS ANSWER --
    because calling IsPerilousPath meant walking the path twice, once there and
    once here, and each walk stats every component. Measured (minimum of four
    runs, this machine): a write naming an existing directory cost 2030 us and a
    delete of one 1987 us, against 788 and 776 before the walk existed; with the
    resolution shared they are 811 and 844. The pieces are the same three
    IsPerilousPath uses, in the same order, so there is still one definition of
    the rule; what is shared is the resolution. }
  haveRes := False;
  if AUse <> puRead then
  begin
    if PerilousByString(p) then Exit(False);
    if IsDirectoryEntry(p) then
    begin
      r := Resolve(p);
      { Reused below only when the two strings ARE the same one: the containment
        half judges the path as the caller wrote it, and Trim moved it. }
      haveRes := p = APath;
      if ResolutionIsAVolumeRoot(r) then Exit(False);
    end;
  end;
  if GRoot = '' then Exit(True);
  if p = '' then Exit(False);
  if not haveRes then r := Resolve(APath);
  { WHAT THE WALK COULD NOT RESOLVE, IT DOES NOT GET TO VOUCH FOR. Truncation
    means Path is a prefix of what the kernel opens. A link it could not follow
    means the directory could be anywhere -- and if that link sits BELOW the root,
    "anywhere" includes outside it, which is how a junction planted in the cage
    let a write through into C:\.

    A link at or ABOVE the root is not refused, and that is deliberate: the root's
    own resolution went through the same one, so both sides of the comparison
    already share it and containment is still decidable. Refusing there would
    kill every write in a sandbox whose root happens to sit under a volume mount
    point -- a guard that refuses the work it was installed to permit. }
  if r.Truncated then Exit(False);
  if (r.UnknownAt <> '') and IsBelowRoot(r.UnknownAt) then Exit(False);
  Result := IsInsideRoot(r.Path);
end;

function SandboxScratchPath: String;
begin
  if GRoot = '' then Exit('');
  Result := IncludeTrailingPathDelimiter(GRoot) + 'phosphor-scratch';
  if not DirectoryExists(Result) then ForceDirectories(Result);
  Result := IncludeTrailingPathDelimiter(Result);
end;

end.
