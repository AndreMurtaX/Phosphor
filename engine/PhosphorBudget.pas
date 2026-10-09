{******************************************************************************
  Phosphor BASIC -- the execution budget (the ceilings, inside a library call)

  MIT License. Copyright (c) 2026 Andre Murta.

  THE HOLE THIS CLOSES. MaxSteps, TimeoutMs and MaxOutputBytes are tested in the
  VM's dispatch loop, BETWEEN instructions. A library call is ONE instruction, so
  everything a library does is invisible to all three: a host that sets every
  ceiling docs/embedding.md prescribes still waits for ever on

      println regex_find$("(a+)+$", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!")
      x$ = string$(1e18, 65)
      pause(1e9)

  because each of those is a single opCall whose work happens below the loop that
  does the checking. The guarantee the embedding guide makes to a host did not
  hold.

  THE SHAPE. There is no way to preempt arbitrary native code in-process without
  threads, so this is not a preemptive scheduler. It is a budget that the engine
  installs before a run and that every library operation which can run long
  CONSULTS, plus one rule that does the work no consultation can:

    RULE 1  An operation whose SIZE is derivable from its arguments asks
            BudgetAllows(count) BEFORE it starts, and refuses rather than
            beginning something it cannot finish inside the budget.
    RULE 2  An operation whose size is NOT derivable -- a directory walk, a
            find-all over a subject, a wait -- calls BudgetCharge as it goes, so
            the wall clock is looked at from inside the call.
    RULE 3  An operation that can neither be sized nor interrupted -- a
            backtracking regex inside the RTL -- is judged STRUCTURALLY before it
            starts (BudgetPatternBounded) and refused if its worst case is
            unbounded work.

  scripts/check-budget.py is what keeps the rule from rotting: every loop or
  allocation over a script-supplied count, in engine/libs and host/packages, must
  consult this unit or be listed there as exempt with a reason. The filesystem
  sandbox learned that lesson the expensive way; this one starts with the gate.

  WHAT RULE 1 DOES NOT BOUND, STATED PLAINLY BECAUSE A HOST WILL OTHERWISE READ
  MORE INTO IT. RULE 1 bounds ONE LIBRARY CALL. It is asked at the opCall seam,
  by the library function, about its own arguments. The `+` OPERATOR IS NOT A
  LIBRARY CALL -- it is opAdd, a VM instruction -- so string concatenation is
  OUTSIDE this budget entirely. Measured on this build under the ceilings
  docs/embedding.md prescribes (MaxSteps 1000000, TimeoutMs 2000):

      s$ = string$(1600000000, 97)             refused, 0 ms
      s$ = string$(200000000, 97)              allowed
      s$ = s$ + s$  (three times)              rc = 0, len 1600000000,
                                               5032 ms, 14.7 GB peak

  The same byte count: six times the refused size, built by three instructions
  out of a million. MaxSteps counts INSTRUCTIONS, and an instruction whose cost
  is not O(1) makes it a poor proxy for work; the VM's TimeoutMs does stop such
  a run, but only after the allocation has been made.

  CLOSED ON 2026-09-10, where this note said it would have to be: engine/
  PhosphorVM.pas, at opAdd, where the size of the result is known before the
  concatenation happens. TPhosphorVM.MaxMemoryBytes is a fourth ceiling beside
  MaxSteps, MaxOutputBytes and TimeoutMs, measured as GROWTH from the heap this
  run started with, so it bounds the script rather than the host. opAdd asks it
  before it concatenates when the growth is worth measuring, and a check beside
  the wall clock in the step loop catches everything smaller.

  RULE 1 STILL DOES NOT BOUND MEMORY, and nothing above changed: it is still one
  library call about its own arguments. The two ceilings answer different
  questions and a host wants both. And a ceiling is not a quota -- an allocation
  already under way cannot be interrupted -- so a host that must cap the PROCESS
  absolutely still wants a job object on Windows or an rlimit or cgroup on Linux.

  INERT UNLESS THE HOST ASKED FOR A BOUND. BudgetBegin(0, 0) -- which is what a
  host that sets no ceilings gets -- makes every consultation below answer "go
  ahead" on its first line. A trusted script therefore behaves EXACTLY as it did
  before this unit existed: nothing is refused, nothing is measured, and the only
  cost is one Boolean test per consulted operation.

  PROCESS-WIDE, like PhosphorSandbox and for the same reason: a library function
  is a plain callback with no VM to ask. Two engines in one process share one
  budget, and the last BudgetBegin wins. A host that runs two scripts at once, in
  two threads, is outside what this can promise -- as it already is for the
  sandbox root.

  CATCHABLE, unlike the VM's own three. The VM's ceilings abort the run and ON
  ERROR cannot see them. A refusal from here arrives as an ordinary peLimit
  return value from a library function, which TPhosphorVM.Fault will offer to an
  installed handler. That does NOT give a script a way out: the budget LATCHES
  (once spent it stays spent for the run, so every later consultation refuses at
  once, in constant time) and the time and instructions the script spends
  catching and retrying are counted by the VM's own ceilings, which are fatal. A
  caught refusal buys a script nothing but a tidier way to give up.
******************************************************************************}
unit PhosphorBudget;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, PhosphorErrors;

const
  { WHAT A UNIT IS. One unit is one ELEMENTARY operation inside a library: a byte
    touched, an iteration of an inner loop, a directory entry visited. A VM
    instruction is worth far more than that -- decode, stack traffic, a managed
    value copied -- so the allowance for a run is MaxSteps * BudgetUnitsPerStep,
    not MaxSteps.

    The ratio is deliberately generous, because the failure it must avoid is
    refusing a legitimate program. Under the million-step budget
    docs/embedding.md prescribes, string$(1000000) spends 0.4% of the allowance
    and is not slowed measurably, while string$(2147483647) -- which is what
    string$(1e18) becomes after ArgI32's saturating clamp -- is over it by a
    factor of eight and is refused before a byte is allocated. }
  BudgetUnitsPerStep = 256;

  { What a millisecond of WAITING costs. A wait allocates nothing and touches no
    byte, so it cannot be priced by size; this is the order of magnitude of
    elementary operations this hardware does in a millisecond. It is what stops
    pause(1e9) under a budget that set MaxSteps and no TimeoutMs: 25 seconds of
    sleeping exhausts the million-step allowance. }
  BudgetUnitsPerMs = 10000;

  { What a millisecond of WORK buys -- the same exchange as BudgetUnitsPerMs but
    in the other direction, and therefore NOT the same number.

    TWO CEILINGS, ONE RULE. The first version of this unit priced RULE 1 only
    against MaxSteps: the size test lived inside `if GMaxSteps > 0`, so a host
    that set TimeoutMs ALONE -- a configuration TPhosphorEngine supports and
    docs/embedding.md never forbids -- got no size refusal whatsoever, and the
    unit header's own example (x$ = string$(1e18, 65)) allocated two gigabytes
    and returned SUCCESS. A rule that is priced against one ceiling is a rule the
    other ceiling does not have.

    THE NUMBER IS NOT A TASTE. docs/embedding.md prescribes MaxSteps = 1000000
    and TimeoutMs = 2000 together, so those two must buy the SAME allowance:

        1000000 steps * 256 units/step  =  2000 ms * 128000 units/ms

    A host that sets one of the pair therefore gets exactly the allowance a host
    that sets the other gets, and a host that sets both gets the smaller of the
    two as the clock runs down. Nothing about the step-only path changes.

    Why the opposite direction from BudgetUnitsPerMs: waiting must be EXPENSIVE
    (a big number stops pause(1e9)) and working must be CHEAP (a big number
    avoids refusing a legitimate string$). One constant cannot be both, and the
    first version's mistake was to have only one of them. }
  BudgetUnitsPerMsOfWork = 128000;

  { The longest a sliced wait blocks before it looks at the clock again. }
  BudgetSliceMs = 20;

  { How many units may be charged between two reads of the clock. The VM uses the
    same 4096 for the same reason: GetTickCount64 is cheap but not free, and a
    per-character loop calls in far more often than a wall clock can resolve. }
  BudgetClockEvery = 4096;

  // A nest of COUNTED repeats may still be astronomically large: a group
  // repeated 0..1000 times whose body repeats 0..1000 times is a million
  // repetitions with no unbounded quantifier anywhere in it. This is the product
  // past which such a nest counts as unbounded work.

  BudgetMaxRepeatProduct = 1000000;

  { QUADRATIC APPEND: what one `x := x + <one piece>` iteration costs.

    scripts/check-budget.py used to document that "a STRING argument is
    deliberately not tainted: its Length bounds a loop exactly as any other
    container's does." That is only true when the loop BODY is O(1), and

        x := x + Copy(AText, i, 1)

    is not: FPC's fpc_AnsiStr_Concat reallocates and the heap copies whenever it
    cannot extend in place. Round two fixed the product-of-two-strings half of
    that wrong assumption and left this half, so three routines in the directories
    the gate scans -- IsValidBase64, Utf8UpperU/Utf8LowerU, CpReverse -- ran 24-39x
    over a 2000 ms ceiling and reported SUCCESS, islimit FALSE. Six ordinary lines
    reached 284391 ms and 3.8 GB that way.

    THE NUMBER IS MEASURED, not chosen. Unbudgeted, on this build, one of those
    loops over an n-byte string costs:

        n =  1 MB   ~150 ms      n = 20 MB  1684-1937 ms
        n = 10 MB   668-904 ms   n = 40 MB  4650-5178 ms

    -- so it reaches the 2000 ms that docs/embedding.md prescribes at about
    20 MB. That ceiling is worth 2000 * BudgetUnitsPerMsOfWork = 256000000 units,
    and 256000000 / 20000000 = 12.8 units per byte. 12 is that, rounded DOWN so
    the price errs towards allowing: it refuses above ~21 MB, where the work
    really is over the ceiling, and leaves every smaller string alone. The growth
    is mildly superlinear (2.8x per doubling at the top end), so a linear price
    UNDER-charges the largest strings -- which is the safe direction for a guard
    whose failure mode is refusing honest work. }
  BudgetUnitsPerAppendedByte = 12;

  { And how many bytes of a MEMORY COPY buy one unit, for the appends that are
    fully quadratic rather than amortised. Measured on the worst of them,
    JsonEscape: a string of n quotes costs 703 / 2658 / 11526 / 63680 ms at
    n = 25000 / 50000 / 100000 / 200000 -- four times the work per doubling, a
    full copy of the answer per append and no realloc luck at all. It reaches the
    prescribed 2000 ms at about n = 45000, having copied sum(2i) ~ n^2 = 2.0e9
    bytes. 2.0e9 bytes / 256000000 units = 7.9, so eight bytes copied cost one
    unit, on the same scale as BudgetUnitsPerMsOfWork. }
  BudgetBytesCopiedPerUnit = 8;

{ Install the ceilings for one run. Both 0 = inert (see the header). Nests: an
  inner Begin/End pair leaves the outer one's ceilings in place. }
procedure BudgetBegin(AMaxSteps, ATimeoutMs: Int64);
procedure BudgetEnd;

{ TIME THAT WAS NOT THE SCRIPT'S. Move this run's start forward by AMs, so that a
  stretch of wall clock nobody in the script spent is not charged to it.

  THE ONE CALLER, AND WHY IT IS NOT A LIBRARY. TPhosphorVM's debug seam MAY BLOCK
  -- it is the only seam in the engine that may -- and a host that parks in it for
  a minute while a person reads a breakpoint has burned a minute of a clock that
  started when the run did. The VM gives that minute back to its own FStartTick;
  this gives the same minute back to the budget's clock, which is a SECOND wall
  clock, started by BudgetBegin from the same TimeoutMs and read by OutOfTime and
  MsLeft. Correcting one and not the other leaves a debugged script's very next
  library call refused with "the budget for this run is spent", for time a person
  spent looking at it. Measured shape, not a hypothetical: with TimeoutMs = 2000,
  parking for three seconds at one breakpoint left MsLeft at 0 for the rest of the
  run.

  IT ONLY EVER MOVES THE START FORWARD, never back, and only while a budget is
  actually installed. So it cannot lengthen a run beyond its ceiling by any
  argument -- an AMs of 0 or less does nothing -- and it cannot resurrect a budget
  that was never begun. GSpent is deliberately NOT cleared: a refusal that already
  happened happened, and un-spending it here would be this unit lying about its
  own history. }
procedure BudgetParked(AMs: Int64);

{ True when the host asked for any bound at all. A library uses this to skip work
  that only matters under a budget -- never to decide whether to be correct. }
function BudgetActive: Boolean;

{ RULE 1. Reserve ACount units for an operation whose size its arguments already
  determine. True = charged, go ahead. False = refuse; BudgetRefusal says why.
  A refusal here does NOT latch: string$(1e18) is refused and string$(10) still
  works. }
function BudgetAllows(ACount: Int64): Boolean;

{ RULE 2. Charge AUnits of work already done (or about to be done, one iteration
  at a time). False = the budget is spent; that DOES latch. }
function BudgetCharge(AUnits: Int64): Boolean;

{ The error a refused operation returns. AWhat is the function's BASIC name. }
function BudgetRefusal(const AWhat: String): TPhosphorError;

{ A wait, in slices, that stops early when the budget is spent; False = it did.
  With no budget installed this is exactly Sleep(AMs) and always True. }
function BudgetSleep(AMs: Int64): Boolean;

{ Has the run's budget latched shut? Cheap; for a caller that must ask after the
  fact rather than before. }
function BudgetSpent: Boolean;

{ Milliseconds left on the run's clock; 0 when the host set no time ceiling. Never
  negative and never zero while time remains, so a caller can hand it straight to
  a native timeout that reads 0 as "wait for ever". For the one shape that can
  neither be sized nor charged nor judged: a wait on somebody else's network. }
function BudgetRemainingMs: Int64;

{ ONE `x := x + <piece>` append, charged by what the concatenation COPIES.
  ALen is the length the string being extended has NOW: FPC's
  fpc_AnsiStr_Concat reallocates and copies those bytes whenever the heap cannot
  extend the block in place, so a loop of n appends copies O(n * ALen) bytes
  however innocent `for i := 1 to Length(S)` looks around it. False = the budget
  is spent; the caller must stop and report, never hand back the half-built
  string. }
function BudgetAppend(ALen: Int64): Boolean;

{ THE ACHIEVABLE COST OF ONE NAIVE SEARCH of ANeedle in AHay, in units.

  ROUND TWO PRICED THE WORST CASE, Length(hay) * Length(needle), on the reasoning
  that a ceiling must be priced against a worst case. That is right about the
  SIZE of an answer and wrong about the TIME of a search, and it refused a band
  of entirely ordinary work. Swept over document size against needle length,
  19 of 27 searches were refused -- and all 27 together, unbudgeted, cost 62 ms:

      doc=100000   needle=4096  REFUSED     doc=1000000  needle=32  REFUSED
      doc=10000000 needle=8     REFUSED     ("319999008 units of work and only
                                              95358608 are left")

  Finding a 300-character quotation in a 990 KB document -- 0 ms unbudgeted --
  was refused on instr, countstr, replacestr$ AND buffer_indexof under exactly
  the ceilings docs/embedding.md prescribes.

  THE WORST CASE NEEDS A HAYSTACK WHOSE EVERY POSITION STARTS WITH THE NEEDLE'S
  FIRST BYTE, and ordinary text never does. Both naive searches in this tree skip
  a position on the first byte and only then compare -- FPC's Pos/PosEx
  (rtl/inc/astrings.inc, read rather than assumed):

      if (SubStr[1] = pc^) and (CompareByte(Substr[1], pc^, SubLen) = 0) then ...

  and PhosphorBufferLib's BufferIndexOf, which breaks its inner loop at the first
  mismatch. So the work is Length(hay) first-byte tests plus at most one full
  needle comparison per position where that first byte occurs:

      cost = Length(hay) + hits(hay, needle[1]) * Length(needle)

  That count is not sampled and not guessed: it is read off the haystack in one
  pass, the same order as the search's own floor. It remains an UPPER bound (both
  comparisons stop at their first mismatch), and it still refuses the amplifiers
  round one found -- instr(string$(1000000,97), string$(20000,97)+"b") has its
  first byte at all million positions, prices at 1.96e10 and is refused.

  ACaseless: for a search that folds case (replacetext$, ContainsText), which
  upper-cases both sides before searching.

  TWO DELIBERATE CONSEQUENCES. The counting pass is itself a pass over the
  haystack, so it is CHARGED here before it is made -- a refusal charges nothing,
  so without that a loop of refused searches would buy unbounded free scans of a
  large string. And with NO budget installed the price is never read, so it is
  not computed: the answer is 0 and no scan happens, leaving an unbudgeted host
  exactly as fast as it was before this unit existed. }
function BudgetSearchCost(const AHay, ANeedle: String;
                          ACaseless: Boolean = False): Int64;

{ RULE 3. Is APattern's worst case bounded work? False = it contains a
  construct that can backtrack exponentially, or one too large for the judge to
  finish reading; AWhy names which. True is a claim of proof: every repeated
  part was shown unambiguous (see the comment above the implementation). }
function BudgetPatternBounded(const APattern: String; out AWhy: String): Boolean;

implementation

var
  GDepth: Integer = 0;
  GActive: Boolean = False;
  GMaxSteps: Int64 = 0;
  GTimeoutMs: Int64 = 0;
  GUnits: Int64 = 0;
  GNextClock: Int64 = 0;
  GStart: QWord = 0;
  GSpent: Boolean = False;
  GWhy: String = '';

// --- installation ------------------------------------------------------------
procedure BudgetBegin(AMaxSteps, ATimeoutMs: Int64);
begin
  Inc(GDepth);
  if GDepth > 1 then Exit;          // an inner run keeps the outer run's budget
  if AMaxSteps < 0 then AMaxSteps := 0;
  if ATimeoutMs < 0 then ATimeoutMs := 0;
  GMaxSteps := AMaxSteps;
  GTimeoutMs := ATimeoutMs;
  GActive := (GMaxSteps > 0) or (GTimeoutMs > 0);
  GUnits := 0;
  GNextClock := BudgetClockEvery;
  GStart := GetTickCount64();
  GSpent := False;
  GWhy := '';
end;

procedure BudgetEnd;
begin
  if GDepth > 0 then Dec(GDepth);
  if GDepth > 0 then Exit;
  GActive := False;
  GMaxSteps := 0;
  GTimeoutMs := 0;
  GUnits := 0;
  GSpent := False;
  GWhy := '';
end;

function BudgetActive: Boolean;
begin
  Result := GActive;
end;

procedure BudgetParked(AMs: Int64);
var
  now, gone: QWord;
begin
  if (GDepth <= 0) or (AMs <= 0) then Exit;
  { CLAMPED AT "NOW", AND THE CLAMP IS NOT BELT AND BRACES -- it is the whole
    reason this is four lines and not one. GStart is a QWord and every reader
    computes `GetTickCount64() - GStart`, so a start pushed even one millisecond
    into the FUTURE makes that subtraction wrap to about 18 quintillion and every
    ceiling read "spent" for the rest of the run. Measured on the first version of
    this procedure: a budget with a 200 ms ceiling, told 5000 ms were parked,
    answered 0 ms remaining. It is also the honest bound on its own terms -- no
    more time can have been parked than has elapsed. }
  now := GetTickCount64();
  if now <= GStart then Exit;
  gone := now - GStart;
  if QWord(AMs) >= gone then GStart := now
  else GStart := GStart + QWord(AMs);
end;

// --- the two consultations ---------------------------------------------------
{ Saturating: a count that came from a program can be High(Int64), and adding it
  twice must not wrap the counter back under the ceiling. }
function AddSat(const A, B: Int64): Int64;
begin
  if (B > 0) and (A > High(Int64) - B) then Result := High(Int64)
  else if (B < 0) and (A < Low(Int64) - B) then Result := Low(Int64)
  else Result := A + B;
end;

function OutOfTime: Boolean;
begin
  Result := (GTimeoutMs > 0) and (GetTickCount64() - GStart > QWord(GTimeoutMs));
end;

{ The run's unit allowance, 0 when no step ceiling was set. }
function Allowance: Int64;
begin
  if GMaxSteps <= 0 then Exit(0);
  if GMaxSteps > High(Int64) div BudgetUnitsPerStep then Exit(High(Int64));
  Result := GMaxSteps * BudgetUnitsPerStep;
end;

{ How many milliseconds of the run's clock are left, 0 when no time ceiling was
  set. The private half of BudgetRemainingMs, without its "never zero" clamp. }
function MsLeft: Int64;
var gone: QWord;
begin
  if GTimeoutMs <= 0 then Exit(0);
  gone := GetTickCount64() - GStart;
  if gone >= QWord(GTimeoutMs) then Exit(0);
  Result := GTimeoutMs - Int64(gone);
end;

{ RULE 1's CEILING: the largest single operation that may still be started.

  This is the fix for the ceiling split. Each ceiling the host actually set
  contributes a bound, and the answer is the SMALLEST of them:

    MaxSteps  -> what is left of MaxSteps * BudgetUnitsPerStep
    TimeoutMs -> what is left of the clock, at BudgetUnitsPerMsOfWork per ms

  With only MaxSteps set this is exactly what the first version computed, so the
  step-only path is unchanged to the unit. With only TimeoutMs set there is now a
  size test where there was none. With BOTH set the answer starts equal (the two
  constants are chosen so the documented pair agree) and then falls with the
  clock, which is the honest reading of "can this finish inside the budget".

  -1 = no ceiling at all (an inert budget); every size is allowed. }
function SizeCeiling: Int64;
var byTime, byStep, ms: Int64;
begin
  Result := -1;
  if GMaxSteps > 0 then
  begin
    byStep := Allowance() - GUnits;
    if byStep < 0 then byStep := 0;
    Result := byStep;
  end;
  if GTimeoutMs > 0 then
  begin
    ms := MsLeft();
    if ms > High(Int64) div BudgetUnitsPerMsOfWork then byTime := High(Int64)
    else byTime := ms * BudgetUnitsPerMsOfWork;
    if (Result < 0) or (byTime < Result) then Result := byTime;
  end;
end;

function BudgetCharge(AUnits: Int64): Boolean;
begin
  if not GActive then Exit(True);
  if GSpent then Exit(False);
  if AUnits < 0 then AUnits := 0;
  GUnits := AddSat(GUnits, AUnits);
  if (GMaxSteps > 0) and (GUnits > Allowance()) then
  begin
    GSpent := True;
    GWhy := 'the run has spent its step budget of ' + IntToStr(GMaxSteps) +
            ' inside library calls';
    Exit(False);
  end;
  // The clock, throttled: read it when enough units have gone by since the last
  // read, and always when a single charge was large enough to matter on its own.
  if (GTimeoutMs > 0) and ((GUnits >= GNextClock) or (AUnits >= BudgetClockEvery)) then
  begin
    GNextClock := AddSat(GUnits, BudgetClockEvery);
    if OutOfTime() then
    begin
      GSpent := True;
      GWhy := 'the run has spent its time limit of ' + IntToStr(GTimeoutMs) + ' ms';
      Exit(False);
    end;
  end;
  Result := True;
end;

function BudgetAllows(ACount: Int64): Boolean;
var
  ceil: Int64;
begin
  if not GActive then Exit(True);
  if GSpent then Exit(False);
  if ACount < 0 then ACount := 0;
  ceil := SizeCeiling();
  if (ceil >= 0) and (ACount > ceil) then
  begin
    // Deliberately NOT latched. One oversized request is a bad argument, not a
    // spent run: refusing string$(1e18) must leave string$(10) working, and an
    // over-eager guard that poisoned the rest of the run would be its own bug.
    GWhy := 'that would take ' + IntToStr(ACount) +
            ' units of work and only ' + IntToStr(ceil) + ' are left';
    Exit(False);
  end;
  Result := BudgetCharge(ACount);
end;

function BudgetRefusal(const AWhat: String): TPhosphorError;
var
  why: String;
begin
  why := GWhy;
  if why = '' then why := 'the run''s execution budget is spent';
  Result := MakeError(peLimit, AWhat + ': ' + why);
end;

// --- a wait that can be interrupted ------------------------------------------
{ Positions in AHay at which a naive search would begin a full needle
  comparison: those holding AFirst, or its ASCII case partner when the search
  folds case. Only the first Length(hay)-Length(needle)+1 positions can start a
  match, which is what ALimit carries in. }
function FirstByteHits(const AHay: String; AFirst: Char; ACaseless: Boolean;
                       ALimit: Integer): Int64;
var
  i: Integer;
  want: Char;
begin
  Result := 0;
  if ALimit > Length(AHay) then ALimit := Length(AHay);
  if not ACaseless then
  begin
    for i := 1 to ALimit do
      if AHay[i] = AFirst then Inc(Result);
    Exit;
  end;
  // UpCase is ASCII-only. AnsiUpperCase's locale fold can move bytes >= 128
  // among themselves but never onto an ASCII letter, so for an ASCII AFirst the
  // ASCII fold is exact. For a high AFirst the fold is not knowable here and
  // every high byte is counted -- an over-estimate, the safe direction.
  want := UpCase(AFirst);
  if AFirst >= #128 then
  begin
    for i := 1 to ALimit do
      if (AHay[i] = AFirst) or (AHay[i] >= #128) then Inc(Result);
    Exit;
  end;
  for i := 1 to ALimit do
    if UpCase(AHay[i]) = want then Inc(Result);
end;

function BudgetSearchCost(const AHay, ANeedle: String;
                          ACaseless: Boolean = False): Int64;
begin
  // No budget: nothing will read this, so do not pay for a scan to produce it.
  if not GActive then Exit(0);
  if (ANeedle = '') or (Length(ANeedle) > Length(AHay)) then
    Exit(Int64(Length(AHay)));
  // The counting pass, charged before it is made -- see the header.
  if not BudgetCharge(Int64(Length(AHay))) then Exit(High(Int64));
  Result := Int64(Length(AHay)) +
            FirstByteHits(AHay, ANeedle[1], ACaseless,
                          Length(AHay) - Length(ANeedle) + 1) *
            Int64(Length(ANeedle));
end;

function BudgetAppend(ALen: Int64): Boolean;
begin
  if ALen < 0 then ALen := 0;
  Result := BudgetCharge(ALen div BudgetBytesCopiedPerUnit);
end;

function BudgetSpent: Boolean;
begin
  Result := GActive and GSpent;
end;

function BudgetRemainingMs: Int64;
var
  byStep, byTime: Int64;
begin
  Result := 0;
  if not GActive then Exit;                     // no ceiling: 0 = "wait for ever"
  { THE MIRROR OF THE SIZE TEST, AND THE SAME MISTAKE THE OTHER WAY ROUND. The
    first version answered 0 whenever GTimeoutMs <= 0, so the one caller that
    needs it -- the HTTP read timeout, the only shape that can be neither sized
    nor charged nor judged -- got "wait for ever" under a STEP-only budget, and a
    peer that trickles bytes held the interpreter exactly as before.

    A step budget does bound a wait: pause() already prices a millisecond of
    waiting at BudgetUnitsPerMs, so what is left of the step allowance converts
    to milliseconds at that same rate. Under the documented million-step budget
    that is 25600 ms -- the same 25 seconds that stops pause(1e9). }
  byStep := 0;
  if GMaxSteps > 0 then
  begin
    byStep := (Allowance() - GUnits) div BudgetUnitsPerMs;
    if byStep < 1 then byStep := 1;             // 1, not 0: 0 means "no ceiling"
    Result := byStep;
  end;
  if GTimeoutMs > 0 then
  begin
    byTime := MsLeft();
    if byTime < 1 then byTime := 1;
    if (Result = 0) or (byTime < Result) then Result := byTime;
  end;
end;

function BudgetSleep(AMs: Int64): Boolean;
var
  left, slice: Int64;
begin
  Result := True;
  if AMs <= 0 then Exit;
  if not GActive then
  begin
    // Exactly what an unbudgeted host has always got.
    if AMs > High(Integer) then AMs := High(Integer);
    Sleep(LongInt(AMs));
    Exit;
  end;
  if GSpent then Exit(False);
  left := AMs;
  while left > 0 do
  begin
    slice := left;
    if slice > BudgetSliceMs then slice := BudgetSliceMs;
    Sleep(LongInt(slice));
    left := left - slice;
    // A millisecond asleep is priced against the clock (BudgetUnitsPerMs), so a
    // step-bounded run cannot buy an unbounded wait, and a time-bounded one stops
    // at its deadline.
    if not BudgetCharge(slice * BudgetUnitsPerMs) then Exit(False);
  end;
end;

// --- RULE 3: is this pattern's worst case bounded? ---------------------------
{ WHY A STRUCTURAL TEST AND NOT A TIMER. TRegExpr's matcher (0.987; the version
  check is in regexpr.pas, REVersionMajor/Minor) is a recursive backtracker with
  no step hook, no timeout property and no interrupt: once Exec is called there
  is no line of our code that runs again until it returns. Charging it afterwards
  would close the door behind the horse. The only thing that can be done BEFORE
  the call is to read the pattern.

  WHAT A BACKTRACKER COSTS. On a subject it fails to match, TRegExpr tries every
  way the pattern can consume every prefix of the subject, one after another,
  and remembers nothing between them. Its work is therefore the number of PATHS
  through the pattern's automaton that spell a prefix of the subject. A repeated
  part makes that number exponential exactly when the repeat is AMBIGUOUS in the
  sense automata theory names: some state of it has two different paths back to
  itself that spell the same text (Weber and Seidl, "On the degree of ambiguity
  of finite automata", 1991 -- EDA). Pump that text k times and there are 2^k
  paths. Without such a state the count is polynomial.

  THE CRITERION IS THAT DEFINITION, DECIDED, NOT APPROXIMATED BY RULES OF THUMB.
  The judge this replaces asked three structural questions -- does a mandatory
  separator exist, does the body end on one, does it begin on one -- and called
  the body unambiguous if any said yes. Each was a question about the wrong
  thing, and the round-2 attacker of 2026-10-09 walked through all three:

    ^(a*a*b)+$    a separator pins where an iteration ENDS, not how the bytes
                  INSIDE one are divided between two flexible atoms: a block of
                  m a's splits m+1 ways, (m+1)^k for k blocks, 15 s under a
                  2000 ms budget;
    ^((a|a)b)+$   an unquantified inner alternation was never asked whether its
                  branches overlap -- it folded into its parent as one atom;
    ^(ab?|b)+$    the boundary windows looked at atoms of the SAME branch, and
                  the next iteration may take another.

  And it refused (a|ab)+, which is a uniquely decodable code and runs in 0 ms,
  because its branches share a first byte. So now: the repeated body is compiled
  to a Thompson automaton exactly as TRegExpr walks it (one path per
  alternative, per count of a counted repeat, per way of matching the empty
  string), the empty moves are folded into weighted edges between the states
  that consume a byte, and the PRODUCT of that automaton with itself is searched
  from every diagonal pair (p,p) for an off-diagonal pair (q,r) that leads back
  to the diagonal. Every state of a repeated body lies on the repeat's cycle, so
  that is two different paths from a state back to itself on the same text --
  the definition, no more and no less. An edge with two empty routes between
  the same two bytes is the same thing with q = r (the (c()?)+ shape), and an
  empty move that loops back on itself is a body that can repeat while
  consuming nothing (the (a*)* shape); both refuse.

  COUNTED REPEATS. A repeat counted three or more times is judged by the same
  test as the unbounded one, and then given one chance the unbounded one does
  not get: a body with no loop of its own has finitely many paths P, so k
  iterations of it have at most P^k whatever the subject. The dotted-quad
  pattern of an IPv4 address is ambiguous inside an iteration ([01]?\d?\d reads
  "11" two ways) and was rightly allowed for three iterations -- 6^3 paths --
  where its unbounded twin is 2^n. Past BudgetMaxCountedPaths the count itself
  is the explosion: (a?) taken twenty times before twenty a's. A counted repeat
  over a body WITH a loop of its own and an ambiguous iteration -- (a+) ten
  times -- is polynomial of degree ten and refuses, as before. Nests of counts
  are still capped by BudgetMaxRepeatProduct.

  WHAT IT READS IS WHAT THE MATCHER READS. Every set an atom stands for is a
  SUPERSET of what TRegExpr 0.987 matches -- the version RegExpr is in FPC
  3.2.2, read from its source -- and a superset can only find more ambiguity,
  never hide some. \x61 is the byte a, (?i) folds case to the end of its group,
  (?x) makes blanks and #-comments nothing, an empty group or a comment
  consumes nothing. An ATOM whose bytes it cannot name -- a backreference, an
  escape it does not model -- inside a repeated body makes "unambiguous"
  unprovable, so that body refuses.

  WHAT IT CANNOT LOOK AT, IT REFUSES. A pattern nested past MaxReDepth, bigger
  than MaxReNodes, or whose repeated body needs more than MaxReStates states or
  MaxReWork steps of product search, is refused. Until 2026-10-09 the old
  judge's table limits (96 atoms, 16 branches, 48 levels) meant ALLOW, and
  padding any 2^n shape past one of them was a documented way through. The
  limits are now far past any pattern a program writes -- a 300-word
  alternation under a repeat is judged in milliseconds -- so the only thing a
  refusal past them costs is a pattern nobody writes, and the thing it closes
  is a bypass anybody can type. docs/embedding.md records the decision.

  WHAT IT DOES NOT CLAIM. Polynomial blow-up -- a*a*a*b at the top level,
  degree two -- is outside this judge: the budget's time ceiling bounds what the
  matcher may cost a CALL, not the cost of every call it is willing to start.
  The judge closes the exponential door, which is the one a forty-character
  subject can hold open for a week.

  All of it applies ONLY when the host installed a budget. }

const
  { A counted repeat of at least this many iterations is judged like an
    unbounded one. Three is low enough to catch a twenty-fold repeat of .*a and
    high enough to leave every two-iteration date shape unjudged. }
  BudgetAmbiguousRepeat = 3;

  { An ambiguous counted repeat over a loop-free body is allowed while its
    paths, P to the count, stay at or under this. 6^3 = 216 (the IPv4 quad)
    is allowed; 2^20 ((a?) twenty times) is not. }
  BudgetMaxCountedPaths = 4096;

  { THE JUDGE'S OWN LIMITS. Past any of them the pattern is refused, not
    allowed -- see the comment above. }
  MaxReDepth = 100;          // nested groups
  MaxReNodes = 262144;       // parse-tree nodes for the whole pattern
  MaxReStates = 4096;        // automaton states for one repeated body
  MaxReWork = 20000000;      // closure and product steps, for the whole pattern

  { A counted repeat whose upper count is at most this is unrolled exactly
    (one path per count, as TRegExpr walks it). A larger one is read as its
    first MaxReLoopCopies copies followed by an unbounded loop -- a SUPERSET
    of its paths, which can only make the judge refuse more. }
  MaxReUnroll = 64;
  MaxReLoopCopies = 3;

type
  TByteSet = set of Byte;

  TQuantKind = (qkNone, qkOptional, qkBounded, qkUnbounded);

  { The parse tree. rnByte consumes one byte of CSet; rnEmpty consumes nothing
    (an anchor, a zero-width escape, a lookaround, a comment, a directive);
    rnUnknown is an atom the judge cannot name; rnRep repeats its one child
    MinR..MaxR times (MaxR < 0 = unbounded). Children are a First/Next list. }
  TReNodeKind = (rnByte, rnEmpty, rnUnknown, rnCat, rnAlt, rnRep);

  TReNode = record
    Kind: TReNodeKind;
    CSet: TByteSet;
    MinR, MaxR: Int64;
    First, Last, Next: Integer;
    Group: Boolean;          // rnRep over a parenthesised group: the judged kind
    { rnRep over a group that TRegExpr compiles to OP_LOOP -- a counted repeat,
      or a lazy one -- rather than to a branch that jumps back. }
    LoopOp: Boolean;
    { A LoopOp nested in another, or holding one: its counts are not to be
      trusted, and it is read as unbounded (see MarkLoops). }
    Unsure: Boolean;
    HasParent: Boolean;
  end;

  { The modifiers in force. TRegExpr reads (?i) and (?x) as a directive that
    holds to the end of the ENCLOSING group (ParseReg saves fCompModifiers on
    entry and restores it on exit), across a '|' too, and a nested group
    inherits whatever is in force where it opens. }
  TReMods = record
    CaseFold: Boolean;       // (?i): every literal and class matches both cases
    Extended: Boolean;       // (?x): unescaped whitespace and #-comments are nothing
  end;

  { One state of a judged body's automaton: a byte state consumes one byte of
    CSet and moves to Out1; an empty state moves to Out1 and/or Out2. }
  TReState = record
    IsByte: Boolean;
    CSet: TByteSet;
    Out1, Out2: Integer;
  end;

  TReVerdict = (rvUnambiguous, rvUnknown, rvEmptyLoop, rvEmptyTwice,
                rvAmbiguous, rvTooBig);

  TReIntArray = array of Integer;

function SetOfRange(A, B: Byte): TByteSet;
var i: Integer;
begin
  Result := [];
  for i := A to B do Include(Result, Byte(i));
end;

function AllBytes: TByteSet;
begin
  Result := SetOfRange(0, 255);
end;

function DigitSet: TByteSet;
begin
  Result := SetOfRange(Ord('0'), Ord('9'));
end;

function WordSet: TByteSet;
begin
  Result := SetOfRange(Ord('a'), Ord('z')) + SetOfRange(Ord('A'), Ord('Z')) +
            DigitSet() + [Byte(Ord('_'))];
end;

function SpaceSet: TByteSet;
begin
  Result := [Byte(9), Byte(10), Byte(11), Byte(12), Byte(13), Byte(32)];
end;

{ \v and \h, as TRegExpr 0.987 defines them in a non-Unicode build:
  RegExprLineSeparators (CR LF VT FF) and RegExprHorzSeparators (TAB SPACE NBSP).
  This judge used to read \v as VT alone and \h as a literal 'h', so
  ^(\h|\x20)+$ -- two branches that both match a space -- looked disjoint. }
function VertSet: TByteSet;
begin
  Result := [Byte(10), Byte(11), Byte(12), Byte(13)];
end;

function HorzSet: TByteSet;
begin
  Result := [Byte(9), Byte(32), Byte($A0)];
end;

function AsciiLetterSet: TByteSet;
begin
  Result := SetOfRange(Ord('a'), Ord('z')) + SetOfRange(Ord('A'), Ord('Z'));
end;

function HighSet: TByteSet;
begin
  Result := SetOfRange(128, 255);
end;

function AsciiUp(B: Byte): Byte;
begin
  if (B >= Ord('a')) and (B <= Ord('z')) then Result := B - 32 else Result := B;
end;

{ What one LITERAL byte matches under (?i). TRegExpr's OP_EXACTLYCI accepts the
  byte or InvertCase of it. For ASCII that is exactly the other case. For a byte
  above 127 it is AnsiUpperCase/AnsiLowerCase of a lone byte, which depends on
  the platform and the locale (a Turkish code page maps one of them to ASCII
  'I'), so the answer is every byte it could be -- a SUPERSET, which can only
  make the judge refuse more, never call an ambiguous body unambiguous. }
function FoldLiteral(B: Byte): TByteSet;
begin
  if (B >= Ord('a')) and (B <= Ord('z')) then Result := [B, Byte(B - 32)]
  else if (B >= Ord('A')) and (B <= Ord('Z')) then Result := [B, Byte(B + 32)]
  else if B >= 128 then Result := [B] + HighSet() + AsciiLetterSet()
  else Result := [B];
end;

function HexVal(C: Char; out AVal: Integer): Boolean;
begin
  Result := True;
  if (C >= '0') and (C <= '9') then AVal := Ord(C) - Ord('0')
  else if (C >= 'a') and (C <= 'f') then AVal := Ord(C) - Ord('a') + 10
  else if (C >= 'A') and (C <= 'F') then AVal := Ord(C) - Ord('A') + 10
  else begin AVal := 0; Result := False; end;
end;

function SatAdd(A, B: Int64): Int64;
begin
  if A > High(Int64) - B then Result := High(Int64) else Result := A + B;
end;

function SatMul(A, B: Int64): Int64;
begin
  if (A = 0) or (B = 0) then Exit(0);
  if A > High(Int64) div B then Result := High(Int64) else Result := A * B;
end;

function BudgetPatternBounded(const APattern: String; out AWhy: String): Boolean;
var
  nodes: array of TReNode;
  nn: Integer;
  i, n: Integer;
  gaveUp: Boolean;
  st: array of TReState;
  ns: Integer;
  work: Int64;
  tooBig: Boolean;

  { Read the quantifier standing at i (if any) and step past it. AMax is the
    largest number of repetitions, AMin the smallest. ALoopOp answers whether,
    on a group, TRegExpr 0.987 compiles it to OP_LOOP: a counted form, or a
    lazy one (ParsePiece: EmitComplexBraces); a greedy * + ? on a group is a
    branch that jumps back instead. }
  function ReadQuant(out AMin, AMax: Int64; out ALoopOp: Boolean): TQuantKind;
  var j, lo, hi: Int64; sawComma, sawHi: Boolean; c: Char;
  begin
    AMax := 1;
    AMin := 1;
    ALoopOp := False;
    Result := qkNone;
    if i > n then Exit;
    c := APattern[i];
    if c = '*' then
    begin
      Inc(i);
      AMin := 0;
      Result := qkUnbounded;
    end
    else if c = '+' then
    begin
      Inc(i);
      Result := qkUnbounded;
    end
    else if c = '?' then
    begin
      Inc(i);
      AMin := 0;
      Result := qkOptional;
    end
    else if c = '{' then
    begin
      // Only a real {n}, {n,} or {n,m} is a quantifier; a stray '{' is a literal.
      j := i + 1; lo := 0; hi := 0; sawComma := False; sawHi := False;
      while (j <= n) and (APattern[j] >= '0') and (APattern[j] <= '9') do
      begin
        if lo < 100000000 then lo := lo * 10 + (Ord(APattern[j]) - Ord('0'));
        Inc(j);
      end;
      if (j <= n) and (APattern[j] = ',') then
      begin
        sawComma := True;
        Inc(j);
        while (j <= n) and (APattern[j] >= '0') and (APattern[j] <= '9') do
        begin
          sawHi := True;
          if hi < 100000000 then hi := hi * 10 + (Ord(APattern[j]) - Ord('0'));
          Inc(j);
        end;
      end;
      if (j > n) or (APattern[j] <> '}') then Exit;   // not a quantifier at all
      i := Integer(j) + 1;
      AMin := lo;
      ALoopOp := True;
      if sawComma and not sawHi then
        Result := qkUnbounded                             // {n,}
      else
      begin
        if not sawComma then hi := lo;                    // {n}
        AMax := hi;
        if (hi <= 1) and (lo <= 0) then Result := qkOptional
        else Result := qkBounded;
      end;
    end;
    { A lazy suffix does not change how much work the worst case is -- but on a
      group it makes the repeat an OP_LOOP. A possessive '+' is a compile error
      in 0.987 (reeNestedSQP) and is stepped past the same way. }
    if (Result <> qkNone) and (i <= n) and ((APattern[i] = '?') or (APattern[i] = '+')) then
    begin
      if APattern[i] = '?' then ALoopOp := True;
      Inc(i);
    end;
  end;

  (* An escape's brace operand, \p{...} or \u{...}: step past it when it is one,
     and never past anything that is structure -- a paren, a bar, a bracket --
     or another escape. *)
  procedure SkipBraceOperand;
  var k: Integer;
  begin
    if (i > n) or (APattern[i] <> '{') then Exit;
    k := i + 1;
    while (k <= n) and (APattern[k] <> '}') do
    begin
      if APattern[k] in ['(', ')', '|', '[', ']', '\'] then Exit;
      Inc(k);
    end;
    if k <= n then i := k + 1;
  end;

  (* THE WHOLE ESCAPE, OPERAND INCLUDED. i is on the backslash; this steps past
    every byte the escape owns and answers what it matches.

    THE MEANINGS ARE TRegExpr 0.987's, read from its ParseAtom and UnQuoteChar
    (non-Unicode build): \xNN and \x{N..} are one byte, \cX is a control byte,
    \t \n \r \f \a \e are bytes, \d \D \w \W \s \S \v \V \h \H are classes,
    \b \B \A \Z are zero-width, \1..\9 are backreferences, and ANY OTHER escaped
    byte is that byte. Escaped letters this judge does not model -- \u, \p, \P,
    \z, \G, \k, \Q and the rest, and \0 -- mean a literal letter to 0.987 but
    something else to a newer TRegExpr or to PCRE, so they are UNKNOWN (and \u
    and \p take their operand with them, so a hex digit is never left behind to
    pass for something it is not). An unknown atom inside a repeated body
    refuses -- see JudgeRepeat -- because a set this judge cannot name is a set
    it cannot prove anything about.

    ACode is the single byte the escape stands for when it is a literal (a
    class uses it as a range end, and (?i) folds it), and -1 otherwise.
    Inside a class 0.987 has no zero-width escapes and no backreferences: \b is
    a letter there, so in a class those are unknown too. *)
  procedure ReadEscape(AInClass: Boolean; out ASet: TByteSet;
                       out AKnown, AZeroWidth: Boolean; out ACode: Integer);
  var c: Char; v, d, k: Integer;
  begin
    ASet := [];
    AKnown := True;
    AZeroWidth := False;
    ACode := -1;
    Inc(i);                                  // past the backslash
    if i > n then begin AKnown := False; Exit; end;   // trailing '\': rejected anyway
    c := APattern[i];
    Inc(i);                                  // past the escape letter
    case c of
      'd': ASet := DigitSet();
      'D': ASet := AllBytes() - DigitSet();
      'w': ASet := WordSet();
      'W': ASet := AllBytes() - WordSet();
      's': ASet := SpaceSet();
      'S': ASet := AllBytes() - SpaceSet();
      'v': ASet := VertSet();
      'V': ASet := AllBytes() - VertSet();
      'h': ASet := HorzSet();
      'H': ASet := AllBytes() - HorzSet();
      't': ACode := 9;
      'n': ACode := 10;
      'r': ACode := 13;
      'f': ACode := 12;
      'a': ACode := 7;
      'e': ACode := 27;
      'c':
        if (i <= n) and (APattern[i] in ['a'..'z', 'A'..'Z']) then
        begin
          ACode := Ord(UpCase(APattern[i])) - Ord('A') + 1;
          Inc(i);
        end
        else
          AKnown := False;                   // the engine rejects it
      'x':
        if (i <= n) and (APattern[i] = '{') then
        begin
          k := i + 1;
          v := 0;
          while (k <= n) and HexVal(APattern[k], d) do
          begin
            if v <= $FFFF then v := v * 16 + d;
            Inc(k);
          end;
          if (k <= n) and (APattern[k] = '}') and (k > i + 1) and (v <= 255) then
            ACode := v
          else
            AKnown := False;                 // too big for a byte, or malformed
          if (k <= n) and (APattern[k] = '}') then i := k + 1 else i := k;
        end
        else if (i + 1 <= n) and HexVal(APattern[i], d) and HexVal(APattern[i + 1], v) then
        begin
          ACode := d * 16 + v;
          Inc(i, 2);
        end
        else
          AKnown := False;                   // the engine rejects it
      'b', 'B', 'A', 'Z':
        if AInClass then AKnown := False
        else begin AKnown := False; AZeroWidth := True; end;
      '1'..'9':
        AKnown := False;                     // a backreference: any text at all
      'u':
        begin
          AKnown := False;
          if (i <= n) and (APattern[i] = '{') then SkipBraceOperand()
          else
          begin
            k := 0;
            while (k < 4) and (i <= n) and HexVal(APattern[i], d) do
            begin
              Inc(i);
              Inc(k);
            end;
          end;
        end;
      'p', 'P':
        begin
          AKnown := False;
          if (i <= n) and (APattern[i] = '{') then SkipBraceOperand()
          else if (i <= n) and (APattern[i] in ['a'..'z', 'A'..'Z']) then Inc(i);
        end;
      '0', 'g', 'i'..'m', 'o', 'q', 'y', 'z',
      'C', 'E'..'G', 'I'..'O', 'Q', 'R', 'T', 'U', 'X', 'Y':
        AKnown := False;                     // an escape this judge does not model
    else
      ACode := Ord(c);                       // an escaped byte is that byte
    end;
    if ACode >= 0 then ASet := [Byte(ACode)];
  end;

  { Step past a [...] class and answer the bytes it can match.

    The grammar is TRegExpr 0.987's: a ']' first is a literal, a '-' last is a
    literal, a range's ends may be escapes (\x41-\x5A), and a class escape such
    as \d cannot begin a range.

    UNDER (?i) THE ENGINE UPPER-CASES. It stores every item upper-cased and
    tests _UpperCase(subject) against them (FindInCharClass), so an ASCII
    subject matches exactly when its upper case is in the upper-cased items --
    which is computed here exactly. A subject above 127 upper-cases by the
    locale, so it is counted as possibly matching any non-empty class. A NEGATED
    class matches what the positive one does not, so its superset is everything
    an ASCII subject provably avoids, plus every byte above 127. }
  procedure ClassSet(AFold: Boolean; out ASet: TByteSet; out AKnown: Boolean);
  var
    neg, hiItem, hiRange: Boolean;
    lo, hi, code, b: Integer;
    raw, up, esc: TByteSet;
    ek, ez: Boolean;
  begin
    ASet := [];
    AKnown := True;
    raw := [];
    up := [];
    hiItem := False;
    hiRange := False;
    neg := False;
    Inc(i);                                  // past '['
    if (i <= n) and (APattern[i] = '^') then begin neg := True; Inc(i); end;
    // A ']' first is a member, not the end, so the loop's own test lets the
    // first item through whatever it is: b counts the items taken so far.
    b := 0;
    while (i <= n) and ((APattern[i] <> ']') or (b = 0)) do
    begin
      Inc(b);
      if (APattern[i] = '-') and (i + 1 <= n) and (APattern[i + 1] = ']') then
      begin
        lo := Ord('-');                      // a '-' last is a literal
        Inc(i);
      end
      else if APattern[i] = '\' then
      begin
        ReadEscape(True, esc, ek, ez, code);
        if not ek then begin AKnown := False; Continue; end;
        if code < 0 then
        begin
          // a class escape: a set, and it cannot begin a range
          raw := raw + esc;
          up := up + esc;
          Continue;
        end;
        lo := code;
      end
      else
      begin
        lo := Ord(APattern[i]);
        Inc(i);
      end;
      // A range: this item, a '-', and an end that is not the closing ']'.
      if (i + 1 <= n) and (APattern[i] = '-') and (APattern[i + 1] <> ']') then
      begin
        Inc(i);                              // past '-'
        if APattern[i] = '\' then
        begin
          ReadEscape(True, esc, ek, ez, code);
          if (not ek) or (code < 0) then begin AKnown := False; Continue; end;
          hi := code;
        end
        else
        begin
          hi := Ord(APattern[i]);
          Inc(i);
        end;
        if hi < lo then begin AKnown := False; Continue; end;   // rejected, or (?r)
        raw := raw + SetOfRange(Byte(lo), Byte(hi));
        if (lo < 128) and (hi < 128) then
          up := up + SetOfRange(AsciiUp(Byte(lo)), AsciiUp(Byte(hi)))
        else
          hiRange := True;
      end
      else
      begin
        Include(raw, Byte(lo));
        if lo < 128 then Include(up, AsciiUp(Byte(lo))) else hiItem := True;
      end;
    end;
    if (i <= n) and (APattern[i] = ']') then Inc(i)
    else AKnown := False;                    // unterminated: the engine rejects it
    if not AFold then
    begin
      if neg then ASet := AllBytes() - raw else ASet := raw;
      Exit;
    end;
    ASet := [];
    for b := 0 to 127 do
      if (AsciiUp(Byte(b)) in up) <> neg then Include(ASet, Byte(b));
    if neg then
      ASet := ASet + HighSet()
    else if hiRange then
      ASet := AllBytes()
    else
    begin
      if (up <> []) or hiItem then ASet := ASet + HighSet();
      if hiItem then ASet := ASet + AsciiLetterSet();
    end;
  end;

  { A modifier string such as i, -i, ix-s: what TRegExpr's ParseModifiers
    reads. Only the two that change what an atom matches are tracked. }
  procedure ApplyModifiers(var M: TReMods; AFrom, ATo: Integer);
  var k: Integer; isOn: Boolean;
  begin
    isOn := True;
    for k := AFrom to ATo do
      case APattern[k] of
        '-': isOn := False;
        'i', 'I': M.CaseFold := isOn;
        'x', 'X': M.Extended := isOn;
      end;
  end;

  // --- the parse tree -------------------------------------------------------

  { Node 0 is a spare empty node that nothing links: past MaxReNodes every
    new node is it, and the verdict is already "too large to judge". }
  function NewNode(AKind: TReNodeKind): Integer;
  begin
    if nn >= MaxReNodes then
    begin
      gaveUp := True;
      Exit(0);
    end;
    if nn >= Length(nodes) then SetLength(nodes, nn * 2 + 16);
    nodes[nn].Kind := AKind;
    nodes[nn].CSet := [];
    nodes[nn].MinR := 1;
    nodes[nn].MaxR := 1;
    nodes[nn].First := -1;
    nodes[nn].Last := -1;
    nodes[nn].Next := -1;
    nodes[nn].Group := False;
    nodes[nn].LoopOp := False;
    nodes[nn].Unsure := False;
    nodes[nn].HasParent := False;
    Result := nn;
    Inc(nn);
  end;

  function ByteNode(const ASet: TByteSet): Integer;
  begin
    Result := NewNode(rnByte);
    nodes[Result].CSet := ASet;
  end;

  procedure AddKid(AParent, AKid: Integer);
  begin
    if gaveUp then Exit;
    if nodes[AParent].First < 0 then nodes[AParent].First := AKid
    else nodes[nodes[AParent].Last].Next := AKid;
    nodes[AParent].Last := AKid;
    nodes[AKid].HasParent := True;
  end;

  function ParseAlt(var M: TReMods; ADepth: Integer): Integer; forward;

  { One atom at i. AGroup answers whether it was a parenthesised group, which
    is what makes a quantifier on it a judged repeat. }
  function ParseAtom(var M: TReMods; ADepth: Integer; out AGroup: Boolean): Integer;
  var
    c: Char;
    aset: TByteSet;
    aknown, azero, look: Boolean;
    code, j: Integer;
    m2: TReMods;
  begin
    AGroup := False;
    c := APattern[i];
    case c of
      '\':
        begin
          ReadEscape(False, aset, aknown, azero, code);
          if azero then Exit(NewNode(rnEmpty));
          if not aknown then Exit(NewNode(rnUnknown));
          if (code >= 0) and M.CaseFold then aset := FoldLiteral(Byte(code));
          Result := ByteNode(aset);
        end;
      '[':
        begin
          ClassSet(M.CaseFold, aset, aknown);
          if aknown then Result := ByteNode(aset) else Result := NewNode(rnUnknown);
        end;
      '^', '$':
        begin
          Inc(i);                            // zero-width anchors
          Result := NewNode(rnEmpty);
        end;
      '.':
        begin
          Inc(i);
          Result := ByteNode(AllBytes());
        end;
      '*', '+', '?':
        { A quantifier with nothing before it is, to TRegExpr, a quantifier on
          the zero-width piece before it -- under (?x) the blank in `(a) ?` --
          or a compile error. Either way it repeats something that consumes
          nothing: an empty node, and the caller reads the quantifier. }
        Result := NewNode(rnEmpty);
      '(':
        begin
          { A MODIFIER DIRECTIVE OR A COMMENT IS NOT A GROUP. TRegExpr emits a
            comment node for (?i) and (?#...), consuming nothing. (?i:...) -- a
            scoped group, which 0.987 rejects and a newer TRegExpr accepts --
            is a group with the modifiers applied to it alone. }
          if (i + 1 <= n) and (APattern[i + 1] = '?') then
          begin
            if (i + 2 <= n) and (APattern[i + 2] = '#') then
            begin
              i := i + 3;
              while (i <= n) and (APattern[i] <> ')') do Inc(i);
              if i <= n then Inc(i);
              Exit(NewNode(rnEmpty));
            end;
            j := i + 2;
            while (j <= n) and (APattern[j] in ['i', 'I', 'r', 'R', 's', 'S', 'g', 'G',
                                                 'm', 'M', 'x', 'X', '-']) do Inc(j);
            if (j > i + 2) and (j <= n) and (APattern[j] = ')') then
            begin
              ApplyModifiers(M, i + 2, j - 1);
              i := j + 1;
              Exit(NewNode(rnEmpty));
            end;
            if (j > i + 2) and (j <= n) and (APattern[j] = ':') then
            begin
              m2 := M;
              ApplyModifiers(m2, i + 2, j - 1);
              i := j + 1;
              Result := ParseAlt(m2, ADepth + 1);
              if (i <= n) and (APattern[i] = ')') then Inc(i);
              AGroup := True;
              Exit;
            end;
          end;
          Inc(i);
          // A group inherits the modifiers in force where it opens.
          m2 := M;
          look := False;
          if (i <= n) and (APattern[i] = '?') then
          begin
            Inc(i);
            if (i <= n) and ((APattern[i] = ':') or (APattern[i] = '>')) then Inc(i)
            else if (i <= n) and ((APattern[i] = '=') or (APattern[i] = '!')) then
            begin
              look := True;                           // lookahead
              Inc(i);
            end
            else if (i <= n) and (APattern[i] = '<') then
            begin
              Inc(i);
              if (i <= n) and ((APattern[i] = '=') or (APattern[i] = '!')) then
              begin
                look := True;                         // lookbehind
                Inc(i);
              end
              else
                while (i <= n) and (APattern[i] <> '>') do Inc(i);   // (?<name>
              if (i <= n) and (APattern[i] = '>') then Inc(i);
            end
            else if (i <= n) and (APattern[i] = 'P') then
            begin
              Inc(i);
              while (i <= n) and (APattern[i] <> '>') do Inc(i);
              if (i <= n) and (APattern[i] = '>') then Inc(i);
            end
            else
              // Any other (? form, which 0.987 rejects at compile time: step to
              // its ')', and the group is empty.
              while (i <= n) and (APattern[i] <> ')') do Inc(i);
          end;
          Result := ParseAlt(m2, ADepth + 1);
          if (i <= n) and (APattern[i] = ')') then Inc(i);
          { A LOOKAROUND CONSUMES NOTHING. Its own repeats are in the tree and
            are judged like any other -- the matcher backtracks inside it -- but
            where it stands it is an empty node: it neither starts, ends nor
            divides an iteration of anything around it. }
          if look then Exit(NewNode(rnEmpty));
          AGroup := True;
        end;
    else
      begin
        if M.CaseFold then aset := FoldLiteral(Byte(Ord(c)))
        else aset := [Byte(Ord(c))];
        Inc(i);
        Result := ByteNode(aset);
      end;
    end;
  end;

  { One branch: atoms and their quantifiers, up to a '|', a ')' or the end. }
  function ParseSeq(var M: TReMods; ADepth: Integer): Integer;
  var
    seq, atom, r: Integer;
    c: Char;
    grp, loopOp: Boolean;
    q: TQuantKind;
    qmin, qmax: Int64;
  begin
    seq := NewNode(rnCat);
    while (i <= n) and not gaveUp do
    begin
      c := APattern[i];
      { (?x): an unescaped blank and a #-comment to the end of the line are not
        atoms (ParseAtom emits OP_COMMENT for them). Read as literals, the blank
        in (?x)^(a+ a?)+$ was a byte the a's could not consume, and the body is
        (a+a?)+. }
      if M.Extended and (c in [' ', #9, #10, #13]) then
      begin
        Inc(i);
        Continue;
      end;
      if M.Extended and (c = '#') then
      begin
        while (i <= n) and (APattern[i] <> #10) and (APattern[i] <> #13) do Inc(i);
        Continue;
      end;
      if (c = '|') or (c = ')') then Break;
      atom := ParseAtom(M, ADepth, grp);
      q := ReadQuant(qmin, qmax, loopOp);
      if q <> qkNone then
      begin
        r := NewNode(rnRep);
        nodes[r].MinR := qmin;
        if q = qkUnbounded then nodes[r].MaxR := -1
        else if qmax < qmin then nodes[r].MaxR := qmin   // {5,2}: rejected anyway
        else nodes[r].MaxR := qmax;
        nodes[r].Group := grp;
        nodes[r].LoopOp := grp and loopOp;
        AddKid(r, atom);
        atom := r;
      end;
      AddKid(seq, atom);
    end;
    Result := seq;
  end;

  function ParseAlt(var M: TReMods; ADepth: Integer): Integer;
  var alt: Integer;
  begin
    if ADepth > MaxReDepth then
    begin
      gaveUp := True;
      i := n + 1;
      Exit(0);
    end;
    alt := NewNode(rnAlt);
    repeat
      AddKid(alt, ParseSeq(M, ADepth));
      if gaveUp or (i > n) or (APattern[i] <> '|') then Break;
      Inc(i);
    until False;
    Result := alt;
  end;

  (* NESTED OP_LOOPs DO NOT COUNT. TRegExpr 0.987 keeps a counted (or lazy)
     group repeat's iteration count in LoopStack[LoopStackIdx], one slot per
     nesting depth, and OP_LOOPENTRY zeroes the slot on entry -- while an
     earlier instance of a loop at that depth may still be on the backtracking
     stack, to be resumed with somebody else's count. Measured: the group
     "a, one to two times" taken one to two times and that taken twice should
     match two to eight a's, and matches nine and twelve but not two; with
     "aa" appended and taken four times it ran 219 ms on 28 a's, doubling every
     byte and a half, where its 6^4 paths would be instant. The judge's model
     of a count is therefore only true of an OP_LOOP that neither holds
     another nor sits inside one; for those, the only safe reading is a loop
     with no bound at either end -- a superset of whatever the counters do.
     Answers whether the subtree holds an OP_LOOP. *)
  function MarkLoops(K: Integer; AInside: Boolean): Boolean;
  var c: Integer; isLoop, below: Boolean;
  begin
    isLoop := (nodes[K].Kind = rnRep) and nodes[K].LoopOp;
    below := False;
    c := nodes[K].First;
    while c >= 0 do
    begin
      if MarkLoops(c, AInside or isLoop) then below := True;
      c := nodes[c].Next;
    end;
    if isLoop and (AInside or below) then nodes[K].Unsure := True;
    Result := isLoop or below;
  end;

  { Does the subtree hold an atom the judge cannot name? }
  function HasUnknown(K: Integer): Boolean;
  var c: Integer;
  begin
    if nodes[K].Kind = rnUnknown then Exit(True);
    c := nodes[K].First;
    while c >= 0 do
    begin
      if HasUnknown(c) then Exit(True);
      c := nodes[c].Next;
    end;
    Result := False;
  end;

  { Does the subtree hold a loop -- an unbounded repeat, or a count too large
    to unroll, which Build reads as one? }
  function HasLoop(K: Integer): Boolean;
  var c: Integer;
  begin
    if (nodes[K].Kind = rnRep) and
       ((nodes[K].MaxR < 0) or (nodes[K].MaxR > MaxReUnroll) or
        nodes[K].Unsure) then Exit(True);
    c := nodes[K].First;
    while c >= 0 do
    begin
      if HasLoop(c) then Exit(True);
      c := nodes[c].Next;
    end;
    Result := False;
  end;

  { The largest product of nested counted repeats in the subtree: a group
    repeated 0..1000 times over a body repeated 0..1000 times is a million. }
  function Reps(K: Integer): Int64;
  var c: Integer; r: Int64;
  begin
    Result := 1;
    c := nodes[K].First;
    while c >= 0 do
    begin
      r := Reps(c);
      if r > Result then Result := r;
      c := nodes[c].Next;
    end;
    if (nodes[K].Kind = rnRep) and (nodes[K].MaxR > 1) then
      Result := SatMul(Result, nodes[K].MaxR);
  end;

  // --- the automaton of one repeated body -----------------------------------

  function NewState(AIsByte: Boolean; const ASet: TByteSet; AOut1, AOut2: Integer): Integer;
  begin
    if ns >= MaxReStates then
    begin
      tooBig := True;
      Exit(0);
    end;
    st[ns].IsByte := AIsByte;
    st[ns].CSet := ASet;
    st[ns].Out1 := AOut1;
    st[ns].Out2 := AOut2;
    Result := ns;
    Inc(ns);
    Inc(work);
  end;

  { Thompson's construction, in continuation form: the states that match node
    K and then go on to ANext; answers the entry state. One path per
    alternative, per count of a counted repeat, per way of matching nothing --
    exactly the choices TRegExpr's backtracker makes, so the paths here are its
    attempts. }
  function Build(K, ANext: Integer): Integer;
  var
    kids: array of Integer;
    c, m, j, s, t, loopAt, copies, optional: Integer;
    mn, mx: Int64;
  begin
    Result := ANext;
    if tooBig then Exit;
    case nodes[K].Kind of
      rnByte:
        Result := NewState(True, nodes[K].CSet, ANext, -1);
      rnEmpty, rnUnknown:
        Result := ANext;               // an unknown never reaches here: JudgeRepeat
      rnCat, rnAlt:
        begin
          m := 0;
          kids := nil;
          c := nodes[K].First;
          while c >= 0 do
          begin
            SetLength(kids, m + 1);
            kids[m] := c;
            Inc(m);
            c := nodes[c].Next;
          end;
          if m = 0 then Exit(ANext);
          if nodes[K].Kind = rnCat then
          begin
            s := ANext;
            for j := m - 1 downto 0 do s := Build(kids[j], s);
          end
          else
          begin
            // a chain of two-way splits: exactly one empty route per branch
            s := Build(kids[m - 1], ANext);
            for j := m - 2 downto 0 do
            begin
              t := Build(kids[j], ANext);
              s := NewState(False, [], t, s);
            end;
          end;
          Result := s;
        end;
      rnRep:
        begin
          c := nodes[K].First;
          mn := nodes[K].MinR;
          mx := nodes[K].MaxR;
          if nodes[K].Unsure then
          begin
            mn := 0;                   // its counter is not to be trusted
            mx := -1;
          end;
          if (mx < 0) or (mx > MaxReUnroll) then
          begin
            // X{m,} -- and a count too large to unroll -- as its first copies
            // and then a loop: a superset of its paths.
            loopAt := NewState(False, [], -1, ANext);
            t := Build(c, loopAt);
            st[loopAt].Out1 := t;
            s := loopAt;
            if mn > MaxReLoopCopies then copies := MaxReLoopCopies
            else copies := Integer(mn);
            for j := 1 to copies do s := Build(c, s);
          end
          else
          begin
            // X{m,n} as m copies and then n-m nested optional ones: one path
            // per count, as the matcher counts. Both are at most MaxReUnroll.
            s := ANext;
            optional := Integer(mx - mn);
            copies := Integer(mn);
            for j := 1 to optional do
            begin
              t := Build(c, s);
              s := NewState(False, [], t, ANext);
            end;
            for j := 1 to copies do s := Build(c, s);
          end;
          Result := s;
        end;
    end;
  end;

  { An order of the EMPTY states in which every empty move goes forward, or
    False when an empty move can come back to where it started -- a body that
    can go round while consuming nothing. }
  function EmptyOrder(out AOrder: TReIntArray; out ACount: Integer): Boolean;
  var
    color: array of Byte;
    stackS, stackE: array of Integer;
    sp, s0, v, e, w: Integer;
  begin
    Result := True;
    SetLength(color, ns);
    SetLength(stackS, ns + 1);
    SetLength(stackE, ns + 1);
    SetLength(AOrder, ns);
    ACount := 0;
    for s0 := 0 to ns - 1 do
    begin
      if st[s0].IsByte or (color[s0] <> 0) then Continue;
      sp := 0;
      stackS[0] := s0;
      stackE[0] := 0;
      color[s0] := 1;
      while sp >= 0 do
      begin
        v := stackS[sp];
        e := stackE[sp];
        Inc(stackE[sp]);
        Inc(work);
        if e = 0 then w := st[v].Out1
        else if e = 1 then w := st[v].Out2
        else
        begin
          color[v] := 2;                     // finished: post-order
          AOrder[ACount] := v;
          Inc(ACount);
          Dec(sp);
          Continue;
        end;
        if (w < 0) or st[w].IsByte then Continue;
        if color[w] = 1 then Exit(False);    // back to a state still open
        if color[w] = 0 then
        begin
          color[w] := 1;
          Inc(sp);
          stackS[sp] := w;
          stackE[sp] := 0;
        end;
      end;
    end;
  end;

  { THE TEST. Is the repeat of node X, taken round and round, ambiguous? }
  function JudgeRepeat(X: Integer): TReVerdict;
  var
    exitAt, loopAt, t, k, u, v, j, p, q, a, b, a2, b2, ia, ib, head, tail: Integer;
    order: TReIntArray;
    nOrder: Integer;
    cnt: array of Byte;
    adjStart, adjTo: array of Integer;
    nAdj: Integer;
    seen: array of Byte;
    queue: array of Integer;
    idx: Int64;
  begin
    if HasUnknown(X) then Exit(rvUnknown);
    ns := 0;
    tooBig := False;
    exitAt := NewState(False, [], -1, -1);
    loopAt := NewState(False, [], -1, exitAt);
    t := Build(X, loopAt);
    st[loopAt].Out1 := t;
    if tooBig then Exit(rvTooBig);

    if not EmptyOrder(order, nOrder) then Exit(rvEmptyLoop);

    { FOLD THE EMPTY MOVES INTO EDGES between byte states, counting the empty
      routes (saturating at 2). Every byte state lies on the loop's cycle, so
      every edge found here is inside the one strongly connected component the
      test is about. }
    SetLength(cnt, ns);
    SetLength(adjStart, ns + 1);
    adjTo := nil;
    nAdj := 0;
    for u := 0 to ns - 1 do
    begin
      adjStart[u] := nAdj;
      if not st[u].IsByte then Continue;
      if work > MaxReWork then Exit(rvTooBig);
      FillChar(cnt[0], ns, 0);
      cnt[st[u].Out1] := 1;
      // reverse post-order of the empty states is a topological order
      for j := nOrder - 1 downto 0 do
      begin
        v := order[j];
        if cnt[v] = 0 then Continue;
        if st[v].Out1 >= 0 then
          if cnt[st[v].Out1] + cnt[v] >= 2 then cnt[st[v].Out1] := 2
          else cnt[st[v].Out1] := cnt[st[v].Out1] + cnt[v];
        if st[v].Out2 >= 0 then
          if cnt[st[v].Out2] + cnt[v] >= 2 then cnt[st[v].Out2] := 2
          else cnt[st[v].Out2] := cnt[st[v].Out2] + cnt[v];
      end;
      Inc(work, ns);
      for v := 0 to ns - 1 do
        if st[v].IsByte and (cnt[v] > 0) then
        begin
          // two empty routes from one byte to the next: nothing matched twice
          if cnt[v] >= 2 then Exit(rvEmptyTwice);
          if st[v].CSet = [] then Continue;  // a state no byte can enter
          if nAdj >= Length(adjTo) then SetLength(adjTo, nAdj * 2 + 64);
          adjTo[nAdj] := v;
          Inc(nAdj);
        end;
    end;
    adjStart[ns] := nAdj;

    { THE PRODUCT, searched from every diagonal pair. A pair (a,b), a < b, is
      the two copies of the automaton in two different states after the same
      text; reaching one from (p,p) and then the diagonal again from it is two
      different paths from p round to the same state on the same text. }
    SetLength(seen, (Int64(ns) * ns) div 8 + 1);
    queue := nil;
    head := 0;
    tail := 0;
    for p := 0 to ns - 1 do
    begin
      if (not st[p].IsByte) or (st[p].CSet = []) then Continue;
      for ia := adjStart[p] to adjStart[p + 1] - 1 do
        for ib := ia + 1 to adjStart[p + 1] - 1 do
        begin
          Inc(work);
          a := adjTo[ia];
          b := adjTo[ib];
          if (st[a].CSet * st[b].CSet) = [] then Continue;
          if a > b then begin k := a; a := b; b := k; end;
          idx := Int64(a) * ns + b;
          if (seen[idx shr 3] and (1 shl (idx and 7))) <> 0 then Continue;
          seen[idx shr 3] := seen[idx shr 3] or (1 shl (idx and 7));
          if tail + 2 > Length(queue) then SetLength(queue, tail * 2 + 64);
          queue[tail] := a;
          queue[tail + 1] := b;
          Inc(tail, 2);
        end;
      if work > MaxReWork then Exit(rvTooBig);
    end;
    while head < tail do
    begin
      a := queue[head];
      b := queue[head + 1];
      Inc(head, 2);
      for ia := adjStart[a] to adjStart[a + 1] - 1 do
        for ib := adjStart[b] to adjStart[b + 1] - 1 do
        begin
          Inc(work);
          a2 := adjTo[ia];
          b2 := adjTo[ib];
          if a2 = b2 then Exit(rvAmbiguous);   // back on the diagonal
          if (st[a2].CSet * st[b2].CSet) = [] then Continue;
          if a2 > b2 then begin q := a2; a2 := b2; b2 := q; end;
          idx := Int64(a2) * ns + b2;
          if (seen[idx shr 3] and (1 shl (idx and 7))) <> 0 then Continue;
          seen[idx shr 3] := seen[idx shr 3] or (1 shl (idx and 7));
          if tail + 2 > Length(queue) then SetLength(queue, tail * 2 + 64);
          queue[tail] := a2;
          queue[tail + 1] := b2;
          Inc(tail, 2);
        end;
      if work > MaxReWork then Exit(rvTooBig);
    end;
    Result := rvUnambiguous;
  end;

  { How many paths a LOOP-FREE body has from its entry to its exit, saturating;
    -1 when it is too big to build. }
  function PathCount(X: Integer): Int64;
  var
    exitAt, entry, s0, v, e, w, sp, j: Integer;
    paths: array of Int64;
    color: array of Byte;
    stackS, stackE, order: array of Integer;
    nOrder: Integer;
  begin
    ns := 0;
    tooBig := False;
    exitAt := NewState(False, [], -1, -1);
    entry := Build(X, exitAt);
    if tooBig then Exit(-1);
    SetLength(color, ns);
    SetLength(stackS, ns + 1);
    SetLength(stackE, ns + 1);
    SetLength(order, ns);
    nOrder := 0;
    s0 := entry;
    sp := 0;
    stackS[0] := s0;
    stackE[0] := 0;
    color[s0] := 1;
    while sp >= 0 do
    begin
      v := stackS[sp];
      e := stackE[sp];
      Inc(stackE[sp]);
      if e = 0 then w := st[v].Out1
      else if (e = 1) and not st[v].IsByte then w := st[v].Out2
      else
      begin
        order[nOrder] := v;
        Inc(nOrder);
        Dec(sp);
        Continue;
      end;
      if (w < 0) or (color[w] <> 0) then Continue;
      color[w] := 1;
      Inc(sp);
      stackS[sp] := w;
      stackE[sp] := 0;
    end;
    // post-order: every state after the states it leads to
    SetLength(paths, ns);
    for j := 0 to nOrder - 1 do
    begin
      v := order[j];
      if v = exitAt then paths[v] := 1
      else
      begin
        paths[v] := 0;
        if st[v].Out1 >= 0 then paths[v] := SatAdd(paths[v], paths[st[v].Out1]);
        if (not st[v].IsByte) and (st[v].Out2 >= 0) then
          paths[v] := SatAdd(paths[v], paths[st[v].Out2]);
      end;
    end;
    Result := paths[entry];
  end;

  { A counted repeat's second chance: a loop-free body whose paths, to the
    power of the count, stay small. }
  function CountedSmall(X: Integer; ACount: Int64): Boolean;
  var p, total: Int64; j: Int64;
  begin
    if HasLoop(X) then Exit(False);
    p := PathCount(X);
    if p < 0 then Exit(False);
    total := 1;
    j := 0;
    while (j < ACount) and (total <= BudgetMaxCountedPaths) do
    begin
      total := SatMul(total, p);
      Inc(j);
    end;
    Result := total <= BudgetMaxCountedPaths;
  end;

var
  m0: TReMods;
  k: Integer;
  mx, total: Int64;
  v: TReVerdict;
begin
  AWhy := '';
  Result := True;
  n := Length(APattern);
  if n = 0 then Exit;
  nn := 0;
  nodes := nil;
  NewNode(rnEmpty);                    // node 0: the spare
  gaveUp := False;
  work := 0;
  // RegexGuard's TRegExpr starts with the library defaults, ModifierI and
  // ModifierX both off (RegExprModifierI/X in regexpr.pas).
  m0.CaseFold := False;
  m0.Extended := False;
  i := 1;
  ParseAlt(m0, 1);
  // A ')' with nothing open is the engine's to reject; read on past it, so a
  // repeat after it is still judged.
  while (i <= n) and not gaveUp do
  begin
    Inc(i);
    ParseAlt(m0, 1);
  end;
  if gaveUp then
  begin
    AWhy := 'a pattern nested deeper than ' + IntToStr(MaxReDepth) + ' groups or ' +
            'longer than ' + IntToStr(MaxReNodes) + ' atoms is too large for the ' +
            'judge to read, and what it has not read it cannot call safe';
    Exit(False);
  end;

  { THE JUDGEMENT. A repeat is created after everything inside it, so walking
    the nodes in order judges the innermost repeat first. }
  for k := 1 to nn - 1 do
    if not nodes[k].HasParent then MarkLoops(k, False);
  st := nil;
  for k := 1 to nn - 1 do
  begin
    if (nodes[k].Kind <> rnRep) or not nodes[k].Group then Continue;
    mx := nodes[k].MaxR;
    if nodes[k].Unsure then mx := -1;  // judged as the loop it may become
    if (mx < 0) or (mx >= BudgetAmbiguousRepeat) then
    begin
      if st = nil then SetLength(st, MaxReStates);
      v := JudgeRepeat(nodes[k].First);
      { A NULLABLE body gets no second chance. Its paths are few -- (a?) four
        times is sixteen -- but TRegExpr 0.987 either rejects it at compile
        ("operand could be empty") or, when a counted repeat from zero hides the
        nullability from that check, recurses without end computing its
        first-character set; the old judge refused it too. }
      if (mx >= 0) and (v in [rvEmptyTwice, rvAmbiguous]) and
         CountedSmall(nodes[k].First, mx) then
        v := rvUnambiguous;
      if (v = rvTooBig) or (work > MaxReWork) then
      begin
        AWhy := 'a repeat of a group too large for the judge to finish (past ' +
                IntToStr(MaxReStates) + ' states or ' + IntToStr(MaxReWork) +
                ' steps of search), and what it has not read it cannot call safe';
        Exit(False);
      end;
      case v of
        rvUnknown:
          AWhy := 'a repeat of a group holding an atom the judge cannot name -- a ' +
                  'backreference, or an escape it does not model -- cannot be ' +
                  'proved unambiguous';
        rvEmptyLoop:
          AWhy := 'a repeat of a group that can match the empty string (the (a*)* ' +
                  'shape) can go round without consuming anything';
        rvEmptyTwice:
          AWhy := 'a repeat of a group that can match the empty string in more ' +
                  'than one way (the (c()?)+ shape) can take exponentially many ' +
                  'attempts';
        rvAmbiguous:
          if mx < 0 then
            AWhy := 'a repeat of a group whose body can match the same text in ' +
                    'more than one way (the (a+)+, (a|a)+ and (a*a*b)+ shapes) can ' +
                    'take exponentially many attempts -- a separator no part of ' +
                    'the body can consume, and branches that cannot match the same ' +
                    'text, would make it linear'
          else
            AWhy := 'a counted repeat of ' + IntToStr(mx) +
                    ' iterations over a body that can match the same text in ' +
                    'more than one way (the (a+){10} shape) can take ' +
                    'exponentially many attempts';
      else
        ;                                    // unambiguous: nothing to say
      end;
      if v <> rvUnambiguous then
      begin
        if (v = rvEmptyLoop) and (mx >= 0) then
          AWhy := 'a counted repeat of ' + IntToStr(mx) + ' iterations over a ' +
                  'body that can match the empty string (the (a?){20} shape) ' +
                  'divides the same text among its iterations in too many ways'
        else if (v = rvEmptyTwice) and (mx >= 0) then
          AWhy := 'a counted repeat of ' + IntToStr(mx) + ' iterations over a ' +
                  'body that matches the empty string in more than one way has ' +
                  'more paths than the judge allows (' +
                  IntToStr(BudgetMaxCountedPaths) + ')';
        Exit(False);
      end;
    end;
    if mx > 1 then
    begin
      total := SatMul(Reps(nodes[k].First), mx);
      if total > BudgetMaxRepeatProduct then
      begin
        AWhy := 'nested counted repeats expand to more than ' +
                IntToStr(BudgetMaxRepeatProduct) + ' repetitions';
        Exit(False);
      end;
    end;
  end;
  // The outermost level is not inside any repeat, so what it does once is
  // linear work and nothing here refuses it.
end;

end.
