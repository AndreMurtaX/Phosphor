{******************************************************************************
  Phosphor BASIC -- dictionary library (a function package)

  MIT License. Copyright (c) 2026 Andre Murta.

  String-keyed maps as handle objects: dict@ (numeric values), sdict@ (string),
  pdict@ (handle/pointer). Element get/set is kind-agnostic (one implementation,
  registered under every typed name); the dict knows its own value kind. All
  errors are RETURNED, never raised, and a fabricated handle is rejected by
  GetDict (IsHandle) rather than dereferenced.

  Entries live in two parallel arrays and that IS the documented insertion order
  (dict_key$ reads position n of it). Beside them sits a hash table that maps a
  key to its position, so IndexOf -- which ten registered functions go through,
  eight of them to READ -- costs a probe instead of a scan of every key.
******************************************************************************}
unit PhosphorDictLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles;

type
  TPhosphorDict = class
  private
    FKeys: array of String;
    FVals: array of TValue;
    FCount: Integer;
    { The lookup index, and nothing more than an accelerator. FBuckets is open
      addressed with linear probing and holds an ENTRY NUMBER, one-based, so 0
      reads as empty; its length is always a power of two and FMask is that
      length minus one. Every hit it reports is confirmed against FKeys with the
      same `=` the old linear scan used, so a collision costs a probe and can
      never change an answer.

      The index is not free: with FHashes it costs about six bytes per entry on
      live heap -- 60.7 bytes per entry before, 66.9 after -- so an embedder who
      sets MaxMemoryBytes holds roughly 7% fewer keys under the same ceiling
      (8187 -> 7625 under 1 MB, measured). Nothing answers wrongly; the program
      is refused. docs/libraries/dict.md says the same thing to the caller. }
    FBuckets: array of Integer;
    FMask: Integer;
    { Each entry's hash, taken once when the entry is made and carried beside
      its key ever after. Without it Reindex would re-HASH every surviving key,
      and Remove calls Reindex -- so removal would cost the dictionary's total
      key BYTES instead of its entry count. Measured, 1000 removals from the
      front of a 4000-entry dictionary with 202-byte keys: 54 ms under the old
      linear scan, 691 ms with this index but no stored hashes, 62 ms with them.
      Filling and then removing was 740 ms without them against the scan's
      576 ms -- a change sold as a speedup, making a real workload SLOWER. With
      them, Reindex re-PLACES entries and reads no key at all. Four bytes per
      allocated entry slot. }
    FHashes: array of LongWord;
    function GetKey(AIndex: Integer): String;
    function GetVal(AIndex: Integer): TValue;
    procedure Bind(AEntry: Integer);
    procedure Reindex;
  public
    Kind: TArrayKind;
    constructor Create(AKind: TArrayKind);
    function IndexOf(const AKey: String): Integer;
    procedure SetVal(const AKey: String; const AVal: TValue);
    procedure Remove(const AKey: String);
    procedure Clear;
    function TypeName: String;
    { Keys, Vals and Count used to be public mutable FIELDS. They are read-only
      now for one reason: the table has to agree with the arrays after EVERY
      mutation, and an index that disagrees with its array is a silently wrong
      answer -- worse than the scan it replaced. Exactly three routines mutate,
      all of them below; with the fields closed, nothing anywhere can put the
      two out of step, which is what makes the agreement an invariant rather
      than a habit. }
    property Count: Integer read FCount;
    property Keys[AIndex: Integer]: String read GetKey;
    property Vals[AIndex: Integer]: TValue read GetVal;
  end;

procedure RegisterDictFuncs(Reg: TPhosphorRegistry);

implementation

