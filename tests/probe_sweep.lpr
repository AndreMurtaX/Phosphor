{******************************************************************************
  probe_sweep -- the stepper, over GENERATED program shapes, against an oracle
  derived from the boundary trace and never from the engine's own step rule.

  WHY THIS EXISTS, in one sentence: a sweep that measures the OFF state of a
  feature has not measured the feature.

  The debug seam arrived with four sweeps behind it -- 1326 generated programs,
  129 real ones and 1296 ceiling cells -- and every one of them ran against a
  build with no debugger installed. They measured, very thoroughly, that an
  UNATTACHED engine had not changed. The piece is a debugger. The one defect that
  mattered lived on the axis none of them crossed: what the stepper does over
  program shapes, and specifically that a step out of an `on error call` handler
  set the mode to `continue` and the session never stopped again.

  tests/probe_step.lpr pins that case and a few dozen others by name, from
  fixtures whose expected traces are derived line by line. This file is the other
  half: it does not know what the shapes are going to be, and it judges them
  against a rule stated here rather than read from PhosphorVM.

  AND THE SAME SENTENCE APPLIES ONE LEVEL DOWN, which is why every generated
  program is judged TWICE. The first round of this file ran two hundred programs
  and every one of them went through TPhosphorEngine.Run -- the door with no host
  above it. A GUI and a debug adapter use the other one: Prepare once, then
  CallFunction per click, with the host's own Pascal below the call's outermost
  frame. That is where FExecDepth, the clamp's frame floor and the whole
  re-entrancy story actually live, and two defects were found there by hand
  because nothing generated was looking. Every program that HAS functions is now
  also debugged through one host call of `f1`, with the same oracle and the
  clamp's floor taken from the door rather than assumed.

  HOW ONE PROGRAM IS JUDGED.

    DETACHED    no seam installed and nothing armed -- the engine an ordinary
                embedder ships, and the leg this file ran without for three
                rounds. docs/proof-axes.md section 5 states the invariant the
                whole piece is judged on: detached, attached-and-continuing and
                attached-and-stepping must be byte-identical on EXIT CODE,
                STDOUT, ERROR LINE and ERROR MESSAGE. The second and third were
                here from the first round; this is the first.

                It is not a duplicate of REFERENCE. There FDbgArmed is True and
                the seam answers `continue`; here the hook in the opStmt arm is
                never taken at all. A defect whose cause is the PRESENCE of a
                debugger rather than its ANSWERS is identical in both attached
                modes and invisible to every comparison between them.

    REFERENCE   arm every line 1..MaxArm and answer daRun. The armed set is
                consulted BEFORE the step mode, so this stops at every statement
                boundary whatever the stepper thinks, and records the triple
                (line, frame depth, gosub depth) at each. That list, with the
                program's stdout and exit code, is the reference.

                AN EMPTY REFERENCE IS A FAILURE, not "nothing to check". Delete
                the hook and every program yields an empty reference, every
                comparison is skipped, and a sweep that treated that as vacuous
                would print `failures: 0` for an engine with no debugger in it at
                all. Measured on the CURRENT corpus, which is the only way this
                sentence can be written honestly -- it has been stale twice: with
                the hook removed this file reports 498 failures, not 0 -- one for
                each of the 498 programs that reach this check, the other 14
                being the host-door shapes whose top level does not survive
                Prepare and which leave by the branch above it. The floor on
                `with an error` at the end of the run is the same idea for the
                other two fields of the verdict: with no reference there is
                nothing to count, and it goes to 0.

    INTO        stop at entry, arm nothing, answer daStepInto for ever. The trace
                must equal the reference boundary for boundary. The corpus is one
                statement per line, which is what makes that true -- two
                boundaries on one line are ONE step, and that case is pinned by
                name in probe_step rather than here.

    OVER k      step into as far as boundary k, answer daStepOver there, then
                daRun. The pair rule: the next stop is the first LATER boundary
                whose (frame, gosub) pair is <= the pair at k. Both halves are
                calls -- an activation frame and a pending GOSUB return address --
                and lexicographic order on the pair is "how deep am I".

    OUT k       the same with daStepOut, and STRICTLY less. Except at the door's
                own floor -- frame <= floor with no pending GOSUB -- where the
                step-out clamp turns the request into `continue`, because this
                activation has no shallower boundary to reach. The floor is 0
                through Run and the call's own frame through a host call. Stating
                that exception HERE, from the definition, rather than reading it
                from the engine, is what makes this an oracle.

    READ        arm every line and read every global and every local of every
                live frame at every stop. stdout and rc must come out
                byte-identical to the reference: reading a stopped frame executes
                nothing, and this is the measurement that says so rather than the
                sentence.

    WINDOW      host door only, and the axis the first two rounds of this file
                still did not cross: what the host DOES while the program is
                stopped. The seam reads the library budget's clock, parks 100 ms,
                evaluates one of the program's own functions through
                CallFunction, and reads the clock again -- with TimeoutMs,
                MaxOutputBytes and MaxMemoryBytes all installed, which the other
                four modes leave off entirely.

                Judged two ways. The drop across the window must be the
                EVALUATION's cost and not the person's, measured directly rather
                than waiting for a refusal: these programs are a few hundred
                instructions long, so neither ceiling's throttled check is
                necessarily reached, and a mode that only looked for a refusal
                would pass on an engine with no correction in it. And the whole
                pass is run a second time WITHOUT the park, with everything
                required identical -- output, exit code, the function's value,
                the engine's message, the trace. That differential has no formula
                in it and therefore cannot record the engine's own behaviour as
                correct.

                Measured able to reject: against the build whose correction is
                applied only when the seam RETURNS, all 118 host-door programs
                that have a session to call into fail, each naming the
                milliseconds the park took off the script.

  THE ONE PLACE THE PAIR RULE IS NOT EXACT, and it is documented behaviour rather
  than slack: a fault dispatch and a `resume` move the frame pointer wholesale,
  and DebugRebase promotes a pending step to dmStepInto there on purpose, so the
  user sees where the handler took them. On a program that faults, a step may
  therefore land EARLIER than the pair rule says. It may never land LATER, and it
  may never land NOWHERE, and those two are asserted on every program. The clamp
  keeps its exact assertion everywhere, because dmRun is the one mode the rebase
  does not promote.

  Prints "ok: N" / "fail: M" and exits non-zero on any failure. Run with --fail
  to corrupt one expectation and confirm the check can fail.
******************************************************************************}
program probe_sweep;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  SysUtils, Classes,
  PhosphorValue, PhosphorOpcodes, PhosphorBudget, PhosphorEngine, PhosphorVM;

