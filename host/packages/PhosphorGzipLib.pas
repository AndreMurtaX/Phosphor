{******************************************************************************
  Phosphor BASIC -- gzip (RFC 1952) compression (an OPT-IN host package)

  MIT License. Copyright (c) 2026 Andre Murta.

  An opt-in package (host/packages/, RegisterGzipFuncs) that produces and reads
  real gzip streams -- the 10-byte gzip header, a raw DEFLATE body, and the
  CRC32 + ISIZE trailer -- so gzip_compressfile writes a .gz a system `gunzip`
  can open, not merely a private format. The DEFLATE codec is FPC's paszlib
  (`zstream`, pure Pascal), which ships WITH the compiler -- no external runtime
  library, so this runs on both OSes unconditionally.

    gzip_compress$(s$)            gzip a string  -> the packed bytes as a string
    gzip_compress$(s$, level)     ... at a stated zlib level (0..9)
    gzip_decompress$(s$)          ungzip a packed string -> the original bytes
    gzip_compressfile(src$,dst$)  gzip a file                              -> 1/0
    gzip_compressfile(src$,dst$,level)                                     -> 1/0
    gzip_decompressfile(src$,dst$)  ungzip a file                          -> 1/0
    gzip_size(s$)                 byte length of the original text
    gzip_csize(s$)               byte length of a packed form
    gzip_ratio(orig$, packed$)   packed/original, a number < 1 when it shrank
    gzip_error()                 code of the most recent gzip op (0 = clear)

  Failures are answered (0 / "") and recorded in gzip_error(), never raised,
  matching the engine's I/O contract.

  This also completes oracle 11's gzip half; 11's regex is covered by
  31_regex_dict_num and its base64 by 00_base64, so no separate 11 file exists.
******************************************************************************}
unit PhosphorGzipLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, zstream,
  PhosphorValue, PhosphorErrors, PhosphorRegistry;

procedure RegisterGzipFuncs(Reg: TPhosphorRegistry);

implementation

var
  GzipErr: Integer = 0;           // 0 = the last gzip op was clean; 1 = it failed
  Crc32Table: array[0..255] of Cardinal;

// --- CRC32 (IEEE, reflected 0xEDB88320) -- self-contained, no inline note ----
procedure BuildCrc32Table;
var i, j: Integer; c: Cardinal;
begin
  for i := 0 to 255 do
  begin
    c := Cardinal(i);
    for j := 0 to 7 do
      if (c and 1) <> 0 then c := $EDB88320 xor (c shr 1)
      else c := c shr 1;
    Crc32Table[i] := c;
  end;
end;

function Crc32Str(const S: RawByteString): Cardinal;
var i: Integer; c: Cardinal;
begin
  c := $FFFFFFFF;
  for i := 1 to Length(S) do
    c := Crc32Table[(c xor Byte(S[i])) and $FF] xor (c shr 8);
  Result := c xor $FFFFFFFF;
end;

// --- raw DEFLATE / INFLATE (no zlib header, no adler) via paszlib zstream -----
function LevelOf(ALevel: Integer): Tcompressionlevel;
begin
  if ALevel <= 0 then Result := clnone
  else if ALevel <= 2 then Result := clfastest
  else if ALevel <= 8 then Result := cldefault
  else Result := clmax;
end;

function RawDeflate(const Src: RawByteString; ALevel: Integer): RawByteString;
var mem: TMemoryStream; cs: Tcompressionstream;
begin
  Result := '';
  mem := TMemoryStream.Create();
  try
    cs := Tcompressionstream.Create(LevelOf(ALevel), mem, True);
    try
      if Length(Src) > 0 then cs.WriteBuffer(Src[1], Length(Src));
    finally
      cs.Free;   // Destroy flushes the remaining deflate output
    end;
    SetLength(Result, mem.Size);
    if mem.Size > 0 then
    begin
      mem.Position := 0;
      mem.ReadBuffer(Result[1], mem.Size);
    end;
  finally
    mem.Free;
  end;
end;

