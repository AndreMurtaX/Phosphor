{******************************************************************************
  Phosphor BASIC -- base64 / hex encoding (an OPT-IN host package)

  MIT License. Copyright (c) 2026 Andre Murta.

  This is not part of the engine. It lives under host/packages/ -- a package a
  host CHOOSES to register (RegisterBase64Funcs) -- so the engine stays free of
  every optional integration. A package may reach for units the engine may not;
  the boundary check scans only engine/, so this is legitimate here.

    base64_encode$(s$)        base64_decode$(s$)          MIME base64, no wrap
    base64_urlencode$(s$)     base64_urldecode$(s$)       URL-safe, no padding
    base64_encodefile$(path$) base64_decodefile(b64$, path$)  a whole file
    base64_valid(s$)          1 if s$ is valid base64 (line breaks allowed)
    base64_error()            code of the most recent base64 op (0 = clear)
    hex_encode$(s$)           hex_decode$(s$)

  FPC's fcl-base base64 (EncodeStringBase64) emits a continuous line -- no MIME
  76-char wrapping -- so the encoder's own output is always base64_valid, and a
  URL-safe string never carries a stray line feed. Encoding is byte-exact and
  round-trips: decode(encode(s)) = s.
******************************************************************************}
unit PhosphorBase64Lib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, base64,
  PhosphorValue, PhosphorErrors, PhosphorRegistry;

procedure RegisterBase64Funcs(Reg: TPhosphorRegistry);

implementation

var
  B64Err: Integer = 0;   // 0 = the last base64 op was clean; 1 = it failed

