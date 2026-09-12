{******************************************************************************
  probe_step -- the debug seam, the hook, and the step state machine

  A host could not stop a running program. There was a BREAKPOINT statement the
  script had to contain, reported through a seam that must never block, and
  nothing else: no way to stop at a line the script does not know about, no way
  to step, no way to pause from outside, and no way to end a run early. This
  probe is that machinery's proof.

  THE ONE DESIGN CONSTRAINT EVERYTHING ELSE FOLLOWS FROM: this engine is single
  threaded, so stopping means CALLING BACK, not blocking. The seam is invoked
  from inside the hook and RETURNS the next action; a host that wants to wait
  does its waiting inside the callback. So a Pascal probe can script a debugging
  session exactly -- hand the engine a list of actions and compare the list of
  stops it was offered, byte for byte -- which is why this file and not a .bas
  test is where the machine is pinned.

  EVERY EXPECTED TRACE BELOW IS DERIVED FROM ITS FIXTURE LISTING BY HAND, never
  read off a run. Each carries the derivation in a comment beside it, one
  boundary at a time, because this project has four expectations in its history
  that recorded a defect as correct by being written from what the run printed.

  What it pins, and what breaks if the support is removed:

    * step into visits every boundary, including the SECOND iteration of a
      one-line loop body -- which a rule written on the source line alone cannot
      see, because the second iteration carries the same line at the same depth;
    * step over never enters a call, and still lands in the caller when the step
      was asked on the last statement of a body;
    * step out is silent until the frame stack is strictly shallower, and is
      CLAMPED at the re-entrancy floor -- asserted in BOTH directions, because a
      clamp that fires one level too eagerly would refuse a legitimate step out
      of a nested call and no green suite would notice;
    * a pending step does NOT survive an ON ERROR unwind. Two shapes, one per
      wholesale frame move: `on error goto` + `resume` climbing back into the
      frame that faulted, and `on error call` dropping to a handler that then
      runs one frame DEEPER than the step was asked at;
    * pause is a flag another thread may set, consumed exactly once;
    * stop ends the run the way `end` does -- rc 0, no error code invented -- and
      the statement it stopped at never runs; but a stop taken inside the HOST's
      own CallFunction SAYS so, because there is no rc there to carry it and a
      default value with no error is a function that returned zero;
    * the arming survives a run and the STEP does not, at all three doors that
      start one -- across two REPL lines, across a prepared run into the host's
      first CallFunction, and NOT across a script's own `callfunc`, which is the
      same run continuing;
    * the step-out clamp's floor is the DOOR's, which is 0 through Run and 1
      through a host call -- pinned in both directions at both doors;
    * MaxOutputBytes means the same thing to two hosts, one of which installed a
      breakpoint reporter and one of which did not;
    * a seam that RAISES becomes an engine error at the boundary, and does not
      unwind the interpreter;
    * a host that calls back INTO the engine from the seam is not stopped again
      inside its own stop;
    * the three ledgers a parked seam would otherwise charge to the script --
      the VM's wall clock, the library budget's own wall clock, and the memory
      ceiling's heap floor -- are given back. Each is a program that is REFUSED
      without the correction and completes with it;
    * and they are given back AS THE WINDOW GOES, not when it closes, so a watch
      expression evaluated after a person has been looking at the stack is judged
      against the script's real consumption and not against the pause. Both wall
      clocks, both directions. What the host spends RUNNING SCRIPT in there is
      charged, on the same footing as the bytes it allocates -- asserted by the
      same seven hundred milliseconds spent two ways, with opposite answers;
    * the re-entrancy guard is not part of the arming, so a host that re-syncs
      its breakpoint set from inside a stop is not stopped inside its own stop;
    * and installing the seam AFTER Prepare reaches the prepared VM -- as does
      clearing it -- because arming and installing are two halves of one attach
      and they used to disagree.

  Prints "ok: N" / "fail: M" and exits non-zero on any failure. Run with --fail
  to corrupt one expectation and confirm the check can fail.
******************************************************************************}
program probe_step;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  SysUtils,
  PhosphorValue, PhosphorOpcodes, PhosphorBudget, PhosphorEngine, PhosphorVM;

var
  Ok: Integer = 0;
  Failed: Integer = 0;
  ProveFail: Boolean = False;

procedure Report(Pass: Boolean; const Name: String);
begin
  if Pass then Inc(Ok)
  else begin Inc(Failed); Writeln(StdErr, 'FAIL: ', Name); end;
end;

procedure CheckStr(const AGot, AWant, AName: String);
begin
  if AGot = AWant then Inc(Ok)
  else
  begin
    Inc(Failed);
    Writeln(StdErr, 'FAIL: ', AName, ' -- got "', AGot, '", wanted "', AWant, '"');
  end;
end;

procedure CheckInt(AGot, AWant: Integer; const AName: String);
begin
  if AGot = AWant then Inc(Ok)
  else
  begin
    Inc(Failed);
    Writeln(StdErr, 'FAIL: ', AName, ' -- got ', AGot, ', wanted ', AWant);
  end;
end;

{ ------------------------------------------------------------------------- }

{ THE SCRIPTED HOST. It answers each stop from a fixed list of actions -- the
  last one repeats once the list runs out, so a trace can say "step three times
  then run" without padding -- and records every stop it was offered as
  "<reason><line>@<depth>". That string IS the assertion: a stop too many, a stop
  too few, a stop at the wrong line and a stop at the wrong depth are four
  different defects and one comparison sees all of them. }
type
  TDrive = class
    Eng: TPhosphorEngine;
    Actions: array of TPhosphorDebugAction;
    Next: Integer;
    Trace: String;
    Text: String;
    // Optional behaviours, off unless a test asks for one.
    PauseAtStop: Integer;     // call InterruptDebug at this 1-based stop (0 = never)
    SleepMsAtStop: Integer;   // park this long at the first stop (0 = never)
    HogAtStop: Boolean;       // retain a large allocation at the first stop
    RaiseAtStop: Integer;     // raise from this 1-based stop (0 = never)
    ReentryAtStop: Integer;   // call back into the engine at this stop (0 = never)
    ReentryName: String;      // which routine to re-enter ('' = 'twice', arg 4)
    ReentryArg: Int64;        // its one argument
    { THE WINDOW, IN THREE PIECES. A person reads the stack, asks for a watch,
      then reads the answer: idle, script, idle. The two clocks have to treat the
      middle piece differently from the two outer ones, so a fixture has to be
      able to build all three. }
    ParkBeforeEvalMs: Integer;  // park this long at the re-entry stop, before it
    ParkAfterEvalMs: Integer;   // and this long after it, still inside the seam
    ReenteredErr: String;       // what the engine said about the re-entrant call
    { A HOST RE-SYNCING THE EDITOR'S BREAKPOINTS FROM INSIDE A STOP, which is how
      "replace the set" is naturally written and how the re-entrancy guard came to
      be erased along with the arming. }
    ResyncAtStop: Integer;
    ResyncLines: array of Integer;
    Hog: String;              // what HogAtStop retained, kept alive by this field
    Depth: Integer;           // seam re-entrancy, as the SEAM sees it
    MaxDepth: Integer;
    Reentered: String;        // what the re-entrant call answered
    Stops: Integer;
    { WHAT THE SEAM COULD ACTUALLY REACH FROM INSIDE ITSELF. `of object` makes
      Self the HOST's object, so the engine's state window is reached through
      TPhosphorEngine.DebugVM and through nothing else; three doc blocks used to
      say the seam "gets the VM as Self", and on the strength of that a host
      stopping through Run would have found nothing to read. Recorded at every
      stop in every test, which costs two field reads and means no test can
      silently lose the reach. }
    VMSeen: Integer;          // stops where DebugVM answered a VM
    PreparedSeen: Integer;    // stops where PreparedVM also answered one
    FrameDepthSeen: Integer;  // DbgFrameDepth, from the VM, at the last stop
    GlobalWanted: String;     // a global to read by NAME at each stop ('' = none)
    GlobalText: String;       // what it held at the last stop that had it
    GosubTrace: Boolean;      // also record DbgGosubDepth at each stop
    GosubSeen: String;
    function Debug(AReason: TPhosphorStopReason; ALine: Integer;
                   AFrameDepth: Integer): TPhosphorDebugAction;
    procedure Output(const AText: String);
  end;

procedure TDrive.Output(const AText: String);
begin
  Text := Text + AText;
end;

function ReasonTag(AReason: TPhosphorStopReason): String;
begin
  case AReason of
    srEntry: Result := 'E';
    srBreakpoint: Result := 'B';
    srStep: Result := 'S';
  else
    Result := 'P';                  // srPause
  end;
end;

function TDrive.Debug(AReason: TPhosphorStopReason; ALine: Integer;
  AFrameDepth: Integer): TPhosphorDebugAction;
var
  v: TValue;
  vm: TPhosphorVM;
  p: TProgram;
  gi: Integer;
begin
  Inc(Depth);
  if Depth > MaxDepth then MaxDepth := Depth;
  try
    Inc(Stops);
    if Trace <> '' then Trace := Trace + ' ';
    Trace := Trace + ReasonTag(AReason) + IntToStr(ALine) + '@' + IntToStr(AFrameDepth);

    { WHAT THIS SEAM CAN REACH, asked at every stop of every test. Reading state
      from a stopped frame executes no BASIC, so doing it here cannot change what
      any other assertion in this file measures -- and if it ever did, the traces
      would say so. }
    vm := Eng.DebugVM;
    if vm <> nil then
    begin
      Inc(VMSeen);
      FrameDepthSeen := vm.DbgFrameDepth;
      if GosubTrace then
      begin
        if GosubSeen <> '' then GosubSeen := GosubSeen + ' ';
        GosubSeen := GosubSeen + IntToStr(vm.DbgGosubDepth);
      end;
      if GlobalWanted <> '' then
      begin
        p := vm.DbgProgram;
        if (p <> nil) and p.HasNames then
          for gi := 0 to vm.DbgGlobalCount - 1 do
            if SameText(p.GlobalName(gi), GlobalWanted) then
            begin
              GlobalText := ValToStr(vm.DbgGlobal(gi));
              Break;
            end;
      end;
    end;
    if Eng.PreparedVM <> nil then Inc(PreparedSeen);

    if (RaiseAtStop > 0) and (Stops = RaiseAtStop) then
      raise Exception.Create('the host went away');
    if (PauseAtStop > 0) and (Stops = PauseAtStop) and (Eng.PreparedVM <> nil) then
      Eng.PreparedVM.InterruptDebug();
    if (SleepMsAtStop > 0) and (Stops = 1) then
      Sleep(SleepMsAtStop);
    if HogAtStop and (Stops = 1) then
      // 32 MB, RETAINED in a field: a debug adapter buffering a stack frame or a
      // JSON payload is doing exactly this, and before the correction those bytes
      // were charged to the script's memory ceiling.
      Hog := StringOfChar('h', 32 * 1024 * 1024);
    { THE HOST CALLING BACK INTO THE ENGINE FROM ITS OWN STOP. Guarded here at
      depth 1 as well as in the engine, so that a build WITHOUT the engine's guard
      fails this probe's assertion instead of recursing until the stack runs out.
      A test that dies cannot report which expectation it was about. }
    if (ResyncAtStop > 0) and (Stops = ResyncAtStop) then
    begin
      Eng.DisarmDebug();
      Eng.ArmDebug(ResyncLines, False);
    end;
    if (ReentryAtStop > 0) and (Stops = ReentryAtStop) and (Depth = 1) and
       (Eng.PreparedVM <> nil) then
    begin
      if ParkBeforeEvalMs > 0 then Sleep(ParkBeforeEvalMs);
      if ReentryName = '' then
        v := Eng.CallFunction('twice', [ValInt(4)])
      else
        v := Eng.CallFunction(ReentryName, [ValInt(ReentryArg)]);
      Reentered := ValToStr(v);
      ReenteredErr := Eng.ErrorMessage;
      if ParkAfterEvalMs > 0 then Sleep(ParkAfterEvalMs);
    end;

    if Next <= High(Actions) then
    begin
      Result := Actions[Next];
      Inc(Next);
    end
    else if Length(Actions) > 0 then
      Result := Actions[High(Actions)]     // the last action repeats
    else
      Result := daRun;
  finally
    Dec(Depth);
  end;
end;

function NewDrive(AEng: TPhosphorEngine;
                  const AActions: array of TPhosphorDebugAction): TDrive;
var i: Integer;
begin
  Result := TDrive.Create();
  Result.Eng := AEng;
  SetLength(Result.Actions, Length(AActions));
  for i := 0 to High(AActions) do Result.Actions[i] := AActions[i];
  AEng.OnOutput := @Result.Output;
  AEng.OnDebug := @Result.Debug;
end;

{ The expectation, corrupted by --fail so the comparison is known to be able to
  fail. It corrupts the EXPECTATION and never the engine. }
function Want(const S: String): String;
begin
  if ProveFail then Result := S + ' S999@9' else Result := S;
end;


{ ------------------------------------------------------------------------- }

{ FIXTURE ONE: a call, a loop whose body is ONE LINE, and an `end` before the
  function block -- the idiom the language reference teaches.

     1  x = 0
     2  y = add2(3)
     3  for i = 1 to 2
     4    x = x + i
     5  next
     6  println "done"
     7  end
     8  function add2(n) local t
     9    t = n + n
    10    return t
    11  endfunction

  WHICH LINES CARRY A BOUNDARY, derived from the listing: 1, 2, 3, 4, 6, 7 in the
  top level and 9, 10 in the body. `next` and `endfunction` are block terminators
  and carry none. Line 8 is a function HEADER: it carries one, but it is the jump
  over the body and the top level halts on line 7 before ever reaching it. }
const
  FixStep =
    'x = 0'                          + #10 +
    'y = add2(3)'                    + #10 +
    'for i = 1 to 2'                 + #10 +
    '  x = x + i'                    + #10 +
    'next'                           + #10 +
    'println "done"'                 + #10 +
    'end'                            + #10 +
    'function add2(n) local t'       + #10 +
    '  t = n + n'                    + #10 +
    '  return t'                     + #10 +
    'endfunction'                    + #10;

{ FIXTURE TWO: `on error goto`, a handler at the TOP LEVEL, and a `resume next`
  that climbs back INTO the frame that faulted.

     1  on error goto oops
     2  v = risky(2)
     3  println "after"
     4  end
     5  oops:
     6  handled = 1
     7  resume next
     8  function risky(n) local q
     9    q = n / 0
    10    return q
    11  endfunction

  The fault is raised at depth 1 (inside risky) and the handler was installed at
  depth 0, so the frame pointer DROPS on the way in and CLIMBS BACK on the
  resume. Those are the two wholesale moves the step state must not outlive. }
  FixOnErrGoto =
    'on error goto oops'             + #10 +
    'v = risky(2)'                   + #10 +
    'println "after"'                + #10 +
    'end'                            + #10 +
    'oops:'                          + #10 +
    'handled = 1'                    + #10 +
    'resume next'                    + #10 +
    'function risky(n) local q'      + #10 +
    '  q = n / 0'                    + #10 +
    '  return q'                     + #10 +
    'endfunction'                    + #10;

{ FIXTURE THREE: `on error call`, whose handler runs one frame DEEPER than the
  level the fault dropped to -- the shape that tells the two rebase sites apart.

     1  on error call oops
     2  v = risky(2)
     3  println "after"
     4  end
     5  function oops(code, msg$) local z
     6    z = code
     7    return 0
     8  endfunction
     9  function risky(n) local q
    10    q = n / 0
    11    return q
    12  endfunction }
  FixOnErrCall =
    'on error call oops'             + #10 +
    'v = risky(2)'                   + #10 +
    'println "after"'                + #10 +
    'end'                            + #10 +
    'function oops(code, msg$) local z' + #10 +
    '  z = code'                     + #10 +
    '  return 0'                     + #10 +
    'endfunction'                    + #10 +
    'function risky(n) local q'      + #10 +
    '  q = n / 0'                    + #10 +
    '  return q'                     + #10 +
    'endfunction'                    + #10;

