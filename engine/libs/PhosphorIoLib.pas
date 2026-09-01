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
  PhosphorValue, PhosphorErrors, PhosphorRegistry;

procedure RegisterIoFuncs(Reg: TPhosphorRegistry);

implementation

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
  Err := NoError;
  Result := ValInt(Ord(WriteAllBytes(Args[0].Str, Args[1].Str)));
end;
function t_file_readalltext(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: String;
begin
  Err := NoError;
  ReadAllBytes(Args[0].Str, s);
  Result := ValStr(s);
end;
function t_file_exists(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  Result := ValInt(Ord(FileExists(Args[0].Str)));
end;
function t_file_delete(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  Result := ValInt(Ord(DeleteFile(Args[0].Str)));
end;

// savetext$/opentext$: the encoding argument is accepted; utf-8 is raw bytes,
// which is what the whole engine already speaks.
function t_savetext(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  WriteAllBytes(Args[0].Str, Args[2].Str);
  Result := ValStr(Args[0].Str);
end;
function t_opentext(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: String;
begin
  Err := NoError;
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
  Err := NoError; p := Args[0].Str;
  Result := ValStr(Copy(p, LastSep(p) + 1, MaxInt));
end;
function t_path_getextension(const Args: array of TValue; out Err: TPhosphorError): TValue;
var p: String; sep, dot: Integer;
begin
  Err := NoError; p := Args[0].Str;
  sep := LastSep(p);
  dot := LastDotAfter(p, sep);
  if dot > 0 then Result := ValStr(Copy(p, dot, MaxInt)) else Result := ValStr('');
end;
function t_path_getfilenamenoext(const Args: array of TValue; out Err: TPhosphorError): TValue;
var p, fn: String; sep, dot: Integer;
begin
  Err := NoError; p := Args[0].Str;
  sep := LastSep(p);
  fn := Copy(p, sep + 1, MaxInt);
  dot := LastDotAfter(p, sep);
  if dot > 0 then Result := ValStr(Copy(p, sep + 1, dot - sep - 1)) else Result := ValStr(fn);
end;
function t_path_changeextension(const Args: array of TValue; out Err: TPhosphorError): TValue;
var p, ext: String; sep, dot: Integer;
begin
  Err := NoError; p := Args[0].Str; ext := Args[1].Str;
  sep := LastSep(p);
  dot := LastDotAfter(p, sep);
  if dot > 0 then Result := ValStr(Copy(p, 1, dot - 1) + ext) else Result := ValStr(p + ext);
end;

// the directory part, WITH its trailing separator ("C:\folder\notes.txt" ->
// "C:\folder\"); empty when the path has no separator.
function t_extractfilepath(const Args: array of TValue; out Err: TPhosphorError): TValue;
var p: String;
begin
  Err := NoError; p := Args[0].Str;
  Result := ValStr(Copy(p, 1, LastSep(p)));
end;

function t_dir_exists(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  Result := ValInt(Ord(DirectoryExists(Args[0].Str)));
end;

procedure RegisterIoFuncs(Reg: TPhosphorRegistry);
begin
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

end.
