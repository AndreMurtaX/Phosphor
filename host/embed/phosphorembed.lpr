{******************************************************************************
  phosphorembed -- the engine embedded as a scripting layer (the third host)

  MIT License. Copyright (c) 2026 Andre Murta.

  Neither a console REPL nor a GUI: this is what "embeddable" means. A host
  program registers its OWN functions, PREPARES a user script once (which defines
  BASIC routines and does any setup), and then CALLS those routines from Pascal as
  many times as it likes, exchanging values and reading back errors -- the engine
  never learning who is driving it.

  It doubles as a test: it asserts each result and exits non-zero on any failure
  (run with --fail to corrupt one expectation and confirm the check can fail).
  docs/embedding.md walks through this file as the worked example.
******************************************************************************}
program phosphorembed;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  SysUtils,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorEngine;

// --- 1. A function THIS host provides to every script it runs ----------------
// The host owns the discount policy; the script just asks for it. Registered by
// signature 'name:codes' -- here no arguments, returning a number.
function host_discount(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  Result := ValDouble(0.10);
end;

// --- the user's script: defines routines the host will call ------------------
const
  UserScript =
    'function total(qty, unit)'                          + #10 +
    '  net = qty * unit'                                 + #10 +
    '  return net - net * host_discount()'               + #10 +   // calls the host fn
    'end function'                                       + #10 +
    ''                                                   + #10 +
    'function greet$(name$)'                             + #10 +
    '  return "hello, " + name$'                         + #10 +
    'end function'                                       + #10 +
    ''                                                   + #10 +
    'function boom()'                                    + #10 +
    '  return 1 / 0'                                     + #10 +   // fails when called
    'end function'                                       + #10;

var
  Ok: Integer = 0;
  Failed: Integer = 0;
  ProveFail: Boolean = False;

procedure Report(Pass: Boolean; const Name: String);
begin
  if Pass then Inc(Ok)
  else begin Inc(Failed); Writeln(StdErr, 'FAIL: ', Name); end;
end;

var
  eng: TPhosphorEngine;
  v: TValue;
  rc: Integer;
begin
  ProveFail := (ParamCount >= 1) and (ParamStr(1) = '--fail');

  eng := TPhosphorEngine.Create;
  try
    // 2. Register the host's own function into the engine.
    eng.Registry.Add('host_discount:', @host_discount);
    // 3. A safety ceiling, since the script could be untrusted.
    eng.MaxSteps := 1000000;

    // 4. Prepare the script once -- this runs its top level and keeps the VM live.
    rc := eng.Prepare(UserScript);
    Report(rc = 0, 'the script prepared cleanly');
    if rc <> 0 then begin Writeln(StdErr, 'prepare failed: ', eng.ErrorMessage); Halt(1); end;

    // 5. Call the BASIC routines from Pascal, repeatedly, exchanging values.
    v := eng.CallFunction('total', [ValInt(3), ValInt(100)]);
    Writeln('total(3, 100)  = ', ValToStr(v));       // 300 - 10% = 270
    Report((not ProveFail) and (Abs(v.Num - 270) < 1E-9), 'total(3,100) = 270');

    v := eng.CallFunction('total', [ValInt(2), ValInt(50)]);
    Writeln('total(2, 50)   = ', ValToStr(v));       // 100 - 10% = 90
    Report(Abs(v.Num - 90) < 1E-9, 'total(2,50) = 90');

    v := eng.CallFunction('greet$', [ValStr('world')]);
    Writeln('greet$("world") = ', ValToStr(v));
    Report((v.Kind = vkString) and (v.Str = 'hello, world'), 'greet$ returns "hello, world"');

    // 6. An error inside a called routine comes back as engine error state,
    //    not a crash -- the host decides what to do.
    v := eng.CallFunction('boom', []);
    Report(eng.LastError.Code = peDivByZero, 'boom() reports division by zero');
    Writeln('boom()          -> ', eng.ErrorMessage);

    // 7. The globals a call changed persist for the next call (same live VM):
    //    total() left `net` set; a second Prepare would be needed to reset.
    v := eng.CallFunction('no_such_function', []);
    Report(eng.LastError.Code = peUnknownFunction, 'an unknown routine is reported, not run');
  finally
    eng.Free;   // Finish() frees the prepared VM and its handles
  end;

  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed > 0 then Halt(1) else Halt(0);
end.
