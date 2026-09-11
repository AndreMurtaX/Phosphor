{******************************************************************************
  probe_onerror -- the WORDING of the abandoned-activation diagnostics.

  tests/negative/33 to /43 pin that these programs are refused. They cannot pin
  what the refusal SAYS: that corpus compares exit codes only, and tests/classic
  runs with stderr discarded. So an edit that garbled either message -- or that
  quietly made both of them say the same thing, or named the wrong function, or
  lost the handler's line -- would leave every runner on both operating systems
  green. A reviewer read all ten by hand and confirmed them once, which is the
  situation this project has a rule about: a completeness claim in prose is a
  promise, a check is the proof.

  From Pascal because the message is a HOST-facing value. `eng.LastError.Message`
  is the string an embedding application shows its user; the console host prints
  it to stderr and the byte-exact runners throw that away. Comparing it here is
  the same question a host asks, it runs on both operating systems, and it is
  exact -- `=`, not `Pos`, so a lost word fails rather than passing quietly.

  WHAT IS PINNED, and each of these was a wrong answer at some point in the four
  rounds this check took:

    - the ON ERROR arm's full text, through both doors (a direct call and a
      callfunc), with the handler's line, the error it took and the abandoned
      call's name;
    - the `gosub` arm's full text, which must NOT be the ON ERROR one: it is the
      spelling with no `on error` in the program at all;
    - the handler line when the handler has no body -- a label as the last line
      of the file installs a pc of exactly FProg.Count, and there is no
      instruction there to take a line from. That used to read "the ON ERROR GOTO
      handler at the end of the program took ... and ran to the end of the
      program", the same clause twice, naming nothing the reader could look at;
    - that the ABANDONING handler is named, not an inner one that resumed after
      it (the record is a snapshot taken at the jump, not a field read at the
      end);
    - that the call left OPEN is named, not a stale frame above it from an
      install that had already returned;
    - the error code and the reported line, which travel with the message;
    - and the other direction: five correct programs whose message must be EMPTY.
      A diagnostic is only worth pinning if the thing that produces it can also
      keep quiet.

  Prints "ok: N" / "fail: M" and exits non-zero on any failure. Run with --fail
  to corrupt one expectation and confirm the check can fail.
******************************************************************************}
program probe_onerror;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  SysUtils, PhosphorErrors, PhosphorEngine;

const
  LF = #10;

var
  Ok: Integer = 0;
  Failed: Integer = 0;
  ProveFail: Boolean = False;

procedure Report(Pass: Boolean; const Name: String);
begin
  if Pass then Inc(Ok)
  else begin Inc(Failed); Writeln(StdErr, 'FAIL: ', Name); end;
end;

{ THE TWO MESSAGES, WRITTEN OUT HERE. Deliberately a second copy of the text
  rather than anything read from the engine: a copy that is generated from the
  thing it checks cannot disagree with it. AWhere is the whole phrase that names
  the handler, because which of its three spellings appears is itself part of
  what is being pinned. }
function Arm1Msg(const AWhere, AErr, AName: String): String;
begin
  Result :=
    'the ON ERROR GOTO handler ' + AWhere + ' took ''' + AErr +
    ''' and ran to the end of the program without ''resume'' or ''resume next'', ' +
    'so the call to ' + AName + ' it was raised inside was never returned from. ' +
    'Resume from the handler, or install it with ''on error call'', which comes ' +
    'back by itself -- a label is always outside the function, so a handler that ' +
    'does neither abandons the call';
end;

function Arm2Msg(const AName: String): String;
begin
  Result :=
    'control reached the end of the program inside ' + AName + ', so the call ' +
    'to it was never returned from. A ''gosub'' made inside a function must ' +
    '''return'', and an ON ERROR handler a function installs must ''resume'' -- ' +
    'a label is always outside the function, so jumping to one leaves the call ' +
    'open and only those two ways go back into it';
end;

{ Run ASource and require that it was REFUSED with exactly AWantMsg at AWantLine. }
procedure CheckRefused(const AName, ASource, AWantMsg: String; AWantLine: Integer);
var
  eng: TPhosphorEngine;
  rc: Integer;
  got: String;
