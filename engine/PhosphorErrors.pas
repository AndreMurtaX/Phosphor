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
    peLimit           = 7,  // a host execution limit was hit (steps/time/output);
                            // fatal by design -- ON ERROR cannot catch it
    { THE INTERPRETER ITSELF TOOK A FAULT, AND EXECUTION IS OVER.

      Every other code on this list describes something the PROGRAM did: it
      divided by zero, it named a function that is not there, it overflowed. This
      one describes something that happened TO the interpreter -- an access
      violation, a stack overflow, a corrupt heap -- and the difference is not a
      matter of degree.

      A value error leaves the process intact, which is why handing it to ON
      ERROR and continuing is correct. A state fault means memory has ALREADY
      been written somewhere it should not have been, and nothing in the
      exception says where or what it hit. Resuming the script on top of that
      trades a loud death for a silent wrong answer, which is the worse of the
      two: the program keeps running and its results cannot be trusted.

      So ON ERROR never sees this code. err() never returns 8 inside a script.
      It exists for the HOST, which reads it from LastError after Run returns
      False, so an application embedding the engine can tell "the script had an
      error nobody handled" from "the interpreter was hurt" -- and, with
      TPhosphorEngine.ContainFaults set, can say so, save the user's work and
      shut down on its own terms instead of meeting the LCL's modal crash dialog
      on a machine with nobody in front of it. }
    peFatal           = 8
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
