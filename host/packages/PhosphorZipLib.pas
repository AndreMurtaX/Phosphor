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
******************************************************************************}
unit PhosphorZipLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Zipper,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles, PhosphorSandbox;

procedure RegisterZipFuncs(Reg: TPhosphorRegistry);

implementation

var
  ZipErr: Integer = 0;   // 0 = the last zip op was clean; 1 = it failed

type
  { Raised by a constructor the sandbox refused. A named class rather than a bare
    Exception so the reason survives into any handler that cares to look, and so
    a reader of the raise line does not have to guess why a zip constructor is
    throwing. Every caller in this unit already turns an exception into
    ZipErr := 1 and a zero handle, which is the refusal the script sees. }
  EPhosphorZipRefused = class(Exception);

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
    UZ: TUnZipper;
    FScratch: TMemoryStream;
    constructor Create(const APath: String);
    destructor Destroy; override;
    function IndexOf(const AName: String): Integer;
    function ReadEntry(const AName: String; out AData: String): Boolean;
    procedure DoCreateStream(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
    procedure DoDoneStream(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
  end;

{ TZipWriter }

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
  Z.Entries.AddFileEntry(ADisk, AArchive);
end;

procedure TZipWriter.AddStr(const AContent, AArchive: String);
var ms: TMemoryStream;
begin
  ms := TMemoryStream.Create();
  if Length(AContent) > 0 then ms.WriteBuffer(AContent[1], Length(AContent));
  ms.Position := 0;
  Owned.Add(ms);
  Z.Entries.AddFileEntry(ms, AArchive);
end;

function TZipWriter.Save: Boolean;
begin
  Z.ZipAllFiles;
  Result := True;
end;

{ TZipReader }

constructor TZipReader.Create(const APath: String);
begin
  if not SandboxAllows(APath, puRead) then
    raise EPhosphorZipRefused.Create('refused: the path is outside the sandbox root');
  UZ := TUnZipper.Create();
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
  Result := -1;
  for i := 0 to UZ.Entries.Count - 1 do
    if UZ.Entries[i].ArchiveFileName = AName then
      Exit(i);
end;

procedure TZipReader.DoCreateStream(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
begin
  FScratch := TMemoryStream.Create();
  AStream := FScratch;
end;

procedure TZipReader.DoDoneStream(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
begin
  // Keep FScratch alive past CloseOutput (it nils the local reference for us).
  AStream.Position := 0;
end;

function TZipReader.ReadEntry(const AName: String; out AData: String): Boolean;
var sl: TStringList;
begin
  Result := False;
  AData := '';
  FScratch := nil;
  sl := TStringList.Create();
  try
    sl.Add(AName);
    UZ.OnCreateStream := @DoCreateStream;
    UZ.OnDoneStream := @DoDoneStream;
    try
      UZ.UnZipFiles(sl);
    finally
      UZ.OnCreateStream := nil;
      UZ.OnDoneStream := nil;
    end;
  finally
    sl.Free;
  end;
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
  try
    z := TZipper.Create();
    try
      z.FileName := Args[0].Str;
      if not SandboxAllows(Args[1].Str, puRead) then Exit(ValInt(0));
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
            if (sr.Attr and faDirectory) = 0 then names.Add(sr.Name);
          until FindNext(sr) <> 0;
        finally
          FindClose(sr);
        end;
        names.CustomSort(@CompareNameBytes);
        for i := 0 to names.Count - 1 do
          z.Entries.AddFileEntry(base + names[i], names[i]);
      finally
        names.Free;
      end;
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
function ArchiveIsSafe(AUz: TUnZipper): Boolean;
var i: Integer;
begin
  Result := True;
  for i := 0 to AUz.Entries.Count - 1 do
    if not SafeEntryName(AUz.Entries[i].ArchiveFileName) then
      Exit(False);
end;

function f_unzip_extract(const Args: array of TValue; out Err: TPhosphorError): TValue;
var uz: TUnZipper;
begin
  Err := NoError();
  Result := ValInt(0);
  if not SandboxAllows(Args[0].Str, puRead) then begin ZipErr := 1; Exit; end;
  try
    uz := TUnZipper.Create();
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
      uz.UnZipAllFiles;
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
  been taught these names too. }
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
var w: TZipWriter; r: TZipReader;
begin
  Err := NoError();
  Result := ValInt(0);
  try
    if GetWriter(Args[0].Hnd, w) then
    begin
      w.Save();                        // flush the archive to disk before releasing
      FreeHandle(Args[0].Hnd);
      Result := ValInt(1);
      ZipErr := 0;
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
    else ZipErr := 1;
  except
    Result := ValStr('');
    ZipErr := 1;
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
  s := '';
  for i := 0 to r.UZ.Entries.Count - 1 do
  begin
    if i > 0 then s := s + #10;
    s := s + r.UZ.Entries[i].ArchiveFileName;
  end;
  Result := ValStr(s);
end;

function f_zip_extract(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TZipReader; sl: TStringList;
begin
  Err := NoError();
  Result := ValInt(0);
  if not GetReader(Args[0].Hnd, r) then begin ZipErr := 1; Exit; end;
  sl := TStringList.Create();
  try
    try
      sl.Add(Args[1].Str);
      if not ArchiveIsSafe(r.UZ) then
      begin
        ZipErr := 1;
        Err := MakeError(peRuntime, 'archive refused: an entry name escapes the ' +
          'destination directory');
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
      r.UZ.OutputPath := Args[2].Str;
      r.UZ.UnZipFiles(sl);
      Result := ValInt(1);
      ZipErr := 0;
    except
      Result := ValInt(0);
      ZipErr := 1;
    end;
  finally
    sl.Free;
  end;
end;

function f_zip_extractall(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TZipReader;
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
    r.UZ.Files.Clear();               // a prior single-entry op left a filter behind;
    r.UZ.OutputPath := Args[1].Str; // an empty list means "every file"
    r.UZ.UnZipAllFiles;
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
  if not SandboxAllows(Args[0].Str, puWrite) then begin ZipErr := 1; Exit; end;
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

end.