function RawInflate(const Src: RawByteString): RawByteString;
var inp, outs: TMemoryStream; ds: Tdecompressionstream; buf: array[0..65535] of Byte; n: LongInt;
begin
  Result := '';
  inp := TMemoryStream.Create();
  outs := TMemoryStream.Create();
  try
    if Length(Src) > 0 then inp.WriteBuffer(Src[1], Length(Src));
    inp.Position := 0;
    ds := Tdecompressionstream.Create(inp, True);
    try
      repeat
        n := ds.Read(buf, SizeOf(buf));
        if n > 0 then outs.WriteBuffer(buf, n);
      until n < SizeOf(buf);   // a short read means the DEFLATE stream ended
    finally
      ds.Free;
    end;
    SetLength(Result, outs.Size);
    if outs.Size > 0 then
    begin
      outs.Position := 0;
      outs.ReadBuffer(Result[1], outs.Size);
    end;
  finally
    inp.Free;
    outs.Free;
  end;
end;

// --- gzip container ---------------------------------------------------------
function LE32(V: Cardinal): RawByteString;
begin
  SetLength(Result, 4);
  Result[1] := Chr(V and $FF);
  Result[2] := Chr((V shr 8) and $FF);
  Result[3] := Chr((V shr 16) and $FF);
  Result[4] := Chr((V shr 24) and $FF);
end;

function GzipWrap(const Src: RawByteString; ALevel: Integer): RawByteString;
var hdr: RawByteString;
begin
  // magic 1F 8B, CM=8 (deflate), FLG=0, MTIME=0, XFL=0, OS=FF (unknown).
  // Build it byte-by-byte with Chr, NOT a string literal: under {$codepage UTF8}
  // a literal #$8B/#$FF is re-encoded as its multi-byte UTF-8 form and corrupts
  // the header. Chr() at runtime yields a single raw byte.
  SetLength(hdr, 10);
  hdr[1] := Chr($1F); hdr[2] := Chr($8B); hdr[3] := Chr($08); hdr[4] := Chr($00);
  hdr[5] := Chr($00); hdr[6] := Chr($00); hdr[7] := Chr($00); hdr[8] := Chr($00);
  hdr[9] := Chr($00); hdr[10] := Chr($FF);
  Result := hdr + RawDeflate(Src, ALevel) +
            LE32(Crc32Str(Src)) + LE32(Cardinal(Length(Src)));
end;

