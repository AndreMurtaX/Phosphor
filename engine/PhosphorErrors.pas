{******************************************************************************
  Phosphor BASIC -- error state (record, don't raise)

  MIT License. Copyright (c) 2026 Andre Murta.

  A founding decision (decisions.md, "Errors"): the engine and its libraries
  RECORD error state and hand it back, instead of raising and killing the user's
  program. Plan9Basic had 121 fatal raises and no error handling; Phosphor makes
  a recoverable error a value that flows back to the caller, so that ON ERROR
  (a later step) has something to read. This unit defines that shape. It is
  frozen in the first increment even though nothing fails yet.
******************************************************************************}
unit PhosphorErrors;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

type
  { Assigned by append only, never reordered -- these codes are part of the
    engine's surface the way opcodes are. }
  TPhosphorErrorCode = (
    peNone            = 0,
    peIntOverflow     = 1,  // integer arithmetic overflowed (never a silent promotion)
    peDivByZero       = 2,
    peTypeMismatch    = 3,  // an operator or a call got a kind it cannot accept
    peUnknownFunction = 4,  // no registry overload matches name + argument kinds
    peSyntax          = 5,
    peRuntime         = 6,
    peLimit           = 7   // a host execution limit was hit (steps/time/output);
                            // fatal by design -- ON ERROR cannot catch it
  );

  TPhosphorError = record
    Code: TPhosphorErrorCode;
    Message: String;
  end;

function MakeError(ACode: TPhosphorErrorCode; const AMessage: String): TPhosphorError;
function NoError: TPhosphorError;
function IsError(const AError: TPhosphorError): Boolean; inline;

implementation

function MakeError(ACode: TPhosphorErrorCode; const AMessage: String): TPhosphorError;
begin
  Result.Code := ACode;
  Result.Message := AMessage;
end;

function NoError: TPhosphorError;
begin
  Result.Code := peNone;
  Result.Message := '';
end;

function IsError(const AError: TPhosphorError): Boolean; inline;
begin
  Result := AError.Code <> peNone;
end;

end.
