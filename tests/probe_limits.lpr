{******************************************************************************
  probe_limits -- a Pascal test of the execution ceilings (phase-3 step 2)

  Limits are a HOST-facing feature: the embedder sets them on TPhosphorEngine
  before Run, so they are tested here from Pascal, the way a host uses them --
  not from a .bas file (the byte-exact runner sets no limits). Each check runs a
  script under a ceiling and asserts the run aborted with peLimit, that a normal
  script within the ceilings runs clean, and that ON ERROR cannot catch a limit.

  ALSO the FRONT END's ceilings and its refusal to read a token that is not
  there, and those are here for a sharper reason than convenience. Each of them
  used to KILL the process -- an access violation on a source file whose first
  character cannot start a token, a stack overflow on a run of prefix operators
  -- and the negative-test harness asks only whether the exit code was non-zero.
  A crash is non-zero. A .bas file therefore could not tell the fix from the bug:
  it would have gone green either way. From Pascal the question is the one an
  embedding host actually asks: Compile must RETURN False and say why, and it
  must not raise.

  Prints "ok: N" / "fail: M" and exits non-zero on any failure. Run with --fail
  to corrupt one expectation and confirm the check can fail.
******************************************************************************}
program probe_limits;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  SysUtils, PhosphorErrors, PhosphorEngine, PhosphorCompiler, PhosphorOpcodes,
  PhosphorValue, PhosphorRegistry, PhosphorVM;

var
  Ok: Integer = 0;
  Failed: Integer = 0;
  ProveFail: Boolean = False;

procedure Report(Pass: Boolean; const Name: String);
begin
  if Pass then Inc(Ok)
  else begin Inc(Failed); Writeln(StdErr, 'FAIL: ', Name); end;
end;

{ Run ASource with the given ceilings; assert the outcome. AWantLimit true means
  the run must abort with peLimit; false means it must succeed (Run = 0). }
procedure Check(const AName, ASource: String;
  ASteps, AOutput, ATimeoutMs: Int64; AWantLimit: Boolean);
var
  eng: TPhosphorEngine;
  rc: Integer;
  hitLimit: Boolean;
begin
  eng := TPhosphorEngine.Create();
  try
    eng.MaxSteps := ASteps;
    eng.MaxOutputBytes := AOutput;
    eng.TimeoutMs := ATimeoutMs;
    rc := eng.Run(ASource);
    hitLimit := (rc <> 0) and (eng.LastError.Code = peLimit);
    if AWantLimit then
      Report(hitLimit, AName + ' (expected a limit)')
    else
      Report(rc = 0, AName + ' (expected success)');
  finally
    eng.Free;
  end;
end;

{ The memory ceiling, which needs its own runner because it is the only one of
  the four whose interesting cases are about SIZE rather than about time. AWant is
  the fragment the message must carry, or '' for a run that must succeed. }
procedure CheckMem(const AName, ASource: String; AMemBytes: Int64;
  const AWant: String; AHostHolds: Integer = 0);
var
  eng: TPhosphorEngine;
  rc: Integer;
  ballast: String;
begin
  { AHostHolds is memory the HOST is already sitting on when the run begins. The
    ceiling is about what the SCRIPT adds, so it must make no difference -- and
    measuring absolute heap instead of growth is a one-line change that no other
    check here can see. An application holding 300 MB of its own data would
    otherwise refuse every script under a 32 MB ceiling before it ran a line. }
  ballast := '';
  if AHostHolds > 0 then ballast := StringOfChar('B', AHostHolds);
  eng := TPhosphorEngine.Create();
  try
    eng.MaxMemoryBytes := AMemBytes;
    eng.TimeoutMs := 60000;   { so a runaway case fails the probe instead of hanging it }
    rc := eng.Run(ASource);
    if AWant = '' then
      Report(rc = 0, AName + ' (expected success, got ' + eng.ErrorMessage + ')')
    else
      Report((rc <> 0) and (eng.LastError.Code = peLimit) and
             (Pos(AWant, eng.ErrorMessage) > 0),
             AName + ' (expected a limit saying "' + AWant + '", got code ' +
             IntToStr(Ord(eng.LastError.Code)) + ' ' + eng.ErrorMessage + ')');
  finally
    eng.Free;
  end;
  if Length(ballast) <> AHostHolds then
    Report(False, AName + ' (the ballast was collected under the check)');
