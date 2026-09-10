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

  and PhosphorBufferLib's IndexOfFrom, which breaks its inner loop at the first
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
  construct that can backtrack super-linearly; AWhy names it. Answers True for
  anything it cannot judge, so an exotic pattern is allowed, not refused. }
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

  WHAT THE CRITERION IS, AND WHAT IT IS NOT. The first version of this judge
  implemented "star height >= 2": a repeat of a group that itself repeats without
  bound was refused. That is not the ReDoS criterion, and it refused nearly half
  of a set of sixty real-world patterns -- a unix path, a slug, a dotted version,
  a comma-separated row, a domain name -- every one of which runs in single-digit
  milliseconds against a hostile failing subject. A guard that answers an error
  where the right answer exists is exactly as serious as the hang it replaced.

  The real criterion is the AMBIGUITY of the repeated body. (a+)+ is catastrophic
  because "aa" can be one iteration or two, so a failing tail makes the matcher
  try every way of cutting the subject up: 2^n. (\d+\.)+ is NOT, because every
  iteration must end on a '.' and \d cannot match a '.', so there is exactly ONE
  way to cut the subject up however long it is. A mandatory SEPARATOR that no
  flexible atom in the body can consume removes the ambiguity, and with it the
  blow-up.

  So a repeat of a group is refused when the body is AMBIGUOUS, which is judged
  three ways, any one of which is enough to call it safe:

    (i)   some mandatory fixed-width atom in the body has a character set
          disjoint from every flexible (optional or unbounded) atom's set;
    (ii)  the body ENDS on a mandatory fixed-width atom disjoint from the
          flexible atoms that follow the previous mandatory one;
    (iii) the body STARTS on a mandatory fixed-width atom disjoint from the
          flexible atoms that precede the next mandatory one.

  A body with no mandatory atom at all can match the empty string, which is the
  (a?)+ / (a*)* shape, and is refused. So is an alternation whose branches can
  begin on the same byte, which is the (a|ab)+ shape: there the ambiguity is
  between the branches rather than inside one.

  BOUNDED REPEATS COUNT TOO. A counted repeat -- (a+) taken ten times, or (a?)
  taken twenty times before a run of twenty a's -- carries no unbounded outer
  quantifier and the first version allowed both; both blow up (2703 ms and worse
  on a 26-character subject). A counted repeat of at least BudgetAmbiguousRepeat
  iterations over an ambiguous body is refused for the same reason -- the number
  of ways to cut the subject up is ambiguity^count either way.

  Anything this cannot parse confidently is ALLOWED, as before: a pattern nested
  past what the tables track, an unterminated class, a backreference. Every
  uncertainty resolves toward letting the pattern run, and all of it applies ONLY
  when the host installed a budget. }

const
  { A counted repeat of at least this many iterations over an ambiguous body is
    treated as unbounded work. Three is low enough to catch a twenty-fold repeat
    of .*a and high enough to leave the three-fold repeat inside an IPv4 pattern
    -- whose body is unambiguous anyway -- and every two-iteration date shape. }
  BudgetAmbiguousRepeat = 3;

type
  TByteSet = set of Byte;

  TQuantKind = (qkNone, qkOptional, qkBounded, qkUnbounded);

  { One atom of a branch, in order. KIND is what the ambiguity test needs:

      akSep   mandatory and FIXED width -- a barrier that pins an iteration
              boundary, if its set is disjoint from the flexible atoms
      akFlex  optional or unbounded -- it can slide across a boundary
      akWide  mandatory but of VARIABLE width (a group whose body is not fixed):
              it must be consumed, but it cannot pin a boundary, and whatever it
              can consume counts as flexible }
  TReAtomKind = (akSep, akFlex, akWide);

  TReAtom = record
    CSet: TByteSet;
    Known: Boolean;
    Kind: TReAtomKind;
    Branch: Integer;
  end;

const
  MaxReDepth = 48;
  MaxReBranch = 15;
  MaxReAtoms = 96;

