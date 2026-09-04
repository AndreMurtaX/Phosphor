{******************************************************************************
  Phosphor BASIC -- error library (a function package under engine/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  The BASIC-visible face of the ON ERROR handler. When a runtime error is caught
  by `on error goto <label>`, the handler reads what happened with:

    err()        the error code   (0 none, 1 int-overflow, 2 div-by-zero,
                 3 type-mismatch, 4 unknown-function, 5 syntax, 6 runtime)
    errmsg$()    the error message
    erl()        the source line where it occurred
    err_clear()  reset err()/errmsg$()/erl() to "no error"

  And a program can raise its own catchable error:

    error(msg$)  fail the current statement with a runtime error carrying msg$
                 -- caught by an active ON ERROR handler, like any other.

  err/errmsg$/erl/err_clear are host-aware (they read the executing VM's caught-
  error state through the same seam callfunc uses); error is a plain function that
  simply returns an error, which the VM turns into a fault. All host-agnostic --
  running and catching a BASIC error needs no console, file or window.
******************************************************************************}
unit PhosphorErrLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorVM;

procedure RegisterErrFuncs(Reg: TPhosphorRegistry);

implementation

function f_err(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(TPhosphorVM(AVM).ErrCode); end;

function f_errmsg(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValStr(TPhosphorVM(AVM).ErrMessage); end;

function f_erl(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(TPhosphorVM(AVM).ErrLine); end;

function f_err_clear(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); TPhosphorVM(AVM).ClearError(); Result := ValInt(0); end;

{ error(msg$) -- raise a catchable runtime error. Returning it from a registered
  function is exactly how a library reports failure, so the VM faults on it. }
function f_error(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := MakeError(peRuntime, Args[0].Str);
  Result := ValInt(0);
end;

procedure RegisterErrFuncs(Reg: TPhosphorRegistry);
begin
  Reg.AddHost('err:',       @f_err);
  Reg.AddHost('errmsg$:',   @f_errmsg);
  Reg.AddHost('erl:',       @f_erl);
  Reg.AddHost('err_clear:', @f_err_clear);
  Reg.Add('error:$', @f_error);
end;

end.
