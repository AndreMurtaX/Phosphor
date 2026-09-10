{******************************************************************************
  Phosphor BASIC -- the demo's scripting, with no user interface attached.

  MIT License. Copyright (c) 2026 Andre Murta.

  THIS UNIT EXISTS SEPARATELY ON PURPOSE, and the reason is a rule this project
  paid for: ask of every program in the tree what RUNS it, and if the answer is
  "a person", that is the bug before any line of it is read. A demo whose only
  entry point is a button is a program nothing runs. So everything that DECIDES
  lives here -- registering the host's own functions, setting the ceilings,
  running a script, classifying what came back -- and it is a pure function of
  its input with no LCL, no form and no display. mainform.pas is the part that
  is left, and it has no decisions in it.

  demo_smoke.lpr calls straight into this unit and asserts all three outcomes,
  so the demo is exercised by the suite on both operating systems, headless,
  every run.

  WHAT IT DEMONSTRATES, which is the whole point of a demo:

    1. a script that runs and prints
    2. a script that fails and handles its own failure with ON ERROR
    3. a script that fails and does NOT handle it -- an ordinary error the host
       reports
    4. a ceiling: a runaway loop stopped by MaxSteps, which ON ERROR cannot catch
    5. A FAULT IN THE HOST'S OWN CODE. app_boom() raises an access violation the
       way a buggy host function would, and with ContainFaults the application
       gets a message and keeps its process instead of meeting the LCL's modal
       crash dialog. See docs/embedding.md.
******************************************************************************}
unit PhosphorDemoRunner;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, PhosphorValue, PhosphorErrors, PhosphorEngine;