type
  TReLevel = record
    Unbounded: Boolean;      // an unbounded quantifier occurs in this body
    Reps: Int64;             // the largest bounded-repetition product in it
    Opaque: Boolean;         // a lookaround: it consumes nothing, so no first-set
    Branches: Integer;       // how many alternatives so far (1 + the '|' count)
    First: array[0..MaxReBranch] of TByteSet;
    Known: array[0..MaxReBranch] of Boolean;
    NeedFirst: Boolean;      // still collecting the current branch's first set
    AnyFirst: Boolean;       // this branch has contributed at least one atom
    NAtoms: Integer;         // atoms recorded for the ambiguity test
    Atoms: array[0..MaxReAtoms - 1] of TReAtom;
    Overflowed: Boolean;     // more atoms than the table holds: do not judge
    FixedWidth: Boolean;     // every branch consumes a fixed number of bytes
  end;

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

function BudgetPatternBounded(const APattern: String; out AWhy: String): Boolean;
var
  lv: array[0..MaxReDepth] of TReLevel;
  top: Integer;
  i, n: Integer;
  gaveUp: Boolean;

  procedure ResetLevel(var L: TReLevel);
  var b: Integer;
  begin
    L.Unbounded := False;
    L.Reps := 1;
    L.Opaque := False;
    L.Branches := 1;
    for b := 0 to MaxReBranch do
    begin
      L.First[b] := [];
      L.Known[b] := True;
    end;
    L.NeedFirst := True;
    L.AnyFirst := False;
    L.NAtoms := 0;
    L.Overflowed := False;
    L.FixedWidth := True;
  end;

  { Read the quantifier standing at i (if any) and step past it. AMax is the
    largest number of repetitions, AMin the smallest -- the ambiguity test needs
    both, because an exact count is a fixed-width barrier and a range is not. }
  function ReadQuant(out AMin, AMax: Int64): TQuantKind;
  var j, lo, hi: Int64; sawComma, sawHi: Boolean; c: Char;
  begin
    AMax := 1;
    AMin := 1;
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
      if sawComma and not sawHi then Exit(qkUnbounded);   // {n,}
      if not sawComma then hi := lo;                      // {n}
      AMax := hi;
      if (hi <= 1) and (lo <= 0) then Exit(qkOptional);
      Result := qkBounded;
    end;
    // A lazy or possessive suffix does not change how much work the worst case is.
    if (Result <> qkNone) and (i <= n) and ((APattern[i] = '?') or (APattern[i] = '+')) then
      Inc(i);
  end;

  { Fold one consumed atom into the current branch's first-set. }
  procedure NoteAtom(const ASet: TByteSet; AKnown, AOptional: Boolean);
  var b: Integer;
  begin
    if lv[top].Opaque then Exit;
    b := lv[top].Branches - 1;
    if b > MaxReBranch then Exit;
    if not lv[top].NeedFirst then Exit;
    if AKnown then lv[top].First[b] := lv[top].First[b] + ASet
    else lv[top].Known[b] := False;
    lv[top].AnyFirst := True;
    if not AOptional then lv[top].NeedFirst := False;
  end;

  { Record one atom of the current branch, in order, for the ambiguity test. }
  procedure PushAtom(const ASet: TByteSet; AKnown: Boolean; AKind: TReAtomKind);
  var k: Integer;
  begin
    if lv[top].Opaque then Exit;               // a lookaround consumes nothing
    if AKind <> akSep then lv[top].FixedWidth := False;
    if lv[top].NAtoms >= MaxReAtoms then
    begin
      lv[top].Overflowed := True;
      Exit;
    end;
    k := lv[top].NAtoms;
    lv[top].Atoms[k].CSet := ASet;
    lv[top].Atoms[k].Known := AKnown;
    lv[top].Atoms[k].Kind := AKind;
    lv[top].Atoms[k].Branch := lv[top].Branches - 1;
    Inc(lv[top].NAtoms);
  end;

  { A quantifier's atom kind: what it does to an iteration boundary. }
  function KindOf(AQ: TQuantKind; AMin, AMax: Int64): TReAtomKind;
  begin
    case AQ of
      qkNone: Result := akSep;                              // exactly once
      qkBounded:
        if AMin = AMax then Result := akSep                 // {n}: fixed width
        else Result := akFlex;                              // {n,m}: it can slide
    else
      Result := akFlex;                                     // ?, *, +, {n,}
    end;
  end;

  { The set an escape sequence can start with. AKnown=False = do not judge it. }
  procedure EscapeSet(AChar: Char; out ASet: TByteSet; out AKnown, AZeroWidth: Boolean);
  begin
    ASet := [];
    AKnown := True;
    AZeroWidth := False;
    case AChar of
      'd': ASet := DigitSet();
      'D': ASet := AllBytes() - DigitSet();
      'w': ASet := WordSet();
      'W': ASet := AllBytes() - WordSet();
      's': ASet := SpaceSet();
      'S': ASet := AllBytes() - SpaceSet();
      'n': ASet := [Byte(10)];
      'r': ASet := [Byte(13)];
      't': ASet := [Byte(9)];
      'f': ASet := [Byte(12)];
      'v': ASet := [Byte(11)];
      'a': ASet := [Byte(7)];
      'e': ASet := [Byte(27)];
      'b', 'B', 'A', 'Z', 'z', 'G': begin AKnown := False; AZeroWidth := True; end;
      '0'..'9', 'x', 'c', 'p', 'P', 'u': AKnown := False;   // backref / numeric escape
    else
      ASet := [Byte(Ord(AChar))];
    end;
  end;

  { Step past a [...] class and answer the bytes it can match. }
  procedure ClassSet(out ASet: TByteSet; out AKnown: Boolean);
  var neg: Boolean; lo, hi: Integer; esc: TByteSet; ek, ez: Boolean; first: Boolean;
  begin
    ASet := [];
    AKnown := True;
    neg := False;
    Inc(i);                                  // past '['
    if (i <= n) and (APattern[i] = '^') then begin neg := True; Inc(i); end;
    first := True;
    while (i <= n) and ((APattern[i] <> ']') or first) do
    begin
      first := False;
      if APattern[i] = '\' then
      begin
        if i + 1 > n then begin AKnown := False; Inc(i); Break; end;
        EscapeSet(APattern[i + 1], esc, ek, ez);
        if ek then ASet := ASet + esc else AKnown := False;
        Inc(i, 2);
        Continue;
      end;
      lo := Ord(APattern[i]);
      if (i + 2 <= n) and (APattern[i + 1] = '-') and (APattern[i + 2] <> ']') then
      begin
        hi := Ord(APattern[i + 2]);
        if hi >= lo then ASet := ASet + SetOfRange(Byte(lo), Byte(hi))
        else AKnown := False;
        Inc(i, 3);
      end
      else
      begin
        Include(ASet, Byte(lo));
        Inc(i);
      end;
    end;
    if (i <= n) and (APattern[i] = ']') then Inc(i)
    else AKnown := False;                    // unterminated: do not judge it
    if neg then ASet := AllBytes() - ASet;
  end;

  { Do two of this level's branches share a possible first byte? That is the
    (a|ab)+ shape: two ways to begin an iteration is two ways to cut the subject
    up, exactly like a sliding quantifier. }
  function BranchesOverlap(const L: TReLevel): Boolean;
  var a, b, cnt: Integer;
  begin
    Result := False;
    cnt := L.Branches;
    if cnt > MaxReBranch + 1 then Exit;      // too many to have tracked: do not judge
    if cnt < 2 then Exit;
    for a := 0 to cnt - 2 do
      for b := a + 1 to cnt - 1 do
        if L.Known[a] and L.Known[b] and ((L.First[a] * L.First[b]) <> []) then
          Exit(True);
  end;

  function UnionFirst(const L: TReLevel; out ASet: TByteSet): Boolean;
  var b, cnt: Integer;
  begin
    ASet := [];
    cnt := L.Branches;
    if cnt > MaxReBranch + 1 then Exit(False);
    for b := 0 to cnt - 1 do
    begin
      if not L.Known[b] then Exit(False);
      ASet := ASet + L.First[b];
    end;
    Result := True;
  end;

  { Everything the body can consume, whatever the branch -- what a group folds
    into its parent when the group is itself quantified. }
  function ConsumedUnion(const L: TReLevel; out ASet: TByteSet): Boolean;
  var k: Integer;
  begin
    ASet := [];
    Result := True;
    for k := 0 to L.NAtoms - 1 do
    begin
      if not L.Atoms[k].Known then Exit(False);
      ASet := ASet + L.Atoms[k].CSet;
    end;
    if L.Overflowed then Result := False;
  end;

  { THE AMBIGUITY TEST. True = the body decomposes uniquely, so repeating it
    cannot take super-linearly many attempts. }
  function BodyUnambiguous(const L: TReLevel): Boolean;
  var
    flexAll: TByteSet;
    k, b, cnt, firstK, lastK, w: Integer;
    anyMandatory, branchOk, windowKnown: Boolean;
    window: TByteSet;
  begin
    Result := False;
    if L.Overflowed then Exit;                 // more than the table holds
    if L.NAtoms = 0 then Exit;                 // an empty body matches everywhere
    cnt := L.Branches;
    if cnt > MaxReBranch + 1 then Exit;

    { The union of every atom that can slide -- optional, unbounded, or a
      variable-width group. Taken across ALL branches, because iteration k may
      use one branch and iteration k+1 another. An unknown set poisons it: a
      backreference or a Unicode property escape could match anything. }
    flexAll := [];
    for k := 0 to L.NAtoms - 1 do
      if L.Atoms[k].Kind <> akSep then
      begin
        if not L.Atoms[k].Known then Exit;
        flexAll := flexAll + L.Atoms[k].CSet;
      end;

    for b := 0 to cnt - 1 do
    begin
      branchOk := False;
      anyMandatory := False;
      firstK := -1;
      lastK := -1;
      for k := 0 to L.NAtoms - 1 do
        if L.Atoms[k].Branch = b then
        begin
          if L.Atoms[k].Kind <> akFlex then anyMandatory := True;
          if firstK < 0 then firstK := k;
          lastK := k;
        end;
      // A branch that can match nothing at all is the (a?)+ shape: every
      // position can be split any number of ways.
      if not anyMandatory then Exit;

      // (i) some fixed-width mandatory atom no flexible atom can consume.
      for k := 0 to L.NAtoms - 1 do
        if (L.Atoms[k].Branch = b) and (L.Atoms[k].Kind = akSep) and
           L.Atoms[k].Known and ((L.Atoms[k].CSet * flexAll) = []) then
        begin
          branchOk := True;
          Break;
        end;

      // (ii) the branch ENDS on a barrier: only the flexible atoms since the
      // previous barrier can reach across the boundary behind it.
      if (not branchOk) and (lastK >= 0) and (L.Atoms[lastK].Kind = akSep) and
         L.Atoms[lastK].Known then
      begin
        window := [];
        windowKnown := True;
        w := lastK - 1;
        while w >= 0 do
        begin
          if L.Atoms[w].Branch = b then
          begin
            if L.Atoms[w].Kind = akSep then Break;
            if not L.Atoms[w].Known then begin windowKnown := False; Break; end;
            window := window + L.Atoms[w].CSet;
          end;
          Dec(w);
        end;
        if windowKnown and ((L.Atoms[lastK].CSet * window) = []) then branchOk := True;
      end;

      // (iii) the branch BEGINS on a barrier: only the flexible atoms up to the
      // next barrier can reach across the boundary in front of it.
      if (not branchOk) and (firstK >= 0) and (L.Atoms[firstK].Kind = akSep) and
         L.Atoms[firstK].Known then
      begin
        window := [];
        windowKnown := True;
        w := firstK + 1;
        while w < L.NAtoms do
        begin
          if L.Atoms[w].Branch = b then
          begin
            if L.Atoms[w].Kind = akSep then Break;
            if not L.Atoms[w].Known then begin windowKnown := False; Break; end;
            window := window + L.Atoms[w].CSet;
          end;
          Inc(w);
        end;
        if windowKnown and ((L.Atoms[firstK].CSet * window) = []) then branchOk := True;
      end;

      if not branchOk then Exit;
    end;
    Result := True;
  end;

var
  c: Char;
  q: TQuantKind;
  qmin, qmax, total: Int64;
  aset: TByteSet;
  aknown, azero: Boolean;
  popped: TReLevel;
  kind: TReAtomKind;
  ambiguous: Boolean;
begin
  AWhy := '';
  Result := True;
  n := Length(APattern);
  if n = 0 then Exit;
  top := 0;
  gaveUp := False;
  ResetLevel(lv[0]);
  i := 1;
  while i <= n do
  begin
    c := APattern[i];
    case c of
      '\':
        begin
          if i + 1 > n then begin Inc(i); Continue; end;
          EscapeSet(APattern[i + 1], aset, aknown, azero);
          Inc(i, 2);
          q := ReadQuant(qmin, qmax);
          if azero then
          begin
            // A zero-width assertion consumes nothing, so it neither starts a
            // branch nor repeats anything.
            Continue;
          end;
          if q = qkUnbounded then lv[top].Unbounded := True
          else if q = qkBounded then
            if qmax > lv[top].Reps then lv[top].Reps := qmax;
          NoteAtom(aset, aknown, q in [qkOptional, qkUnbounded]);
          PushAtom(aset, aknown, KindOf(q, qmin, qmax));
        end;
      '(':
        begin
          if top >= MaxReDepth then begin gaveUp := True; Break; end;
          Inc(top);
          ResetLevel(lv[top]);
          Inc(i);
          if (i <= n) and (APattern[i] = '?') then
          begin
            Inc(i);
            if (i <= n) and ((APattern[i] = ':') or (APattern[i] = '>')) then Inc(i)
            else if (i <= n) and ((APattern[i] = '=') or (APattern[i] = '!')) then
            begin
              lv[top].Opaque := True;                 // lookahead
              Inc(i);
            end
            else if (i <= n) and (APattern[i] = '<') then
            begin
              Inc(i);
              if (i <= n) and ((APattern[i] = '=') or (APattern[i] = '!')) then
              begin
                lv[top].Opaque := True;               // lookbehind
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
              // (?imsx) and friends: a modifier group, opaque and consuming nothing
              while (i <= n) and (APattern[i] <> ')') do Inc(i);
          end;
        end;
      ')':
        begin
          if top = 0 then begin Inc(i); Continue; end;   // unbalanced: not ours to judge
          popped := lv[top];
          Dec(top);
          Inc(i);
          q := ReadQuant(qmin, qmax);
          ambiguous := False;
          if (q = qkUnbounded) or ((q = qkBounded) and (qmax >= BudgetAmbiguousRepeat)) then
          begin
            // THE JUDGEMENT, and the only place a pattern is ever refused.
            if BranchesOverlap(popped) then
            begin
              AWhy := 'a repeat of an alternation whose branches can start on the ' +
                      'same character (the (a|ab)+ shape) can take exponentially ' +
                      'many attempts';
              Exit(False);
            end;
            ambiguous := not BodyUnambiguous(popped);
            if ambiguous and (not popped.Overflowed) and (popped.NAtoms > 0) then
            begin
              if q = qkUnbounded then
                AWhy := 'a repeat of a group whose body can match the same text in ' +
                        'more than one way (the (a+)+ shape) can take exponentially ' +
                        'many attempts -- a mandatory separator between iterations ' +
                        'would make it linear'
              else
                AWhy := 'a counted repeat of ' + IntToStr(qmax) +
                        ' iterations over a body that can match the same text in ' +
                        'more than one way (the (a+){10} shape) can take ' +
                        'exponentially many attempts';
              Exit(False);
            end;
          end;
          if q = qkUnbounded then lv[top].Unbounded := True
          else if q = qkBounded then
          begin
            total := popped.Reps * qmax;
            if (popped.Reps > 0) and (total div popped.Reps <> qmax) then
              total := High(Int64);                       // the product wrapped
            if total > BudgetMaxRepeatProduct then
            begin
              AWhy := 'nested counted repeats expand to more than ' +
                      IntToStr(BudgetMaxRepeatProduct) + ' repetitions';
              Exit(False);
            end;
            if total > lv[top].Reps then lv[top].Reps := total;
            if popped.Unbounded then lv[top].Unbounded := True;
          end
          else
          begin
            if popped.Unbounded then lv[top].Unbounded := True;
            if popped.Reps > lv[top].Reps then lv[top].Reps := popped.Reps;
          end;

          if popped.Opaque then
          begin
            // A lookaround consumes nothing: it cannot begin a branch, and it
            // cannot pin or cross an iteration boundary either.
          end
          else
          begin
            if UnionFirst(popped, aset) then
              NoteAtom(aset, True, (q in [qkOptional, qkUnbounded]) or (not popped.AnyFirst))
            else
              NoteAtom([], False, q in [qkOptional, qkUnbounded]);
            { A GROUP FOLDS INTO ITS PARENT AS ONE ATOM. Which kind it is decides
              whether the parent can use it as a barrier:
                quantified flexibly -> akFlex, and everything inside it can slide
                mandatory, one branch, every atom fixed -> akSep, a real barrier
                mandatory otherwise -> akWide: it must be consumed, but its width
                                       varies, so it pins nothing }
            if not ConsumedUnion(popped, aset) then
            begin
              aset := [];
              aknown := False;
            end
            else
              aknown := True;
            if q in [qkOptional, qkUnbounded] then kind := akFlex
            else if (q = qkBounded) and (qmin <> qmax) then kind := akFlex
            else if popped.FixedWidth and (popped.Branches = 1) and
                    (not popped.Overflowed) then kind := akSep
            else kind := akWide;
            PushAtom(aset, aknown, kind);
          end;
        end;
      '|':
        begin
          Inc(i);
          if lv[top].Branches <= MaxReBranch then Inc(lv[top].Branches)
          else Inc(lv[top].Branches);          // counted, but no longer tracked
          lv[top].NeedFirst := True;
          lv[top].AnyFirst := False;
        end;
      '[':
        begin
          ClassSet(aset, aknown);
          q := ReadQuant(qmin, qmax);
          if q = qkUnbounded then lv[top].Unbounded := True
          else if q = qkBounded then
            if qmax > lv[top].Reps then lv[top].Reps := qmax;
          NoteAtom(aset, aknown, q in [qkOptional, qkUnbounded]);
          PushAtom(aset, aknown, KindOf(q, qmin, qmax));
        end;
      '^', '$':
        Inc(i);                                 // zero-width anchors
      '.':
        begin
          Inc(i);
          q := ReadQuant(qmin, qmax);
          if q = qkUnbounded then lv[top].Unbounded := True
          else if q = qkBounded then
            if qmax > lv[top].Reps then lv[top].Reps := qmax;
          NoteAtom(AllBytes(), True, q in [qkOptional, qkUnbounded]);
          PushAtom(AllBytes(), True, KindOf(q, qmin, qmax));
        end;
      '*', '+', '?':
        Inc(i);                                 // a quantifier with nothing before it
    else
      begin
        aset := [Byte(Ord(c))];
        Inc(i);
        q := ReadQuant(qmin, qmax);
        if q = qkUnbounded then lv[top].Unbounded := True
        else if q = qkBounded then
          if qmax > lv[top].Reps then lv[top].Reps := qmax;
        NoteAtom(aset, True, q in [qkOptional, qkUnbounded]);
        PushAtom(aset, True, KindOf(q, qmin, qmax));
      end;
    end;
  end;
  if gaveUp then Exit(True);                    // nested past what we track: allow
  // The outermost level is not inside any repeat, so its own Reps/Unbounded are
  // linear work and nothing here refuses them.
end;

end.