const
  MaxArm = 400;
  { HOW LONG A PERSON LOOKS AT A STOP, in the window mode. Sized from the tick
    the two clocks are read with: GetTickCount64 is about 15.6 ms on Windows and
    a few ms on Linux, so 100 ms is six coarse ticks and cannot be mistaken for
    jitter in either direction. It is also the whole cost this mode adds -- one
    park per host-door program, and the control pass does not sleep at all. }
  WindowParkMs = 100;

type
  TTriple = record
    Line, Frame, Gosub: Integer;
  end;
  TTriples = array of TTriple;

  TMode = (mDetach, mRef, mInto, mStepAt, mRead, mWindow);

  TRun = class
    Eng: TPhosphorEngine;
    Mode: TMode;
    StepAt: Integer;                  // 1-based boundary to answer Step* at
    StepAction: TPhosphorDebugAction;
    Seen: TTriples;
    Text: String;
    Reads: Int64;
    { mWindow: what the host does INSIDE the stop. The park is real wall clock
      and the evaluation is a real re-entry, which together are the cell a debug
      adapter spends its whole life in and the one no generated corpus in this
      piece crossed until now. }
    ParkMs: Integer;
    WindowCall: String;
    WindowArg: Int64;
    Parked: Boolean;
    EvalText: String;
    BudgetDrop: Int64;                // ms the budget clock lost across the window
    function Debug(AReason: TPhosphorStopReason; ALine, AFrameDepth: Integer):
             TPhosphorDebugAction;
    procedure Output(const AText: String);
  end;

var
  Ok: Int64 = 0;
  Failed: Integer = 0;
  Programs: Integer = 0;
  ProveFail: Boolean = False;
  { Set per program from the SOURCE, not from the run: a fault is the only thing
    that puts a wholesale frame move in one of these programs, and therefore the
    only thing that lets a step land earlier than the pair rule. }
  Faults: Boolean;
  { WHETHER THE GENERATOR BUILT THIS PROGRAM TO DIE. Set from the indices that
    made it -- a fault site with no handler over it -- and never from the run, so
    the assertion it feeds compares two independent answers to the same question:
    what the corpus intended, and what the engine reported.

    It is what makes the error LINE and the error MESSAGE live fields rather than
    two empty strings compared against two empty strings. For three rounds every
    generated program ended cleanly, by a `Continue` in SweepAll that skipped the
    uncaught combinations, so half of the four-field verdict this file now claims
    to compare could not have differed however broken the engine was. }
  Uncaught: Boolean;
  { WHAT THE ENGINE SAID ABOUT THE LAST EXECUTION, beside the text that carries
    it: the error message of the door that ran, so the check above can be made
    without parsing the verdict back apart. }
  ExErrMsg: String;
  WithError: Integer = 0;
  { Host-door programs whose top level did not survive Prepare, so the door had
    no session to offer. Printed, because a number that grew without anyone
    noticing would mean the corpus had quietly stopped debugging that door. }
  DoorSkipped: Integer = 0;
  Src: String;
  SrcName: String;
  RefT: TTriples;
  RefText: String;
  RefRc: Integer;
  { WHICH DOOR THIS PROGRAM IS BEING DEBUGGED THROUGH. '' is TPhosphorEngine.Run,
    the top-level door; anything else is the name of a function a HOST calls
    after Prepare, which is the door a GUI and a debug adapter actually use and
    the one this file crossed for nobody in its first round.

    DoorFloor is that door's clamp floor -- ExecFrom's AStopFrameSP + 1, the
    shallowest frame this activation can reach. It is -1 + 1 = 0 for Run and
    (the frame depth at rest) + 1 for a host call, and it is MEASURED from the
    VM before the call rather than assumed, because a program whose top level
    abandoned an activation is at rest somewhere else. }
  DoorCall: String;
  DoorArg: Int64;
  DoorFloor: Integer;
  { THE WINDOW MODE'S ONE KNOB AND ITS TWO ANSWERS. WindowPark is the wall clock
    a person spends looking at the stop; WinEval and WinDrop come back out of
    Execute because the mode's verdict is about what happened INSIDE the seam and
    the three out-parameters describe what happened around it. }
  WindowPark: Integer;
  WinEval: String;
  WinDrop: Int64;

procedure Pass;
begin
  Inc(Ok);
end;

procedure Fail(const AWhat: String);
begin
  Inc(Failed);
  Writeln(StdErr, 'FAIL ', SrcName, ': ', AWhat);
end;

procedure Output(const AText: String); forward;

procedure TRun.Output(const AText: String);
begin
  Text := Text + AText;
end;

function TRun.Debug(AReason: TPhosphorStopReason; ALine, AFrameDepth: Integer):
  TPhosphorDebugAction;
var
  n, fr, sl: Integer;
  vm: TPhosphorVM;
  v: TValue;
