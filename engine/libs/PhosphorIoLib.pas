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
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles;

type
  { A raw byte buffer as a handle object, for file_readallbytes@/writeallbytes.
    Public so a sibling lib (PhosphorStrListLib's stream load/save) can move a
    string list through the SAME handle IoLib hands out for a file's bytes. }
  TPhosphorBytes = class
    Data: String;
  end;

procedure RegisterIoFuncs(Reg: TPhosphorRegistry);

implementation

var
  GIoError: Integer;   // last IO error code; ioerror()/iostrerror$() read it

// --- raw whole-file text (no BOM, no newline translation) -------------------
function WriteAllBytes(const APath, AContent: String): Boolean;
var fs: TFileStream;
begin
  Result := False;
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

function ReadAllBytes(const APath: String; out AContent: String): Boolean;
var fs: TFileStream; len: Int64;
begin
  AContent := '';
  Result := False;
  if not FileExists(APath) then Exit;
  try
    fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
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

function t_file_writealltext(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(Ord(WriteAllBytes(Args[0].Str, Args[1].Str)));
end;
function t_file_readalltext(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: String;
begin
  Err := NoError();
  if ReadAllBytes(Args[0].Str, s) then GIoError := 0 else GIoError := 2;  // 2 ~ not found
  Result := ValStr(s);
end;
function t_file_exists(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(Ord(FileExists(Args[0].Str)));
end;
function t_file_delete(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(Ord(DeleteFile(Args[0].Str)));
end;

// savetext$/opentext$: the encoding argument is accepted; utf-8 is raw bytes,
// which is what the whole engine already speaks.
function t_savetext(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  WriteAllBytes(Args[0].Str, Args[2].Str);
  Result := ValStr(Args[0].Str);
end;
function t_opentext(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: String;
begin
  Err := NoError();
  ReadAllBytes(Args[0].Str, s);
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

function t_path_getfilename(const Args: array of TValue; out Err: TPhosphorError): TValue;
var p: String;
begin
  Err := NoError(); p := Args[0].Str;
  Result := ValStr(Copy(p, LastSep(p) + 1, MaxInt));
end;
function t_path_getextension(const Args: array of TValue; out Err: TPhosphorError): TValue;
var p: String; sep, dot: Integer;
begin
  Err := NoError(); p := Args[0].Str;
  sep := LastSep(p);
  dot := LastDotAfter(p, sep);
  if dot > 0 then Result := ValStr(Copy(p, dot, MaxInt)) else Result := ValStr('');
end;
function t_path_getfilenamenoext(const Args: array of TValue; out Err: TPhosphorError): TValue;
var p, fn: String; sep, dot: Integer;
begin
  Err := NoError(); p := Args[0].Str;
  sep := LastSep(p);
  fn := Copy(p, sep + 1, MaxInt);
  dot := LastDotAfter(p, sep);
  if dot > 0 then Result := ValStr(Copy(p, sep + 1, dot - sep - 1)) else Result := ValStr(fn);
end;
function t_path_changeextension(const Args: array of TValue; out Err: TPhosphorError): TValue;
var p, ext: String; sep, dot: Integer;
begin
  Err := NoError(); p := Args[0].Str; ext := Args[1].Str;
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
  Result := ValStr(Copy(p, 1, LastSep(p)));
end;

function t_dir_exists(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
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

function MatchGlob(const AName, APattern: String; ACaseSensitive: Boolean): Boolean;
var n, p: String;
  function M(ni, pi: Integer): Boolean;
  begin
    while pi <= Length(p) do
    begin
      if p[pi] = '*' then
      begin
        while (pi <= Length(p)) and (p[pi] = '*') do Inc(pi);
        if pi > Length(p) then Exit(True);
        while ni <= Length(n) do
        begin
          if M(ni, pi) then Exit(True);
          Inc(ni);
        end;
        Exit(False);
      end
      else if (ni <= Length(n)) and ((p[pi] = '?') or (p[pi] = n[ni])) then
      begin Inc(ni); Inc(pi); end
      else Exit(False);
    end;
    Result := ni > Length(n);
  end;
begin
  if ACaseSensitive then begin n := AName; p := APattern; end
  else begin n := LowerCase(AName); p := LowerCase(APattern); end;
  Result := M(1, 1);
end;

// --- directory listing ------------------------------------------------------
procedure CollectEntries(const ADir, APattern: String; AFiles, ADirs, ARecursive: Boolean; AList: TStrings);
var sr: TSearchRec; base: String;
begin
  base := IncludeTrailingPathDelimiter(ADir);
  if FindFirst(base + '*', faAnyFile, sr) = 0 then
  begin
    repeat
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
var l: TStringList; i: Integer;
begin
  Result := '';
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
    for i := 0 to l.Count - 1 do
    begin
      if i > 0 then Result := Result + #10;
      Result := Result + l[i];
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
function CopyFileBytes(const ASrc, ADst: String): Boolean;
var s: String;
begin
  Result := ReadAllBytes(ASrc, s) and WriteAllBytes(ADst, s);
end;
procedure DeleteTree(const ADir: String);
var sr: TSearchRec; base: String;
begin
  base := IncludeTrailingPathDelimiter(ADir);
  if FindFirst(base + '*', faAnyFile, sr) = 0 then
  begin
    repeat
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
  Result := ForceDirectories(ADst);
  if not Result then Exit;
  sbase := IncludeTrailingPathDelimiter(ASrc);
  dbase := IncludeTrailingPathDelimiter(ADst);
  if FindFirst(sbase + '*', faAnyFile, sr) = 0 then
  begin
    repeat
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

// --- directory functions ----------------------------------------------------
function t_dir_create(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); ForceDirectories(Args[0].Str); Result := ValInt(1); end;
function t_dir_isempty(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(Ord(ListToStr(Args[0].Str, '*', True, True, False) = '')); end;
function t_dir_delete(const Args: array of TValue; out Err: TPhosphorError): TValue;
var
  ok: Boolean;
begin
  Err := NoError();
  // ANSWER WHAT HAPPENED. Both calls return a result and both used to have it
  // thrown away, so a dir_delete of a non-empty directory answered 1, left the
  // directory standing, and set no error -- a program could not tell it had
  // failed by any means. file_delete next door already answers Ord(DeleteFile).
  if (Length(Args) >= 2) and (AsDouble(Args[1]) <> 0) then
  begin
    // The local tree walker reports nothing, so ask the filesystem the question
    // the caller actually has: is the directory gone?
    DeleteTree(Args[0].Str);
    ok := not DirectoryExists(Args[0].Str);
  end
  else
    ok := RemoveDir(Args[0].Str);
  if ok then GIoError := 0 else GIoError := 3;   // 3 ~ the operation was refused
  Result := ValInt(Ord(ok));
end;
function t_dir_getfiles(const Args: array of TValue; out Err: TPhosphorError): TValue;
var pat: String; rec: Boolean;
begin
  Err := NoError();
  if Length(Args) >= 2 then pat := Args[1].Str else pat := '*';
  rec := (Length(Args) >= 3) and (AsDouble(Args[2]) <> 0);
  Result := ValStr(ListToStr(Args[0].Str, pat, True, False, rec));
end;
function t_dir_getdirectories(const Args: array of TValue; out Err: TPhosphorError): TValue;
var pat: String; rec: Boolean;
begin
  Err := NoError();
  if Length(Args) >= 2 then pat := Args[1].Str else pat := '*';
  rec := (Length(Args) >= 3) and (AsDouble(Args[2]) <> 0);
  Result := ValStr(ListToStr(Args[0].Str, pat, False, True, rec));
end;
function t_dir_getentries(const Args: array of TValue; out Err: TPhosphorError): TValue;
var pat: String;
begin
  Err := NoError();
  if Length(Args) >= 2 then pat := Args[1].Str else pat := '*';
  Result := ValStr(ListToStr(Args[0].Str, pat, True, True, False));
end;
function t_dir_getparent(const Args: array of TValue; out Err: TPhosphorError): TValue;
var p: String; sep: Integer;
begin
  Err := NoError(); p := Args[0].Str;
  if (p <> '') and ((p[Length(p)] = '/') or (p[Length(p)] = '\')) then SetLength(p, Length(p) - 1);
  sep := LastSepIdx(p);
  if sep > 0 then Result := ValStr(Copy(p, 1, sep - 1)) else Result := ValStr('');
end;
function t_dir_isrelativepath(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(Ord(not IsRooted(Args[0].Str))); end;
function t_dir_getcurrent(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValStr(GetCurrentDir); end;
function t_dir_setcurrent(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); SetCurrentDir(Args[0].Str); Result := ValInt(1); end;
function t_dir_copy(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(Ord(CopyTree(Args[0].Str, Args[1].Str))); end;
function t_dir_move(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(Ord(RenameFile(Args[0].Str, Args[1].Str))); end;

// --- file copy/move/content -------------------------------------------------
function t_file_copy(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if (Length(Args) >= 3) and (AsDouble(Args[2]) = 0) and FileExists(Args[1].Str) then
  begin Result := ValInt(0); Exit; end;   // no overwrite, target exists
  Result := ValInt(Ord(CopyFileBytes(Args[0].Str, Args[1].Str)));
end;
function t_file_move(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(Ord(RenameFile(Args[0].Str, Args[1].Str))); end;
function t_file_createempty(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(Ord(WriteAllBytes(Args[0].Str, ''))); end;
function t_file_getsize(const Args: array of TValue; out Err: TPhosphorError): TValue;
var fs: TFileStream;
begin
  Err := NoError(); Result := ValInt(0);
  try
    fs := TFileStream.Create(Args[0].Str, fmOpenRead or fmShareDenyNone);
    try Result := ValInt(fs.Size); finally fs.Free; end;
  except end;
end;
function t_file_appendalltext(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: String;
begin
  Err := NoError();
  ReadAllBytes(Args[0].Str, s);
  Result := ValInt(Ord(WriteAllBytes(Args[0].Str, s + Args[1].Str)));
end;

// --- bytes (a handle-backed buffer) -----------------------------------------
function t_file_readallbytes(const Args: array of TValue; out Err: TPhosphorError): TValue;
var b: TPhosphorBytes;
begin
  Err := NoError();
  b := TPhosphorBytes.Create();
  ReadAllBytes(Args[0].Str, b.Data);
  Result := ValHandle(RegisterHandle(b));
end;
function t_file_writeallbytes(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  // A bogus handle writes nothing (0) rather than obeying.
  Err := NoError();
  if (Args[1].Kind = vkHandle) and IsHandle(Args[1].Hnd) and (HandleObj(Args[1].Hnd) is TPhosphorBytes) then
    Result := ValInt(Ord(WriteAllBytes(Args[0].Str, TPhosphorBytes(HandleObj(Args[1].Hnd)).Data)))
  else
    Result := ValInt(0);
end;

// --- timestamps: files are real (FileSetDate/FileAge); dirs are in-process --
function t_file_settime(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); FileSetDate(Args[0].Str, DateTimeToFileDate(AsDouble(Args[1]))); Result := ValInt(1); end;
function t_file_gettime(const Args: array of TValue; out Err: TPhosphorError): TValue;
var age: LongInt;
begin
  Err := NoError(); age := FileAge(Args[0].Str);
  if age > 0 then Result := ValDouble(FileDateToDateTime(age)) else Result := ValInt(0);
end;
function DirTimeKey(AKind: Char; const APath: String): String;
begin Result := AKind + APath; end;
function t_dir_settime_c(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); GDirTimes.Values[DirTimeKey('c', Args[0].Str)] := DtToStr(AsDouble(Args[1])); Result := ValInt(1); end;
function t_dir_settime_w(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); GDirTimes.Values[DirTimeKey('w', Args[0].Str)] := DtToStr(AsDouble(Args[1])); Result := ValInt(1); end;
function t_dir_settime_a(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); GDirTimes.Values[DirTimeKey('a', Args[0].Str)] := DtToStr(AsDouble(Args[1])); Result := ValInt(1); end;
function t_dir_gettime_c(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(StrToDt(GDirTimes.Values[DirTimeKey('c', Args[0].Str)])); end;
function t_dir_gettime_w(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(StrToDt(GDirTimes.Values[DirTimeKey('w', Args[0].Str)])); end;
function t_dir_gettime_a(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValDouble(StrToDt(GDirTimes.Values[DirTimeKey('a', Args[0].Str)])); end;

// --- path extras ------------------------------------------------------------
function t_path_combine(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if Length(Args) >= 3 then Result := ValStr(Combine2(Combine2(Args[0].Str, Args[1].Str), Args[2].Str))
  else Result := ValStr(Combine2(Args[0].Str, Args[1].Str));
end;
function t_path_getdirectoryname(const Args: array of TValue; out Err: TPhosphorError): TValue;
var p: String; sep: Integer;
begin
  Err := NoError(); p := Args[0].Str; sep := LastSepIdx(p);
  if sep > 0 then Result := ValStr(Copy(p, 1, sep - 1)) else Result := ValStr('');
end;
function t_path_hasextension(const Args: array of TValue; out Err: TPhosphorError): TValue;
var p: String; sep, dot, i: Integer;
begin
  Err := NoError(); p := Args[0].Str; sep := LastSepIdx(p); dot := 0;
  for i := Length(p) downto sep + 1 do
    if p[i] = '.' then begin dot := i; Break; end;
  Result := ValInt(Ord(dot > 0));
end;
function t_path_getfullpath(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValStr(ExpandFileName(Args[0].Str)); end;
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
  Result := ValInt(Ord(MatchGlob(Args[0].Str, Args[1].Str, cs)));
end;
function HasValidChars(const S: String; AForFile: Boolean): Boolean;
var i: Integer; c: Char;
begin
  Result := True;
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if Ord(c) < 32 then Exit(False);
    if AForFile and (c in ['/', '\', ':', '*', '?', '"', '<', '>', '|']) then Exit(False);
  end;
end;
function t_path_hasvalidpathchars(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(Ord(HasValidChars(Args[0].Str, False))); end;
function t_path_hasvalidfilenamechars(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(Ord(HasValidChars(Args[0].Str, True))); end;

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
end;

initialization
  GDirTimes := TStringList.Create();

finalization
  GDirTimes.Free;

end.