{ FIXTURE FOUR: nothing but functions, so every boundary is inside a frame the
  HOST entered through CallFunction -- which is where the step-out clamp lives.

     1  end
     2  function outer(n) local a
     3    a = inner(n)
     4    return a
     5  endfunction
     6  function inner(n) local b
     7    b = n + 1
     8    return b
     9  endfunction
    10  function twice(n)
    11    return n + n
    12  endfunction }
  FixFrames =
    'end'                            + #10 +
    'function outer(n) local a'      + #10 +
    '  a = inner(n)'                 + #10 +
    '  return a'                     + #10 +
    'endfunction'                    + #10 +
    'function inner(n) local b'      + #10 +
    '  b = n + 1'                    + #10 +
    '  return b'                     + #10 +
    'endfunction'                    + #10 +
    'function twice(n)'              + #10 +
    '  return n + n'                 + #10 +
    'endfunction'                    + #10;

{ ------------------------------------------------------------------------- }

{ STEP INTO, from the first boundary, all the way out.

  DERIVED FROM THE LISTING, one boundary at a time. A step stops at the next
  boundary that is not WHERE IT WAS, and where it was is a depth, a line and the
  boundary's own pc:

    stop 1  E1@0   stop-at-entry, before line 1 runs
    stop 2  S2@0   line differs
    stop 3  S9@1   the call: depth differs (this is what "into" means)
    stop 4  S10@1  line differs
    stop 5  S3@0   the return: depth differs. The `for` HEADER, which executes
                   ONCE, before the loop top -- not once per iteration
    stop 6  S4@0   the body, first iteration
    stop 7  S4@0   the body, SECOND iteration. Same line, same depth, and the
                   step stops because it is back at the boundary it started
                   from. This is the one a line-only rule cannot see
    stop 8  S6@0   the loop is done; line differs
    stop 9  S7@0   `end`

  `next` and `endfunction` carry no boundary, and line 8's header boundary is
  after the `end` that stops the program. }
procedure CheckStepInto;
var
  eng: TPhosphorEngine;
  d: TDrive;
  rc: Integer;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daStepInto]);
  try
    eng.ArmDebug([], True);
    rc := eng.Run(FixStep);
    CheckInt(rc, 0, 'step-into: the fixture runs to the end');
    CheckStr(d.Trace, Want('E1@0 S2@0 S9@1 S10@1 S3@0 S4@0 S4@0 S6@0 S7@0'),
             'step into offers every boundary, including the second iteration ' +
             'of a one-line loop body');
    CheckStr(d.Text, 'done' + #10, 'and the program still produced its output');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ STEP OVER, the same fixture, the same stop-at-entry.

    stop 1  E1@0   entry
    stop 2  S2@0   line differs at the same depth
    stop 3  S3@0   add2's boundaries are at depth 1, ABOVE the depth the step was
                   asked at, so they are silent -- that is what "over" means. The
                   next boundary at depth 0 is the `for` header
    stop 4  S4@0   the body
    stop 5  S4@0   the body again: back at the boundary the step started from
    stop 6  S6@0
    stop 7  S7@0

  Two fewer stops than step-into, and the two missing ones are exactly 9 and 10. }
procedure CheckStepOver;
var
  eng: TPhosphorEngine;
  d: TDrive;
  rc: Integer;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daStepOver]);
  try
    eng.ArmDebug([], True);
    rc := eng.Run(FixStep);
    CheckInt(rc, 0, 'step-over: the fixture runs to the end');
    CheckStr(d.Trace, Want('E1@0 S2@0 S3@0 S4@0 S4@0 S6@0 S7@0'),
             'step over never enters the call, and still stops each time round ' +
             'the loop');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ STEP OUT of a body entered by stepping into it.

  Actions: into, into, OUT, then run.

    stop 1  E1@0   entry                       -> daStepInto
    stop 2  S2@0                                -> daStepInto
    stop 3  S9@1   inside add2                  -> daStepOut, armed at depth 1
    ...            line 10 is at depth 1, and 1 is not strictly less than 1, so
                   it is silent. This is the assertion: a step out does not stop
                   on the rest of the body it is leaving
    stop 4  S3@0   the return brings the stack to depth 0                -> daRun
    ...            and nothing after that stops.

  The top level is ExecFrom's AStopFrameSP = -1, so depth 1 is NOT at the
  re-entrancy floor and the step out is armed rather than clamped. The clamped
  direction is CheckStepOutClamp. }
procedure CheckStepOut;
var
  eng: TPhosphorEngine;
  d: TDrive;
  rc: Integer;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daStepInto, daStepInto, daStepOut, daRun]);
  try
    eng.ArmDebug([], True);
    rc := eng.Run(FixStep);
    CheckInt(rc, 0, 'step-out: the fixture runs to the end');
    CheckStr(d.Trace, Want('E1@0 S2@0 S9@1 S3@0'),
             'step out is silent for the rest of the body it is leaving and ' +
             'stops in the caller');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ A STEP OVER ASKED ON THE LAST STATEMENT OF A BODY LANDS IN THE CALLER, which
  is the arm of the rule that has nothing to do with staying out of calls. "Over"
  is silent ABOVE the depth it was asked at; BELOW it the body ran out, and that
  stops whatever the line.

  Actions: into, into, into, OVER, then run.

    stop 1  E1@0   entry                                       -> daStepInto
    stop 2  S2@0                                                -> daStepInto
    stop 3  S9@1   inside add2                                  -> daStepInto
    stop 4  S10@1  `return t`, the last statement of the body   -> daStepOver
    stop 5  S3@0   the return leaves the body, so the frame stack is SHALLOWER
                   than the depth the step was asked at                 -> daRun

  Without that arm the step over is measured only at its own depth, depth 1 never
  comes round again, and the trace stops at S10@1 with the program running on to
  its end unwatched. }
procedure CheckStepOverOutOfBody;
var
  eng: TPhosphorEngine;
  d: TDrive;
  rc: Integer;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daStepInto, daStepInto, daStepInto, daStepOver, daRun]);
  try
    eng.ArmDebug([], True);
    rc := eng.Run(FixStep);
    CheckInt(rc, 0, 'step-over-out-of-body: the fixture runs to the end');
    CheckStr(d.Trace, Want('E1@0 S2@0 S9@1 S10@1 S3@0'),
             'a step over asked on the last statement of a body stops in the ' +
             'caller, not at the end of the program');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ THE RE-ENTRANCY FLOOR, ASSERTED IN BOTH DIRECTIONS, because a clamp has two
  ways to be wrong and only one of them is visible from the shape it guards.

  A host calling `outer` through CallFunction enters ExecFrom with
  AStopFrameSP = 0, so `outer` itself stands at depth 1 -- the floor + 1. There
  is no boundary below that for this activation to reach: control goes back to
  the host's Pascal, not to more BASIC.

  NOT CLAMPED (the legitimate step out). A breakpoint on line 7 stops inside
  `inner`, at depth 2:

    stop 1  B7@2   armed line                   -> daStepOut, armed at depth 2
    ...            line 8 is depth 2, not strictly less, silent
    stop 2  S4@1   back in `outer`                                      -> daRun

  CLAMPED. A breakpoint on line 3 stops inside `outer`, at depth 1, which IS the
  floor + 1:

    stop 1  B3@1   armed line                   -> daStepOut, treated as daRun
    ...            lines 7, 8 and 4 follow and none of them stops.

  If the clamp fired one level too eagerly the first trace would lose its S4@1 --
  a legitimate step out refused, which is this project's named failure mode and
  the reason both directions are here rather than only the one the clamp is for. }
procedure CheckStepOutClamp;
var
  eng: TPhosphorEngine;
  d: TDrive;
  rc: Integer;
  v: TValue;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daStepOut, daRun]);
  try
    rc := eng.Prepare(FixFrames);
    CheckInt(rc, 0, 'the frames fixture prepares');
    if rc <> 0 then Exit;

    eng.ArmDebug([7], False);
    v := eng.CallFunction('outer', [ValInt(5)]);
    CheckStr(ValToStr(v), '6', 'outer(5) answers 6');
    CheckStr(d.Trace, Want('B7@2 S4@1'),
             'a step out from a nested frame is NOT clamped: it stops in the ' +
             'frame that called it');

    d.Trace := '';
    d.Next := 0;
    d.Stops := 0;
    eng.ArmDebug([3], False);
    v := eng.CallFunction('outer', [ValInt(5)]);
    CheckStr(ValToStr(v), '6', 'outer(5) still answers 6 under the clamp');
    CheckStr(d.Trace, Want('B3@1'),
             'a step out from the OUTERMOST frame of a host call is clamped to ' +
             'continue: there is no shallower boundary to reach');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ AND THE FLOOR IS NOT EVERY RE-ENTRANT FLOOR. `callfunc` re-enters through the
  same door a host callback does, but from INSIDE a running ExecFrom -- so there
  IS more BASIC to come back to, and a step out must reach it.

     1  end
     2  function outer(n) local a
     3    a = callfunc("inner", n)
     4    return a
     5  endfunction
     6  function inner(n) local b
     7    b = n + 1
     8    return b
     9  endfunction

  The host calls `outer`, so outer stands at depth 1 over a floor of 0. `callfunc`
  then re-enters for `inner` with a floor of 1, and inner stands at depth 2.

    stop 1  B7@2   the armed line, inside inner        -> daStepOut. The floor
                   here is 1, not 0, so this activation was entered from inside a
                   run and is NOT clamped
    stop 2  S4@1   back in `outer`, one boundary later                  -> daRun

  A clamp written on the frame depth alone would swallow this: 2 is the floor + 1,
  and the step out would become a continue with the answer one boundary away. }
procedure CheckStepOutThroughCallfunc;
const
  Fix =
    'end'                            + #10 +
    'function outer(n) local a'      + #10 +
    '  a = callfunc("inner", n)'     + #10 +
    '  return a'                     + #10 +
    'endfunction'                    + #10 +
    'function inner(n) local b'      + #10 +
    '  b = n + 1'                    + #10 +
    '  return b'                     + #10 +
    'endfunction'                    + #10;
var
  eng: TPhosphorEngine;
  d: TDrive;
  rc: Integer;
  v: TValue;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daStepOut, daRun]);
  try
    rc := eng.Prepare(Fix);
    CheckInt(rc, 0, 'the callfunc fixture prepares');
    if rc <> 0 then Exit;
    eng.ArmDebug([7], False);
    v := eng.CallFunction('outer', [ValInt(5)]);
    CheckStr(ValToStr(v), '6', 'outer(5) answers 6 through callfunc');
    CheckStr(d.Trace, Want('B7@2 S4@1'),
             'a step out of a routine entered by callfunc reaches the statement ' +
             'that called it: that floor has BASIC above it');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ A PENDING STEP DOES NOT SURVIVE A `resume`. The frame pointer climbs back into
  the activation that faulted, and it does it with no boundary in between.

  Armed on line 6, the handler's first statement. Actions: over, over, then run.

    ...            lines 1, 2 and 9 are not armed and nothing is pending: silent.
                   The fault at line 9 drops the frame pointer from 1 to 0
    stop 1  B6@0   the armed line, in the handler at depth 0   -> daStepOver
    stop 2  S7@0   `resume next`, same depth, line differs      -> daStepOver
    ...            the resume stands the VM back at depth 1, inside `risky`,
                   and continues at the statement after the one that faulted
    stop 3  S10@1  and the step -- rebased onto the stack the resume put back --
                   stops there                                          -> daRun
    ...            line 3 and line 4 follow at depth 0 and do not stop.

  WITHOUT THE REBASE the pending step over is still measured against depth 0, so
  line 10 at depth 1 is silent and the trace ends S3@0 instead: the resume takes
  the user somewhere and the debugger does not say where. }
procedure CheckResumeRebase;
var
  eng: TPhosphorEngine;
  d: TDrive;
  rc: Integer;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daStepOver, daStepOver, daRun]);
  try
    eng.ArmDebug([6], False);
    rc := eng.Run(FixOnErrGoto);
    CheckInt(rc, 0, 'the on-error-goto fixture runs to the end');
    CheckStr(d.Trace, Want('B6@0 S7@0 S10@1'),
             'a step does not survive a resume: it is rebased onto the frame ' +
             'the resume stood the VM back in');
    CheckStr(d.Text, 'after' + #10, 'and the program still produced its output');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ A PENDING STEP DOES NOT SURVIVE A FAULT EITHER, and `on error call` is the
  shape that proves the OTHER rebase site: the handler runs one frame DEEPER than
  the level the fault dropped to, so a step over that is still measured against
  the old depth steps straight over the whole handler.

  Armed on line 2, the call that faults. Actions: over, then run.

    ...            line 1 is not armed and nothing is pending: silent
    stop 1  B2@0   the armed line                              -> daStepOver
    ...            line 10, inside risky at depth 1, is above the depth the step
                   was asked at: silent, which is what "over" means. It faults
    ...            the fault stands the VM at the handler's install level, 0
    stop 2  S6@1   `on error call` then invokes the handler, so its body runs at
                   depth 1 -- and the step, rebased to depth 0 with no line,
                   stops at its first statement                        -> daRun
    ...            line 7 returns 0, the resume continues at line 11, and lines
                   11, 3 and 4 do not stop.

  WITHOUT THE REBASE the step over is measured against depth 0, the handler's
  body at depth 1 is silent, and the first thing that stops is line 11 after the
  resume has rebased it -- S11@1. The handler ran and the debugger never said so. }
procedure CheckFaultRebase;
var
  eng: TPhosphorEngine;
  d: TDrive;
  rc: Integer;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daStepOver, daRun]);
  try
    eng.ArmDebug([2], False);
    rc := eng.Run(FixOnErrCall);
    CheckInt(rc, 0, 'the on-error-call fixture runs to the end');
    CheckStr(d.Trace, Want('B2@0 S6@1'),
             'a step does not survive a fault: it is rebased onto the level the ' +
             'handler was installed at, so the handler body is not stepped over');
    CheckStr(d.Text, 'after' + #10, 'and the program still produced its output');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ BREAKPOINTS ARE LINES, AND ONLY LINES. Armed on 4 -- the one-line loop body --
  the run stops once per iteration and nowhere else. This is also what says the
  armed set is consulted independently of any step: the mode is dmRun throughout.

    stop 1  B4@0   iteration one
    stop 2  B4@0   iteration two

  And a line NOTHING lands on arms nothing: 5 is `next`, a block terminator that
  carries no boundary at all, and 99 is past the end of the file. Both are
  legitimate things for an editor's gutter to hand over, and neither may stop
  anything or fault. }