// Unwrap a gzip stream into its DEFLATE body, honouring the optional header
// fields any RFC-1952 producer may set (ours sets none, but be a real reader).
function GzipUnwrap(const Src: RawByteString; out Body: RawByteString): Boolean;
var flg: Byte; pos, xlen, last: Integer;
begin
  Result := False;
  Body := '';
  if Length(Src) < 18 then Exit;                        // header(10) + trailer(8)
  if (Byte(Src[1]) <> $1F) or (Byte(Src[2]) <> $8B) then Exit;
  if Byte(Src[3]) <> $08 then Exit;                     // only DEFLATE is defined
  flg := Byte(Src[4]);
  pos := 11;                                            // first byte past the fixed header
  if (flg and $04) <> 0 then                            // FEXTRA
  begin
    if pos + 1 > Length(Src) then Exit;
    xlen := Byte(Src[pos]) or (Byte(Src[pos + 1]) shl 8);
    Inc(pos, 2 + xlen);
  end;
  if (flg and $08) <> 0 then                            // FNAME  (NUL-terminated)
  begin
    while (pos <= Length(Src)) and (Src[pos] <> #0) do Inc(pos);
    Inc(pos);
  end;
  if (flg and $10) <> 0 then                            // FCOMMENT (NUL-terminated)
  begin
    while (pos <= Length(Src)) and (Src[pos] <> #0) do Inc(pos);
    Inc(pos);
  end;
  if (flg and $02) <> 0 then Inc(pos, 2);               // FHCRC
  last := Length(Src) - 8;                              // last body byte, trailer stripped
  if (pos > last) then Exit;
  Body := Copy(Src, pos, last - pos + 1);
  Result := True;
end;

// --- raw file I/O (bytes, no text conversion, no BOM) -----------------------
function LoadFileStr(const APath: String; out S: RawByteString): Boolean;
var fs: TFileStream;
begin
  Result := False;
  S := '';
  try
    fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      SetLength(S, fs.Size);
      if fs.Size > 0 then fs.ReadBuffer(S[1], fs.Size);
      Result := True;
    finally
      fs.Free;
    end;
  except
    Result := False;
  end;
end;

function SaveFileStr(const APath: String; const S: RawByteString): Boolean;
var fs: TFileStream;
begin
  Result := False;
  try
    fs := TFileStream.Create(APath, fmCreate);
    try
      if Length(S) > 0 then fs.WriteBuffer(S[1], Length(S));
      Result := True;
    finally
      fs.Free;
    end;
  except
    Result := False;
  end;
end;

// --- bound functions --------------------------------------------------------
function f_gzip_compress(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  try
    Result := ValStr(GzipWrap(Args[0].Str, 6));
    GzipErr := 0;
  except
    Result := ValStr('');
    GzipErr := 1;
  end;
end;

function f_gzip_compress_lvl(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  try
    Result := ValStr(GzipWrap(Args[0].Str, Round(AsDouble(Args[1]))));
    GzipErr := 0;
  except
    Result := ValStr('');
    GzipErr := 1;
  end;
end;

function f_gzip_decompress(const Args: array of TValue; out Err: TPhosphorError): TValue;
var body, plain: RawByteString;
begin
  Err := NoError();
  try
    if GzipUnwrap(Args[0].Str, body) then
    begin
      plain := RawInflate(body);
      Result := ValStr(plain);
      GzipErr := 0;
    end
    else
    begin
      Result := ValStr('');
      GzipErr := 1;
    end;
  except
    Result := ValStr('');
    GzipErr := 1;
  end;
end;

function DoCompressFile(const Src, Dst: String; ALevel: Integer): Boolean;
var raw: RawByteString;
begin
  Result := False;
  if not LoadFileStr(Src, raw) then Exit;
  Result := SaveFileStr(Dst, GzipWrap(raw, ALevel));
end;

function f_gzip_compressfile(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  try
    if DoCompressFile(Args[0].Str, Args[1].Str, 6) then
    begin Result := ValInt(1); GzipErr := 0; end
    else begin Result := ValInt(0); GzipErr := 1; end;
  except
    Result := ValInt(0); GzipErr := 1;
  end;
end;

function f_gzip_compressfile_lvl(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  try
    if DoCompressFile(Args[0].Str, Args[1].Str, Round(AsDouble(Args[2]))) then
    begin Result := ValInt(1); GzipErr := 0; end
    else begin Result := ValInt(0); GzipErr := 1; end;
  except
    Result := ValInt(0); GzipErr := 1;
  end;
end;

function f_gzip_decompressfile(const Args: array of TValue; out Err: TPhosphorError): TValue;
var raw, body: RawByteString;
begin
  Err := NoError();
  try
    if LoadFileStr(Args[0].Str, raw) and GzipUnwrap(raw, body) and
       SaveFileStr(Args[1].Str, RawInflate(body)) then
    begin Result := ValInt(1); GzipErr := 0; end
    else begin Result := ValInt(0); GzipErr := 1; end;
  except
    Result := ValInt(0); GzipErr := 1;
  end;
end;

function f_gzip_size(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(Length(Args[0].Str));
end;

function f_gzip_csize(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(Length(Args[0].Str));
end;

function f_gzip_ratio(const Args: array of TValue; out Err: TPhosphorError): TValue;
var orig: Integer;
begin
  Err := NoError();
  orig := Length(Args[0].Str);
  if orig = 0 then Result := ValDouble(0)
  else Result := ValDouble(Length(Args[1].Str) / orig);
end;

function f_gzip_error(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(GzipErr);
end;

procedure RegisterGzipFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('gzip_compress$:$',        @f_gzip_compress);
  Reg.Add('gzip_compress$:$n',       @f_gzip_compress_lvl);
  Reg.Add('gzip_decompress$:$',      @f_gzip_decompress);
  Reg.Add('gzip_compressfile:$$',    @f_gzip_compressfile);
  Reg.Add('gzip_compressfile:$$n',   @f_gzip_compressfile_lvl);
  Reg.Add('gzip_decompressfile:$$',  @f_gzip_decompressfile);
  Reg.Add('gzip_size:$',             @f_gzip_size);
  Reg.Add('gzip_csize:$',            @f_gzip_csize);
  Reg.Add('gzip_ratio:$$',           @f_gzip_ratio);
  Reg.Add('gzip_error:',             @f_gzip_error);
end;

initialization
  BuildCrc32Table();

end.
