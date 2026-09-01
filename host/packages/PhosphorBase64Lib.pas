{******************************************************************************
  Phosphor BASIC -- base64 / hex encoding (an OPT-IN host package)

  MIT License. Copyright (c) 2026 Andre Murta.

  This is not part of the engine. It lives under host/packages/ -- a package a
  host CHOOSES to register (RegisterBase64Funcs) -- so the engine stays free of
  every optional integration. A package may reach for units the engine may not;
  the boundary check scans only engine/, so this is legitimate here.

    base64_encode$(s$)   base64_decode$(s$)
    hex_encode$(s$)      hex_decode$(s$)

  Encoding is byte-exact and round-trips: decode(encode(s)) = s.
******************************************************************************}
unit PhosphorBase64Lib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, base64,
  PhosphorValue, PhosphorErrors, PhosphorRegistry;

procedure RegisterBase64Funcs(Reg: TPhosphorRegistry);

implementation

function f_b64_encode(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValStr(EncodeStringBase64(Args[0].Str)); end;

function f_b64_decode(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValStr(DecodeStringBase64(Args[0].Str)); end;

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
var s, r: String; i: Integer;
begin
  Err := NoError;
  s := Args[0].Str;
  r := '';
  for i := 1 to Length(s) do r := r + LowerCase(IntToHex(Ord(s[i]), 2));
  Result := ValStr(r);
end;

function f_hex_decode(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s, r: String; i, hi, lo: Integer;
begin
  Err := NoError;
  s := Args[0].Str;
  r := '';
  i := 1;
  while i + 1 <= Length(s) do
  begin
    hi := HexVal(s[i]); lo := HexVal(s[i + 1]);
    if (hi < 0) or (lo < 0) then Break;   // stop at the first non-hex pair
    r := r + Chr(hi * 16 + lo);
    Inc(i, 2);
  end;
  Result := ValStr(r);
end;

procedure RegisterBase64Funcs(Reg: TPhosphorRegistry);
begin
  Reg.Add('base64_encode$:$', @f_b64_encode);
  Reg.Add('base64_decode$:$', @f_b64_decode);
  Reg.Add('hex_encode$:$',    @f_hex_encode);
  Reg.Add('hex_decode$:$',    @f_hex_decode);
end;

end.