end;

{ Compile ASource and require that it is REJECTED -- Compile returns False, the
  message contains AWantFragment, and NOTHING IS RAISED.

  The except branch is the whole point of doing this from Pascal. An exception
  escaping the compiler is exactly the defect under test (FTokens[-1] on an empty
  token array raised EAccessViolation), so it is caught and reported as a failed
  check rather than being allowed to kill the probe: a dead probe tells the suite
  only that something did not run. This is the same discipline tests/suite/54
  uses for its loops -- a crash test that FAILS instead of crashing the runner. }
procedure CheckRejected(const AName, ASource, AWantFragment: String);
var
  comp: TPhosphorCompiler;
  prog: TProgram;
  rejected: Boolean;
  msg: String;
begin
  comp := TPhosphorCompiler.Create();
  try
    prog := nil;
    msg := '';
    rejected := False;
    try
      rejected := not comp.Compile(ASource, prog);
      if rejected then msg := comp.ErrorMessage;
    except
      on E: Exception do
      begin
        rejected := False;
        msg := 'RAISED ' + E.ClassName + ': ' + E.Message;
      end;
    end;
    if prog <> nil then prog.Free;
    Report(rejected and (Pos(AWantFragment, msg) > 0),
           AName + ' (wanted "' + AWantFragment + '", got "' + msg + '")');
  finally
    comp.Free;
  end;
end;

{ The other half of a ceiling: it must not reject what it was never aimed at.
  A guard that says no to ordinary nesting is a worse bug than the crash. }
procedure CheckAccepted(const AName, ASource: String);
var
  comp: TPhosphorCompiler;
  prog: TProgram;
  accepted: Boolean;
  msg: String;
begin
  comp := TPhosphorCompiler.Create();
  try
    prog := nil;
    msg := '';
    accepted := False;
    try
      accepted := comp.Compile(ASource, prog);
      if not accepted then msg := comp.ErrorMessage;
    except
      on E: Exception do
      begin
        accepted := False;
        msg := 'RAISED ' + E.ClassName + ': ' + E.Message;
      end;
    end;
    if prog <> nil then prog.Free;
    Report(accepted, AName + ' (rejected with "' + msg + '")');
  finally
    comp.Free;
  end;
end;

{ ErrorAtEndOfInput is the flag the REPL reads to decide whether reading another
  line could possibly help. It is a different fact from what the message says and
  cannot be recovered from the text, so it gets its own check. }
procedure CheckErrAtEof(const AName, ASource: String; AWant: Boolean);
var
  comp: TPhosphorCompiler;
  prog: TProgram;
  got: Boolean;
begin
  comp := TPhosphorCompiler.Create();
  try
    prog := nil;
    got := not AWant;   // a raise below leaves the check failing, not passing
    try
      if not comp.Compile(ASource, prog) then got := comp.ErrorAtEndOfInput;
    except
      on E: Exception do got := not AWant;
    end;
    if prog <> nil then prog.Free;
    Report(got = AWant, AName);
  finally
    comp.Free;
  end;
end;

{ Repeat AUnit ACount times -- the generated sources below. }
function Repeated(const AUnit: String; ACount: Integer): String;
var i: Integer;
begin
  Result := '';
  for i := 1 to ACount do Result := Result + AUnit;
end;

