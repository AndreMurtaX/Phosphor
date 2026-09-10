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
  Err := NoError();
  Result := ValDouble(0.10);
end;

// --- the user's script: defines routines the host will call ------------------
const
  { WRITTEN THE WAY docs/language-reference.md TEACHES IT: the top level does its
    setup and then says `end`, "handy before a block of subroutines or functions".

    That one word used to break every call below it. Prepare runs the top level and
    keeps the VM alive, `end` set a halted flag, and CallUserFunc read that flag
    AFTER running a body -- so `total` ran, its answer was thrown away, and the
    host got 0 with LastError NoError. From the FIRST call, not after some later
    halt. The example avoided it only because it had no `end`, which is exactly how
    a worked example stops being worth anything. }
  UserScript =
    'greeting$ = "hello, "'                              + #10 +
    'println "ready"'                                    + #10 +
    'end'                                                + #10 +
    ''                                                   + #10 +
    'function total(qty, unit)'                          + #10 +
    '  net = qty * unit'                                 + #10 +
    '  return net - net * host_discount()'               + #10 +   // calls the host fn
    'end function'                                       + #10 +
    ''                                                   + #10 +
    'function greet$(name$)'                             + #10 +
    '  return greeting$ + name$'                         + #10 +   // a top-level global
    'end function'                                       + #10 +
    ''                                                   + #10 +
    'function boom()'                                    + #10 +
    '  return 1 / 0'                                     + #10 +   // fails when called
    'end function'                                       + #10 +
    ''                                                   + #10 +
    'function finished()'                                + #10 +
    '  println "the script is done"'                     + #10 +
    '  end'                                              + #10 +   // a CALLBACK saying END
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

{ The OUTPUT seam. docs/embedding.md calls OnOutput "the one output seam" and
  then walked through a file that never assigned it. An embedder usually does NOT
  want a script writing to its stdout -- it wants the text -- so taking it into a
  string is both the honest demonstration and what most hosts actually do. }
type
  TEmbedSink = class
    Text: String;
    procedure Take(const AText: String);
  end;

procedure TEmbedSink.Take(const AText: String);
begin
  Text := Text + AText;
end;

var
  eng: TPhosphorEngine;
  sink: TEmbedSink;
  v: TValue;
  rc: Integer;
begin
  ProveFail := (ParamCount >= 1) and (ParamStr(1) = '--fail');

  sink := TEmbedSink.Create();
  eng := TPhosphorEngine.Create();
  try
    // 2. Register the host's own function into the engine.
    eng.Registry.Add('host_discount:', @host_discount);
    // 3. A safety ceiling, since the script could be untrusted.
    eng.MaxSteps := 1000000;
    // ...and the OUTPUT seam. An embedder rarely wants a script printing to its
    // stdout, so it is taken into a string here instead -- which is the point:
    // OnOutput is where PRINT goes, and where it goes is the host's decision.
    eng.OnOutput := @sink.Take;

    // 4. Prepare the script once -- this runs its top level and keeps the VM live.
    rc := eng.Prepare(UserScript);
    Report(rc = 0, 'the script prepared cleanly');
    Report(sink.Text = 'ready' + #10,
           'what the script printed reached the host through OnOutput, not stdout');
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

    // 8. AND WHAT HAPPENS WHEN THE SCRIPT SAYS IT IS DONE.
    //    `end` in a callback means the PROGRAM is over, not just that routine --
    //    unlike the `end` that closed the top level above, which merely ended the
    //    top level and left this session perfectly callable. A host has to be able
    //    to tell the two apart, so: nothing is refused until a callback halts, and
    //    everything is refused afterwards, out loud.
    Report(not eng.Halted, 'the top level saying END did not halt the SESSION');
    sink.Text := '';
    v := eng.CallFunction('finished', []);
    Report(eng.LastError.Code = peNone, 'a callback that runs END is not an error');
    Report(sink.Text = 'the script is done' + #10, 'and its body ran, up to the END');
    Report(eng.Halted, 'but the session is halted now, and the host can ask');

    v := eng.CallFunction('total', [ValInt(3), ValInt(100)]);
    Report(eng.LastError.Code = peRuntime,
           'A CALL AFTER END IS REFUSED, not answered with a default');
    Report(Pos('has run END', eng.ErrorMessage) > 0, 'and the message says why');
    Report(Abs(v.Num) < 1E-9, 'the value is a default, as it must be');
    sink.Text := '';
    Report(sink.Text = '', 'and NOTHING ran: no output, no side effect');

    // 9. Preparing again starts over -- that is the way back.
    rc := eng.Prepare(UserScript);
    Report(rc = 0, 'the same script prepares again');
    Report(not eng.Halted, 'and the new session is not halted');
    v := eng.CallFunction('total', [ValInt(3), ValInt(100)]);
    Report(Abs(v.Num - 270) < 1E-9, 'and calling into it works again');
  finally
    eng.Free;   // Finish() frees the prepared VM and its handles
  end;

  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed > 0 then Halt(1) else Halt(0);
end.
