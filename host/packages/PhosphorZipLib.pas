{******************************************************************************
  Phosphor BASIC -- zip archives (an OPT-IN host package)

  MIT License. Copyright (c) 2026 Andre Murta.

  An opt-in package (host/packages/, RegisterZipFuncs) over FPC's paszlib zipper
  (TZipper/TUnZipper), which ships with the compiler -- no external runtime
  library. The engine stays free of it; a host that wants archives registers it.

  Two surfaces sit side by side:

  Whole-archive (one call each), unchanged:
    zip_compress(zip$, srcdir$)     zip the files directly in srcdir     -> 1/0
    unzip_extract(zip$, destdir$)   extract the whole archive            -> 1/0
    unzip_count(zip$)               number of entries
    unzip_entry$(zip$, n)           the n-th entry name (1-based)

  Handle-based (create/open, add, inspect, extract):
    zip_create@(zip$)               open a new archive for writing      -> handle
    zip_addfile(z@, disk$, name$)   add a file under an archive name     -> 1/0
    zip_addstr(z@, text$, name$)    add an entry from a string           -> 1/0
    zip_open@(zip$)                 open an existing archive for reading -> handle
    zip_count(z@)                   entry count
    zip_exists(z@, name$)           whether an entry is present          -> 1/0
    zip_read$(z@, name$)            an entry's content, in memory
    zip_entrysize(z@, name$)        an entry's uncompressed size
    zip_list$(z@)                   the entry names, newline-joined
    zip_extract(z@, name$, dir$)    extract ONE entry under a directory  -> 1/0
    zip_extractall(z@, dir$)        extract every entry under a directory-> 1/0
    zip_close(z@)                   flush (a writer) / release and free  -> 1/0
    zip_quick(src$, zip$)           archive one file by its bare name    -> 1/0
    zip_error()                     code of the most recent zip op (0 = clear)

  Failures are answered (0 / "" / false) and recorded in zip_error(), never
  raised, matching the engine's I/O contract.

  THE ONE DELIBERATE EXCEPTION IS A HOSTILE ARCHIVE. The three extractors RAISE
  rather than answer when they refuse an archive outright -- an entry name that
  escapes the destination, two headers that spell one entry two different ways,
  an entry that is a symbolic link, two entries that share or overlap one
  stretch of the archive, or two entries under one name -- because a refusal
  answered as 0 reads like an ordinary failure and a caller that ignores it
  goes on believing the archive was merely empty. zip_read$ raises for the last
  two as well: they decide which bytes it answers, where the others decide a
  path on disk, which it never writes. An archive that could not be READ is not
  in that class: a deleted, renamed or locked file is an ordinary failure and is
  still answered 0 with zip_error() = 1, and so is an entry whose CRC-32 does
  not match its bytes, stored or deflated -- the archive is damaged, not lying.
******************************************************************************}
unit PhosphorZipLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Zipper,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles, PhosphorSandbox,
  PhosphorBudget;

procedure RegisterZipFuncs(Reg: TPhosphorRegistry);

implementation

var
  ZipErr: Integer = 0;   // 0 = the last zip op was clean; 1 = it failed
  Crc32Table: array[0..255] of Cardinal;   // filled by BuildCrc32Table, at load