const
  LF = #10;
  // Tight infinite loops (no output).
  ForeverLoop = 'top:' + LF + 'x = x + 1' + LF + 'goto top' + LF;
  // Infinite output.
  ForeverPrint = 'top:' + LF + 'print "x"' + LF + 'goto top' + LF;
  // Tries to catch the limit and keep going -- must NOT be able to.
  CatchAndLoop = 'on error goto h' + LF + 'top:' + LF + 'x = x + 1' + LF +
                 'goto top' + LF + 'h:' + LF + 'resume next' + LF;

  { A CEILING CROSSED INSIDE A NESTED ACTIVATION IS STILL FATAL.

    `callfunc` is a library function that re-enters the interpreter, so when the
    body it runs crosses a ceiling, the peLimit travels back to opCall looking
    exactly like a library that returned an error -- and opCall's ON ERROR path
    would have caught it. That was closed by refusing every peLimit at that
    branch, on a grep that found no library producing one.

    One patch later the budget lane gave the libraries their own refusals
    (`string$: that would take 2147483647 units of work`), which are catchable BY
    DESIGN: nothing has been spent and a program that catches one and asks for
    less is behaving correctly. So the code alone can no longer tell the two
    apart, and the VM now discriminates on where the peLimit came from.

    This pins the half that has no other test. Its twin -- a library refusal
    stays catchable -- is pinned by probe_budget's "catching a refusal builds
    nothing" and "a refused write does not poison the next file_copy", which are
    the two that went red when the two patches were first integrated.

    IT IS THE FRAME CEILING AND NOT THE STEP BUDGET ON PURPOSE, and it runs with
    every ceiling at 0 for that reason. FSteps is shared with the outer loop, so
    a step budget crossed inside a callback RE-FIRES one instruction later and
    would be fatal with this rule or without it -- a pin on it passes either way
    and measures nothing. FFrameSP is restored by CallUserFunc, so the frame
    ceiling is the one that genuinely escapes. Measured both ways before this was
    written: with the rule, rc=5 code=7 "call depth limit exceeded (262144
    activation frames)"; with the rule forced False, rc=0 and the program printed
    its continuation line. }
  LimitInsideCallfunc =
    'on error goto h' + LF +
    'function rec(n)' + LF +
    '  return rec(n + 1)' + LF +
    'end function' + LF +
    'y = callfunc("rec", 1)' + LF +
    'println "the handler resumed and the program continued"' + LF +
    'end' + LF +
    'h:' + LF +
    'resume next' + LF;

{ ----------------------------------------------------------------------------
  A FAULT IN THE INTERPRETER IS NOT AN ERROR IN THE PROGRAM.

  Every other check in this file is about a ceiling the SCRIPT crossed. These are
  about something that happened TO the interpreter -- an access violation, a
  stack overflow, a corrupt heap -- and the engine now answers three separate
  questions about one:

    is it offered to ON ERROR?              never, whatever else is true
    does it end the run?                    always
    does it end the PROCESS?                only if ContainFaults is False

  The first is the one worth arguing about, and the argument is in peFatal: a
  wild write has already landed by the time the exception fires, so a script that
  catches it and carries on answers wrongly instead of dying, and a wrong answer
  nobody is told about is worse than a crash. So ON ERROR is not offered it even
  though the engine is perfectly able to offer it.

  The faults here are RAISED ON PURPOSE by a test-only library function and a
  test-only output callback -- one inside opCall's net, one outside it, because
  those are two different code paths and only the second one needs ContainFaults.
  Neither lives in the shipped engine.
---------------------------------------------------------------------------- }

