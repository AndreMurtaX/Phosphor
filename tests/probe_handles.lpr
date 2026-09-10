{******************************************************************************
  probe_handles -- a Pascal unit-test of the handle registry

  PhosphorHandles is the reason a fabricated or freed `@` is an error message
  instead of a dereference of arbitrary memory, so its promise is worth asserting
  directly rather than through whatever a .bas program happens to exercise: AN ID
  IS NEVER ISSUED TWICE, and a stale one is detectably stale.

  On 2026-09-10 the table stopped being append-only. Slots are recycled through a
  free list and an id carries a generation in its high 32 bits, because the old
  shape cost eight bytes per handle EVER CREATED and turned every enumeration into
  a walk over the dead: 20,000 json_setn@ took 0.24 s in a fresh process and 48 s
  after a million create/free cycles that left nothing live.

  Recycling is exactly the thing the never-reused promise was bought to prevent,
  so most of this file is about proving the promise survived it. The assertions
  that matter most are the ones where an id from BEFORE a slot was recycled is
  offered again afterwards.

  Prints "ok: N" / "fail: M" and exits non-zero on any failure.
  Run with --fail to corrupt one expectation and confirm the check can fail.
******************************************************************************}
program probe_handles;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  SysUtils, Classes, PhosphorHandles;

var
  Ok: Integer = 0;
  Failed: Integer = 0;
  ProveFail: Boolean = False;

procedure Report(Pass: Boolean; const Name: String);
begin
  if Pass then Inc(Ok)
  else begin Inc(Failed); Writeln(StdErr, 'FAIL: ', Name); end;
end;

type
  { Something cheap to allocate whose destruction is observable. }
  TMarker = class(TObject)
  public
    Tag: Integer;
    constructor Create(ATag: Integer);
    destructor Destroy; override;
  end;

var
  GDestroyed: Integer = 0;

constructor TMarker.Create(ATag: Integer);
begin
  inherited Create;
  Tag := ATag;
end;

destructor TMarker.Destroy;
begin
  Inc(GDestroyed);
  inherited Destroy;
end;

function MakeId(AGen, ASlotPart: Int64): Int64;
begin
  Result := (AGen shl 32) or ASlotPart;
end;

function SlotPart(AId: Int64): Int64;
begin
  Result := AId and Int64($FFFFFFFF);
end;

function GenPart(AId: Int64): Int64;
begin
  Result := AId shr 32;
end;

{ ------------------------------------------------------------------ basics -- }
procedure CheckBasics;
var
  a, b: Int64;
begin
  ResetHandles();
  Report(FirstLiveHandle() = 0, 'a fresh registry enumerates nothing');
  Report(LiveHandleCount() = 0, 'and holds no live handles');
  Report(not IsHandle(0), '0 is never a handle');
  Report(not IsHandle(-1), 'nor is a negative id');
  Report(not IsHandle(1), 'nor is 1 before anything is registered');
  Report(HandleObj(1) = nil, 'and HandleObj answers nil for it');

  a := RegisterHandle(TMarker.Create(1));
  Report(a = 1, 'THE FIRST ID OF A RUN IS STILL 1 (generation zero costs no bits)');
  b := RegisterHandle(TMarker.Create(2));
  Report(b = 2, 'and the second is 2');
  Report(IsHandle(a) and IsHandle(b), 'both are handles');
  Report(TMarker(HandleObj(a)).Tag = 1, 'the first answers its own object');
  Report(TMarker(HandleObj(b)).Tag = 2, 'and the second answers its own');
  Report(LiveHandleCount() = 2, 'two live');

  Report(RegisterHandle(nil) = 0,
         'registering nil answers 0 rather than making a handle that is not one');
  Report(LiveHandleCount() = 2, 'and does not count');
end;

{ ------------------------------------------------------------- freeing ------ }
procedure CheckFreeing;
var
  a, b: Int64;
  before: Integer;
begin
  ResetHandles();
  GDestroyed := 0;
  a := RegisterHandle(TMarker.Create(1));
  b := RegisterHandle(TMarker.Create(2));

  before := GDestroyed;
  Report(FreeHandle(a), 'freeing a live handle answers True');
  Report(GDestroyed = before + 1, 'and the object was actually destroyed');
  Report(not IsHandle(a), 'the id is no longer a handle');
  Report(HandleObj(a) = nil, 'and answers nil');
  Report(IsHandle(b), 'the other handle is untouched');
  Report(LiveHandleCount() = 1, 'one live');

  Report(not FreeHandle(a), 'FREEING THE SAME HANDLE TWICE ANSWERS FALSE');
  Report(not FreeHandle(9999), 'and so does freeing one that never existed');
  Report(GDestroyed = before + 1, 'neither destroyed anything');
