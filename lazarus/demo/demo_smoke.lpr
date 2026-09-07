{******************************************************************************
  Phosphor BASIC -- what runs the Lazarus demo.

  MIT License. Copyright (c) 2026 Andre Murta.

  The demo is a windowed application, and a windowed application is a program
  nothing runs: its only entry point is a person clicking. That is a defect this
  project has already paid for twice -- the Windows key encoder and phosphorgui
  were both found by hand, on an afternoon, because nothing automated ever
  executed them, and neither had a weak test; neither had a test at all.

  So the demo's DECISIONS live in PhosphorDemoRunner, with no LCL and no display
  attached, and this program calls straight into them. It runs in the suite on
  both operating systems, headless, on every run. What the buttons do is what is
  asserted here -- the form offers the same five scripts from the same unit, so
  the two cannot drift apart.

  Prints "ok: N" / "fail: M" and exits non-zero on any failure.
  Run with --fail to corrupt one expectation and confirm the check can fail.
******************************************************************************}
program demo_smoke;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  SysUtils, PhosphorDemoRunner;

var
  Ok: Integer = 0;
  Failed: Integer = 0;
  ProveFail: Boolean = False;

procedure Report(Pass: Boolean; const Name: String);
begin
  if Pass then Inc(Ok)
  else begin Inc(Failed); Writeln(StdErr, 'FAIL: ', Name); end;
end;

procedure CheckOutcome(const AName, ASource: String; AWant: TDemoOutcome);
var
  r: TDemoResult;
begin
  r := RunDemoScript(ASource);
  Report(r.Outcome = AWant,
         AName + ' (wanted ' + OutcomeName(AWant) + ', got ' +
         OutcomeName(r.Outcome) + ': ' + r.Message + ')');
end;

var
  r: TDemoResult;
begin
  ProveFail := (ParamCount >= 1) and (ParamStr(1) = '--fail');

  { 1. IT RUNS, IT PRINTS, AND IT REACHES BACK INTO THE APPLICATION. }
  r := RunDemoScript(DemoScriptHello);
  Report(r.Outcome = doOk, 'the hello script runs to the end');
  Report(Pos('hello from Phosphor demo', r.Output) > 0,
         '...and a host FUNCTION answered it (app_name$)');
  Report(Pos('line 3', r.Output) > 0, '...and its loop printed every pass');
  Report(Pos('the script says hello', r.HostLog) > 0,
         '...and a host PROCEDURE received what it sent (app_log)');
  Report(r.Message = '', '...with no error to report');

  { 2. THE SCRIPT HANDLES ITS OWN FAILURE. This is the ordinary case and the one
       ON ERROR exists for: the error is a VALUE, the process is untouched, and
       carrying on is correct. }
  r := RunDemoScript(DemoScriptCaught);
  Report(r.Outcome = doOk, 'a handled error is not the host''s problem');
  Report(Pos('caught: division by zero', r.Output) > 0,
         '...and errmsg$() named it inside the script');
  Report(Pos('reached by resume next', r.Output) > 0,
         '...and resume next carried on past it');

  { 3. NOBODY HANDLED IT, so the host is told -- and told the ordinary way. }
  r := RunDemoScript(DemoScriptUncaught);
  Report(r.Outcome = doScriptError, 'an unhandled error reaches the host');
  Report(Pos('division by zero', r.Message) > 0, '...naming what went wrong');
  Report(Pos('about to divide', r.Output) > 0,
         '...and what the script printed before it is still there');

  { 4. A CEILING, which ON ERROR must NOT be able to catch. The script above it
       installs a handler and loops for ever; if the handler could catch this,
       the ceiling would bound nothing. }
  r := RunDemoScript(DemoScriptRunaway);
  Report(r.Outcome = doLimit, 'a runaway loop is stopped by MaxSteps');
  Report(Pos('step budget', r.Message) > 0, '...and says which ceiling it was');

  { 5. THE ONE THIS DEMO WAS BUILT FOR: a fault in the HOST'S OWN function.
       Three separate assertions, because three separate things must be true. }
  r := RunDemoScript(DemoScriptHostFault);
  Report(r.Outcome = doFault, 'a fault in a host function is contained');
  Report(r.Code = 8, '...carries peFatal (8), not an ordinary error code');
  Report(Pos('EAccessViolation', r.Message) > 0,
         '...and names the exception class, which is the news for a log');
  Report(Pos('never printed', r.Output) = 0,
         '...and ON ERROR did NOT run the handler');
  Report(Pos('calling into the host', r.Output) > 0,
         '...while what ran before the fault is still there to show the user');

  { AND THE PROCESS IS STILL HERE. Everything after this line is proof: a demo
    that died at check 5 would print no counts at all. }
  r := RunDemoScript(DemoScriptHello);
  Report(r.Outcome = doOk,
         'the application survived the fault and can script again');

  if ProveFail then
    Report(False, 'ProveFail: a deliberate failure');

  Writeln('ok: ', Ok, ' fail: ', Failed);
  if Failed > 0 then Halt(1);
end.