begin
  eng := TPhosphorEngine.Create();
  try
    eng.TimeoutMs := 20000;   { a runaway fails the probe instead of hanging it }
    rc := eng.Run(ASource);
    got := eng.LastError.Message;
    if rc = 0 then
      Report(False, AName + ' (the program was not refused at all)')
    else if eng.LastError.Code <> peRuntime then
      Report(False, AName + ' (code ' + IntToStr(Ord(eng.LastError.Code)) +
             ', wanted peRuntime)')
    else if got <> AWantMsg then
      Report(False, AName + ' (the message reads:' + LF + '  ' + got + LF +
             'and it should read:' + LF + '  ' + AWantMsg + ')')
    else
      Report(eng.ErrorLine = AWantLine,
             AName + ' (reported line ' + IntToStr(eng.ErrorLine) + ', wanted ' +
             IntToStr(AWantLine) + ')');
  finally
    eng.Free;
  end;
end;

{ The other direction: the program runs, and says nothing. }
procedure CheckQuiet(const AName, ASource: String);
var
  eng: TPhosphorEngine;
  rc: Integer;
begin
  eng := TPhosphorEngine.Create();
  try
    eng.TimeoutMs := 20000;
    rc := eng.Run(ASource);
    Report((rc = 0) and (eng.LastError.Message = ''),
           AName + ' (rc ' + IntToStr(rc) + ', message "' +
           eng.LastError.Message + '")');
  finally
    eng.Free;
  end;
end;

