{******************************************************************************
  Phosphor BASIC -- string library (a function package under engine/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  Started for the string-list `text` case (which needs chr$). Step 8 fills this
  out with mid$/instr/len (base-1), max()/min(), stri$, etc.
******************************************************************************}
unit PhosphorStrLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, PhosphorValue, PhosphorErrors, PhosphorRegistry;

procedure RegisterStrFuncs(Reg: TPhosphorRegistry);

implementation

// chr$(n): the character with byte code n (0..255). ASCII/control codes such as
// chr$(10) = LF; wider codepoint handling arrives with the rest of the string
// library in step 8.
function t_chr(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  Result := ValStr(Chr(Round(AsDouble(Args[0])) and $FF));
end;

procedure RegisterStrFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('chr$:n', @t_chr);
end;

end.