procedure CheckArmedLines;
var
  eng: TPhosphorEngine;
  d: TDrive;
  rc: Integer;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daRun]);
  try
    eng.ArmDebug([4], False);
    rc := eng.Run(FixStep);
    CheckInt(rc, 0, 'armed lines: the fixture runs to the end');
    CheckStr(d.Trace, Want('B4@0 B4@0'),
             'a breakpoint on a one-line loop body fires once per iteration');
  finally
    eng.Free;
    d.Free;
  end;

  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daRun]);
  try
    // Deliberately unsorted, with a duplicate and a line a boundary cannot carry.
    eng.ArmDebug([99, 5, 99, 0, -3], False);
    rc := eng.Run(FixStep);
    CheckInt(rc, 0, 'a set of unreachable lines: the fixture runs to the end');
    CheckStr(d.Trace, Want(''),
             'a block terminator, a line past the end of the file and a line ' +
             'number no source has arm nothing at all');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ PAUSE. The seam asks for one at the entry stop and returns `run`; the very next
  boundary reports srPause, and only that one -- the flag is read and cleared in
  one operation, so it cannot fire twice.

    stop 1  E1@0   entry; the seam calls InterruptDebug and says run
    stop 2  P2@0   the next boundary, paused; the seam says run
    ...            and nothing after it stops, which is the "exactly once" half.

  Through Prepare rather than Run, because InterruptDebug is called ON a VM and
  the VM a one-shot Run makes is a local of that call. That is the engine's
  documented shape, not an accident of this test: PreparedVM is the handle a host
  with another thread has. }
procedure CheckPause;
var
  eng: TPhosphorEngine;
  d: TDrive;
  rc: Integer;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daRun]);
  try
    d.PauseAtStop := 1;
    eng.ArmDebug([], True);
    rc := eng.Prepare(FixStep);
    CheckInt(rc, 0, 'pause: the fixture prepares');
    CheckStr(d.Trace, Want('E1@0 P2@0'),
             'InterruptDebug stops the next boundary with srPause, exactly once');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ STOP. The seam says so at the boundary of line 6, which is the `println` -- so
  the statement it stopped at never runs and the program produces NOTHING.

  It ends the run the way `end` does: rc 0, no error, and Halted True afterwards.
  There is no ninth error code, and the reason is written at TPhosphorDebugAction.

  The second half is the control: the SAME fixture with the same breakpoint and
  `run` instead of `stop` prints "done". Without it this test would pass on an
  engine where line 6 simply never executed. }
procedure CheckStop;
var
  eng: TPhosphorEngine;
  d: TDrive;
  rc: Integer;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daStop]);
  try
    eng.ArmDebug([6], False);
    rc := eng.Prepare(FixStep);
    CheckInt(rc, 0, 'stop: the run reports success, not an invented error code');
    CheckStr(d.Trace, Want('B6@0'), 'stop: one stop and then nothing');
    CheckStr(d.Text, '', 'the statement the debugger stopped at never ran');
    Report(eng.Halted, 'stop leaves the engine Halted, the way END does');
  finally
    eng.Free;
    d.Free;
  end;

  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daRun]);
  try
    eng.ArmDebug([6], False);
    rc := eng.Prepare(FixStep);
    CheckInt(rc, 0, 'the control: the same fixture with `run` instead of `stop`');
    CheckStr(d.Text, 'done' + #10,
             'and it DOES print, so the silence above was the stop and not the ' +
             'fixture');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ A SEAM THAT RAISES. The host is on a socket and a socket throws. An exception
  travelling out of the hook would leave the value stack, the frame stack and
  every open channel wherever the unwinding left them, so it becomes an ordinary
  engine error at the boundary -- the one place the VM's state is known clean. }
procedure CheckSeamRaises;
var
  eng: TPhosphorEngine;
  d: TDrive;
  rc: Integer;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daRun]);
  try
    d.RaiseAtStop := 1;
    eng.ArmDebug([6], False);
    rc := eng.Run(FixStep);
    Report(rc <> 0, 'a seam that raises fails the run instead of unwinding it');
    Report(Pos('the debug seam raised', eng.ErrorMessage) > 0,
           'and the error says where it came from (' + eng.ErrorMessage + ')');
    CheckInt(rc, 6, 'and it is reported at the line the seam was asked about');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ A HOST CALLING BACK INTO THE ENGINE FROM ITS OWN STOP. `twice` has a boundary
  on line 11 and line 11 is NOT armed, but line 7 is -- so the re-entrant call
  runs a function whose statements would be offered to the seam if the hook did
  not know it was already inside one.

  The assertion is the SEAM DEPTH, not the trace: a stop inside a stop is the
  defect, and the trace would only show it as extra entries whose lines happen to
  belong to another function. MaxDepth = 1 says it directly. }
procedure CheckSeamReentry;
var
  eng: TPhosphorEngine;
  d: TDrive;
  rc: Integer;
  v: TValue;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daStepInto, daStepInto, daStepInto]);
  try
    rc := eng.Prepare(FixFrames);
    CheckInt(rc, 0, 're-entry: the frames fixture prepares');
    if rc <> 0 then Exit;
    { AT THE SECOND STOP AND NOT THE FIRST, and the difference is the whole test.
      The first stop is a breakpoint with nothing pending, so the mode is `run`
      and the statements of a re-entrant call would not have stopped anyway -- a
      build with no guard at all passes that version. By the second stop a step
      into is pending, so every boundary the re-entrant call executes is one the
      hook would offer if it did not know it was already inside a stop. }
    d.ReentryAtStop := 2;
    eng.ArmDebug([7], False);
    v := eng.CallFunction('outer', [ValInt(5)]);
    CheckStr(ValToStr(v), '6', 'the outer call still answers 6');
    CheckStr(d.Reentered, '8', 'the re-entrant call from inside the seam answered');
    CheckInt(d.MaxDepth, 1,
             'the seam was never entered from inside itself: statements run by a ' +
             'host callback made from a stop are not offered as stops');
    CheckStr(d.Trace, Want('B7@2 S8@2 S4@1'),
             'and the re-entrant call left no trace of its own in the session');
    { AND THE SEAM CAN STILL REACH ITS OWN VM AFTERWARDS. The re-entrant call is
      a run of its own at every door -- it sets the engine's live-VM field on the
      way in -- so a field that were NILLED on the way out instead of restored
      would leave every later boundary of the OUTER run unable to reach the VM: a
      debugger that works until the first watch expression. Three stops, three
      reads, and the third is after the re-entry. }
    CheckInt(d.VMSeen, 3,
             'the live VM is still reachable at the stops AFTER a re-entrant ' +
             'call: the doors nest, so the field is restored and not nilled');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ ------------------------------------------------------------------------- }
{ THE THREE LEDGERS A PARKED SEAM WOULD OTHERWISE CHARGE TO THE SCRIPT.

  Each of these is a program that a host with a ceiling set would have seen
  REFUSED for something a person did while looking at a breakpoint. Each asserts
  the run completes AND that its output is right, because "it did not fail" is
  not the same as "it did the work".

  MaxSteps is the fourth ceiling and needs no correction: parking executes no
  instruction, so an instruction count is correct by construction. That is not an
  omission from this list; it is the reason it has three entries and not four. }

{ LEDGER ONE: the VM's own wall clock, which is sampled once per run and read
  every 4096 instructions. The fixture spends 3000 iterations AFTER the park so
  that the check is reached at all -- a program short enough never to reach it
  would pass this test on any build. }
procedure CheckParkedClock;
var
  eng: TPhosphorEngine;
  d: TDrive;
  rc: Integer;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daRun]);
  try
    d.SleepMsAtStop := 350;
    eng.TimeoutMs := 200;
    eng.ArmDebug([], True);
    rc := eng.Run('s = 0' + #10 +
                  'for i = 1 to 3000' + #10 +
                  '  s = s + 1' + #10 +
                  'next' + #10 +
                  'println str$(s)' + #10);
    CheckInt(rc, 0,
             'a seam parked for longer than the whole time ceiling does not ' +
             'time out the script (' + eng.ErrorMessage + ')');
    CheckStr(d.Text, '3000' + #10, 'and the loop really ran to the end');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ LEDGER TWO: the library budget's own clock, which is a DIFFERENT clock started
  by BudgetBegin from the same TimeoutMs and read by every library call that
  consults RULE 1. This fixture is deliberately SHORT -- well under the 4096
  instructions the VM's own check needs -- so that nothing but the budget can
  refuse it, and a pass here is about the budget and not about ledger one. }
procedure CheckParkedBudget;
var
  eng: TPhosphorEngine;
  d: TDrive;
  rc: Integer;
  before, after: Int64;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daRun]);
  try
    d.SleepMsAtStop := 350;
    eng.TimeoutMs := 200;
    eng.ArmDebug([], True);
    rc := eng.Run('s$ = string$(50, 65)' + #10 +
                  'println str$(len(s$))' + #10);
    CheckInt(rc, 0,
             'a parked seam does not spend the LIBRARY budget either (' +
             eng.ErrorMessage + ')');
    CheckStr(d.Text, '50' + #10, 'and the library call really did its work');
  finally
    eng.Free;
    d.Free;
  end;

  { AND THE UNIT ITSELF, asked directly, because the engine test above can only
    say that nothing refused -- it cannot say the clock moved by the right amount.

    DERIVED FROM THE DEFINITION. A 5000 ms ceiling, 120 ms of real waiting, then
    100 of those milliseconds given back: the remaining time must go UP by about
    100 and must never exceed the ceiling. The margin is 50 rather than 100
    because the two reads are not simultaneous, and the ceiling test is the half
    that catches the mistake the first version of BudgetParked actually made --
    pushing the start into the FUTURE, where the unsigned subtraction every reader
    does wraps and answers 0 for the rest of the run. }
  BudgetBegin(0, 5000);
  try
    Sleep(120);
    before := BudgetRemainingMs;
    BudgetParked(100);
    after := BudgetRemainingMs;
    Report(after >= before + 50,
           'BudgetParked gives the parked milliseconds back to the budget clock ' +
           '(' + IntToStr(before) + ' -> ' + IntToStr(after) + ')');
    Report((after > 0) and (after <= 5000),
           'and it never pushes the start past now, which would wrap the clock');
  finally
    BudgetEnd();
  end;
  { TOLD MORE THAN HAS ELAPSED, which is the case the clamp is for and the one a
    caller reaches by rounding: a park of 20 ms reported as 100000. Without the
    clamp the start goes a hundred seconds into the FUTURE, the unsigned
    subtraction every reader does wraps, and a 5000 ms budget answers 1 ms left
    for the rest of the run. Derived from the arithmetic, not from a run: the
    give-back can never exceed what has elapsed, so the remaining time here is
    still the whole ceiling, to within the 20 ms actually spent. }
  BudgetBegin(0, 5000);
  try
    Sleep(20);
    BudgetParked(100000);
    after := BudgetRemainingMs;
    Report(after > 4000,
           'a park longer than the run itself is clamped at now, not wrapped ' +
           'past it (' + IntToStr(after) + ' ms left of 5000)');
  finally
    BudgetEnd();
  end;
  { And it cannot resurrect a budget nobody began: outside a Begin/End pair it is
    a no-op, so a stray call can never hand a later run a clock that never
    started. }
  BudgetParked(5000);
  BudgetBegin(0, 200);
  try
    Report(BudgetRemainingMs <= 200,
           'a BudgetParked outside a run does not carry into the next one');
  finally
    BudgetEnd();
  end;
end;

{ LEDGER THREE: the memory ceiling's floor, which is process heap sampled when
  the run began. A debug adapter buffering a stack frame in here is indis-
  tinguishable from the script allocating, unless the engine measures either side
  of the seam and declines to charge the difference.

  32 MB retained by the host against a 4 MB ceiling: without the correction the
  script's very next concatenation is over the ceiling before it allocates a
  byte. The script itself builds about 200 KB, which is well inside 4 MB, so a
  pass is about the host's allocation and not about the script's. }
procedure CheckParkedHeap;
var
  eng: TPhosphorEngine;
  d: TDrive;
  rc: Integer;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daRun]);
  try
    d.HogAtStop := True;
    eng.MaxMemoryBytes := 4 * 1024 * 1024;
    eng.ArmDebug([], True);
    rc := eng.Run('t$ = string$(1000, 66)' + #10 +
                  's$ = ""' + #10 +
                  'for i = 1 to 200' + #10 +
                  '  s$ = s$ + t$' + #10 +
                  'next' + #10 +
                  'println str$(len(s$))' + #10);
    CheckInt(rc, 0,
             'memory the HOST allocated while parked is not charged to the ' +
             'script (' + eng.ErrorMessage + ')');
    CheckStr(d.Text, '200000' + #10, 'and the script built its string');
    CheckInt(Length(d.Hog), 32 * 1024 * 1024,
             'the host really was holding 32 MB across the stop');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ ------------------------------------------------------------------------- }

{ THE BREAKPOINT STREAM IS ON A CEILING NOW, AND IT WAS ON NONE.

  MaxOutputBytes counted what left through OnOutput and nothing else, so a
  `breakpoint` inside a loop was outside all four ceilings: the console host
  bounds ONE report by three named lengths, and the COUNT of reports is the half
  no host can bound without lying about the program's state. Measured on the
  build before the charge existed: `trace 1` plus one breakpoint in a
  100 000-iteration loop wrote 37.8 MB to stderr at exit 0.

  Two directions, because a ceiling has two ways to be wrong. With no ceiling set
  the reports all arrive -- so the charge cannot be refusing anything a host did
  not ask to have refused. With a small one the run is refused, and refused with
  peLimit at the line the breakpoint is on. }
type
  TBpCount = class
    N: Integer;
    Bytes: Integer;
    Ops: Integer;
    Line: Integer;
    procedure Fired(const AMessage: String; ALine: Integer;
                    const AOperands: array of TValue);
    procedure Output(const AText: String);
  end;

procedure TBpCount.Fired(const AMessage: String; ALine: Integer;
  const AOperands: array of TValue);
begin
  Inc(N);
  Inc(Bytes, Length(AMessage));
  Inc(Ops, Length(AOperands));
  if Line = 0 then Line := ALine;     // the first one, for the refusal assertion
end;

procedure TBpCount.Output(const AText: String);
begin
  if AText = '' then Inc(N, 0);
end;

const
  { Twenty iterations, one breakpoint each. The message is 24 bytes -- count them
    -- and the one operand is the loop counter, charged what PRINT would charge
    for it: one byte for i = 1..9 and two for i = 10..20. So the payload of the
    first nine reports is 25 bytes each and of the last eleven 26, and the run
    hands over 9 * 25 + 11 * 26 = 511. Derived from the listing and from the rule
    at opBreakpoint, not from a run.

    IT USED TO BE 56 A REPORT, because the charge was TextLenOf and TextLenOf
    prices any non-string at a flat 32 -- an estimator borrowed from opAdd, which
    measures the heap afterwards, into a place that spends the number against a
    threshold instead. This expectation recorded that: a comment that said "56"
    and meant "32 bytes for the digit 1". }
  FixBreak =
    'trace 1'                                    + #10 +
    'for i = 1 to 20'                            + #10 +
    '  breakpoint "twenty-four bytes here..", i' + #10 +
    'next'                                       + #10 +
    'end'                                        + #10;

procedure CheckBreakpointCharged;
var
  eng: TPhosphorEngine;
  c: TBpCount;
  rc: Integer;
begin
  eng := TPhosphorEngine.Create();
  c := TBpCount.Create();
  try
    eng.OnBreakpoint := @c.Fired;
    eng.OnOutput := @c.Output;
    rc := eng.Run(FixBreak);
    CheckInt(rc, 0, 'with no output ceiling every breakpoint still reports');
    CheckInt(c.N, 20, 'and all twenty of them arrive');
    CheckInt(c.Bytes, 20 * 24, 'each carrying its 24-byte message');
    CheckInt(c.Ops, 20, 'and its one operand');
  finally
    eng.Free;
    c.Free;
  end;

  eng := TPhosphorEngine.Create();
  c := TBpCount.Create();
  try
    eng.OnBreakpoint := @c.Fired;
    eng.OnOutput := @c.Output;
    { 140 bytes buys 5 reports at 25 bytes of payload each -- 5 * 25 = 125, and
      the sixth (i = 6, still one digit) would reach 150, which is over. Derived
      from the rule, not a run. Under the old flat-32 charge the same ceiling
      bought TWO reports, which is what makes this assertion say which pricing is
      in force rather than merely that there is one. }
    eng.MaxOutputBytes := 140;
    rc := eng.Run(FixBreak);
    CheckInt(rc, 3,
             'a breakpoint stream over the output ceiling is refused, at the ' +
             'line the breakpoint is on');
    Report(Pos('output limit exceeded', eng.ErrorMessage) > 0,
           'and it is the output ceiling that refuses it (' + eng.ErrorMessage + ')');
    CheckInt(c.N, 5,
             'the report that would have crossed the ceiling was not made at ' +
             'all: half a frame on a debug stream is worse than none');
  finally
    eng.Free;
    c.Free;
  end;
end;

{ ARMING A LINE NO SOURCE HAS. An editor's gutter hands over line numbers, and 0
  is what an off-by-one produces; a .pbc can also carry a boundary whose Line is 0
  or negative, because ReadProgram takes each instruction's Line straight from the
  file and ValidateProgram bounds indices and never a line. ArmDebug drops both,
  so a host cannot arm a set that only a corrupt program could match.

  Built by hand and run on a bare VM, because nothing the compiler emits carries
  such a line -- the same reason probe_debug builds its StoppableLines fixtures
  that way. The program is three boundaries: line 0, line -4, line 7. Arming
  [0, -4, 7] must stop on 7 and on nothing else. }
type
  TLineWatch = class
    Trace: String;
    function Debug(AReason: TPhosphorStopReason; ALine: Integer;
                   AFrameDepth: Integer): TPhosphorDebugAction;
  end;

function TLineWatch.Debug(AReason: TPhosphorStopReason; ALine: Integer;
  AFrameDepth: Integer): TPhosphorDebugAction;
begin
  if Trace <> '' then Trace := Trace + ' ';
  Trace := Trace + ReasonTag(AReason) + IntToStr(ALine) + '@' + IntToStr(AFrameDepth);
  Result := daRun;
end;

procedure CheckArmUnusableLine;
var
  vm: TPhosphorVM;
  w: TLineWatch;
  p: TProgram;
begin
  vm := TPhosphorVM.Create();
  w := TLineWatch.Create();
  p := TProgram.Create();
  try
    p.Emit(opStmt, 0, 0, 0);        // a boundary with no line
    p.Emit(opNop, 0, 0, 0);
    p.Emit(opStmt, 0, 0, -4);       // a boundary with a negative line
    p.Emit(opNop, 0, 0, -4);
    p.Emit(opStmt, 0, 0, 7);        // an ordinary one
    p.Emit(opNop, 0, 0, 7);
    p.Emit(opHalt, 0, 0, 7);
    p.SetGlobalTableUnnamed([]);
    vm.OnDebug := @w.Debug;
    vm.ArmDebug([0, -4, 7], False);
    Report(vm.Run(p), 'the hand-built line fixture runs');
    CheckStr(w.Trace, Want('B7@0'),
             'a line of 0 or less is dropped when the host arms it: only the ' +
             'real line stops');
  finally
    p.Free;
    w.Free;
    vm.Free;
  end;
end;

{ ------------------------------------------------------------------------- }

{ ATTACHED, DETACHED, AND THE COST THAT SEPARATES THEM. A host that installs the
  seam and never arms is DETACHED: the hook is one Boolean test per statement
  boundary and the seam is never consulted. That is the claim the commit message
  puts a number on, and this is the assertion that it is a claim about behaviour
  and not only about timing. }
procedure CheckAttachDetach;
var
  eng: TPhosphorEngine;
  d: TDrive;
  rc: Integer;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daStepInto]);
  try
    // Installed, never armed.
    rc := eng.Run(FixStep);
    CheckInt(rc, 0, 'detached: the fixture runs to the end');
    CheckStr(d.Trace, Want(''),
             'a seam that is installed but never armed is never consulted');

    eng.ArmDebug([], True);
    rc := eng.Prepare(FixStep);
    CheckInt(rc, 0, 'attached: the fixture prepares');
    Report((eng.PreparedVM <> nil) and eng.PreparedVM.DebugAttached,
           'and the VM says it is attached');
    Report(d.Stops > 0, 'and it was consulted');

    eng.DisarmDebug();
    Report((eng.PreparedVM <> nil) and (not eng.PreparedVM.DebugAttached),
           'DisarmDebug detaches the prepared VM immediately');
    d.Trace := '';
    d.Next := 0;
    d.Stops := 0;
    rc := eng.Run(FixStep);
    CheckInt(rc, 0, 'and a later run is undebugged');
    CheckStr(d.Trace, Want(''), 'with no stops at all');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ ------------------------------------------------------------------------- }