type
  { What became of a run. The host cares about the difference between the last
    two, which is exactly why peFatal exists: "the script had an error nobody
    handled" and "the interpreter was hurt" are different news. }
  TDemoOutcome = (
    doOk,            // ran to the end
    doScriptError,   // an ordinary error the script did not handle
    doLimit,         // a ceiling: the script spent more than it was allowed
    doFault          // peFatal: contained, and this engine is spent
  );

  TDemoResult = record
    Outcome: TDemoOutcome;
    Output: String;      // everything the script printed
    HostLog: String;     // everything the script sent through app_log
    Message: String;     // the error, when there was one
    Code: Integer;       // LastError.Code, for a host that wants the number
  end;

{ Run ASource with the demo's host functions registered and the ceilings the
  documentation prescribes. Never raises: that is the point of the exercise. }
function RunDemoScript(const ASource: String): TDemoResult;

{ The four scripts the form's buttons offer, so the smoke test and the user
  interface are demonstrating the same things rather than two different sets. }
function DemoScriptHello: String;
function DemoScriptCaught: String;
function DemoScriptUncaught: String;
function DemoScriptRunaway: String;
function DemoScriptHostFault: String;

function OutcomeName(AOutcome: TDemoOutcome): String;

implementation

{ ----------------------------------------------------------------------------
  THE HOST'S OWN FUNCTIONS.

  A registered function is a plain procedure pointer, so what it needs to reach
  lives at unit level. That is the shape every library in this tree uses.
---------------------------------------------------------------------------- }

var
  GHostLog: String = '';

function h_app_name(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  E := NoError();
  Result := ValStr('Phosphor demo');
end;

function h_app_log(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  E := NoError();
  GHostLog := GHostLog + A[0].Str + LineEnding;
  { A mutator answers information, not a success flag -- house rule. The count of
    lines the host has logged is something a script can actually use. }
  Result := ValInt(Length(GHostLog));
end;

function h_app_boom(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  E := NoError();
  Result := ValInt(0);
  { DELIBERATE, and it stands in for the real thing: a host function with a bug
    in it. Nothing in the engine can prevent this -- the code is the
    application's own -- so the only question is what the application SEES when
    it happens. Without ContainFaults this leaves Run as a Pascal exception and,
    in a program that links Forms, ends at the LCL's modal crash dialog. With it,
    the run ends, the process lives, and the caller is told. }
  raise EAccessViolation.Create('app_boom: a deliberate bug in the host''s own code');
end;

{ ----------------------------------------------------------------------------
  THE RUNNER
---------------------------------------------------------------------------- }

type
  TOutputSink = class
    Text: String;
    procedure Take(const AText: String);
  end;

procedure TOutputSink.Take(const AText: String);
begin
  Text := Text + AText;
end;

function RunDemoScript(const ASource: String): TDemoResult;
var
  eng: TPhosphorEngine;
  sink: TOutputSink;
  rc: Integer;
begin
  Result.Outcome := doOk;
  Result.Output := '';
  Result.HostLog := '';
  Result.Message := '';
  Result.Code := 0;

  GHostLog := '';
  sink := TOutputSink.Create();
  eng := TPhosphorEngine.Create();
  try
    eng.OnOutput := @sink.Take;

    { The host's own vocabulary. The suffix on the NAME is the return type:
      app_name$ answers a string, app_log answers a number. }
    eng.Registry.Add('app_name$:', @h_app_name);
    eng.Registry.Add('app_log:$', @h_app_log);
    eng.Registry.Add('app_boom:', @h_app_boom);

    { The ceilings docs/embedding.md prescribes for a script the application did
      not write. Generous enough that nothing here notices them, small enough
      that a runaway loop stops in well under a second.

      ALL FOUR. This demonstration set three of them and left memory unbounded,
      which is the shape the fourth ceiling was added for: three instructions can
      take 14.7 GB while the other three watch. A demonstration of bounding an
      untrusted script has to bound it. }
    eng.MaxSteps := 2000000;
    eng.TimeoutMs := 3000;
    eng.MaxOutputBytes := 1024 * 1024;
    eng.MaxMemoryBytes := 256 * 1024 * 1024;

    { AND THE ONE THIS DEMO EXISTS TO SHOW. Off by default in the engine; a
      desktop application that would rather tell its user and save their work
      than vanish should turn it on. }
    eng.ContainFaults := True;

    rc := eng.Run(ASource);

    Result.Output := sink.Text;
    Result.HostLog := GHostLog;
    Result.Code := Ord(eng.LastError.Code);
    if rc = 0 then
      Result.Outcome := doOk
    else
    begin
      Result.Message := eng.ErrorMessage;
      case eng.LastError.Code of
        peFatal: Result.Outcome := doFault;
        peLimit: Result.Outcome := doLimit;
      else
        Result.Outcome := doScriptError;
      end;
    end;
  finally
    eng.Free;
    sink.Free;
  end;
end;

function OutcomeName(AOutcome: TDemoOutcome): String;
begin
  case AOutcome of
    doOk:          Result := 'ran to the end';
    doScriptError: Result := 'the script failed and did not handle it';
    doLimit:       Result := 'the script hit a ceiling the host set';
    doFault:       Result := 'the interpreter faulted -- contained, process alive';
  else
    Result := '?';
  end;
end;

{ ----------------------------------------------------------------------------
  THE SCRIPTS
---------------------------------------------------------------------------- }

function DemoScriptHello: String;
begin
  Result :=
    'rem a script talking to the application that hosts it' + LineEnding +
    'println "hello from " + app_name$()' + LineEnding +
    'n = app_log("the script says hello")' + LineEnding +
    'for i = 1 to 3' + LineEnding +
    '  println "  line " + str$(i)' + LineEnding +
    'next' + LineEnding +
    'println "the host log holds " + str$(n) + " characters"' + LineEnding;
end;

function DemoScriptCaught: String;
begin
  Result :=
    'rem the script handles its own failure and carries on' + LineEnding +
    'on error goto oops' + LineEnding +
    'x = 1 / 0' + LineEnding +
    'println "this line is reached by resume next"' + LineEnding +
    'end' + LineEnding +
    'oops:' + LineEnding +
    'println "caught: " + errmsg$() + " (err " + str$(err()) + ")"' + LineEnding +
    'resume next' + LineEnding;
end;

function DemoScriptUncaught: String;
begin
  Result :=
    'rem no handler, so the HOST is told' + LineEnding +
    'println "about to divide"' + LineEnding +
    'x = 1 / 0' + LineEnding +
    'println "never printed"' + LineEnding;
end;

function DemoScriptRunaway: String;
begin
  Result :=
    'rem a ceiling ON ERROR cannot catch -- a script must not be able to sit' + LineEnding +
    'rem on top of the limit that bounds it' + LineEnding +
    'on error goto h' + LineEnding +
    'top:' + LineEnding +
    'x = x + 1' + LineEnding +
    'goto top' + LineEnding +
    'h:' + LineEnding +
    'resume next' + LineEnding;
end;

function DemoScriptHostFault: String;
begin
  Result :=
    'rem app_boom() is the APPLICATION''s function, and it has a bug in it.' + LineEnding +
    'rem ON ERROR is not offered this and never will be: by the time the fault' + LineEnding +
    'rem fires, a wild write has already landed somewhere.' + LineEnding +
    'on error goto h' + LineEnding +
    'println "calling into the host"' + LineEnding +
    'x = app_boom()' + LineEnding +
    'println "never printed, handler or no handler"' + LineEnding +
    'end' + LineEnding +
    'h:' + LineEnding +
    'println "never printed either"' + LineEnding +
    'resume next' + LineEnding;
end;

end.