begin
  if AReason = srPause then ;         // never asked for here
  vm := Eng.DebugVM;
  { THE WINDOW, AT THE FIRST STOP AND ONLY THERE. Read the budget clock, park,
    evaluate one of the program's own functions, read the clock again. The drop
    across it is what the correction is FOR, measured directly rather than
    inferred from whether something was refused -- these programs are a few
    hundred instructions long, so the VM's throttled clock check and RULE 1's
    throttled one may never be reached at all, and a mode that waited for a
    refusal would pass on an engine with no correction in it. Said plainly
    because that is the shape of every vacuous test this project has found. }
  if (Mode = mWindow) and (not Parked) then
  begin
    Parked := True;
    BudgetDrop := BudgetRemainingMs;
    if ParkMs > 0 then Sleep(ParkMs);
    if (WindowCall <> '') and (Eng.PreparedVM <> nil) then
    begin
      v := Eng.CallFunction(WindowCall, [ValInt(WindowArg)]);
      EvalText := ValToStr(v) + '|' + Eng.ErrorMessage;
    end;
    BudgetDrop := BudgetDrop - BudgetRemainingMs;
  end;
  n := Length(Seen);
  SetLength(Seen, n + 1);
  Seen[n].Line := ALine;
  Seen[n].Frame := AFrameDepth;
  if vm <> nil then Seen[n].Gosub := vm.DbgGosubDepth else Seen[n].Gosub := -1;

  if (Mode = mRead) and (vm <> nil) then
  begin
    for fr := 0 to vm.DbgGlobalCount - 1 do
    begin
      v := vm.DbgGlobal(fr);
      Inc(Reads, Length(ValToStr(v)));
    end;
    for fr := 0 to vm.DbgFrameDepth - 1 do
      for sl := 0 to vm.DbgFrameLocalCount(fr) - 1 do
      begin
        v := vm.DbgLocal(fr, sl);
        Inc(Reads, Length(ValToStr(v)));
      end;
  end;

  case Mode of
    mInto: Result := daStepInto;
    mStepAt:
      if n + 1 < StepAt then Result := daStepInto
      else if n + 1 = StepAt then Result := StepAction
      else Result := daRun;
  else
    Result := daRun;                  // mRef, mRead and mWindow
  end;
end;

procedure Output(const AText: String);
begin
  if AText = '' then Inc(Ok, 0);
end;

function ShowTriples(const T: TTriples; AFrom, ACount: Integer): String;
var i: Integer;
begin
  Result := '';
  for i := AFrom to AFrom + ACount - 1 do
  begin
    if (i < 0) or (i > High(T)) then Break;
    if Result <> '' then Result := Result + ' ';
    Result := Result + IntToStr(T[i].Line) + '@' + IntToStr(T[i].Frame) +
              '/' + IntToStr(T[i].Gosub);
  end;
end;