(* FNV-1a over the RAW BYTES of the key, and it has to stay that way: the library
   page promises keys are compared exactly, byte for byte -- case matters,
   whitespace matters, no Unicode normalization happens -- and IndexOf still
   settles every candidate with Pascal's own `=`. A hash that folded case or
   normalized would simply never offer the entry that `=` would have accepted, and
   the miss would be silent.

   What `=` actually compares, read rather than assumed (rtl/inc/astrings.inc:717
   fpc_AnsiStr_Compare_equal, and :64 TranslatePlaceholderCP): it compares raw
   bytes only when the two operands' CODE PAGE TAGS agree, and transcodes both to
   UTF-8 first when they do not. So "hash the raw bytes" and "compare the raw
   bytes" are the same rule only for strings that carry the same tag. Every string
   this engine makes carries one -- DefaultSystemCodePage, measured across sixteen
   string-producing shapes -- so no BASIC program can reach the difference, and the
   unit's codepage directive colours only string LITERALS, none of which reach this
   function. An EMBEDDER can: hand in a String tagged differently (a host linking
   PhosphorCrtLib without the LCL tags CP_UTF8) and a key `=` would have accepted
   is one the hash separates. That is a MISS, never a wrong value, because every
   hit is still settled by `=` below.

   The multiply is done in QWord and masked back rather than left to wrap around:
   unsigned overflow is an error when a host compiles with overflow or range
   checking on, and this unit must not depend on which switches it is given.
   QWord is 64 bits on every target the engine builds for, and 2^32 * 16777619 is
   under 2^57, so the product cannot overflow it on either operating system.

   This comment is in the star form and not the file's usual braces because a
   brace comment that names a compiler switch opens a second comment level --
   a warning, and the bar here is zero warnings. *)
function HashKey(const AKey: String): LongWord;
var i: Integer;
begin
  Result := $811C9DC5;
  for i := 1 to Length(AKey) do
  begin
    Result := Result xor LongWord(Byte(AKey[i]));
    Result := LongWord((QWord(Result) * 16777619) and $FFFFFFFF);
  end;
end;

constructor TPhosphorDict.Create(AKind: TArrayKind);
begin
  inherited Create();
  Kind := AKind;
  FCount := 0;
  Reindex();
end;

function TPhosphorDict.GetKey(AIndex: Integer): String;
begin
  Result := FKeys[AIndex];
end;

function TPhosphorDict.GetVal(AIndex: Integer): TValue;
begin
  Result := FVals[AIndex];
end;

{ Place one entry in the first free slot from its hash position. The loop is
  bounded by the table rather than written `while True`: the table is never more
  than half full, so a free slot always exists and the bound is never reached --
  but a bound that cannot be reached still beats a loop that cannot end. What
  keeps it unreachable is the `* 2` in SetVal's load-factor line further down;
  falling out of this loop would leave an entry in the arrays and NOT in
  the table, which is a key that is present and cannot be found. That is why the
  suite pins the load factor rather than trusting it. }
procedure TPhosphorDict.Bind(AEntry: Integer);
var slot, probes: Integer;
begin
  slot := Integer(FHashes[AEntry] and LongWord(FMask));
  for probes := 1 to Length(FBuckets) do
  begin
    if FBuckets[slot] = 0 then
    begin
      FBuckets[slot] := AEntry + 1;
      Exit;
    end;
    slot := (slot + 1) and FMask;
  end;
end;

{ Build the table from the entries, which are the truth. Called from everything
  that can renumber an entry, and cheap enough to be: one pass of FCount probes
  over cached hashes, which is what Remove's shift already costs and reads no
  key. It re-PLACES entries; it does not re-hash them. }
procedure TPhosphorDict.Reindex;
var slotCount, i: Integer;
begin
  slotCount := 8;
  while slotCount < (FCount * 2) do slotCount := slotCount * 2;
  SetLength(FBuckets, 0);            // discard, then allocate: FPC zeroes a fresh
  SetLength(FBuckets, slotCount);    // dynamic array, and every slot must read empty
  FMask := slotCount - 1;
  for i := 0 to FCount - 1 do Bind(i);
end;

{ There is deliberately NO `if FCount = 0 then Exit` fast path here, and its
  absence is load-bearing. An empty dictionary has an empty table -- Create and
  Clear both end in Reindex -- so the probe below reads an empty slot and answers
  -1 on its own; the guard would have been a line whose wrong version (deletion)
  nothing could tell from its right one. Worse, it would have made Clear's own
  contract untestable: a Clear that shortened the count without emptying the
  table is exactly the defect the guard would hide for every question asked
  before the next insert. }
function TPhosphorDict.IndexOf(const AKey: String): Integer;
var slot, probes, entry: Integer;
begin
  Result := -1;
  slot := Integer(HashKey(AKey) and LongWord(FMask));
  for probes := 1 to Length(FBuckets) do
  begin
    entry := FBuckets[slot];
    if entry = 0 then Exit;          // an empty slot ends the probe: not present
    if FKeys[entry - 1] = AKey then Exit(entry - 1);
    slot := (slot + 1) and FMask;
  end;