{ STEP OUT OF A ROUTINE ENTERED BY TOP-LEVEL CODE. This is the case a floor of
  zero cannot tell apart from a host callback, and a clamp written on the floor
  got it wrong: it set the mode to dmRun, which in a step-only session is the
  debugger going quiet for the rest of the program.

     1  x = callfunc("inner", 5)
     2  println str$(x)
     3  end
     4  function inner(n) local b
     5    b = n + 1
     6    return b
     7  endfunction

  `callfunc` re-enters through CallUserFunc from inside the TOP LEVEL's ExecFrom,
  so `inner` stands at depth 1 over a floor of 0 -- the same floor a host callback
  has. The only difference is that an ExecFrom is live on the PASCAL stack above
  it, and FExecDepth is the count of exactly that: 2 here, 1 for a host call.

    stop 1  B5@1   the armed line, inside inner                 -> daStepOut
    ...            line 6 is the same depth and the same gosub depth: silent
    ...            inner returns; the frame pointer drops to 0
    stop 2  S2@0   the statement after the one that called it          -> daRun
    ...            line 3 is `end` and nothing is pending: silent

  The control that says the clamp still exists is CheckStepOutClamp, whose second
  half steps out of the outermost frame of a HOST call and is silent. }
procedure CheckStepOutOfTopLevelCallfunc;
const
  Fix =
    'x = callfunc("inner", 5)'       + #10 +
    'println str$(x)'                + #10 +
    'end'                            + #10 +
    'function inner(n) local b'      + #10 +
    '  b = n + 1'                    + #10 +
    '  return b'                     + #10 +
    'endfunction'                    + #10;
var
  eng: TPhosphorEngine;
  d: TDrive;
  rc: Integer;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daStepOut, daRun]);
  try
    eng.ArmDebug([5], False);
    rc := eng.Run(Fix);
    CheckInt(rc, 0, 'the top-level callfunc fixture runs to the end');
    CheckStr(d.Trace, Want('B5@1 S2@0'),
             'a step out of a routine callfunc entered from the TOP LEVEL ' +
             'reaches the statement after it: a floor of 0 is not proof the ' +
             'host is above');
    CheckStr(d.Text, '6' + #10, 'and the program still computed its answer');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ AND THE SAME DEFECT ON THE IDIOM THE LANGUAGE REFERENCE TEACHES. `on error call`
  (docs/language-reference.md) routes faults to a function, and that function is
  entered through CallUserFunc from the fault dispatcher with a floor of 0 --
  again the host callback's floor, again with a whole top level above it.

     1  on error call handler
     2  a = 1
     3  z = 1 / 0
     4  println "after"
     5  end
     6  function handler(code, msg$) local q
     7    q = code
     8    return 0
     9  endfunction

  EVERY boundary, derived from the listing: 1@0, 2@0, 3@0 (the statement that
  faults), then the handler's body at depth 1 -- 7@1, 8@1 -- then the resume
  continues after line 3 and gives 4@0 and 5@0.

    stop 1  B7@1   the armed line, the handler's first statement -> daStepOut
    ...            line 8 is the same depth: silent
    ...            the handler returns and the resume stands the VM back at the
                   top level, which is BOTH shallower than the step was asked at
                   and a wholesale frame move -- so the step stops at the next
                   boundary either way
    stop 2  S4@0   the statement after the one that faulted            -> daRun

  BEFORE THE FIX the trace was `B7@1` and nothing else: four more boundaries ran,
  the return to the top level among them, and the debugger reported none of them.
  A step-only session -- stop at entry, then step -- ends there. }
procedure CheckStepOutOfErrorHandler;
const
  Fix =
    'on error call handler'          + #10 +
    'a = 1'                          + #10 +
    'z = 1 / 0'                      + #10 +
    'println "after"'                + #10 +
    'end'                            + #10 +
    'function handler(code, msg$) local q' + #10 +
    '  q = code'                     + #10 +
    '  return 0'                     + #10 +
    'endfunction'                    + #10;
var
  eng: TPhosphorEngine;
  d: TDrive;
  rc: Integer;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daStepOut, daRun]);
  try
    eng.ArmDebug([7], False);
    rc := eng.Run(Fix);
    CheckInt(rc, 0, 'the on-error-call fixture runs to the end');
    CheckStr(d.Trace, Want('B7@1 S4@0'),
             'a step out of an `on error call` handler lands on the statement ' +
             'after the fault -- it does not detach the debugger');
    CheckStr(d.Text, 'after' + #10, 'and the program still produced its output');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ GOSUB IS A CALL AND FFrameSP DOES NOT KNOW IT.

     1  a = 1
     2  gosub sub1
     3  a = a + 1
     4  println str$(a)
     5  end
     6  sub1:
     7  a = a + 10
     8  a = a + 100
     9  return

  Line 6 is a label and carries no boundary; every other line does. `gosub` moves
  FCSP and pushes no activation frame, so on FFrameSP alone lines 7, 8 and 9 are
  "the same level" as line 2 -- and step over on line 2 walked the whole
  subroutine, reporting its statements as if they were the caller's own, while
  step out from inside it was measured against a depth the subroutine SHARES with
  its caller and never became shallower.

  a ends at 1 + 10 + 100 + 1 = 112, whatever the debugger does.

  Three sessions on one fixture, because a rule has three ways to be wrong:

    into, from line 2   B2@0 S7@0 S8@0 S9@0 S3@0
        the control. The subroutine is not invisible -- a stepper that asks to go
        everywhere is taken everywhere -- so step over's silence below is a
        decision and not blindness.
    over, from line 2   B2@0 S3@0
        lines 7, 8 and 9 are DEEPER by the pair (frame, gosub) and silent; after
        `return` pops the entry, line 3 is at the pair the step was asked at and
        carries a different line, so it stops.
    out,  from line 7   B7@0 S3@0
        8 and 9 are at the same pair: silent. Note that line 9 is the `return`
        ITSELF and its boundary runs before the pop, so it is silent too. Then
        the pop makes line 3 strictly shallower and it stops. }
const
  FixGosub =
    'a = 1'                          + #10 +
    'gosub sub1'                     + #10 +
    'a = a + 1'                      + #10 +
    'println str$(a)'                + #10 +
    'end'                            + #10 +
    'sub1:'                          + #10 +
    'a = a + 10'                     + #10 +
    'a = a + 100'                    + #10 +
    'return'                         + #10;

procedure CheckGosubIsACall;
var
  eng: TPhosphorEngine;
  d: TDrive;
  rc: Integer;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daStepInto, daStepInto, daStepInto, daStepInto, daRun]);
  try
    d.GosubTrace := True;
    eng.ArmDebug([2], False);
    rc := eng.Run(FixGosub);
    CheckInt(rc, 0, 'the gosub fixture runs to the end');
    CheckStr(d.Trace, Want('B2@0 S7@0 S8@0 S9@0 S3@0'),
             'step INTO takes the user through the subroutine body: it is ' +
             'reachable, so step over''s silence is a decision');
    CheckStr(d.Text, '112' + #10, 'and the subroutine did its arithmetic');
    { AND THE WINDOW SAYS WHERE THE USER IS. The stops above are line 2 (before
      the gosub runs), lines 7, 8 and 9 (inside the subroutine, one return
      address pending) and line 3 (after the return). DbgFrameDepth is 0 for all
      five -- a gosub pushes no activation -- so a debugger with only that number
      would say "top level" throughout. }
    CheckStr(d.GosubSeen, Want('0 1 1 1 0'),
             'DbgGosubDepth is the other half of where the user is: 0 outside ' +
             'the subroutine and 1 inside it, at a frame depth of 0 throughout');
  finally
    eng.Free;
    d.Free;
  end;

  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daStepOver, daRun]);
  try
    eng.ArmDebug([2], False);
    rc := eng.Run(FixGosub);
    CheckInt(rc, 0, 'the gosub fixture runs to the end under step over');
    CheckStr(d.Trace, Want('B2@0 S3@0'),
             'step over on a `gosub` line does not walk the subroutine');
    CheckStr(d.Text, '112' + #10, 'and the subroutine still ran');
  finally
    eng.Free;
    d.Free;
  end;

  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daStepOut, daRun]);
  try
    eng.ArmDebug([7], False);
    rc := eng.Run(FixGosub);
    CheckInt(rc, 0, 'the gosub fixture runs to the end under step out');
    CheckStr(d.Trace, Want('B7@0 S3@0'),
             'step out from inside a top-level subroutine reaches the line ' +
             'after the `gosub` -- a pending return address is somewhere to go');
    CheckStr(d.Text, '112' + #10, 'and the subroutine still ran');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ THE ARMED SET IS BINARY-SEARCHED, SO ITS ORDER IS AN INVARIANT AND NOTHING SAW
  IT. An editor hands breakpoints over in the order they were clicked. ArmDebug
  sorts and de-duplicates once; without the sort the search silently misses --
  and every fixture in this file happened to arm in ascending order, so the whole
  probe stayed green with the sort disabled.

  FixStep carries boundaries on 1, 2, 3, 4, 6 and 7, with 4 twice (the one-line
  loop body). Arming the set 2, 4, 6 in any order must stop on all three, in EXECUTION
  order: B2@0 B4@0 B4@0 B6@0. Derived from the listing, and the same expectation
  three times -- which is the point, because the set is the same set. }
procedure CheckArmOrder;

  procedure OneOrder(const ALines: array of Integer; const AName: String);
  var
    eng: TPhosphorEngine;
    d: TDrive;
    rc: Integer;
  begin
    eng := TPhosphorEngine.Create();
    d := NewDrive(eng, [daRun]);
    try
      eng.ArmDebug(ALines, False);
      rc := eng.Run(FixStep);
      CheckInt(rc, 0, 'arm order: the fixture runs to the end (' + AName + ')');
      CheckStr(d.Trace, Want('B2@0 B4@0 B4@0 B6@0'),
               'the armed set does not depend on the order it was handed in (' +
               AName + ')');
    finally
      eng.Free;
      d.Free;
    end;
  end;

begin
  OneOrder([2, 4, 6], 'ascending');
  OneOrder([6, 4, 2], 'descending');
  OneOrder([4, 2, 6], 'click order');
  // And the same set with duplicates and an unusable line mixed in.
  OneOrder([6, 2, 6, 4, 0, 2], 'duplicated and with a line 0');
end;

{ A STEP OVER MUST RE-CAPTURE WHERE IT WAS ASKED, and nothing in this file could
  tell. Every other step-over fixture has one statement per line, so a capture
  left at the boundary the FIRST step was asked at still differs from every later
  line and the trace comes out identical.

     1  a = 0
     2  a = 1 : a = 2
     3  println str$(a)
     4  end

  Line 2 carries TWO boundaries, one per statement, at the same line and two
  different pcs. That is the one shape where a stale capture shows:

    stop 1  E1@0   stop at entry                               -> daStepOver
                   captured at line 1
    stop 2  S2@0   the first statement of line 2 -- line differs  -> daStepOver
                   RE-CAPTURED here, at line 2 and this pc
    ...            the second statement of line 2: same line, same depth, a
                   different pc, and not the pc the step was asked at. Silent,
                   which is what makes `a = 1 : a = 2` one step and not two
    stop 3  S3@0                                                -> daStepOver
    stop 4  S4@0                                                -> daRun

  WITHOUT THE RE-CAPTURE the step is still measured against line 1 -- or against
  the "nowhere" a run begins at -- and the second statement of line 2 stops too:
  E1@0 S2@0 S2@0 S3@0 S4@0. }