type
  { A JUDGEMENT ABOUT THE ARCHIVE, not a failure to read it. Raised from inside
    an extraction when the archive it actually reads -- the directory paszlib
    re-reads at the start of every extraction, over the stream it extracts from
    -- is one this library refuses. Every caller turns it into the
    'archive refused: ...' error, which a script sees as a raise. }
  EZipRefused = class(Exception);

  TGuardedInput = class;
  { Raised by a constructor the sandbox refused. A named class rather than a bare
    Exception so the reason survives into any handler that cares to look, and so
    a reader of the raise line does not have to guess why a zip constructor is
    throwing. Every caller in this unit already turns an exception into
    ZipErr := 1 and a zero handle, which is the refusal the script sees. }
  EPhosphorZipRefused = class(Exception);

  { AN UNZIPPER THAT CHARGES WHAT IT WRITES (ledger d46, d47).

    Every expansion used to be priced from the archive's CENTRAL DIRECTORY --
    ArchiveFitsBudget, or BudgetAllows(Entries[i].Size) -- which is the archive's
    own claim about itself. The inflate loop (TInflater.DeCompress, zipper.pp)
    reads until the DEFLATE stream ends, whatever the directory said, so an entry
    that declares one byte expands to whatever it really holds: the guard checked
    a different copy of the value than the one that acts (d46). And two of the
    three extractors, zip_extract and zip_extractall, asked nothing at all, which
    check-budget.py could not see because they reach the unzipper through a field
    (d47).

    So the meter is in the TYPE, not at the doors. OnProgressEx reports the real
    output position as the inflate goes; every byte past the last report is
    charged, and when the budget refuses, Terminate stops the inflate loop. A
    stopped entry then fails its CRC check and raises, which every caller already
    turns into a failure -- Spent is what tells that failure apart as a refusal.
    UnZipAllFiles is virtual, and UnZipFiles calls it, so the reset at the top of
    each extraction cannot be skipped by a door that forgets it.

    THE PARTIAL FILE IS REMOVED. A refusal mid-entry leaves a file that was opened
    with fmCreate and holds only what fitted; the unzipper names it in OnStartFile
    and this deletes exactly that file -- never a directory, never anything
    recursive, and never in the in-memory mode zip_read$ uses, where there is no
    file. Its path was already judged by ArchiveIsSafe and
    ArchiveLocalNamesAreSafe and sits under a destination the sandbox allowed.
    Entries that finished before the refusal stay, and the docs say so.

    A STORED ENTRY IS CHARGED TOO, AND CHECKED (2026-10-09). This comment used to
    say a stored entry "cannot amplify -- it copies only bytes the archive already
    holds on disk". False: paszlib's method-0 branch (UnZipOneFile's DoUnzip) is
    one Dest.CopyFrom(FZipStream, LocalHdr.Compressed_Size), sized from the LOCAL
    header and reporting no progress, so nothing here saw it -- and nothing stops
    three hundred central records from pointing at ONE local header. A 1 MiB
    archive declaring size 0 three hundred times copied 300 MiB under a budget
    that refuses string$(300000000). The same branch carries paszlib's
    "TODO: Implement CRC Check", so a stored entry whose bytes did not match its
    CRC-32 came back as clean data while a deflated one was refused.
    So the archive is read through TGuardedInput, which this unzipper hands
    paszlib as its input stream, and for a stored entry it is ARMED at the byte
    where the entry's data begins: every read from there on is charged before it
    happens and run through the CRC register, and the register is compared with
    the entry's CRC-32 when the copy ends -- a mismatch raises exactly the error
    paszlib raises for a deflated one. The bytes charged are the bytes copied,
    whatever any header declared.

    THE ARCHIVE IS JUDGED WHERE IT IS READ. Every extraction begins with paszlib
    RE-READING the central directory (UnZipAllFiles -> ReadZipDirectory clears
    Entries and fills it again), so a judgement made on the entries Examine read
    earlier is a judgement about a different copy -- a file swapped between
    zip_open@ and zip_extract is extracted from its new directory. The first
    UnZipOneFile of every extraction therefore judges the entries just read,
    over the very stream being extracted from (JudgeArchive), before any output
    is opened: overlapping or shared local headers and repeated names always,
    and, when writing to disk, the name, local-header and link rules the
    extractors also ask up front.

    AN ENTRY IS CHOSEN BY ITS BYTES. paszlib's own filter (Files, matched by
    IsMatch) is a sorted TStringList, and a TStringList compares
    CASE-INSENSITIVELY by default: zip_read$(r@, "a.txt") read "A.TXT" as well,
    kept the last, leaked the first, and answered content for a name zip_exists
    calls absent. ExtractOnly filters here, byte for byte, and UnZipAllFiles
    refuses a non-empty Files so no door can reach the other filter. }
  TMeteredUnZipper = class(TUnZipper)
  private
    FCharged: Int64;     // output already charged in this extraction
    FPartial: String;    // the disk file being written now; '' between entries
    FInput: TGuardedInput;  // the stream paszlib reads; nil outside an open input
    FJudged: Boolean;    // this extraction's directory has been judged
    FWanted: RawByteString;
    FHasWanted: Boolean; // extract only the entry named FWanted, by its bytes
    procedure Meter(Sender: TObject; const ATotPos, ATotSize: Int64);
    procedure Started(Sender: TObject; const AFileName: String);
    procedure OpenIn(Sender: TObject; var AStream: TStream);
    procedure CloseIn(Sender: TObject; var AStream: TStream);
  protected
    procedure UnZipOneFile(Item: TFullZipFileEntry); override;
  public
    Spent: Boolean;      // this extraction was stopped by the execution budget
    constructor Create;
    procedure UnZipAllFiles; override;
    function ChargeCopy(N: Int64): Boolean;
    procedure ExtractOnly(const AName: RawByteString);
    procedure ExtractEvery;
  end;

  { THE INPUT STREAM, WITH A METER THAT CAN BE ARMED. Everything paszlib reads
    from the archive comes through Read; while Armed, a read that BEGINS at or
    past DataStart is the stored copy -- the header parse that precedes it only
    ever begins a read before that byte -- and is charged, then folded into Crc.
    FPos is tracked here rather than asked of the file, which would be a seek
    system call on every one of the small reads a directory is made of. }
  TGuardedInput = class(TStream)
  private
    FInner: TStream;
    FOwner: TMeteredUnZipper;
    FPos: Int64;
  protected
    function GetSize: Int64; override;
  public
    Armed: Boolean;
    DataStart: Int64;
    Crc: Cardinal;
    constructor Create(AInner: TStream; AOwner: TMeteredUnZipper);
    destructor Destroy; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

  { A write handle: a TZipper plus the in-memory streams that back its
    string entries. The streams must outlive the AddFileEntry call and stay
    alive until ZipAllFiles has read them, so the writer owns and frees them. }
  TZipWriter = class
    Z: TZipper;
    Owned: TList;
    constructor Create(const APath: String);
    destructor Destroy; override;
    procedure AddFile(const ADisk, AArchive: String);
    procedure AddStr(const AContent, AArchive: String);
    function Save: Boolean;
  end;

  { A read handle: a TUnZipper already Examined, so its entry list is ready to
    inspect. FScratch is used only during an in-memory ReadEntry. }
  TZipReader = class
    UZ: TMeteredUnZipper;
    FScratch: TMemoryStream;
    FSpent: Boolean;   // the last ReadEntry was refused by the execution budget
    constructor Create(const APath: String);
    destructor Destroy; override;
    function IndexOf(const AName: String): Integer;
    function ReadEntry(const AName: String; out AData: String): Boolean;
    procedure DoCreateStream(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
    procedure DoDoneStream(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
  end;

function JudgeArchive(AEntries: TFullZipFileEntries; AStream: TStream;
  AForDisk: Boolean; out AWhy: String): Boolean; forward;

{ Two names compared as BYTES, the order CompareStr would give but with no code
  page in the way: '=' on strings whose dynamic code pages differ converts them
  first, and an entry flagged UTF-8 carries a different one from the script's. }
function NameBytesCompare(const A, B: RawByteString): Integer;
var n: SizeInt;
begin
  n := Length(A);
  if Length(B) < n then n := Length(B);
  Result := 0;
  if n > 0 then Result := CompareByte(A[1], B[1], n);
  if Result = 0 then
    Result := Ord(Length(A) > Length(B)) - Ord(Length(A) < Length(B));
end;

{ CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320, initial and final value
  0xFFFFFFFF) -- the one PKWARE APPNOTE 4.4.7 names. Self-contained, like
  PhosphorGzipLib's: paszlib's crc32 is declared inline, and a call the compiler
  declines to inline is a note, which this tree's build treats as a defect. }
procedure BuildCrc32Table;
var i, k: Integer; c: Cardinal;
begin
  for i := 0 to 255 do
  begin
    c := Cardinal(i);
    for k := 1 to 8 do
      if (c and 1) <> 0 then c := (c shr 1) xor $EDB88320 else c := c shr 1;
    Crc32Table[i] := c;
  end;
end;

{ TGuardedInput }

constructor TGuardedInput.Create(AInner: TStream; AOwner: TMeteredUnZipper);
begin
  inherited Create();
  FInner := AInner;
  FOwner := AOwner;
  FPos := AInner.Position;
  Armed := False;
end;

destructor TGuardedInput.Destroy;
begin
  FInner.Free;
  inherited Destroy();
end;

function TGuardedInput.GetSize: Int64;
begin
  Result := FInner.Size;
end;

function TGuardedInput.Read(var Buffer; Count: Longint): Longint;
var i: Longint; p: PByte; c: Cardinal;
begin
  if Armed and (FPos >= DataStart) and (Count > 0) then
  begin
    // Charged BEFORE the read: a refusal copies nothing more. CopyFrom asks for
    // at most 128 KiB at a time, so a refused chunk is never read at all.
    if not FOwner.ChargeCopy(Count) then
      raise EZipError.Create('stopped by the execution budget');
    Result := FInner.Read(Buffer, Count);
    { The CRC-32 register over the bytes just read -- the ones charged above. The
      register starts at $FFFFFFFF (set where the guard is armed) and is
      inverted when the copy ends, so a copy read in pieces is one stream. }
    p := PByte(@Buffer);
    c := Crc;
    for i := 0 to Result - 1 do
      c := Crc32Table[(c xor p[i]) and $FF] xor (c shr 8);
    Crc := c;
  end
  else
    Result := FInner.Read(Buffer, Count);
  if Result > 0 then Inc(FPos, Result);
end;

function TGuardedInput.Write(const Buffer; Count: Longint): Longint;
begin
  Result := 0;
  raise EStreamError.Create('an archive being read is not written');
end;

function TGuardedInput.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  FPos := FInner.Seek(Offset, Origin);
  Result := FPos;
end;

{ TMeteredUnZipper }

constructor TMeteredUnZipper.Create;
begin
  inherited Create();
  OnProgressEx := @Meter;
  OnStartFile := @Started;
  OnOpenInputStream := @OpenIn;
  OnCloseInputStream := @CloseIn;
end;

{ THE ARCHIVE IS OPENED HERE, by path, so the gate is asked here -- the rule this
  unit carries is that the question belongs where the path is bound. Every door
  has already asked it about the same path; this is the line that opens it. }
procedure TMeteredUnZipper.OpenIn(Sender: TObject; var AStream: TStream);
begin
  if not SandboxAllows(FileName, puRead) then
    raise EPhosphorZipRefused.Create('refused: the archive is outside the sandbox root');
  FInput := TGuardedInput.Create(
    TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite), Self);
  AStream := FInput;
end;

procedure TMeteredUnZipper.CloseIn(Sender: TObject; var AStream: TStream);
begin
  // paszlib frees the stream itself right after this (CloseInput).
  FInput := nil;
end;

function TMeteredUnZipper.ChargeCopy(N: Int64): Boolean;
begin
  Result := False;
  if Spent then Exit;
  if not BudgetCharge(N) then
  begin
    Spent := True;
    Terminate();
    Exit;
  end;
  Result := True;
end;

procedure TMeteredUnZipper.ExtractOnly(const AName: RawByteString);
begin
  FWanted := AName;
  FHasWanted := True;
  try
    UnZipAllFiles();
  finally
    FHasWanted := False;
    FWanted := '';
  end;
end;

procedure TMeteredUnZipper.ExtractEvery;
begin
  FHasWanted := False;
  UnZipAllFiles();
end;

procedure TMeteredUnZipper.Meter(Sender: TObject; const ATotPos, ATotSize: Int64);
var delta: Int64;
begin
  // ATotPos is the output written so far in THIS extraction, across entries; it
  // only grows. Sender is the decompressor, or the unzipper itself at the end.
  delta := ATotPos - FCharged;
  if delta <= 0 then Exit;
  FCharged := ATotPos;
  if (not Spent) and (not BudgetCharge(delta)) then
  begin
    Spent := True;
    Terminate();
  end;
end;

procedure TMeteredUnZipper.Started(Sender: TObject; const AFileName: String);
begin
  // In-memory mode (OnCreateStream set) hands over a name that is no file at all.
  if Assigned(OnCreateStream) then FPartial := '' else FPartial := AFileName;
end;

procedure TMeteredUnZipper.UnZipOneFile(Item: TFullZipFileEntry);
var why: String; method: Word; stored: Boolean;
begin
  if not FJudged then
  begin
    // Before ANY entry is opened, so a refusal writes nothing at all. Asked even
    // when the wanted entry comes later: the judgement is about the archive.
    if not JudgeArchive(Entries, FInput, not Assigned(OnCreateStream), why) then
      raise EZipRefused.Create(why);
    FJudged := True;
  end;
  // Item.ArchiveFileName is still the CENTRAL name here -- the one paszlib's
  // IsMatch would have used, and the one every reader in this unit answers.
  if FHasWanted and (NameBytesCompare(Item.ArchiveFileName, FWanted) <> 0) then
    Exit;
  FPartial := '';
  { Where the data begins is where the LOCAL header ends, and only paszlib's own
    parse of that header knows where that is (an extra field can say anything).
    So its parse is run here first; inherited runs the same one again on the same
    bytes and lands on the same byte. It sets only fields of Item that it sets
    again, and the method it answers is the one inherited will act on. }
  ReadZipHeader(Item, method);
  stored := method = 0;
  if stored then
  begin
    FInput.DataStart := FInput.Position;
    FInput.Crc := $FFFFFFFF;
    FInput.Armed := True;
  end;
  try
    inherited UnZipOneFile(Item);
  finally
    if Assigned(FInput) then FInput.Armed := False;
  end;
  { The comparison paszlib makes for a deflated entry, against the same value:
    Item.CRC32 is the local header's CRC, or the central one when the local
    header carries none. The message is paszlib's SErrInvalidCRC without the
    name, which is attacker bytes. FPartial is still set, so UnZipAllFiles
    removes the file that holds the unchecked bytes. }
  if stored and ((FInput.Crc xor $FFFFFFFF) <> Item.CRC32) then
    raise EZipError.Create('Invalid CRC checksum while unzipping a stored entry');
  FPartial := '';            // this entry finished; it is not a partial any more
end;

procedure TMeteredUnZipper.UnZipAllFiles;
begin
  // The one filter is ExtractOnly's. paszlib's Files filter matches names
  // case-insensitively, so a door that filled it would choose entries by a rule
  // no reader here answers by.
  if Files.Count > 0 then
    raise EZipError.Create('internal: extract through ExtractOnly, not Files');
  FCharged := 0;
  FPartial := '';
  FJudged := False;
  Spent := False;
  try
    inherited UnZipAllFiles();
  except
    { One file, the one opened for the entry that failed -- stopped by the budget,
      or failing its CRC-32, stored or deflated. Either way what it holds is not
      the entry, and a caller told 0 must not find it on disk looking like one.
      fmCreate already replaced whatever stood at that path. Asked about like any
      other path this unit touches, though the extractor already had to be. }
    if (FPartial <> '') and SandboxAllows(FPartial, puWrite) then
      DeleteFile(FPartial);
    FPartial := '';
    raise;
  end;
  // The last charge can be refused at the END of an entry, after its bytes are
  // complete and its CRC has passed: nothing raised, but the loop stopped before
  // the next entry. It is still a refusal, and it must not read as success.
  if Spent then
    raise EZipError.Create('stopped by the execution budget');
end;

{ TZipWriter }

{ AN ENTRY NAME MAY NOT BE EMPTY, and the refusal belongs at the ADD -- the same
  rule, and the same reason, as the missing-file check in AddFile below.

  A stream entry with an empty archive name is one TZipper cannot write, and it
  says so at the LAST possible moment. TZipper.SaveToFile opens the output with
  fmCreate -- which truncates whatever archive was already at that path to 0
  bytes -- and only then calls SaveToStream, which calls GetFileInfo, which
  raises SErrMissingArchiveName for the entry. So the add answered 1, the caller
  carried on adding, and zip_close destroyed the whole archive: every good entry
  in it, and the file that stood there before, left behind as 0 bytes that this
  package's own reader calls corrupt.

  Only the EMPTY name does this. TZipFileEntry.GetArchiveFileName falls back to
  the DISK file name when the archive name is empty, so an empty name is fatal
  exactly when there is no disk name to fall back on -- a string entry. It is
  refused for zip_addfile too, where it is not fatal but is still wrong: the
  entry would be stored under the source's full disk path, and SafeEntryName
  refuses an absolute name on the way out, so the archive would be one this
  library cannot extract.

  Deliberately NOT SafeEntryName: a '..' segment is a legal thing to WRITE into
  an archive -- tests/packages/09_safety.bas builds exactly that archive, the way
  an attacker would, to prove the extractor refuses it. An entry name is judged
  where it decides a path on disk, which is extraction. }
procedure CheckEntryName(const AWho, AArchive: String);
begin
  if AArchive = '' then
    raise EInOutError.Create(AWho + ': an entry name may not be empty');
end;

{ THE GUARD IS IN THE CONSTRUCTOR, where the file is actually bound, rather than
  only in the registered function that calls it -- so a caller added later is
  covered without anyone remembering. It RAISES rather than answering: a
  constructor has no way to say no, and every caller here already turns an
  exception into ZipErr := 1 and a zero handle, which is the refusal a script
  sees. }
constructor TZipWriter.Create(const APath: String);
begin
  if not SandboxAllows(APath, puWrite) then
    raise EPhosphorZipRefused.Create('refused: the path is outside the sandbox root');
  Z := TZipper.Create();
  Z.FileName := APath;
  Owned := TList.Create();
end;

destructor TZipWriter.Destroy;
var i: Integer;
begin
  for i := 0 to Owned.Count - 1 do
    TObject(Owned[i]).Free;
  Owned.Free;
  Z.Free;
  inherited Destroy();
end;

procedure TZipWriter.AddFile(const ADisk, AArchive: String);
begin
  // Checked HERE, at the call the program can still react to. AddFileEntry only
  // records a name: a missing file was reported as a successful add and only failed
  // later, inside zip_close, where it took the whole archive down with it and left
  // the writer handle leaked. The caller had already been told it worked.
  if not SandboxAllows(ADisk, puRead) then
    raise EInOutError.Create('zip_addfile: "' + ADisk + '" is outside the sandbox root');
  if not FileExists(ADisk) then
    raise EInOutError.Create('zip_addfile: "' + ADisk + '" does not exist');
  CheckEntryName('zip_addfile', AArchive);
  Z.Entries.AddFileEntry(ADisk, AArchive);
end;

procedure TZipWriter.AddStr(const AContent, AArchive: String);
var ms: TMemoryStream;
begin
  // Asked BEFORE the stream is made, so a refused add allocates nothing and
  // leaves the writer exactly as it was: the entries already in it still close.
  CheckEntryName('zip_addstr', AArchive);
  ms := TMemoryStream.Create();
  if Length(AContent) > 0 then ms.WriteBuffer(AContent[1], Length(AContent));
  ms.Position := 0;
  Owned.Add(ms);
  Z.Entries.AddFileEntry(ms, AArchive);
end;

{ AN ARCHIVE WITH NO ENTRIES IS NOT A FILE THIS LIBRARY CAN WRITE, so do not
  write one and do not claim to have. TZipper.SaveToStream returns at
  `If CheckEntries=0 then Exit` having written NOTHING -- but SaveToFile has
  already created the stream, so what reached disk was a 0-byte file that this
  package's own reader rejects (unzip_count answered 0 with zip_error()=1, which
  is how it reports a CORRUPT archive). Nor is a well-formed empty archive a way
  out: TUnZipper.FindEndHeaders uses offset 0 as its "no end-of-central-directory
  found" sentinel, so a bare 22-byte EOCD -- which begins at offset 0 -- is
  reported as corrupt too. There is no readable empty archive to hand back, so
  the honest answer is False, and no file at all. }
function TZipWriter.Save: Boolean;
begin
  Result := Z.Entries.Count > 0;
  if Result then Z.ZipAllFiles;
end;

{ TZipReader }

constructor TZipReader.Create(const APath: String);
begin
  if not SandboxAllows(APath, puRead) then
    raise EPhosphorZipRefused.Create('refused: the path is outside the sandbox root');
  UZ := TMeteredUnZipper.Create();
  UZ.FileName := APath;
  UZ.Examine;              // populates Entries; raises on a missing/corrupt file
  FScratch := nil;
end;

destructor TZipReader.Destroy;
begin
  FScratch.Free;
  UZ.Free;
  inherited Destroy();
end;

function TZipReader.IndexOf(const AName: String): Integer;
var i: Integer;
begin
  // By BYTES, the rule ExtractOnly selects by, so zip_exists, zip_entrysize and
  // the read that follows them can never disagree about which entry a name is.
  Result := -1;
  for i := 0 to UZ.Entries.Count - 1 do
    if NameBytesCompare(UZ.Entries[i].ArchiveFileName, AName) = 0 then
      Exit(i);
end;

procedure TZipReader.DoCreateStream(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
begin
  // One entry per read, now that names are matched exactly and an archive with a
  // name twice is refused -- but a second match would otherwise leak the first.
  FreeAndNil(FScratch);
  FScratch := TMemoryStream.Create();
  AStream := FScratch;
end;

procedure TZipReader.DoDoneStream(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
begin
  // Keep FScratch alive past CloseOutput (it nils the local reference for us).
  AStream.Position := 0;
end;

function TZipReader.ReadEntry(const AName: String; out AData: String): Boolean;
var idx: Integer;
begin
  Result := False;
  AData := '';
  FSpent := False;
  // One entry, one declared size, one RULE 1 question -- asked before UnZipFiles
  // is entered, so an archive that admits to being too big costs nothing. It is
  // only the FIRST answer: the declared size is the archive's claim, and the
  // metered unzipper charges what the entry really becomes (d46). FSpent tells
  // the caller that False here means "refused", not "no such entry".
  idx := IndexOf(AName);
  // A name the archive does not hold is answered here. It used to go on to
  // paszlib's filter, which matched it case-insensitively and read another entry.
  if idx < 0 then Exit(False);
  if not BudgetAllows(UZ.Entries[idx].Size) then
  begin
    FSpent := True;
    Exit(False);
  end;
  FreeAndNil(FScratch);
  UZ.OnCreateStream := @DoCreateStream;
  UZ.OnDoneStream := @DoDoneStream;
  try
    UZ.ExtractOnly(AName);
  except
    // A stopped or failed entry leaves FScratch holding what got out; it is not
    // an answer, and nothing else would free it before the next read.
    FreeAndNil(FScratch);
    UZ.OnCreateStream := nil;
    UZ.OnDoneStream := nil;
    if UZ.Spent then
    begin
      FSpent := True;
      Exit(False);
    end;
    raise;
  end;
  UZ.OnCreateStream := nil;
  UZ.OnDoneStream := nil;
  if Assigned(FScratch) then
  begin
    SetLength(AData, FScratch.Size);
    if FScratch.Size > 0 then
    begin
      FScratch.Position := 0;
      FScratch.ReadBuffer(AData[1], FScratch.Size);
    end;
    FreeAndNil(FScratch);
    Result := True;
  end;
end;

// --- handle helpers ---------------------------------------------------------
function GetWriter(AId: Int64; out AW: TZipWriter): Boolean;
var o: TObject;
begin
  o := HandleObj(AId);
  Result := o is TZipWriter;
  if Result then AW := TZipWriter(o) else AW := nil;
end;

function GetReader(AId: Int64; out AR: TZipReader): Boolean;
var o: TObject;
begin
  o := HandleObj(AId);
  Result := o is TZipReader;
  if Result then AR := TZipReader(o) else AR := nil;
end;

// --- whole-archive functions (unchanged) ------------------------------------
{ Byte-wise, case-sensitive: the same order on every filesystem. }
function CompareNameBytes(AList: TStringList; A, B: Integer): Integer;
begin
  Result := CompareStr(AList[A], AList[B]);
end;

function f_zip_compress(const Args: array of TValue; out Err: TPhosphorError): TValue;
var z: TZipper; sr: TSearchRec; base: String; names: TStringList; i: Integer;
begin
  Err := NoError();
  Result := ValInt(0);
  { TWO PATHS, SO TWO QUESTIONS, EACH WITH THE VERB ITS PATH DESERVES. Only
    Args[1], the source directory, was ever asked about. Args[0] is the archive
    this WRITES, and it went straight to TZipper.FileName -- so a run confined by
    --sandbox created a zip anywhere on the disk, and because SaveToFile opens
    the output with fmCreate, it did so ON TOP of whatever file was already
    there: an existing 30-byte document came back as a 153-byte archive.
    Asked before TZipper.Create, so a refusal constructs nothing.

    RECORDED, not just answered: the page promises "0 if srcdir$ is outside the
    sandbox root or anything fails, with zip_error() set to 1", and this exit
    left the slot reading clean. }
  if not SandboxAllows(Args[0].Str, puWrite) then begin ZipErr := 1; Exit(ValInt(0)); end;
  if not SandboxAllows(Args[1].Str, puRead) then begin ZipErr := 1; Exit(ValInt(0)); end;
  try
    z := TZipper.Create();
    try
      z.FileName := Args[0].Str;
      { A SOURCE DIRECTORY THAT IS NOT THERE IS A FAILURE, ANSWERED BEFORE ANY FILE
        IS MADE. FindFirst on a directory that does not exist simply matches
        nothing -- and so does FindFirst on a path naming a FILE -- so the entry
        list came out empty, ZipAllFiles was called on it anyway, and this
        answered 1 with zip_error() clear while leaving behind the 0-byte file
        TZipWriter.Save explains. A caller who mistyped the directory name was
        told the backup succeeded and handed an archive nothing can open. }
      if not DirectoryExists(Args[1].Str) then begin ZipErr := 1; Exit(ValInt(0)); end;
      base := IncludeTrailingPathDelimiter(Args[1].Str);
      // Collected, SORTED, then added. Entries went in in raw directory-enumeration
      // order, which NTFS and ext4 do not agree on, so the same folder produced
      // archives whose entries were in a different order on each platform -- and
      // unzip_entry$(z$, 1) answered a different file. A byte order is arbitrary,
      // but it is the same arbitrary order everywhere.
      names := TStringList.Create();
      try
        if FindFirst(base + '*', faAnyFile, sr) = 0 then
        try
          repeat
            // The same directory walk IoLib charges, and for the same reason: the
            // filesystem decides how many iterations this is, not the argument.
            if not BudgetCharge(BudgetUnitsPerStep) then
            begin
              Err := BudgetRefusal('zip_compress');
              FindClose(sr);
              names.Free;
              Exit(ValInt(0));
            end;
            if (sr.Attr and faDirectory) = 0 then names.Add(sr.Name);
          until FindNext(sr) <> 0;
        finally
          FindClose(sr);
        end;
        names.CustomSort(@CompareNameBytes);
        for i := 0 to names.Count - 1 do
        begin
          { ASKED AT EVERY LEVEL, NOT ONLY OF THE ARGUMENT.

            `base` was gated once, as a directory. Each CHILD is a distinct disk
            path handed to the RTL, and it is not an Args[i], so an enumeration
            that walks the handler's arguments is structurally blind to it -- the
            gate's own blind spot, one level down. A file symlink inside the
            directory pointing outside the root would have its TARGET's content
            read into the archive, and the script reads it back with zip_read$.

            This is the rule PhosphorIoLib already states twice, at CollectEntries
            and at DeleteTree: "re-asked at every level of the recursion". And
            zip_addfile gates the individual path already, so without this line
            adding one file was refused while archiving its parent succeeded. }
          if not SandboxAllows(base + names[i], puRead) then
          begin
            ZipErr := 1;
            names.Free;
            Exit(ValInt(0));
          end;
          z.Entries.AddFileEntry(base + names[i], names[i]);
        end;
      finally
        names.Free;
      end;
      // NOTHING TO ARCHIVE IS A FAILURE TOO, for the reason TZipWriter.Save
      // records: a zero-entry list produces a 0-byte file this package's own
      // reader calls corrupt, and paszlib cannot read a well-formed empty archive
      // back either. This is the same hole seen from the other side -- a directory
      // that is genuinely empty, and one holding only subdirectories, which this
      // function deliberately does not descend into.
      if z.Entries.Count = 0 then begin ZipErr := 1; Exit(ValInt(0)); end;
      z.ZipAllFiles;
      Result := ValInt(1);
      ZipErr := 0;
    finally
      z.Free;
    end;
  except
    Result := ValInt(0);
    ZipErr := 1;
  end;
end;

// --- extraction safety ------------------------------------------------------
{ An entry name decides where a byte lands on disk, and it comes from whoever built
  the archive. `../../../../etc/x` escapes the destination directory entirely -- the
  "zip slip" -- and so do an absolute path and a Windows drive letter.

  Rejected: an empty name, a name starting with '/' or '\', a name whose second
  character is ':' (a drive), and any name with a '..' PATH SEGMENT. A '..' inside a
  file name ("my..notes.txt") is fine and is not what this looks for. }
function SafeEntryName(const AName: String): Boolean;
var
  norm: String;
  i, segStart: Integer;

  function SegmentIsDotDot(AFrom, ATo: Integer): Boolean;
  begin
    Result := (ATo - AFrom = 2) and (norm[AFrom] = '.') and (norm[AFrom + 1] = '.');
  end;

begin
  Result := False;
  if AName = '' then Exit;
  norm := StringReplace(AName, '\', '/', [rfReplaceAll]);
  if norm[1] = '/' then Exit;                                   // absolute
  if (Length(norm) >= 2) and (norm[2] = ':') then Exit;         // drive letter
  segStart := 1;
  for i := 1 to Length(norm) + 1 do
    if (i = Length(norm) + 1) or (norm[i] = '/') then
    begin
      if SegmentIsDotDot(segStart, i) then Exit;
      segStart := i + 1;
    end;
  Result := True;
end;

{ True when every entry in an examined unzipper is safe to write. }
{ THE SIZE AN ARCHIVE DECLARES IT WILL BECOME. Examine has already read the
  central directory, so the total uncompressed size is known BEFORE a byte is
  written -- which turns the decompression bomb into a RULE 1 case after all:
  forty kilobytes that declare ten gigabytes are refused here rather than inside
  UnZipAllFiles writes anything.

  IT IS THE FIRST ANSWER, NOT THE LAST. This comment used to say that a lying
  archive "can only lie DOWNWARD into a smaller claim, and a smaller claim is the
  one this check would have let through anyway" -- which is true and is exactly
  the defect (ledger d46): a downward lie is LET THROUGH, and the inflate then
  reads until the stream ends, not until the claim is used up. The bytes that
  actually come out are charged by TMeteredUnZipper as they come out. This check
  stays because an honest archive that admits to being too big should be refused
  before a single file is created.

  AND THE SUM COUNTS EACH RECORD, NOT EACH STRETCH OF BYTES. Three hundred
  records that all point at one stored entry and each declare size 0 sum to 0
  here, and copied 300 MiB (2026-10-09). That shape is refused outright now
  (JudgeArchive: no two entries share or overlap one local header), and a stored
  copy is charged by what it copies, so neither half rests on this sum. }
function ArchiveFitsBudget(AUz: TUnZipper): Boolean;
var i: Integer; total: Int64;
begin
  total := 0;
  for i := 0 to AUz.Entries.Count - 1 do
    total := total + AUz.Entries[i].Size;
  Result := BudgetAllows(total);
end;

function ArchiveIsSafe(AUz: TUnZipper): Boolean;
var i: Integer;
begin
  Result := True;
  for i := 0 to AUz.Entries.Count - 1 do
    if not SafeEntryName(AUz.Entries[i].ArchiveFileName) then
      Exit(False);
end;

type
  { REACHES THE PROTECTED TZipFileEntry.HdrPos -- the offset of an entry's LOCAL
    FILE HEADER, which Examine has already taken from the central directory and
    corrected from a zip64 extra field (zipper.pp:2583, 2626). Nothing else in
    paszlib exposes it, and the check below needs exactly the offset
    TUnZipper.ReadZipHeader will seek to, not one of its own guessing.

    Derived from TFullZipFileEntry rather than from TZipFileEntry so the cast is
    a downcast between RELATED types: with the wider base FPC issues "Class types
    'TFullZipFileEntry' and '...' are not related", and a warning is a defect
    here. }
  TZipEntryCracker = class(TFullZipFileEntry);

{ THE NAME A ZIP ENTRY IS EXTRACTED UNDER IS NOT THE NAME IT ADVERTISES.

  ArchiveIsSafe above judges AUz.Entries[i].ArchiveFileName, which
  TUnZipper.Examine filled from the CENTRAL DIRECTORY (zipper.pp:2590).
  Extraction then re-reads the LOCAL FILE HEADER and OVERWRITES both names
  (zipper.pp:2317-2318, inside ReadZipHeader, which UnZipOneFile calls FIRST at
  2787); GetOutputFileName builds the path from Item.DiskFileName (2762) and
  FOutputPath (2782), and OpenOutput ForceDirectories that path and opens it with
  fmCreate (2255-2259). So the string that was judged is not the string that
  decides where the byte lands. An archive advertising `harmless.txt` in its
  central directory and carrying `../../../../ESCAPED.txt` in its local header
  wrote outside the destination AND outside the sandbox root, and all three
  extractors answered 1 with zip_error() = 0.

  The sandbox cannot cover for it: TUnZipper opens the output file itself, which
  is the blind spot recorded in the comment at the head of the handle section.

  WHICH HOOK -- MEASURED, NOT REASONED. None fires between ReadZipHeader and
  OpenOutput. OnStartFile runs at the END of OpenOutput (zipper.pp:2266), after
  fmCreate has already created the file, so a refusal there still leaves a byte
  outside the destination. OnCreateStream fires early enough but sets
  IsCustomStream (2793), and that DROPS FOutputPath from the path entirely
  (2779-2784) -- it would break every honest destination, which is why the
  proposal that named it warned about it in the same breath. What is available
  before any byte is written is the archive itself, so the local file headers are
  read here, up front, and the names extraction will actually use are judged:

    * every local name must pass SafeEntryName, and
    * it must be BYTE-IDENTICAL to the name the central directory advertised.

  THE SECOND HALF IS NOT REDUNDANT. An archive whose two names merely DISAGREE is
  lying about itself even when both names are harmless: unzip_entry$, zip_list$,
  zip_exists and zip_entrysize all answer from the central directory while
  zip_extract writes under the local one, so a caller told "keep.txt" gets a file
  named something else and no channel says so. The disagreement is refused in its
  own right, which also means this guard does not have to be as clever as
  SafeEntryName -- any spelling that reaches a different place than the one
  advertised is a different string, and a different string is refused.

  AND A NAME IS NOT THE ONLY THING AN ENTRY CAN BE. An entry whose attributes
  mark it a UNIX SYMBOLIC LINK is extracted by paszlib as a link whose TARGET is
  the entry's decompressed content (zipper.pp:2818-2825, fpSymlink) -- a string
  no name check ever looks at. An archive can then carry a link `dir` aimed at
  `../../../..` and a following entry `dir/x`, both names impeccable, and the
  second entry's byte lands wherever the first one pointed: measured on Linux,
  outside the destination AND outside the sandbox root, with unzip_extract
  answering 1 and zip_error() 0. Windows never reaches it (paszlib forces
  IsLink := False off UNIX, zipper.pp:2799-2804), which is precisely why a
  Windows-green suite could not see it. Nothing in this package extracts a link
  on purpose, so every link entry is refused, on both operating systems: the
  refusal is a judgement about the archive, not about the host. IsLink reads
  Attributes, which Examine takes from the CENTRAL directory (zipper.pp:2596)
  and ReadZipHeader never overwrites -- so unlike the name, this is already the
  copy that decides.

  AND THE COMPARISON ITSELF WAS MEASURED against this FPC (3.2.2) rather than
  assumed: ArchiveFileName holds the filename field's bytes UNCHANGED -- for a
  name carrying a byte >= 128, with the EFS language-encoding flag both set and
  clear. The one transform paszlib applies is SetArchiveFileName's
  DirectorySeparator -> '/' (zipper.pp:3186-3190), mirrored below. The compare is
  then made over BYTES: '=' on two strings whose dynamic code pages differ
  CONVERTS them rather than comparing them.

  AUnreadable SEPARATES AN I/O FAILURE FROM A REFUSAL. The archive is re-opened
  here, and an archive that has been deleted, renamed or locked since it was
  opened cannot be read -- which is a failure, not an accusation. This unit's
  header promises that failures are ANSWERED (0 / "" / false) and recorded in
  zip_error(), never raised, with zip slip the one deliberate exception; a raise
  on a vanished file breaks that promise and misdiagnoses it besides, telling a
  script its archive escaped the destination when the file simply went away. So
  the callers raise on a refusal and answer 0 on an unreadable archive, and this
  flag is how they tell the two apart. }
function LinkRefusal(AEntries: TFullZipFileEntries; out AWhy: String): Boolean;
var i: Integer;
begin
  { A LINK IS NOT A FILE, AND ITS TARGET IS NOT A NAME. See the note on symbolic
    links above. True = refused. }
  Result := False;
  AWhy := '';
  for i := 0 to AEntries.Count - 1 do
    if AEntries[i].IsLink then
    begin
      AWhy := 'entry ' + IntToStr(i + 1) + ' is a symbolic link, and the place a ' +
              'link points is not a name this library can check';
      Exit(True);
    end;
end;

type
  TIdxArray = array of Integer;
  TInt64Array = array of Int64;
  TNameArray = array of RawByteString;

{ A stable bottom-up merge sort of AIdx, by AStart (AByName = False) or by the
  bytes of ANames. Stable, so two equal keys keep the central directory's order
  and a refusal names the lower entry first.

  CHARGED PASS BY PASS: the entry count is the archive's choice, and a sort is
  log2(n) passes of n moves. APassCost is what one pass costs -- n, plus every
  name byte when the comparison reads names, since one comparison can read a
  65535-byte name. False = the budget refused and AIdx is half sorted. }
function SortEntryIndexes(var AIdx: TIdxArray; const AStart: TInt64Array;
  const ANames: TNameArray; AByName: Boolean; APassCost: Int64): Boolean;
var
  tmp: TIdxArray;
  n, width, lo, mid, hi, i, j, k: Integer;

  function Before(A, B: Integer): Boolean;
  begin
    if AByName then Result := NameBytesCompare(ANames[A], ANames[B]) <= 0
    else Result := AStart[A] <= AStart[B];
  end;

begin
  Result := False;
  n := Length(AIdx);
  SetLength(tmp, n);
  width := 1;
  while width < n do
  begin
    if not BudgetCharge(APassCost) then Exit;
    lo := 0;
    while lo < n do
    begin
      mid := lo + width;
      if mid > n then mid := n;
      hi := lo + 2 * width;
      if hi > n then hi := n;
      i := lo; j := mid; k := lo;
      while (i < mid) and (j < hi) do
      begin
        if Before(AIdx[i], AIdx[j]) then begin tmp[k] := AIdx[i]; Inc(i); end
        else begin tmp[k] := AIdx[j]; Inc(j); end;
        Inc(k);
      end;
      while i < mid do begin tmp[k] := AIdx[i]; Inc(i); Inc(k); end;
      while j < hi do begin tmp[k] := AIdx[j]; Inc(j); Inc(k); end;
      lo := hi;
    end;
    for i := 0 to n - 1 do AIdx[i] := tmp[i];
    width := width * 2;
  end;
  Result := True;
end;

{ THE JUDGEMENT OF AN ARCHIVE, over an OPEN stream -- the up-front check opens
  one, and TMeteredUnZipper judges the one it is extracting from, on the entries
  paszlib has just read again. One pass over the local file headers, then two
  structural questions.

  ALWAYS ASKED:
    * every entry has a local file header where its record says, signature and
      all -- one that does not cannot be read, and is not one to vouch for;
    * NO TWO ENTRIES SHARE OR OVERLAP A STRETCH OF THE ARCHIVE. An entry spans
      from its local header to the end of its data: 30 bytes, its name and extra
      field (as the LOCAL header sizes them), then the larger of the compressed
      sizes the two headers give. A well-formed archive lays entries end to end;
      one where two records point at one header, or one entry's header sits
      inside another's data, can make a stretch of bytes count once per record.
      That is the overlap bomb (2026-10-09): one stored 1 MiB entry, three
      hundred records, 300 MiB out. Only adjacent pairs, after sorting by
      offset, need comparing: if any entry starts inside another, the first one
      to start after that other does too;
    * NO TWO ENTRIES CARRY ONE NAME, compared as bytes. Every reader here answers
      a name out of the central directory, so an archive with a name twice cannot
      say which one a caller gets: zip_read$ took the first, zip_extractall left
      the second on disk. Info-ZIP and Python both accept such an archive (Python
      warns as it writes one); this library refuses it, deliberately -- it is
      ambiguous about itself in exactly the way a local/central name mismatch is.

  ASKED WHEN THE ENTRIES ARE BEING WRITTEN TO DISK (AForDisk):
    * no entry is a symbolic link;
    * every local name passes SafeEntryName, and
    * is byte-identical to the name the central directory advertised.
  zip_read$ writes no path, so it is not asked those three -- the rules that
  choose WHICH BYTES it answers apply to it, the rules that choose WHERE a byte
  lands do not.

  AStream is positioned wherever this leaves it; paszlib seeks before it reads.
  AWhy names entries by number and never quotes a name: names are attacker bytes,
  and every unit in this tree sets the UTF8 code page. }
function JudgeArchive(AEntries: TFullZipFileEntries; AStream: TStream;
  AForDisk: Boolean; out AWhy: String): Boolean;
var
  i, k, a, b, n: Integer;
  fsize, hdrPos, dataLen, spanCap, nameBytes: Int64;
  hdr: array[0..29] of Byte;
  nameLen, extraLen: Integer;
  localCSize: Cardinal;
  local, central: RawByteString;
  starts, ends: TInt64Array;
  names: TNameArray;
  idx: TIdxArray;
begin
  Result := False;
  AWhy := '';
  n := AEntries.Count;
  if n = 0 then Exit(True);
  { One seek and one bounded read per entry, over an entry count the ARCHIVE
    chose: charged before the pass, as it always was. The two sorts below charge
    their own passes as they go. }
  if not BudgetAllows(n) then
  begin
    AWhy := 'the execution budget refuses an archive of ' + IntToStr(n) + ' entries';
    Exit;
  end;
  if AForDisk and LinkRefusal(AEntries, AWhy) then Exit;
  fsize := AStream.Size;
  // No span can honestly reach past the end of the file; capping the arithmetic
  // there keeps a QWord size field from overflowing it.
  spanCap := fsize + 1;
  nameBytes := 0;
  SetLength(starts, n);
  SetLength(ends, n);
  SetLength(names, n);
  SetLength(idx, n);
  for i := 0 to n - 1 do
  begin
    { The fixed 30-byte part of a local file header, assembled byte by byte so
      this does not depend on the machine's endianness -- paszlib reads the record
      and byte-swaps it on a big-endian target instead. fsize is read once: the
      Size property is a seek-to-end and a seek-back, and asking it per entry made
      repeated single-entry extraction from a 5000-entry archive twice as slow. }
    hdrPos := TZipEntryCracker(AEntries[i]).HdrPos;
    if (hdrPos < 0) or (hdrPos + 30 > fsize) then
    begin
      AWhy := 'entry ' + IntToStr(i + 1) + ' has no readable local file header';
      Exit;
    end;
    AStream.Seek(hdrPos, soBeginning);
    if (AStream.Read(hdr[0], 30) <> 30) or
       // 'PK'#3#4
       (hdr[0] <> $50) or (hdr[1] <> $4B) or (hdr[2] <> $03) or (hdr[3] <> $04) then
    begin
      AWhy := 'entry ' + IntToStr(i + 1) + ' has no readable local file header';
      Exit;
    end;
    nameLen := hdr[26] or (hdr[27] shl 8);   // Words, so at most 65535 each
    extraLen := hdr[28] or (hdr[29] shl 8);
    localCSize := Cardinal(hdr[18]) or (Cardinal(hdr[19]) shl 8) or
                  (Cardinal(hdr[20]) shl 16) or (Cardinal(hdr[21]) shl 24);
    if AForDisk then
    begin
      // An entry with no name is not one to write.
      local := '';
      if nameLen > 0 then
      begin
        SetLength(local, nameLen);
        if AStream.Read(local[1], nameLen) <> nameLen then local := '';
      end;
      if local = '' then
      begin
        AWhy := 'entry ' + IntToStr(i + 1) + ' has no readable local file header';
        Exit;
      end;
      if not SafeEntryName(local) then
      begin
        AWhy := 'the local file header of entry ' + IntToStr(i + 1) +
                ' names a path that escapes the destination directory';
        Exit;
      end;
      { MIRRORS SetArchiveFileName (zipper.pp:3182-3190), which rewrites the
        host separator to '/' before storing the central name -- so a central
        name that reached paszlib holding a '\' is stored with a '/' while the
        local header's raw bytes still hold the '\', and the two would differ
        for a reason the archive never chose.

        GUARDED BY AN IFNDEF UNIX RATHER THAN BY `if DirectorySeparator <> '/'`.
        DirectorySeparator is a CONSTANT per target, so that test folds at
        compile time and on Linux the body became dead: "PhosphorZipLib.pas(591,9)
        Warning: unreachable code", and `bash scripts/build.sh` exited 1 on a
        tree that built clean on Windows. Off UNIX the separator is '\' and the
        replacement is exactly the one the runtime test asked for; on UNIX it is
        '/' already and the statement was always a no-op. }
      {$IFNDEF UNIX}
      local := StringReplace(local, DirectorySeparator, '/', [rfReplaceAll]);
      {$ENDIF}
      central := AEntries[i].ArchiveFileName;
      if NameBytesCompare(local, central) <> 0 then
      begin
        AWhy := 'entry ' + IntToStr(i + 1) + ' advertises one name in the central ' +
                'directory and carries another in its local file header';
        Exit;
      end;
    end;
    { The data: the larger of the two compressed sizes. The local one is what
      paszlib COPIES for a stored entry; the central one is the only one there is
      when the local header defers to a data descriptor (sizes 0) or to zip64
      ($FFFFFFFF, which Examine has already replaced in the central copy). }
    if AEntries[i].CompressedSize >= QWord(spanCap) then dataLen := spanCap
    else dataLen := Int64(AEntries[i].CompressedSize);
    if (localCSize <> $FFFFFFFF) and (Int64(localCSize) > dataLen) then
      dataLen := localCSize;
    starts[i] := hdrPos;
    ends[i] := hdrPos + 30 + nameLen + extraLen + dataLen;
    names[i] := AEntries[i].ArchiveFileName;
    Inc(nameBytes, Length(names[i]));
    idx[i] := i;
  end;
  if not SortEntryIndexes(idx, starts, names, False, n) then
  begin
    AWhy := 'the execution budget refuses an archive of ' + IntToStr(n) + ' entries';
    Exit;
  end;
  for k := 1 to n - 1 do
  begin
    a := idx[k - 1];
    b := idx[k];
    if starts[a] = starts[b] then
    begin
      AWhy := 'entries ' + IntToStr(a + 1) + ' and ' + IntToStr(b + 1) +
              ' point at the same local file header';
      Exit;
    end;
    if ends[a] > starts[b] then
    begin
      AWhy := 'the local file header of entry ' + IntToStr(b + 1) +
              ' overlaps the data of entry ' + IntToStr(a + 1);
      Exit;
    end;
  end;
  for i := 0 to n - 1 do idx[i] := i;
  if not SortEntryIndexes(idx, starts, names, True, n + nameBytes) then
  begin
    AWhy := 'the execution budget refuses an archive of ' + IntToStr(n) + ' entries';
    Exit;
  end;
  for k := 1 to n - 1 do
  begin
    a := idx[k - 1];
    b := idx[k];
    if NameBytesCompare(names[a], names[b]) = 0 then
    begin
      AWhy := 'entries ' + IntToStr(a + 1) + ' and ' + IntToStr(b + 1) +
              ' carry the same name';
      Exit;
    end;
  end;
  Result := True;
end;

function ArchiveLocalNamesAreSafe(AEntries: TFullZipFileEntries;
  const APath: String; out AWhy: String; out AUnreadable: Boolean): Boolean;
var
  fs: TFileStream;
begin
  Result := False;
  AWhy := '';
  AUnreadable := False;
  if AEntries.Count = 0 then Exit(True);
  { The archive is opened AGAIN, by path, so the gate is asked again -- every
    caller here has already asked, and the rule this unit carries is that the
    question belongs at the point the path is bound, not at the point someone
    remembered. }
  if not SandboxAllows(APath, puRead) then
  begin
    AWhy := 'the archive is outside the sandbox root';
    Exit;
  end;
  { Judged before the archive is even opened, so this refusal is a property of the
    archive and never an outcome of I/O. JudgeArchive asks it again; it is cheap. }
  if LinkRefusal(AEntries, AWhy) then Exit;
  try
    fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  except
    { An archive this cannot re-read is one it cannot vouch for -- but it is a
      FAILURE, not a refusal, and the caller must answer 0 rather than raise. }
    AUnreadable := True;
    AWhy := 'the archive could not be re-read to check its local file headers';
    Exit;
  end;
  try
    Result := JudgeArchive(AEntries, fs, True, AWhy);
  finally
    fs.Free;
  end;
end;

function f_unzip_extract(const Args: array of TValue; out Err: TPhosphorError): TValue;
var uz: TMeteredUnZipper; why: String; unread: Boolean;
begin
  Err := NoError();
  Result := ValInt(0);
  if not SandboxAllows(Args[0].Str, puRead) then begin ZipErr := 1; Exit; end;
  { Args[1] IS A PATH ON DISK TOO -- the directory every entry is written into,
    and the half of this call nobody asked the gate about. The two guards below
    are not the same guard: ArchiveIsSafe stops an ENTRY NAME climbing out of the
    destination, and this stops the DESTINATION ITSELF from being outside the
    root. An archive full of well-behaved names extracted cleanly into a
    directory the script had no business writing to, which is the whole escape. }
  if not SandboxAllows(Args[1].Str, puWrite) then begin ZipErr := 1; Exit; end;
  try
    uz := TMeteredUnZipper.Create();
    try
      uz.FileName := Args[0].Str;
      uz.OutputPath := Args[1].Str;
      uz.Examine;
      if not ArchiveIsSafe(uz) then
      begin
        ZipErr := 1;
        Err := MakeError(peRuntime, 'archive refused: an entry name escapes the ' +
          'destination directory (a leading /, a drive letter, or a ".." segment)');
        Exit;
      end;
      { AND THE NAMES EXTRACTION WILL ACTUALLY USE, which are not the ones the
        line above judged. See ArchiveLocalNamesAreSafe. }
      if not ArchiveLocalNamesAreSafe(uz.Entries, uz.FileName, why, unread) then
      begin
        ZipErr := 1;
        { A VANISHED ARCHIVE IS ANSWERED, NOT RAISED. Only a judgement about the
          archive's contents earns the deliberate exception to this unit's
          "failures are answered" rule; an archive that could not be re-read is
          an ordinary failure and keeps the 0 / zip_error() = 1 it always had. }
        if not unread then
          Err := MakeError(peRuntime, 'archive refused: ' + why);
        Exit;
      end;
      if not ArchiveFitsBudget(uz) then
      begin
        ZipErr := 1;
        Err := BudgetRefusal('unzip_extract');
        Exit;
      end;
      try
        uz.ExtractEvery;
      except
        // The archive the extraction actually read was judged and refused.
        on E: EZipRefused do
        begin
          ZipErr := 1;
          Err := MakeError(peRuntime, 'archive refused: ' + E.Message);
          Exit;
        end;
        else
        begin
          // The meter stopped it: a refusal, not a corrupt archive.
          if uz.Spent then
          begin
            ZipErr := 1;
            Err := BudgetRefusal('unzip_extract');
            Exit;
          end;
          raise;
        end;
      end;
      Result := ValInt(1);
      ZipErr := 0;
    finally
      uz.Free;
    end;
  except
    Result := ValInt(0);
    ZipErr := 1;
  end;
end;

function f_unzip_count(const Args: array of TValue; out Err: TPhosphorError): TValue;
var uz: TUnZipper;
begin
  Err := NoError();
  Result := ValInt(0);
  if not SandboxAllows(Args[0].Str, puRead) then begin ZipErr := 1; Exit; end;
  try
    uz := TUnZipper.Create();
    try
      uz.FileName := Args[0].Str;
      uz.Examine;
      Result := ValInt(uz.Entries.Count);
      ZipErr := 0;
    finally
      uz.Free;
    end;
  except
    // RECORD it. The unit header promises failures reach zip_error(), and these two
    // swallowed the exception with the slot untouched -- so a caller could not tell
    // a corrupt archive from an empty one, which is the whole question they ask.
    ZipErr := 1;
    Result := ValInt(0);
  end;
end;

function f_unzip_entry(const Args: array of TValue; out Err: TPhosphorError): TValue;
var uz: TUnZipper; n: Integer;
begin
  Err := NoError();
  Result := ValStr('');
  if not SandboxAllows(Args[0].Str, puRead) then begin ZipErr := 1; Exit; end;
  try
    uz := TUnZipper.Create();
    try
      uz.FileName := Args[0].Str;
      uz.Examine;
      n := ArgI32(Args[1]);   // 1-based
      if (n >= 1) and (n <= uz.Entries.Count) then
      begin
        Result := ValStr(uz.Entries[n - 1].ArchiveFileName);
        ZipErr := 0;
      end
      else
        ZipErr := 1;   // an index outside the archive is a refusal, not an empty name
    finally
      uz.Free;
    end;
  except
    ZipErr := 1;
    Result := ValStr('');
  end;
end;

// --- handle-based create/add/close ------------------------------------------
{ EVERY DISK PATH THIS PACKAGE IS HANDED GOES THROUGH THE GATE FIRST.

  Only zip_compress asked. The other four -- create, open, addfile, extract --
  took a path straight from the script and handed it to the RTL, so a run
  confined by --sandbox wrote a zip anywhere on the disk while file_writealltext
  to a comparable path was refused two lines earlier. Demonstrated on 2026-09-06:
  a script rooted in a scratch directory created an archive in C:\Dev.

  check-sandbox.py did not report it, and could not: it looks for Pascal
  filesystem primitives, and TZipper/TUnZipper open their own files. The gate has
  been taught these names too.

  AND THEN THE SAME MISTAKE AGAIN, ONE ARGUMENT ACROSS. That fix reached the
  paths those functions READ and the archives they CREATE by handle, and stopped
  there. Four routines here take TWO paths, and in every one of them the path
  left ungated was the DESTINATION: zip_compress's archive, unzip_extract's
  output directory, zip_extractall's output directory, and zip_quick's archive --
  whose source, meanwhile, was checked with puWrite, the verb belonging to the
  other end. The escape survived its own fix, in the direction that writes, and
  every suite and all seven gates stayed green through it, because a gate that
  asks whether a ROUTINE mentions SandboxAllows cannot ask whether EVERY path in
  it was checked.

  So the rule is not "this unit asks the gate", which is a claim about a file. It
  is: A ROUTINE WITH TWO PATHS ASKS TWICE, each with the verb its own path
  deserves -- puRead for the one it reads, puWrite for the one it writes. There
  are eight functions here that name a path on disk, sixteen such arguments
  between them, and each one is asked about at the point it is bound.

  AN ENTRY NAME IS NOT A DISK PATH ON THE WAY IN. zip_addfile's and zip_addstr's
  third argument becomes bytes inside the archive; the archive file itself is
  gated, and writing "../x" into one escapes nothing. On the way OUT it decides
  where a byte lands, and there it is gated -- SafeEntryName, over every entry,
  through ArchiveIsSafe, in all three extractors. Both halves are needed: the
  destination check does not stop zip slip, and SafeEntryName does not stop a
  destination outside the root. }
function f_zip_create(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  try
    Result := ValHandle(RegisterHandle(TZipWriter.Create(Args[0].Str)));
    ZipErr := 0;
  except
    Result := ValHandle(0);
    ZipErr := 1;
  end;
end;

function f_zip_addfile(const Args: array of TValue; out Err: TPhosphorError): TValue;
var w: TZipWriter;
begin
  Err := NoError();
  Result := ValInt(0);
  if not GetWriter(Args[0].Hnd, w) then begin ZipErr := 1; Exit; end;
  // Args[1] is a path ON DISK being read into the archive.
  if not SandboxAllows(Args[1].Str, puRead) then begin ZipErr := 1; Exit; end;
  try
    w.AddFile(Args[1].Str, Args[2].Str);
    Result := ValInt(1);
    ZipErr := 0;
  except
    Result := ValInt(0);
    ZipErr := 1;
  end;
end;

function f_zip_addstr(const Args: array of TValue; out Err: TPhosphorError): TValue;
var w: TZipWriter;
begin
  Err := NoError();
  Result := ValInt(0);
  if not GetWriter(Args[0].Hnd, w) then begin ZipErr := 1; Exit; end;
  try
    w.AddStr(Args[1].Str, Args[2].Str);
    Result := ValInt(1);
    ZipErr := 0;
  except
    Result := ValInt(0);
    ZipErr := 1;
  end;
end;

function f_zip_close(const Args: array of TValue; out Err: TPhosphorError): TValue;
var w: TZipWriter; r: TZipReader; wrote: Boolean;
begin
  Err := NoError();
  Result := ValInt(0);
  try
    if GetWriter(Args[0].Hnd, w) then
    begin
      // THIS is where a writer's archive reaches disk, so this is where a caller
      // learns whether it did. Closing a writer holding no entries answered 1 and
      // left a 0-byte file (see TZipWriter.Save) -- a program acting on that 1
      // reports a backup that does not exist. The handle is released either way,
      // so nothing leaks and a second close still reports itself as a stale one.
      wrote := w.Save();               // flush the archive to disk before releasing
      FreeHandle(Args[0].Hnd);
      if wrote then
      begin
        Result := ValInt(1);
        ZipErr := 0;
      end
      else
        ZipErr := 1;
    end
    else if GetReader(Args[0].Hnd, r) then
    begin
      FreeHandle(Args[0].Hnd);
      Result := ValInt(1);
      ZipErr := 0;
    end
    else
      ZipErr := 1;
  except
    Result := ValInt(0);
    ZipErr := 1;
  end;
end;

// --- handle-based open/inspect/extract --------------------------------------
function f_zip_open(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  try
    Result := ValHandle(RegisterHandle(TZipReader.Create(Args[0].Str)));
    ZipErr := 0;
  except
    Result := ValHandle(0);
    ZipErr := 1;                     // a failed open leaves a non-zero code behind
  end;
end;

function f_zip_count(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TZipReader;
begin
  Err := NoError();
  if GetReader(Args[0].Hnd, r) then Result := ValInt(r.UZ.Entries.Count)
  else begin Result := ValInt(0); ZipErr := 1; end;
end;

function f_zip_exists(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TZipReader;
begin
  // 1/0, not a bool: assert_true/assert_false carry a message only on the
  // numeric overload (:n$), and there is no assert_*:?$ to catch a bool + msg.
  Err := NoError();
  if GetReader(Args[0].Hnd, r) then Result := ValInt(Ord(r.IndexOf(Args[1].Str) >= 0))
  else begin Result := ValInt(0); ZipErr := 1; end;
end;

function f_zip_read(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TZipReader; data: String;
begin
  Err := NoError();
  Result := ValStr('');
  if not GetReader(Args[0].Hnd, r) then begin ZipErr := 1; Exit; end;
  try
    if r.ReadEntry(Args[1].Str, data) then
    begin Result := ValStr(data); ZipErr := 0; end
    else
    begin
      ZipErr := 1;
      // A refusal is not a missing entry, and must not read as one.
      if r.FSpent then Err := BudgetRefusal('zip_read$');
    end;
  except
    { An archive JudgeArchive refuses -- two records on one local header, one
      entry inside another, a name twice -- is refused here as the extractors
      refuse it: those are the rules that decide which bytes this answers. A
      CRC mismatch is not one of them; it is damage, answered "" below. }
    on E: EZipRefused do
    begin
      Result := ValStr('');
      ZipErr := 1;
      Err := MakeError(peRuntime, 'archive refused: ' + E.Message);
    end;
    else
    begin
      Result := ValStr('');
      ZipErr := 1;
    end;
  end;
end;

function f_zip_entrysize(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TZipReader; i: Integer;
begin
  Err := NoError();
  Result := ValInt(0);
  if not GetReader(Args[0].Hnd, r) then begin ZipErr := 1; Exit; end;
  i := r.IndexOf(Args[1].Str);
  if i >= 0 then Result := ValInt(r.UZ.Entries[i].Size)
  else ZipErr := 1;
end;

function f_zip_list(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TZipReader; s: String; i: Integer;
begin
  Err := NoError();
  Result := ValStr('');
  if not GetReader(Args[0].Hnd, r) then begin ZipErr := 1; Exit; end;
  // QUADRATIC APPEND, charged as it goes (RULE 2): one append per archive entry,
  // copying the whole listing each time.
  s := '';
  for i := 0 to r.UZ.Entries.Count - 1 do
  begin
    if not BudgetAppend(Length(s)) then
    begin Err := BudgetRefusal('zip_list$'); Exit(ValStr('')); end;
    if i > 0 then s := s + #10;
    s := s + r.UZ.Entries[i].ArchiveFileName;
  end;
  Result := ValStr(s);
end;

function f_zip_extract(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TZipReader; why: String; unread: Boolean; idx: Integer;
begin
  Err := NoError();
  Result := ValInt(0);
  if not GetReader(Args[0].Hnd, r) then begin ZipErr := 1; Exit; end;
  try
    if not ArchiveIsSafe(r.UZ) then
    begin
      ZipErr := 1;
      Err := MakeError(peRuntime, 'archive refused: an entry name escapes the ' +
        'destination directory');
      Exit;
    end;
    { AND THE NAMES EXTRACTION WILL ACTUALLY USE. The entry is picked by its
      CENTRAL name (ExtractOnly, as paszlib's IsMatch did, zipper.pp:2850), so
      this call is doubly exposed: the entry it picks and the path it writes
      are chosen from two different strings. See ArchiveLocalNamesAreSafe. }
    if not ArchiveLocalNamesAreSafe(r.UZ.Entries, r.UZ.FileName, why, unread) then
    begin
      ZipErr := 1;
      // An archive that vanished between zip_open@ and here is answered, not
      // raised -- see the same guard in f_unzip_extract.
      if not unread then
        Err := MakeError(peRuntime, 'archive refused: ' + why);
      Exit;
    end;
    // Args[2] is a DESTINATION DIRECTORY on disk. ArchiveIsSafe above stops an
    // entry name from climbing out of it; this stops the destination itself
    // from being outside the root in the first place.
    if not SandboxAllows(Args[2].Str, puWrite) then
    begin
      ZipErr := 1;
      Exit;
    end;
    { AN ENTRY THE ARCHIVE DOES NOT HOLD IS A FAILURE, NOT A NO-OP. The name
      handed to the extraction is a FILTER, and a filter that matches
      nothing is not an error to it -- so this answered 1 with zip_error() clear
      for a name never in the archive, and the destination directory was not
      even created. Both channels said success. The sibling zip_read$ answers
      the same absent name correctly ("" with zip_error()=1), so nothing told a
      program that the file it believed it had just written does not exist.
      Asked last, so every refusal that already stood -- a hostile archive, a
      destination outside the sandbox root -- still comes first and unchanged. }
    idx := r.IndexOf(Args[1].Str);
    if idx < 0 then
    begin
      ZipErr := 1;
      Exit;
    end;
    { THE BUDGET, WHICH THIS DOOR NEVER ASKED (ledger d47). The declared size
      first, so an entry that admits to being too big writes nothing; then the
      metered unzipper charges what it really becomes. }
    if not BudgetAllows(r.UZ.Entries[idx].Size) then
    begin
      ZipErr := 1;
      Err := BudgetRefusal('zip_extract');
      Exit;
    end;
    r.UZ.OutputPath := Args[2].Str;
    try
      r.UZ.ExtractOnly(Args[1].Str);
    except
      on E: EZipRefused do
      begin
        ZipErr := 1;
        Err := MakeError(peRuntime, 'archive refused: ' + E.Message);
        Exit;
      end;
      else
      begin
        if r.UZ.Spent then
        begin
          ZipErr := 1;
          Err := BudgetRefusal('zip_extract');
          Exit;
        end;
        raise;
      end;
    end;
    Result := ValInt(1);
    ZipErr := 0;
  except
    Result := ValInt(0);
    ZipErr := 1;
  end;
end;

function f_zip_extractall(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TZipReader; why: String; unread: Boolean;
begin
  Err := NoError();
  Result := ValInt(0);
  if not GetReader(Args[0].Hnd, r) then begin ZipErr := 1; Exit; end;
  try
    if not ArchiveIsSafe(r.UZ) then
    begin
      ZipErr := 1;
      Err := MakeError(peRuntime, 'archive refused: an entry name escapes the ' +
        'destination directory');
      Exit;
    end;
    { AND THE NAMES EXTRACTION WILL ACTUALLY USE. See ArchiveLocalNamesAreSafe. }
    if not ArchiveLocalNamesAreSafe(r.UZ.Entries, r.UZ.FileName, why, unread) then
    begin
      ZipErr := 1;
      // An archive that vanished between zip_open@ and here is answered, not
      // raised -- see the same guard in f_unzip_extract.
      if not unread then
        Err := MakeError(peRuntime, 'archive refused: ' + why);
      Exit;
    end;
    { Args[1] is a DESTINATION DIRECTORY on disk, and this routine asked the gate
      nothing at all -- the only one of the eight path-taking functions here with
      no SandboxAllows in it. check-sandbox.py never even considered it: it
      reaches the unzipper through the field r.UZ, so the routine names neither
      TUnZipper nor any primitive on the gate's list, and a routine the gate does
      not look at cannot be reported as a hole. Asked in the same order as the
      sibling zip_extract: the hostile-archive refusal above still comes first,
      and still comes as an error rather than a quiet 0. }
    if not SandboxAllows(Args[1].Str, puWrite) then
    begin
      ZipErr := 1;
      Exit;
    end;
    { THE BUDGET, WHICH THIS DOOR NEVER ASKED (ledger d47): the declared total
      first, as unzip_extract asks it, then the meter on what really comes out. }
    if not ArchiveFitsBudget(r.UZ) then
    begin
      ZipErr := 1;
      Err := BudgetRefusal('zip_extractall');
      Exit;
    end;
    r.UZ.OutputPath := Args[1].Str;
    try
      r.UZ.ExtractEvery;
    except
      on E: EZipRefused do
      begin
        ZipErr := 1;
        Err := MakeError(peRuntime, 'archive refused: ' + E.Message);
        Exit;
      end;
      else
      begin
        if r.UZ.Spent then
        begin
          ZipErr := 1;
          Err := BudgetRefusal('zip_extractall');
          Exit;
        end;
        raise;
      end;
    end;
    Result := ValInt(1);
    ZipErr := 0;
  except
    Result := ValInt(0);
    ZipErr := 1;
  end;
end;

function f_zip_quick(const Args: array of TValue; out Err: TPhosphorError): TValue;
var z: TZipper;
begin
  Err := NoError();
  Result := ValInt(0);
  { THE GATE WAS ASKED ABOUT ONE PATH, AND WITH THE OTHER PATH'S VERB. Args[0] is
    the file this READS into the archive and was checked with puWrite; Args[1] is
    the archive it WRITES and was not checked at all. The wrong verb was not
    harmless either way round: puWrite adds the perilous-path rule to a path that
    is only read, and leaves the one being written to unguarded. }
  if not SandboxAllows(Args[0].Str, puRead) then begin ZipErr := 1; Exit; end;
  if not SandboxAllows(Args[1].Str, puWrite) then begin ZipErr := 1; Exit; end;
  { A SOURCE THAT IS NOT THERE IS A FAILURE ANSWERED BEFORE THE OUTPUT IS TOUCHED
    -- the rule TZipWriter.AddFile already carries, and here it guards data, not
    just tidiness. SaveToFile opens the archive with fmCreate FIRST and
    GetFileInfo raises SErrFileDoesNotExist for the missing source AFTER, so a
    mistyped source name truncated whatever archive stood at the destination to 0
    bytes and answered 0 with nothing left to reopen. puWrite on Args[0] used to
    refuse an empty source by accident; this is the check that actually belongs
    here, and it refuses every missing source, not just the empty spelling. }
  if not FileExists(Args[0].Str) then begin ZipErr := 1; Exit; end;
  try
    z := TZipper.Create();
    try
      z.FileName := Args[1].Str;
      // Store the bare file name; FPC's ExtractFileName splits on both '/' and
      // '\' on Windows, so the archive shape does not follow which slash the
      // programmer typed (the wart the reference had).
      z.Entries.AddFileEntry(Args[0].Str, ExtractFileName(Args[0].Str));
      z.ZipAllFiles;
      Result := ValInt(1);
      ZipErr := 0;
    finally
      z.Free;
    end;
  except
    Result := ValInt(0);
    ZipErr := 1;
  end;
end;

function f_zip_error(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(ZipErr);
end;

procedure RegisterZipFuncs(Reg: TPhosphorRegistry);
begin
  // whole-archive
  Reg.Add('zip_compress:$$',  @f_zip_compress);
  Reg.Add('unzip_extract:$$', @f_unzip_extract);
  Reg.Add('unzip_count:$',    @f_unzip_count);
  Reg.Add('unzip_entry$:$n',  @f_unzip_entry);
  // handle-based
  Reg.Add('zip_create@:$',    @f_zip_create);
  Reg.Add('zip_addfile:@$$',  @f_zip_addfile);
  Reg.Add('zip_addstr:@$$',   @f_zip_addstr);
  Reg.Add('zip_close:@',      @f_zip_close);
  Reg.Add('zip_open@:$',      @f_zip_open);
  Reg.Add('zip_count:@',      @f_zip_count);
  Reg.Add('zip_exists:@$',    @f_zip_exists);
  Reg.Add('zip_read$:@$',     @f_zip_read);
  Reg.Add('zip_entrysize:@$', @f_zip_entrysize);
  Reg.Add('zip_list$:@',      @f_zip_list);
  Reg.Add('zip_extract:@$$',  @f_zip_extract);
  Reg.Add('zip_extractall:@$',@f_zip_extractall);
  Reg.Add('zip_quick:$$',     @f_zip_quick);
  Reg.Add('zip_error:',       @f_zip_error);
end;

initialization
  // At unit load, not at registration: the table belongs to the unzipper type,
  // and a type must not depend on a host having called RegisterZipFuncs first.
  BuildCrc32Table();

end.