{ -1 / 0 / +1: the pair compared lexicographically. THE ORACLE'S OWN COPY of the
  question, written here from the definition of a call -- an activation frame is
  one and a pending GOSUB return address is one -- and deliberately not shared
  with the engine's DebugRelDepth. Two implementations of one rule is the point:
  a sweep that called the engine's version could not fail. }
function Rel(const A, B: TTriple): Integer;
begin
  if A.Frame <> B.Frame then
  begin
    if A.Frame < B.Frame then Result := -1 else Result := 1;
  end
  else if A.Gosub <> B.Gosub then
  begin
    if A.Gosub < B.Gosub then Result := -1 else Result := 1;
  end
  else
    Result := 0;
end;

procedure Execute(AMode: TMode; AStepAt: Integer; AAction: TPhosphorDebugAction;
                  out ATriples: TTriples; out AText: String; out ARc: Integer);
var
  eng: TPhosphorEngine;
  r: TRun;
  lines: array of Integer;
  v: TValue;

  { A for counter may not be a variable from the enclosing scope, so this one is
    the nested routine's own. }
  procedure Arm;
  var
    a: Integer;
  begin
    { THE DETACHED LEG ARMS NOTHING, because it has nothing to arm with: no seam
      was installed, and an armed VM with a nil seam is a different configuration
      again (DebugPoll answers `continue` to nobody). What this leg has to be is
      the engine an ordinary embedder ships -- FDbgArmed False, FOnDebug nil --
      or it is not the control. }
    if AMode = mDetach then Exit;
    if AMode in [mRef, mRead] then
    begin
      SetLength(lines, MaxArm);
      for a := 0 to MaxArm - 1 do lines[a] := a + 1;
      eng.ArmDebug(lines, False);
    end
    else
      eng.ArmDebug([], True);          // stop at entry, nothing armed
  end;

begin
  eng := TPhosphorEngine.Create();
  r := TRun.Create();
  try
    r.Eng := eng;
    r.Mode := AMode;
    r.StepAt := AStepAt;
    r.StepAction := AAction;
    eng.OnOutput := @r.Output;
    if AMode <> mDetach then eng.OnDebug := @r.Debug;
    { THE LEG IS THE CONFIGURATION IT CLAIMS TO BE, asserted rather than assumed.
      A mutation that made Arm() stop excluding mDetach SURVIVED the whole of this
      file before these two lines existed: with the seam nil, DebugPoll leaves at
      its second line, no boundary is ever recorded, and the "was offered no
      boundaries" check below stays green -- so the leg would have gone on
      measuring an ARMED engine with a nil seam, which is a third configuration
      and not the one an embedder ships. The field that decides is FDbgArmed, and
      DebugAttached is the read of it. }
    Pass();
    if Assigned(eng.OnDebug) = (AMode = mDetach) then
      Fail('the detached leg installed a seam, or an attached one did not');
    if AMode = mWindow then
    begin
      r.ParkMs := WindowPark;
      r.WindowCall := DoorCall;
      r.WindowArg := DoorArg;
      { ALL FOUR CEILINGS INSTALLED, which is the half the other four modes
        leave off. They are set wide enough that a correct program cannot reach
        them -- what is being measured is the LEDGER, not a refusal -- and
        narrow enough to be live: a host that sets none cannot be charged by
        anything, so a sweep through one would prove nothing about the
        correction either way.

        MaxSteps is the fourth and it was absent from this list for a round,
        which left one cell of the ceilings-by-host-behaviours grid with nothing
        in it at all. It is the one ceiling a park cannot disturb -- parking
        executes no instruction -- so what it is doing here is the RE-ENTRY half:
        the window evaluates one of the program's own functions, and those
        instructions are the script's. The sharp version of that, where the
        budget is calibrated so that one more body cannot fit, is by name in
        tests/probe_step.lpr; here it is simply installed, so that no generated
        program is ever swept with a ceiling switched off. }
      eng.TimeoutMs := 4000;
      eng.MaxOutputBytes := 4096;
      eng.MaxMemoryBytes := 64 * 1024 * 1024;
      eng.MaxSteps := 100 * 1000 * 1000;
    end;
    if DoorCall = '' then
    begin
      Arm();
      ARc := eng.Run(Src);
      { THE VERDICT, AND ALL FOUR FIELDS OF IT. Output and exit code were compared
        from this file's first round; the ERROR LINE and the ERROR MESSAGE were
        not, and through this door they were not even reachable -- so a debugger
        that moved the line a fault is blamed on, or changed the sentence, would
        have been invisible to every comparison here. They are part of the text
        so that every existing comparison acquires them at once. }
      AText := r.Text + '|' + IntToStr(eng.ErrorLine) + '|' + eng.ErrorMessage;
      ExErrMsg := eng.ErrorMessage;
    end
    else
    begin
      { THE HOST-ENTERED DOOR: Prepare, then arm, then call.

        The order is the point. Prepare runs the top level with the seam
        installed and NOTHING armed, so it offers no boundary and contributes no
        triple -- every triple recorded here belongs to the CALL, which is what
        makes the reference comparable across the five modes. Arming afterwards
        is not a trick: TPhosphorEngine.ArmDebug applies to a live prepared VM on
        purpose, because that VM is the one the host is about to call into.

        The call's own answer and the engine's message join the text, so a mode
        that changes what the function RETURNS -- or turns a clean stop into an
        error -- fails on the comparison the reference already makes, and not
        only on the trace. }
      ARc := eng.Prepare(Src);
      { Prepare's own verdict, taken BEFORE the call, because CallFunction opens
        with ClearErrorState and the two would otherwise be the same two fields
        read twice. }
      AText := r.Text + '|' + IntToStr(eng.ErrorLine) + '|' + eng.ErrorMessage;
      ExErrMsg := eng.ErrorMessage;
      if ARc = 0 then
      begin
        if (AMode = mRef) and (eng.PreparedVM <> nil) then
          DoorFloor := eng.PreparedVM.DbgFrameDepth + 1;
        Arm();
        { AND THE ARMING HALF OF THE SAME QUESTION, which needs a VM to ask and so
          can only be asked at this door -- through Run the VM is a local of the
          engine and there is nothing to read it from. Arm() has ONE guard for the
          detached leg, and it is exercised here on every host-door program, so a
          mutation to it cannot survive even though only one of the two doors can
          witness it. }
        Pass();
        if eng.PreparedVM.DebugAttached = (AMode = mDetach) then
          Fail('the detached leg armed the VM, or an attached one did not');
        r.Text := '';
        v := eng.CallFunction(DoorCall, [ValInt(DoorArg)]);
        AText := AText + '|' + ValToStr(v) + '|' + IntToStr(eng.ErrorLine) +
                 '|' + eng.ErrorMessage + '|' + r.Text;
        ExErrMsg := eng.ErrorMessage;
      end;
    end;
    ATriples := r.Seen;
    WinEval := r.EvalText;
    WinDrop := r.BudgetDrop;
  finally
    eng.Free;
    r.Free;
  end;
end;

{ THE VERDICT ON ONE STEP.

  AWant is the reference index the pair rule points at, or -1 for "there is
  nothing to land on". AClamped says the step-out clamp turned the request into
  `continue`.

    clamped      EXACTLY k stops, on every program, faulting or not: dmRun is the
                 one mode DebugRebase does not promote.
    fault-free   EXACTLY k+1 stops and the landing is EXACTLY AWant.
    faulting     at most k+1 stops, and the landing lies between k and AWant.
                 EARLIER is the rebase doing its documented job; LATER is an
                 overshoot; NOWHERE is the silence this piece exists to prevent. }
procedure Judge(const AWhat: String; AK: Integer; const AGot: TTriples;
                AWant: Integer; AClamped: Boolean);
var
  j, landed: Integer;
begin
  Pass();
  if AClamped then
  begin
    if Length(AGot) <> AK then
      Fail(Format('%s at %d is clamped to continue and must give exactly %d ' +
                  'stops, gave %d [%s]',
                  [AWhat, AK, AK, Length(AGot), ShowTriples(AGot, 0, 14)]));
    Exit;
  end;
  if (AWant >= 0) and (Length(AGot) < AK + 1) then
  begin
    Fail(Format('%s at %d NEVER STOPPED AGAIN -- the oracle says %s is ' +
                'reachable [%s]',
                [AWhat, AK, ShowTriples(RefT, AWant, 1), ShowTriples(AGot, 0, 14)]));
    Exit;
  end;
  if Length(AGot) > AK + 1 then
  begin
    Fail(Format('%s at %d gave %d stops, at most %d are possible [%s]',
                [AWhat, AK, Length(AGot), AK + 1, ShowTriples(AGot, 0, 14)]));
    Exit;
  end;
  if Length(AGot) = AK then Exit;      // nothing to land on, and nothing landed
  landed := -1;
  for j := AK to High(RefT) do
    if (RefT[j].Line = AGot[AK].Line) and (RefT[j].Frame = AGot[AK].Frame) and
       (RefT[j].Gosub = AGot[AK].Gosub) then begin landed := j; Break; end;
  if landed < 0 then
  begin
    Fail(Format('%s at %d landed on %s, which is not a boundary the program reaches',
                [AWhat, AK, ShowTriples(AGot, AK, 1)]));
    Exit;
  end;
  if Faults then
  begin
    if (AWant >= 0) and (landed > AWant) then
      Fail(Format('%s at %d OVERSHOT: landed on %s (reference %d), the pair ' +
                  'rule says %s (%d)',
                  [AWhat, AK, ShowTriples(AGot, AK, 1), landed + 1,
                   ShowTriples(RefT, AWant, 1), AWant + 1]));
  end
  else if landed <> AWant then
    Fail(Format('%s at %d landed on %s (reference %d), the oracle says %s (%d)',
                [AWhat, AK, ShowTriples(AGot, AK, 1), landed + 1,
                 ShowTriples(RefT, AWant, 1), AWant + 1]));
end;

{ ACall = '' debugs ASource through TPhosphorEngine.Run; anything else prepares
  it and then debugs one HOST call of that function, which is a different door
  with a different clamp floor and a different re-entrancy story. }
procedure OneProgram(const AName, ASource, ACall: String; AArg: Int64);
var
  t, detT: TTriples;
  txt, detTxt: String;
  rc, detRc, k, i, j, want: Integer;
  clamped: Boolean;
  winEvalParked, winTraceParked: String;
begin
  SrcName := AName;
  Src := ASource;
  DoorCall := ACall;
  DoorArg := AArg;
  DoorFloor := 0;                      // Run's floor; Execute measures a call's
  Inc(Programs);
  Faults := Pos('1 / 0', Src) > 0;

  Execute(mRef, 0, daRun, RefT, RefText, RefRc);

  { A TOP LEVEL THAT DID NOT SURVIVE Prepare. Through the host door the program's
    own statements run during Prepare, and some shapes end there -- a fault with
    no live handler, or a handler that abandons the call it was raised inside. A
    host cannot call a function of a session that failed to prepare, so this door
    offers no boundary and there is no stepping to judge. That is a property of
    the door, not a silence in the stepper.

    IT IS DECIDED BY WHAT THE RUN REPORTED, not by a prediction about which
    shapes die -- the first version of the error check in this file tried to
    predict that and was wrong about 29 programs. And it cannot hide the thing
    the empty-reference check below is for: deleting the hook leaves Prepare
    answering 0, so those programs come out of this branch and fail there.

    The three legs are still compared, because that comparison is the one that
    CAN be made here and an engine whose debugger changed whether a program
    prepares at all is exactly what it is for. }
  if (ACall <> '') and (RefRc <> 0) then
  begin
    Inc(DoorSkipped);
    Execute(mDetach, 0, daRun, detT, detTxt, detRc);
    Pass();
    if detTxt <> RefText then
      Fail('THE DEBUGGER IS NOT INVISIBLE: a top level that fails to prepare ' +
           'says ' + RefText + ' with one attached and ' + detTxt + ' without');
    Pass();
    if detRc <> RefRc then
      Fail('THE DEBUGGER IS NOT INVISIBLE: a top level that fails to prepare ' +
           'exits differently with one attached');
    Exit;
  end;

  Pass();
  if Length(RefT) = 0 then
  begin
    Fail('the reference trace is EMPTY -- no boundary was offered');
    Exit;
  end;
  { THE TWO NEW FIELDS ARE LIVE, AND THIS IS WHAT SAYS SO. Without something
    here, the error line and the error message would be an empty string compared
    against an empty string on every program, which is a comparison that cannot
    fail -- and for three rounds it would have been, because SweepAll skipped
    every uncaught combination outright.

    ONE DIRECTION ONLY, AND THE SOUND ONE. A fault site with no live handler over
    it must produce an error: that is a property of the two indices that built
    the program and needs nothing read off a run. The converse is NOT asserted,
    and the reason is worth writing down rather than leaving as slack, because
    the first version of this check did assert it and was wrong about 29
    programs. A body with no `end` in it falls off its top level straight into
    the `oops:` tail and executes `resume next` with no fault outstanding, and a
    fault inside a function a HOST called is declined by a top-level handler --
    the fault dispatcher has its own re-entrancy floor. Both are documented
    engine behaviour, both end in an error, and neither is an uncaught fault.
    Predicting the full set would mean re-deriving the engine's fault routing in
    this file, which is the one thing an oracle must not do. The aggregate floor
    at the end of the run is what keeps the fields honest instead. }
  Pass();
  if Uncaught and (ExErrMsg = '') then
    Fail('the generator built this program to die -- a fault site with no live ' +
         'handler over it -- and the engine finished it cleanly');
  if ExErrMsg <> '' then Inc(WithError);

  { --fail corrupts the REFERENCE, never the engine: one boundary's frame depth
    is moved, which makes the pair rule point somewhere the engine will not go. }
  if ProveFail then Inc(RefT[Length(RefT) div 2].Frame, 3);

  { THE THIRD LEG, AND THE ONE THIS FILE RAN WITHOUT FOR THREE ROUNDS.

    docs/proof-axes.md states the invariant the whole piece is judged on: for one
    source, in one cell, DETACHED, ATTACHED-AND-CONTINUING and
    ATTACHED-AND-STEPPING must be byte-identical on exit code, stdout, error line
    and error message. Two of those three were already here -- mRef answers
    `continue` at every boundary and mInto steps through every one of them, and
    every other mode is compared against mRef. The one that was missing is the
    engine an ordinary embedder actually ships: NO SEAM INSTALLED AT ALL.

    Why that is not the same measurement as mRef. FDbgArmed is False and FOnDebug
    is nil here, so the hook in the opStmt arm never calls DebugPoll, no window is
    ever opened, no clock is ever credited and no step state exists to leak. Any
    defect whose cause is the PRESENCE of a debugger rather than its ANSWERS is
    identical in mRef and mInto and can only be seen from here -- and the first
    four sweeps this piece shipped measured the detached engine ALONE, which is
    the mirror image of the same mistake and is written up at the top of this
    file. Measured able to reject: `ErrorLine := ALine` added to the top of
    DebugPoll -- an armed engine blaming a fault on the last boundary it offered
    instead of on the failing statement -- is identical in both attached modes and
    fails 120 programs here.

    The comparison is the whole verdict text, which since this round carries the
    error line and the error message beside the output, plus the exit code. }
  Execute(mDetach, 0, daRun, detT, detTxt, detRc);
  Pass();
  if Length(detT) <> 0 then
    Fail(Format('the DETACHED leg was offered %d boundaries -- it installs no ' +
                'seam and arms nothing, so it must be offered none',
                [Length(detT)]));
  { --fail corrupts this leg's ANSWER, for the same reason and in the same
    direction as the line above: an assertion nobody has watched fail is not
    known to be able to fail, and these three are new. }
  if ProveFail then detTxt := detTxt + '/corrupted';
  Pass();
  if detTxt <> RefText then
    Fail(Format('THE DEBUGGER IS NOT INVISIBLE: with a debugger attached and ' +
                'answering continue this program says %s, and with none ' +
                'attached at all it says %s', [RefText, detTxt]));
  Pass();
  if detRc <> RefRc then
    Fail(Format('THE DEBUGGER IS NOT INVISIBLE: with a debugger attached and ' +
                'answering continue this program exits %d, and with none ' +
                'attached at all it exits %d', [RefRc, detRc]));

  { AND THE THIRD PAIR OF THE THREE-LEG DIFFERENTIAL. This compares
    attached-and-stepping against attached-and-continuing; the block above
    compared attached-and-continuing against detached; so all three agree, on all
    four fields, or one of these five assertions names which pair does not. }
  Execute(mInto, 0, daRun, t, txt, rc);
  Pass();
  if txt <> RefText then Fail('step into changed the output');
  Pass();
  if rc <> RefRc then Fail('step into changed the exit code');
  Pass();
  if Length(t) <> Length(RefT) then
    Fail(Format('step into visited %d boundaries, the reference has %d [%s]',
                [Length(t), Length(RefT), ShowTriples(t, 0, 12)]))
  else
    for i := 0 to High(t) do
      if (t[i].Line <> RefT[i].Line) or (t[i].Frame <> RefT[i].Frame) or
         (t[i].Gosub <> RefT[i].Gosub) then
      begin
        Fail(Format('step into differs from the reference at boundary %d: ' +
                    '%s against %s',
                    [i + 1, ShowTriples(t, i, 1), ShowTriples(RefT, i, 1)]));
        Break;
      end;

  Execute(mRead, 0, daRun, t, txt, rc);
  Pass();
  if txt <> RefText then
    Fail('reading every variable at every boundary changed the output');
  Pass();
  if rc <> RefRc then
    Fail('reading every variable at every boundary changed the exit code');

  for k := 1 to Length(RefT) do
  begin
    if k > 12 then Break;

    Execute(mStepAt, k, daStepOver, t, txt, rc);
    Pass();
    if txt <> RefText then Fail(Format('step over at %d changed the output', [k]));
    Pass();
    if rc <> RefRc then Fail(Format('step over at %d changed the exit code', [k]));
    want := -1;
    for j := k to High(RefT) do
      if Rel(RefT[j], RefT[k - 1]) <= 0 then begin want := j; Break; end;
    Judge('step over', k, t, want, False);

    Execute(mStepAt, k, daStepOut, t, txt, rc);
    Pass();
    if txt <> RefText then Fail(Format('step out at %d changed the output', [k]));
    Pass();
    if rc <> RefRc then Fail(Format('step out at %d changed the exit code', [k]));
    { THE CLAMP, STATED FROM THE DOOR AND NOT FROM THE ENGINE. A step out is
      turned into `continue` exactly where this activation has no shallower
      boundary to reach: at or below the door's own frame floor, with no pending
      GOSUB return address to come back to. Through Run the floor is 0 -- the top
      level of a program has nothing to step out to. Through a HOST call it is 1
      (or whatever the VM was at rest, plus the frame the call pushes), because
      the frame below the call belongs to the host's Pascal and not to more
      BASIC. Same sentence, one number. }
    clamped := (RefT[k - 1].Frame <= DoorFloor) and (RefT[k - 1].Gosub = 0);
    want := -1;
    if not clamped then
      for j := k to High(RefT) do
        if Rel(RefT[j], RefT[k - 1]) < 0 then begin want := j; Break; end;
    Judge('step out', k, t, want, clamped);
  end;

  { THE WINDOW. Only through the host door, because TPhosphorEngine.CallFunction
    needs a PREPARED session and the Run door has none -- so a seam stopped
    through Run has nothing to call back into, and the re-entrancy cell only
    exists on this side.

    THE ORACLE IS A DIFFERENTIAL WITH NO FORMULA IN IT: the same program, the
    same host, the same three ceilings, the same evaluation from inside the same
    stop -- and the ONLY difference between the two passes is whether a person
    paused first. Everything must come out identical: the program's output, its
    exit code, the function's return value, the engine's message about it, and
    the trace. A rule stated as an equality between two runs cannot record the
    engine's own behaviour as correct, which is what a formula copied from
    PhosphorVM would do.

    AND THE LEDGER ITSELF, measured rather than inferred. These programs are a
    few hundred instructions long, so neither throttled ceiling check is
    necessarily reached and a mode that waited for a refusal could pass on an
    engine with no correction at all. The budget's clock is read inside the seam
    either side of the park, and the drop across it must be the EVALUATION's cost
    and not the person's: bounded at half the park, which on the unfixed engine
    is the whole park and fails on every program that has a function. }
  if (ACall <> '') and (WindowPark > 0) then
  begin
    Execute(mWindow, 0, daRun, t, txt, rc);
    Pass();
    if WinDrop > WindowPark div 2 then
      Fail(Format('the window''s %d ms park cost the script %d ms of its budget ' +
                  '-- a person reading a stop is not the script''s time',
                  [WindowPark, WinDrop]));
    Pass();
    if txt <> RefText then
      Fail(Format('parking and evaluating inside the stop changed the output: ' +
                  '%s against the reference %s', [txt, RefText]));
    Pass();
    if rc <> RefRc then
      Fail(Format('parking and evaluating inside the stop changed the exit code ' +
                  '(%d against %d)', [rc, RefRc]));
    winEvalParked := WinEval;
    winTraceParked := ShowTriples(t, 0, 4);

    { THE CONTROL: the identical pass with nobody in front of it. }
    WindowPark := 0;
    try
      Execute(mWindow, 0, daRun, t, txt, rc);
    finally
      WindowPark := WindowParkMs;
    end;
    Pass();
    if WinEval <> winEvalParked then
      Fail(Format('the watch expression answered %s after a pause and %s ' +
                  'without one', [winEvalParked, WinEval]));
    Pass();
    if ShowTriples(t, 0, 4) <> winTraceParked then
      Fail('the pause changed which boundaries the session was offered');
    Pass();
    if txt <> RefText then Fail('the unparked window changed the output');
    Pass();
    if rc <> RefRc then Fail('the unparked window changed the exit code');
  end;
end;

{ ------------------------------------------------------------------------- }

{ THE CORPUS, built here rather than read from a directory so that the sweep is
  one binary with no data beside it and runs identically on both operating
  systems. ONE STATEMENT PER LINE throughout -- see the header.

  Every body is the top level; every tail is the functions that follow it. The
  cross product is body x error-handler x fault-site x ending. }
const
  NL = #10;

  { `innerfault` is the sixteenth and it is the one A1's rewritten fault path
    lives in: `f1` installs a handler of its OWN and then faults, so the jump to
    that handler leaves f1's activation open with nothing that can return to it.
    The engine diagnoses it by name (tests/negative/33 to 42), and the machinery
    that decides -- a monotone fault sequence, an abandonment record settled by
    WHICH fault, and a RANGE of fabricated frame slots -- was rewritten on
    2026-09-11 and had never been stepped through by anything. Through the host
    door it is also the only body whose top level does not survive Prepare. }
  BodyCount = 16;
  BodyName: array[0..BodyCount - 1] of String = (
    'plain', 'for1', 'for2', 'fornest', 'while', 'ifelse', 'select',
    'gosub', 'gosub2', 'gosubloop', 'call', 'callloop', 'call2deep',
    'recurse', 'callfunc', 'innerfault');
  BodyTop: array[0..BodyCount - 1] of String = (
    'a = 1' + NL + 'a = a + 2' + NL + 'println str$(a)' + NL,
    's = 0' + NL + 'for i = 1 to 3' + NL + 's = s + i' + NL + 'next' + NL +
      'println str$(s)' + NL,
    's = 0' + NL + 'for i = 1 to 2' + NL + 's = s + i' + NL + 's = s + 1' + NL +
      'next' + NL + 'println str$(s)' + NL,
    's = 0' + NL + 'for i = 1 to 2' + NL + 'for j = 1 to 2' + NL + 's = s + 1' +
      NL + 'next' + NL + 'next' + NL + 'println str$(s)' + NL,
    'k = 0' + NL + 'while k < 3' + NL + 'k = k + 1' + NL + 'endwhile' + NL +
      'println str$(k)' + NL,
    'a = 1' + NL + 'if a > 0 then' + NL + 'a = 10' + NL + 'else' + NL +
      'a = 20' + NL + 'endif' + NL + 'println str$(a)' + NL,
    'a = 2' + NL + 'select case a' + NL + 'case 1' + NL + 'a = 11' + NL +
      'case 2' + NL + 'a = 22' + NL + 'endselect' + NL + 'println str$(a)' + NL,
    'a = 1' + NL + 'gosub subr' + NL + 'a = a + 1' + NL + 'println str$(a)' + NL +
      'end' + NL + 'subr:' + NL + 'a = a + 10' + NL + 'a = a + 100' + NL +
      'return' + NL,
    'a = 1' + NL + 'gosub subr' + NL + 'gosub subr' + NL + 'println str$(a)' + NL +
      'end' + NL + 'subr:' + NL + 'a = a + 10' + NL + 'return' + NL,
    'a = 0' + NL + 'for i = 1 to 2' + NL + 'gosub subr' + NL + 'next' + NL +
      'println str$(a)' + NL + 'end' + NL + 'subr:' + NL + 'a = a + 5' + NL +
      'return' + NL,
    'a = f1(3)' + NL + 'println str$(a)' + NL + 'end' + NL,
    's = 0' + NL + 'for i = 1 to 2' + NL + 's = s + f1(i)' + NL + 'next' + NL +
      'println str$(s)' + NL + 'end' + NL,
    'a = f1(3)' + NL + 'println str$(a)' + NL + 'end' + NL,
    'a = f1(3)' + NL + 'println str$(a)' + NL + 'end' + NL,
    'a = callfunc("f1", 3)' + NL + 'println str$(a)' + NL + 'end' + NL,
    'a = f1(3)' + NL + 'println str$(a)' + NL + 'end' + NL + 'inner:' + NL +
      'caught = 1' + NL);
  { The functions each body needs, '' for the ones that need none. A fault asked
    for "inside a function" is inserted after the first statement of the first
    one, so a body with no functions has no such variant. }
  BodyFns: array[0..BodyCount - 1] of String = (
    '', '', '', '', '', '', '', '', '', '',
    'function f1(n) local t' + NL + 't = n + 1' + NL + 'return t' + NL +
      'endfunction' + NL,
    'function f1(n) local t' + NL + 't = n + 1' + NL + 'return t' + NL +
      'endfunction' + NL,
    'function f1(n) local t' + NL + 't = f2(n)' + NL + 'return t' + NL +
      'endfunction' + NL + 'function f2(n) local u' + NL + 'u = n + 1' + NL +
      'return u' + NL + 'endfunction' + NL,
    'function f1(n) local t' + NL + 'if n <= 0 then' + NL + 'return 0' + NL +
      'endif' + NL + 't = f1(n - 1)' + NL + 'return t + n' + NL +
      'endfunction' + NL,
    'function f1(n) local t' + NL + 't = n + 1' + NL + 'return t' + NL +
      'endfunction' + NL,
    'function f1(n) local z' + NL + 'on error goto inner' + NL +
      'z = 1 / 0' + NL + 'return 7' + NL + 'endfunction' + NL);

  { THE FIFTH IS A HANDLER THAT NEVER RESUMES, and it is here because every
    handler in the first four resumes, so the corpus only ever took the wholesale
    frame move in PAIRS -- down to the handler and back up to the failing
    statement. This one takes the first and not the second: the fault drops
    FFrameSP to the handler's level and the program then runs to its end from
    there, with whatever the call stack was above it simply gone. DebugRebase is
    what makes a step survive that, and this is the shape that asks it to.

    MEASURED, NOT ASSUMED, because the first version of this comment claimed it
    produced the ABANDONED-ACTIVATION diagnostic and it does not: a handler
    installed at TOP LEVEL taking a fault raised inside a call is one of the
    shapes that must NOT be diagnosed, and tests/suite/62 and /63 pin exactly
    that. It exits 0. The diagnosed shape needs the handler installed INSIDE the
    call, which is what the `innerfault` body below is for. }
  ErrCount = 5;
  ErrName: array[0..ErrCount - 1] of String = ('none', 'goto', 'call', 'off',
                                               'abandon');
  ErrHead: array[0..ErrCount - 1] of String = (
    '',
    'on error goto oops' + NL,
    'on error call oops' + NL,
    'on error goto oops' + NL + 'on error goto 0' + NL,
    'on error goto oops' + NL);
  ErrTail: array[0..ErrCount - 1] of String = (
    '',
    'oops:' + NL + 'handled = 1' + NL + 'resume next' + NL,
    'function oops(code, msg$) local q' + NL + 'q = code' + NL + 'return 0' + NL +
      'endfunction' + NL,
    'oops:' + NL + 'handled = 1' + NL + 'resume next' + NL,
    'oops:' + NL + 'handled = 1' + NL);

{ Put a line in front of the LAST line of ATop, so whatever followed it still
  runs after a `resume next`. }
function InsertBeforeLast(const ABlock, ALine: String): String;
var
  sl: TStringList;
begin
  sl := TStringList.Create();
  try
    sl.Text := ABlock;
    if sl.Count > 0 then sl.Insert(sl.Count - 1, ALine) else sl.Add(ALine);
    Result := sl.Text;
  finally
    sl.Free;
  end;
end;

function InsertAfterFirst(const ABlock, ALine: String): String;
var
  sl: TStringList;
begin
  sl := TStringList.Create();
  try
    sl.Text := ABlock;
    if sl.Count > 1 then sl.Insert(1, ALine) else sl.Add(ALine);
    Result := sl.Text;
  finally
    sl.Free;
  end;
end;

procedure SweepAll;
var
  b, e, f, t: Integer;
  top, fns, src, name: String;
begin
  for b := 0 to BodyCount - 1 do
    for e := 0 to ErrCount - 1 do
      for f := 0 to 2 do                      // 0 none, 1 top level, 2 in a fn
        for t := 0 to 1 do                    // 0 no trailing `end`, 1 one
        begin
          if (f = 2) and (BodyFns[b] = '') then Continue;
          top := BodyTop[b];
          fns := BodyFns[b];
          if f = 1 then top := InsertBeforeLast(top, 'zz = 1 / 0');
          if f = 2 then fns := InsertAfterFirst(fns, 'zz = 1 / 0');
          src := ErrHead[e] + top;
          if (t = 1) and (Pos('end' + NL, src) = 0) then src := src + 'end' + NL;
          src := src + fns + ErrTail[e];
          name := BodyName[b] + '/' + ErrName[e] + '/fault' + IntToStr(f) +
                  '/end' + IntToStr(t);
          { A FAULT SITE WITH NO LIVE HANDLER OVER IT: e = 0 installed none and
            e = 3 installed one and then took it away with `on error goto 0`.
            Stated from the indices, which is the only place it can be stated
            without reading the run. }
          Uncaught := (f <> 0) and ((e = 0) or (e = 3));
          OneProgram(name, src, '', 0);
          { AND THE SAME PROGRAM THROUGH THE OTHER DOOR.

            Every program above is debugged through TPhosphorEngine.Run, which is
            the door with no host above it: FExecDepth reaches 1, the clamp floor
            is 0, and a step out of the outermost frame has nowhere to go because
            the outermost frame IS the program. A GUI host and a debug adapter
            use the other one -- Prepare once, then CallFunction per click -- and
            there the outermost frame of the call has the HOST's Pascal below it,
            the floor is 1, and the re-entrancy story is the whole of what the
            clamp's three terms were written for.

            Crossing it found two defects by hand that nothing generated was
            looking at, which is the reason this loop exists. Only the bodies
            with functions can be entered this way.

            AND NOT WHEN THE FAULT IS UNCAUGHT. Through this door the top level
            runs during Prepare, so a program that dies there never reaches the
            call: Prepare answers non-zero, no boundary is ever offered, and the
            reference trace is empty. That is a property of the door and not a
            defect -- a host cannot call a function of a session that failed to
            prepare -- so the uncaught shapes are swept through Run, where they
            are the only programs in the corpus that produce an error line and an
            error message at all. }
          if (BodyFns[b] <> '') and (not Uncaught) then
            OneProgram(name + '/hostcall', src, 'f1', 3);
        end;
end;

begin
  ProveFail := (ParamCount >= 1) and (ParamStr(1) = '--fail');
  WindowPark := WindowParkMs;
  SweepAll();
  { A CORPUS IN WHICH NOTHING FAILS CANNOT MEASURE THE ERROR FIELDS, and that was
    this file's state until this round. The floor is not a number somebody read
    off a run: SweepAll builds an uncaught variant for every body, so a corpus
    with fewer of these than it has bodies has lost the shape, not just a few
    programs. }
  Writeln('programs: ', Programs);
  Writeln('with an error: ', WithError);
  Writeln('host door not prepared: ', DoorSkipped);
  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if (Programs < 100) or (WithError < BodyCount) or (Failed > 0) then
    Halt(1)
  else
    Halt(0);
end.