procedure CheckStepOverRecaptures;
const
  Fix =
    'a = 0'                          + #10 +
    'a = 1 : a = 2'                  + #10 +
    'println str$(a)'                + #10 +
    'end'                            + #10;
var
  eng: TPhosphorEngine;
  d: TDrive;
  rc: Integer;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daStepOver, daStepOver, daStepOver, daRun]);
  try
    eng.ArmDebug([], True);
    rc := eng.Run(Fix);
    CheckInt(rc, 0, 'the colon fixture runs to the end');
    CheckStr(d.Trace, Want('E1@0 S2@0 S3@0 S4@0'),
             'a step over re-captures where it was asked, so two statements on ' +
             'one line are one step');
    CheckStr(d.Text, '2' + #10, 'and both statements on line 2 ran');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ A BREAKPOINT REPORT COSTS WHAT PRINTING ITS PAYLOAD COSTS, and it used to cost
  a great deal more. The charge was TextLenOf, which prices ANY non-string at a
  flat 32 without rendering it -- an estimator whose own header says the
  exactness does not matter "because the caller is deciding whether a growth is
  worth measuring and then measuring the heap itself". True of opAdd, which
  measures afterwards; false here, where the number is SPENT against a threshold.

  TWO PROGRAMS, ONE CEILING, AND THAT IS THE WHOLE ASSERTION:

     the report   trace 1 / a = 1 / b = 22 / c = 333
                  breakpoint "msg", a, b, c / end
     the print    a = 1 / b = 22 / c = 333
                  print "msg" / print a / print b / print c / end

  The payload is 3 + 1 + 2 + 3 = 9 bytes: "msg", then each number as `print`
  writes it (opPrint emits ValToStr and adds nothing -- no leading space, no
  separator). So a ceiling of 9 must admit BOTH and a ceiling of 8 must refuse
  BOTH, and neither program's arithmetic is read off a run.

  UNDER THE OLD CHARGE the report cost 3 + 32 * 3 = 99 and a ceiling of 9 refused
  it -- a program whose real output is nine bytes, refused for ninety-nine. }
procedure CheckBreakpointCostsWhatPrintCosts;
const
  Reported =
    'trace 1'                        + #10 +
    'a = 1'                          + #10 +
    'b = 22'                         + #10 +
    'c = 333'                        + #10 +
    'breakpoint "msg", a, b, c'      + #10 +
    'end'                            + #10;
  Printed =
    'a = 1'                          + #10 +
    'b = 22'                         + #10 +
    'c = 333'                        + #10 +
    'print "msg"'                    + #10 +
    'print a'                        + #10 +
    'print b'                        + #10 +
    'print c'                        + #10 +
    'end'                            + #10;
var
  eng: TPhosphorEngine;
  c: TBpCount;
begin
  eng := TPhosphorEngine.Create();
  c := TBpCount.Create();
  try
    eng.OnBreakpoint := @c.Fired;
    eng.OnOutput := @c.Output;
    eng.MaxOutputBytes := 9;
    CheckInt(eng.Run(Reported), 0,
             'a report whose payload is nine bytes fits a nine-byte ceiling (' +
             eng.ErrorMessage + ')');
    CheckInt(c.N, 1, 'and it was made');
  finally
    eng.Free;
    c.Free;
  end;

  eng := TPhosphorEngine.Create();
  c := TBpCount.Create();
  try
    eng.OnBreakpoint := @c.Fired;
    eng.OnOutput := @c.Output;
    eng.MaxOutputBytes := 8;
    CheckInt(eng.Run(Reported), 5,
             'and one byte less refuses it, at the breakpoint''s line');
    CheckInt(c.N, 0, 'with the report not made at all');
  finally
    eng.Free;
    c.Free;
  end;

  { The second path to the same number: the same payload through PRINT, which
    charges MaxOutputBytes by a different route in a different case arm. }
  eng := TPhosphorEngine.Create();
  c := TBpCount.Create();
  try
    eng.OnOutput := @c.Output;
    eng.MaxOutputBytes := 9;
    CheckInt(eng.Run(Printed), 0,
             'printing the same payload also fits nine bytes (' +
             eng.ErrorMessage + ')');
  finally
    eng.Free;
    c.Free;
  end;

  eng := TPhosphorEngine.Create();
  c := TBpCount.Create();
  try
    eng.OnOutput := @c.Output;
    eng.MaxOutputBytes := 8;
    CheckInt(eng.Run(Printed), 7,
             'and one byte less refuses it too, at the last print');
  finally
    eng.Free;
    c.Free;
  end;
end;

{ THE MEMORY CEILING IS NOT ESCAPABLE THROUGH THE SEAM, and it was.

  A park gives the script back the heap the HOST added while it was stopped --
  which is right for an adapter buffering a stack frame, and wrong the moment the
  host spends the park running the SCRIPT. TPhosphorEngine.CallFunction on a
  stopped frame is exactly what a watch expression is, and crediting that window
  handed a program a way past its own ceiling: ask the debugger to do the
  allocation.

     1  armed = 1
     2  z = grow2(2000000)
     3  println str$(z)
     4  end
     5  function grow1(n)
     6    a$ = string$(n, "x")
     7    return len(a$)
     8  endfunction
     9  function grow2(n)
    10    b$ = string$(n, "x")
    11    return len(b$)
    12  endfunction

  a$ and b$ are undeclared inside their functions, so both are GLOBALS and both
  stay allocated. The ceiling is 4 MB. The host stops on line 1 and evaluates
  grow1(3000000); the script then runs grow2(2000000). Retained together that is
  5 000 000 bytes against a 4 194 304-byte ceiling, so the run must be refused --
  and it is refused for the same reason it would be if the script had asked for
  both itself, which is the point.

  THE CONTROL IS CheckParkedHeap, one test above: a host that retains 32 MB
  across a stop WITHOUT running any script code is still credited every byte. A
  fix that simply stopped crediting would break that one. }
procedure CheckMemoryCeilingThroughSeam;
const
  Fix =
    'end'                            + #10 +
    'function grow1(n)'              + #10 +
    '  a$ = string$(n, 120)'         + #10 +
    '  return len(a$)'               + #10 +
    'endfunction'                    + #10 +
    'function grow2(n)'              + #10 +
    '  hold = 1'                     + #10 +
    '  b$ = string$(n, 120)'         + #10 +
    '  return len(b$)'               + #10 +
    'endfunction'                    + #10;
var
  eng: TPhosphorEngine;
  d: TDrive;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daRun]);
  try
    d.ReentryAtStop := 1;
    d.ReentryName := 'grow1';
    d.ReentryArg := 3000000;
    eng.MaxMemoryBytes := 4 * 1024 * 1024;
    CheckInt(eng.Prepare(Fix), 0, 'the two-globals fixture prepares');
    eng.ArmDebug([7], False);
    eng.CallFunction('grow2', [ValInt(2000000)]);
    CheckStr(d.Reentered, '3000000',
             'the host really did evaluate the script''s own function from ' +
             'inside its stop');
    Report(Pos('memory limit exceeded', eng.ErrorMessage) > 0,
           'memory the host made the SCRIPT allocate while parked is still the ' +
           'script''s: the ceiling refuses it (' + eng.ErrorMessage + ')');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ WHAT THE SEAM CAN REACH, MEASURED AT THE DOOR THAT HAD NOTHING.

  TPhosphorDebugProc is `of object`, so `Self` inside it is the HOST's adapter.
  Three doc blocks said the seam "gets the VM as Self" and one of them was the
  stated reason for not offering the live VM at all -- so through
  TPhosphorEngine.Run, the door an embedder reaches for first, the work order's
  own goal (the call stack and the variables readable while stopped) was
  unreachable: PreparedVM is nil unless Prepare built it, and Run keeps its VM in
  a local.

  DebugVM is that VM, for the exact region that is executing.

     1  answer = 41
     2  answer = answer + 1
     3  println str$(answer)

  Armed on line 3: at that stop `answer` holds 42, by arithmetic and not by a
  run, and it is read BY NAME through DebugVM -- which is the whole window, since
  the names come from DebugVM.DbgProgram. }
procedure CheckSeamReachesVM;
const
  Fix =
    'answer = 41'                    + #10 +
    'answer = answer + 1'            + #10 +
    'println str$(answer)'           + #10;
var
  eng: TPhosphorEngine;
  d: TDrive;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daRun]);
  try
    d.GlobalWanted := 'answer';
    eng.ArmDebug([3], False);
    CheckInt(eng.Run(Fix), 0, 'the named-global fixture runs to the end');
    CheckInt(d.VMSeen, 1,
             'through Run the seam reaches the executing VM: DebugVM is not nil');
    CheckInt(d.PreparedSeen, 0,
             'and PreparedVM is nil there, which is what used to leave a host ' +
             'stopping through Run with nothing to read');
    CheckStr(d.GlobalText, Want('42'),
             'so a global is readable BY NAME from inside the stop');
    CheckInt(d.FrameDepthSeen, 0, 'and the VM agrees about the frame depth');
    Report(eng.DebugVM = nil,
           'and it is nil again once the run is over: it is never a pointer to ' +
           'hold');
  finally
    eng.Free;
    d.Free;
  end;

  { The prepared door answers the SAME object, so a host writes one line of code
    for both. Asserted by identity, not by "both are non-nil". }
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daRun]);
  try
    d.GlobalWanted := 'answer';
    eng.ArmDebug([3], False);
    CheckInt(eng.Prepare(Fix), 0, 'the same fixture prepares');
    CheckInt(d.VMSeen, 1, 'and the seam reaches a VM through Prepare too');
    CheckInt(d.PreparedSeen, 1, 'where PreparedVM answers as well');
    Report(eng.DebugVM = nil, 'DebugVM is nil between calls on a prepared VM');
    Report(eng.PreparedVM <> nil, 'while PreparedVM keeps answering');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ A DEBUGGER'S STOP INSIDE A HOST CALL, AND WHAT THE ENGINE SAYS ABOUT IT.

  `daStop` ends the run the way `end` does, and through the TOP-LEVEL door that
  is exactly right: the session stays closed and CallUserFunc refuses by name.
  Through the HOST's own door -- Prepare, then CallFunction, which is what a GUI
  dispatching a click into BASIC actually uses -- the same two lines said two
  false things:

    * the stopped call answered 0 with LastError still NoError, which a host
      cannot tell from a function that returned zero; and
    * every later call was refused with "the script has run END; this session is
      over" -- a sentence a host puts in FRONT OF A USER about a script that ran
      no such statement.

  The fixture contains exactly one `end`, on line 1, and it belongs to the top
  level, which finished normally. The call that is refused never went near it.

    1  end             <- the top level: one statement, one boundary
    2  function f(n)   <- a header is not a statement and carries no boundary
    3    return n + 1  <- the armed line, the only boundary inside f
    4  endfunction     <- a terminator carries none either

  So ArmDebug([3]) stops once per CALL to f and never during Prepare, and the
  expected trace of a session that calls f once is exactly `B3@1`: one
  breakpoint stop, on line 3, one frame deep.

  WHAT IS NOT CHANGED HERE: that a debugger's stop closes the session. That was
  decided when FHaltedByDebug was written and EndOfTopLevel was taught to leave
  it alone -- a run the host cut short has an unfinished top level, and opening
  a session on it would say nothing. Only what the engine SAYS about it. }
procedure CheckStopInsideHostCall;
const
  Fix =
    'end'                            + #10 +
    'function f(n)'                  + #10 +
    '  return n + 1'                 + #10 +
    'endfunction'                    + #10;
  EndFix =
    'x = 1'                          + #10 +
    'end'                            + #10 +
    'function g(n)'                  + #10 +
    '  return n + 1'                 + #10 +
    'endfunction'                    + #10;
