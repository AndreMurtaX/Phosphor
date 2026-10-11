{******************************************************************************
  Phosphor BASIC -- file text I/O and path helpers (a function package)

  MIT License. Copyright (c) 2026 Andre Murta.

  Whole-file text read/write that preserves bytes exactly: no BOM is written and
  no line ending is translated, so eleven characters written are eleven read back
  and a bare LF stays one character. The path helpers are pure string operations
  that accept BOTH '/' and '\' as separators on every platform, so a path written
  with '/' behaves the same on Windows and Linux. Failures are RETURNED (a write
  answers 0, a read of a missing file answers ""), never raised.
******************************************************************************}
unit PhosphorIoLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles, PhosphorSandbox,
  PhosphorBudget;

type
  { A raw byte buffer as a handle object, for file_readallbytes@/writeallbytes.
    Public so a sibling lib (PhosphorStrListLib's stream load/save) can move a
    string list through the SAME handle IoLib hands out for a file's bytes. }
  TPhosphorBytes = class
    Data: String;
  end;

{ ASK THE SANDBOX, AND SAY SO WHEN IT REFUSES (ledger n10, d62).

  Every routine in this unit, PhosphorSysLib and PhosphorStrListLib that touches
  the filesystem asks the gate through THIS, never through SandboxAllows directly
  -- scripts/check-sandbox.py refuses a bare SandboxAllows in those three units.
  A refusal records IOERR_REFUSED in ioerror(), so iostrerror$() says "access
  denied". Until 2026-10-06 a refusal recorded 2 ("file not found") in
  file_readalltext$, 3 ("path not found") in five more, and NOTHING in the other
  thirty-odd names that reach the gate -- which left ioerror() holding whatever the
  previous call put there, a stale answer read as this call's. }
const
  IOERR_REFUSED = 5;   // 'access denied' in IoErrorText
  IOERR_FAILED = 3;    // the operation was attempted and did not happen
  { The longest path IoGate does not price: PATH_MAX on Linux. See IoGate. }
  IoPathFreeBytes = 4096;

function IoGate(const APath: String; AUse: TPathUse): Boolean;
{ THE SAME DOOR, AT THE CALLER'S RATE (round 9). IoGate prices a long path at
  what the gate and a QUERY cost (file_exists, file_getsize: BudgetMilliRewrite).
  A call that makes the OS do more with the path -- create, remove or enter a
  directory, delete a file -- passes the rate measured for it: on Windows a
  chdir of a 4 MB path cost 249 ms, 36 times the query's price, and 3000 of them
  ran 117 s under a step budget worth 2000 ms. }
function IoGateAt(const APath: String; AUse: TPathUse; AMilliEach: Int64): Boolean;
{ After an IoGate that said no: the BUDGET's refusal of the path is AFn's
  peLimit, named in Err; the SANDBOX's stays what it always was, 0 with
  ioerror() 5. Always False, so a door reads `IoGate(..) or GateRefused(..)`.
  EVERY caller of IoGate that holds an error asks it -- SysLib's mkdir, rmdir,
  chdir, kill and fileexists did not, and answered a refused path as a plain 0
  with ioerror() 3, a failure, while dir_create beside them said peLimit
  (round 9; scripts/check-budget.py's refusal gate now holds it). }
function GateRefused(const AFn: String; var Err: TPhosphorError): Boolean;
{ THE ANSWER OF A FILESYSTEM MUTATOR, in one place: 1 when the operation
  happened and 0 when it did not, with ioerror() set to match -- 0 on success,
  IOERR_FAILED on failure. Pass it what the RTL call returned. A refusal never
  gets here: IoGate has already answered it and recorded IOERR_REFUSED, so a
  script can tell "refused" (5) from "tried and failed" (3). mkdir, rmdir,
  chdir, kill, file_delete and dir_setcurrent all answer through it. }
function IoAnswer(AOk: Boolean): TValue;
{ The answer of a filesystem QUERY that was asked and answered: 1 or 0 as AYes
  says, and ioerror() back to 0 -- a "no" is an answer, not a failure. Without it
  a refusal's 5 from an earlier call stood beside the next answer, and a refused
  query could not be told from a "no". fileexists answers through it. }
function IoQueried(AYes: Boolean): TValue;
{ A refusal decided by the caller rather than by the sandbox: 0, and ioerror()
  5. For a request the gate passes but that names nothing to act on -- chdir("")
  with no sandbox in force, which the RTL answers True without moving. }
function IoRefused: TValue;

procedure RegisterIoFuncs(Reg: TPhosphorRegistry);

implementation

var
  GIoError: Integer;   // last IO error code; ioerror()/iostrerror$() read it
  GWalkSpent: Boolean; // a tree walk stopped because the run's budget ran out
  GPathPriced: Boolean; // the last IoGate refused because the budget priced its path

{ THE PATH IS PRICED HERE, AT THE ONE DOOR EVERY FILE OPERATION PASSES (round
  7). SandboxAllows reads the whole path -- a NUL scan, a trim, a walk of its
  components -- and the RTL hands it to the OS as a wide string after that, so a
  file call is linear in its path, which a script can make 50 MB long. Priced
  before the gate reads it -- at the REWRITE rate since round 8, which is what
  the gate and a failing system call measured (1.3 to 2.2 ns a byte across
  file_exists, dir_exists, file_readalltext$ and file_getsize); the OS rate it
  had was path_getfullpath$'s, a call that does far more with the path, and
  charged these 6.5 times their cost. A refusal is the walk's: GWalkSpent is
  set, so every operation that reports a walk (WalkRefused) reports this as the
  peLimit it is, and every other door asks GateRefused, which names it.

  A REFUSAL HERE DOES NOT LATCH, AND THE DOOR MUST ASK (round 9). A long path
  is an ARGUMENT, and an oversized argument is refused without spending the run
  (RULE 1): the program may go on with a shorter one. So the refusal's only
  record is GWalkSpent / GPathPriced, and every door that calls this asks
  GateRefused or WalkRefused, which turn it into the door's peLimit -- the
  five SysLib doors that never asked answered a refused path as 0 with
  ioerror() 3, and nothing else would ever have said it. scripts/check-budget.py
  holds the rule: a refusal recorded in a flag is settled only by a REPORTER
  of that flag, never by a later BudgetSpent, which a flag does not set. }
function IoGateAt(const APath: String; AUse: TPathUse; AMilliEach: Int64): Boolean;
begin
  GPathPriced := False;
  { A path no longer than IoPathFreeBytes is the price of the system call it
    rides on, and is NOT asked about: that keeps file_exists working after a
    script has spent its budget (tests/packages/27_zip_integrity.bas looks at
    the disk exactly then), and bounds what an unpriced call can cost to 4096
    bytes of path. A longer path is priced WHOLE -- no OS accepts one past 32767
    UTF-16 units, but the gate and the conversion read it all first. }
  if (Length(APath) > IoPathFreeBytes) and not BudgetLinear(Length(APath), AMilliEach) then
  begin
    GWalkSpent := True;
    GPathPriced := True;
    GIoError := IOERR_FAILED;
    Exit(False);
  end;
  Result := SandboxAllows(APath, AUse);
  if not Result then GIoError := IOERR_REFUSED;
end;

function IoGate(const APath: String; AUse: TPathUse): Boolean;
begin
  Result := IoGateAt(APath, AUse, BudgetMilliRewrite);
end;

function GateRefused(const AFn: String; var Err: TPhosphorError): Boolean;
begin
  Result := False;
  if GPathPriced then
  begin
    Err := BudgetRefusal(AFn);
    GPathPriced := False;
    GWalkSpent := False;
  end;
end;

{ A DIRECTORY WALK IS A LOOP THE VM CANNOT SEE. CollectEntries, DeleteTree and
  CopyTree each recurse over as many entries as the filesystem holds, all inside
  ONE opCall, so dir_getfiles$ over a large tree runs for as long as the tree is
  big with every execution ceiling set. Unlike string$ the size is NOT derivable
  from the arguments -- only the filesystem knows -- so this is RULE 2 of
  PhosphorBudget: charge per entry and stop when the budget says stop.

  An entry costs a directory syscall plus a path build, worth rather more than one
  interpreted instruction, so it is priced at BudgetUnitsPerStep -- one step each.
  The million-step budget docs/embedding.md prescribes therefore buys a million
  directory entries, which no legitimate listing comes near.

  A walk that stops early must never read as a walk that finished, so it sets
  GWalkSpent and every entry point below reports it as the peLimit it is. }
function WalkStep: Boolean;
begin
  if GWalkSpent then Exit(False);
  Result := BudgetCharge(BudgetUnitsPerStep);
  if not Result then GWalkSpent := True;
end;

procedure WalkBegin;
begin
  GWalkSpent := False;
end;

{ GWalkSpent OR THE LATCH (round 9). CopyFileBytes charges the bytes it copies
  through BudgetCharge, which latches the run and sets no GWalkSpent -- so a
  file_copy refused there answered 0 as a failure, ioerror 3, while the same
  refusal one helper over (ReadAllBytes) was the peLimit it is. Every charge
  below a door either sets the flag or latches the budget; this asks both.
  Round 10 asks a copy for its whole price up front, without latching, so
  CopyFileBytes no longer latches at all -- the latch is still asked here,
  because a walk that a latch stopped is a refusal whichever helper charged,
  and scripts/check-budget.py now settles a latch only by a reporter that
  READS it: with this line cut to `GWalkSpent` alone the gate reports every
  door that walks (round 10: it used to stay green). }
function WalkRefused(const AFn: String; out Err: TPhosphorError): Boolean;
begin
  Result := GWalkSpent or BudgetSpent();
  if Result then
  begin
    Err := BudgetRefusal(AFn);
    GIoError := 3;
  end;
end;

// --- raw whole-file text (no BOM, no newline translation) -------------------
{ APaid: the write's units were already asked for, with the read that produced
  AContent (CopyFileBytes). Required, never defaulted -- a default of True would
  be an unpriced write that nobody chose. }
function WriteAllBytesAs(const APath, AContent: String; APaid: Boolean): Boolean;
var fs: TFileStream;
begin
  Result := False;
  // Asked HERE and not at each caller: a t_ function added later inherits the
  // guard by calling this, and cannot forget it.
  if not IoGate(APath, puWrite) then Exit;
  // One byte written is one unit, like one byte read: a file_writealltext$ of a
  // gigabyte is a gigabyte of work inside one opCall whichever way it flows.
  if (not APaid) and not BudgetAllows(Length(AContent)) then
  begin
    GWalkSpent := True;
    Exit;
  end;
  try
    fs := TFileStream.Create(APath, fmCreate);
    try
      if Length(AContent) > 0 then fs.WriteBuffer(AContent[1], Length(AContent));
    finally
      fs.Free;
    end;
    Result := True;
  except
    Result := False;
  end;
end;

function WriteAllBytes(const APath, AContent: String): Boolean;
begin
  Result := WriteAllBytesAs(APath, AContent, False);
end;

{ A WHOLE FILE IS A SIZE THE ARGUMENTS DO NOT NAME -- BUT THE FILESYSTEM DOES.

  file_readalltext$ of a twelve-gigabyte file finished in 1437 ms having
  committed twelve gigabytes inside one opCall, under the same ceiling that
  refuses a one-gibibyte buffer. The path says nothing about the size, so the
  first version's grep for "a loop over a script-supplied count" could not see
  it; but the size is in hand the moment the stream is open, one line BEFORE the
  SetLength that commits it. That makes it a RULE 1 shape after all -- ask, then
  allocate -- and one byte of file is one unit, the same unit as everywhere else.

  It is asked HERE and not at each caller for the same reason SandboxAllows is:
  a t_ function added later inherits the guard by calling this.

  ATimes: how many units each byte read costs the caller -- 1 for a read, 2 for
  a COPY, which writes every byte back out and asks for both halves here, in one
  question, before a byte is committed (round 10; see CopyFileBytes). }
function ReadAllBytesTimes(const APath: String; out AContent: String;
                           ATimes: Int64): Boolean;
var fs: TFileStream; len: Int64;
begin
  AContent := '';
  Result := False;
  if not IoGate(APath, puRead) then Exit;
  if not FileExists(APath) then Exit;
  try
    fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      len := fs.Size;
      if (len > 0) and (ATimes > 1) and (len > High(Int64) div ATimes) then
        len := High(Int64) div ATimes;           // saturates: refused below
      if not BudgetAllows(len * ATimes) then
      begin
        GWalkSpent := True;
        Exit;
      end;
      len := fs.Size;
      SetLength(AContent, len);
      if len > 0 then fs.ReadBuffer(AContent[1], len);
    finally
      fs.Free;
    end;
    Result := True;
  except
    Result := False;
  end;
end;

function ReadAllBytes(const APath: String; out AContent: String): Boolean;
begin
  Result := ReadAllBytesTimes(APath, AContent, 1);
end;

function t_file_writealltext(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  WalkBegin();
  Result := ValInt(Ord(WriteAllBytes(Args[0].Str, Args[1].Str)));
  if WalkRefused('file_writealltext', Err) then Result := ValInt(0);
end;
function t_file_readalltext(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: String;
begin
  Err := NoError();
  WalkBegin();
  // 2 is "nothing there to read"; a REFUSAL has already recorded 5 inside
  // ReadAllBytes, and must not be overwritten into a claim that the file is
  // missing -- which is what this line used to make of every refusal (n10).
  GIoError := 0;
  if (not ReadAllBytes(Args[0].Str, s)) and (GIoError <> IOERR_REFUSED) then GIoError := 2;
  if WalkRefused('file_readalltext$', Err) then Exit(ValStr(''));
  Result := ValStr(s);
end;
function t_file_exists(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  // Outside the sandbox a file does not exist as far as the script is concerned:
  // answering truthfully would leak the shape of a filesystem it cannot read.
  if not (IoGate(Args[0].Str, puRead) or GateRefused('file_exists', Err)) then begin Result := ValInt(0); Exit; end;
  Result := ValInt(Ord(FileExists(Args[0].Str)));
end;
function t_file_delete(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if not (IoGateAt(Args[0].Str, puDelete, BudgetMilliOs) or
          GateRefused('file_delete', Err)) then
  begin Result := ValInt(0); Exit; end;
  Result := IoAnswer(DeleteFile(Args[0].Str));
end;

// savetext$/opentext$: the encoding argument is accepted; utf-8 is raw bytes,
// which is what the whole engine already speaks.
function t_savetext(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  WalkBegin();
  WriteAllBytes(Args[0].Str, Args[2].Str);
  if WalkRefused('savetext$', Err) then Exit(ValStr(''));
  Result := ValStr(Args[0].Str);
end;
function t_opentext(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: String;
begin
  Err := NoError();
  WalkBegin();
  ReadAllBytes(Args[0].Str, s);
  if WalkRefused('opentext$', Err) then Exit(ValStr(''));
  Result := ValStr(s);
end;

// --- path helpers (pure; '/' and '\' both separate, on every platform) ------
function LastSep(const P: String): Integer;
var i: Integer;
begin
  Result := 0;
  for i := Length(P) downto 1 do
    if (P[i] = '/') or (P[i] = '\') then Exit(i);
end;

function LastDotAfter(const P: String; AAfter: Integer): Integer;
var i: Integer;
begin
  Result := 0;
  for i := Length(P) downto AAfter + 1 do
    if P[i] = '.' then Exit(i);
end;

{ THE PATH SPLITTERS are a backwards scan for a separator and a copy of what
  they found: priced at the copy rate over the whole path, before either. }
function PathOk(const AWho, APath: String; var Err: TPhosphorError): Boolean;
begin
  Result := BudgetLinearOk(AWho, Length(APath), BudgetMilliCopy, Err);
end;

function t_path_getfilename(const Args: array of TValue; out Err: TPhosphorError): TValue;
var p: String;
begin
  Err := NoError(); p := Args[0].Str;
  if not PathOk('path_getfilename$', p, Err) then Exit(ValStr(''));
  Result := ValStr(Copy(p, LastSep(p) + 1, MaxInt));
end;
function t_path_getextension(const Args: array of TValue; out Err: TPhosphorError): TValue;
var p: String; sep, dot: Integer;
begin
  Err := NoError(); p := Args[0].Str;
  if not PathOk('path_getextension$', p, Err) then Exit(ValStr(''));
  sep := LastSep(p);
  dot := LastDotAfter(p, sep);
  if dot > 0 then Result := ValStr(Copy(p, dot, MaxInt)) else Result := ValStr('');
end;
function t_path_getfilenamenoext(const Args: array of TValue; out Err: TPhosphorError): TValue;
var p, fn: String; sep, dot: Integer;
begin
  Err := NoError(); p := Args[0].Str;
  if not PathOk('path_getfilenamenoext$', p, Err) then Exit(ValStr(''));
  sep := LastSep(p);
  fn := Copy(p, sep + 1, MaxInt);
  dot := LastDotAfter(p, sep);
  if dot > 0 then Result := ValStr(Copy(p, sep + 1, dot - sep - 1)) else Result := ValStr(fn);
end;
function t_path_changeextension(const Args: array of TValue; out Err: TPhosphorError): TValue;
var p, ext: String; sep, dot: Integer;
begin
  Err := NoError(); p := Args[0].Str; ext := Args[1].Str;
  { Two copies (the stem, then the stem and the extension) after the backward
    scans. It was priced as ONE copy of `p + ext` -- a copy it made just to ask
    the price, and then made twice more (round 8, measured at 2.2x its price). }
  if not BudgetLinearOk('path_changeextension$', 2 * (Int64(Length(p)) + Length(ext)),
                        BudgetMilliCopy, Err) then Exit(ValStr(''));
  sep := LastSep(p);
  dot := LastDotAfter(p, sep);
  if dot > 0 then Result := ValStr(Copy(p, 1, dot - 1) + ext) else Result := ValStr(p + ext);
end;

// the directory part, WITH its trailing separator ("C:\folder\notes.txt" ->
// "C:\folder\"); empty when the path has no separator.
function t_extractfilepath(const Args: array of TValue; out Err: TPhosphorError): TValue;
var p: String;
begin
  Err := NoError(); p := Args[0].Str;
  if not PathOk('extractfilepath$', p, Err) then Exit(ValStr(''));
  Result := ValStr(Copy(p, 1, LastSep(p)));
end;

function t_dir_exists(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if not (IoGate(Args[0].Str, puRead) or GateRefused('dir_exists', Err)) then begin Result := ValInt(0); Exit; end;
  Result := ValInt(Ord(DirectoryExists(Args[0].Str)));
end;

// ============================================================================
//  IOUtils surface: directories, copy/move, timestamps, bytes, path extras.
// ============================================================================

var
  GDirTimes: TStringList;   // dir timestamps kept in-process (FileAge can't read a dir)

// --- glob matcher (own, so case handling is identical on every platform) ----
{ Byte-wise, case-sensitive comparison for a directory listing: the same order on
  every platform. See the note at the call site. }
function CompareEntryBytes(AList: TStringList; AIndex1, AIndex2: Integer): Integer;
begin
  Result := CompareStr(AList[AIndex1], AList[AIndex2]);
end;

{ THE TREE'S OTHER BACKTRACKING MATCHER, and it was the shape RULE 3 exists for.

  The first version of this was a RECURSIVE star-backtracker: on a '*' it called
  itself once for every remaining position. That is the same exponential the
  regex judge refuses, reached through the filesystem API instead of the regex
  one -- and it was reachable two ways, directly as path_matchespattern and from
  inside CollectEntries, whose per-entry charge is O(1) while the per-entry match
  was O(2^n). Twenty stars against a forty-character name did not return:

      n$ = string$(40, 97)
      p$ = mulstring$("*a", 20) + "*b"
      println path_matchespattern(n$, p$)   ' still running after 20 s

  It is now the classic greedy matcher with ONE remembered star, which is the
  standard linear-space wildcard algorithm and provably answers the same thing:
  with only '*' and '?' there is never a reason to try an earlier star again once
  a later one has been placed, so remembering the most recent star and resuming
  one character further is complete. The worst case falls from 2^n to n*m.

  n*m is still not O(1), so it is CHARGED as it goes (RULE 2 of PhosphorBudget):
  the counter is the number of character comparisons actually made, and a run
  whose budget is spent stops and says so through GWalkSpent, exactly as the
  directory walk does. With no budget installed BudgetCharge answers True on its
  first line and this is a plain matcher again.

  THE CASE FOLD IS PER COMPARISON, NOT A PASS (round 8). The lenient form began
  `n := LowerCase(AName); p := LowerCase(APattern)` -- two copies of both
  strings, made before the loop that charges, and charged by nothing. With the
  pattern "x" against a name of a's, the first comparison fails, the loop ends
  without a tick, and 2000 calls on a 100 MB name ran 45859 ms under a 2000 ms
  ceiling (step-only: success). SysUtils.LowerCase folds A..Z and nothing else,
  byte by byte, so folding each byte as it is compared answers exactly what
  comparing the two folded copies answered -- and the only work left is the
  comparisons, which the loop already charges. The trailing run of stars is
  walked under the same meter. }
function FoldGlob(C: Char; AFold: Boolean): Char; inline;
begin
  if AFold and (C >= 'A') and (C <= 'Z') then Result := Chr(Ord(C) + 32)
  else Result := C;
end;

function MatchGlob(const AName, APattern: String; ACaseSensitive: Boolean): Boolean;
var
  ni, pi, starPi, starNi, ln, lp: Integer;
  ticks: Int64;
  fold: Boolean;

  { One comparison's worth of work, charged in blocks; False = stop. }
  function Tick: Boolean;
  begin
    Result := True;
    Inc(ticks);
    if ticks >= BudgetClockEvery then
    begin
      ticks := 0;
      if GWalkSpent then Exit(False);
      if not BudgetCharge(BudgetClockEvery) then
      begin
        GWalkSpent := True;
        Exit(False);
      end;
    end;
  end;

begin
  fold := not ACaseSensitive;
  ln := Length(AName);
  lp := Length(APattern);
  ni := 1; pi := 1;
  starPi := 0; starNi := 0;
  ticks := 0;
  while ni <= ln do
  begin
    if not Tick() then Exit(False);
    // '*' is tested FIRST. Round two tested the literal/'?' comparison first,
    // and a pattern '*' landing on a name byte that is itself '*' was consumed
    // as a literal pair with no star remembered: path_matchespattern("*a","*")
    // answered 0. A name may legally contain '*' (dir_getfiles$ on Linux), so
    // the star branch must win the tie. 100 of 7225 length-0..3 cases over
    // {a,b,*,?} were wrong before this reordering; 0 of 7225 after it.
    if (pi <= lp) and (APattern[pi] = '*') then
    begin
      starPi := pi;
      starNi := ni;
      Inc(pi);
    end
    else if (pi <= lp) and ((APattern[pi] = '?') or
                            (FoldGlob(APattern[pi], fold) = FoldGlob(AName[ni], fold))) then
    begin
      Inc(ni); Inc(pi);
    end
    else if starPi > 0 then
    begin
      // Resume the last star one character further along the name.
      pi := starPi + 1;
      Inc(starNi);
      ni := starNi;
    end
    else
      Exit(False);
  end;
  while (pi <= lp) and (APattern[pi] = '*') do
  begin
    if not Tick() then Exit(False);
    Inc(pi);
  end;
  Result := pi > lp;
end;

// --- directory listing ------------------------------------------------------
procedure CollectEntries(const ADir, APattern: String; AFiles, ADirs, ARecursive: Boolean; AList: TStrings);
var sr: TSearchRec; base: String;
begin
  // Asked at every level, not only by the caller: a recursive listing walks into
  // subdirectories itself, and a directory symlink is how it would otherwise walk
  // straight out of the root.
  if not IoGate(ADir, puRead) then Exit;
  base := IncludeTrailingPathDelimiter(ADir);
  if FindFirst(base + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if not WalkStep() then Break;
      if (sr.Name = '.') or (sr.Name = '..') then Continue;
      if (sr.Attr and faDirectory) <> 0 then
      begin
        if ADirs and MatchGlob(sr.Name, APattern, False) then AList.Add(sr.Name);
        if ARecursive then CollectEntries(base + sr.Name, APattern, AFiles, ADirs, ARecursive, AList);
      end
      else if AFiles and MatchGlob(sr.Name, APattern, False) then
        AList.Add(sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;
function ListToStr(const ADir, APattern: String; AFiles, ADirs, ARecursive: Boolean): String;
var l: TStringList; i: Integer; total, at: Int64;
begin
  Result := '';
  if not IoGate(ADir, puRead) then Exit;
  l := TStringList.Create();
  try
    CollectEntries(ADir, APattern, AFiles, ADirs, ARecursive, l);
    // Sorted by BYTES, not by the machine's collation. TStringList.Sort compares
    // with AnsiCompareText, which orders "a-b.txt" and "ab.txt" one way under a
    // Windows locale and the other way under a C locale -- so the same directory
    // listed in a different order on each platform, and any golden over a listing
    // was platform-dependent. A byte order is arbitrary but it is the SAME
    // arbitrary order everywhere.
    l.CustomSort(@CompareEntryBytes);
    { JOINED ONCE, NOT APPENDED (round 7). `Result := Result + l[i]` copies the
      whole answer per entry when the heap cannot extend it -- O(entries x
      bytes), the shape TPhosphorStringList.JoinInto was rewritten out of --
      while the walk charged one step per entry. Measured once, sized once,
      moved; and the bytes are charged, since the answer is a copy of them. }
    total := 0;
    for i := 0 to l.Count - 1 do total := total + Length(l[i]) + 1;
    if total > 0 then Dec(total);
    if not BudgetLinear(total, BudgetMilliCopy) then
    begin
      GWalkSpent := True;
      Exit;
    end;
    SetLength(Result, total);
    at := 1;
    for i := 0 to l.Count - 1 do
    begin
      if i > 0 then begin Result[at] := #10; Inc(at); end;
      if Length(l[i]) > 0 then Move(l[i][1], Result[at], Length(l[i]));
      at := at + Length(l[i]);
    end;
  finally
    l.Free;
  end;
end;

// --- path predicates and pieces (own, both separators) ----------------------
function LastSepIdx(const P: String): Integer;
var i: Integer;
begin
  Result := 0;
  for i := Length(P) downto 1 do
    if (P[i] = '/') or (P[i] = '\') then Exit(i);
end;
function IsRooted(const P: String): Boolean;
begin
  Result := False;
  if P = '' then Exit;
  if (P[1] = '/') or (P[1] = '\') then Exit(True);
  if (Length(P) >= 2) and (P[2] = ':') then Exit(True);
end;
function Combine2(const A, B: String): String;
begin
  if A = '' then Result := B
  else if (A[Length(A)] = '/') or (A[Length(A)] = '\') then Result := A + B
  else Result := A + PathDelim + B;
end;

// --- byte-copy and tree helpers ---------------------------------------------
{ A COPY IS ASKED FOR WHOLE, ONCE, BEFORE IT STARTS (round 10). It was three
  questions about one file: the read asked len without latching, then the copy
  CHARGED len -- which latches -- and then the write asked len again. So a
  file_copy cost three times its size, and whether a refusal spent the run
  depended on the size the wrong way round: a file larger than what was left
  was refused and the run went on, one between a half and all of it was read,
  then latched the run, and one between a third and a half was refused at the
  write and the run went on (under the documented ceilings, 128 to 256 MB
  latched). A copy is a read and a write of the same bytes: 2 units a byte,
  asked as one RULE 1 question, refused without latching, and recorded in
  GWalkSpent like every other refusal below a door here. }
function CopyFileBytes(const ASrc, ADst: String): Boolean;
var s: String;
begin
  Result := ReadAllBytesTimes(ASrc, s, 2) and WriteAllBytesAs(ADst, s, True);
  if GWalkSpent then Result := False;
end;
procedure DeleteTree(const ADir: String);
var sr: TSearchRec; base: String;
begin
  // Re-asked at every level of the recursion, so a directory symlink planted
  // inside a permitted tree cannot walk the deletion out of it.
  if not IoGate(ADir, puDelete) then Exit;
  base := IncludeTrailingPathDelimiter(ADir);
  if FindFirst(base + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if not WalkStep() then Break;
      if (sr.Name = '.') or (sr.Name = '..') then Continue;
      if (sr.Attr and faDirectory) <> 0 then DeleteTree(base + sr.Name)
      else DeleteFile(base + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  RemoveDir(ADir);
end;
function CopyTree(const ASrc, ADst: String): Boolean;
var sr: TSearchRec; sbase, dbase: String;
begin
  Result := False;
  if not (IoGate(ASrc, puRead) and IoGate(ADst, puWrite)) then Exit;
  Result := ForceDirectories(ADst);
  if not Result then Exit;
  sbase := IncludeTrailingPathDelimiter(ASrc);
  dbase := IncludeTrailingPathDelimiter(ADst);
  if FindFirst(sbase + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if not WalkStep() then Break;
      if (sr.Name = '.') or (sr.Name = '..') then Continue;
      if (sr.Attr and faDirectory) <> 0 then CopyTree(sbase + sr.Name, dbase + sr.Name)
      else CopyFileBytes(sbase + sr.Name, dbase + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

// datetime <-> string with no locale (exact, for the in-process dir-time table)
function DtToStr(ADt: Double): String;
begin Result := IntToStr(PInt64(@ADt)^); end;
function StrToDt(const S: String): Double;
var i: Int64;
begin i := StrToInt64Def(S, 0); Result := PDouble(@i)^; end;

function IoAnswer(AOk: Boolean): TValue;
begin
  if AOk then GIoError := 0 else GIoError := IOERR_FAILED;
  Result := ValInt(Ord(AOk));
end;

function IoQueried(AYes: Boolean): TValue;
begin
  GIoError := 0;
  Result := ValInt(Ord(AYes));
end;

function IoRefused: TValue;
begin
  GIoError := IOERR_REFUSED;
  Result := ValInt(0);
end;

// --- directory functions ----------------------------------------------------
function t_dir_create(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  // Same class as dir_delete's: the answer was discarded and 1 returned regardless,
  // so a path that could not be created reported success. An empty path is refused
  // here too -- ForceDirectories('') answers True having made nothing.
  if not (IoGateAt(Args[0].Str, puWrite, BudgetMilliOsPath) or
          GateRefused('dir_create', Err)) then
  begin
    Result := ValInt(0);
    Exit;
  end;
  if ForceDirectories(Args[0].Str) then GIoError := 0 else GIoError := 3;
  Result := ValInt(Ord(DirectoryExists(Args[0].Str)));
end;
function t_dir_isempty(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  WalkBegin();
  Result := ValInt(Ord(ListToStr(Args[0].Str, '*', True, True, False) = ''));
  if WalkRefused('dir_isempty', Err) then Result := ValInt(0);
end;
function t_dir_delete(const Args: array of TValue; out Err: TPhosphorError): TValue;
var
  ok: Boolean;
begin
  Err := NoError();
  // ANSWER WHAT HAPPENED. Both calls return a result and both used to have it
  // thrown away, so a dir_delete of a non-empty directory answered 1, left the
  // directory standing, and set no error -- a program could not tell it had
  // failed by any means. file_delete next door already answers Ord(DeleteFile).
  // REFUSE BEFORE DOING ANYTHING. dir_delete("", 1) used to walk the root of the
  // current drive and delete it, then answer 1 -- because DirectoryExists("") is
  // False, so the post-check read the disaster as success.
  if not (IoGateAt(Args[0].Str, puDelete, BudgetMilliOsPath) or
          GateRefused('dir_delete', Err)) then
  begin
    Result := ValInt(0);
    Exit;
  end;
  if (Length(Args) >= 2) and (AsDouble(Args[1]) <> 0) then
  begin
    // The local tree walker reports nothing, so ask the filesystem the question
    // the caller actually has: is the directory gone?
    WalkBegin();
    DeleteTree(Args[0].Str);
    if WalkRefused('dir_delete', Err) then Exit(ValInt(0));
    ok := not DirectoryExists(Args[0].Str);
  end
  else
    ok := RemoveDir(Args[0].Str);
  if ok then GIoError := 0 else GIoError := 3;   // 3 ~ the operation failed; a refusal is 5
  Result := ValInt(Ord(ok));
end;
function t_dir_getfiles(const Args: array of TValue; out Err: TPhosphorError): TValue;
var pat: String; rec: Boolean;
begin
  Err := NoError();
  if Length(Args) >= 2 then pat := Args[1].Str else pat := '*';
  rec := (Length(Args) >= 3) and (AsDouble(Args[2]) <> 0);
  WalkBegin();
  Result := ValStr(ListToStr(Args[0].Str, pat, True, False, rec));
  if WalkRefused('dir_getfiles$', Err) then Result := ValStr('');
end;
function t_dir_getdirectories(const Args: array of TValue; out Err: TPhosphorError): TValue;
var pat: String; rec: Boolean;
begin
  Err := NoError();
  if Length(Args) >= 2 then pat := Args[1].Str else pat := '*';
  rec := (Length(Args) >= 3) and (AsDouble(Args[2]) <> 0);
  WalkBegin();
  Result := ValStr(ListToStr(Args[0].Str, pat, False, True, rec));
  if WalkRefused('dir_getdirectories$', Err) then Result := ValStr('');
end;
function t_dir_getentries(const Args: array of TValue; out Err: TPhosphorError): TValue;
var pat: String;
begin
  Err := NoError();
  if Length(Args) >= 2 then pat := Args[1].Str else pat := '*';
  WalkBegin();
  Result := ValStr(ListToStr(Args[0].Str, pat, True, True, False));
  if WalkRefused('dir_getentries$', Err) then Result := ValStr('');
end;
function t_dir_getparent(const Args: array of TValue; out Err: TPhosphorError): TValue;
var p: String; sep: Integer;
begin
  Err := NoError(); p := Args[0].Str;
  if not PathOk('dir_getparent$', p, Err) then Exit(ValStr(''));
  if (p <> '') and ((p[Length(p)] = '/') or (p[Length(p)] = '\')) then SetLength(p, Length(p) - 1);
  sep := LastSepIdx(p);
  if sep > 0 then Result := ValStr(Copy(p, 1, sep - 1)) else Result := ValStr('');
end;
function t_dir_isrelativepath(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(Ord(not IsRooted(Args[0].Str))); end;
function t_dir_getcurrent(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValStr(GetCurrentDir); end;
function t_dir_setcurrent(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  // Moving the working directory outside the root would make every RELATIVE path
  // after it resolve outside too, so the move itself is what has to be refused.
  Err := NoError();
  if not (IoGateAt(Args[0].Str, puRead, BudgetMilliOsPath) or
          GateRefused('dir_setcurrent', Err)) then Exit(ValInt(0));
  if Args[0].Str = '' then Exit(IoRefused());   // see chdir: '' moved nothing and answered 1
  Result := IoAnswer(SetCurrentDir(Args[0].Str));
end;
function t_dir_copy(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  WalkBegin();
  Result := ValInt(Ord(CopyTree(Args[0].Str, Args[1].Str)));
  if WalkRefused('dir_copy', Err) then Result := ValInt(0);
end;
{ IS THE TARGET OF A MOVE ALREADY TAKEN? docs/libraries/io.md promises file_move
  and dir_move answer 0 "when the target already exists", and until 2026-10-05
  that was true on Windows ONLY, by accident of the RTL: RenameFile is MoveFileW
  with no flags there, which refuses, and rename(2) on Unix, which REPLACES -- so
  on Linux file_move silently destroyed the file at the target and answered 1,
  and dir_move replaced an empty directory. The promise is now kept in plain code,
  identically on both.

  "Taken" is anything that occupies the name: a file, a directory, or a symlink --
  including a DANGLING one, which is why both tests are asked not to follow links
  (rename(2) would replace the link itself). The engine may not use the Unix units,
  and it does not need to: SysUtils' FollowLink=False forms ask lstat on Unix.

  A NAME THAT DENOTES THE SOURCE ITSELF IS NOT TAKEN. On a case-insensitive
  filesystem a rename that changes only the case of a name finds its "target"
  existing -- it is the source -- and refusing it would trade one defect for
  another. SameFileName compares the way the platform's filesystem does, which is
  exactly the question.

  WHAT THIS DOES NOT CLOSE, said rather than implied: the check and the rename are
  two calls, so another process creating the target between them is still
  replaced on Unix. Closing that needs renameat2(RENAME_NOREPLACE), which the RTL
  does not bind and the engine may not reach for; the window is one syscall wide
  and needs a second writer racing for the same name. }
function MoveTargetTaken(const ASrc, ADst: String): Boolean;
begin
  // Both names are expanded by the OS below; the gate priced only the target.
  if (Length(ASrc) + Length(ADst) > IoPathFreeBytes) and
     not BudgetLinear(Length(ASrc) + Length(ADst), BudgetMilliOs) then
  begin
    GWalkSpent := True;
    Exit(True);
  end;
  { IT ASKS THE GATE ITSELF, though both callers already have: a helper that
    probes the filesystem is a probe check-sandbox.py rightly will not trust to
    its callers, and the next caller may not have asked. A refused name is
    answered as taken, which makes the move answer 0 -- the refusal it owed. }
  if not IoGate(ADst, puWrite) then Exit(True);
  if SameFileName(ExpandFileName(ASrc), ExpandFileName(ADst)) then Exit(False);
  Result := FileExists(ADst, False) or DirectoryExists(ADst, False);
end;

function t_dir_move(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if not ((IoGate(Args[0].Str, puDelete) or GateRefused('dir_move', Err)) and
          (IoGate(Args[1].Str, puWrite) or GateRefused('dir_move', Err))) then
  begin Result := ValInt(0); Exit; end;
  GWalkSpent := False;          // only MoveTargetTaken's own refusal is asked about below
  if MoveTargetTaken(Args[0].Str, Args[1].Str) then
  begin
    Result := ValInt(0);
    if WalkRefused('dir_move', Err) then GWalkSpent := False;
    Exit;
  end;
  Result := ValInt(Ord(RenameFile(Args[0].Str, Args[1].Str)));
end;

// --- file copy/move/content -------------------------------------------------
function t_file_copy(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if not ((IoGate(Args[0].Str, puRead) or GateRefused('file_copy', Err)) and
          (IoGate(Args[1].Str, puWrite) or GateRefused('file_copy', Err))) then
  begin Result := ValInt(0); Exit; end;
  if (Length(Args) >= 3) and (AsDouble(Args[2]) = 0) and FileExists(Args[1].Str) then
  begin Result := ValInt(0); Exit; end;   // no overwrite, target exists
  // EVERY entry point that reaches a charged helper clears the flag first. Not
  // doing so is not merely a missing report: GWalkSpent LATCHES, so one refusal
  // anywhere would make every later file_copy answer 0 for the rest of the run.
  WalkBegin();
  Result := ValInt(Ord(CopyFileBytes(Args[0].Str, Args[1].Str)));
  if WalkRefused('file_copy', Err) then Result := ValInt(0);
end;
function t_file_move(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if not ((IoGate(Args[0].Str, puDelete) or GateRefused('file_move', Err)) and
          (IoGate(Args[1].Str, puWrite) or GateRefused('file_move', Err))) then
  begin Result := ValInt(0); Exit; end;
  GWalkSpent := False;          // only MoveTargetTaken's own refusal is asked about below
  if MoveTargetTaken(Args[0].Str, Args[1].Str) then
  begin
    Result := ValInt(0);
    if WalkRefused('file_move', Err) then GWalkSpent := False;
    Exit;
  end;
  Result := ValInt(Ord(RenameFile(Args[0].Str, Args[1].Str)));
end;
function t_file_createempty(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  WalkBegin();
  Result := ValInt(Ord(WriteAllBytes(Args[0].Str, '')));
  if WalkRefused('file_createempty', Err) then Result := ValInt(0);
end;
{$IFDEF WINDOWS}
{ WHAT A FILE IS NOW, on Windows (round 10) -- for file_getsize and the
  file_get*time doors. Declared from kernel32, as PhosphorSysLib declares its
  own, because the engine boundary keeps the 'windows' unit out. }
type
  TIoFileTime = record
    Lo, Hi: LongWord;
  end;
  { WIN32_FILE_ATTRIBUTE_DATA: 4 + 3*8 + 4 + 4 = 36 bytes, no padding. }
  TIoAttrData = record
    Attr: LongWord;
    Created, Accessed, Written: TIoFileTime;
    SizeHi, SizeLo: LongWord;
  end;
  { BY_HANDLE_FILE_INFORMATION: 4 + 3*8 + 6*4 = 52 bytes, no padding. }
  TIoHandleInfo = record
    Attr: LongWord;
    Created, Accessed, Written: TIoFileTime;
    Serial, SizeHi, SizeLo, Links, IndexHi, IndexLo: LongWord;
  end;

function IoGetFileAttributesExW(AName: PWideChar; ALevel: LongInt; AData: Pointer): LongBool;
  stdcall; external 'kernel32.dll' name 'GetFileAttributesExW';
function IoCreateFileW(AName: PWideChar; AAccess, AShare: LongWord; ASecurity: Pointer;
  ADisposition, AFlags: LongWord; ATemplate: THandle): THandle;
  stdcall; external 'kernel32.dll' name 'CreateFileW';
function IoCloseHandle(AHandle: THandle): LongBool;
  stdcall; external 'kernel32.dll' name 'CloseHandle';
function IoGetFileType(AHandle: THandle): LongWord;
  stdcall; external 'kernel32.dll' name 'GetFileType';
function IoGetFileInformationByHandle(AHandle: THandle; AInfo: Pointer): LongBool;
  stdcall; external 'kernel32.dll' name 'GetFileInformationByHandle';
function IoFileTimeToLocalFileTime(AUtc, ALocal: Pointer): LongBool;
  stdcall; external 'kernel32.dll' name 'FileTimeToLocalFileTime';
function IoFileTimeToDosDateTime(AFileTime: Pointer; ADate, ATime: Pointer): LongBool;
  stdcall; external 'kernel32.dll' name 'FileTimeToDosDateTime';
function IoGetLastError: LongWord;
  stdcall; external 'kernel32.dll' name 'GetLastError';

const
  IO_ATTR_DIRECTORY = $10;
  IO_ATTR_REPARSE = $400;
  IO_SHARE_ALL = 7;                 // FILE_SHARE_READ or _WRITE or _DELETE
  IO_OPEN_EXISTING = 3;
  IO_BACKUP_SEMANTICS = $02000000;  // lets the handle name a directory, so it can be told apart
  IO_TYPE_DISK = 1;
  IO_SHARING_VIOLATION = 32;

{ THE DIRECTORY ENTRY IS NOT THE FILE, ON WINDOWS. Round 9 moved file_getsize
  to FindFirst -- FindFirstFileW, which answers from the directory entry -- to
  stop it OPENING a file to read one number (a FIFO blocked that open on
  Linux, and a locked file refused it). On Linux that is a stat, the inode,
  and current. On Windows it is NOT, measured on this build:

    a file being written through another handle   file_getsize 0, the file 142000
    after an append through that handle            142000, the file 142005
    a hard link, after an append through the other 12345, the file 12350
    a symbolic link to a 12345-byte file           0 (the LINK's entry)

  -- a wrong number, on Windows only, and 0 cannot be told from an empty or a
  missing file. GetFileAttributesExW is the same directory entry (the symlink
  is 0 there too). The current answer comes from a HANDLE, and a handle opened
  with NO access rights -- only the attributes can be read through it -- is
  refused by no sharing mode (a file another handle holds with share 0 is
  answered) and reads no data, and Windows has no FIFO in a directory to block
  on: a named pipe lives in \\.\pipe\, where the attribute query below fails
  first, and an open of a busy one fails at once (ERROR_PIPE_BUSY), it does
  not wait.

  The attribute query goes first, without following anything, and settles
  "nothing there", "a directory" and every device name (NUL, CON: no
  attributes) without an open. Only then is the handle opened, FOLLOWING a
  link as a read would, and only a disk file that is not a directory is a
  regular file. A file the attribute query is itself refused for -- a paging
  file the system holds -- keeps the directory entry, the best that exists.

  ONE OPEN THIS STILL MAKES, said rather than implied: a symbolic link whose
  target is a named pipe is followed to the pipe, and that open connects to
  the pipe's server (measured: the server then sees a client come and go).
  Nothing blocks and nothing is read; telling a link's target apart before
  opening it would mean reading its reparse data, which is more machinery than
  a size query should carry, for a link someone made on purpose. }
function WinFileNow(const APath: String; out ASize: Int64; out AWritten: TIoFileTime;
                    out AHeld: Boolean): Boolean;
var
  w: UnicodeString;
  d: TIoAttrData;
  h: THandle;
  info: TIoHandleInfo;
begin
  Result := False;
  ASize := 0;
  AWritten.Lo := 0;
  AWritten.Hi := 0;
  AHeld := False;
  w := UnicodeString(APath);       // the conversion the RTL's own path calls make
  if w = '' then Exit;
  FillChar(d, SizeOf(d), 0);
  if not IoGetFileAttributesExW(PWideChar(w), 0, @d) then
  begin
    // Held so closely that even its attributes are refused: the CALLER asks
    // the directory entry, through the gate it has already passed.
    AHeld := IoGetLastError() = IO_SHARING_VIOLATION;
    Exit;
  end;
  if (d.Attr and IO_ATTR_DIRECTORY) <> 0 then Exit;
  h := IoCreateFileW(PWideChar(w), 0, IO_SHARE_ALL, nil, IO_OPEN_EXISTING,
                     IO_BACKUP_SEMANTICS, 0);
  if h = THandle(-1) then
  begin
    if (d.Attr and IO_ATTR_REPARSE) <> 0 then Exit;   // a link that leads nowhere
    ASize := Int64(d.SizeHi) shl 32 or d.SizeLo;
    AWritten := d.Written;
    Exit(True);
  end;
  try
    if IoGetFileType(h) <> IO_TYPE_DISK then Exit;
    FillChar(info, SizeOf(info), 0);
    if not IoGetFileInformationByHandle(h, @info) then Exit;
    if (info.Attr and IO_ATTR_DIRECTORY) <> 0 then Exit;
    ASize := Int64(info.SizeHi) shl 32 or info.SizeLo;
    AWritten := info.Written;
    Result := True;
  finally
    IoCloseHandle(h);
  end;
end;

{ FileAge's own conversion (rtl/win/sysutils.pp WinToDosTime): local time, then
  the DOS date FileDateToDateTime reads. -1 when Windows cannot convert it. }
function WinDosAge(const AWritten: TIoFileTime): LongInt;
var lft: TIoFileTime; dd, dt: Word;
begin
  Result := -1;
  if IoFileTimeToLocalFileTime(@AWritten, @lft) and
     IoFileTimeToDosDateTime(@lft, @dd, @dt) then
    Result := LongInt((LongWord(dd) shl 16) or dt);
end;
{$ENDIF}

{ A SIZE IS ASKED OF THE DIRECTORY, NEVER BY OPENING THE FILE (round 9).

  This opened the path -- TFileStream.Create, open(O_RDONLY) -- to read one
  number. On Linux, open() of a FIFO with no writer BLOCKS in the kernel until a
  writer comes, and neither ceiling can reach a call that is blocked: under
  MaxSteps 1000000 and TimeoutMs 2000 a file_getsize of a FIFO was still waiting
  when it was killed at ten seconds, and with a writer present it answered -1,
  which nothing documents. A directory walk that sums sizes hangs on the first
  FIFO in it -- io.md's own example is one.

  FindFirst is what `ls -l` and `du` do: a stat on Unix, FindFirstFileW on
  Windows, and the size the filesystem records, with no open at all. Only a
  REGULAR file has a size here: a directory, a FIFO, a device or a socket
  answers 0 at once, the 0 a missing file answers. A file another process holds
  locked is answered too, since nothing is opened to be refused.

  A name holding a wildcard is matched EXACTLY: FindFirst would read 'a*b' as a
  pattern, and the first file it happened to match is not the one asked about.
  Windows names cannot hold one; a Linux name can.

  ON WINDOWS THE DIRECTORY ENTRY IS STALE, AND THE ANSWER IS THE FILE'S (round
  10): see WinFileNow above. Linux keeps the stat, which is the file's. }
function t_file_getsize(const Args: array of TValue; out Err: TPhosphorError): TValue;
{$IFDEF WINDOWS}
var size: Int64; written: TIoFileTime; held: Boolean; sr: TSearchRec;
begin
  Err := NoError(); Result := ValInt(0);
  if not (IoGateAt(Args[0].Str, puRead, BudgetMilliOs) or
          GateRefused('file_getsize', Err)) then Exit;
  if WinFileNow(Args[0].Str, size, written, held) then Exit(ValInt(size));
  { A file held so that even its attributes are refused (a paging file the
    system holds) keeps the directory entry, the best answer there is. ONE
    entry: a name with a wildcard never gets here -- the attribute query fails
    on it with ERROR_INVALID_NAME, not a sharing violation. }
  if held and (FindFirst(Args[0].Str, faAnyFile, sr) = 0) then
  begin
    if (sr.Attr and faDirectory) = 0 then Result := ValInt(sr.Size);
    FindClose(sr);
  end;
end;
{$ELSE}
var sr: TSearchRec; want: String; exact: Boolean;
begin
  Err := NoError(); Result := ValInt(0);
  // The directory search reads the path as the OS does: 3.9 ns a byte measured.
  if not (IoGateAt(Args[0].Str, puRead, BudgetMilliOs) or
          GateRefused('file_getsize', Err)) then Exit;
  want := ExtractFileName(Args[0].Str);
  exact := (Pos('*', want) > 0) or (Pos('?', want) > 0);
  if FindFirst(Args[0].Str, faAnyFile, sr) <> 0 then Exit;
  try
    repeat
      // A pattern walks the directory: an entry is a step, as in the listings.
      if exact and not BudgetCharge(BudgetUnitsPerStep) then
      begin
        Err := BudgetRefusal('file_getsize');
        Exit;
      end;
      if exact and (sr.Name <> want) then Continue;
      if (sr.Attr and faDirectory) <> 0 then Exit;
      {$ifdef unix}
      // S_IFMT / S_IFREG: a FIFO, a device or a socket has no size to give.
      if (sr.Mode and $F000) <> $8000 then Exit;
      {$endif}
      Exit(ValInt(sr.Size));
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
end;
{$ENDIF}
function t_file_appendalltext(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: String;
begin
  Err := NoError();
  // An append is a whole read AND a whole write: the file is charged twice, once
  // by each half, which is what it actually costs.
  WalkBegin();
  ReadAllBytes(Args[0].Str, s);
  if WalkRefused('file_appendalltext', Err) then Exit(ValInt(0));
  // ...and the joined text is a copy of both, made before the write asks.
  if not BudgetLinearOk('file_appendalltext', Int64(Length(s)) + Length(Args[1].Str),
                        BudgetMilliMove, Err) then Exit(ValInt(0));
  Result := ValInt(Ord(WriteAllBytes(Args[0].Str, s + Args[1].Str)));
  if WalkRefused('file_appendalltext', Err) then Result := ValInt(0);
end;

// --- bytes (a handle-backed buffer) -----------------------------------------
function t_file_readallbytes(const Args: array of TValue; out Err: TPhosphorError): TValue;
var b: TPhosphorBytes;
begin
  Err := NoError();
  WalkBegin();
  b := TPhosphorBytes.Create();
  ReadAllBytes(Args[0].Str, b.Data);
  Result := ValHandle(RegisterHandle(b));
  if WalkRefused('file_readallbytes@', Err) then ;   // the handle is still valid, empty
end;
function t_file_writeallbytes(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  // A bogus handle writes nothing (0) rather than obeying.
  Err := NoError();
  WalkBegin();
  if (Args[1].Kind = vkHandle) and IsHandle(Args[1].Hnd) and (HandleObj(Args[1].Hnd) is TPhosphorBytes) then
    Result := ValInt(Ord(WriteAllBytes(Args[0].Str, TPhosphorBytes(HandleObj(Args[1].Hnd)).Data)))
  else
    Result := ValInt(0);
  if WalkRefused('file_writeallbytes', Err) then Result := ValInt(0);
end;

// --- timestamps: files are real (FileSetDate/FileAge); dirs are in-process --
function t_file_settime(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if not (IoGate(Args[0].Str, puWrite) or GateRefused('file_settime', Err)) then begin Result := ValInt(0); Exit; end;
  FileSetDate(Args[0].Str, DateTimeToFileDate(AsDouble(Args[1])));
  Result := ValInt(1);
end;
{ FileAge is FindFirstFileW on Windows -- the directory entry, the same stale
  copy file_getsize read: a symbolic link answered the LINK's own time where a
  read of it reads the target, and Linux (a stat) answers the target's. So on
  Windows the time is the file's, from the handle WinFileNow opens (round 10). }
function t_file_gettime(const Args: array of TValue; out Err: TPhosphorError): TValue;
var age: LongInt; {$IFDEF WINDOWS} size: Int64; written: TIoFileTime; held: Boolean; {$ENDIF}
begin
  Err := NoError();
  if not (IoGate(Args[0].Str, puRead) or GateRefused('file_gettime', Err)) then begin Result := ValInt(0); Exit; end;
  {$IFDEF WINDOWS}
  if WinFileNow(Args[0].Str, size, written, held) then age := WinDosAge(written)
  else if held then age := FileAge(Args[0].Str)    // the entry, as file_getsize keeps it
  else age := -1;
  {$ELSE}
  age := FileAge(Args[0].Str);
  {$ENDIF}
  if age > 0 then Result := ValDouble(FileDateToDateTime(age)) else Result := ValInt(0);
end;
function DirTimeKey(AKind: Char; const APath: String): String;
begin Result := AKind + APath; end;
{ GDirTimes is a list the SCRIPT grows -- one line per directory it stamps -- and
  Values[] finds a line by walking all of them, splitting each at its '='. So a
  stamp read or written costs the list, plus the path it builds a key from. }
function DirTimesOk(const AWho, APath: String; var Err: TPhosphorError): Boolean;
begin
  Result := BudgetLinearOk(AWho, GDirTimes.Count, BudgetMilliNameItem, Err) and
            BudgetLinearOk(AWho, Length(APath), BudgetMilliCopy, Err);
end;
function t_dir_settime_c(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValInt(0);
  if not DirTimesOk('dir_setcreationtime', Args[0].Str, Err) then Exit;
  GDirTimes.Values[DirTimeKey('c', Args[0].Str)] := DtToStr(AsDouble(Args[1])); Result := ValInt(1);
end;
function t_dir_settime_w(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValInt(0);
  if not DirTimesOk('dir_setlastwritetime', Args[0].Str, Err) then Exit;
  GDirTimes.Values[DirTimeKey('w', Args[0].Str)] := DtToStr(AsDouble(Args[1])); Result := ValInt(1);
end;
function t_dir_settime_a(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValInt(0);
  if not DirTimesOk('dir_setlastaccesstime', Args[0].Str, Err) then Exit;
  GDirTimes.Values[DirTimeKey('a', Args[0].Str)] := DtToStr(AsDouble(Args[1])); Result := ValInt(1);
end;
function t_dir_gettime_c(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValDouble(0);
  if not DirTimesOk('dir_getcreationtime', Args[0].Str, Err) then Exit;
  Result := ValDouble(StrToDt(GDirTimes.Values[DirTimeKey('c', Args[0].Str)]));
end;
function t_dir_gettime_w(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValDouble(0);
  if not DirTimesOk('dir_getlastwritetime', Args[0].Str, Err) then Exit;
  Result := ValDouble(StrToDt(GDirTimes.Values[DirTimeKey('w', Args[0].Str)]));
end;
function t_dir_gettime_a(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError(); Result := ValDouble(0);
  if not DirTimesOk('dir_getlastaccesstime', Args[0].Str, Err) then Exit;
  Result := ValDouble(StrToDt(GDirTimes.Values[DirTimeKey('a', Args[0].Str)]));
end;

// --- path extras ------------------------------------------------------------
{ PRICED BY WHAT IT COPIES (round 8). Each Combine2 is a fresh string holding
  both halves, and the three-part form makes two -- the first pair copied twice.
  It priced nothing: 2000 calls on a 100 MB path ran 19641 ms under a 2000 ms
  ceiling. }
function t_path_combine(const Args: array of TValue; out Err: TPhosphorError): TValue;
var copied: Int64;
begin
  Err := NoError();
  copied := Int64(Length(Args[0].Str)) + Length(Args[1].Str);
  if Length(Args) >= 3 then copied := 2 * copied + Length(Args[2].Str);
  if not BudgetLinearOk('path_combine$', copied, BudgetMilliMove, Err) then Exit(ValStr(''));
  if Length(Args) >= 3 then Result := ValStr(Combine2(Combine2(Args[0].Str, Args[1].Str), Args[2].Str))
  else Result := ValStr(Combine2(Args[0].Str, Args[1].Str));
end;
function t_path_getdirectoryname(const Args: array of TValue; out Err: TPhosphorError): TValue;
var p: String; sep: Integer;
begin
  Err := NoError(); p := Args[0].Str;
  if not PathOk('path_getdirectoryname$', p, Err) then Exit(ValStr(''));
  sep := LastSepIdx(p);
  if sep > 0 then Result := ValStr(Copy(p, 1, sep - 1)) else Result := ValStr('');
end;
function t_path_hasextension(const Args: array of TValue; out Err: TPhosphorError): TValue;
var p: String; sep, dot, i: Integer;
begin
  Err := NoError(); p := Args[0].Str;
  if not PathOk('path_hasextension', p, Err) then Exit(ValInt(0));
  sep := LastSepIdx(p); dot := 0;
  for i := Length(p) downto sep + 1 do
    if p[i] = '.' then begin dot := i; Break; end;
  Result := ValInt(Ord(dot > 0));
end;
function t_path_getfullpath(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  { ExpandFileName is the RTL's own FExpand (rtl/inc/fexpand.inc), a walk over
    every byte of the path in Pascal -- NOT GetFullPathNameW, which this comment
    used to claim: that call drops a trailing dot, and path_getfullpath$("a.")
    keeps it (measured, round 9). The OS is asked only for the current
    directory a relative path is joined to (GetDir). Priced at the OS rate. }
  if not BudgetLinearOk('path_getfullpath$', Length(Args[0].Str), BudgetMilliOs, Err) then
    Exit(ValStr(''));
  Result := ValStr(ExpandFileName(Args[0].Str));
end;
function t_path_ispathrooted(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(Ord(IsRooted(Args[0].Str))); end;
function t_path_isrelativepath(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(Ord(not IsRooted(Args[0].Str))); end;
function t_path_getpathroot(const Args: array of TValue; out Err: TPhosphorError): TValue;
var p: String;
begin
  Err := NoError(); p := Args[0].Str;
  if (Length(p) >= 2) and (p[2] = ':') then Result := ValStr(Copy(p, 1, 2) + '\')
  else if (p <> '') and ((p[1] = '/') or (p[1] = '\')) then Result := ValStr(p[1])
  else Result := ValStr('');
end;
function t_path_matchespattern(const Args: array of TValue; out Err: TPhosphorError): TValue;
var cs: Boolean;
begin
  Err := NoError();
  cs := (Length(Args) >= 3) and (AsDouble(Args[2]) <> 0);   // 2-arg form is lenient
  // The direct route into MatchGlob. It is charged like the walk that also
  // reaches it, and a match that stopped short must not read as a match that
  // answered False -- that is the difference between "no" and "I gave up".
  WalkBegin();
  Result := ValInt(Ord(MatchGlob(Args[0].Str, Args[1].Str, cs)));
  if WalkRefused('path_matchespattern', Err) then Result := ValInt(0);
end;
{ ONE TEST A BYTE, two loops (round 8). The file form tested Ord(c) < 32 and
  then a nine-element set on every byte -- about 2 ns a byte against the SCAN
  price of 0.625 that both forms were charged, so a step-only host ran 2.7
  times past its ceiling. One set test a byte measured 1.6 ns, which is still
  not a SCAN, so the file form is priced at the REWRITE rate it measures at;
  the path form, one compare a byte, stays a SCAN. The answer is the same byte
  for byte. }
function HasValidChars(const S: String; AForFile: Boolean): Boolean;
var i: Integer;
begin
  Result := True;
  if AForFile then
  begin
    for i := 1 to Length(S) do
      if S[i] in [#0..#31, '/', '\', ':', '*', '?', '"', '<', '>', '|'] then Exit(False);
  end
  else
    for i := 1 to Length(S) do
      if S[i] < #32 then Exit(False);
end;
function t_path_hasvalidpathchars(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if not BudgetLinearOk('path_hasvalidpathchars', Length(Args[0].Str), BudgetMilliScan, Err) then
    Exit(ValInt(0));
  Result := ValInt(Ord(HasValidChars(Args[0].Str, False)));
end;
function t_path_hasvalidfilenamechars(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if not BudgetLinearOk('path_hasvalidfilenamechars', Length(Args[0].Str), BudgetMilliRewrite, Err) then
    Exit(ValInt(0));
  Result := ValInt(Ord(HasValidChars(Args[0].Str, True)));
end;

// --- io errors --------------------------------------------------------------
function t_ioerror(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(GIoError); end;
{ The text for an I/O error code, the same on every machine.

  SysErrorMessage hands back the OPERATING SYSTEM's message, in the machine's
  language and its ANSI code page: on a pt-BR Windows this returned "O sistema nao
  pode encontrar o arquivo especificado." with a bare 0xE3 byte in it -- not UTF-8,
  so a program that printed it emitted invalid text, and a golden over it could not
  hold on two machines. The codes below are the ones a BASIC program actually meets;
  anything else is named by number rather than guessed at. }
function IoErrorText(ACode: Integer): String;
begin
  case ACode of
    0:   Result := 'No error';
    1:   Result := 'invalid function';
    2:   Result := 'file not found';
    3:   Result := 'path not found';
    4:   Result := 'too many open files';
    5:   Result := 'access denied';
    6:   Result := 'invalid file handle';
    15:  Result := 'invalid drive';
    16:  Result := 'cannot remove the current directory';
    17:  Result := 'not on the same device';
    18:  Result := 'no more files';
    19:  Result := 'the medium is write-protected';
    32:  Result := 'the file is in use by another process';
    38:  Result := 'unexpected end of file';
    39:  Result := 'the disk is full';
    87:  Result := 'invalid parameter';
    101: Result := 'the directory is not empty';
    112: Result := 'not enough space on the disk';
    183: Result := 'the file already exists';
  else
    Result := 'I/O error ' + IntToStr(ACode);
  end;
end;

function t_iostrerror(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValStr(IoErrorText(GIoError));
end;

// ============================================================================
//  What a path IS: file_kind$ and path_canonical$ (round 10)
// ============================================================================
{ A FILE JUDGED BY ITS SPELLING HAS AS MANY DOORS AS THE OS HAS SPELLINGS.
  Round 10 measured six of them past checks that read the name: on Windows the
  8.3 alias of a link (LONGLI~1.DAT for longlinkname.database), the 8.3 alias of
  a journal (TRUNCV~1.DB- for truncvictim.db-journal), an NTFS stream
  (other.db-journal:bk, which dies with other.db-journal), the main stream
  spelled out (crashed.db-wal::$DATA IS crashed.db-wal), a device (CON, which a
  read blocks on), and on Linux a FIFO (whose open blocks). Each check was right
  about the spelling it was shown and wrong about the file. A list of spellings
  is never finished, so these two ask the OS what the path IS:

  file_kind$(p$) -- "file", "dir", "link", "fifo", "device", "socket",
    "stream" or "none"; "" when it cannot be told (a refusal, a name the OS
    will not look at, an entry that cannot be read). A LINK IS A LINK, whatever
    it leads to or whether it leads anywhere: a POSIX symlink, a Windows
    symbolic link or junction (any name-surrogate reparse point). "stream" is
    any Windows path that names a stream by its syntax, "name::$DATA" included
    -- that one names the file itself, and is still not the file's NAME.
    "device" on Windows is a name the OS itself maps to a device: it is asked
    of GetFullPathNameW, which answers \\.\CON for CON (Windows 11 maps only
    the bare names; Windows 10 also C:\x\CON -- the OS decides, not a list).
  path_canonical$(p$) -- the one full name of what p$ leads to: links
    followed, 8.3 aliases expanded, case as the directory holds it, "." and
    ".." gone. For a name that is not there yet, the canonical name of its
    folder joined to the name as given -- so a file about to be created is
    named as it will be. "" when it cannot be answered: a link that leads to
    nothing (there is an entry, and no file to name), a folder that is not
    there, a stream, a device, a refusal.

  On Windows both open a HANDLE WITH NO ACCESS AT ALL (dwDesiredAccess 0): it
  reads no byte, takes no lock a reader would notice, and is what
  GetFinalPathNameByHandleW needs. file_kind$ opens it on the entry itself
  (FILE_FLAG_OPEN_REPARSE_POINT), path_canonical$ through any links. Neither
  opens a device or a pipe -- those are answered from the name first. On
  Linux nothing is opened: lstat, and a walk of the components that reads each
  link (realpath's own algorithm; libc is not linked into every binary that
  carries the engine, so it is written here). }

{$IFDEF WINDOWS}
{ Declared from kernel32, as PhosphorSysLib declares its own: the engine
  boundary keeps the 'windows' unit out. }
function KindGetFullPathNameW(lpFileName: PWideChar; nBufferLength: LongWord; lpBuffer: PWideChar;
  lpFilePart: Pointer): LongWord; stdcall; external 'kernel32.dll' name 'GetFullPathNameW';
function KindCreateFileW(lpFileName: PWideChar; dwDesiredAccess, dwShareMode: LongWord;
  lpSecurityAttributes: Pointer; dwCreationDisposition, dwFlagsAndAttributes: LongWord;
  hTemplateFile: THandle): THandle; stdcall; external 'kernel32.dll' name 'CreateFileW';
function KindCloseHandle(hObject: THandle): LongBool; stdcall; external 'kernel32.dll' name 'CloseHandle';
function KindGetFileType(hFile: THandle): LongWord; stdcall; external 'kernel32.dll' name 'GetFileType';
function KindGetFileAttributesW(lpFileName: PWideChar): LongWord; stdcall;
  external 'kernel32.dll' name 'GetFileAttributesW';
function KindGetFileInformationByHandleEx(hFile: THandle; AClass: LongInt; lpInfo: Pointer;
  dwBufferSize: LongWord): LongBool; stdcall; external 'kernel32.dll' name 'GetFileInformationByHandleEx';
function KindGetFinalPathNameByHandleW(hFile: THandle; lpszFilePath: PWideChar;
  cchFilePath, dwFlags: LongWord): LongWord; stdcall; external 'kernel32.dll' name 'GetFinalPathNameByHandleW';
function KindGetLastError: LongWord; stdcall; external 'kernel32.dll' name 'GetLastError';

const
  KIND_SHARE_ALL = 7;                     // FILE_SHARE_READ | WRITE | DELETE
  KIND_OPEN_EXISTING = 3;
  KIND_BACKUP_SEMANTICS = $02000000;      // a directory opens too
  KIND_OPEN_REPARSE_POINT = $00200000;    // the entry itself, not where it leads
  KIND_TYPE_DISK = 1;
  KIND_TYPE_CHAR = 2;
  KIND_TYPE_PIPE = 3;
  KIND_ATTR_DIR = $10;
  KIND_ATTR_REPARSE = $400;
  KIND_NO_ATTR = $FFFFFFFF;               // INVALID_FILE_ATTRIBUTES
  KIND_TAG_SURROGATE = $20000000;         // IsReparseTagNameSurrogate: symlink, junction
  KIND_TAG_AF_UNIX = $80000023;
  KIND_ATTR_TAG_INFO = 9;                 // FileAttributeTagInfo
  { The errors that mean "nothing by that name": file not found, path not
    found, and a name the file system cannot hold (ERROR_INVALID_NAME, which is
    what a '*' or a '?' in a Windows name earns). }
  KIND_ERR_NOT_FOUND = 2;
  KIND_ERR_PATH_NOT_FOUND = 3;
  KIND_ERR_INVALID_NAME = 123;

type
  TKindAttrTag = record
    Attributes: LongWord;
    ReparseTag: LongWord;
  end;

function KindBadHandle: THandle; inline;
begin
  Result := not THandle(0);
end;

{ UTF-16 to the engine's UTF-8; False when it holds an unpaired surrogate,
  which no UTF-8 can spell -- such a name could be shown but not used. }
function KindToUtf8(const W: UnicodeString; out S: String): Boolean;
var i, n: Integer; c: Word;
begin
  S := '';
  n := Length(W);
  i := 1;
  while i <= n do
  begin
    c := Word(W[i]);
    if (c >= $D800) and (c <= $DBFF) then
    begin
      if (i = n) or (Word(W[i + 1]) < $DC00) or (Word(W[i + 1]) > $DFFF) then Exit(False);
      Inc(i);
    end
    else if (c >= $DC00) and (c <= $DFFF) then
      Exit(False);
    Inc(i);
  end;
  S := UTF8Encode(W);
  Result := True;
end;

{ The full path as WINDOWS makes it -- the same call CreateFileW makes on the
  name, which is why its answer, and not the spelling, is judged: it drops a
  trailing dot or space and turns a reserved device name into \\.\NAME. }
function KindFullW(const APath: String): UnicodeString;
var w: UnicodeString; n: LongWord;
begin
  Result := '';
  w := UTF8Decode(APath);
  if w = '' then Exit;
  SetLength(Result, 1024);
  n := KindGetFullPathNameW(PWideChar(w), Length(Result), PWideChar(Result), nil);
  if n >= LongWord(Length(Result)) then
  begin
    SetLength(Result, n + 1);
    n := KindGetFullPathNameW(PWideChar(w), Length(Result), PWideChar(Result), nil);
  end;
  if (n = 0) or (n >= LongWord(Length(Result))) then Exit('');
  SetLength(Result, n);
end;

{ Where the path proper starts, past \\?\ or \\.\ , UNC\ , a drive's X: and a
  UNC server -- so that a ':' after it can only be a stream's. }
function KindBodyStart(const W: UnicodeString): Integer;
var i: Integer;
begin
  i := 1;
  if (Length(W) >= 4) and (W[1] = '\') and (W[2] = '\') and ((W[3] = '?') or (W[3] = '.')) and (W[4] = '\') then
  begin
    i := 5;
    if (Length(W) >= i + 3) and (UpCase(W[i]) = 'U') and (UpCase(W[i + 1]) = 'N') and
       (UpCase(W[i + 2]) = 'C') and (W[i + 3] = '\') then Exit(i + 4);
  end
  else if (Length(W) >= 2) and (W[1] = '\') and (W[2] = '\') then
    Exit(3);
  if (Length(W) >= i + 1) and (W[i + 1] = ':') and
     (((W[i] >= 'A') and (W[i] <= 'Z')) or ((W[i] >= 'a') and (W[i] <= 'z'))) then
    Inc(i, 2);
  Result := i;
end;

function KindIsStream(const W: UnicodeString): Boolean;
var i: Integer;
begin
  for i := KindBodyStart(W) to Length(W) do
    if W[i] = ':' then Exit(True);
  Result := False;
end;

{ A device by its full name: \\.\ and not \\.\X:\ (a drive spelled the device
  way, which names files). 1 a device, 2 a pipe, 0 neither. }
function KindDevice(const W: UnicodeString): Integer;
begin
  Result := 0;
  if not ((Length(W) >= 4) and (W[1] = '\') and (W[2] = '\') and (W[3] = '.') and (W[4] = '\')) then Exit;
  if (Length(W) >= 6) and (W[6] = ':') then Exit;
  if (Length(W) >= 9) and (LowerCase(String(Copy(W, 5, 5))) = 'pipe\') then Exit(2);
  Result := 1;
end;

{ The final name of an open handle, without the \\?\ the call prefixes. }
function KindFinalName(H: THandle; out S: String): Boolean;
var buf: UnicodeString; n: LongWord;
begin
  S := '';
  SetLength(buf, 1024);
  n := KindGetFinalPathNameByHandleW(H, PWideChar(buf), Length(buf), 0);
  if n >= LongWord(Length(buf)) then
  begin
    SetLength(buf, n + 1);
    n := KindGetFinalPathNameByHandleW(H, PWideChar(buf), Length(buf), 0);
  end;
  if (n = 0) or (n >= LongWord(Length(buf))) then Exit(False);
  SetLength(buf, n);
  if Copy(buf, 1, 8) = '\\?\UNC\' then buf := '\\' + Copy(buf, 9, MaxInt)
  else if Copy(buf, 1, 4) = '\\?\' then buf := Copy(buf, 5, MaxInt);
  Result := KindToUtf8(buf, S);
end;

{ What the entry at APath is, on Windows. Asks the gate itself: a helper that
  probes the filesystem is not trusted to its callers (check-sandbox.py). }
function KindOfWin(const APath: String; var AErr: TPhosphorError): String;
var w: UnicodeString; h: THandle; t, attr, e: LongWord; info: TKindAttrTag; dev: Integer;
begin
  Result := '';
  if not (IoGateAt(APath, puRead, BudgetMilliOs) or GateRefused('file_kind$', AErr)) then Exit;
  w := KindFullW(APath);
  if w = '' then Exit;
  dev := KindDevice(w);
  if dev = 2 then Exit('fifo');
  if dev = 1 then Exit('device');
  if KindIsStream(w) then Exit('stream');
  h := KindCreateFileW(PWideChar(w), 0, KIND_SHARE_ALL, nil, KIND_OPEN_EXISTING,
                       KIND_BACKUP_SEMANTICS or KIND_OPEN_REPARSE_POINT, 0);
  if h = KindBadHandle() then
  begin
    e := KindGetLastError();
    attr := KindGetFileAttributesW(PWideChar(w));
    if attr = KIND_NO_ATTR then
    begin
      if (e = KIND_ERR_NOT_FOUND) or (e = KIND_ERR_PATH_NOT_FOUND) or (e = KIND_ERR_INVALID_NAME) then
        Exit('none');
      Exit('');
    end;
    // There, and held so that not even a handle with no access opens (a
    // paging file): the attributes still say what it is, the tag is unread.
    if (attr and KIND_ATTR_REPARSE) <> 0 then Exit('link');
    if (attr and KIND_ATTR_DIR) <> 0 then Exit('dir');
    Exit('file');
  end;
  try
    t := KindGetFileType(h);
    FillChar(info, SizeOf(info), 0);
    if not KindGetFileInformationByHandleEx(h, KIND_ATTR_TAG_INFO, @info, SizeOf(info)) then
      info.Attributes := KindGetFileAttributesW(PWideChar(w));
  finally
    KindCloseHandle(h);
  end;
  if t = KIND_TYPE_CHAR then Exit('device');
  if t = KIND_TYPE_PIPE then Exit('fifo');
  if t <> KIND_TYPE_DISK then Exit('');
  if info.Attributes = KIND_NO_ATTR then Exit('');
  if (info.Attributes and KIND_ATTR_REPARSE) <> 0 then
  begin
    if (info.ReparseTag and KIND_TAG_SURROGATE) <> 0 then Exit('link');
    if info.ReparseTag = KIND_TAG_AF_UNIX then Exit('socket');
  end;
  if (info.Attributes and KIND_ATTR_DIR) <> 0 then Exit('dir');
  Result := 'file';
end;

{ The final name of an EXISTING entry, through any links: "" when it cannot
  be opened (a link that leads nowhere, a file held exclusively) or is no file
  on a disk. ADirOnly: answer only for a directory. }
function KindOpenFinal(const W: UnicodeString; ADirOnly: Boolean; out S: String; out AErr: LongWord): Boolean;
var h: THandle; info: TKindAttrTag;
begin
  S := '';
  Result := False;
  h := KindCreateFileW(PWideChar(W), 0, KIND_SHARE_ALL, nil, KIND_OPEN_EXISTING, KIND_BACKUP_SEMANTICS, 0);
  if h = KindBadHandle() then
  begin
    AErr := KindGetLastError();
    Exit;
  end;
  AErr := 0;
  try
    if KindGetFileType(h) <> KIND_TYPE_DISK then Exit;
    if ADirOnly then
    begin
      FillChar(info, SizeOf(info), 0);
      if not KindGetFileInformationByHandleEx(h, KIND_ATTR_TAG_INFO, @info, SizeOf(info)) then Exit;
      if (info.Attributes and KIND_ATTR_DIR) = 0 then Exit;
    end;
    Result := KindFinalName(h, S);
  finally
    KindCloseHandle(h);
  end;
end;

function CanonicalWin(const APath: String; var AErr: TPhosphorError): String;
var w, parent, leaf: UnicodeString; s, ls: String; e: LongWord; i, sep: Integer;
begin
  Result := '';
  if not (IoGateAt(APath, puRead, BudgetMilliOs) or GateRefused('path_canonical$', AErr)) then Exit;
  w := KindFullW(APath);
  if (w = '') or (KindDevice(w) <> 0) or KindIsStream(w) then Exit;
  if KindOpenFinal(w, False, s, e) then Exit(s);
  if e <> KIND_ERR_NOT_FOUND then Exit;
  // Nothing opened. An ENTRY there that cannot be opened is a link to
  // nothing -- or a link onto a journal's name, LONGLI~1.DAT -- and has no
  // canonical name: answering the parent plus the leaf would name the link,
  // and SQLite writes where it leads.
  if KindGetFileAttributesW(PWideChar(w)) <> KIND_NO_ATTR then Exit;
  sep := 0;
  for i := Length(w) downto KindBodyStart(w) do
    if (w[i] = '\') or (w[i] = '/') then begin sep := i; Break; end;
  if sep = 0 then Exit;
  leaf := Copy(w, sep + 1, MaxInt);
  if (leaf = '') or (leaf = '.') or (leaf = '..') then Exit;
  parent := Copy(w, 1, sep);
  if not KindOpenFinal(parent, True, s, e) then Exit;
  if not KindToUtf8(leaf, ls) then Exit;
  if (s <> '') and (s[Length(s)] = '\') then Result := s + ls
  else Result := s + '\' + ls;
end;
{$ENDIF}

{$IFNDEF WINDOWS}
const
  KIND_LINK_ATTR = $400;      // faSymLink, spelled out: it carries `platform`
  KIND_SPECIAL_ATTR = $04;    // faSysFile: a FIFO, a device or a socket
  KIND_ENOENT = 2;
  KIND_ENOTDIR = 20;

{ What the entry at APath is, on Unix: lstat, through FileGetAttr (which is
  FpLStat there, rtl/unix/sysutils.pp), and for a special file its mode, from
  FindFirst asked to lstat (faSymLink in the search attributes). }
function KindOfUnix(const APath: String; var AErr: TPhosphorError): String;
var a, e: LongInt; sr: TSearchRec; want: String; exact: Boolean; m: LongInt;
begin
  Result := '';
  if not (IoGateAt(APath, puRead, BudgetMilliOs) or GateRefused('file_kind$', AErr)) then Exit;
  a := FileGetAttr(APath);
  if a = -1 then
  begin
    e := GetLastOSError();
    if (e = KIND_ENOENT) or (e = KIND_ENOTDIR) then Exit('none');
    Exit('');
  end;
  if (a and KIND_LINK_ATTR) <> 0 then Exit('link');
  if (a and faDirectory) <> 0 then Exit('dir');
  if (a and KIND_SPECIAL_ATTR) = 0 then Exit('file');
  // A name may hold '*' or '?' on Unix, and FindFirst would read them as a
  // pattern: the entries it walks are steps, as in the listings.
  want := ExtractFileName(APath);
  exact := (Pos('*', want) > 0) or (Pos('?', want) > 0);
  m := -1;
  if FindFirst(APath, faAnyFile or KIND_LINK_ATTR, sr) = 0 then
  try
    repeat
      if exact and not BudgetCharge(BudgetUnitsPerStep) then
      begin
        AErr := BudgetRefusal('file_kind$');
        Exit('');
      end;
      if exact and (sr.Name <> want) then Continue;
      m := sr.Mode and $F000;
      Break;
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
  case m of
    $1000: Result := 'fifo';
    $2000, $6000: Result := 'device';
    $C000: Result := 'socket';
    $8000: Result := 'file';
    $4000: Result := 'dir';
  else
    Result := '';
  end;
end;

{ realpath, written out: every component in turn, a link read and its target
  put in front of what is left (from the root when it is absolute), at most 40
  links (the kernel's own MAXSYMLINKS). The LAST component alone may be
  missing: then it is joined as given to its resolved folder. Each component
  is a step, charged like a directory entry. }
function CanonicalUnix(const APath: String; var AErr: TPhosphorError): String;
var
  rest, comp, cur, cand: String;
  target: RawByteString;   // the signature FileGetSymLinkTarget takes by var
  hops, a, p: LongInt;
  isLast: Boolean;
begin
  Result := '';
  if not (IoGateAt(APath, puRead, BudgetMilliOs) or GateRefused('path_canonical$', AErr)) then Exit;
  if APath[1] = '/' then
  begin
    cur := '/';
    rest := Copy(APath, 2, MaxInt);
  end
  else
  begin
    cur := GetCurrentDir();
    if (cur = '') or (cur[1] <> '/') then Exit;
    rest := APath;
  end;
  hops := 0;
  while rest <> '' do
  begin
    if not BudgetCharge(BudgetUnitsPerStep) then
    begin
      AErr := BudgetRefusal('path_canonical$');
      Exit('');
    end;
    p := Pos('/', rest);
    if p = 0 then
    begin
      comp := rest;
      rest := '';
    end
    else
    begin
      comp := Copy(rest, 1, p - 1);
      rest := Copy(rest, p + 1, MaxInt);
    end;
    if (comp = '') or (comp = '.') then Continue;
    if comp = '..' then
    begin
      p := Length(cur);
      while (p > 1) and (cur[p] <> '/') do Dec(p);
      cur := Copy(cur, 1, p);
      if (Length(cur) > 1) and (cur[Length(cur)] = '/') then SetLength(cur, Length(cur) - 1);
      Continue;
    end;
    if cur = '/' then cand := '/' + comp else cand := cur + '/' + comp;
    isLast := rest = '';
    a := FileGetAttr(cand);
    if a = -1 then
    begin
      // Missing: an answer only for the last component, with no '/' after
      // it (which would ask for a folder that is not there).
      if isLast and (p = 0) and (GetLastOSError() = KIND_ENOENT) then Exit(cand);
      Exit('');
    end;
    if (a and KIND_LINK_ATTR) <> 0 then
    begin
      Inc(hops);
      if hops > 40 then Exit('');
      target := '';
      try
        // It raises when the link leads nowhere (it stats the target):
        // a dangling link has no canonical name.
        if not FileGetSymLinkTarget(RawByteString(cand), target) then Exit('');
      except
        Exit('');
      end;
      if target = '' then Exit('');
      if target[1] = '/' then cur := '/';
      if rest = '' then rest := String(target) else rest := String(target) + '/' + rest;
      Continue;
    end;
    if (not isLast) and ((a and faDirectory) = 0) then Exit('');
    cur := cand;
  end;
  Result := cur;
end;
{$ENDIF}

{ The empty name names nothing, on every system and under any sandbox: it is
  answered before the gate, which refuses "" as a path (it would be the
  working directory to a call that resolves it). }
function t_file_kind(const Args: array of TValue; out Err: TPhosphorError): TValue;
var k: String;
begin
  Err := NoError();
  if Args[0].Str = '' then
  begin
    GIoError := 0;
    Exit(ValStr('none'));
  end;
  GIoError := 0;   // so a refusal's 5 below is this call's, not an earlier one's
  {$IFDEF WINDOWS}
  k := KindOfWin(Args[0].Str, Err);
  {$ELSE}
  k := KindOfUnix(Args[0].Str, Err);
  {$ENDIF}
  if k <> '' then GIoError := 0
  else if GIoError <> IOERR_REFUSED then GIoError := IOERR_FAILED;
  Result := ValStr(k);
end;

function t_path_canonical(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: String;
begin
  Err := NoError();
  if Args[0].Str = '' then
  begin
    GIoError := IOERR_FAILED;
    Exit(ValStr(''));
  end;
  GIoError := 0;
  {$IFDEF WINDOWS}
  c := CanonicalWin(Args[0].Str, Err);
  {$ELSE}
  c := CanonicalUnix(Args[0].Str, Err);
  {$ENDIF}
  if c <> '' then GIoError := 0
  else if GIoError <> IOERR_REFUSED then GIoError := IOERR_FAILED;
  Result := ValStr(c);
end;

procedure RegisterIoFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('dir_create:$',            @t_dir_create);
  Reg.Add('dir_isempty:$',           @t_dir_isempty);
  Reg.Add('dir_delete:$',            @t_dir_delete);
  Reg.Add('dir_delete:$n',           @t_dir_delete);
  Reg.Add('dir_getfiles$:$',         @t_dir_getfiles);
  Reg.Add('dir_getfiles$:$$',        @t_dir_getfiles);
  Reg.Add('dir_getfiles$:$$n',       @t_dir_getfiles);
  Reg.Add('dir_getdirectories$:$',   @t_dir_getdirectories);
  Reg.Add('dir_getdirectories$:$$',  @t_dir_getdirectories);
  Reg.Add('dir_getdirectories$:$$n', @t_dir_getdirectories);
  Reg.Add('dir_getentries$:$',       @t_dir_getentries);
  Reg.Add('dir_getentries$:$$',      @t_dir_getentries);
  Reg.Add('dir_getparent$:$',        @t_dir_getparent);
  Reg.Add('dir_isrelativepath:$',    @t_dir_isrelativepath);
  Reg.Add('dir_getcurrent$:',        @t_dir_getcurrent);
  Reg.Add('dir_setcurrent:$',        @t_dir_setcurrent);
  Reg.Add('dir_copy:$$',             @t_dir_copy);
  Reg.Add('dir_move:$$',             @t_dir_move);
  Reg.Add('dir_setcreationtime:$n',  @t_dir_settime_c);
  Reg.Add('dir_getcreationtime:$',   @t_dir_gettime_c);
  Reg.Add('dir_setlastwritetime:$n', @t_dir_settime_w);
  Reg.Add('dir_getlastwritetime:$',  @t_dir_gettime_w);
  Reg.Add('dir_setlastaccesstime:$n',@t_dir_settime_a);
  Reg.Add('dir_getlastaccesstime:$', @t_dir_gettime_a);
  Reg.Add('file_copy:$$',            @t_file_copy);
  Reg.Add('file_copy:$$n',           @t_file_copy);
  Reg.Add('file_move:$$',            @t_file_move);
  Reg.Add('file_createempty:$',      @t_file_createempty);
  Reg.Add('file_getsize:$',          @t_file_getsize);
  Reg.Add('file_appendalltext:$$',   @t_file_appendalltext);
  Reg.Add('file_readallbytes@:$',    @t_file_readallbytes);
  Reg.Add('file_writeallbytes:$@',   @t_file_writeallbytes);
  Reg.Add('file_setcreationtime:$n', @t_file_settime);
  Reg.Add('file_getcreationtime:$',  @t_file_gettime);
  Reg.Add('file_setlastwritetime:$n',@t_file_settime);
  Reg.Add('file_getlastwritetime:$', @t_file_gettime);
  Reg.Add('file_setlastaccesstime:$n',@t_file_settime);
  Reg.Add('file_getlastaccesstime:$',@t_file_gettime);
  Reg.Add('path_combine$:$$',        @t_path_combine);
  Reg.Add('path_combine$:$$$',       @t_path_combine);
  Reg.Add('path_getdirectoryname$:$',@t_path_getdirectoryname);
  Reg.Add('path_hasextension:$',     @t_path_hasextension);
  Reg.Add('path_getfullpath$:$',     @t_path_getfullpath);
  Reg.Add('path_ispathrooted:$',     @t_path_ispathrooted);
  Reg.Add('path_isrelativepath:$',   @t_path_isrelativepath);
  Reg.Add('path_getpathroot$:$',     @t_path_getpathroot);
  Reg.Add('path_matchespattern:$$',  @t_path_matchespattern);
  Reg.Add('path_matchespattern:$$n', @t_path_matchespattern);
  Reg.Add('path_hasvalidpathchars:$',@t_path_hasvalidpathchars);
  Reg.Add('path_hasvalidfilenamechars:$', @t_path_hasvalidfilenamechars);
  Reg.Add('ioerror:',                @t_ioerror);
  Reg.Add('iostrerror$:',            @t_iostrerror);

  Reg.Add('file_writealltext:$$',        @t_file_writealltext);
  Reg.Add('file_readalltext$:$',         @t_file_readalltext);
  Reg.Add('file_exists:$',               @t_file_exists);
  Reg.Add('file_delete:$',               @t_file_delete);
  Reg.Add('savetext$:$$$',               @t_savetext);
  Reg.Add('opentext$:$$',                @t_opentext);
  Reg.Add('path_getfilename$:$',         @t_path_getfilename);
  Reg.Add('path_getextension$:$',        @t_path_getextension);
  Reg.Add('path_getfilenamenoext$:$',    @t_path_getfilenamenoext);
  Reg.Add('path_changeextension$:$$',    @t_path_changeextension);
  // extractfile* are the SysLib spelling of the same string surgery (both take
  // '/' and '\'); extractfilepath$ keeps the trailing separator.
  Reg.Add('extractfilename$:$',          @t_path_getfilename);
  Reg.Add('extractfileext$:$',           @t_path_getextension);
  Reg.Add('extractfilepath$:$',          @t_extractfilepath);
  Reg.Add('changefileext$:$$',           @t_path_changeextension);
  Reg.Add('dir_exists:$',                @t_dir_exists);
  // round 10: what a path IS, asked of the OS rather than read off its spelling
  Reg.Add('file_kind$:$',                @t_file_kind);
  Reg.Add('path_canonical$:$',           @t_path_canonical);
end;

initialization
  GDirTimes := TStringList.Create();

finalization
  GDirTimes.Free;

end.
