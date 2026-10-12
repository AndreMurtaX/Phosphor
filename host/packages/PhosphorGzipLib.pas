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
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorSandbox, PhosphorBudget,
  PhosphorIoLib;

procedure RegisterGzipFuncs(Reg: TPhosphorRegistry);

implementation

var
  GzipErr: Integer = 0;           // 0 = the last gzip op was clean; 1 = it failed
  // There USED TO BE a GzipSpent global here -- "the last inflate stopped on the
  // budget" -- reset only when an inflate began. A call that never began one (its
  // source was missing) read the previous call's answer and reported a missing
  // file as a budget refusal (ledger n3). RawInflate now answers it through an
  // out parameter, so there is no previous answer left to read.
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

function RawInflate(const Src: RawByteString; out Spent: Boolean): RawByteString;
var inp, outs: TMemoryStream; ds: Tdecompressionstream; buf: array[0..65535] of Byte; n: LongInt;
begin
  Result := '';
  Spent := False;
  inp := TMemoryStream.Create();
  outs := TMemoryStream.Create();
  try
    if Length(Src) > 0 then inp.WriteBuffer(Src[1], Length(Src));
    inp.Position := 0;
    ds := Tdecompressionstream.Create(inp, True);
    try
      { A DECOMPRESSION BOMB IS THE SIZE THAT IS NOT DERIVABLE FROM ITS ARGUMENT.
        Forty kilobytes of gzip expand to ten gigabytes, and the whole expansion
        happens inside one opCall where no execution ceiling can see it -- the
        argument says nothing about how big the answer will be, so RULE 1 cannot
        apply and RULE 2 does: charge each 64 KB block as it comes out and stop
        when the budget is spent. Spent keeps a truncated result from reading as a
        successful one -- and the CALLER must ask it before doing anything with
        the result, which is where d14 was. }
      repeat
        n := ds.Read(buf, SizeOf(buf));
        if n > 0 then outs.WriteBuffer(buf, n);
        if (n > 0) and (not BudgetCharge(n)) then
        begin
          Spent := True;
          Break;
        end;
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
{ THE PATH AND THE FILE ARE BOTH PRICED, BEFORE EITHER IS TOUCHED (round 9).
  The path is the script's: the gate reads it whole and the OS converts it, and
  nothing asked about it -- the engine's own doors have priced a path at IoGate
  since round 7, and this package's file doors ran 30 s on a 4 MB path under a
  budget worth 2000 ms. And the file's size was committed (SetLength) before
  anything was asked, where file_readalltext$ asks first; the read was charged
  only after it had been made. Both are asked here, and both refusals are
  written into the caller's error, as AWho's. }
function LoadFileStr(const AWho, APath: String; out S: RawByteString;
                     var Err: TPhosphorError): Boolean;
var fs: TFileStream; len: Int64;
begin
  Result := False;
  S := '';
  if not BudgetLinearOk(AWho, Length(APath), BudgetMilliOs, Err) then Exit;
  if not SandboxAllows(APath, puRead) then Exit;
  if IoSpecialKind(APath) <> '' then Exit;   // a FIFO's open blocks (round 11)
  try
    fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      len := fs.Size;
      // The read is a copy of the file: charged at that rate, before it is made.
      if not BudgetLinearOk(AWho, len, BudgetMilliCopy, Err) then Exit;
      SetLength(S, len);
      if len > 0 then fs.ReadBuffer(S[1], len);
      Result := True;
    finally
      fs.Free;
    end;
  except
    Result := False;
  end;
end;

function SaveFileStr(const AWho, APath: String; const S: RawByteString;
                     var Err: TPhosphorError): Boolean;
var fs: TFileStream;
begin
  Result := False;
  if not BudgetLinearOk(AWho, Length(APath), BudgetMilliOs, Err) then Exit;
  if not SandboxAllows(APath, puWrite) then Exit;
  if IoSpecialKind(APath) <> '' then Exit;
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
{ DEFLATE IS PRICED BY ITS INPUT (round 7). Measured (-O2, no ceilings, 2 MB):
  random bytes 29 ns a byte, English-like text 42 ns at level 6 and 76 ns at
  level 9 -- the level-9 lazy matcher walks longer chains. It was priced at
  80 ns a byte whatever the level and whatever the data.

  AND THE DATA DECIDES IT TENFOLD, SO IT IS CHARGED WHAT IT TOOK (round 8). The
  price sweep (tests/probe_limits.lpr --prices) measured, per input byte: one
  byte repeated 3.3 ns at level 1, a repetitive text 7 ns, this tree's own
  reference 14.5 / 36 / 50 ns at levels 1 / 6 / 9, random bytes 28-30 ns at
  every level -- so the 80 ns price charged a log file eleven times what
  compressing it cost, and no single per-byte price can sit within a factor of
  two of all of them. So the deflate is asked, up front, for the FLOOR -- the
  cheapest input there is, GzipFloorMilli -- which still refuses a gigabyte
  before a byte is compressed, and is then charged the wall time it actually
  took, less the floor already paid, the moment it returns. That is the
  budget's own scale (BudgetUnitsPerMsOfWork a millisecond), and it is the rule
  the HTTP package already follows for a wait on the network: work that cannot
  be sized is charged as it is measured. An overrun is at most one call, and
  the charge latches the budget for the next. The CRC pass is in the time.
  Decompression is metered by what it writes. }