var
  eng: TPhosphorEngine;
  d: TDrive;
  v: TValue;
  msg1, msg2: String;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daStop]);
  try
    eng.ArmDebug([3], False);
    CheckInt(eng.Prepare(Fix), 0, 'stop-in-call: the fixture prepares');
    CheckStr(d.Trace, '',
             'stop-in-call: and Prepare itself stops at nothing -- line 3 is ' +
             'inside f, which the top level never calls');

    v := eng.CallFunction('f', [ValInt(41)]);
    msg1 := eng.ErrorMessage;
    CheckStr(d.Trace, Want('B3@1'),
             'stop-in-call: the host call stops once, on the armed line, one ' +
             'frame deep');
    CheckStr(ValToStr(v), '0',
             'stop-in-call: a stopped call has no return value to give, and 0 ' +
             'is what it hands back');
    CheckStr(msg1, 'a debugger stopped this call before it returned',
             'stop-in-call: AND IT SAYS SO. It used to answer 0 with no error ' +
             'at all, which is a successful call returning zero');

    v := eng.CallFunction('f', [ValInt(1)]);
    msg2 := eng.ErrorMessage;
    CheckStr(ValToStr(v), '0', 'stop-in-call: the second call runs nothing');
    CheckStr(msg2, 'a debugger stopped this session -- Prepare it again ' +
                   'before calling into it',
             'stop-in-call: the session is closed, and the refusal no longer ' +
             'blames an END the script never ran');
    Report(eng.Halted, 'stop-in-call: the session really is closed');
    CheckStr(d.Trace, Want('B3@1'),
             'stop-in-call: and the refused call never reached a boundary, so ' +
             'the trace did not grow');
  finally
    eng.Free;
    d.Free;
  end;

  { THE CONTROL, and it is what keeps the branch above from being a rename. A
    script that really DID run `end` still gets the END sentence -- so the two
    messages are told apart by which thing happened, and not by which build. No
    debugger is attached here at all. }
  eng := TPhosphorEngine.Create();
  try
    eng.OnOutput := nil;
    CheckInt(eng.Prepare(EndFix), 0, 'the END control prepares');
    eng.CallFunction('g', [ValInt(1)]);
    CheckStr(eng.ErrorMessage, '',
             'the END control: a plain call on a finished top level works, ' +
             'because EndOfTopLevel cleared the flag `end` set');
  finally
    eng.Free;
  end;

  { THE OTHER HALF OF THE FExecDepth TERM, and it is a control and not a repeat.

    A stop taken inside a SCRIPT-initiated callfunc must still travel as the
    clean halt `end` is, because the interpreter is in the middle of a statement
    that is still holding a value stack: opCall reads FHalted (`if FHalted then
    Exit(True)`) and unwinds the whole run the way it does for `end` inside a
    callfunc. Turning it into a peRuntime there would make a debugger's stop a
    FAULT in the middle of somebody's expression.

      1  a = callfunc("f", 41)
      2  println str$(a)          <- never runs: the stop is final
      3  end
      4  function f(n)
      5    return n + 1           <- armed; the host answers daStop, one frame deep
      6  endfunction

    rc 0, no message, no output -- and without the FExecDepth term this program
    reports an error instead. }
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daStop]);
  try
    eng.ArmDebug([5], False);
    CheckInt(eng.Run(
      'a = callfunc("f", 41)'        + #10 +
      'println str$(a)'              + #10 +
      'end'                          + #10 +
      'function f(n)'                + #10 +
      '  return n + 1'               + #10 +
      'endfunction'                  + #10), 0,
      'stop-in-callfunc: a stop inside a SCRIPT-initiated callfunc is the clean ' +
      'end `end` is, not an error in the middle of an expression');
    CheckStr(eng.ErrorMessage, '',
             'stop-in-callfunc: and it invents no message either');
    CheckStr(d.Trace, Want('B5@1'), 'stop-in-callfunc: one stop, one frame deep');
    CheckStr(d.Text, '',
             'stop-in-callfunc: the statement after the callfunc never ran');
  finally
    eng.Free;
    d.Free;
  end;

  { And the same script halted by `end` a SECOND time -- from inside a call --
    still reports END, because that is what happened. This is the branch's other
    side: FHaltedByDebug is False here and the message must not have moved. }
  eng := TPhosphorEngine.Create();
  try
    eng.OnOutput := nil;
    CheckInt(eng.Prepare(
      'end'                          + #10 +
      'function h()'                 + #10 +
      '  end'                        + #10 +
      'endfunction'                  + #10), 0, 'the END-inside-a-call control prepares');
    eng.CallFunction('h', []);
    eng.CallFunction('h', []);
    CheckStr(eng.ErrorMessage,
             'the script has run END; this session is over -- Prepare it ' +
             'again before calling into it',
             'the END control: a script that ran END is still told so, word ' +
             'for word');
  finally
    eng.Free;
  end;
end;

{ THE ARMING SURVIVES A RUN AND THE STEP DOES NOT -- ASSERTED, NOT ASSERTED-TO.

  DebugBeginRun's own header says that sentence, and until this check nothing in
  the tree held it: deleting `FDbgMode := dmRun` from that routine passed every
  probe on both operating systems. It is the same class as the two guards inside
  StoppableLines that this piece was told to close -- an invariant stated in
  prose with no way to tell when it stops being true.

  IT NEEDS A VM THAT IS REUSED, which is why the obvious shape does not test it:
  TPhosphorEngine.Run builds a fresh TPhosphorVM per call and frees it, so a
  field could not survive from one Run to the next however DebugBeginRun were
  written. The two doors that reuse one are the REPL, where RunFrom starts each
  line, and Prepare-then-CallFunction. Both are crossed below.

  (1) THE REPL. Each line is a RunFrom on the session's VM.
        line 1: `a = 1`   -- armed, so it stops, and the host answers step-into
        line 2: `b = 2`   -- a new statement at line 2, NOT armed
      With the reset, line 2 runs silently: the arming says nothing about line 2
      and the step from the previous line means nothing here. Without it, the
      pending dmStepInto sees a different line and stops -- so the trace grows a
      stop the host never asked for, in a line it never debugged.

  (2) THE HOST CALL. CallUserFunc is entered by two quite different callers and
      the answer differs by which:
        * a SCRIPT-initiated `callfunc` or `on error call` re-enters from inside
          a running ExecFrom, and a step in progress must carry straight through
          it -- CheckStepOutThroughCallfunc and CheckStepOutOfErrorHandler are
          that half, and they would break if this reset fired there;
        * a HOST-initiated CallFunction is the start of an execution of its own,
          the way Run is. TPhosphorEngine.CallFunction already says so for the
          ceilings ("a run of its own as far as the ceilings go" -- it calls
          BudgetBegin), and the step state is now reset on the same footing.
      FExecDepth is what tells them apart: it is 0 on the way into a host call
      and 1 or more on the way into a re-entrant one.

      The fixture leaves a step pending on purpose:
        1  x = 1          <- armed; the host answers step-into
        2  end            <- the step lands here; the host answers step-into
                             AGAIN, so dmStepInto is pending when the run ends
        3  function f(n)
        4    return n + 1 <- not armed
        5  endfunction
      So Prepare's trace is exactly `B1@0 S2@0`, and the call that follows must
      add NOTHING. Without the reset it adds `S4@1`: a stop in a line no one
      armed, from a step asked in a run that is over. }
procedure CheckStepDoesNotSurviveARun;
const
  Fix =
    'x = 1'                          + #10 +
    'end'                            + #10 +
    'function f(n)'                  + #10 +
    '  return n + 1'                 + #10 +
    'endfunction'                    + #10;
var
  eng: TPhosphorEngine;
  d: TDrive;
  v: TValue;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daStepInto]);
  try
    eng.ArmDebug([1], False);
    CheckInt(eng.ReplRun('a = 1'), 0, 'step-not-across-runs: the first REPL line runs');
    CheckStr(d.Trace, 'B1@0',
             'step-not-across-runs: it stops on the armed line and the host ' +
             'steps');
    CheckInt(eng.ReplRun('b = 2'), 0, 'step-not-across-runs: the second line runs');
    CheckStr(d.Trace, Want('B1@0'),
             'step-not-across-runs: and says NOTHING -- the arming survived the ' +
             'line boundary and the step did not');
  finally
    eng.Free;
    d.Free;
  end;

  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daStepInto]);
  try
    eng.ArmDebug([1], False);
    CheckInt(eng.Prepare(Fix), 0, 'step-not-across-runs: the host-call fixture prepares');
    CheckStr(d.Trace, 'B1@0 S2@0',
             'step-not-across-runs: armed, then one step, and a step-into is ' +
             'left pending when the top level ends');
    v := eng.CallFunction('f', [ValInt(41)]);
    CheckStr(ValToStr(v), '42', 'step-not-across-runs: the host call answers 41 + 1');
    CheckStr(d.Trace, Want('B1@0 S2@0'),
             'step-not-across-runs: and the HOST door reset it too -- a step ' +
             'asked in a run that is over does not stop a call the host makes');
  finally
    eng.Free;
    d.Free;
  end;

  { THE CONTROL FOR THE OTHER HALF: a step must still travel THROUGH a
    script-initiated callfunc, which is the same routine entered from inside a
    run. Without this, "reset at CallUserFunc" could be written with no
    FExecDepth term at all and the assertion above would still pass.

      1  y = callfunc("f", 41)   <- armed; the host answers step-into
      2  end
      3  function f(n)
      4    return n + 1          <- step-into lands INSIDE f: the callfunc is a
      5  endfunction                re-entry, not a new run

    Boundary by boundary: line 1, armed, at depth 0; then f's only statement at
    line 4 and depth 1; then -- the callfunc having returned into the middle of
    line 1, and line 1 having finished -- line 2 at depth 0, where `end` ends the
    top level. `B1@0 S4@1 S2@0`, and the middle stop being one frame deep is the
    whole point. }
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daStepInto]);
  try
    eng.ArmDebug([1], False);
    CheckInt(eng.Prepare(
      'y = callfunc("f", 41)'        + #10 +
      'end'                          + #10 +
      'function f(n)'                + #10 +
      '  return n + 1'               + #10 +
      'endfunction'                  + #10), 0,
      'step-not-across-runs: the callfunc control prepares');
    CheckStr(d.Trace, Want('B1@0 S4@1 S2@0'),
             'step-not-across-runs: a SCRIPT-initiated callfunc is a re-entry, ' +
             'not a new run, so the step carries into it AND back out of it');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ THE CLAMP'S FLOOR IS THE DOOR'S, AND THE DOORS HAVE DIFFERENT ONES.

  ExecFrom is given a frame level to stop at, and the clamp turns a step out into
  `continue` at that level plus one: the outermost frame of this activation, the
  one with no shallower BASIC to return to. Through Run that level is -1, so the
  floor is 0 -- the top level of a program. Through a HOST CallFunction it is the
  frame level the VM was resting at, so the floor is 1: the frame below the call
  belongs to the host's Pascal.

  WRITING THE FLOOR AS A CONSTANT 0 IS CORRECT AT ONE DOOR AND WRONG AT THE
  OTHER, and for a long time nothing could tell -- including a generated sweep of
  two hundred programs, because every one of them went through Run. It is not
  even easy to see at the right door: at the call's outermost frame, `continue`
  and "a dmStepOut against a depth this activation can never go below" both mean
  silence for the rest of the call, so the two spellings agree on every program
  that does not move its frame pointer wholesale.

  THE ONE SHAPE THAT SEPARATES THEM is a fault dispatched INSIDE the call, where
  DebugRebase promotes a pending step and leaves dmRun alone. It has to be a
  handler the CALLED FUNCTION installed: a handler installed by the top level
  sits at frame 0, and the fault dispatcher requires FErrHandlerFrameSP >
  AStopFrameSP -- its own re-entrancy floor, and the same idea as this clamp --
  so a top-level handler does not catch a fault inside a host-entered call at
  all. That is pre-existing and deliberate; it is recorded here because it is why
  the fixture looks the way it does.

    1  end
    2  function f1(n) local t
    3    on error call oops   <- installed by THIS activation, at frame 1
    4    t = 0                <- armed; the host answers daStepOut, at frame 1
    5    zz = 1 / 0           <- faults; the handler runs at frame 2
    6    t = n + 1            <- and the resume comes back here
    7    return t
    8  endfunction
    9  function oops(code, msg$) local q
   10    q = code
   11    return 0
   12  endfunction

  Boundary by boundary: line 4 at frame 1 is the only armed one, and the step out
  asked there is at the floor, so it is `continue` and NOTHING else stops. The
  call answers 3 + 1. With the floor written as 0 the same session stops again,
  in the error handler, at line 10 and frame 2 -- a debugger stopping in a
  handler the user never asked to see, out of a step it was told to treat as
  continue. }
procedure CheckStepOutClampAtTheHostDoor;
const
  Fix =
    'end'                            + #10 +
    'function f1(n) local t'         + #10 +
    '  on error call oops'           + #10 +
    '  t = 0'                        + #10 +
    '  zz = 1 / 0'                   + #10 +
    '  t = n + 1'                    + #10 +
    '  return t'                     + #10 +
    'endfunction'                    + #10 +
    'function oops(code, msg$) local q' + #10 +
    '  q = code'                     + #10 +
    '  return 0'                     + #10 +
    'endfunction'                    + #10;
  Deep =
    'end'                            + #10 +
    'function f1(n) local t'         + #10 +
    '  t = f2(n)'                    + #10 +
    '  return t + 1'                 + #10 +
    'endfunction'                    + #10 +
    'function f2(n) local u'         + #10 +
    '  u = n + 1'                    + #10 +
    '  return u'                     + #10 +
    'endfunction'                    + #10;
