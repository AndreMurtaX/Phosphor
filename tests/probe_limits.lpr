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
  SysUtils, PhosphorErrors, PhosphorEngine, PhosphorCompiler, PhosphorOpcodes;

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

  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed > 0 then Halt(1) else Halt(0);
end.
