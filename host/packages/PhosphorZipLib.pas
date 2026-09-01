{******************************************************************************
  Phosphor BASIC -- zip archives (an OPT-IN host package)

  MIT License. Copyright (c) 2026 Andre Murta.

  An opt-in package (host/packages/, RegisterZipFuncs) over FPC's paszlib zipper,
  which ships with the compiler -- no external runtime library. The engine stays
  free of it; a host that wants archives registers it.

    zip_compress(zip$, srcdir$)   zip the files directly in srcdir into zip$  -> 1/0
    unzip_extract(zip$, destdir$) extract zip$ into destdir                   -> 1/0
    unzip_count(zip$)             number of entries in the archive
    unzip_entry$(zip$, n)         the n-th entry name (1-based)

  Failures are answered (0 / "") rather than raised, matching the engine's I/O
  contract.
******************************************************************************}
unit PhosphorZipLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Zipper,
  PhosphorValue, PhosphorErrors, PhosphorRegistry;

procedure RegisterZipFuncs(Reg: TPhosphorRegistry);

implementation

function f_zip_compress(const Args: array of TValue; out Err: TPhosphorError): TValue;
var z: TZipper; sr: TSearchRec; base: String;
begin
  Err := NoError;
  Result := ValInt(0);
  try
    z := TZipper.Create;
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
    finally
      z.Free;
    end;
  except
    Result := ValInt(0);
  end;
end;

function f_unzip_extract(const Args: array of TValue; out Err: TPhosphorError): TValue;
var uz: TUnZipper;
begin
  Err := NoError;
  Result := ValInt(0);
  try
    uz := TUnZipper.Create;
    try
      uz.FileName := Args[0].Str;
      uz.OutputPath := Args[1].Str;
      uz.Examine;
      uz.UnZipAllFiles;
      Result := ValInt(1);
    finally
      uz.Free;
    end;
  except
    Result := ValInt(0);
  end;
end;

function f_unzip_count(const Args: array of TValue; out Err: TPhosphorError): TValue;
var uz: TUnZipper;
begin
  Err := NoError;
  Result := ValInt(0);
  try
    uz := TUnZipper.Create;
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
  Err := NoError;
  Result := ValStr('');
  try
    uz := TUnZipper.Create;
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

procedure RegisterZipFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('zip_compress:$$',  @f_zip_compress);
  Reg.Add('unzip_extract:$$', @f_unzip_extract);
  Reg.Add('unzip_count:$',    @f_unzip_count);
  Reg.Add('unzip_entry$:$n',  @f_unzip_entry);
end;

end.