var
  eng: TPhosphorEngine;
  d: TDrive;
  v: TValue;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daStepOut]);
  try
    CheckInt(eng.Prepare(Fix), 0, 'host-door clamp: the fixture prepares');
    eng.ArmDebug([4], False);
    v := eng.CallFunction('f1', [ValInt(3)]);
    CheckStr(d.Trace, Want('B4@1'),
             'host-door clamp: a step out at the OUTERMOST frame of a host call ' +
             'is `continue`, and the fault that follows does not resurrect it');
    CheckStr(ValToStr(v), '4', 'host-door clamp: and the call still answers 3 + 1');
    CheckStr(eng.ErrorMessage, '',
             'host-door clamp: the handler the function installed took the fault');
  finally
    eng.Free;
    d.Free;
  end;

  { THE OTHER DIRECTION, and without it a clamp that fires at every depth would
    pass the assertion above. f1 calls f2; a step out asked INSIDE f2 is one
    frame above the floor, so it must land back in f1 -- at line 4, the statement
    after the call, at frame 1.

      1  end
      2  function f1(n) local t
      3    t = f2(n)     <- f2 is entered from here
      4    return t + 1  <- where the step out lands
      5  endfunction
      6  function f2(n) local u
      7    u = n + 1     <- armed; the host answers daStepOut, at frame 2
      8    return u
      9  endfunction }
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daStepOut]);
  try
    CheckInt(eng.Prepare(Deep), 0, 'host-door clamp: the two-deep fixture prepares');
    eng.ArmDebug([7], False);
    v := eng.CallFunction('f1', [ValInt(3)]);
    CheckStr(d.Trace, Want('B7@2 S4@1'),
             'host-door clamp: and a step out from one frame ABOVE the floor is ' +
             'not clamped -- it lands in the caller');
    CheckStr(ValToStr(v), '5', 'host-door clamp: 3 + 1 + 1');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ ONE SCRIPT, ONE CEILING, ONE ANSWER -- WHATEVER THE HOST INSTALLED.

  MaxOutputBytes is a ceiling on what the SCRIPT produces, not on what the host
  chooses to write: PRINT is charged whether or not OnOutput is assigned, and
  DebugPoll's own header says so in as many words. The breakpoint charge was
  written inside `if FTrace and Assigned(OnBreakpoint)`, so it was the one half
  of that ceiling that asked who was listening -- and the same script under the
  same ceiling then got two different exit codes from two hosts, one of which
  had merely not installed a reporter.

  Both halves are asserted here against the SAME payload, so the two numbers are
  compared rather than each restated:

    trace 1
    breakpoint "msg", 1, 22, 333     <- 3 + 1 + 2 + 3 = 9 bytes of payload
    print "msg" + "1" + "22" + "333" <- the same 9 bytes through the other seam

  A ceiling of 9 admits either; a ceiling of 8 refuses either; and that verdict
  does not move when the host leaves a seam nil. }
{ Runs ASrc under ACap and answers the VERDICT as one string: 'ok' or the
  engine's own refusal, with the line it refused at. TPhosphorEngine.Run answers
  an error LINE and not an exit code, so a bare integer here would have been two
  different quantities in one column -- and the message is what makes the
  refusal the OUTPUT ceiling's rather than any other. }
function RunCharged(const ASrc: String; ACap: Int64; AInstall: Boolean;
                    out AReports: Integer): String;
var
  eng: TPhosphorEngine;
  c: TBpCount;
  line: Integer;
begin
  eng := TPhosphorEngine.Create();
  c := TBpCount.Create();
  try
    eng.MaxOutputBytes := ACap;
    eng.OnOutput := nil;              // PRINT is charged whether or not this is set
    if AInstall then eng.OnBreakpoint := @c.Fired;
    line := eng.Run(ASrc);
    AReports := c.N;
    if line = 0 then Result := 'ok'
    else Result := 'line ' + IntToStr(line) + ': ' + eng.ErrorMessage;
  finally
    eng.Free;
    c.Free;
  end;
end;

procedure CheckChargeDoesNotAskWhoIsListening;
const
  BpSrc =
    'trace 1'                        + #10 +
    'breakpoint "msg", 1, 22, 333'   + #10;
  PrintSrc =
    'print "msg" + "1" + "22" + "333"' + #10;
  { The refusal, spelled once. Both halves of the ceiling raise the same
    peLimit with the same text, which is itself part of the claim. }
  Refused8 = 'output limit exceeded (8 bytes)';
var
  reports: Integer;
begin
  CheckStr(RunCharged(BpSrc, 9, True, reports), 'ok',
           'charge-host-independent: 9 bytes of payload fit a 9-byte ceiling');
  CheckInt(reports, 1, 'charge-host-independent: and the report was made');
  CheckStr(RunCharged(BpSrc, 8, True, reports), 'line 2: ' + Refused8,
           'charge-host-independent: and are refused by an 8-byte one, at the ' +
           'breakpoint''s own line');
  CheckInt(reports, 0,
           'charge-host-independent: a report that crosses the ceiling is not ' +
           'made at all -- half a frame on a debugger''s stream is worse than none');

  CheckStr(RunCharged(BpSrc, 9, False, reports), 'ok',
           'charge-host-independent: the same script with no reporter installed');
  CheckInt(reports, 0, 'charge-host-independent: and nothing was reported, as asked');
  CheckStr(RunCharged(BpSrc, 8, False, reports), Want('line 2: ' + Refused8),
           'charge-host-independent: AND THE SAME 8-BYTE CEILING STILL REFUSES ' +
           'IT. A ceiling that asks which seams the host installed is two ' +
           'ceilings wearing one name');

  { The other half of the same ceiling, reached through a different case arm
    (opPrint's EmitOutput), so the nine above is derived twice rather than
    restated -- and with OnOutput nil, which is the same "nobody is listening"
    the breakpoint half used to be excused by. }
  CheckStr(RunCharged(PrintSrc, 9, False, reports), 'ok',
           'charge-host-independent: PRINT of the same nine bytes fits nine');
  CheckStr(RunCharged(PrintSrc, 8, False, reports), Want('line 1: ' + Refused8),
           'charge-host-independent: and is refused by eight, with OnOutput nil');
end;

{ ------------------------------------------------------------------------- }

{ THE WINDOW IS GIVEN BACK AS IT GOES, AND WHAT THE HOST DOES INSIDE IT IS
  JUDGED AGAINST THE CORRECTED CLOCK.

  CheckParkedClock and CheckParkedBudget above assert the CONTINUATION: park,
  return, and the script keeps running. They are both green against a correction
  written once, in the seam's finally -- and that correction leaves everything
  the host does INSIDE the window judged against the clock the run started with.
  Re-entering the engine from in there is what a watch expression IS, and it is
  the use docs/embedding.md names by hand.

     1  end
     2  function burn(n) local i, s
     3    s = 0
     4    for i = 1 to n
     5      s = s + i
     6    next
     7    return s
     8  endfunction
     9  function slib(n) local i, t$
    10    t$ = ""
    11    for i = 1 to n
    12      t$ = string$(40, 65)
    13    next
    14    return len(t$)
    15  endfunction
    16  function host(n)
    17    return n + 1
    18  endfunction

  TWO LEDGERS, TWO DIRECTIONS EACH, and the two are separated by which function
  the watch evaluates: `burn` executes instructions and nothing else, so only the
  VM's own wall clock can refuse it; `slib` runs twenty thousand library calls
  over four instructions a turn, so only RULE 1's budget clock can. A fix that
  corrected one and not the other would pass half of this.

  EVERY EXPECTED VALUE IS ARITHMETIC WRITTEN OUT HERE, not read off a run:
  burn(n) sums 1..n, so burn(50000) is 50000 * 50001 / 2 = 1250025000, and slib
  answers len(string$(40, 65)) = 40 whatever n is.

  THE SIZES ARE MEASURED, NOT GUESSED. burn(50000) is 62 ms on this machine and
  slib(20000) is 47 ms, both well inside the 400 ms ceiling, so a cell that
  fails is failing about the correction and not about being slow. The next
  fixture's first draft used a loop I had assumed was "milliseconds" and which
  measured 422 ms; its control failed, which is the only reason I know. }
procedure CheckWatchAfterAPause;
const
  Fix =
    'end'                              + #10 +
    'function burn(n) local i, s'      + #10 +
    '  s = 0'                          + #10 +
    '  for i = 1 to n'                 + #10 +
    '    s = s + i'                    + #10 +
    '  next'                           + #10 +
    '  return s'                       + #10 +
    'endfunction'                      + #10 +
    'function slib(n) local i, t$'     + #10 +
    '  t$ = ""'                        + #10 +
    '  for i = 1 to n'                 + #10 +
    '    t$ = string$(40, 65)'         + #10 +
    '  next'                           + #10 +
    '  return len(t$)'                 + #10 +
    'endfunction'                      + #10 +
    'function host(n)'                 + #10 +
    '  return n + 1'                   + #10 +
    'endfunction'                      + #10;

  { A watch, under a ceiling, with or without a person in front of it. Answers
    the evaluation's value and the engine's word for it as ONE string, so "it
    returned nothing" and "it returned nothing AND said why" cannot be confused
    -- which is the mistake a previous round made by comparing an integer it had
    called an exit code and which was a line number. }
  function Watched(const AName: String; AArg: Int64; AParkMs: Integer): String;
  var
    eng: TPhosphorEngine;
    d: TDrive;
  begin
    eng := TPhosphorEngine.Create();
    d := NewDrive(eng, [daRun]);
    try
      d.ReentryAtStop := 1;
      d.ReentryName := AName;
      d.ReentryArg := AArg;
      d.ParkBeforeEvalMs := AParkMs;
      eng.TimeoutMs := 400;
      if eng.Prepare(Fix) <> 0 then Exit('the fixture did not prepare');
      eng.ArmDebug([], True);            // stop once, at the entry of the next call
      eng.CallFunction('host', [ValInt(41)]);
      Result := d.Reentered;
      if d.ReenteredErr <> '' then Result := Result + ' -- ' + d.ReenteredErr;
      if d.Trace <> 'E17@1' then Result := Result + ' [trace ' + d.Trace + ']';
    finally
      eng.Free;
      d.Free;
    end;
  end;

begin
  { LEDGER ONE. The trace is checked inside Watched and appended only when it is
    wrong, so a cell that stopped somewhere else says so instead of quietly
    measuring a different program. Stop-at-entry fires at the first boundary the
    called function carries, which for `host` is line 17, one frame in. }
  CheckStr(Watched('burn', 50000, 0), '1250025000',
           'watch-after-pause: a watch expression with nobody waiting in front ' +
           'of it answers');
  CheckStr(Watched('burn', 50000, 700), '1250025000',
           'watch-after-pause: AND THE SAME WATCH AFTER A 700 ms PAUSE UNDER A ' +
           '400 ms CEILING. A person reading the stack is not the script''s time');
  { LEDGER TWO, which is a different clock in a different unit with a different
    sentence, and the first version of the correction missed it for the same
    reason it missed this one. }
  CheckStr(Watched('slib', 20000, 0), '40',
           'watch-after-pause: a watch that makes twenty thousand LIBRARY calls ' +
           'answers');
  CheckStr(Watched('slib', 20000, 700), '40',
           'watch-after-pause: and still does after the pause -- RULE 1''s budget ' +
           'clock is the second ledger and it is corrected too');
end;

{ WHAT THE HOST SPENDS IDLE IS GIVEN BACK; WHAT IT SPENDS RUNNING SCRIPT IS NOT.

  The same seven hundred milliseconds inside one window, spent two ways, under
  one 300 ms ceiling. Idle, the script keeps its budget and finishes. Spent
  EVALUATING, the budget is gone and the continuation is refused -- because a
  watch expression really runs the script's own code, and its milliseconds are
  the script's exactly as its bytes are (CheckMemoryCeilingThroughSeam, above,
  is the same rule on the heap) and its instructions are.

  THIS IS ALSO THE ONLY ASSERTION THAT HOLDS THE RE-MARK ON THE WAY OUT of a
  re-entrant call. Without it the credit taken when the window finally closes
  reaches back past the evaluation and hands its time back too, and the third
  cell below -- park, evaluate, park -- completes where it must be refused.

     1  end
     2  function spin(n) local i, s
     3    s = 0
     4    for i = 1 to n
     5      s = s + 1
     6    next
     7    println "done"
     8    return s
     9  endfunction

  AND IT IS JUDGED ON WHAT THE OUTER PROGRAM PRINTED, not on the engine's error
  slot. The first draft read eng.ErrorMessage after the outer call and PASSED ON
  BOTH SIDES of the defect: there is one error slot per engine, the host makes
  two calls, and the INNER one had already filled it -- so a cell whose outer run
  completed reported the watch's refusal as its own. A test that passes for the
  wrong reason is not a confirmation. The verdict below is the returned value and
  the bytes the script pushed through OnOutput, which are the program's own and
  belong to no other call.

  DERIVED, NOT TIMED. The evaluation asks for two billion iterations, which no
  machine finishes inside 300 ms, so it is refused BY ITS OWN CEILING and at
  least 301 ms of script execution has happened when it returns -- whatever the
  hardware. The outer call is 20000 iterations, MEASURED at 16 ms here -- the
  first draft asked for 400000, which is 422 ms and over the ceiling on its own,
  and its control said so. }
procedure CheckEvaluationIsChargedNotCredited;
const
  Fix =
    'end'                              + #10 +
    'function spin(n) local i, s'      + #10 +
    '  s = 0'                          + #10 +
    '  for i = 1 to n'                 + #10 +
    '    s = s + 1'                    + #10 +
    '  next'                           + #10 +
    '  println "done"'                 + #10 +
    '  return s'                       + #10 +
    'endfunction'                      + #10 +
    'function warm(n) local z'         + #10 +
    '  z = pause(0.25)'                + #10 +
    '  return callfunc("noop", n)'     + #10 +
    'endfunction'                      + #10 +
    'function noop(n)'                 + #10 +
    '  return n'                       + #10 +
    'endfunction'                      + #10 +
    'function slow(n) local z'         + #10 +
    '  z = pause(0.2)'                 + #10 +
    '  println "done"'                 + #10 +
    '  return n'                       + #10 +
    'endfunction'                      + #10;

  { Answers what became of the OUTER call, as its own value and its own output. }
  function Outer(ABefore, AAfter: Integer; const AEval: String;
                 out AEvalErr: String): String;
  var
    eng: TPhosphorEngine;
    d: TDrive;
    v: TValue;
  begin
    eng := TPhosphorEngine.Create();
    d := NewDrive(eng, [daRun]);
    try
      AEvalErr := '';
      if AEval <> '' then
      begin
        d.ReentryAtStop := 1;
        d.ReentryName := AEval;
        d.ReentryArg := 2000000000;
      end;
      d.ParkBeforeEvalMs := ABefore;
      d.ParkAfterEvalMs := AAfter;
      // With no evaluation there is no re-entry stop to hang the parks on, so
      // the plain one is used and the two halves are added together.
      if AEval = '' then d.SleepMsAtStop := ABefore + AAfter;
      eng.TimeoutMs := 300;
      if eng.Prepare(Fix) <> 0 then Exit('the fixture did not prepare');
      eng.ArmDebug([], True);
      v := eng.CallFunction('spin', [ValInt(20000)]);
      AEvalErr := d.ReenteredErr;
      Result := ValToStr(v) + '/' + StringReplace(d.Text, #10, '', [rfReplaceAll]);
    finally
      eng.Free;
      d.Free;
    end;
  end;

  { The same shape under the INSTRUCTION ceiling instead of the clock. No park:
    parking spends no instructions, and what is being asked here is whether the
    evaluation's own instructions land on the script's ledger. }
  function OuterSteps(ASteps: Int64; const AEval: String; AEvalArg: Int64;
                      out AErr, AEvalErr: String): String;
  var
    eng: TPhosphorEngine;
    d: TDrive;
    v: TValue;
  begin
    eng := TPhosphorEngine.Create();
    d := NewDrive(eng, [daRun]);
    try
      AErr := '';
      AEvalErr := '';
      if AEval <> '' then
      begin
        d.ReentryAtStop := 1;
        d.ReentryName := AEval;
        d.ReentryArg := AEvalArg;
      end;
      eng.MaxSteps := ASteps;
      if eng.Prepare(Fix) <> 0 then Exit('the fixture did not prepare');
      eng.ArmDebug([], True);
      v := eng.CallFunction('spin', [ValInt(20000)]);
      AErr := eng.ErrorMessage;
      AEvalErr := d.ReenteredErr;
      Result := ValToStr(v) + '/' + StringReplace(d.Text, #10, '', [rfReplaceAll]);
    finally
      eng.Free;
      d.Free;
    end;
  end;

{ THE DEPTH TERM, MEASURED IN SLEEPS SO THAT NO MACHINE'S SPEED ENTERS IT.

  The credit fires when the HOST re-enters from inside its stop. A `callfunc` the
  watch expression itself makes is the SCRIPT re-entering, one activation deeper,
  and crediting there hands back whatever the watch has spent so far.

  Everything below is a `pause`, which is budget-aware -- it waits in slices and
  stops when the run's time does -- so every quantity is wall clock the fixture
  chose and not instructions a fast machine gets through sooner.

     ceiling                                400 ms
     the watch `warm`: pause 0.25           250 ms, then callfunc("noop", 0)
     the outer `slow`: pause 0.2            200 ms, then println "done"

  CHARGED (correct): the watch spends 250 of the 400. `slow` then asks for 200
  with 150 left, BudgetSleep stops at the deadline and `pause` is refused, so
  nothing is printed. CREDITED AT THE INNER callfunc (the mutation): the 250 is
  handed back when `warm` re-enters, `slow` has the whole 400 again, and it
  prints. 250 + 200 against 400 either way -- only the door decides. }
function DepthOfTheDoor: String;
var
  eng: TPhosphorEngine;
  d: TDrive;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daRun]);
  try
    d.ReentryAtStop := 1;
    d.ReentryName := 'warm';
    d.ReentryArg := 0;
    eng.TimeoutMs := 400;
    if eng.Prepare(Fix) <> 0 then Exit('the fixture did not prepare');
    eng.ArmDebug([], True);
    eng.CallFunction('slow', [ValInt(7)]);
    if d.Text = '' then Result := 'REFUSED' else Result := 'RAN: ' + d.Text;
  finally
    eng.Free;
    d.Free;
  end;
end;

{ THE FOURTH CEILING, WHICH THE LIST ABOVE SAYS NEEDS NO CORRECTION AND WHICH
  NOTHING HAD MEASURED. Parking executes no instruction, so MaxSteps is right
  across a park by construction -- that argument is sound and it is the whole of
  why the ledger list has three entries. It says nothing at all about the OTHER
  host behaviour: an evaluation does execute instructions, they are the script's
  by the rule two paragraphs up, and until this pair of runs existed no test in
  this tree set MaxSteps with a debugger attached at all.

  THE CEILING IS CALIBRATED AND THE EXPECTATION IS ARITHMETIC. A step is an
  implementation unit and nothing outside this engine can name how many one BASIC
  loop costs, so a hand-written number here would either be read off a run -- the
  way four expectations in this tree came to pin a wrong answer -- or be wrong on
  the next compiler change. Instead the smallest POWER OF TWO that admits the work
  once is found by asking the engine, with no debugger anywhere near it; and the
  assertion on top of it needs no implementation knowledge at all, because the
  smallest power of two at or above a cost is strictly below twice that cost. So
  a budget calibrated to fit the work once cannot fit it twice, whatever a step
  turns out to be. The watch evaluates the identical call, so the two runs differ
  by exactly one repetition of one body. }
function StepsThatFitOnce: Int64;
var
  m: Int64;
  ignored, ignored2: String;
begin
  m := 1024;
  while m < 1000 * 1000 * 1000 do
  begin
    if OuterSteps(m, '', 0, ignored, ignored2) = '20000/done' then Exit(m);
    m := m * 2;
  end;
  Result := -1;                  // the caller reports this as a failure
end;

var
  evalErr, outerErr: String;
  fits: Int64;
begin
  { IDLE. Seven hundred milliseconds of a person, against a three-hundred
    millisecond ceiling, and the script does not notice. }
  CheckStr(Outer(400, 300, '', evalErr), '20000/done',
           'charged-not-credited: 700 ms of IDLE inside the window costs the ' +
           'script nothing at all');
  { EXECUTION. The watch is refused on its own terms -- which is the answer to
    "does an evaluation need a clock of its own": the script's ceiling is still
    standing over it, so a runaway watch cannot hang the session. }
  CheckStr(Outer(0, 0, 'spin', evalErr), '0/',
           'charged-not-credited: a watch that runs script for longer than the ' +
           'whole ceiling spends the ceiling -- the outer call answers nothing ' +
           'and prints nothing');
  CheckStr(evalErr, 'time limit exceeded (300 ms)',
           'charged-not-credited: and the watch itself was refused rather than ' +
           'running for ever -- the script''s own ceiling bounds it');
  { AND THE TWO TOGETHER, WHICH IS THE SHAPE A DEBUGGER ACTUALLY MAKES: read the
    stack, ask for a watch, read the answer. The idle either side is credited and
    the middle is not, which needs a mark on the way OUT as well as on the way
    in. }
  CheckStr(Outer(400, 300, 'spin', evalErr), '0/',
           'charged-not-credited: park, evaluate, park -- the two idle halves are ' +
           'given back and the evaluation between them is still charged');
  CheckStr(DepthOfTheDoor(), 'REFUSED',
           'charged-not-credited: AND THE CREDIT''S DOOR IS A DEPTH, NOT A FLAG. ' +
           'A `callfunc` inside a watch expression is the script re-entering, not ' +
           'the host, and what it has spent so far is not given back at it');

  { THE FOURTH CEILING. The calibration first, as its own assertion, because a
    ceiling nobody could satisfy would make the pair below pass for the wrong
    reason -- both runs refused, and the difference between them never measured. }
  fits := StepsThatFitOnce();
  Report(fits > 0,
         'charged-not-credited: a step ceiling that admits the work once exists ' +
         '-- without one the pair below would be two refusals and no measurement');
  if fits > 0 then
  begin
    CheckStr(OuterSteps(fits, '', 0, outerErr, evalErr), '20000/done',
             'charged-not-credited: THE CONTROL. The calibrated ceiling admits ' +
             'the outer call with a debugger attached and nobody evaluating');
    { `0/done` and not `0/`, and the difference is derived rather than read: the
      watch is the FIRST of the two bodies, so it fits and prints its own "done"
      and answers; the outer one then has nothing left, is refused, prints
      nothing and answers 0. The `done` in this expectation belongs to the watch
      expression -- which is also the half that says the evaluation really ran
      rather than being refused at its own first instruction. }
    CheckStr(OuterSteps(fits, 'spin', 20000, outerErr, evalErr), '0/done',
             'charged-not-credited: AND THE WATCH''S INSTRUCTIONS ARE THE ' +
             'SCRIPT''S TOO. The same body twice cannot fit a budget calibrated ' +
             'to fit it once, so the watch runs and the outer call is refused -- ' +
             'the third lane of the one rule, and the only ceiling of the four ' +
             'that nothing set with a debugger attached');
    CheckStr(outerErr, 'step budget exceeded (' + IntToStr(fits) + ' instructions)',
             'charged-not-credited: and refused by the STEP budget by name, not ' +
             'by whichever ceiling happened to fire first');
    { AND THE OTHER DIRECTION OF THE SAME CEILING: the watch itself is what runs
      away. Ten times the calibrated work cannot fit, so the EVALUATION is the
      one refused, and the script's own step budget is what bounds it -- the
      answer for MaxSteps to the question `does a watch expression need a ceiling
      of its own`, which was measured for the clock and asserted for nothing
      else. A step ceiling that declined to fire while the host was inside its
      stop would leave a runaway watch running for ever and is caught here. }
    CheckStr(OuterSteps(fits, 'spin', 200000, outerErr, evalErr), '0/',
             'charged-not-credited: a RUNAWAY watch is refused rather than run, ' +
             'and prints nothing');
    CheckStr(evalErr, 'step budget exceeded (' + IntToStr(fits) + ' instructions)',
             'charged-not-credited: and the watch''s own verdict says which ' +
             'ceiling stopped it -- the script''s, because it has none of its own');
  end;
end;

{ THE RE-ENTRANCY GUARD IS NOT PART OF THE ARMING.

  `replace the breakpoint set` is naturally written DisarmDebug + ArmDebug, and a
  host does it from inside a stop because that is when the editor's gutter has
  changed. DisarmDebug cleared FDbgInSeam -- a flag that describes the Pascal
  stack and not the arming -- so the very next watch expression was stopped
  inside its own stop, once per boundary, each level re-syncing and evaluating
  again. Bounded only by MaxCallDepth without a guard on the host's own side; the
  drive object has one, which is why this fixture reports a number instead of
  dying.

  FixFrames, armed on 7 (inside `inner`) and re-synced to 11 (inside `twice`),
  which is the function the re-entrant call runs. Measured before the fix: 11
  stops at seam depth 2. The control re-arms WITHOUT disarming, which is the one
  difference that matters.

  THE TRACE IS DERIVED. outer(5) at stop 1 is B7@2 -- line 7 is inner's only
  statement, two frames in (host frame + inner). The host then replaces the set
  with line 11 alone and evaluates twice(4), whose line 11 must NOT be offered. Coming
  back, the session's remaining boundaries are line 8 (inner's return), line 4
  (outer's return) -- neither of which is 11 -- so the trace ends there. }
procedure CheckSeamGuardSurvivesADisarm;

  function Resynced(AResync: Boolean; out AMaxDepth, AStops: Integer): String;
  var
    eng: TPhosphorEngine;
    d: TDrive;
  begin
    eng := TPhosphorEngine.Create();
    d := NewDrive(eng, [daRun]);
    try
      d.ReentryAtStop := 1;            // 'twice', argument 4
      if AResync then
      begin
        d.ResyncAtStop := 1;
        SetLength(d.ResyncLines, 1);
        d.ResyncLines[0] := 11;
      end;
      if eng.Prepare(FixFrames) <> 0 then Exit('the frames fixture did not prepare');
      eng.ArmDebug([7], False);
      eng.CallFunction('outer', [ValInt(5)]);
      AMaxDepth := d.MaxDepth;
      AStops := d.Stops;
      Result := d.Reentered;
    finally
      eng.Free;
      d.Free;
    end;
  end;

var
  maxDepth, stops: Integer;
begin
  CheckStr(Resynced(False, maxDepth, stops), '8',
           'disarm-guard: the control -- a host that only ARMS from its stop -- ' +
           'still gets its watch answered');
  CheckInt(maxDepth, 1, 'disarm-guard: and is never entered from inside itself');
  CheckInt(stops, 1, 'disarm-guard: one stop, which is the one it armed');
  CheckStr(Resynced(True, maxDepth, stops), '8',
           'disarm-guard: a host that DISARMS AND RE-ARMS from its stop gets the ' +
           'same answer');
  CheckInt(maxDepth, 1,
           'disarm-guard: AND IS STILL NOT STOPPED INSIDE ITS OWN STOP. The ' +
           're-entrancy flag says a seam call is live on the Pascal stack, which ' +
           'is not something disarming can know');
  CheckInt(stops, 1,
           'disarm-guard: and the new set -- line 11 alone -- matches no ' +
           'boundary the session has left, so the stop count does not move');
end;

{ INSTALLING THE SEAM REACHES A SESSION THAT IS ALREADY PREPARED.

  ArmDebug forwards to a live VM on purpose and says so; OnDebug was a plain
  field write and ConfigureVM, the only copier, had been and gone. So the two
  halves of one attach disagreed: Prepare, install, arm, call gave ZERO stops and
  no diagnostic -- which is the shape a GUI uses when a person clicks Debug on a
  script that is already loaded. Measured before the fix: stops 0, with the VM
  armed and its seam nil.

  BOTH DIRECTIONS. Installing mid-session must reach the VM, and CLEARING it
  mid-session must too, or a host that detaches is left with a VM still holding a
  pointer to an adapter it has finished with.

  THE TRACE IS DERIVED from FixFrames: armed on 7, `outer(5)` calls `inner`,
  whose only statement is line 7 at two frames in -- the host's frame plus
  inner's. One stop, B7@2. }
procedure CheckSeamInstalledAfterPrepare;
var
  eng: TPhosphorEngine;
  d: TDrive;
  v: TValue;
begin
  eng := TPhosphorEngine.Create();
  d := TDrive.Create();
  try
    d.Eng := eng;
    SetLength(d.Actions, 1);
    d.Actions[0] := daRun;
    eng.OnOutput := @d.Output;
    { PREPARED WITH NO SEAM AT ALL, which is the whole point: ConfigureVM copies
      what the engine holds at Prepare time, and at Prepare time it holds nil. }
    CheckInt(eng.Prepare(FixFrames), 0, 'late-attach: the frames fixture prepares');
    eng.OnDebug := @d.Debug;
    eng.ArmDebug([7], False);
    Report(Assigned(eng.PreparedVM.OnDebug),
           'late-attach: installing the seam after Prepare reaches the prepared VM');
    v := eng.CallFunction('outer', [ValInt(5)]);
    CheckStr(ValToStr(v), '6', 'late-attach: the call still answers 6');
    CheckStr(d.Trace, Want('B7@2'),
             'late-attach: AND IT REALLY STOPS. A host that attaches to a session ' +
             'it has already prepared used to get a normal run and no diagnostic');
    { AND THE OTHER DIRECTION, which is the same property write with nil in it. }
    eng.OnDebug := nil;
    Report(not Assigned(eng.PreparedVM.OnDebug),
           'late-attach: and DETACHING mid-session reaches the prepared VM too');
    eng.CallFunction('outer', [ValInt(5)]);
    CheckStr(d.Trace, Want('B7@2'),
             'late-attach: so the armed line stops offering itself once the seam ' +
             'is gone -- the trace does not grow');
  finally
    eng.Free;
    d.Free;
  end;

  { AND THE REPL'S VM IS THE OTHER ONE THE ARMING REACHES, so the seam has to
    reach it too or the pair disagrees again one object over. That VM is built
    lazily by the first ReplRun, so "after Prepare" for a session means after its
    first line. One line defines a function, the second calls it; the seam is
    installed between them and line 2 is armed.

       1  function twice(n) return n + n endfunction
       2  println str$(twice(4))

    DERIVED: line 2 is the only statement the second ReplRun executes at the top
    level, at frame 0, so the trace is B2@0 and the output is 8. }
  eng := TPhosphorEngine.Create();
  d := TDrive.Create();
  try
    d.Eng := eng;
    SetLength(d.Actions, 1);
    d.Actions[0] := daRun;
    eng.OnOutput := @d.Output;
    CheckInt(eng.ReplRun('function twice(n) return n + n endfunction'), 0,
             'late-attach: the REPL takes the definition line');
    eng.OnDebug := @d.Debug;               // after the session's VM exists
    eng.ArmDebug([2], False);
    CheckInt(eng.ReplRun('println str$(twice(4))'), 0,
             'late-attach: and the next REPL line runs');
    CheckStr(d.Text, '8' + #10, 'late-attach: with the right answer');
    CheckStr(d.Trace, Want('B2@0'),
             'late-attach: AND THE SEAM REACHED THE SESSION''S VM TOO. ArmDebug ' +
             'forwards to both; a setter that forwarded to only one would leave ' +
             'the REPL half of the pair disagreeing');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ A WATCH EXPRESSION THAT FAULTS IS NOT THE OUTER CALL'S VERDICT.

  The engine's ErrorLine and ErrorMessage describe the door the host most recently
  called. Every door clears them on the way IN and writes them when it FAILS, and
  that was the whole of it -- which is right for a door nothing nests inside. The
  debug seam is documented as a door a host may re-enter through, so a watch
  expression is a CallFunction inside a CallFunction: the inner one faults and
  writes both fields, the outer one then finishes cleanly, and `IsError` is False
  so nothing overwrites them. The host reads its own successful call's verdict and
  is told about a fault in somebody else's evaluation.

  FOUND BY THE SWEEP, not by hand, and only in the round the three-leg differential
  started comparing the error LINE and the error MESSAGE beside the output: the
  detached leg of tests/probe_sweep.lpr's `innerfault/goto/fault2/hostcall` shapes.
  Pinned here by name because the sweep judges a generated shape and this judges
  the sentence.

  DERIVED FROM THE FIXTURE, by hand. `boom` faults on its first statement with no
  handler anywhere, so evaluating it from a stop is a fault at line 6 -- the line
  `z = 1 / 0` is on. `outer` is armed at line 3, stops once, and returns 5 + 1.
  So: the inner verdict is `division by zero` at 6, and the outer verdict is the
  value 6 with NO message and line 0.

    1  end
    2  function outer(n) local t
    3    t = n + 1
    4    return t
    5  endfunction
    6  function boom(n) local z
    7    z = 1 / 0
    8    return z
    9  endfunction

  The fault is on source line 7; line 1 is `end`. Counted from the listing above. }
procedure CheckWatchFaultIsNotTheCallsVerdict;
const
  Fix =
    'end'                              + #10 +   // 1
    'function outer(n) local t'        + #10 +   // 2
    '  t = n + 1'                      + #10 +   // 3
    '  return t'                       + #10 +   // 4
    'endfunction'                      + #10 +   // 5
    'function boom(n) local z'         + #10 +   // 6
    '  z = 1 / 0'                      + #10 +   // 7
    '  return z'                       + #10 +   // 8
    'endfunction'                      + #10;    // 9
var
  eng: TPhosphorEngine;
  d: TDrive;
  v: TValue;
begin
  eng := TPhosphorEngine.Create();
  d := NewDrive(eng, [daRun]);
  try
    d.ReentryAtStop := 1;
    d.ReentryName := 'boom';
    d.ReentryArg := 1;
    CheckInt(eng.Prepare(Fix), 0, 'watch-fault: the fixture prepares');
    eng.ArmDebug([3], False);
    v := eng.CallFunction('outer', [ValInt(5)]);
    CheckStr(d.Trace, Want('B3@1'), 'watch-fault: one stop, in outer''s own frame');
    CheckStr(ValToStr(v), '6', 'watch-fault: and the outer call still answers 5 + 1');
    { The evaluation's own verdict, read where a host reads it: from the nested
      call, inside the seam. That half must NOT change -- a host that evaluates a
      bad watch has to be told. }
    CheckStr(d.ReenteredErr, 'division by zero',
             'watch-fault: the watch expression''s own verdict is still reported ' +
             'to the host that asked for it');
    { And the outer call's verdict about ITSELF. }
    CheckStr(eng.ErrorMessage, '',
             'watch-fault: AND THE SUCCESSFUL CALL SAYS NOTHING. It used to carry ' +
             'the watch''s "division by zero" out to a host whose own call worked');
    CheckInt(eng.ErrorLine, 0,
             'watch-fault: and no line either -- it used to name line 7, which is ' +
             'in a function the host never called');
  finally
    eng.Free;
    d.Free;
  end;
end;

{ ------------------------------------------------------------------------- }

begin
  ProveFail := (ParamCount >= 1) and (ParamStr(1) = '--fail');

  CheckStepInto();
  CheckStepOver();
  CheckStepOut();
  CheckStepOverOutOfBody();
  CheckStepOutClamp();
  CheckStepOutThroughCallfunc();
  CheckResumeRebase();
  CheckFaultRebase();
  CheckArmedLines();
  CheckPause();
  CheckStop();
  CheckSeamRaises();
  CheckSeamReentry();
  CheckParkedClock();
  CheckParkedBudget();
  CheckParkedHeap();
  CheckBreakpointCharged();
  CheckArmUnusableLine();
  CheckAttachDetach();
  CheckStepOutOfTopLevelCallfunc();
  CheckStepOutOfErrorHandler();
  CheckGosubIsACall();
  CheckArmOrder();
  CheckStepOverRecaptures();
  CheckBreakpointCostsWhatPrintCosts();
  CheckMemoryCeilingThroughSeam();
  CheckSeamReachesVM();
  CheckStopInsideHostCall();
  CheckStepDoesNotSurviveARun();
  CheckStepOutClampAtTheHostDoor();
  CheckChargeDoesNotAskWhoIsListening();
  CheckWatchAfterAPause();
  CheckEvaluationIsChargedNotCredited();
  CheckSeamGuardSurvivesADisarm();
  CheckSeamInstalledAfterPrepare();
  CheckWatchFaultIsNotTheCallsVerdict();

  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed > 0 then Halt(1) else Halt(0);
end.
