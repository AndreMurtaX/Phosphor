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
       that computed one has a bug this must not carry out for it. Reads are not
       refused: listing a drive root destroys nothing.

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
function IsPerilousPath(const APath: String): Boolean;
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
  { EVERY SEPARATOR, NOT JUST THE NATIVE ONE. ExcludeTrailingPathDelimiter strips
    PathDelim, which on Windows is '\' alone -- so "C:\" reduced to "C:" and was
    caught, while "C:/" stayed three characters long and was not. The Windows API
    accepts both spellings equally, and this project's own documentation tells a
    reader to prefer the forward slash ("C:/temp") because a backslash in a string
    literal is an escape. The rule was therefore blind to the spelling it had
    taught people to use.

    Repeated, because "C://" and "C:\\" are drive roots too: strip until nothing
    trailing is left. }
  { Both spellings, everywhere: the separator is normalised BEFORE anything is
    measured, so the rest of this function sees one form. '/' alone still reduces
    to '' and is still the root. }
  p := StringReplace(p, '/', '\', [rfReplaceAll]);
  while (Length(p) > 0) and (p[Length(p)] = '\') do
    Delete(p, Length(p), 1);
  {$ELSE}
  while (Length(p) > 0) and (p[Length(p)] = '/') do
    Delete(p, Length(p), 1);
  {$ENDIF}
  if p = '' then Exit(True);                       // '/' or '\' alone
  {$IFDEF WINDOWS}
  // 'C:', 'C:\', 'C:/' and 'C://' all reduce to two characters here
  if (Length(p) = 2) and (p[2] = ':') then Exit(True);
  { A UNC root, in either spelling: \\server and \\server\share alike.

    The comment here used to promise "\\server\share with nothing under it" while
    the test was `Pos('\', ...) = 0`, which is true only for \\server -- so the
    share root itself, the one thing on a network that answers to "delete
    everything", was treated as an ordinary folder. A share root is a drive root
    with a different spelling. Two components after the slashes is still a root;
    three is a folder inside one. }
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