end;

{ --------------------------------------------- the promise, under recycling - }
procedure CheckIdsAreNeverReissued;
var
  first, again, third: Int64;
  i: Integer;
  seen: TStringList;
  id: Int64;
begin
  ResetHandles();

  { The narrow case, stated as plainly as it can be: free the only handle, make
    another, and the new one must not BE the old one. }
  first := RegisterHandle(TMarker.Create(1));
  FreeHandle(first);
  again := RegisterHandle(TMarker.Create(2));
  Report(again <> first, 'AN ID IS NOT REISSUED WHEN ITS SLOT IS RECYCLED');
  Report(SlotPart(again) = SlotPart(first),
         'and the SLOT is recycled -- that is the point of the generation');
  Report(GenPart(again) = GenPart(first) + 1, 'the generation went up by one');
  Report(not IsHandle(first),
         'THE OLD ID IS STILL DETECTABLY STALE, with a live object in its slot');
  Report(HandleObj(first) = nil,
         'and answers nil rather than the stranger now occupying the slot');
  Report(IsHandle(again), 'while the new id is good');
  Report(TMarker(HandleObj(again)).Tag = 2, 'and answers ITS object');

  FreeHandle(again);
  third := RegisterHandle(TMarker.Create(3));
  Report((third <> first) and (third <> again), 'a third pass reissues neither');
  Report(not IsHandle(first) and not IsHandle(again), 'and both older ids stay stale');
  FreeHandle(third);

  { The broad case: ten thousand cycles, every id kept, none repeated. A set is
    the only honest way to say "never" here. }
  ResetHandles();
  seen := TStringList.Create;
  try
    seen.Sorted := True;
    seen.Duplicates := dupError;
    for i := 1 to 10000 do
    begin
      id := RegisterHandle(TMarker.Create(i));
      try
        seen.Add(IntToStr(id));
      except
        on E: Exception do
        begin
          Report(False, 'id ' + IntToStr(id) + ' was issued twice at cycle ' + IntToStr(i));
          Break;
        end;
      end;
      FreeHandle(id);
    end;
    Report(seen.Count = 10000, '10,000 create/free cycles issued 10,000 DISTINCT ids');
  finally
    seen.Free;
  end;
end;

{ ------------------------------------------------- the table stops growing -- }
procedure CheckSlotsAreRecycled;
var
  i: Integer;
  id: Int64;
begin
  ResetHandles();
  { One live handle at a time, a hundred thousand times. The slot part of the id
    is the observable: if the table grew, the slot would climb with it. This is
    the memory half of the defect -- it used to be eight bytes per cycle, kept
    until the next Run. }
  for i := 1 to 100000 do
  begin
    id := RegisterHandle(TMarker.Create(i));
    FreeHandle(id);
  end;
  id := RegisterHandle(TMarker.Create(0));
  Report(SlotPart(id) = 1,
         'AFTER 100,000 CREATE/FREE CYCLES THE TABLE STILL HAS ONE SLOT');
  Report(GenPart(id) = 100000, 'and that slot is on its hundred-thousandth life');
  Report(LiveHandleCount() = 1, 'one live handle');
  FreeHandle(id);

  { Held at the same time, they must NOT share a slot. }
  ResetHandles();
  for i := 1 to 100 do
    RegisterHandle(TMarker.Create(i));
  Report(LiveHandleCount() = 100, 'a hundred held at once are a hundred live');
  id := RegisterHandle(TMarker.Create(101));
  Report(SlotPart(id) = 101, 'and the next one takes a fresh slot, not a used one');
end;

{ ------------------------------------------------------------ enumeration --- }
procedure CheckEnumeration;
var
  ids: array[1..10] of Int64;
  i, n, sum: Integer;
  id: Int64;
  seenTag: array[1..10] of Boolean;
  o: TObject;