function t_boom(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  Result := ValInt(0);
  E := NoError();
  raise EAccessViolation.Create('a deliberate fault from a library function');
end;

function t_convert(const A: array of TValue; out E: TPhosphorError): TValue;
begin
  Result := ValInt(0);
  E := NoError();
  { THE MIRROR. A value error from a library must stay catchable -- this is the
    direction a guard written in a hurry breaks, and it has broken twice in this
    project already. }
  raise EConvertError.Create('an ordinary bad argument');
end;

var
  BoomOnOutput: Boolean = False;

type
  { A CLASS because OnOutput is a method pointer (`of object`) and a free
    procedure cannot be assigned to one -- the same trap phosphorguitest hit with
    Application.OnException, and it costs a compile error rather than anything
    silent. }
  TFaultingOutput = class
    class procedure Emit(const S: String);
  end;

class procedure TFaultingOutput.Emit(const S: String);
begin
  { Raised from a HOST CALLBACK, which the dispatch loop calls outside opCall's
    try/except -- so this one leaves ExecFrom as a Pascal exception and is the
    case ContainFaults exists for. }
  if BoomOnOutput then
    raise EAccessViolation.Create('a deliberate fault from a host callback');
end;

{ Run ASource with the fault library registered; report what came back. }
{ A REFUSAL THAT LEAKS IS A WORSE BUG THAN WHAT IT REFUSES, and no .bas
  assertion can see one.

  The JSON graft gates (PhosphorJsonLib, SetMember and AddItem) free the node they
  refuse, because the caller has already CLONED it by the time the gate is asked --
  `AddItem(a, level, v.Clone, Err)`. Deleting those two Free calls leaves every
  assertion in tests/suite/27_json.bas green and every runner on both operating
  systems at exit 0, while the process climbs to 4.2 GB against the 13.9 MB it
  holds to now. Measured, by the review that asked for this check.

  So the question is asked the only way it can be: run the SAME work twice with
  different refusal counts and watch the heap high-water. A gate that frees is flat
  in the count; one that leaks is linear in it. The bound is deliberately loose --
  the leak is two orders of magnitude past it, and a tight bound here would be a
  probe that fails on a busy machine. }
procedure CheckRefusedGraftDoesNotLeak;
const
  { Build to the ceiling, then offer a 601-node subtree over and over. Every offer
    is cloned, refused, and must be freed. }
  Sc =
    'root@ = json_array@()' + LF +
    'cur@ = root@' + LF +
    'for i% = 1 to 255' + LF +
    '  n@ = json_array@()' + LF +
    '  x@ = json_push@(cur@, n@)' + LF +
    '  cur@ = json_item@(cur@, 1)' + LF +
    'next' + LF +
    'sub@ = json_array@()' + LF +
    'for i% = 1 to 600' + LF +
    '  x@ = json_pushn@(sub@, i%)' + LF +
    'next' + LF +
    'refused = 0' + LF +
    'seen = 0' + LF +
    'on error goto oops' + LF +
    'for r% = 1 to REPS' + LF +
    '  x@ = json_push@(cur@, sub@)' + LF +
    { NOT THE LAST STATEMENT IN THE BODY, and that is load-bearing. `resume next`
      on the last statement of a block leaves the BLOCK -- gauntlet finding 7,
      still open as this is written -- so with the push last the loop ran ONE pass
      and this check measured 200 refusals against 1 instead of 200 against 10,000.
      It went green with both Free calls deleted, twice, before the count was
      printed and the script was found to be the thing that was wrong. }
    '  seen = seen + 1' + LF +
    'next' + LF +
    'goto done' + LF +
    'oops:' + LF +
    'refused = refused + 1' + LF +
    'resume next' + LF +
    'done:' + LF +
    'on error goto 0' + LF;
var
  eng: TPhosphorEngine;
  small, big: PtrUInt;
  rc: Integer;

  function RunWith(AReps: Integer): PtrUInt;
  var
    src: String;
  begin
    src := StringReplace(Sc, 'REPS', IntToStr(AReps), [rfReplaceAll]);
    eng := TPhosphorEngine.Create();
    try
      rc := eng.Run(src);
      Report(rc = 0, 'the refusal run at ' + IntToStr(AReps) + ' completed');
    finally
      eng.Free();
    end;
    { CurrHeapUsed, sampled AFTER the engine is freed -- so what is still held is
      what nobody owns. MaxHeapUsed was the first spelling and it does not answer
      this: it is a high-water over the whole process, and the tree the script
      builds legitimately dwarfs the difference the leak makes at these counts.
      The check went green with both Free calls deleted, which is how it was
      caught before it shipped. }
    Result := GetFPCHeapStatus().CurrHeapUsed;
  end;

begin
  small := RunWith(200);
  big := RunWith(10000);
  { 9,800 more refusals of a 601-node subtree, and every one of them freed. What
    is still allocated once the engine is gone must not scale with the count. }
  Report(big < small + (16 * 1024 * 1024),
         'a refused graft frees what it refused (still held after the engine went: ' +
         IntToStr(big div 1024) + ' KB against ' + IntToStr(small div 1024) +
         ' KB, over 9,800 more refusals)');
end;

procedure CheckFault(const AName, ASource: String; AContain, AFaultOnOutput: Boolean;
  AWantCode: TPhosphorErrorCode; AWantRc0: Boolean);
var
  eng: TPhosphorEngine;
  rc: Integer;
  raised: Boolean;
begin
  eng := TPhosphorEngine.Create();
  raised := False;
  try
    eng.ContainFaults := AContain;
    eng.Registry.Add('boom:', @t_boom);
    eng.Registry.Add('badarg:', @t_convert);
    BoomOnOutput := AFaultOnOutput;
    if AFaultOnOutput then eng.OnOutput := @TFaultingOutput.Emit;
    try
      rc := eng.Run(ASource);
    except
      on E: Exception do begin raised := True; rc := -1; end;
    end;
    BoomOnOutput := False;
    if AWantRc0 then
      Report((not raised) and (rc = 0), AName)
    else
      Report((not raised) and (rc <> 0) and (eng.LastError.Code = AWantCode),
             AName);
  finally
    eng.Free;
  end;
end;

{ The same, but asserting that the exception DOES escape -- the default. }
procedure CheckFaultEscapes(const AName, ASource: String);
var
  eng: TPhosphorEngine;
  escaped: Boolean;
begin
  eng := TPhosphorEngine.Create();
  escaped := False;
  try
    eng.ContainFaults := False;
    BoomOnOutput := True;
    eng.OnOutput := @TFaultingOutput.Emit;
    try
      eng.Run(ASource);
    except
      on E: EAccessViolation do escaped := True;
    end;
    BoomOnOutput := False;
    Report(escaped, AName);
  finally
    eng.Free;
  end;
end;

begin
  ProveFail := (ParamCount >= 1) and (ParamStr(1) = '--fail');

  // Step budget bounds an infinite loop.
  Check('step budget', ForeverLoop, 200000, 0, 0, not ProveFail);

  // Output ceiling bounds infinite output.
  Check('output ceiling', ForeverPrint, 0, 50, 0, True);

  // Wall-clock ceiling bounds a loop that produces neither steps-cap nor output.
  Check('time ceiling', ForeverLoop, 0, 0, 50, True);

  // A normal script within generous ceilings runs clean.
  Check('within ceilings runs', 'a = 2 + 3' + LF + 'b = a * a' + LF,
        1000000, 1000, 5000, False);

  // A ceiling is fatal: ON ERROR cannot catch it and loop forever.
  Check('ON ERROR cannot escape a limit', CatchAndLoop, 200000, 0, 0, True);

  // ...including one crossed inside a callback that re-entered the interpreter,
  // which reaches opCall as an ordinary library error. See LimitInsideCallfunc.
  Check('ON ERROR cannot escape a limit crossed inside callfunc',
        LimitInsideCallfunc, 0, 0, 0, True);

  { --- a fault in the interpreter; see the section above --------------------- }

  // Inside opCall's net. The net catches it either way -- what changed is that it
  // is no longer offered to ON ERROR, and no longer wears peRuntime.
  CheckFault('a library fault is peFatal, not a catchable peRuntime',
             'x = boom()' + LF, False, False, peFatal, False);
  CheckFault('...and ON ERROR is not offered it',
             'on error goto h' + LF + 'x = boom()' + LF +
             'println "resumed"' + LF + 'end' + LF + 'h:' + LF +
             'resume next' + LF, False, False, peFatal, False);

  // THE MIRROR, and the direction this project has broken twice: an ordinary
  // value error from the same seam must still be catchable and still peRuntime.
  CheckFault('a library VALUE error is still catchable by ON ERROR',
             'on error goto h' + LF + 'x = badarg()' + LF +
             'end' + LF + 'h:' + LF + 'resume next' + LF,
             False, False, peNone, True);
  CheckFault('...and uncaught it is still an ordinary peRuntime',
             'x = badarg()' + LF, False, False, peRuntime, False);

  // Outside the net: a host callback. Contained, this is a failed Run and
  // nothing reaches the host.
  CheckFault('a host-callback fault is contained when asked',
             'println "hello"' + LF, True, True, peFatal, False);

  // And NOT contained by default -- the exception escapes Run exactly as it
  // always did, so a host that wants to fail fast still does.
  CheckFaultEscapes('a host-callback fault still escapes when not asked',
                    'println "hello"' + LF);

  { --- the front end: a bad FIRST character ---------------------------------
    TLexer.Tokenize gives up the moment it meets a character that cannot start a
    token, so when that character is the first one, not a single token was ever
    pushed. TLexer.Cur's fallback -- FTokens[FCount - 1] -- was then FTokens[-1]
    on a nil array, and copying a TToken out of it also copied its StrVal: String
    field, incrementing a refcount through a wild pointer. TPhosphorCompiler.Fail
    asks Cur().Kind on every failure, so EVERY lexical error at offset 1 came
    through it: `phosphor run` on a file starting with '~' died with an access
    violation instead of printing the error the SAME character prints on line 2,
    `phosphor compile` exited 0 having written nothing, and a UTF-8 BOM -- which
    every Windows editor writes -- killed the REPL on the first line of a piped
    session. }
  CheckRejected('bad first character', '~' + LF, 'unexpected character');
  CheckRejected('lone NUL byte', #0, 'unexpected character');
  CheckRejected('UTF-8 BOM before good source',
                #$EF#$BB#$BF + 'println 1 + 1' + LF, 'unexpected character');
  CheckRejected('the same character on line 2 still reports',
                'print 1' + LF + '~' + LF, 'unexpected character');

  { A lexical failure is never "the input has not finished yet". The flag is what
    tells the REPL to wait for a continuation line, and with no tokens at all the
    synthesised EOF would have read as end-of-input -- so the prompt would have
    sat waiting for a line that can never repair a bad character. }
  CheckErrAtEof('a bad first character is not end-of-input', '~' + LF, False);

  { --- the front end: a literal the machine cannot hold ---------------------
    '1' followed by 400 zeros was rejected; `1e999` was ACCEPTED, because FPC's
    TryStrToFloat returns True on it and hands back +Inf. That put a non-finite
    Double in the constant pool, falsifying the invariant FiniteD states in
    PhosphorValue, and the first operation that made a NaN of it (x - x) raised
    EInvalidOp and killed the process past an `on error goto`. }
  CheckRejected('overflowing exponent literal', 'x = 1e999' + LF, 'out of range');
  CheckRejected('overflowing exponent literal in DATA',
                'data 1e999' + LF + 'read x' + LF, 'out of range');
  CheckAccepted('the largest double still compiles',
                'x = 1.7976931348623157e308' + LF);
  CheckAccepted('an underflowing exponent is just zero', 'x = 1e-999' + LF);

  { --- the front end: every path that recurses on nesting -------------------
    The parenthesis guard covered ParseExpr and nothing else, and three other
    paths recurse on input depth without passing through it. Each killed the
    process with a stack overflow -- not an exception, so no handler and no crash
    guard ever saw it, and an embedding host went down with the script. }
  CheckRejected('unary minus chain', 'println ' + Repeated('-', 300) + '1' + LF,
                'expression nests');
  CheckRejected('unary plus chain', 'println ' + Repeated('+', 300) + '1' + LF,
                'expression nests');
  CheckRejected('signed exponent chain (ParseSignedPrimary)',
                'println 2 ^ ' + Repeated('-', 300) + '1' + LF, 'expression nests');
  CheckRejected('not chain', 'println ' + Repeated('not ', 300) + '(1 = 1)' + LF,
                'expression nests');
  CheckRejected('nested blocks',
                Repeated('if 1 = 1 then' + LF, 300) + 'print 7' + LF +
                Repeated('endif' + LF, 300), 'blocks nest');
  CheckRejected('nested blocks, one-line form',
                Repeated('if 1 = 1 then ', 300) + 'print 7' + LF, 'blocks nest');
  CheckRejected('parentheses (the ceiling that already existed)',
                'x = ' + Repeated('(', 300) + '1' + Repeated(')', 300) + LF,
                'expression nests');

  { Ordinary nesting must still compile: a ceiling that rejects real programs is
    a worse bug than the crash it was added to prevent. }
  CheckAccepted('64 nested blocks still compile',
                Repeated('if 1 = 1 then' + LF, 64) + 'print 7' + LF +
                Repeated('endif' + LF, 64));
  CheckAccepted('64 parentheses and a few signs still compile',
                'x = ' + Repeated('(', 64) + '---1' + Repeated(')', 64) + LF);

  { A ceiling that refuses must not pay for refusing; see the note on the check. }
  CheckRefusedGraftDoesNotLeak;

  { THE FOURTH CEILING. The other three bound how LONG a script runs, and the
    budget unit's own header says in terms that none of them bounds memory: RULE 1
    is asked at the opCall seam by a LIBRARY about its own arguments, and `+` is
    not a library call. Three instructions out of a million reached 1.6 GB of
    string and 14.7 GB of peak with rc 0. }

  { The shape the finding names: double a string, one O(n) instruction at a time. }
  CheckMem('memory ceiling: doubling is refused before it allocates',
           's$ = string$(2000000, 97)' + LF +
           'for i% = 1 to 6' + LF + '  s$ = s$ + s$' + LF + 'next' + LF,
           32 * 1024 * 1024, 'memory limit exceeded');

  { UNLIMITED IS STILL UNLIMITED. 0 is the default and must change nothing: a
    ceiling that a host did not ask for would be the failure mode this project
    names first. }
  CheckMem('and the same run is untouched with no ceiling set',
           's$ = string$(2000000, 97)' + LF +
           'for i% = 1 to 6' + LF + '  s$ = s$ + s$' + LF + 'next' + LF,
           0, '');

  { THE BACKSTOP. Memory that grows through a library, one call at a time, with no
    single allocation large enough for the pre-check to look at. A FRESH string per
    turn: adding one `chunk$` a thousand times stores a thousand references to one
    buffer -- AnsiStrings are refcounted -- and the heap barely moves, which is how
    the first version of this check passed while measuring nothing. }
  CheckMem('memory ceiling: growth with no large concatenation is caught too',
           'L@ = strings@()' + LF +
           'for i% = 1 to 4000' + LF +
           '  n = strings_add(L@, string$(65536, 65))' + LF +
           'next' + LF,
           32 * 1024 * 1024, 'memory limit exceeded');

  { THE CEILING IS ABOUT THE SCRIPT, NOT ABOUT THE PROCESS. Same script, same
    ceiling, with the host already holding 64 MB of its own. }
    { The loop is not decoration: the periodic check fires every 4096 steps, so a
      four-line script finishes before one ever looks at the heap. A first draft
      had no loop and could not tell the two spellings apart. }
  CheckMem('a ceiling bounds what the SCRIPT adds, not what the host holds',
           's$ = string$(4000000, 97)' + LF +
           'for i% = 1 to 5000' + LF + '  n = n + 1' + LF + 'next' + LF +
           'if len(s$) <> 4000000 then' + LF + '  x = 1 / 0' + LF + 'end if' + LF,
           32 * 1024 * 1024, '', 64 * 1024 * 1024);

  { AND ORDINARY WORK UNDER THE CEILING IS UNTOUCHED. }
  CheckMem('ordinary string building under the ceiling is not refused',
           's$ = ""' + LF +
           'for i% = 1 to 20000' + LF + '  s$ = s$ + "x"' + LF + 'next' + LF +
           'if len(s$) <> 20000 then' + LF + '  x = 1 / 0' + LF + 'end if' + LF,
           32 * 1024 * 1024, '');

  { FATAL, like the other three: a script cannot catch its way out of its own
    ceiling. The handler below would swallow an ordinary error. }
  CheckMem('ON ERROR cannot escape the memory ceiling',
           'on error goto oops' + LF +
           's$ = string$(2000000, 97)' + LF +
           'for i% = 1 to 6' + LF + '  s$ = s$ + s$' + LF + '  n = n + 1' + LF +
           'next' + LF +
           'goto fin' + LF + 'oops:' + LF + 'resume next' + LF + 'fin:' + LF,
           32 * 1024 * 1024, 'memory limit exceeded');

  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed > 0 then Halt(1) else Halt(0);
end.
