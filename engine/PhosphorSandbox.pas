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

{ Resolve to an absolute real path: '.' and '..' collapsed, symlinks followed on
  every component that exists. Public because the sandbox probe asserts on it. }
function RealPathOf(const APath: String): String;

implementation

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
  recursive delete, and is not a property to trade away. RealPathOf additionally
  follows symlinks, which costs a FileExists, a DirectoryExists and a
  FileGetSymLinkTarget for every component, on a guard consulted before every
  write; and here it would answer no differently, because FollowLinks returns a
  path unchanged when it is not a link. Rule 2 still resolves links, through
  RealPathOf, where a link is what matters.

  WHY THE TEXT TEST IS KEPT AS WELL, rather than replaced. ExpandFileName('C:')
  answers the current directory ON drive C:, not the root of it -- a bare drive
  letter is the one spelling that resolution makes LESS suspicious, and it is
  perilous. So the two are OR-ed: the text test refuses a string that names a
  volume and no directory in it, the structural test refuses every string that
  leads to one. }

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

function IsPerilousPath(const APath: String): Boolean;
var
  p: String;
begin
  { Trimmed once, here, so both tests judge the same string: "C:\ " with a
    trailing space is the drive root, and only Trim makes it look like one. }
  p := Trim(APath);
  if p = '' then Exit(True);
  Result := NamesAVolumeOnly(p) or ResolvesToAVolumeRoot(p);
end;

// --- resolution --------------------------------------------------------------
{ Split the part of a path after the drive/root into its components. Written with
  Copy rather than character concatenation: under the UTF8 codepage directive this
  unit compiles with, appending a Char to a String re-encodes it and destroys
  every byte >= 128. }
procedure SplitComponents(const ARest: String; var AParts: array of String;
                          out ACount: Integer);
var
  i, start: Integer;
begin
  ACount := 0;
  start := 1;
  for i := 1 to Length(ARest) + 1 do
    if (i > Length(ARest)) or (ARest[i] = '/') or (ARest[i] = '\') then
    begin
      if (i > start) and (ACount <= High(AParts)) then
      begin
        AParts[ACount] := Copy(ARest, start, i - start);
        Inc(ACount);
      end;
      start := i + 1;
    end;
end;

{ Rooted, without the LCL's FilenameIsAbsolute -- the engine may not reach FileUtil. }
function IsRootedPath(const APath: String): Boolean;
begin
  if APath = '' then Exit(False);
  if (APath[1] = '/') or (APath[1] = '\') then Exit(True);
  Result := ExtractFileDrive(APath) <> '';
end;

{ Follow a symlink chain, bounded. Answers the path unchanged when it is not a
  link (or the platform cannot say), so a failure here can only make the check
  STRICTER, never looser. }
function FollowLinks(const APath: String; var AHops: Integer): String;
var
  target: RawByteString;   // the signature FileGetSymLinkTarget takes by var
  t: String;
begin
  Result := APath;
  while AHops < 40 do
  begin
    if not (FileExists(Result) or DirectoryExists(Result)) then Exit;
    target := '';
    if not FileGetSymLinkTarget(RawByteString(Result), target) then Exit;
    if target = '' then Exit;
    Inc(AHops);
    t := String(target);
    if not IsRootedPath(t) then
      t := IncludeTrailingPathDelimiter(
             ExtractFilePath(ExcludeTrailingPathDelimiter(Result))) + t;
    Result := ExcludeTrailingPathDelimiter(ExpandFileName(t));
  end;
end;

function RealPathOf(const APath: String): String;
var
  full, rest, base, cand: String;
  parts: array[0..255] of String;
  count, i, hops: Integer;
begin
  full := ExpandFileName(APath);           // absolute; '.' and '..' collapsed
  base := ExtractFileDrive(full);          // 'C:' / '\\server\share' / '' on unix
  rest := Copy(full, Length(base) + 1, Length(full));
  SplitComponents(rest, parts, count);
  hops := 0;
  Result := base + PathDelim;
  for i := 0 to count - 1 do
  begin
    cand := IncludeTrailingPathDelimiter(Result) + parts[i];
    // A link is replaced by its target, which may itself be a link; the target
    // is then the new prefix and the remaining components hang off it.
    Result := ExcludeTrailingPathDelimiter(FollowLinks(cand, hops));
    if Result = '' then Result := base + PathDelim;
  end;
  Result := ExcludeTrailingPathDelimiter(Result);
  if Result = '' then Result := base + PathDelim;
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
  p := ExcludeTrailingPathDelimiter(ExpandFileName(Trim(APath)));
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
  f := ExcludeTrailingPathDelimiter(AFull);
  {$IFDEF WINDOWS}
  r := LowerCase(r);
  f := LowerCase(f);
  {$ENDIF}
  if f = r then Exit(True);
  Result := Copy(f, 1, Length(r) + 1) = r + PathDelim;
end;

function SandboxAllows(const APath: String; AUse: TPathUse): Boolean;
begin
  if (AUse <> puRead) and IsPerilousPath(APath) then Exit(False);
  if GRoot = '' then Exit(True);
  if Trim(APath) = '' then Exit(False);
  Result := IsInsideRoot(RealPathOf(APath));
end;

function SandboxScratchPath: String;
begin
  if GRoot = '' then Exit('');
  Result := IncludeTrailingPathDelimiter(GRoot) + 'phosphor-scratch';
  if not DirectoryExists(Result) then ForceDirectories(Result);
  Result := IncludeTrailingPathDelimiter(Result);
end;

end.