function f_b64_encode(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValStr(EncodeStringBase64(Args[0].Str)); end;

function f_b64_decode(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  // The unit's own contract is "returned, never raised", and this was the one path
  // that broke it: base64_decode$("!!!!") let an EStreamError out of the RTL and
  // ended the program. The failure is recorded where base64_error() can read it.
  Err := NoError();
  try
    Result := ValStr(DecodeStringBase64(Args[0].Str));
    B64Err := 0;
  except
    Result := ValStr('');
    B64Err := 1;
  end;
end;

// --- URL-safe base64 (RFC 4648 section 5: '-'/'_', padding stripped) --------
function f_b64_urlencode(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: String; i: Integer;
begin
  Err := NoError();
  s := EncodeStringBase64(Args[0].Str);
  for i := 1 to Length(s) do
    case s[i] of
      '+': s[i] := '-';
      '/': s[i] := '_';
    end;
  // strip '=' padding, which a URL should not carry
  while (s <> '') and (s[Length(s)] = '=') do SetLength(s, Length(s) - 1);
  Result := ValStr(s);
end;

function f_b64_urldecode(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: String; i: Integer;
begin
  Err := NoError();
  s := Args[0].Str;
  for i := 1 to Length(s) do
    case s[i] of
      '-': s[i] := '+';
      '_': s[i] := '/';
    end;
  while (Length(s) mod 4) <> 0 do s := s + '=';   // restore padding for the decoder
  try
    Result := ValStr(DecodeStringBase64(s));
    B64Err := 0;
  except
    Result := ValStr('');
    B64Err := 1;
  end;
end;

// --- whole-file encode / decode (bytes, no text conversion, no BOM) ---------
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

function f_b64_encodefile(const Args: array of TValue; out Err: TPhosphorError): TValue;
var raw: RawByteString;
begin
  Err := NoError();
  if LoadFileStr(Args[0].Str, raw) then
  begin Result := ValStr(EncodeStringBase64(raw)); B64Err := 0; end
  else begin Result := ValStr(''); B64Err := 1; end;
end;

function f_b64_decodefile(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  try
    if SaveFileStr(Args[1].Str, DecodeStringBase64(Args[0].Str)) then
    begin Result := ValInt(1); B64Err := 0; end
    else begin Result := ValInt(0); B64Err := 1; end;
  except
    Result := ValInt(0); B64Err := 1;
  end;
end;

// --- validity ---------------------------------------------------------------
// True if s$ (with any CR/LF removed -- MIME wrapping is tolerated) is a
// well-formed base64 string: only the base64 alphabet, '=' padding at the end
// alone, length a multiple of 4. A space, tab or stray byte makes it invalid.
function IsValidBase64(const AText: String): Boolean;
var s: String; i, pad: Integer; c: Char;
begin
  Result := False;
  s := '';
  for i := 1 to Length(AText) do
    if (AText[i] <> #13) and (AText[i] <> #10) then s := s + Copy(AText, i, 1);
  if (s = '') or ((Length(s) mod 4) <> 0) then Exit;
  pad := 0;
  for i := 1 to Length(s) do
  begin
    c := s[i];
    if c = '=' then
    begin
      Inc(pad);
      if pad > 2 then Exit;                // at most two '=' of padding
    end
    else
    begin
      if pad > 0 then Exit;                // '=' padding may only trail the data
      if not (((c >= 'A') and (c <= 'Z')) or ((c >= 'a') and (c <= 'z')) or
              ((c >= '0') and (c <= '9')) or (c = '+') or (c = '/')) then Exit;
    end;
  end;
  Result := True;
end;

function f_b64_valid(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(Ord(IsValidBase64(Args[0].Str)));
end;

function f_b64_error(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(B64Err);
end;

// --- hex --------------------------------------------------------------------
function HexVal(C: Char): Integer;
begin
  case C of
    '0'..'9': Result := Ord(C) - Ord('0');
    'a'..'f': Result := Ord(C) - Ord('a') + 10;
    'A'..'F': Result := Ord(C) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

function f_hex_encode(const Args: array of TValue; out Err: TPhosphorError): TValue;
const
  HEXD: array[0..15] of Char = ('0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f');
var s: String; r: RawByteString; i, b: Integer;
begin
  Err := NoError();
  s := Args[0].Str;
  // Preallocate and write by index, like hex_decode$. The old `r := r + ...` in a
  // loop reallocated on every byte, making this quadratic: 4 MB cost 0.4 s but
  // 64 MB cost ~37 s. Now it is linear.
  SetLength(r, Length(s) * 2);
  for i := 1 to Length(s) do
  begin
    b := Ord(s[i]);
    r[i * 2 - 1] := HEXD[b shr 4];
    r[i * 2]     := HEXD[b and $0F];
  end;
  Result := ValStr(r);
end;

function f_hex_decode(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: String; r: RawByteString; i, hi, lo, n: Integer;
begin
  Err := NoError();
  s := Args[0].Str;
  // Build the bytes into a RawByteString by INDEXED assignment, exactly as the gzip
  // header does. Concatenating `r := r + Chr(b)` under {$codepage UTF8} re-encodes a
  // byte >= 128 into its multi-byte UTF-8 form (or '?'), which is why hex_decode$
  // used to corrupt every non-ASCII byte while its encode half stayed byte-exact.
  // Chr() written to r[n] stores the raw byte, and ValStr of a RawByteString keeps
  // it (the same path base64/gzip/zip use).
  SetLength(r, Length(s) div 2);
  n := 0;
  i := 1;
  while i + 1 <= Length(s) do
  begin
    hi := HexVal(s[i]); lo := HexVal(s[i + 1]);
    if (hi < 0) or (lo < 0) then Break;   // stop at the first non-hex pair
    Inc(n);
    r[n] := Chr(hi * 16 + lo);
    Inc(i, 2);
  end;
  SetLength(r, n);
  Result := ValStr(r);
end;

procedure RegisterBase64Funcs(Reg: TPhosphorRegistry);
begin
  Reg.Add('base64_encode$:$',     @f_b64_encode);
  Reg.Add('base64_decode$:$',     @f_b64_decode);
  Reg.Add('base64_urlencode$:$',  @f_b64_urlencode);
  Reg.Add('base64_urldecode$:$',  @f_b64_urldecode);
  Reg.Add('base64_encodefile$:$', @f_b64_encodefile);
  Reg.Add('base64_decodefile:$$', @f_b64_decodefile);
  Reg.Add('base64_valid:$',       @f_b64_valid);
  Reg.Add('base64_error:',        @f_b64_error);
  Reg.Add('hex_encode$:$',        @f_hex_encode);
  Reg.Add('hex_decode$:$',        @f_hex_decode);
end;

end.