end;

procedure TPhosphorDict.SetVal(const AKey: String; const AVal: TValue);
var idx: Integer;
begin
  idx := IndexOf(AKey);
  if idx >= 0 then
  begin
    FVals[idx] := AVal;              // overwrite keeps the position it already had
    Exit;
  end;
  if FCount = Length(FKeys) then
  begin
    SetLength(FKeys, (FCount + 1) * 2);
    SetLength(FVals, (FCount + 1) * 2);
    SetLength(FHashes, (FCount + 1) * 2);
  end;
  FKeys[FCount] := AKey;
  FVals[FCount] := AVal;
  FHashes[FCount] := HashKey(AKey);   // the only place a key is ever hashed for storage
  Inc(FCount);
  { Half full at most, and the `* 2` is the whole of that rule -- drop it and the
    table is allowed to fill completely. That is not a style preference: a table
    whose length is a power of two is EXACTLY FULL whenever the entry count is
    that same power of two, and an absent-key probe in a full table finds no
    empty slot to stop at, so it walks every slot and compares every key. At
    n = 8192 that is the linear scan this change was made to remove, restored in
    full. tests/suite/62_dict_index.bas sizes its cost case to 8192 for exactly
    that reason and fails within a second of the `* 2` going away. }
  if (FCount * 2) > Length(FBuckets) then
    Reindex()
  else
    Bind(FCount - 1);
end;

procedure TPhosphorDict.Remove(const AKey: String);
var idx, i: Integer;
begin
  idx := IndexOf(AKey);
  if idx < 0 then Exit;
  for i := idx to FCount - 2 do
  begin
    FKeys[i] := FKeys[i + 1];
    FVals[i] := FVals[i + 1];
    FHashes[i] := FHashes[i + 1];    // the hash travels with its key, or Reindex places it wrong
  end;
  Dec(FCount);
  { EVERY entry above idx just changed number. Deleting only the removed key's
    own slot would leave the table pointing one past the truth for all of them --
    a wrong VALUE returned for a key that is still present, and silent. }
  Reindex();
end;

procedure TPhosphorDict.Clear;
begin
  { FKeys and FVals keep their contents past FCount, exactly as they always have.
    That was invisible while IndexOf was bounded by FCount; with a table beside
    them it would not be, so the table is emptied here rather than merely
    shortened -- otherwise dict_haskey answers 1 for a key that was cleared. }
  FCount := 0;
  Reindex();
end;

function TPhosphorDict.TypeName: String;
begin
  case Kind of
    akString:  Result := 'string';
    akPointer: Result := 'pointer';
  else
    Result := 'numeric';
  end;
end;

// --- library functions ------------------------------------------------------
function GetDict(const V: TValue; out D: TPhosphorDict; out Err: TPhosphorError): Boolean;
begin
  D := nil;
  if (V.Kind <> vkHandle) or (not IsHandle(V.Hnd)) or (not (HandleObj(V.Hnd) is TPhosphorDict)) then
  begin
    Err := MakeError(peRuntime, 'not a valid dictionary handle');
    Exit(False);
  end;
  D := TPhosphorDict(HandleObj(V.Hnd));
  Err := NoError();
  Result := True;
end;

function MakeDict(AKind: TArrayKind): TValue;
begin
  Result := ValHandle(RegisterHandle(TPhosphorDict.Create(AKind)));
end;

