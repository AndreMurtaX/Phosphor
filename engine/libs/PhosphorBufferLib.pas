{******************************************************************************
  Phosphor BASIC -- the byte buffer (a function package under engine/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  The founding brief settled binary I/O in one line: "no scalar BYTE type --
  binary I/O uses a buffer as a handle (`buf@ = buffer_new(1024)`), which is
  pure library, zero cost in the parser and in the VM" (decisions.md). The
  handle existed and the buffer did not: `file_readallbytes@` already handed
  back a TPhosphorBytes, but nothing could look inside one. You could carry a
  file's bytes from a read to a write and no further -- not read byte 5, not
  change it, not build one from nothing.

  ONE SPELLING NOTE. The brief wrote `buf@ = buffer_new(1024)`, which predates the
  rule that a built-in's RETURN TYPE comes from the suffix on its own name. Under
  that rule the constructor must be `buffer_new@`, exactly as `dim@`, `strings@`
  and `json_parse@` are spelled -- the `@` on the left of the `=` types the
  variable, the `@` in the name types the function. The brief's intent is intact;
  only the spelling follows the language that grew out of it.

  So this package is the missing half, and it deliberately does NOT introduce a
  type: it operates on the SAME TPhosphorBytes the Io package already hands out,
  which is what makes the composition work --

      buf@ = file_readallbytes@("in.bin")     ' the existing reader
      buffer_set(buf@, 1, 255)                ' now it is inspectable
      file_writeallbytes("out.bin", buf@)     ' the existing writer

  WHY NOT JUST USE STRINGS. `bytelen`/`byteat`/`bytestr$`/`bytemid$` (StrLib)
  already read bytes out of a string, and for reading that is enough. Writing is
  where a string fails: a string is immutable, so changing one byte of an n-byte
  payload rebuilds all n. A loop over a buffer is then quadratic -- the exact
  trap that made hex_encode$ cost 37 s for 64 MB before it was rewritten to
  index into a preallocated result. A buffer is mutable in place, so the same
  loop is linear. Use bytemid$ to inspect a string; use a buffer to build one.

  BASE-1, like everything else in the language: the first byte is at position 1.
  Byte values are 0..255. Every out-of-range position, count or value is a
  RETURNED error (catchable with `on error goto`), never a raise and never a
  silent clamp -- reading past the end of a buffer is a bug in the program, and
  quietly returning 0 would hide it.

  THE CODEPAGE RULE APPLIES HERE MORE THAN ANYWHERE. This unit is compiled under
  the UTF8 codepage directive, where building a string by concatenation re-encodes
  any byte >= 128 into its multi-byte UTF-8 form. Every operation below therefore
  touches bytes only through SetLength, an indexed read/write, Copy or Move --
  there is not one `+` on a byte string in this file, and there must never be one.

    buffer_new@(n)              n zero bytes            buffer_free(b@)  lenient
    buffer_fromstr@(s$)         a copy of s$'s bytes    buffer_clone@(b@)
    buffer_len(b@)              buffer_resize(b@, n)
    buffer_get(b@, i)           buffer_set(b@, i, v)
    buffer_fill(b@, v)          buffer_fillrange(b@, i, n, v)
    buffer_tostr$(b@)           buffer_slice$(b@, i, n)
    buffer_write(b@, i, s$)     buffer_copy(dst@, di, src@, si, n)
    buffer_indexof(b@, pat$[, from])                    buffer_equal(a@, b@)
    buffer_getint / buffer_getuint / buffer_setint      width 1|2|4|8, LE or BE
    buffer_getdbl / buffer_setdbl (8 bytes)   buffer_getsng / buffer_setsng (4)

  RETURN VALUES CARRY INFORMATION, not a success flag. Failure is already a
  returned ERROR, so a mutator that returned "did it work" would always say the
  same thing. Following arr_set (returns the value stored) and strings_add
  (returns the index it took): buffer_set returns the byte written, _write and
  _copy and _fill return the byte COUNT, _resize returns the new length, and the
  setint/setdbl/setsng trio return the value written. buffer_equal and
  buffer_free return 1 or 0, the shape file_exists established.
******************************************************************************}
unit PhosphorBufferLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles, PhosphorIoLib;

procedure RegisterBufferFuncs(Reg: TPhosphorRegistry);

implementation

// --- argument helpers --------------------------------------------------------
// A numeric argument arrives as a Double ('n' slot) or an Int64 ('%' slot). It
// comes from the program, so it can be NaN, huge, or negative; converting it
// must not overflow. Same crash-proof shape as StrLib's ArgI32.
function ArgI64(const V: TValue): Int64;
var d: Double;
begin
  if V.Kind = vkInt then Exit(V.Int);
  d := AsDouble(V);
  if d <> d then Result := 0                              // NaN
  else if d >= 9223372036854775808.0 then Result := High(Int64)
  else if d <= -9223372036854775808.0 then Result := Low(Int64)
  else Result := Round(d);
end;

function ArgI32(const V: TValue): Integer;
var i: Int64;
begin
  i := ArgI64(V);
  if i > High(Integer) then Result := High(Integer)
  else if i < Low(Integer) then Result := Low(Integer)
  else Result := Integer(i);
end;

// Resolve a handle to the buffer it names. A fabricated or stale handle is
// REJECTED here (IsHandle), never dereferenced -- the property the handle
// registry exists to give.
function GetBuf(const AFn: String; const V: TValue; out B: TPhosphorBytes;
  out Err: TPhosphorError): Boolean;
begin
  B := nil;
  Result := False;
  if (V.Kind <> vkHandle) or (not IsHandle(V.Hnd)) or
     (not (HandleObj(V.Hnd) is TPhosphorBytes)) then
  begin
    Err := MakeError(peRuntime, AFn + ': not a valid buffer handle');
    Exit;
  end;
  B := TPhosphorBytes(HandleObj(V.Hnd));
  Err := NoError();
  Result := True;
end;

// A base-1 range check shared by every positional operation. `count` may be 0
// (an empty range at any valid position, and at Length+1, is legal and is a
// no-op) -- what is never legal is a range that runs off either end.
function CheckRange(const AFn: String; ALen: Integer; APos, ACount: Int64;
  out Err: TPhosphorError): Boolean;
begin
  Result := False;
  if ACount < 0 then
  begin
    Err := MakeError(peRuntime, AFn + ': count ' + IntToStr(ACount) + ' is negative');
    Exit;
  end;
  if (APos < 1) or (APos > Int64(ALen) + 1) then
  begin
    Err := MakeError(peRuntime, AFn + ': position ' + IntToStr(APos) +
      ' is outside 1..' + IntToStr(ALen + 1) + ' (buffer holds ' + IntToStr(ALen) + ' bytes)');
    Exit;
  end;
  if APos + ACount - 1 > Int64(ALen) then
  begin
    Err := MakeError(peRuntime, AFn + ': ' + IntToStr(ACount) + ' bytes from position ' +
      IntToStr(APos) + ' runs past the end (buffer holds ' + IntToStr(ALen) + ' bytes)');
    Exit;
  end;
  Err := NoError();
  Result := True;
end;

function CheckByte(const AFn: String; AVal: Int64; out Err: TPhosphorError): Boolean;
begin
  if (AVal < 0) or (AVal > 255) then
  begin
    Err := MakeError(peRuntime, AFn + ': ' + IntToStr(AVal) + ' is not a byte value (0..255)');
    Exit(False);
  end;
  Err := NoError();
  Result := True;
end;

// --- lifecycle ---------------------------------------------------------------
function NewBuffer(ASize: Integer): TPhosphorBytes;
begin
  Result := TPhosphorBytes.Create();
  SetLength(Result.Data, ASize);
  if ASize > 0 then
    FillChar(Result.Data[1], ASize, 0);   // a new buffer is zero, not garbage
end;

function f_buffer_new(const A: array of TValue; out E: TPhosphorError): TValue;
var n: Int64;
begin
  Result := ValHandle(0);
  n := ArgI64(A[0]);
  if n < 0 then
  begin
    E := MakeError(peRuntime, 'buffer_new: size ' + IntToStr(n) + ' is negative');
    Exit;
  end;
  if n > 1073741824 then   // 1 GiB: a typo like buffer_new(1e12) must not try to allocate it
  begin
    E := MakeError(peRuntime, 'buffer_new: size ' + IntToStr(n) + ' exceeds the 1 GiB limit');
    Exit;
  end;
  E := NoError();
  Result := ValHandle(RegisterHandle(NewBuffer(Integer(n))));
end;

function f_buffer_fromstr(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TPhosphorBytes;
begin
  E := NoError();
  b := TPhosphorBytes.Create();
  b.Data := A[0].Str;          // a plain assignment: same string type, raw copy
  Result := ValHandle(RegisterHandle(b));
end;

function f_buffer_clone(const A: array of TValue; out E: TPhosphorError): TValue;
var src, dst: TPhosphorBytes;
begin
  Result := ValHandle(0);
  if not GetBuf('buffer_clone@', A[0], src, E) then Exit;
  dst := TPhosphorBytes.Create();
  dst.Data := src.Data;
  Result := ValHandle(RegisterHandle(dst));
end;

function f_buffer_free(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  // LENIENT, and deliberately so -- the shape strings_free settled on: freeing is
  // the one operation a program does defensively, so a stale, already-freed or
  // wrong-typed handle is ANSWERED with 0 rather than raised. Everything else in
  // this unit is strict, because reading past the end of a buffer is a bug worth
  // stopping for; freeing twice is not.
  E := NoError();
  Result := ValInt(0);
  if (A[0].Kind <> vkHandle) or (not IsHandle(A[0].Hnd)) then Exit;
  if not (HandleObj(A[0].Hnd) is TPhosphorBytes) then Exit;
  if FreeHandle(A[0].Hnd) then Result := ValInt(1);
end;

function f_buffer_len(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TPhosphorBytes;
begin
  Result := ValInt(0);
  if not GetBuf('buffer_len', A[0], b, E) then Exit;
  Result := ValInt(Length(b.Data));
end;

function f_buffer_resize(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TPhosphorBytes; n: Int64; old: Integer;
begin
  Result := ValInt(0);
  if not GetBuf('buffer_resize', A[0], b, E) then Exit;
  n := ArgI64(A[1]);
  if n < 0 then
  begin
    E := MakeError(peRuntime, 'buffer_resize: size ' + IntToStr(n) + ' is negative');
    Exit;
  end;
  if n > 1073741824 then
  begin
    E := MakeError(peRuntime, 'buffer_resize: size ' + IntToStr(n) + ' exceeds the 1 GiB limit');
    Exit;
  end;
  old := Length(b.Data);
  SetLength(b.Data, Integer(n));
  if Integer(n) > old then                       // growth is zero-filled, like buffer_new
    FillChar(b.Data[old + 1], Integer(n) - old, 0);
  Result := ValInt(Integer(n));                  // the new length
end;

// --- single bytes ------------------------------------------------------------
function f_buffer_get(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TPhosphorBytes; p: Int64;
begin
  Result := ValInt(0);
  if not GetBuf('buffer_get', A[0], b, E) then Exit;
  p := ArgI64(A[1]);
  if not CheckRange('buffer_get', Length(b.Data), p, 1, E) then Exit;
  Result := ValInt(Ord(b.Data[Integer(p)]));
end;

function f_buffer_set(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TPhosphorBytes; p, v: Int64;
begin
  Result := ValInt(0);
  if not GetBuf('buffer_set', A[0], b, E) then Exit;
  p := ArgI64(A[1]);
  if not CheckRange('buffer_set', Length(b.Data), p, 1, E) then Exit;
  v := ArgI64(A[2]);
  if not CheckByte('buffer_set', v, E) then Exit;
  // An INDEXED write stores the raw byte. `b.Data := b.Data + Chr(v)` would
  // re-encode anything >= 128 through the UTF-8 codepage -- see the header.
  b.Data[Integer(p)] := Chr(Integer(v));
  Result := ValInt(v);                           // the byte written, as arr_set does
end;

function f_buffer_fill(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TPhosphorBytes; v: Int64;
begin
  Result := ValInt(0);
  if not GetBuf('buffer_fill', A[0], b, E) then Exit;
  v := ArgI64(A[1]);
  if not CheckByte('buffer_fill', v, E) then Exit;
  if Length(b.Data) > 0 then
    FillChar(b.Data[1], Length(b.Data), Byte(v));
  Result := ValInt(Length(b.Data));              // bytes filled
end;

function f_buffer_fillrange(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TPhosphorBytes; p, n, v: Int64;
begin
  Result := ValInt(0);
  if not GetBuf('buffer_fillrange', A[0], b, E) then Exit;
  p := ArgI64(A[1]);
  n := ArgI64(A[2]);
  if not CheckRange('buffer_fillrange', Length(b.Data), p, n, E) then Exit;
  v := ArgI64(A[3]);
  if not CheckByte('buffer_fillrange', v, E) then Exit;
  if n > 0 then
    FillChar(b.Data[Integer(p)], Integer(n), Byte(v));
  Result := ValInt(n);                           // bytes filled
end;

// --- bulk --------------------------------------------------------------------
function f_buffer_tostr(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TPhosphorBytes;
begin
  Result := ValStr('');
  if not GetBuf('buffer_tostr$', A[0], b, E) then Exit;
  Result := ValStr(b.Data);
end;

function f_buffer_slice(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TPhosphorBytes; p, n: Int64;
begin
  Result := ValStr('');
  if not GetBuf('buffer_slice$', A[0], b, E) then Exit;
  p := ArgI64(A[1]);
  n := ArgI64(A[2]);
  if not CheckRange('buffer_slice$', Length(b.Data), p, n, E) then Exit;
  Result := ValStr(Copy(b.Data, Integer(p), Integer(n)));   // Copy, never concatenation
end;

function f_buffer_write(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TPhosphorBytes; p: Int64; s: String;
begin
  Result := ValInt(0);
  if not GetBuf('buffer_write', A[0], b, E) then Exit;
  p := ArgI64(A[1]);
  s := A[2].Str;
  if not CheckRange('buffer_write', Length(b.Data), p, Length(s), E) then Exit;
  if Length(s) > 0 then
    Move(s[1], b.Data[Integer(p)], Length(s));
  Result := ValInt(Length(s));                   // bytes written
end;

function f_buffer_copy(const A: array of TValue; out E: TPhosphorError): TValue;
var dst, src: TPhosphorBytes; dp, sp, n: Int64;
begin
  Result := ValInt(0);
  if not GetBuf('buffer_copy', A[0], dst, E) then Exit;
  if not GetBuf('buffer_copy', A[2], src, E) then Exit;
  dp := ArgI64(A[1]);
  sp := ArgI64(A[3]);
  n  := ArgI64(A[4]);
  if not CheckRange('buffer_copy (source)', Length(src.Data), sp, n, E) then Exit;
  if not CheckRange('buffer_copy (destination)', Length(dst.Data), dp, n, E) then Exit;
  // Move, not a manual loop: it is defined for OVERLAPPING regions, so copying a
  // buffer onto itself (dst@ = src@) to shift bytes left or right is correct.
  if n > 0 then
    Move(src.Data[Integer(sp)], dst.Data[Integer(dp)], Integer(n));
  Result := ValInt(n);                           // bytes copied
end;

function IndexOfFrom(const AHay, ANeedle: String; AFrom: Integer): Integer;
var i, j, last: Integer; ok: Boolean;
begin
  Result := 0;
  if ANeedle = '' then Exit;                 // an empty pattern matches nothing, not everything
  last := Length(AHay) - Length(ANeedle) + 1;
  if AFrom < 1 then AFrom := 1;
  for i := AFrom to last do
  begin
    ok := True;
    for j := 1 to Length(ANeedle) do
      if AHay[i + j - 1] <> ANeedle[j] then begin ok := False; Break; end;
    if ok then Exit(i);
  end;
end;

function f_buffer_indexof2(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TPhosphorBytes;
begin
  Result := ValInt(0);
  if not GetBuf('buffer_indexof', A[0], b, E) then Exit;
  Result := ValInt(IndexOfFrom(b.Data, A[1].Str, 1));
end;

function f_buffer_indexof3(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TPhosphorBytes;
begin
  Result := ValInt(0);
  if not GetBuf('buffer_indexof', A[0], b, E) then Exit;
  Result := ValInt(IndexOfFrom(b.Data, A[1].Str, ArgI32(A[2])));
end;

function f_buffer_equal(const A: array of TValue; out E: TPhosphorError): TValue;
var x, y: TPhosphorBytes;
begin
  Result := ValInt(0);
  if not GetBuf('buffer_equal', A[0], x, E) then Exit;
  if not GetBuf('buffer_equal', A[1], y, E) then Exit;
  if Length(x.Data) <> Length(y.Data) then Exit;
  Result := ValInt(Ord((Length(x.Data) = 0) or
                       (CompareByte(x.Data[1], y.Data[1], Length(x.Data)) = 0)));
end;

// --- fixed-width integers ----------------------------------------------------
// Width is 1, 2, 4 or 8 bytes; the byte order is little-endian unless the
// optional final argument says otherwise. The assembly is ARITHMETIC (shifts),
// never a Move of a machine word, so a .bin written on one machine reads back
// identically on another regardless of the CPU's own endianness.
function CheckWidth(const AFn: String; AW: Int64; out Err: TPhosphorError): Boolean;
begin
  if (AW <> 1) and (AW <> 2) and (AW <> 4) and (AW <> 8) then
  begin
    Err := MakeError(peRuntime, AFn + ': width ' + IntToStr(AW) + ' is not 1, 2, 4 or 8');
    Exit(False);
  end;
  Err := NoError();
  Result := True;
end;

function ReadRaw(const B: TPhosphorBytes; APos, AW: Integer; ABig: Boolean): QWord;
var i: Integer;
begin
  Result := 0;
  if ABig then
    for i := 0 to AW - 1 do
      Result := (Result shl 8) or QWord(Ord(B.Data[APos + i]))
  else
    for i := AW - 1 downto 0 do
      Result := (Result shl 8) or QWord(Ord(B.Data[APos + i]));
end;

procedure WriteRaw(const B: TPhosphorBytes; APos, AW: Integer; ABig: Boolean; AVal: QWord);
var i: Integer;
begin
  if ABig then
    for i := AW - 1 downto 0 do
    begin
      B.Data[APos + i] := Chr(Byte(AVal and $FF));
      AVal := AVal shr 8;
    end
  else
    for i := 0 to AW - 1 do
    begin
      B.Data[APos + i] := Chr(Byte(AVal and $FF));
      AVal := AVal shr 8;
    end;
end;

function SignExtend(ARaw: QWord; AW: Integer): Int64;
var bits: Integer;
begin
  if AW >= 8 then Exit(Int64(ARaw));
  bits := AW * 8;
  if (ARaw and (QWord(1) shl (bits - 1))) <> 0 then
    Result := Int64(ARaw or (QWord(High(QWord)) shl bits))
  else
    Result := Int64(ARaw);
end;

function DoGetInt(const A: array of TValue; ASigned, ABig: Boolean;
  const AFn: String; out E: TPhosphorError): TValue;
var b: TPhosphorBytes; p, w: Int64; raw: QWord;
begin
  Result := ValInt(0);
  if not GetBuf(AFn, A[0], b, E) then Exit;
  p := ArgI64(A[1]);
  w := ArgI64(A[2]);
  if not CheckWidth(AFn, w, E) then Exit;
  if (not ASigned) and (w = 8) then
  begin
    E := MakeError(peRuntime, AFn + ': width 8 has no unsigned form (it would not fit an integer)');
    Exit;
  end;
  if not CheckRange(AFn, Length(b.Data), p, w, E) then Exit;
  raw := ReadRaw(b, Integer(p), Integer(w), ABig);
  if ASigned then Result := ValInt(SignExtend(raw, Integer(w)))
  else Result := ValInt(Int64(raw));
end;

function f_buffer_getint(const A: array of TValue; out E: TPhosphorError): TValue;
begin Result := DoGetInt(A, True, False, 'buffer_getint', E); end;

function f_buffer_getint_e(const A: array of TValue; out E: TPhosphorError): TValue;
begin Result := DoGetInt(A, True, A[3].Bl, 'buffer_getint', E); end;

function f_buffer_getuint(const A: array of TValue; out E: TPhosphorError): TValue;
begin Result := DoGetInt(A, False, False, 'buffer_getuint', E); end;

function f_buffer_getuint_e(const A: array of TValue; out E: TPhosphorError): TValue;
begin Result := DoGetInt(A, False, A[3].Bl, 'buffer_getuint', E); end;

function DoSetInt(const A: array of TValue; ABig: Boolean;
  out E: TPhosphorError): TValue;
var b: TPhosphorBytes; p, w, v, lo, hi: Int64;
begin
  Result := ValInt(0);
  if not GetBuf('buffer_setint', A[0], b, E) then Exit;
  p := ArgI64(A[1]);
  w := ArgI64(A[2]);
  if not CheckWidth('buffer_setint', w, E) then Exit;
  if not CheckRange('buffer_setint', Length(b.Data), p, w, E) then Exit;
  v := ArgI64(A[3]);
  if w < 8 then
  begin
    // The accepted range spans both readings of the width: -2^(bits-1) for a
    // signed value, up to 2^bits - 1 for an unsigned one, so both 200 and -56
    // fit in one byte. Anything outside is a CATCHABLE ERROR, never a silent
    // truncation -- decisions.md, "integer overflow is a catchable error".
    lo := -(Int64(1) shl (w * 8 - 1));
    hi := (Int64(1) shl (w * 8)) - 1;
    if (v < lo) or (v > hi) then
    begin
      E := MakeError(peRuntime, 'buffer_setint: ' + IntToStr(v) +
        ' does not fit ' + IntToStr(w) + ' byte(s) (' + IntToStr(lo) + '..' + IntToStr(hi) + ')');
      Exit;
    end;
  end;
  WriteRaw(b, Integer(p), Integer(w), ABig, QWord(v));
  Result := ValInt(v);                           // the value written
end;

function f_buffer_setint(const A: array of TValue; out E: TPhosphorError): TValue;
begin Result := DoSetInt(A, False, E); end;

function f_buffer_setint_e(const A: array of TValue; out E: TPhosphorError): TValue;
begin Result := DoSetInt(A, A[4].Bl, E); end;

// --- IEEE-754 floats ---------------------------------------------------------
// Stored little-endian, 8 bytes for a double and 4 for a single. The bit
// pattern is obtained with Move into an integer of the same size and then
// written out byte by byte, so the on-disk order is fixed by this code rather
// than by the CPU.
function f_buffer_getdbl(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TPhosphorBytes; p: Int64; raw: QWord; d: Double;
begin
  Result := ValDouble(0);
  if not GetBuf('buffer_getdbl', A[0], b, E) then Exit;
  p := ArgI64(A[1]);
  if not CheckRange('buffer_getdbl', Length(b.Data), p, 8, E) then Exit;
  raw := ReadRaw(b, Integer(p), 8, False);
  Move(raw, d, 8);
  Result := ValDouble(d);
end;

function f_buffer_setdbl(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TPhosphorBytes; p: Int64; raw: QWord; d: Double;
begin
  Result := ValInt(0);
  if not GetBuf('buffer_setdbl', A[0], b, E) then Exit;
  p := ArgI64(A[1]);
  if not CheckRange('buffer_setdbl', Length(b.Data), p, 8, E) then Exit;
  d := AsDouble(A[2]);
  Move(d, raw, 8);
  WriteRaw(b, Integer(p), 8, False, raw);
  Result := ValDouble(d);                        // the value written
end;

function f_buffer_getsng(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TPhosphorBytes; p: Int64; raw: QWord; l: LongWord; s: Single;
begin
  Result := ValDouble(0);
  if not GetBuf('buffer_getsng', A[0], b, E) then Exit;
  p := ArgI64(A[1]);
  if not CheckRange('buffer_getsng', Length(b.Data), p, 4, E) then Exit;
  raw := ReadRaw(b, Integer(p), 4, False);
  l := LongWord(raw);
  Move(l, s, 4);
  Result := ValDouble(s);
end;

function f_buffer_setsng(const A: array of TValue; out E: TPhosphorError): TValue;
var b: TPhosphorBytes; p: Int64; l: LongWord; s: Single;
begin
  Result := ValInt(0);
  if not GetBuf('buffer_setsng', A[0], b, E) then Exit;
  p := ArgI64(A[1]);
  if not CheckRange('buffer_setsng', Length(b.Data), p, 4, E) then Exit;
  s := AsDouble(A[2]);
  Move(s, l, 4);
  WriteRaw(b, Integer(p), 4, False, QWord(l));
  Result := ValDouble(s);                        // the value written, at single precision
end;

procedure RegisterBufferFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('buffer_new@:n',        @f_buffer_new);
  Reg.Add('buffer_fromstr@:$',    @f_buffer_fromstr);
  Reg.Add('buffer_clone@:@',      @f_buffer_clone);
  Reg.Add('buffer_free:@',        @f_buffer_free);
  Reg.Add('buffer_len:@',         @f_buffer_len);
  Reg.Add('buffer_resize:@n',     @f_buffer_resize);

  Reg.Add('buffer_get:@n',        @f_buffer_get);
  Reg.Add('buffer_set:@nn',       @f_buffer_set);
  Reg.Add('buffer_fill:@n',       @f_buffer_fill);
  Reg.Add('buffer_fillrange:@nnn', @f_buffer_fillrange);

  Reg.Add('buffer_tostr$:@',      @f_buffer_tostr);
  Reg.Add('buffer_slice$:@nn',    @f_buffer_slice);
  Reg.Add('buffer_write:@n$',     @f_buffer_write);
  Reg.Add('buffer_copy:@n@nn',    @f_buffer_copy);
  Reg.Add('buffer_indexof:@$',    @f_buffer_indexof2);
  Reg.Add('buffer_indexof:@$n',   @f_buffer_indexof3);
  Reg.Add('buffer_equal:@@',      @f_buffer_equal);

  Reg.Add('buffer_getint:@nn',    @f_buffer_getint);
  Reg.Add('buffer_getint:@nn?',   @f_buffer_getint_e);
  Reg.Add('buffer_getuint:@nn',   @f_buffer_getuint);
  Reg.Add('buffer_getuint:@nn?',  @f_buffer_getuint_e);
  Reg.Add('buffer_setint:@nn%',   @f_buffer_setint);
  Reg.Add('buffer_setint:@nnn',   @f_buffer_setint);
  Reg.Add('buffer_setint:@nn%?',  @f_buffer_setint_e);
  Reg.Add('buffer_setint:@nnn?',  @f_buffer_setint_e);

  Reg.Add('buffer_getdbl:@n',     @f_buffer_getdbl);
  Reg.Add('buffer_setdbl:@nn',    @f_buffer_setdbl);
  Reg.Add('buffer_getsng:@n',     @f_buffer_getsng);
  Reg.Add('buffer_setsng:@nn',    @f_buffer_setsng);
end;

end.
