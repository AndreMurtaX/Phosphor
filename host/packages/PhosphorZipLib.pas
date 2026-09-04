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
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles;

procedure RegisterZipFuncs(Reg: TPhosphorRegistry);

implementation

var
  ZipErr: Integer = 0;   // 0 = the last zip op was clean; 1 = it failed

type
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

constructor TZipWriter.Create(const APath: String);
begin
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
function f_zip_compress(const Args: array of TValue; out Err: TPhosphorError): TValue;
var z: TZipper; sr: TSearchRec; base: String;
begin
  Err := NoError();
  Result := ValInt(0);
  try
    z := TZipper.Create();
    try
      z.FileName := Args[0].Str;
      base := IncludeTrailingPathDelimiter(Args[1].Str);
      if FindFirst(base + '*', faAnyFile, sr) = 0 then
      try
        repeat
          if (sr.Attr and faDirectory) = 0 then
            z.Entries.AddFileEntry(base + sr.Name, sr.Name);
        until FindNext(sr) <> 0;
      finally
        FindClose(sr);
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

function f_unzip_extract(const Args: array of TValue; out Err: TPhosphorError): TValue;
var uz: TUnZipper;
begin
  Err := NoError();
  Result := ValInt(0);
  try
    uz := TUnZipper.Create();
    try
      uz.FileName := Args[0].Str;
      uz.OutputPath := Args[1].Str;
      uz.Examine;
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
  try
    uz := TUnZipper.Create();
    try
      uz.FileName := Args[0].Str;
      uz.Examine;
      Result := ValInt(uz.Entries.Count);
    finally
      uz.Free;
    end;
  except
    Result := ValInt(0);
  end;
end;

function f_unzip_entry(const Args: array of TValue; out Err: TPhosphorError): TValue;
var uz: TUnZipper; n: Integer;
begin
  Err := NoError();
  Result := ValStr('');
  try
    uz := TUnZipper.Create();
    try
      uz.FileName := Args[0].Str;
      uz.Examine;
      n := Round(AsDouble(Args[1]));   // 1-based
      if (n >= 1) and (n <= uz.Entries.Count) then Result := ValStr(uz.Entries[n - 1].ArchiveFileName);
    finally
      uz.Free;
    end;
  except
    Result := ValStr('');
  end;
end;

// --- handle-based create/add/close ------------------------------------------
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