function t_dict_new(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := MakeDict(akNumeric); end;
function t_sdict_new(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := MakeDict(akString); end;
function t_pdict_new(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := MakeDict(akPointer); end;

// (handle, key$, value) -> value; returns the dict handle so it reads as a
// constructor-style call site too.
function t_dict_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict;
begin
  Result := Args[0];
  if not GetDict(Args[0], d, Err) then Exit;
  d.SetVal(Args[1].Str, Args[2]);
end;

function DefaultFor(K: TArrayKind): TValue;
begin
  case K of
    akString:  Result := ValStr('');
    akPointer: Result := ValHandle(0);
  else
    Result := ValInt(0);
  end;
end;

{ Read a key, answering AMissing when there is none. The stored value is handed
  back exactly as it was stored -- no conversion, ever -- so a mismatch surfaces
  where the value is finally used, with the language's own type error, and
  dict_typeof is how a program avoids reaching that point. }
function ReadKey(const Args: array of TValue; const AMissing: TValue;
                 out Err: TPhosphorError): TValue;
var d: TPhosphorDict; idx: Integer;
begin
  Result := AMissing;
  if not GetDict(Args[0], d, Err) then Exit;
  idx := d.IndexOf(Args[1].Str);
  if idx >= 0 then Result := d.Vals[idx];
end;

{ The legacy spelling: a missing key answers the CONTAINER's default, which is
  what dict@/sdict@/pdict@ were created for and what the oracle pins. }
function t_dict_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict;
begin
  Result := ValInt(0);
  if not GetDict(Args[0], d, Err) then Exit;
  Result := ReadKey(Args, DefaultFor(d.Kind), Err);
end;

{ The typed spellings. Each answers ITS OWN empty value for a missing key --
  the shared reader could not, because it knew the container's kind and not the
  caller's question. }
function t_dict_get_num(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := ReadKey(Args, ValInt(0), Err); end;
function t_dict_get_str(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := ReadKey(Args, ValStr(''), Err); end;
function t_dict_get_hnd(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := ReadKey(Args, ValHandle(0), Err); end;
function t_dict_get_bool(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := ReadKey(Args, ValBool(False), Err); end;

{ dict_typeof(d@, k$) -- what does this key hold?

  The codes are the language's own five kinds in their declared order, and -1 for
  a key that is not there. A separate answer for "absent" matters: without it a
  program cannot tell an absent key from one holding a number, and dict_haskey
  would have to be asked first every single time. }
function t_dict_typeof(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict; idx: Integer;
begin
  Result := ValInt(-1);
  if not GetDict(Args[0], d, Err) then Exit;
  idx := d.IndexOf(Args[1].Str);
  if idx >= 0 then Result := ValInt(Ord(d.Vals[idx].Kind));
end;

function t_dict_typeof_name(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict; idx: Integer;
begin
  Result := ValStr('');
  if not GetDict(Args[0], d, Err) then Exit;
  idx := d.IndexOf(Args[1].Str);
  if idx < 0 then Exit;                 // absent answers "", never a kind name
  case d.Vals[idx].Kind of
    vkString: Result := ValStr('string');
    vkInt:    Result := ValStr('int');
    vkHandle: Result := ValStr('handle');
    vkBool:   Result := ValStr('bool');
  else
    Result := ValStr('number');
  end;
end;

function t_dict_getdef(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict; idx: Integer;
begin
  Result := Args[2];
  if not GetDict(Args[0], d, Err) then Exit;
  idx := d.IndexOf(Args[1].Str);
  if idx >= 0 then Result := d.Vals[idx] else Result := Args[2];
end;

function t_dict_count(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict;
begin
  Result := ValInt(0);
  if GetDict(Args[0], d, Err) then Result := ValInt(d.Count);
end;

function t_dict_haskey(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict;
begin
  Result := ValInt(0);
  if GetDict(Args[0], d, Err) then Result := ValInt(Ord(d.IndexOf(Args[1].Str) >= 0));
end;

function t_dict_remove(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict;
begin
  Result := ValInt(0);
  if not GetDict(Args[0], d, Err) then Exit;
  // Answer whether anything was actually removed. It used to answer 1 for a key
  // that was never there, which is the one question this call exists to settle --
  // a mutator returns information, the rule arr_set and strings_add follow.
  if d.IndexOf(Args[1].Str) < 0 then Exit;   // absent: nothing removed, answer 0
  d.Remove(Args[1].Str);
  Result := ValInt(1);
end;

{ dict_clear@ answers the DICTIONARY, which is what the @ on its name has always
  promised and what its sibling dict_set@ has always done.

  It used to answer ValInt(1) -- both a lie about the type and a bare success
  flag, the two things this codebase treats as defects, in three characters. The
  cost was real rather than theoretical: `d@ = dict_clear@(d@)` aborted the
  program AT RUN TIME with "cannot store int into handle variable" -- the store
  is what checks the kind, so the line ran and the failure arrived only when it
  did. The one spelling a reader would guess from the name was the one that could
  not work, and the library page had to spend a paragraph apologising for it.

  Nothing is lost by dropping the 1. It was constant -- it never once said
  whether anything had been removed -- and how many entries there were is what
  dict_count answers, before the call. }
function t_dict_clear(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict;
begin
  Result := Args[0];
  if not GetDict(Args[0], d, Err) then Exit;
  d.Clear();
end;

function t_dict_typename(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict;
begin
  Result := ValStr('');
  if GetDict(Args[0], d, Err) then Result := ValStr(d.TypeName());
end;

// key at a 1-based position (insertion order)
function t_dict_key(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict; i: Integer;
begin
  Result := ValStr('');
  if not GetDict(Args[0], d, Err) then Exit;
  i := ArgI32(Args[1]) - 1;
  if (i < 0) or (i >= d.Count) then
  begin
    Err := MakeError(peRuntime, Format('dict index %d out of bounds 1..%d', [i + 1, d.Count]));
    Exit;
  end;
  Result := ValStr(d.Keys[i]);
end;

// value-kind code: 0 numeric, 1 string, 2 pointer
function t_dict_type(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: TPhosphorDict;
begin
  Result := ValInt(0);
  if not GetDict(Args[0], d, Err) then Exit;
  case d.Kind of
    akString:  Result := ValInt(1);
    akPointer: Result := ValInt(2);
  else
    Result := ValInt(0);
  end;
end;

procedure RegisterDictFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('dict@:',  @t_dict_new);
  Reg.Add('sdict@:', @t_sdict_new);
  Reg.Add('pdict@:', @t_pdict_new);

  { ONE dictionary that holds anything. The storage always did -- Vals is an
    array of the engine's five-kind cell and the setter enforced nothing -- so
    these four shapes are the surface catching up with the container. An int
    needs no shape of its own: the registry widens % to n. }
  Reg.Add('dict_set@:@$n',  @t_dict_set);
  Reg.Add('dict_set@:@$$',  @t_dict_set);
  Reg.Add('dict_set@:@$@',  @t_dict_set);
  Reg.Add('dict_set@:@$?',  @t_dict_set);
  { The older spellings, kept: same container, same implementation. }
  Reg.Add('sdict_set@:@$$', @t_dict_set);
  Reg.Add('pdict_set@:@$@', @t_dict_set);

  { A function's return type comes from the suffix on its OWN name, so there can
    be no polymorphic getter -- typed getters are what the language allows, and
    each answers its own empty value for a key that is not there. }
  Reg.Add('dict_get:@$',   @t_dict_get);       // legacy: the container's default
  Reg.Add('dict_get$:@$',  @t_dict_get_str);
  Reg.Add('dict_get@:@$',  @t_dict_get_hnd);
  Reg.Add('dict_get?:@$',  @t_dict_get_bool);
  Reg.Add('dict_get%:@$',  @t_dict_get_num);
  Reg.Add('sdict_get$:@$', @t_dict_get_str);
  Reg.Add('pdict_get@:@$', @t_dict_get_hnd);
  { What a KEY holds -- the question that only exists once one dictionary can
    hold several kinds, and what makes dict_key$ useful for walking a mixed one. }
  Reg.Add('dict_typeof:@$',   @t_dict_typeof);
  Reg.Add('dict_typeof$:@$',  @t_dict_typeof_name);

  Reg.Add('dict_getdef:@$n',   @t_dict_getdef);
  Reg.Add('dict_getdef$:@$$',  @t_dict_getdef);
  Reg.Add('dict_getdef?:@$?',  @t_dict_getdef);
  Reg.Add('sdict_getdef$:@$$', @t_dict_getdef);

  Reg.Add('dict_getdef@:@$@',  @t_dict_getdef);
  Reg.Add('pdict_getdef@:@$@', @t_dict_getdef);

  Reg.Add('dict_count:@',      @t_dict_count);
  Reg.Add('dict_haskey:@$',    @t_dict_haskey);
  Reg.Add('dict_exists:@$',    @t_dict_haskey);   // alias: asks without reading
  Reg.Add('dict_remove:@$',    @t_dict_remove);
  Reg.Add('dict_clear@:@',     @t_dict_clear);
  Reg.Add('dict_typename$:@',  @t_dict_typename);
  Reg.Add('dict_key$:@n',      @t_dict_key);
  Reg.Add('dict_type:@',       @t_dict_type);
end;

end.
