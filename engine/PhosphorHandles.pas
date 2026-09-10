{******************************************************************************
  Phosphor BASIC -- handle registry (core infrastructure)

  MIT License. Copyright (c) 2026 Andre Murta.

  A handle (`@`) is an Int64 id into this registry, not a raw pointer, so a
  fabricated or stale handle is detectable (IsHandle) instead of dereferencing
  arbitrary memory -- the property Plan9Basic's HandleRegistry existed to give.
  Ids are never reused within a run; ResetHandles frees every live object and is
  called at the start of each Run so handles never leak between programs.

  This unit knows nothing about what the objects ARE -- the handle-based
  collections (arrays, dicts, ...) live in the library packages under
  engine/libs and only store/retrieve their objects here as plain TObjects.

  AN ID IS NOT A ROW NUMBER, AND THAT CHANGED ON 2026-09-10.

  It used to be exactly one: the table only ever grew, an id was its index, and a
  freed id was a nil left in place for ever with the comment "id stays used but
  now invalid". Two costs came out of that, and the second was not obvious.

  The memory cost is the one you would predict: eight bytes per handle EVER
  CREATED, reclaimed only by ResetHandles -- which runs at the start of a Run, and
  a GUI host calls Run once and then sits in app_run() for hours. Every dict every
  event handler made was a permanent slot.

  The time cost was 200x. A library that must find every handle pointing into
  something it is about to destroy walked 1..HandleCount, and HandleCount was the
  count of handles ever created. So an O(1) json member replacement became
  O(handles-ever-created): measured, 20,000 json_setn@ take 0.24 s in a fresh
  process and 48 s after a million create/free cycles that left NOTHING live.

  So slots are recycled now, and an id carries a GENERATION in its high 32 bits
  so that recycling stays invisible to the promise above:

      id = (generation shl 32) or (slot + 1)

  A slot's generation goes up every time it is freed, so an id issued for a slot
  can never be issued again, and a stale id decodes to a slot whose generation no
  longer matches -- IsHandle answers False for exactly the same reason it always
  did. The first handles of a run are still 1, 2, 3: generation zero costs no
  bits, and only a slot that has actually been recycled produces a large id.

  Enumeration is a doubly-linked list of the LIVE slots, walked with
  FirstLiveHandle/NextLiveHandle. Not a scan of the table: a program that creates
  a million handles and frees all but one must not make its next enumeration cost
  a million steps, which is the defect above wearing a different hat.

  WHAT IT COSTS, because the paragraphs above only say what it buys. A slot was
  one pointer and is now 24 bytes -- pointer, generation, two links -- so a
  program holding a million handles LIVE at once pays 25.2 MB of table where it
  used to pay 8.39 MB. That is the trade: bounded 24 in place of unbounded 8. The
  same million handles created and freed one at a time now leak nothing, where
  they used to leak the whole 8.39 MB until the next Run.

  THE GENERATION STOPS AT $7FFFFFFF, NOT $FFFFFFFF, AND THAT IS LOAD-BEARING.
  An id is a signed Int64. A generation of $80000000 shifted left 32 sets bit 63,
  so the id comes back NEGATIVE -- and SlotOf refuses anything below 1, which is
  right for every other caller and fatal here: RegisterHandle would hand out an id
  that nothing honours, for an object that is live, unreachable and unfreeable.
  Worse, that dead slot is linked at the HEAD of the live list, so FirstLiveHandle
  answers it, NextLiveHandle rejects it, and the whole walk truncates to one
  element -- which is InvalidateBorrowed silently not telling a borrowed JSON
  handle that its node is gone, and GuiOtherFormShown answering False with windows
  still on screen. Measured at 78 seconds of raw create/free churn on one slot.
  The compile-time check below is there so this cannot be reintroduced by someone
  widening the constant to "use the whole field".
******************************************************************************}
unit PhosphorHandles;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

function RegisterHandle(AObj: TObject): Int64;
function HandleObj(AId: Int64): TObject;
function IsHandle(AId: Int64): Boolean;
function FreeHandle(AId: Int64): Boolean;   // free one object, invalidate its id
procedure ResetHandles;

{ Enumeration, for a library that must find every handle pointing INTO something
  it is about to destroy. The JSON package uses it: replacing a member frees the
  node a borrowed child handle still points at, and that handle has to be told.
  The GUI host uses it to ask whether any window other than the one closing is
  still on screen.

  Walk it as

      id := FirstLiveHandle();
      while id <> 0 do
      begin
        o := HandleObj(id);
        ...
        id := NextLiveHandle(id);
      end;

  0 is never a handle, so it is the terminator. The order is unspecified (it is
  newest-first today) and no caller may depend on it.

  DO NOT FREE THE CURRENT HANDLE DURING A WALK. NextLiveHandle reads the link out
  of the slot the id names, and freeing it unlinks that slot; the walk would stop
  early rather than continue, which is a wrong answer and not a crash. Neither
  caller does this. If one ever needs to, take the ids into a local array first. }
function FirstLiveHandle: Int64;
function NextLiveHandle(AId: Int64): Int64;
function LiveHandleCount: Integer;

implementation

type
  TSlot = record
    Obj: TObject;          // nil exactly when the slot is free
    Gen: LongWord;         // generation of the id that owns it now
    Prev, Next: Integer;   // live list, -1 for none
  end;

const
  SLOT_MASK = Int64($FFFFFFFF);
  { Not $FFFFFFFF: bit 63 of the id must stay clear. See the header. }
  GEN_MAX   = LongWord($7FFFFFFF);
  NO_SLOT   = -1;

{$IF GEN_MAX > $7FFFFFFF}
  {$ERROR GEN_MAX must keep bit 63 of an id clear, or RegisterHandle returns a negative id that SlotOf refuses}
{$ENDIF}