const
  GzipFloorMilli = 384;

{ The time a deflate took, beyond the floor it was asked for. False = the budget
  is spent (latched); the deflate's answer is then not handed back. }
function DeflateCharged(const AWho: String; AStart: QWord; ABytes: Int64;
                        var Err: TPhosphorError): Boolean;
var took, extra: Int64;
begin
  Result := True;
  if not BudgetActive() then Exit;
  took := Int64(GetTickCount64() - AStart);
  extra := took * BudgetUnitsPerMsOfWork - BudgetMilliUnits(ABytes, GzipFloorMilli);
  if (extra > 0) and not BudgetCharge(extra) then
  begin
    Err := BudgetRefusal(AWho);
    Result := False;
  end;
end;

function f_gzip_compress(const Args: array of TValue; out Err: TPhosphorError): TValue;
var t0: QWord;
begin
  Err := NoError();
  if not BudgetLinearOk('gzip_compress$', Length(Args[0].Str), GzipFloorMilli, Err) then
    Exit(ValStr(''));
  try
    t0 := GetTickCount64();
    Result := ValStr(GzipWrap(Args[0].Str, 6));
    if not DeflateCharged('gzip_compress$', t0, Length(Args[0].Str), Err) then Exit(ValStr(''));
    GzipErr := 0;
  except
    Result := ValStr('');
    GzipErr := 1;
  end;
end;

function f_gzip_compress_lvl(const Args: array of TValue; out Err: TPhosphorError): TValue;
var t0: QWord;
begin
  Err := NoError();
  if not BudgetLinearOk('gzip_compress$', Length(Args[0].Str), GzipFloorMilli, Err) then
    Exit(ValStr(''));
  try
    t0 := GetTickCount64();
    Result := ValStr(GzipWrap(Args[0].Str, ArgI32(Args[1])));
    if not DeflateCharged('gzip_compress$', t0, Length(Args[0].Str), Err) then Exit(ValStr(''));
    GzipErr := 0;
  except
    Result := ValStr('');
    GzipErr := 1;
  end;
end;

function f_gzip_decompress(const Args: array of TValue; out Err: TPhosphorError): TValue;
var body, plain: RawByteString; spent: Boolean;
begin
  Err := NoError();
  try
    if GzipUnwrap(Args[0].Str, body) then
    begin
      plain := RawInflate(body, spent);
      if spent then
      begin
        Err := BudgetRefusal('gzip_decompress$');
        GzipErr := 1;
        Exit(ValStr(''));
      end;
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

function DoCompressFile(const Src, Dst: String; ALevel: Integer;
                        var Err: TPhosphorError): Boolean;
var raw, gz: RawByteString; t0: QWord;
begin
  Result := False;
  if not LoadFileStr('gzip_compressfile', Src, raw, Err) then Exit;
  // The read was charged by LoadFileStr; the deflate's floor is asked before
  // it runs, and its time once it has -- and nothing is written if that is
  // refused.
  if not BudgetLinearOk('gzip_compressfile', Length(raw), GzipFloorMilli, Err) then Exit;
  t0 := GetTickCount64();
  gz := GzipWrap(raw, ALevel);
  if not DeflateCharged('gzip_compressfile', t0, Length(raw), Err) then Exit;
  Result := SaveFileStr('gzip_compressfile', Dst, gz, Err);
end;

function f_gzip_compressfile(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  try
    if DoCompressFile(Args[0].Str, Args[1].Str, 6, Err) then
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
    if DoCompressFile(Args[0].Str, Args[1].Str, ArgI32(Args[2]), Err) then
    begin Result := ValInt(1); GzipErr := 0; end
    else begin Result := ValInt(0); GzipErr := 1; end;
  except
    Result := ValInt(0); GzipErr := 1;
  end;
end;

{ DECIDE, THEN WRITE (ledger d14). This was one boolean chain ending in
  SaveFileStr(Dst, RawInflate(body)), with the budget asked AFTER it: a refused
  inflate had already truncated the destination and written whatever fitted over
  it, so the refusal arrived after the damage. The destination is now touched only
  by an inflate that finished. }
function f_gzip_decompressfile(const Args: array of TValue; out Err: TPhosphorError): TValue;
var raw, body, plain: RawByteString; spent: Boolean;
begin
  Err := NoError();
  Result := ValInt(0);
  GzipErr := 1;
  try
    if not (LoadFileStr('gzip_decompressfile', Args[0].Str, raw, Err) and
            GzipUnwrap(raw, body)) then Exit;
    plain := RawInflate(body, spent);
    if spent then
    begin
      Err := BudgetRefusal('gzip_decompressfile');
      Exit;
    end;
    if SaveFileStr('gzip_decompressfile', Args[1].Str, plain, Err) then
    begin Result := ValInt(1); GzipErr := 0; end;
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