{ ---------------------------------------------------------------------------
  THE SOURCES. Every one is laid out so the lines the diagnostics name can be
  counted off the text rather than taken from a run: the first line of the
  source is line 1, and the line each constant below claims is written beside
  it. A handler's own line is the first STATEMENT after its label, because a
  label emits no instruction of its own.
--------------------------------------------------------------------------- }
const
  { 1 function risky   2 on error   3 the fault   4 return   5 endfunction
    6 c = 55   7 the call   8 goto   9 h:   10 the handler   11 tail:   12 tc }
  SrcDirect =
    'function risky(n) local z' + LF +      { 1 }
    '  on error goto h' + LF +              { 2 }
    '  z = 1 / 0' + LF +                    { 3  <- the fault }
    '  return 7' + LF +                     { 4 }
    'endfunction' + LF +                    { 5 }
    'c = 55' + LF +                         { 6 }
    'c = 1 + risky(1)' + LF +               { 7 }
    'goto tail' + LF +                      { 8 }
    'h:' + LF +                             { 9 }
    'hc = 1' + LF +                         { 10 <- the handler }
    'tail:' + LF +                          { 11 }
    'tc = 1' + LF;                          { 12 }

  { The same program through the other door. callfunc re-enters the interpreter
    natively, so the wound shows as the tail running twice rather than as a
    dropped statement -- but the diagnostic is the same one. }
  SrcCallfunc =
    'function risky(n) local z' + LF +      { 1 }
    '  on error goto h' + LF +              { 2 }
    '  z = 1 / 0' + LF +                    { 3  <- the fault }
    '  return 7' + LF +                     { 4 }
    'endfunction' + LF +                    { 5 }
    'c = 55' + LF +                         { 6 }
    'c = 1 + callfunc("risky", 1)' + LF +   { 7 }
    'goto tail' + LF +                      { 8 }
    'h:' + LF +                             { 9 }
    'hc = 1' + LF +                         { 10 <- the handler }
    'tail:' + LF +                          { 11 }
    'tc = 1' + LF;                          { 12 }

  { A HANDLER WITH NO BODY: the label is the last line of the file, so the
    installed pc is exactly FProg.Count and no instruction carries a line. The
    install does, and that is what the message must name. }
  SrcNoBody =
    'function risky(n) local z' + LF +      { 1 }
    '  on error goto h' + LF +              { 2  <- the install }
    '  z = 1 / 0' + LF +                    { 3  <- the fault }
    '  return 7' + LF +                     { 4 }
    'endfunction' + LF +                    { 5 }
    'r = risky(1)' + LF +                   { 6 }
    'h:' + LF;                              { 7 }

  { `gosub` out of a function body to a top-level label that ends in `goto`.
    No `on error` anywhere: the ON ERROR arm has nothing to have recorded, and
    the message must be the other one. The line it reports is where the
    abandoned function's body starts. }
  SrcGosub =
    'function risky(n) local z' + LF +      { 1 }
    '  gosub sub1' + LF +                   { 2  <- risky''s body starts here }
    '  return 7' + LF +                     { 3 }
    'endfunction' + LF +                    { 4 }
    'r = risky(1)' + LF +                   { 5 }
    'goto tail' + LF +                      { 6 }
    'sub1:' + LF +                          { 7 }
    'sc = 1' + LF +                         { 8 }
    'goto tail' + LF +                      { 9 }
    'tail:' + LF +                          { 10 }
    'tc = 1' + LF;                          { 11 }

  { THE ABANDONING HANDLER IS NAMED, NOT AN INNER ONE THAT CAME BACK. The
    handler abandons risky and then calls an ordinary helper whose own handler
    resumes. Reading the ON ERROR fields at the end names the INNER handler and
    the inner error; the record is taken at the jump, so it names this one. }
  SrcInnerResume =
    'function risky(n) local z' + LF +      { 1 }
    '  on error goto h' + LF +              { 2 }
    '  z = 1 / 0' + LF +                    { 3  <- the fault that abandons }
    '  return 7' + LF +                     { 4 }
    'endfunction' + LF +                    { 5 }
    'function helper(n) local w' + LF +     { 6 }
    '  on error goto h2' + LF +             { 7 }
    '  w = 2 / 0' + LF +                    { 8 }
    '  return 3' + LF +                     { 9 }
    'endfunction' + LF +                    { 10 }
    'r = callfunc("risky", 1)' + LF +       { 11 }
    'goto tail' + LF +                      { 12 }
    'h:' + LF +                             { 13 }
    'k = helper(1)' + LF +                  { 14 <- the handler }
    'goto tail' + LF +                      { 15 }
    'h2:' + LF +                            { 16 }
    'resume next' + LF +                    { 17 }
    'tail:' + LF +                          { 18 }
    'tc = 1' + LF;                          { 19 }

  { THE CALL LEFT OPEN IS NAMED, NOT A STALE FRAME ABOVE IT. deep() installs the
    handler two frames down and RETURNS, so the fault dispatcher stands the VM
    over slots deep() and mid() left behind. Naming the frame under the pointer
    at the end names deep, which came back perfectly well; the call actually
    abandoned is risky. }
  SrcStaleDeep =
    'function deep(n)' + LF +               { 1 }
    '  on error goto h' + LF +              { 2 }
    '  return 1' + LF +                     { 3 }
    'endfunction' + LF +                    { 4 }
    'function mid(n)' + LF +                { 5 }
    '  return deep(n)' + LF +               { 6 }
    'endfunction' + LF +                    { 7 }
    'function risky(n) local z' + LF +      { 8 }
    '  z = 1 / 0' + LF +                    { 9  <- the fault }
    '  return 7' + LF +                     { 10 }
    'endfunction' + LF +                    { 11 }
    'x = mid(1)' + LF +                     { 12 }
    'r = callfunc("risky", 1)' + LF +       { 13 }
    'goto tail' + LF +                      { 14 }
    'h:' + LF +                             { 15 }
    'hc = 1' + LF +                         { 16 <- the handler }
    'goto tail' + LF +                      { 17 }
    'tail:' + LF +                          { 18 }
    'tc = 1' + LF;                          { 19 }

  { --- and the programs that must say nothing ---------------------------- }

  { A TOP-LEVEL handler that never resumes: documented and ordinary. }
  QuietTopLevel =
    'on error goto h' + LF +
    'z = 1 / 0' + LF +
    'goto tail' + LF +
    'h:' + LF +
    'hc = 1' + LF +
    'tail:' + LF +
    'tc = 1' + LF;

  { A handler installed in a function over a fault raised one call DEEPER, then
    resumed. The resume has to put back everything between the two levels. }
  QuietOverlap =
    'function g(n) local z' + LF +
    '  z = 10 / d' + LF +
    '  return 3' + LF +
    'endfunction' + LF +
    'function f(n) local w' + LF +
    '  on error goto h' + LF +
    '  w = 1000 + g(1)' + LF +
    '  return w' + LF +
    'endfunction' + LF +
    'd = 0' + LF +
    'r = f(1)' + LF +
    'goto tail' + LF +
    'h:' + LF +
    'd = 2' + LF +
    'resume' + LF +
    'tail:' + LF +
    'tc = 1' + LF;

  { A fault raised by the HANDLER''s own top-level code while the VM stands over
    a stale deep install''s fabricated frames. The depths look like a call is
    open; nothing is. }
  QuietFabricated =
    'function deep(n)' + LF +
    '  on error goto h' + LF +
    '  return 1' + LF +
    'endfunction' + LF +
    'function mid(n)' + LF +
    '  return deep(n)' + LF +
    'endfunction' + LF +
    'x = mid(1)' + LF +
    'z = 1 / 0' + LF +
    'goto tail' + LF +
    'h:' + LF +
    'on error goto h2' + LF +
    'z2 = 1 / 0' + LF +
    'goto tail' + LF +
    'h2:' + LF +
    'hc = 1' + LF +
    'tail:' + LF +
    'tc = 1' + LF;

  { `gosub` that RETURNS: the nearest neighbour of the arm-2 refusal. }
  QuietGosubReturns =
    'function risky(n) local z' + LF +
    '  gosub sub1' + LF +
    '  return 7' + LF +
    'endfunction' + LF +
    'r = risky(1)' + LF +
    'goto tail' + LF +
    'sub1:' + LF +
    'sc = 1' + LF +
    'return' + LF +
    'tail:' + LF +
    'tc = 1' + LF;

  { `on error call` inside a function: it comes back by itself, and this check
    must never touch it. }
  QuietOnErrorCall =
    'function risky(n) local z' + LF +
    '  on error call oc' + LF +
    '  z = 1 / 0' + LF +
    '  return 7' + LF +
    'endfunction' + LF +
    'function oc(code%, msg$)' + LF +
    '  return 0' + LF +
    'endfunction' + LF +
    'r = callfunc("risky", 1)' + LF +
    'tc = 1' + LF;

var
  WantDirect: String;

begin
  ProveFail := (ParamCount >= 1) and (ParamStr(1) = '--fail');

  { --- the ON ERROR arm, both doors -------------------------------------- }
  WantDirect := Arm1Msg('at line 10', 'division by zero', 'risky');
  if ProveFail then WantDirect := WantDirect + ' (corrupted)';
  CheckRefused('the ON ERROR arm through a direct call', SrcDirect, WantDirect, 3);
  { THE LINE THROUGH THE CALLFUNC DOOR IS THE CALL SITE, not the fault. That is
    the engine's own convention for anything raised inside a re-entrant run --
    the error travels out of the nested interpreter and opCall reports it at the
    statement that made the call -- and it is not this check's to change.
    Established against the PRISTINE binary, with an ordinary uncaught
    `z = 1 / 0` in a callfunc'd body: the body's line is 4, the call is on line 9,
    and the message reads ...:9: division by zero. The three expectations below
    that name a call site rather than a fault line are that convention, not a
    number copied off this probe's own run. }
  CheckRefused('the ON ERROR arm through callfunc', SrcCallfunc,
               Arm1Msg('at line 10', 'division by zero', 'risky'), 7);

  { --- a handler with no body -------------------------------------------- }
  CheckRefused('a handler whose label is the last line names its install',
               SrcNoBody,
               Arm1Msg('installed at line 2', 'division by zero', 'risky'), 3);

  { --- the gosub arm ------------------------------------------------------ }
  CheckRefused('the gosub arm is its own message', SrcGosub, Arm2Msg('risky'), 2);

  { --- what the record has to remember ----------------------------------- }
  CheckRefused('the abandoning handler is named, not the inner one that resumed',
               SrcInnerResume,
               Arm1Msg('at line 14', 'division by zero', 'risky'), 11);
  CheckRefused('the call left open is named, not a stale frame above it',
               SrcStaleDeep,
               Arm1Msg('at line 16', 'division by zero', 'risky'), 13);

  { --- and the programs that must say nothing ---------------------------- }
  CheckQuiet('a top-level handler that never resumes', QuietTopLevel);
  CheckQuiet('a resume that reaches back past the handler frame', QuietOverlap);
  CheckQuiet('a fault raised in a fabricated frame', QuietFabricated);
  CheckQuiet('a gosub that returns', QuietGosubReturns);
  CheckQuiet('`on error call` inside a function', QuietOnErrorCall);

  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed > 0 then Halt(1) else Halt(0);
end.