begin
  ResetHandles();
  for i := 1 to 10 do
    ids[i] := RegisterHandle(TMarker.Create(i));

  n := 0;
  for i := 1 to 10 do seenTag[i] := False;
  id := FirstLiveHandle();
  while (id <> 0) and (n <= 20) do
  begin
    o := HandleObj(id);
    if o is TMarker then seenTag[TMarker(o).Tag] := True;
    Inc(n);
    id := NextLiveHandle(id);
  end;
  Report(n = 10, 'the walk visits every live handle exactly once');
  sum := 0;
  for i := 1 to 10 do if seenTag[i] then Inc(sum);
  Report(sum = 10, 'and reaches all ten objects');

  { Free three from the middle and the walk must skip exactly those. }
  FreeHandle(ids[3]);
  FreeHandle(ids[7]);
  FreeHandle(ids[10]);
  Report(LiveHandleCount() = 7, 'seven live after three frees');
  n := 0;
  for i := 1 to 10 do seenTag[i] := False;
  id := FirstLiveHandle();
  while (id <> 0) and (n <= 20) do
  begin
    o := HandleObj(id);
    if o is TMarker then seenTag[TMarker(o).Tag] := True;
    Inc(n);
    id := NextLiveHandle(id);
  end;
  Report(n = 7, 'THE WALK IS OVER THE LIVE HANDLES, NOT THE TABLE');
  Report((not seenTag[3]) and (not seenTag[7]) and (not seenTag[10]),
         'and the freed three are not among them');
  Report(seenTag[1] and seenTag[2] and seenTag[4] and seenTag[5] and
         seenTag[6] and seenTag[8] and seenTag[9], 'while the other seven are');

  { The head and the tail are the two links a list gets wrong. }
  ResetHandles();
  id := RegisterHandle(TMarker.Create(1));
  Report(FirstLiveHandle() = id, 'one handle: it is the head');
  Report(NextLiveHandle(id) = 0, 'and there is nothing after it');
  FreeHandle(id);
  Report(FirstLiveHandle() = 0, 'freeing the only one empties the walk');
  Report(NextLiveHandle(id) = 0, 'and a stale id walks nowhere');

  { A hundred thousand dead handles must cost the walk nothing, which is the
    defect this whole change is about. Not timed here -- a probe that asserts a
    duration is a probe that fails on a busy machine -- but the COUNT is the
    thing that was O(ever-created), so counting it is the honest assertion. }
  ResetHandles();
  for i := 1 to 100000 do
    FreeHandle(RegisterHandle(TMarker.Create(i)));
  RegisterHandle(TMarker.Create(0));
  n := 0;
  id := FirstLiveHandle();
  while (id <> 0) and (n <= 5) do
  begin
    Inc(n);
    id := NextLiveHandle(id);
  end;
  Report(n = 1, 'after 100,000 dead handles the walk still takes ONE step');
end;

{ ------------------------------------------------------------------ reset --- }
procedure CheckReset;
var
  i: Integer;
  before: Integer;
  id: Int64;
begin
  ResetHandles();
  GDestroyed := 0;
  for i := 1 to 5 do RegisterHandle(TMarker.Create(i));
  id := RegisterHandle(TMarker.Create(6));
  FreeHandle(id);
  before := GDestroyed;
  Report(before = 1, 'one destroyed so far');

  ResetHandles();
  Report(GDestroyed = before + 5, 'RESET DESTROYS EVERY LIVE OBJECT');
  Report(LiveHandleCount() = 0, 'and nothing is live');
  Report(FirstLiveHandle() = 0, 'and the walk is empty');
  Report(not IsHandle(1), 'ids from before the reset are not handles');

  id := RegisterHandle(TMarker.Create(1));
  Report(id = 1, 'and the first id after a reset is 1 again');
  ResetHandles();
end;

{ ------------------------------------ the three an adversary got through ---- }
procedure CheckWhatTheFirstFiftyFiveMissed;
var
  h: array[1..7] of Int64;
  i, n: Integer;
  id, stale, future: Int64;
  o: TObject;
  seenTag: array[1..7] of Boolean;
