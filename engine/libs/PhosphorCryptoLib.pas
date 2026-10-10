{******************************************************************************
  Phosphor BASIC -- cryptographic hashing (a function package under engine/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  Digests, a keyed MAC, a password-based key derivation, and the two calls a
  program that keeps passwords actually needs:

    sha256$(s$)                       FIPS 180-4, lowercase hex
    sha1$(s$)   md5$(s$)              legacy checksums (FPC's hash package), hex
    hmac_sha256$(key$, msg$)          RFC 2104 over SHA-256, hex
    pbkdf2_sha256$(pw$, salt$, iterations, bytes)
                                      RFC 8018 PBKDF2-HMAC-SHA256, hex
    password_hash$(pw$)               a salted, self-describing password record
    password_hash$(pw$, iterations)
    password_verify?(pw$, record$)    true when pw$ is the password in record$
    crypto_equal?(a$, b$)             compare without leaking WHERE they differ

  Every input is the string's BYTES, exactly as stored -- Phosphor strings are
  UTF-8, so "é" hashes as C3 A9. Nothing here transcodes.

  SHA-256 is written out below because FPC 3.2.2's hash package stops at SHA-1
  (packages/hash/src: crc, md5, sha1, hmac over those two, ntlm, uuid). MD5 and
  SHA-1 come from that package; both are BROKEN for collision resistance and are
  here only to match checksums other programs publish.

  THE PASSWORD RECORD is Django's: pbkdf2_sha256$<iterations>$<salt>$<hash>,
  with the hash base64 and the salt ASCII. A record made here verifies in
  Django and the other way round, and the format names its own algorithm and
  cost, so raising the iteration count later leaves old records verifiable.
  The salt is 32 lowercase hex digits from one CreateGUID -- on Windows
  CoCreateGuid, on Linux the kernel's random UUID -- which is 122 random bits.
  A salt has to be UNIQUE, not secret, and that is far more than uniqueness
  needs. The engine may not reach the OS's random source directly (no windows,
  no unix units here), and CreateGUID is the RTL's portable door to it; the
  sys library already uses it for guidfilename$.

  THE COST IS THE POINT, and a script supplies it: an iteration count, a key
  length, or -- in password_verify? -- a record that came from a database and
  names its own count. Every PBKDF2 loop charges the execution budget as it
  goes, so a host limit stops it; with no budget installed, a record naming two
  billion iterations takes as long as it says, which is the documented meaning
  of that record.
******************************************************************************}
unit PhosphorCryptoLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, md5, sha1, base64,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorBudget;

procedure RegisterCryptoFuncs(Reg: TPhosphorRegistry);

{ The raw 32-byte digest, for a Pascal caller that wants bytes, not hex. }
function Sha256Bytes(const S: RawByteString): RawByteString;

implementation

const
  PasswordAlgorithm = 'pbkdf2_sha256';
  { OWASP's figure for PBKDF2-HMAC-SHA256 (Password Storage Cheat Sheet, 2023),
    and Django 4.2's default. Measured here at about a third of a second. }
  DefaultPasswordIterations = 600000;
  { The derived key PBKDF2 may be asked for. RFC 8018 allows (2^32-1)*32 bytes;
    nothing a program stores needs more than a few blocks, and every block costs
    the full iteration count again. }
  MaxDerivedBytes = 1024;
  { Budget units per SHA-256 compression: a 64-byte block, on the byte scale the
    other libraries charge. }
  UnitsPerBlock = 64;
  { How many PBKDF2 iterations run between two charges. }
  ChargeEvery = 1024;

// --- SHA-256 (FIPS 180-4) ------------------------------------------------------

type
  TSha256State = array[0..7] of Cardinal;
  TSha256Ctx = record
    H: TSha256State;
    Buf: array[0..63] of Byte;
    BufLen: Integer;
    Total: QWord;          // bytes absorbed so far
  end;

const
  K256: array[0..63] of Cardinal = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1, $923f82a4, $ab1c5ed5,
    $d807aa98, $12835b01, $243185be, $550c7dc3, $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174,
    $e49b69c1, $efbe4786, $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147, $06ca6351, $14292967,
    $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13, $650a7354, $766a0abb, $81c2c92e, $92722c85,
    $a2bfe8a1, $a81a664b, $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a, $5b9cca4f, $682e6ff3,
    $748f82ee, $78a5636f, $84c87814, $8cc70208, $90befffa, $a4506ceb, $bef9a3f7, $c67178f2);

  H256Init: TSha256State = (
    $6a09e667, $bb67ae85, $3c6ef372, $a54ff53a, $510e527f, $9b05688c, $1f83d9ab, $5be0cd19);

{$push}{$Q-}{$R-}
procedure Sha256Compress(var H: TSha256State; P: PByte);
var
  W: array[0..63] of Cardinal;
  a, b, c, d, e, f, g, hh, t1, t2, s0, s1: Cardinal;
  i: Integer;
begin
  for i := 0 to 15 do
    W[i] := (Cardinal(P[i * 4]) shl 24) or (Cardinal(P[i * 4 + 1]) shl 16) or
            (Cardinal(P[i * 4 + 2]) shl 8) or Cardinal(P[i * 4 + 3]);
  for i := 16 to 63 do
  begin
    s0 := RorDWord(W[i - 15], 7) xor RorDWord(W[i - 15], 18) xor (W[i - 15] shr 3);
    s1 := RorDWord(W[i - 2], 17) xor RorDWord(W[i - 2], 19) xor (W[i - 2] shr 10);
    W[i] := W[i - 16] + s0 + W[i - 7] + s1;
  end;
  a := H[0]; b := H[1]; c := H[2]; d := H[3];
  e := H[4]; f := H[5]; g := H[6]; hh := H[7];
  for i := 0 to 63 do
  begin
    s1 := RorDWord(e, 6) xor RorDWord(e, 11) xor RorDWord(e, 25);
    t1 := hh + s1 + ((e and f) xor ((not e) and g)) + K256[i] + W[i];
    s0 := RorDWord(a, 2) xor RorDWord(a, 13) xor RorDWord(a, 22);
    t2 := s0 + ((a and b) xor (a and c) xor (b and c));
    hh := g; g := f; f := e; e := d + t1;
    d := c; c := b; b := a; a := t1 + t2;
  end;
  H[0] := H[0] + a; H[1] := H[1] + b; H[2] := H[2] + c; H[3] := H[3] + d;
  H[4] := H[4] + e; H[5] := H[5] + f; H[6] := H[6] + g; H[7] := H[7] + hh;
end;
{$pop}

procedure Sha256Init(out C: TSha256Ctx);
begin
  C.H := H256Init;
  FillChar(C.Buf, SizeOf(C.Buf), 0);
  C.BufLen := 0;
  C.Total := 0;
end;

procedure Sha256Update(var C: TSha256Ctx; P: PByte; N: SizeInt);
var take: SizeInt;
begin
  Inc(C.Total, QWord(N));
  if C.BufLen > 0 then
  begin
    take := 64 - C.BufLen;
    if take > N then take := N;
    Move(P^, C.Buf[C.BufLen], take);
    Inc(C.BufLen, take); Inc(P, take); Dec(N, take);
    if C.BufLen < 64 then Exit;
    Sha256Compress(C.H, @C.Buf[0]);
    C.BufLen := 0;
  end;
  while N >= 64 do
  begin
    Sha256Compress(C.H, P);
    Inc(P, 64); Dec(N, 64);
  end;
  if N > 0 then
  begin
    Move(P^, C.Buf[0], N);
    C.BufLen := N;
  end;
end;

procedure Sha256UpdateStr(var C: TSha256Ctx; const S: RawByteString);
begin
  if S <> '' then Sha256Update(C, PByte(Pointer(S)), Length(S));
end;

{ The 32-byte digest, big-endian words, into D. C is spent afterwards. }
procedure Sha256Final(var C: TSha256Ctx; out D: TSha256State);
var
  bits: QWord;
  i: Integer;
begin
  bits := C.Total * 8;
  C.Buf[C.BufLen] := $80;
  Inc(C.BufLen);
  if C.BufLen > 56 then
  begin
    FillChar(C.Buf[C.BufLen], 64 - C.BufLen, 0);
    Sha256Compress(C.H, @C.Buf[0]);
    C.BufLen := 0;
  end;
  FillChar(C.Buf[C.BufLen], 56 - C.BufLen, 0);
  for i := 0 to 7 do
    C.Buf[56 + i] := Byte(bits shr (56 - 8 * i));
  Sha256Compress(C.H, @C.Buf[0]);
  D := C.H;
end;

function StateToBytes(const D: TSha256State): RawByteString;
var i: Integer;
begin
  SetLength(Result, 32);
  for i := 0 to 7 do
  begin
    Result[i * 4 + 1] := Chr(Byte(D[i] shr 24));
    Result[i * 4 + 2] := Chr(Byte(D[i] shr 16));
    Result[i * 4 + 3] := Chr(Byte(D[i] shr 8));
    Result[i * 4 + 4] := Chr(Byte(D[i]));
  end;
end;

function Sha256Bytes(const S: RawByteString): RawByteString;
var c: TSha256Ctx; d: TSha256State;
begin
  Sha256Init(c);
  Sha256UpdateStr(c, S);
  Sha256Final(c, d);
  Result := StateToBytes(d);
end;

const
  HexDigits: array[0..15] of Char = '0123456789abcdef';

function ToHex(const S: RawByteString): String;
var i: Integer;
begin
  SetLength(Result, Length(S) * 2);
  for i := 1 to Length(S) do
  begin
    Result[i * 2 - 1] := HexDigits[Ord(S[i]) shr 4];
    Result[i * 2] := HexDigits[Ord(S[i]) and 15];
  end;
end;

// --- HMAC-SHA256 (RFC 2104) ----------------------------------------------------

type
  { The two contexts after absorbing key xor ipad and key xor opad. Computing
    them once is what makes PBKDF2 cost two compressions per iteration, not four. }
  THmacKey = record
    Inner, Outer: TSha256Ctx;
  end;

procedure HmacPrepare(const Key: RawByteString; out K: THmacKey);
var
  block: array[0..63] of Byte;
  pad: array[0..63] of Byte;
  kk: RawByteString;
  i: Integer;
begin
  if Length(Key) > 64 then kk := Sha256Bytes(Key) else kk := Key;
  FillChar(block, SizeOf(block), 0);
  if kk <> '' then Move(kk[1], block[0], Length(kk));
  for i := 0 to 63 do pad[i] := block[i] xor $36;
  Sha256Init(K.Inner);
  Sha256Update(K.Inner, @pad[0], 64);
  for i := 0 to 63 do pad[i] := block[i] xor $5c;
  Sha256Init(K.Outer);
  Sha256Update(K.Outer, @pad[0], 64);
end;

{ HMAC of a message under a prepared key, into D. }
procedure HmacDigest(const K: THmacKey; P: PByte; N: SizeInt; out D: TSha256State);
var
  c: TSha256Ctx;
  inner: TSha256State;
  ib: array[0..31] of Byte;
  i: Integer;
begin
  c := K.Inner;
  Sha256Update(c, P, N);
  Sha256Final(c, inner);
  for i := 0 to 7 do
  begin
    ib[i * 4] := Byte(inner[i] shr 24);
    ib[i * 4 + 1] := Byte(inner[i] shr 16);
    ib[i * 4 + 2] := Byte(inner[i] shr 8);
    ib[i * 4 + 3] := Byte(inner[i]);
  end;
  c := K.Outer;
  Sha256Update(c, @ib[0], 32);
  Sha256Final(c, D);
end;

function HmacSha256(const Key, Msg: RawByteString): RawByteString;
var k: THmacKey; d: TSha256State;
begin
  HmacPrepare(Key, k);
  if Msg <> '' then HmacDigest(k, PByte(Pointer(Msg)), Length(Msg), d)
  else HmacDigest(k, nil, 0, d);
  Result := StateToBytes(d);
end;

// --- PBKDF2-HMAC-SHA256 (RFC 8018 section 5.2) ---------------------------------

{ False when the execution budget refused the work; Key is then undefined.
  AIterations and ABytes are validated by the caller (>= 1). }
function Pbkdf2Sha256(const Password, Salt: RawByteString;
                      AIterations: Int64; ABytes: Integer;
                      out Key: RawByteString): Boolean;
var
  k: THmacKey;
  blocks, blk, w: Integer;
  j, sinceCharge: Int64;
  first: RawByteString;
  u, t: TSha256State;
  ub: array[0..31] of Byte;
  tb: RawByteString;
begin
  Result := False;
  Key := '';
  blocks := (ABytes + 31) div 32;
  { THE BYTES ARE WORK TOO, not only the rounds (round 5, 2026-10-10). Each
    block hashes the whole salt once more, and the password is hashed once if it
    is longer than a block -- and both are the caller's, or a stored record's.
    They used to be charged nothing, so a megabyte salt over 32 blocks ran ~9x
    past TimeoutMs before the first charge read the clock. Asked BEFORE the work,
    one byte one unit (UnitsPerBlock per 64-byte block), so an oversized request
    is refused rather than run. }
  if not BudgetAllows(Length(Password)) then Exit;
  HmacPrepare(Password, k);
  for blk := 1 to blocks do
  begin
    if not BudgetAllows(Int64(Length(Salt)) + 4) then Exit;
    first := Salt + Chr(Byte(blk shr 24)) + Chr(Byte(blk shr 16)) +
             Chr(Byte(blk shr 8)) + Chr(Byte(blk));
    HmacDigest(k, PByte(Pointer(first)), Length(first), u);
    t := u;
    sinceCharge := 1;
    j := 2;
    while j <= AIterations do
    begin
      for w := 0 to 7 do
      begin
        ub[w * 4] := Byte(u[w] shr 24);
        ub[w * 4 + 1] := Byte(u[w] shr 16);
        ub[w * 4 + 2] := Byte(u[w] shr 8);
        ub[w * 4 + 3] := Byte(u[w]);
      end;
      HmacDigest(k, @ub[0], 32, u);
      for w := 0 to 7 do t[w] := t[w] xor u[w];
      Inc(sinceCharge);
      if sinceCharge >= ChargeEvery then
      begin
        if not BudgetCharge(sinceCharge * 2 * UnitsPerBlock) then Exit;
        sinceCharge := 0;
      end;
      Inc(j);
    end;
    if not BudgetCharge(sinceCharge * 2 * UnitsPerBlock) then Exit;
    tb := StateToBytes(t);
    Key := Key + tb;
  end;
  SetLength(Key, ABytes);
  Result := True;
end;

// --- constant-time comparison --------------------------------------------------

{ True when A and B hold the same bytes. The time taken depends on the LENGTHS
  only, never on where the first difference sits -- which is what a byte-by-byte
  `=` that stops early leaks to someone timing a password or a MAC check. }
function SameBytesConstTime(const A, B: RawByteString): Boolean;
var
  i, n: Integer;
  diff: Byte;
begin
  diff := 0;
  if Length(A) <> Length(B) then diff := 1;
  n := Length(A);
  if Length(B) < n then n := Length(B);
  for i := 1 to n do
    diff := diff or (Byte(A[i]) xor Byte(B[i]));
  Result := diff = 0;
end;

// --- argument helpers ------------------------------------------------------------

{ An integral count in [ALo, AHi], or a runtime error naming the function. }
function CountArg(const V: TValue; ALo, AHi: Int64; const AWhat, AName: String;
                  out N: Int64; out Err: TPhosphorError): Boolean;
var d: Double;
begin
  Result := False;
  N := 0;
  d := AsDouble(V);
  if (d <> d) or (d < ALo) or (d > AHi) or (Frac(d) <> 0) then
  begin
    Err := MakeError(peRuntime, AWhat + ': ' + AName + ' must be a whole number from ' +
                     IntToStr(ALo) + ' to ' + IntToStr(AHi));
    Exit;
  end;
  N := Trunc(d);
  Result := True;
end;

{ 32 lowercase hex digits from one GUID: its 122 random bits and its 6 fixed
  version/variant bits, which a salt does not mind. }
function NewSalt: String;
var
  g: TGUID;
  raw: RawByteString;
begin
  CreateGUID(g);
  SetLength(raw, SizeOf(g));
  Move(g, raw[1], SizeOf(g));
  Result := ToHex(raw);
end;

{ The Django record for Password under a fresh salt, or False when the budget
  refused the derivation. }
function MakeRecord(const Password: RawByteString; AIterations: Int64;
                    out Rec: String): Boolean;
var salt: String; dk: RawByteString;
begin
  salt := NewSalt();
  Result := Pbkdf2Sha256(Password, salt, AIterations, 32, dk);
  if Result then
    Rec := PasswordAlgorithm + '$' + IntToStr(AIterations) + '$' + salt + '$' +
           EncodeStringBase64(dk)
  else
    Rec := '';
end;

{ Split a record into its four fields. False for anything that is not exactly
  the record Django writes: algorithm$iterations$salt$hash, the count in plain
  decimal with no leading zero, from 1 to 2147483647, a non-empty salt, and the
  hash as standard padded base64 of exactly 32 bytes -- the field must be what
  encoding those 32 bytes gives back, character for character.

  ROUND 5 (2026-10-10). Any hash from 1 to 1024 bytes was accepted, and verify
  derived and compared only that many bytes: a record whose hash had been cut to
  one byte said yes to one wrong password in 256. Django re-encodes with
  dklen=32 and compares the whole record, so a short hash never matches there,
  and neither does a count written "01000" or a hash missing its "=". A record
  that Django would refuse is refused here too, which is what "Django's format"
  promises -- and a hash longer than 32 bytes no longer multiplies the cost the
  record names by its number of blocks. }
function ParseRecord(const Rec: String; out Iter: Int64; out Salt: String;
                     out Hash: RawByteString): Boolean;
var
  parts: array[0..3] of String;
  i, n, p: Integer;
  rest: String;
  code: Integer;
begin
  Result := False;
  Iter := 0; Salt := ''; Hash := '';
  rest := Rec;
  n := 0;
  while n < 3 do
  begin
    p := Pos('$', rest);
    if p = 0 then Exit;
    parts[n] := Copy(rest, 1, p - 1);
    Delete(rest, 1, p);
    Inc(n);
  end;
  if Pos('$', rest) > 0 then Exit;
  parts[3] := rest;
  if parts[0] <> PasswordAlgorithm then Exit;
  if (parts[1] = '') or (Length(parts[1]) > 10) or (parts[1][1] = '0') then Exit;
  for i := 1 to Length(parts[1]) do
    if not (parts[1][i] in ['0'..'9']) then Exit;
  Val(parts[1], Iter, code);
  if (code <> 0) or (Iter < 1) or (Iter > High(Integer)) then Exit;
  if parts[2] = '' then Exit;
  Salt := parts[2];
  if Length(parts[3]) <> 44 then Exit;     // 32 bytes, padded: 44 characters
  try
    Hash := DecodeStringBase64(parts[3], True);
  except
    Exit;
  end;
  if Length(Hash) <> 32 then Exit;
  if EncodeStringBase64(Hash) <> parts[3] then Exit;   // the canonical spelling only
  Result := True;
end;

// --- the registered functions --------------------------------------------------

function t_sha256(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValStr(ToHex(Sha256Bytes(Args[0].Str)));
end;

function t_sha1(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: RawByteString; d: TSHA1Digest; raw: RawByteString;
begin
  Err := NoError();
  s := Args[0].Str;
  if s = '' then d := SHA1Buffer(s, 0)
  else d := SHA1Buffer(s[1], Length(s));
  SetLength(raw, SizeOf(d));
  Move(d, raw[1], SizeOf(d));
  Result := ValStr(ToHex(raw));
end;

function t_md5(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: RawByteString; d: TMD5Digest; raw: RawByteString;
begin
  Err := NoError();
  s := Args[0].Str;
  if s = '' then d := MD5Buffer(s, 0)
  else d := MD5Buffer(s[1], Length(s));
  SetLength(raw, SizeOf(d));
  Move(d, raw[1], SizeOf(d));
  Result := ValStr(ToHex(raw));
end;

function t_hmac_sha256(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValStr(ToHex(HmacSha256(Args[0].Str, Args[1].Str)));
end;

function t_pbkdf2_sha256(const Args: array of TValue; out Err: TPhosphorError): TValue;
var iter, bytes: Int64; dk: RawByteString;
begin
  Err := NoError();
  Result := ValStr('');
  if not CountArg(Args[2], 1, High(Integer), 'pbkdf2_sha256$', 'iterations', iter, Err) then Exit;
  if not CountArg(Args[3], 1, MaxDerivedBytes, 'pbkdf2_sha256$', 'bytes', bytes, Err) then Exit;
  if not Pbkdf2Sha256(Args[0].Str, Args[1].Str, iter, Integer(bytes), dk) then
  begin
    Err := BudgetRefusal('pbkdf2_sha256$');
    Exit;
  end;
  Result := ValStr(ToHex(dk));
end;

function HashWith(const Args: array of TValue; AIter: Int64;
                  out Err: TPhosphorError): TValue;
var rec: String;
begin
  Err := NoError();
  if not MakeRecord(Args[0].Str, AIter, rec) then
  begin
    Err := BudgetRefusal('password_hash$');
    Exit(ValStr(''));
  end;
  Result := ValStr(rec);
end;

function t_password_hash(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Result := HashWith(Args, DefaultPasswordIterations, Err);
end;

function t_password_hash_n(const Args: array of TValue; out Err: TPhosphorError): TValue;
var iter: Int64;
begin
  Err := NoError();
  Result := ValStr('');
  if not CountArg(Args[1], 1, High(Integer), 'password_hash$', 'iterations', iter, Err) then Exit;
  Result := HashWith(Args, iter, Err);
end;

function t_password_verify(const Args: array of TValue; out Err: TPhosphorError): TValue;
var
  iter: Int64;
  salt: String;
  want, got: RawByteString;
begin
  Err := NoError();
  Result := ValBool(False);
  { A record that does not parse is simply not a match: the caller asked "is
    this the password", and for a damaged record the answer is no. }
  if not ParseRecord(Args[1].Str, iter, salt, want) then Exit;
  if not Pbkdf2Sha256(Args[0].Str, salt, iter, 32, got) then
  begin
    Err := BudgetRefusal('password_verify?');
    Exit;
  end;
  Result := ValBool(SameBytesConstTime(got, want));
end;

function t_crypto_equal(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValBool(SameBytesConstTime(Args[0].Str, Args[1].Str));
end;

procedure RegisterCryptoFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('sha256$:$', @t_sha256);
  Reg.Add('sha1$:$', @t_sha1);
  Reg.Add('md5$:$', @t_md5);
  Reg.Add('hmac_sha256$:$$', @t_hmac_sha256);
  Reg.Add('pbkdf2_sha256$:$$nn', @t_pbkdf2_sha256);
  Reg.Add('password_hash$:$', @t_password_hash);
  Reg.Add('password_hash$:$n', @t_password_hash_n);
  Reg.Add('password_verify?:$$', @t_password_verify);
  Reg.Add('crypto_equal?:$$', @t_crypto_equal);
end;

end.