var
  GSlots: array of TSlot;
  GUsed: Integer;          // slots ever allocated: the high-water of live handles
  GFree: array of Integer; // stack of recyclable slot indices
  GFreeTop: Integer;
  GLiveHead: Integer;
  GLive: Integer;

function IdOf(ASlot: Integer): Int64; inline;
begin
  Result := (Int64(GSlots[ASlot].Gen) shl 32) or Int64(ASlot + 1);
end;

{ The slot an id names, or NO_SLOT if the id cannot name one. Answers the
  question without consulting the slot, so IsHandle can bound-check before it
  indexes. }
function SlotOf(AId: Int64): Integer; inline;
var
  lo: Int64;
begin
  if AId < 1 then Exit(NO_SLOT);
  lo := AId and SLOT_MASK;
  if (lo < 1) or (lo > GUsed) then Exit(NO_SLOT);
  Result := Integer(lo - 1);
end;

function IsHandle(AId: Int64): Boolean;
var
  s: Integer;
begin
  s := SlotOf(AId);
  Result := (s <> NO_SLOT) and (GSlots[s].Obj <> nil) and
            (GSlots[s].Gen = LongWord(AId shr 32));
end;

function RegisterHandle(AObj: TObject): Int64;
var
  s: Integer;
begin
  { No caller registers nil -- there are 24 call sites and none does -- and the
    invariant matters, because `Obj <> nil` IS the liveness test. Answering 0 is
    the honest reply if one ever tries: 0 is not a handle. }
  if AObj = nil then Exit(0);

  if GFreeTop > 0 then
  begin
    Dec(GFreeTop);
    s := GFree[GFreeTop];
  end
  else
  begin
    if GUsed = Length(GSlots) then
      SetLength(GSlots, (Int64(GUsed) + 1) * 2);
    s := GUsed;
    Inc(GUsed);
    GSlots[s].Gen := 0;
  end;

  GSlots[s].Obj := AObj;
  GSlots[s].Prev := NO_SLOT;
  GSlots[s].Next := GLiveHead;
  if GLiveHead <> NO_SLOT then GSlots[GLiveHead].Prev := s;
  GLiveHead := s;
  Inc(GLive);
  Result := IdOf(s);
end;

{ The same test as IsHandle, but resolving the slot ONCE. This is the hottest
  call in the unit -- every library function that takes a handle arrives here --
  and calling IsHandle and then SlotOf again walked the id twice: measured at
  +41% over the pre-recycling unit for 20M lookups, and back to -3% with this. }
function HandleObj(AId: Int64): TObject;
var
  s: Integer;
begin
  Result := nil;
  s := SlotOf(AId);
  if (s <> NO_SLOT) and (GSlots[s].Obj <> nil) and
     (GSlots[s].Gen = LongWord(AId shr 32)) then
    Result := GSlots[s].Obj;
end;

function FreeHandle(AId: Int64): Boolean;
var
  s: Integer;
begin
  if not IsHandle(AId) then
    Exit(False);
  s := SlotOf(AId);

  GSlots[s].Obj.Free;
  GSlots[s].Obj := nil;

  if GSlots[s].Prev <> NO_SLOT then
    GSlots[GSlots[s].Prev].Next := GSlots[s].Next
  else
    GLiveHead := GSlots[s].Next;
  if GSlots[s].Next <> NO_SLOT then
    GSlots[GSlots[s].Next].Prev := GSlots[s].Prev;
  GSlots[s].Prev := NO_SLOT;
  GSlots[s].Next := NO_SLOT;
  Dec(GLive);

  if GSlots[s].Gen < GEN_MAX then
  begin
    Inc(GSlots[s].Gen);
    if GFreeTop = Length(GFree) then
      SetLength(GFree, (Int64(GFreeTop) + 1) * 2);
    GFree[GFreeTop] := s;
    Inc(GFreeTop);
  end;
  { else: this slot has reached the last generation an id can carry, so the next
    one would either wrap and reissue an id or set bit 63 and produce an id that
    is not a handle at all. It is retired instead -- never pushed back onto the
    free list -- because the never-reused promise is what the whole handle design
    is for, and one leaked slot per 2,147,483,647 frees is a price worth paying to
    keep it absolute. The next handle takes a fresh slot and the table grows by
    one, which is the whole consequence.

    THIS BRANCH USED TO BE UNREACHABLE. With GEN_MAX at $FFFFFFFF the id went
    negative at half that, FreeHandle stopped answering True, and the generation
    never climbed to the cap -- so the comment justifying the retirement described
    code that could not run. It runs now, and probe_handles asserts the shape of
    it without paying the 87 seconds it takes to reach. }

  Result := True;
end;

function FirstLiveHandle: Int64;
begin
  if GLiveHead = NO_SLOT then Exit(0);
  Result := IdOf(GLiveHead);
end;

function NextLiveHandle(AId: Int64): Int64;
var
  s: Integer;
begin
  Result := 0;
  if not IsHandle(AId) then Exit;
  s := GSlots[SlotOf(AId)].Next;
  if s <> NO_SLOT then Result := IdOf(s);
end;

function LiveHandleCount: Integer;
begin
  Result := GLive;
end;

procedure ResetHandles;
var
  i: Integer;
begin
  for i := 0 to GUsed - 1 do
    if GSlots[i].Obj <> nil then
      GSlots[i].Obj.Free;
  GUsed := 0;
  GFreeTop := 0;
  GLiveHead := NO_SLOT;
  GLive := 0;
  SetLength(GSlots, 0);
  SetLength(GFree, 0);
end;

initialization
  GUsed := 0;
  GFreeTop := 0;
  GLiveHead := NO_SLOT;
  GLive := 0;

finalization
  ResetHandles();

end.