begin
  { An adversarial review mutated this registry fifteen ways and three mutations
    walked straight through the assertions above. Each of these is the shape that
    kills one of them, and each was confirmed by making the mutation and watching
    the probe go red. A test that cannot fail is worse than no test, because it
    is counted. }

  { (1) UNLINK FORGETS THE SUCCESSOR'S Prev.
    A forward-only walk cannot see a broken Prev. It takes a slot being freed,
    RECYCLED, and then the node whose Prev pointed at it being freed in turn --
    which writes the unlink through a stale Prev into a stranger's slot. }
  ResetHandles();
  for i := 1 to 6 do h[i] := RegisterHandle(TMarker.Create(i));
  FreeHandle(h[3]);
  h[7] := RegisterHandle(TMarker.Create(7));   // recycles the slot 3 had
  FreeHandle(h[2]);                            // its Prev pointed at that slot
  Report(LiveHandleCount() = 5, 'count survives a free through a recycled neighbour');
  for i := 1 to 7 do seenTag[i] := False;
  n := 0;
  id := FirstLiveHandle();
  while (id <> 0) and (n <= 12) do
  begin
    o := HandleObj(id);
    if o is TMarker then seenTag[TMarker(o).Tag] := True;
    Inc(n);
    id := NextLiveHandle(id);
  end;
  Report(n = 5, 'AND THE WALK STAYS WHOLE -- a broken back-link is visible here');
  Report(seenTag[1] and seenTag[4] and seenTag[5] and seenTag[6] and seenTag[7],
         'with all five survivors reachable');
  Report((not seenTag[2]) and (not seenTag[3]), 'and neither freed one');

  { (2) IsHandle DROPS THE LIVENESS TEST.
    Every stale id offered above has a MISMATCHED generation, so the generation
    test alone rejects it and `Obj <> nil` is never load-bearing. The one shape
    where it is the only guard left is the id a free slot WILL issue next. }
  ResetHandles();
  id := RegisterHandle(TMarker.Create(1));
  FreeHandle(id);
  future := MakeId(GenPart(id) + 1, SlotPart(id));
  Report(not IsHandle(future),
         'AN ID A FREE SLOT WILL ISSUE NEXT IS NOT A HANDLE YET');
  Report(HandleObj(future) = nil, 'and answers no object');
  Report(not FreeHandle(future), 'and cannot be freed');
  Report(NextLiveHandle(future) = 0, 'and walks nowhere');
  id := RegisterHandle(TMarker.Create(2));
  Report(id = future, 'the slot then issues exactly that id');
  Report(IsHandle(id), 'and NOW it is a handle');

  { (3) NextLiveHandle DOES NOT VALIDATE THE ID IT IS HANDED.
    A stale id whose slot has since been recycled and is LIVE would otherwise
    hand back the stranger's successor, splicing a walk into a list position it
    was never at. }
  ResetHandles();
  stale := RegisterHandle(TMarker.Create(1));
  h[2] := RegisterHandle(TMarker.Create(2));
  h[3] := RegisterHandle(TMarker.Create(3));
  FreeHandle(stale);
  h[4] := RegisterHandle(TMarker.Create(4));   // recycles the stale id's slot
  Report(SlotPart(h[4]) = SlotPart(stale), 'the slot behind the stale id is live again');
  Report(not IsHandle(stale), 'the stale id is still stale');
  Report(NextLiveHandle(stale) = 0,
         'AND WALKS NOWHERE, though its slot now holds a live stranger');

  { The generation cannot reach the sign bit -- that is a compile-time guard in
    the unit, because reaching it at runtime takes 87 seconds of churn. What IS
    cheap is asserting that an id carrying such a generation is refused, which is
    what the guard exists to make unreachable. }
  ResetHandles();
  id := RegisterHandle(TMarker.Create(1));
  Report(MakeId($80000000, 1) < 0, 'a generation of 2^31 would make a NEGATIVE id');
  Report(not IsHandle(MakeId($80000000, SlotPart(id))),
         'and such an id is refused rather than resolved');
  Report(HandleObj(MakeId($80000000, SlotPart(id))) = nil, 'and answers nil');
  Report(IsHandle(id), 'while the real handle beside it is untouched');
  ResetHandles();
end;

begin
  ProveFail := (ParamCount >= 1) and (ParamStr(1) = '--fail');

  CheckBasics;
  CheckFreeing;
  CheckIdsAreNeverReissued;
  CheckSlotsAreRecycled;
  CheckEnumeration;
  CheckReset;
  CheckWhatTheFirstFiftyFiveMissed;

  if ProveFail then
    Report(FirstLiveHandle() = 12345, 'ProveFailure: a deliberately false claim');

  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed = 0 then Halt(0) else Halt(1);
end.
