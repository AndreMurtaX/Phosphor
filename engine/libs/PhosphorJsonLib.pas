{******************************************************************************
  Phosphor BASIC -- JSON library (a function package under engine/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  A JSON value is a handle over an fpjson node. json_object@/json_array@/
  json_parse@ own their tree; json_get@ hands back a NON-owning handle onto a
  child of an already-owned tree, so ResetHandles (which frees every handle)
  frees each tree exactly once -- the owning wrapper frees the fpjson node, the
  borrowed wrapper frees nothing. Errors are RETURNED; a fabricated handle is
  rejected by GetNode (IsHandle). Array access is 1-based, like everything in
  Phosphor (the reference's JSON arrays were 0-based).
******************************************************************************}
unit PhosphorJsonLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, fpjson, jsonparser,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles, PhosphorBudget;

procedure RegisterJsonFuncs(Reg: TPhosphorRegistry);

{ Byte-exact JSON text for a node -- see the long note above the implementation.
  Exported because a sibling library that builds fpjson trees (the RAG index, the
  SQLite package) must not fall back on AsJSON, which re-encodes every byte >= $80. }
function JsonText(N: TJSONData; APretty: Boolean; AIndent, ALevel: Integer): String;

{ Bridge for a sibling library (e.g. the opt-in SQLite package) that needs to
  build or read JSON handles WITHOUT duplicating the wrapper. JsonRegisterNode
  wraps an fpjson node as a handle with the same ownership rule json_object@
  uses (Owns=True frees the node on ResetHandles; False borrows a node owned by
  another tree). JsonNodeFromHandle validates a handle id and hands back its
  node. One wrapper, one owner -- exactly the pattern IoLib/StrListLib share for
  their byte-buffer type. }
{ ALevel is how deep ANode sits in its own tree -- 1 for a root, which is what a
  sibling package building a tree of its own always has. See TPhosphorJson.Level. }
function JsonRegisterNode(ANode: TJSONData; AOwns: Boolean;
  ALevel: Integer = 1): Int64;
function JsonNodeFromHandle(AHandleId: Int64; out ANode: TJSONData): Boolean;

implementation

type
  { Wraps one fpjson node. Owns=True for a root built or parsed here; Owns=False
    for a child handed out by json_get@ (its node belongs to the parent tree). }
  TPhosphorJson = class
    Node: TJSONData;
    Owns: Boolean;
    { HOW DEEP THIS NODE SITS IN ITS OWN TREE. 1 for a root; a borrowed child is
      its parent's Level + 1.

      fpjson nodes carry no parent pointer, so there is no way to ask a node how
      deep it is -- and without that, a build door cannot tell whether what it is
      about to graft would push the tree past MaxJsonDepth. Recording it when the
      handle is BORROWED costs one addition and is exact, because a live node's
      depth never changes: nothing here re-parents a node (every graft clones),
      and deleting an ancestor frees the node and empties the handle. }
    Level: Integer;
    destructor Destroy; override;
  end;

destructor TPhosphorJson.Destroy;
begin
  if Owns and (Node <> nil) then Node.Free;
  inherited Destroy();
end;

function JsonRegisterNode(ANode: TJSONData; AOwns: Boolean; ALevel: Integer): Int64;
var w: TPhosphorJson;
begin
  w := TPhosphorJson.Create();
  w.Node := ANode;
  w.Owns := AOwns;
  w.Level := ALevel;
  Result := RegisterHandle(w);
end;

function JsonNodeFromHandle(AHandleId: Int64; out ANode: TJSONData): Boolean;
var o: TObject;
begin
  ANode := nil;
  o := HandleObj(AHandleId);
  Result := o is TPhosphorJson;
  if Result then ANode := TPhosphorJson(o).Node;
end;

{ ALevel IS REQUIRED, and it used to default to 1.

  1 is the value a ROOT has, so the default was the unsafe one: a borrow site that
  forgot to pass a level registered a node claiming to be at the top of its own
  tree, and the ceiling below could then be walked straight past. A review measured
  exactly that -- dropping the level at json_get@ let a script build 401 levels
  with every runner on both operating systems still green, while the identical
  omission at json_item@ happened to be caught. A class covered by accident at one
  door and not at the other is worse than one covered nowhere, because it reads as
  covered.

  Required, the omission is a compile error. The exported JsonRegisterNode keeps
  its default: a sibling package registering a tree of its own really does have a
  root, and it is not reaching into anyone's borrowed node. }
function RegJson(N: TJSONData; AOwns: Boolean; ALevel: Integer): TValue;
begin
  Result := ValHandle(JsonRegisterNode(N, AOwns, ALevel));
end;

{ How deep the node this handle names sits in its tree. Only ever called after a
  Get* has already accepted the handle, so a stranger cannot reach it. }
function JsonLevelOf(const V: TValue): Integer;
var o: TObject;
begin
  Result := 1;
  o := HandleObj(V.Hnd);
  if o is TPhosphorJson then Result := TPhosphorJson(o).Level;
end;

{ How deep the tree under N is: 1 for a scalar or an empty container, 1 + the
  deepest child otherwise. Counted no further than ACap, so this is bounded even
  if it is ever handed a tree that got past the doors below. }
function JsonDepthOf(N: TJSONData; ACap: Integer): Integer;
var
  i, d: Integer;
begin
  Result := 1;
  if (N = nil) or (ACap <= 1) then Exit;
  if not (N.JSONType in [jtObject, jtArray]) then Exit;
  for i := 0 to N.Count - 1 do
  begin
    d := 1 + JsonDepthOf(N.Items[i], ACap - 1);
    if d > Result then
    begin
      Result := d;
      if Result >= ACap then Exit(ACap);
    end;
  end;
end;

{ How many path segments a json_*_path spelling names, so a node reached through
  one gets the level it actually sits at rather than its parent's plus one. }
function JsonPathSegments(const APath: String): Integer;
var
  i: Integer;
begin
  Result := 1;
  for i := 1 to Length(APath) do
    if APath[i] = '.' then Inc(Result);
end;

function GetNode(const V: TValue; out N: TJSONData; out Err: TPhosphorError): Boolean;
begin
  N := nil;
  if (V.Kind <> vkHandle) or (not IsHandle(V.Hnd)) or (not (HandleObj(V.Hnd) is TPhosphorJson)) then
  begin
    Err := MakeError(peRuntime, 'not a valid json handle');
    Exit(False);
  end;
  N := TPhosphorJson(HandleObj(V.Hnd)).Node;
  if N = nil then
  begin
    Err := MakeError(peRuntime,
      'this json handle is stale: the value it borrowed was replaced or removed');
    Exit(False);
  end;
  Err := NoError();
  Result := True;
end;

function GetObj(const V: TValue; out O: TJSONObject; out Err: TPhosphorError): Boolean;
var n: TJSONData;
begin
  O := nil;
  if not GetNode(V, n, Err) then Exit(False);
  if not (n is TJSONObject) then
  begin
    Err := MakeError(peRuntime, 'json value is not an object');
    Exit(False);
  end;
  O := TJSONObject(n);
  Result := True;
end;

function GetArr(const V: TValue; out A: TJSONArray; out Err: TPhosphorError): Boolean;
var n: TJSONData;
begin
  A := nil;
  if not GetNode(V, n, Err) then Exit(False);
  if not (n is TJSONArray) then
  begin
    Err := MakeError(peRuntime, 'json value is not an array');
    Exit(False);
  end;
  A := TJSONArray(n);
  Result := True;
end;

{ THE SAME 64-BIT GUARD, THE SAME 32-BIT NARROWING, IN A DIFFERENT LIBRARY.

  The guard here is `Abs(d) < 9.2e18` -- an Int64 window -- and the constructor
  underneath it is `TJSONIntegerNumber.Create(AValue: Integer)` (fcl-json's
  fpjson.pp:263; its field is `FValue : Integer`). Round(d) hands it an Int64 and
  the compiler narrows it without a word, so every JSON number between 2^31 and
  2^63 was stored wrapped:

      json_setn@(o@, "big", 3000000000) : println json_stringify$(o@)
      -> the object rendered "big" as -1294967296

  and json_getn read the wrapped value straight back. Silent corruption of data
  the program handed us intact. fpjson has TJSONInt64Number for exactly this, so
  the fix is to pick the node type the value needs rather than the one the
  smaller range fits. }
function NumNode(d: Double): TJSONData;
var v: Int64;
begin
  if (Frac(d) = 0) and (Abs(d) < 9.2e18) then
  begin
    v := Round(d);
    if (v >= Low(Integer)) and (v <= High(Integer)) then
      Result := TJSONIntegerNumber.Create(Integer(v))
    else
      Result := TJSONInt64Number.Create(v);
  end
  else Result := TJSONFloatNumber.Create(d);
end;

{ A borrowed handle points at a node its parent owns. Replacing or removing that
  member FREES the node, and the borrowed handle was left pointing into freed
  memory -- reading it was an access violation, and writing through it corrupted
  the heap:

      o@ = json_object@()
      json_sets@(o@, "a", "first")
      c@ = json_get@(o@, "a")      ' borrows the child
      json_sets@(o@, "a", "second") ' frees what c@ points at
      json_value$(c@)               ' -> access violation

  Before any node is freed, every borrowed handle pointing at it OR AT ANYTHING
  INSIDE IT is emptied, so the read that follows is a clean "stale handle" error
  instead of a crash. Owned handles are left alone: they hold their own trees. }
const
  { How deep a JSON tree may be, everywhere: what json_parse@ refuses in a
    document and what the two graft gates below refuse in a tree a script builds.
    The reasoning for the number, and the measurements behind it, are in the long
    note above JsonNestsTooDeep. }
  MaxJsonDepth = 256;

{ Would grafting AAdd under a target at ALevel take the tree past the ceiling?
  A refusal sets Err; the caller frees what it built. }
function GraftTooDeep(ALevel: Integer; AAdd: TJSONData;
  out Err: TPhosphorError): Boolean;
begin
  Result := ALevel + JsonDepthOf(AAdd, MaxJsonDepth + 1) > MaxJsonDepth;
  if Result then
    Err := MakeError(peRuntime, Format(
      'json: this would nest more than %d levels deep', [MaxJsonDepth]))
  else
    Err := NoError();
end;

function NodeContains(ARoot, ATarget: TJSONData): Boolean;
var i: Integer;
begin
  if (ARoot = nil) or (ATarget = nil) then Exit(False);
  if ARoot = ATarget then Exit(True);
  Result := False;
  if ARoot.JSONType in [jtObject, jtArray] then
    for i := 0 to ARoot.Count - 1 do
      if NodeContains(ARoot.Items[i], ATarget) then Exit(True);
end;

{ Walks the LIVE handles, not the table.

  This loop was `for i := 1 to HandleCount`, and HandleCount was the number of
  handles ever created -- so replacing one member cost a step for every handle the
  program had ever made, including all the ones it had correctly freed. Measured:
  20,000 json_setn@ took 0.24 s in a fresh process and 48 s after a million
  create/free cycles that left nothing live. Nothing here was wrong; the registry
  could not tell it which handles still existed. Now it can.

  Nothing in this loop frees a handle, which is what makes the walk safe -- see
  the warning on NextLiveHandle.

  COUNTED, not merely terminated by the list. LiveHandleCount is both the honest
  bound -- there is nothing else to visit -- and a guarantee that this walk ends
  even if the live list were ever left inconsistent, which matters because it runs
  while a subtree is being destroyed. scripts/check-budget.py reads it as bounded
  for the same reason it read `1 to HandleCount` as bounded: a count of what is
  already in memory is not an amplifier. }
procedure InvalidateBorrowed(ANode: TJSONData);
var
  id: Int64;
  i: Integer;
  o: TObject;
  w: TPhosphorJson;
begin
  if ANode = nil then Exit;
  id := FirstLiveHandle();
  for i := 1 to LiveHandleCount() do
  begin
    if id = 0 then Break;
    o := HandleObj(id);
    if o is TPhosphorJson then
    begin
      w := TPhosphorJson(o);
      if (not w.Owns) and NodeContains(ANode, w.Node) then
        w.Node := nil;
    end;
    id := NextLiveHandle(id);
  end;
end;

{ Look a member up by name WITHOUT fpjson's Find.

  Find compares names in a way that misses a non-ASCII name entirely: for a key
  stored byte-exactly (Names[i] reads it back unchanged) Find returns nil while
  IndexOfName finds it at 0. A member that can be written and never read is not a
  member, so every lookup here goes through IndexOfName. }
function FindMember(O: TJSONObject; const AName: String): TJSONData;
var idx: Integer;
begin
  Result := nil;
  if O = nil then Exit;
  idx := O.IndexOfName(AName);
  if idx >= 0 then Result := O.Items[idx];
end;

{ THE DEPTH CEILING IS ENFORCED HERE, AND IN AddItem, AND NOWHERE ELSE.

  MaxJsonDepth used to be asked exactly one question, in t_json_parse, and the
  comment above it explains what it is for: fpjson's parser recurses, and so does
  its DESTRUCTOR, so a document's nesting is spent on the process stack twice.
  Everything a script BUILDS bypassed that. A plain loop that nests a fragment in
  a fragment reached depth 131072 with ~131k nodes; the program printed its
  complete and correct output and then died in teardown with an unhandled
  EStackOverflow and exit 3, handing the shell a failure for a run that had
  succeeded. json_stringify$ on the same tree was a segmentation fault.

  Thirteen doors add a node to a tree. Guarding thirteen doors is how this project
  has written defects before -- one more spelling walks through the fourteenth --
  so the check sits on the two functions every one of them goes through, and they
  take the target's Level and answer False rather than grafting. The refused node
  is FREED here: the caller built or cloned it before asking, and a refusal that
  leaked would be a worse bug than the one being refused.

  EVERY SCRIPT-DRIVEN GRAFT, precisely. Two Add calls in this unit do not come
  through here, and are safe for reasons of their own: JsonUnmarkTree's
  Extract-then-Add renames a member and preserves the tree's shape exactly, and
  t_json_keys builds a fresh array of plain strings, which is depth two. Neither
  can be handed a node a script chose. }
function SetMember(O: TJSONObject; ALevel: Integer; const K: String;
  V: TJSONData; out Err: TPhosphorError): Boolean;
var idx: Integer;
begin
  if GraftTooDeep(ALevel, V, Err) then
  begin
    V.Free;
    Exit(False);
  end;
  idx := O.IndexOfName(K);
  if idx >= 0 then
  begin
    InvalidateBorrowed(O.Items[idx]);
    O.Delete(idx);
  end;
  O.Add(K, V);
  Result := True;
end;

{ The array half of the same gate. }
function AddItem(A: TJSONArray; ALevel: Integer; V: TJSONData;
  out Err: TPhosphorError): Boolean;
begin
  if GraftTooDeep(ALevel, V, Err) then
  begin
    V.Free;
    Exit(False);
  end;
  A.Add(V);
  Result := True;
end;

{ Read any node as a number without ever raising. A number is exact; a bool is
  0/1; a numeric string is parsed (else 0); null / object / array read as 0. (The
  old code called AsFloat on every non-number, which raised EConvertError on a
  non-numeric string and crashed the program -- a reader must return a value.) }
function NumVal(N: TJSONData): TValue;
var d: Double; fs: TFormatSettings;
begin
  case N.JSONType of
    jtNumber:
      if TJSONNumber(N).NumberType = ntInteger then Result := ValInt(N.AsInt64)
      else Result := ValDouble(N.AsFloat);
    jtBoolean:
      if N.AsBoolean then Result := ValInt(1) else Result := ValInt(0);
    jtString:
      begin
        fs := DefaultFormatSettings;
        fs.DecimalSeparator := '.';
        fs.ThousandSeparator := #0;
        if TryStrToFloat(N.AsString, d, fs) then Result := ValDouble(d)
        else Result := ValInt(0);
      end;
  else
    Result := ValInt(0);   // jtNull / jtObject / jtArray
  end;
end;

{ ------------------------------------------------------------------------------
  JSON TEXT, BYTE-EXACT.

  fpjson's own serializer is not. StringToJSONString -- the only escaper it
  exposes, and the one every AsJSON/FormatJSON path goes through -- returns SEVEN
  bytes for the five-byte string "cafe" with an acute e: the UTF-8 pair C3 A9
  comes back as C3 83 C2 A9, each byte re-encoded as though it were a separate
  Latin-1 character. Measured directly against fcl-json 3.2.2:

      TJSONString.Create(s).AsString  ->  63 61 66 C3 A9      (correct)
      TJSONString.Create(s).AsJSON    ->  22 63 61 66 C3 83 C2 A9 22

  So the tree HELD the right bytes and only rendering broke them, which is why a
  json_gets$ round trip looked fine while the text written to a file was mojibake.

  Only strings and structure are assembled here. Numbers, booleans and null keep
  fpjson's own rendering: they are ASCII, so they cannot be damaged, and borrowing
  them keeps this byte-identical to the previous output for every ASCII document
  -- including fpjson's spacing, which is preserved deliberately. Fixing the
  corruption is this change; restyling the output is not.
  ------------------------------------------------------------------------------ }

{ The escapes JSON requires, and no others. Every byte >= $80 passes through
  untouched: UTF-8 in, the same UTF-8 out. Built by appending SLICES, never a
  Char (see scripts/check-codepage.py). }
{ QUADRATIC APPEND, charged as it goes (RULE 2). This is the worst one in the
  tree and it was invisible to the gate for two rounds: `Result := Result + ..`
  fires once per SPECIAL character, so a string of quotes copies the whole answer
  per character. Measured, unbudgeted: 703 / 2658 / 11526 / 63680 / 200023 ms for
  25000 / 50000 / 100000 / 200000 / 400000 quotes -- json_stringify$ of a one
  megabyte string of quotes did not finish in five minutes under a 2000 ms
  ceiling, at 17 MB of memory, so nothing else would ever have stopped it.

  The size is NOT knowable up front (it is the count of specials, not Length(S)),
  so this is RULE 2 rather than RULE 1: each append is charged for the bytes it
  copies. A string with no specials pays for one append and is untouched.

  On refusal the answer is emptied, not truncated -- and the budget LATCHES, so
  the BufAdd that JsonWrite makes immediately after this call sets B.Spent and
  json_stringify$/json_pretty$ return the peLimit. }
function JsonEscape(const S: String): String;
var
  i, runStart: Integer;
  c: Char;
begin
  Result := '';
  runStart := 1;
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if (c = '"') or (c = '\') or (c < #32) then
    begin
      if not BudgetAppend(Length(Result)) then begin Result := ''; Exit; end;
      if i > runStart then Result := Result + Copy(S, runStart, i - runStart);
      case c of
        '"':  Result := Result + '\"';
        '\':  Result := Result + '\\';
        #8:   Result := Result + '\b';
        #9:   Result := Result + '\t';
        #10:  Result := Result + '\n';
        #12:  Result := Result + '\f';
        #13:  Result := Result + '\r';
      else
        Result := Result + '\u' + LowerCase(IntToHex(Ord(c), 4));
      end;
      runStart := i + 1;
    end;
  end;
  if Length(S) >= runStart then
  begin
    if not BudgetAppend(Length(Result)) then begin Result := ''; Exit; end;
    Result := Result + Copy(S, runStart, Length(S) - runStart + 1);
  end;
end;

{ An upper bound on the PADDING JsonText can emit: it writes one pad per node and
  no pad is wider than AIndent times the deepest nesting, so AIndent * ACount *
  ADepth is never less than what the render will build. Walking the tree costs
  what rendering it costs, and the tree is already in memory. }
procedure JsonShape(N: TJSONData; ALevel: Integer; var ACount, ADepth: Int64);
var
  i: Integer;
begin
  if N = nil then Exit;
  Inc(ACount);
  if ALevel > ADepth then ADepth := ALevel;
  for i := 0 to N.Count - 1 do
    JsonShape(N.Items[i], ALevel + 1, ACount, ADepth);
end;

{ RENDERING A DOCUMENT IS ONE opCall, AND IT WAS QUADRATIC TOO.

      s$ = "[" + mulstring$("1,", 100000) + "1]"
      j@ = json_parse@(s$)
      println bytelen(json_pretty$(j@, 8))    ' 64985 ms, rc=0 SUCCESS

  Sixty-five seconds under MaxSteps=1000000 / TimeoutMs=2000, reported as
  success. The round-one guard on json_pretty$ bounded the PADDING -- indent
  times nodes times depth -- and the padding really was bounded; what was not was
  `Result := Result + ...` once per member, which copies the whole answer built so
  far every time. Bounding one term of a cost is not bounding the cost.

  So the renderer now appends into a buffer that grows geometrically, and CHARGES
  each byte it appends (RULE 2: the size of a rendered tree is not derivable from
  the handle, but every byte of it passes through here). A render the budget stops
  sets JSpent, and json_stringify$/json_pretty$ report it rather than handing back
  a truncated document. The bytes produced are exactly the bytes the append loop
  produced -- the sweep in scripts/probe_budget.lpr pins that. }
type
  TJsonBuf = record
    Data: String;
    Len: SizeInt;
    Spent: Boolean;
    Wild: Boolean;    // a number in the tree has no JSON text -- see JsonWrite
  end;

  { Why a render can stop short. jtrBudget and jtrWild are BOTH refusals, and
    the caller must say which: one is "this document is too big for the budget
    you set", the other is "this document cannot be written as JSON at all". }
  TJsonTextResult = (jtrOk, jtrBudget, jtrWild);

procedure BufInit(out B: TJsonBuf);
begin
  B.Data := '';
  B.Len := 0;
  B.Spent := False;
  B.Wild := False;
end;

procedure BufAdd(var B: TJsonBuf; const S: String);
var need, grow: SizeInt;
begin
  if (S = '') or B.Spent or B.Wild then Exit;
  if not BudgetCharge(Length(S)) then begin B.Spent := True; Exit; end;
  need := B.Len + Length(S);
  if need > Length(B.Data) then
  begin
    grow := Length(B.Data) * 2;
    if grow < need then grow := need;
    if grow < 256 then grow := 256;
    SetLength(B.Data, grow);
  end;
  Move(S[1], B.Data[B.Len + 1], Length(S));
  B.Len := need;
end;

function BufStr(const B: TJsonBuf): String;
begin
  Result := Copy(B.Data, 1, B.Len);
end;

procedure JsonWrite(var B: TJsonBuf; N: TJSONData; APretty: Boolean;
  AIndent, ALevel: Integer);
var
  i: Integer;
  pad, padIn, sep: String;
  o: TJSONObject;
  a: TJSONArray;
begin
  if B.Spent or B.Wild then Exit;
  if N = nil then begin BufAdd(B, 'null'); Exit; end;
  case N.JSONType of
    jtString:
      begin
        BufAdd(B, '"');
        BufAdd(B, JsonEscape(TJSONString(N).AsString));
        BufAdd(B, '"');
      end;
    jtObject:
      begin
        o := TJSONObject(N);
        if o.Count = 0 then begin BufAdd(B, '{}'); Exit; end;   // inline, in both modes
        if APretty then
        begin
          pad := StringOfChar(' ', AIndent * (ALevel + 1));
          padIn := StringOfChar(' ', AIndent * ALevel);
          BufAdd(B, '{' + #10);
          sep := '';
          for i := 0 to o.Count - 1 do
          begin
            BufAdd(B, sep);
            BufAdd(B, pad);
            BufAdd(B, '"');
            BufAdd(B, JsonEscape(o.Names[i]));
            BufAdd(B, '" : ');
            JsonWrite(B, o.Items[i], True, AIndent, ALevel + 1);
            if B.Spent or B.Wild then Exit;
            sep := ',' + #10;
          end;
          BufAdd(B, #10);
          BufAdd(B, padIn);
          BufAdd(B, '}');
        end
        else
        begin
          // COMPACT, the word the reference uses. It used to emit '{ ', ' : ' and
          // ' }', while the array branch below was already compact -- so objects
          // were the inconsistency, not the format. json_pretty$ is the readable
          // rendering; this one is the one that goes over a wire.
          BufAdd(B, '{');
          for i := 0 to o.Count - 1 do
          begin
            if i > 0 then BufAdd(B, ',');
            BufAdd(B, '"');
            BufAdd(B, JsonEscape(o.Names[i]));
            BufAdd(B, '":');
            JsonWrite(B, o.Items[i], False, AIndent, 0);
            if B.Spent or B.Wild then Exit;
          end;
          BufAdd(B, '}');
        end;
      end;
    jtArray:
      begin
        a := TJSONArray(N);
        if APretty then
        begin
          padIn := StringOfChar(' ', AIndent * ALevel);
          if a.Count = 0 then begin BufAdd(B, '[' + #10 + padIn + ']'); Exit; end;
          pad := StringOfChar(' ', AIndent * (ALevel + 1));
          BufAdd(B, '[' + #10);
          sep := '';
          for i := 0 to a.Count - 1 do
          begin
            BufAdd(B, sep);
            BufAdd(B, pad);
            JsonWrite(B, a.Items[i], True, AIndent, ALevel + 1);
            if B.Spent or B.Wild then Exit;
            sep := ',' + #10;
          end;
          BufAdd(B, #10);
          BufAdd(B, padIn);
          BufAdd(B, ']');
        end
        else
        begin
          if a.Count = 0 then begin BufAdd(B, '[]'); Exit; end;
          BufAdd(B, '[');
          for i := 0 to a.Count - 1 do
          begin
            if i > 0 then BufAdd(B, ', ');
            JsonWrite(B, a.Items[i], False, AIndent, 0);
            if B.Spent or B.Wild then Exit;
          end;
          BufAdd(B, ']');
        end;
      end;
  else
    { NUMBERS, BOOLEANS AND NULL -- ASCII, and that was the whole argument.

      It is true of every value this library can BUILD, because a TValue can only
      hold a finite Double (FiniteD, in PhosphorValue: "no TValue ever holds a
      non-finite Double"). It was never true of a value fpjson can hold. Give
      fpjson an infinity and AsJSON hands back FloatToStr's `+Inf`, right-padded
      to nineteen columns:

          d@ = json_parse@("[1e400]")
          println json_stringify$(d@)   ->  [                   +Inf]

      That is not JSON. Every parser rejects it, Phosphor's own included, and
      json_stringify$ is what feeds file_writealltext and an HTTP body -- so the
      program writes a document nothing can read back and nothing says a word.

      The door such a value comes through is closed at json_parse@ below, which
      is where FOREIGN text becomes internal data (the same place the lexer
      refuses `x = 1e999`). This is the second half of that: a sibling package
      that builds fpjson trees of its own -- the SQLite one, through
      JsonRegisterNode -- can put an out-of-range REAL in a tree without passing
      through the parser, and the renderer must not answer it with text that is
      not JSON. Refusing here makes "json_stringify$ emits JSON" true of every
      tree, however the tree was built. }
    if (N.JSONType = jtNumber) and (TJSONNumber(N).NumberType = ntFloat) and
       (not IsFiniteD(N.AsFloat)) then
      B.Wild := True
    else
      BufAdd(B, N.AsJSON);
  end;
end;

{ jtrOk = the whole document was rendered. Anything else is a refusal the caller
  must report rather than hand back what it got so far. }
function JsonTextTry(N: TJSONData; APretty: Boolean; AIndent, ALevel: Integer;
  out AText: String): TJsonTextResult;
var b: TJsonBuf;
begin
  BufInit(b);
  JsonWrite(b, N, APretty, AIndent, ALevel);
  AText := '';
  if b.Wild then Result := jtrWild
  else if b.Spent then Result := jtrBudget
  else
  begin
    Result := jtrOk;
    AText := BufStr(b);
  end;
end;

function JsonText(N: TJSONData; APretty: Boolean; AIndent, ALevel: Integer): String;
begin
  if JsonTextTry(N, APretty, AIndent, ALevel, Result) <> jtrOk then Result := '';
end;

{ Named for the caller, the way BudgetRefusal is, so `on error goto` reads which
  function stopped and why. }
function WildRefusal(const AFn: String): TPhosphorError;
begin
  Result := MakeError(peRuntime, AFn +
    ': a number in the document is out of range and has no JSON text');
end;

{ Read any node as a string without raising: null is "", an object/array is its
  compact JSON text, everything else its AsString. }
function StrVal(N: TJSONData): String;
begin
  if (N = nil) or (N.JSONType = jtNull) then Result := ''
  else if N.JSONType in [jtObject, jtArray] then Result := JsonText(N, False, 2, 0)
  else Result := N.AsString;
end;

// --- constructors -----------------------------------------------------------
function t_json_object(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := RegJson(TJSONObject.Create(), True, 1); end;

function t_json_array(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := RegJson(TJSONArray.Create(), True, 1); end;

{ THE NESTING CEILING FOR PARSED JSON, and why it is measured on the TEXT rather
  than counted inside the parser.

  fpjson's GetJSON is recursive descent, and the tree it hands back is freed by a
  recursive destructor -- so a document's nesting depth is spent on the process
  stack TWICE, once going in and once on the way out. Measured here, before the
  ceiling existed: 40000 levels of "[[[...]]]" parsed and exited 0; 50000 levels
  parsed CORRECTLY, printed the program's complete and correct output, and then
  died in teardown -- "phosphor: unhandled EStackOverflow" and exit 0xC0000005 --
  while ResetHandles freed the tree, handing the shell a crash status for a run
  that had already succeeded; 200000 levels never returned from the parse at all.
  A stack overflow is not an exception a handler can catch, so the try/except a
  few lines below never saw it and neither did the program's `on error goto`.

  That teardown half is why the check is a scan of the text and not a depth
  counter threaded through the parse: refusing the document is the only way to be
  sure the recursive destructor is never handed a 50000-deep tree, because by the
  time a counter inside the parser could complain the tree already exists.

  256 is the ceiling the compiler already puts on nested expressions
  (MaxExprDepth in PhosphorCompiler), adopted here for the same stated reason --
  unbounded recursion on input the program did not write is a defect, not a
  feature. json_parse@ is the one function in this library whose input is foreign
  by definition (a file, an HTTP body), and 256 is far past anything a person or a
  serializer emits: .NET's JSON reader stops at 64.

  MaxJsonDepth itself was MOVED UP on 2026-09-10, to sit just above the graft gate
  that now also reads it. This note stays where it was written. }

{ True when AText nests deeper than ALimit, with APos set to the character that
  crossed it. Brackets inside a string literal are text, not structure, so the
  scan tracks string state and its backslash escapes; unbalanced closers are left
  to the parser, which reports them far better than a depth scan could. Only
  nesting counts, so a long FLAT document -- 100k sibling elements -- is
  unaffected however long it gets, exactly as a long non-nested expression is. }
{ THE DELIMITER IS TRACKED, and this scanner was the last of three to learn it.

  fpjson opens a string on a double quote OR on a single quote -- the single quote
  is refused only under joStrict, which t_json_parse does not set, so an object
  whose key is written in single quotes really does parse. This scan opened one
  only on the double quote, so a document could hand it an ODD number of them: a
  double quote inside a single-quoted value flipped the scan into a string, the one
  opening the next key flipped it out, and every bracket after that was read as
  text. depth never
  rose, the 256-level ceiling was never reached, and GetJSON was handed the
  document to recurse over -- 50,000 levels was EStackOverflow with exit 127, and
  200,000 was a segmentation fault with no diagnostic at all.

  JsonHasUEscape and JsonRespellText both hold the opening delimiter in a Char for
  exactly this reason, and say so in their own comments. This one was not brought
  along: the completeness half of the same defect, a third time. }
function JsonNestsTooDeep(const AText: String; ALimit: Integer;
  out APos: Int64): Boolean;
var
  i, depth: Int64;
  delim: Char;
  esc: Boolean;
begin
  APos := 0;
  depth := 0;
  delim := #0;                          // #0 = not inside a literal
  esc := False;
  for i := 1 to Length(AText) do
  begin
    if delim <> #0 then
    begin
      if esc then esc := False
      else if AText[i] = '\' then esc := True
      else if AText[i] = delim then delim := #0;   // the SAME one closes it
      Continue;
    end;
    case AText[i] of
      '"', '''': delim := AText[i];
      '[', '{':
        begin
          Inc(depth);
          if depth > ALimit then
          begin
            APos := i;
            Exit(True);
          end;
        end;
      ']', '}': if depth > 0 then Dec(depth);
    end;
  end;
  Result := False;
end;

{ THE NUMBER THAT DOES NOT FIT, and why the whole document is refused for it.

  `1e400` is well-formed JSON text and fpjson parses it happily: StrToFloat says
  True and hands back +Inf, so the tree holds a Double the rest of the engine has
  been promised does not exist. PhosphorValue's FiniteD states the invariant --
  "no TValue ever holds a non-finite Double" -- and it is the sole reason this
  build can run with the invalid-operation trap unmasked. A parsed tree was the
  hole in it. Everything downstream then lied in its own way: json_stringify$ and
  json_pretty$ wrote `+Inf` padded to nineteen columns, which is not JSON and
  which Phosphor's own parser rejects; json_gets$ and json_value$ answered the
  same text; only json_getn was caught, by the VM's gate on library returns.

  Refusing the DOCUMENT rather than the member is the treatment this engine
  already gives every other door foreign text comes through, and both of them are
  tested:

      x = 1e999            -> the lexer refuses it (tests/negative/25_...)
      input x  (field "1e999") -> `"1e999" is out of range` and x is unchanged
                              (tests/classic/16_input_nonfinite.bas, BOTH doors,
                               console and file)

  A parsed document is the third door and it now answers the same way. The walk
  is over a tree whose depth JsonNestsTooDeep has already capped at 256, so the
  recursion here is bounded by the same ceiling the parse was.

  Only ntFloat is asked: an integer node cannot be non-finite, and a plain-digit
  overflow (`1` and four hundred zeros) is already refused by fpjson itself with
  "Number is not an integer or real number". Exponent form was the spelling that
  walked through. }
function FirstWildNumber(N: TJSONData; const APath: String;
  out AWhere: String): Boolean;
var
  i: Integer;
  o: TJSONObject;
begin
  Result := False;
  if N = nil then Exit;
  case N.JSONType of
    jtNumber:
      if (TJSONNumber(N).NumberType = ntFloat) and (not IsFiniteD(N.AsFloat)) then
      begin
        AWhere := APath;
        Result := True;
      end;
    jtObject:
      begin
        o := TJSONObject(N);
        for i := 0 to o.Count - 1 do
          if FirstWildNumber(o.Items[i], APath + '.' + o.Names[i], AWhere) then
            Exit(True);
      end;
    jtArray:
      for i := 0 to N.Count - 1 do
        if FirstWildNumber(N.Items[i], APath + '[' + IntToStr(i + 1) + ']',
                           AWhere) then
          Exit(True);
  end;
end;

{ The path FirstWildNumber built, phrased for a person. The root itself has no
  path, and a name at the top level carries a leading '.' that reads as noise. }
function WildWhere(const APath: String): String;
begin
  if APath = '' then Exit('the number');
  if APath[1] = '.' then
    Result := 'the number at ' + Copy(APath, 2, Length(APath) - 1)
  else
    Result := 'the number at ' + APath;
end;

{ ------------------------------------------------------------------------------
  \uXXXX, DECODED ON THIS SIDE OF THE PARSER -- the reader's half of the
  hand-written serializer above.

  The serializer was hand-written because fpjson's rendering of a string is not
  byte-exact. Its READING of one is not either, and for four separate reasons
  that are all one mechanism: jsonscanner.pp decodes \uXXXX itself, through an
  ambient code page, into `S : String[4]` -- a four-byte ShortString -- holding a
  pending escape in `u1` and using ZERO as its "nothing pending" sentinel
  (jsonscanner.pp:342-370 and MaybeAppendUnicode at :261). Measured against
  fcl-json 3.2.2, all four on a freshly built binary:

    1. \u0000 IS DROPPED. u1 := 0 is indistinguishable from "no escape pending",
       so the NUL is never emitted:

           json_sets@(o@, "k", "a" + bytestr$(0) + "b")   ' 61 00 62
           json_stringify$(o@)   ->  "k" : "a\u0000b"   ' our writer is right
           json_parse@(that)     ->  61 62                ' one byte gone

       A value the library itself stored could not be read back, and nothing said
       a word. Every other control byte survived, which is what hid it:
       \u0001 and \u001f come back intact.

    2. A LONE SURROGATE IS DROPPED. "\ud83d" answered zero bytes, "\ud83dx"
       answered just the x.

    3. TWO ADJACENT ESCAPES ARE TRUNCATED TO FOUR BYTES, because a PAIR is
       decoded into that ShortString together:

           "\u0800\u0800"  ->  E0 A0 80 E0     (4 bytes, not 6)
           "\uffff\uffff"  ->  EF BF BF EF
           "\u00e9\u0800"  ->  C3 A9 E0 A0
           "\u0800\ud83d\ude00"  ->  E0 A0 80   (the pair vanished)

       Each of those answers is not merely short, it is not valid UTF-8.

    4. AND WHICH OF ITS TWO BRANCHES RUNS DEPENDS ON DefaultSystemCodePage, a
       process-wide global no script can see. The two hosts in this repository
       disagree about the same document, because phosphor.exe links the LCL
       (which sets the code page to UTF-8) and phosphortest.exe does not:

           "k" : "\u00e9"   phosphor.exe -> C3 A9     phosphortest.exe -> E9
           "k" : "\u0800"   phosphor.exe -> E0 A0 80  phosphortest.exe -> 3F

       An embedder linking the engine gets whichever answer its own unit list
       happens to produce. That is not a parser.

  THE FIX, and why it is a rewrite of the TEXT rather than a new parser. fpjson
  is only wrong about string ESCAPES; its structure, its numbers and its error
  messages are all wanted as they are. So the escapes are decoded here, and the
  document is handed on with every string re-spelled in the one dialect fpjson
  reproduces byte for byte -- measured, every byte 0..255 and every escape form:

      byte $22 -> \"      byte $5C -> \\
      $08 $09 $0A $0C $0D -> \b \t \n \f \r
      $02..$1F otherwise  -> \u00xx        (all thirty measured exact)
      $20..$FF            -> the raw byte  (all measured exact, both hosts)

  Every escape emitted here is therefore below $80, where the two code-page
  branches agree, and a PAIR of them is two bytes, where the ShortString cannot
  overflow. Defects 2, 3 and 4 have nowhere left to happen.

  THE ONE BYTE WITH NO SPELLING is $00: \u0000 is what fpjson drops, and a raw
  NUL ends the scan (its buffer is walked as a PAnsiChar). So $00 travels as a
  two-escape MARKER, and $01 -- the only byte that marker could be confused with
  -- travels as another:

      $00 -> \u0001\u0001   which fpjson decodes to  01 01
      $01 -> \u0001\u0002   which fpjson decodes to  01 02

  That is a prefix code: after a re-spelling, byte $01 in a decoded string ALWAYS
  opens a two-byte marker and never stands alone, so JsonUnmark's scan is exact
  rather than heuristic, and it is injective, so two distinct keys cannot collide
  when they are unmarked.

  THE CONDITION THAT CLAIM RESTS ON, WHICH THE FIRST VERSION DID NOT MEET.
  "Byte $01 always opens a marker" is a statement about a string THE REWRITE
  PRODUCED. JsonUnmarkTree finds the strings to undo by SCANNING the parsed tree
  for a $01, and a sentinel scanned for after the fact cannot tell a byte this
  unit wrote from a byte that was already in the data. $01 is a byte real data
  can hold. So the rewrite has to be TOTAL over the string tokens the parser will
  read -- every one of them, or the unmarker is walking somebody else's bytes.

  It was not total. GetJSON(txt, False) leaves Options empty, and
  jsonscanner.pp:314 opens a string on '"' OR on a SINGLE QUOTE -- fpjson's own
  extension, refused only under joStrict, which is not set. The first version
  knew about '"' alone, so a single-quoted literal was copied through unrewritten
  while the unmarker still walked what it decoded to. An all-printable-ASCII
  document with no NUL anywhere in it then manufactured one:

      an object of two members: "note":"caf\u00e9" beside a
      SINGLE-quoted 'name' whose value is report<01><01>txt

          before   72 65 70 6F 72 74 01 01 74 78 74     (right)
          after    72 65 70 6F 72 74 00 74 78 74        (a NUL nobody wrote)

  which is this unit's own defect with the arrow reversed, and in a project whose
  safety story is about paths it is the byte that truncates one. BOTH delimiters
  are re-spelled now, and both are re-emitted with '"': $22 is spelled \" and the
  single quote passes through as a raw byte, so a single-quoted literal converts
  cleanly and fpjson accepts a "-literal everywhere it accepted the other. The
  same hole was a COMPLETENESS gap in the other direction -- 'a\u0000b' lost its
  NUL until the rewrite reached inside single quotes -- and one fix closes both.

  ACCEPTANCE IS NOT ALLOWED TO MOVE, and a rewrite is exactly the thing that
  moves it. Measured over every raw byte 0..31 inside a literal, both delimiters,
  with and without an unrelated \u escape elsewhere in the document: fpjson
  refuses exactly ONE of them -- a raw $00, "string exceeds end of line" -- and
  accepts the other thirty-one verbatim. The rewrite spells a raw $00 as a
  marker, which would have made such a document accepted when an escape happened
  to stand elsewhere in it and refused when none did. So a raw $00 inside a
  literal ABANDONS the rewrite, exactly as a malformed escape does, and fpjson
  refuses the caller's own bytes with its own message. Bytes $01..$1F are
  re-spelled and decode back to themselves, so they are accepted as before.

  POSITIONS BELONG TO THE CALLER'S TEXT. fpjson reports "Pos n" against the text
  it was handed, and that text is not the text the caller wrote: six characters
  of \u escape stand where one byte will. A 35-character document whose error
  fpjson puts at Pos 34 became Pos 14. So when the REWRITTEN text fails to parse,
  the ORIGINAL is parsed again and ITS error is the one reported -- a second
  parse, on the failure path only.

  AND IT IS CHARGED. One raw $01 byte leaves as twelve characters, so the text
  handed to GetJSON can be twelve times the document, and with TTxtBuf's doubling
  and TxtStr's Copy the peak is several times that again. Every byte written is
  charged one unit, the way BufAdd charges on the writing side. A refusal returns
  the peLimit from json_parse@ rather than quietly handing the original to
  GetJSON, because that fallback would answer a document fpjson reads wrongly.

  WHEN IT ENGAGES. Only when the document actually contains a \u escape inside a
  string -- which is the only case fpjson gets wrong. A document without one is
  handed to GetJSON untouched, byte for byte, exactly as before, and no marker
  exists for the walk to undo. A document this cannot re-spell faithfully (an
  escape the standard does not define, a raw NUL in a literal, an unterminated
  string) is ALSO handed over untouched, so fpjson raises its own error with its
  own wording and this change cannot invent one.
  ------------------------------------------------------------------------------ }

const
  { The two markers, in one place, so the writer and JsonUnmark cannot drift. }
  MarkNul = '\u0001\u0001';
  MarkOne = '\u0001\u0002';

type
  { A grow-by-doubling byte buffer, so the re-spelling is linear. `Result :=
    Result + ..` in a loop over the document would be the quadratic append this
    unit already paid for once in JsonEscape (see the note there). Every size
    below is Length() of something already in memory.

    Charge says whether the bytes written here are BUDGETED. The re-spelling is
    charged: it can turn one document byte into twelve, and nothing else on the
    parse path looks at that. The UNMARKING is not, and deliberately -- it walks
    a tree fpjson has already built out of text this buffer already paid for, and
    a refusal in the middle of it would leave a half-undone string, which is a
    silent wrong answer where a refusal was wanted. }
  TTxtBuf = record
    Data: String;
    Len: SizeInt;
    Charge: Boolean;
    Spent: Boolean;
  end;

procedure TxtInit(out B: TTxtBuf; ACharge: Boolean);
begin
  B.Data := '';
  B.Len := 0;
  B.Charge := ACharge;
  B.Spent := False;
  SetLength(B.Data, 256);
end;

procedure TxtRoom(var B: TTxtBuf; ANeed: SizeInt);
var grow: SizeInt;
begin
  if ANeed <= Length(B.Data) then Exit;
  grow := Length(B.Data) * 2;
  if grow < ANeed then grow := ANeed;
  SetLength(B.Data, grow);
end;

procedure TxtAdd(var B: TTxtBuf; const S: String);
begin
  if (S = '') or B.Spent then Exit;
  // One unit per byte written, which is exactly what BufAdd charges on the
  // writing side of this unit.
  if B.Charge and not BudgetCharge(Length(S)) then begin B.Spent := True; Exit; end;
  TxtRoom(B, B.Len + Length(S));
  Move(S[1], B.Data[B.Len + 1], Length(S));
  B.Len := B.Len + Length(S);
end;

{ One byte, stored through an INDEX rather than concatenated: appending a Char to
  a string that carries the UTF8 code page re-encodes it, which is the whole
  subject of scripts/check-codepage.py. An indexed store is a byte store. }
procedure TxtAddByte(var B: TTxtBuf; AByte: Byte);
begin
  if B.Spent then Exit;
  if B.Charge and not BudgetCharge(1) then begin B.Spent := True; Exit; end;
  TxtRoom(B, B.Len + 1);
  B.Data[B.Len + 1] := Chr(AByte);
  B.Len := B.Len + 1;
end;

function TxtStr(const B: TTxtBuf): String;
begin
  Result := Copy(B.Data, 1, B.Len);
end;

function JsonHexNibble(c: Char; out AVal: Integer): Boolean;
begin
  case c of
    '0'..'9': AVal := Ord(c) - Ord('0');
    'a'..'f': AVal := Ord(c) - Ord('a') + 10;
    'A'..'F': AVal := Ord(c) - Ord('A') + 10;
  else
    AVal := 0;
    Exit(False);
  end;
  Result := True;
end;

{ The four hex digits of a \uXXXX at APos. False -- rather than a partial value --
  when they run off the end or are not hex, so the caller can hand fpjson the
  original text and let it report the malformed escape itself. }
function JsonHex4(const S: String; APos: Integer; out AVal: Integer): Boolean;
var i, n: Integer;
begin
  AVal := 0;
  Result := False;
  if (APos < 1) or (APos + 3 > Length(S)) then Exit;
  for i := 0 to 3 do
  begin
    if not JsonHexNibble(S[APos + i], n) then begin AVal := 0; Exit; end;
    AVal := AVal * 16 + n;
  end;
  Result := True;
end;

{ One decoded byte, re-spelled in the dialect fpjson reads back exactly. }
procedure JsonRespellByte(var B: TTxtBuf; AByte: Byte);
begin
  case AByte of
    0:  TxtAdd(B, MarkNul);
    1:  TxtAdd(B, MarkOne);
    8:  TxtAdd(B, '\b');
    9:  TxtAdd(B, '\t');
    10: TxtAdd(B, '\n');
    12: TxtAdd(B, '\f');
    13: TxtAdd(B, '\r');
    34: TxtAdd(B, '\"');
    92: TxtAdd(B, '\\');
  else
    if AByte < 32 then TxtAdd(B, '\u00' + LowerCase(IntToHex(AByte, 2)))
    else TxtAddByte(B, AByte);
  end;
end;

{ A codepoint as UTF-8, each byte then re-spelled. U+0000 is one byte here, as
  the standard says -- it is the MARKER that carries it, not a second encoding. }
procedure JsonRespellCodepoint(var B: TTxtBuf; ACp: LongWord);
begin
  if ACp < $80 then
    JsonRespellByte(B, ACp)
  else if ACp < $800 then
  begin
    JsonRespellByte(B, $C0 or (ACp shr 6));
    JsonRespellByte(B, $80 or (ACp and $3F));
  end
  else if ACp < $10000 then
  begin
    JsonRespellByte(B, $E0 or (ACp shr 12));
    JsonRespellByte(B, $80 or ((ACp shr 6) and $3F));
    JsonRespellByte(B, $80 or (ACp and $3F));
  end
  else
  begin
    JsonRespellByte(B, $F0 or (ACp shr 18));
    JsonRespellByte(B, $80 or ((ACp shr 12) and $3F));
    JsonRespellByte(B, $80 or ((ACp shr 6) and $3F));
    JsonRespellByte(B, $80 or (ACp and $3F));
  end;
end;

{ One string literal, from its opening delimiter at APos to just past the
  matching one. ADelim is that delimiter -- fpjson opens a string on '"' OR on a
  single quote (jsonscanner.pp:314; the single quote is refused only under
  joStrict, which is not set here), and a literal this does not rewrite is a
  literal the unmarker would walk without having written it. See the note above.

  It is always re-emitted with '"': byte $22 is spelled \" and byte $27 passes
  through raw, so a single-quoted literal converts cleanly and fpjson takes a
  "-literal everywhere it took the other.

  False means "this literal is not one I can re-spell faithfully" -- an escape
  the standard does not define, a short \u, a raw NUL (which fpjson refuses, and
  a rewrite must not make acceptable), or no closing delimiter -- and the caller
  then abandons the whole rewrite so fpjson sees the original bytes. }
function JsonRespellLiteral(const AText: String; var APos: Integer;
  var B: TTxtBuf; ADelim: Char): Boolean;
var
  i, hi, lo: Integer;
  c: Char;
begin
  Result := False;
  i := APos + 1;
  TxtAddByte(B, 34);
  while i <= Length(AText) do
  begin
    if B.Spent then Exit;
    c := AText[i];
    if c = ADelim then
    begin
      TxtAddByte(B, 34);
      APos := i + 1;
      Exit(True);
    end;
    if c <> '\' then
    begin
      // The one raw byte fpjson refuses inside a literal, measured over all of
      // 0..31 in both delimiters: give it back to fpjson to refuse.
      if c = #0 then Exit;
      JsonRespellByte(B, Ord(c));
      Inc(i);
      Continue;
    end;
    if i >= Length(AText) then Exit;
    case AText[i + 1] of
      '"':  begin JsonRespellByte(B, 34); Inc(i, 2); end;
      '''': begin JsonRespellByte(B, 39); Inc(i, 2); end;   // fpjson's own extension
      '\':  begin JsonRespellByte(B, 92); Inc(i, 2); end;
      '/':  begin JsonRespellByte(B, 47); Inc(i, 2); end;
      'b':  begin JsonRespellByte(B, 8);  Inc(i, 2); end;
      'f':  begin JsonRespellByte(B, 12); Inc(i, 2); end;
      'n':  begin JsonRespellByte(B, 10); Inc(i, 2); end;
      'r':  begin JsonRespellByte(B, 13); Inc(i, 2); end;
      't':  begin JsonRespellByte(B, 9);  Inc(i, 2); end;
      'u':
        begin
          if not JsonHex4(AText, i + 2, hi) then Exit;
          Inc(i, 6);
          if (hi >= $D800) and (hi <= $DBFF) and (i + 5 <= Length(AText)) and
             (AText[i] = '\') and (AText[i + 1] = 'u') and
             JsonHex4(AText, i + 2, lo) and (lo >= $DC00) and (lo <= $DFFF) then
          begin
            // A surrogate PAIR is one codepoint, and the four bytes it needs are
            // the case fpjson's ShortString could not hold when anything stood
            // next to it.
            JsonRespellCodepoint(B,
              $10000 + (LongWord(hi - $D800) shl 10) + LongWord(lo - $DC00));
            Inc(i, 6);
          end
          else if (hi >= $D800) and (hi <= $DFFF) then
            // A surrogate with no partner denotes no character and has no UTF-8
            // spelling. U+FFFD is what the standard's own guidance says to put
            // there; fpjson dropped it silently, which is the worse of the two.
            JsonRespellCodepoint(B, $FFFD)
          else
            JsonRespellCodepoint(B, LongWord(hi));
        end;
    else
      Exit;   // an escape fpjson will reject: let it do the rejecting
    end;
  end;
end;

{ Is there a \u escape inside a string at all? If not there is nothing fpjson
  gets wrong, and the document goes to it untouched. The delimiter is tracked --
  a literal opens on '"' or on a single quote and closes on the SAME one -- so an
  escape inside a single-quoted literal engages the rewrite too. It used not to,
  and that was the completeness half of the marker hole: 'a\u0000b' lost its NUL
  because no rewrite was ever started. }
function JsonHasUEscape(const AText: String): Boolean;
var
  i: Integer;
  delim: Char;
  esc: Boolean;
begin
  Result := False;
  delim := #0;                          // #0 = not inside a literal
  esc := False;
  for i := 1 to Length(AText) do
  begin
    if delim = #0 then
    begin
      if (AText[i] = '"') or (AText[i] = '''') then delim := AText[i];
      Continue;
    end;
    if esc then
    begin
      if (AText[i] = 'u') or (AText[i] = 'U') then Exit(True);
      esc := False;
    end
    else if AText[i] = '\' then esc := True
    else if AText[i] = delim then delim := #0;
  end;
end;

{ The whole document: every byte outside a string literal copied verbatim, every
  literal re-spelled -- BOTH delimiters, so no string token reaches the parser
  un-rewritten and the unmarker's scan is a statement about bytes this code
  wrote. False leaves AOut empty and means "use the original".

  ABudget separates the two reasons for False: the budget refused (the caller
  must return peLimit -- falling back to the original would answer a document
  fpjson reads wrongly) from "this document is not one I can re-spell" (the
  caller hands fpjson the original and lets it speak). }
function JsonRespellText(const AText: String; out AOut: String;
  out ABudget: Boolean): Boolean;
var
  b: TTxtBuf;
  i, runStart: Integer;
  delim: Char;
begin
  AOut := '';
  Result := False;
  ABudget := False;
  TxtInit(b, True);
  i := 1;
  runStart := 1;
  while i <= Length(AText) do
  begin
    if (AText[i] <> '"') and (AText[i] <> '''') then begin Inc(i); Continue; end;
    delim := AText[i];
    if i > runStart then TxtAdd(b, Copy(AText, runStart, i - runStart));
    if not JsonRespellLiteral(AText, i, b, delim) then
    begin
      ABudget := b.Spent;
      Exit;
    end;
    runStart := i;
  end;
  if Length(AText) >= runStart then
    TxtAdd(b, Copy(AText, runStart, Length(AText) - runStart + 1));
  if b.Spent then begin ABudget := True; Exit; end;
  AOut := TxtStr(b);
  Result := True;
end;

{ A marker is the only way byte $01 can appear in a string the rewrite PRODUCED,
  so its presence is the exact test for "this string needs undoing" -- and that
  is a claim about the rewrite being total over every literal, both delimiters,
  which is what JsonRespellText now is. It says nothing about a document that was
  not rewritten, and none is walked. }
function JsonHasMark(const S: String): Boolean;
var i: Integer;
begin
  Result := False;
  for i := 1 to Length(S) do
    if S[i] = #1 then Exit(True);
end;

function JsonUnmark(const S: String): String;
var
  b: TTxtBuf;
  i: Integer;
begin
  // Uncharged: see TTxtBuf. The text this undoes was charged on the way in, and
  // a refusal halfway through an undo would answer a corrupted string.
  TxtInit(b, False);
  i := 1;
  while i <= Length(S) do
  begin
    if (S[i] = #1) and (i < Length(S)) and (S[i + 1] in [#1, #2]) then
    begin
      if S[i + 1] = #1 then TxtAddByte(b, 0) else TxtAddByte(b, 1);
      Inc(i, 2);
      Continue;
    end;
    TxtAddByte(b, Ord(S[i]));
    Inc(i);
  end;
  Result := TxtStr(b);
end;

{ Undo the markers over the whole tree -- VALUES and member NAMES alike. A name
  is the case that needs work: fpjson keeps names in a hash and offers no rename,
  so an object holding a marked name is emptied with Extract (which does NOT free
  what it removes) and refilled in the same order under the corrected names.

  The recursion is bounded by MaxJsonDepth, which JsonNestsTooDeep has already
  enforced on this document before the parser was entered. }
procedure JsonUnmarkTree(N: TJSONData);
var
  i: Integer;
  o: TJSONObject;
  clean, marked: array of String;
  kids: array of TJSONData;
  rename: Boolean;
begin
  if N = nil then Exit;
  case N.JSONType of
    jtString:
      if JsonHasMark(TJSONString(N).AsString) then
        TJSONString(N).AsString := JsonUnmark(TJSONString(N).AsString);
    jtArray:
      for i := 0 to N.Count - 1 do JsonUnmarkTree(N.Items[i]);
    jtObject:
      begin
        o := TJSONObject(N);
        for i := 0 to o.Count - 1 do JsonUnmarkTree(o.Items[i]);
        rename := False;
        for i := 0 to o.Count - 1 do
          if JsonHasMark(o.Names[i]) then rename := True;
        if not rename then Exit;
        SetLength(clean, o.Count);
        SetLength(marked, o.Count);
        SetLength(kids, o.Count);
        for i := 0 to o.Count - 1 do
        begin
          marked[i] := o.Names[i];
          clean[i] := JsonUnmark(marked[i]);
          kids[i] := o.Items[i];
        end;
        for i := o.Count - 1 downto 0 do o.Extract(i);
        for i := 0 to High(clean) do
          // Add RAISES on a duplicate name -- it does not free the value, which
          // an earlier draft of this comment claimed: Add(String, TJSONData)
          // calls DoAdd(aName, AValue, False) (fpjson.pp:3743), and FreeOnError
          // False means DoError is reached with the node still ours. The parser
          // already rejects a duplicate member and the unmarking is injective,
          // so this branch cannot fire; it is kept because a raise inside a
          // library that returns its errors as values would escape as an
          // exception, and a collision keeping the name it arrived with is a
          // smaller wrong than that.
          if o.IndexOfName(clean[i]) >= 0 then o.Add(marked[i], kids[i])
          else o.Add(clean[i], kids[i]);
      end;
  end;
end;

{ The message to report when the text handed to GetJSON was the REWRITTEN one and
  it failed. fpjson counts "Pos n" in the text it was given, and a \u escape is
  six characters where the byte it denotes is one, so a position taken from the
  rewrite is a lie about what the caller wrote -- measured, a 35-character
  document whose real error sits at Pos 34 reported Pos 14. Parse the ORIGINAL
  again and report ITS error. Two parses, but only on the failure path.

  If the original parses where the rewrite did not, that is a defect in the
  rewrite and not an error in the caller's document: there is no honest position
  to report, so the rewritten text's own message stands. }
function JsonOriginalError(const AOriginal: String; ARespelled: Boolean;
  const AFallback: String): String;
var
  d: TJSONData;
begin
  Result := AFallback;
  if not ARespelled then Exit;
  d := nil;
  try
    d := GetJSON(AOriginal, False);
    d.Free();                           // Free is nil-safe; GetJSON may answer nil
  except
    on E: Exception do Result := E.Message;
  end;
end;

function t_json_parse(const Args: array of TValue; out Err: TPhosphorError): TValue;
var
  d: TJSONData;
  where, txt: String;
  pos: Int64;
  respelled, budget: Boolean;
begin
  Result := ValInt(0);
  // Before the parser is entered at all -- see the note above JsonNestsTooDeep.
  if JsonNestsTooDeep(Args[0].Str, MaxJsonDepth, pos) then
  begin
    Err := MakeError(peRuntime, Format(
      'invalid json: nests more than %d levels deep (at character %d)',
      [MaxJsonDepth, pos]));
    Exit;
  end;
  // The escapes fpjson decodes wrongly are decoded HERE first -- see the long
  // note above. Only a document that actually carries a \u escape is rewritten,
  // and only one this can rewrite faithfully; anything else goes to GetJSON as
  // the caller wrote it, byte for byte, so its own errors are still its own.
  txt := Args[0].Str;
  respelled := False;
  budget := False;
  if JsonHasUEscape(txt) then
  begin
    respelled := JsonRespellText(Args[0].Str, txt, budget);
    if budget then
    begin
      // The rewrite is charged (one unit per byte written, as BufAdd is) because
      // a raw $01 leaves as twelve characters. A refusal is a refusal: handing
      // the original to GetJSON instead would answer, quietly and wrongly, the
      // one class of document this whole rewrite exists to get right.
      Err := BudgetRefusal('json_parse@');
      Exit;
    end;
  end;
  if not respelled then txt := Args[0].Str;
  d := nil;
  try
    // UseUTF8 = FALSE, and the name is the opposite of what it does for us. True
    // asks the parser to DECODE the text through the platform's string type, which
    // on a system whose default code page is not set (Linux here, CP 0) turns the
    // UTF-8 pair C3 A9 into the single byte E9 -- measured. False passes the bytes
    // through untouched, which is byte-exact on BOTH platforms:
    //     Linux   GetJSON(t)        -> 63 61 66 E9        (4 bytes, lossy)
    //             GetJSON(t, False) -> 63 61 66 C3 A9
    //     Windows both               -> 63 61 66 C3 A9
    d := GetJSON(txt, False);
  except
    on E: Exception do
    begin
      // The position in that message counts characters of TXT. If txt is the
      // rewrite, that is not the caller's document -- see JsonOriginalError.
      Err := MakeError(peRuntime, 'invalid json: ' +
        JsonOriginalError(Args[0].Str, respelled, E.Message));
      Exit;
    end;
  end;
  if d = nil then
  begin
    // GetJSON returns nil (without raising) for empty/whitespace-only input. Report
    // it as an invalid-json error instead of wrapping a nil node in a live handle
    // that would fault the moment it is used.
    Err := MakeError(peRuntime, 'invalid json: empty or whitespace-only input');
    Exit;
  end;
  // The tree is not registered yet, so a refusal here frees it rather than
  // handing back a live handle onto a document that cannot be read or written.
  where := '';
  if FirstWildNumber(d, '', where) then
  begin
    d.Free();
    Err := MakeError(peRuntime, 'invalid json: ' + WildWhere(where) +
      ' is out of range');
    Exit;
  end;
  // The markers exist only between the rewrite and here, and only if there was
  // one: a document parsed as it was written carries none and is not walked.
  if respelled then JsonUnmarkTree(d);
  Err := NoError();
  Result := RegJson(d, True, 1);   // a freshly parsed document is its own root
end;

// --- object mutation --------------------------------------------------------
function t_json_setn(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  if not SetMember(o, JsonLevelOf(Args[0]), Args[1].Str,
                   NumNode(AsDouble(Args[2])), Err) then Exit;
  Result := Args[0];
end;
function t_json_sets(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  if not SetMember(o, JsonLevelOf(Args[0]), Args[1].Str,
                   TJSONString.Create(Args[2].Str), Err) then Exit;
  Result := Args[0];
end;
function t_json_setb(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  if not SetMember(o, JsonLevelOf(Args[0]), Args[1].Str,
                   TJSONBoolean.Create(AsDouble(Args[2]) <> 0), Err) then Exit;
  Result := Args[0];
end;
function t_json_remove(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject; idx: Integer;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  idx := o.IndexOfName(Args[1].Str);
  if idx >= 0 then
  begin
    InvalidateBorrowed(o.Items[idx]);
    o.Delete(idx);
  end;
  Result := Args[0];
end;

// --- object read ------------------------------------------------------------
function t_json_getn(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject; m: TJSONData;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  m := FindMember(o, Args[1].Str);
  if m <> nil then Result := NumVal(m)
  else if Length(Args) >= 3 then Result := Args[2];
end;
function t_json_gets(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject; m: TJSONData;
begin
  Result := ValStr('');
  if not GetObj(Args[0], o, Err) then Exit;
  m := FindMember(o, Args[1].Str);
  if m <> nil then Result := ValStr(StrVal(m))
  else if Length(Args) >= 3 then Result := Args[2];
end;
function t_json_getb(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject; m: TJSONData;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  m := FindMember(o, Args[1].Str);
  if (m <> nil) and (m.JSONType = jtBoolean) then Result := ValInt(Ord(m.AsBoolean));
end;
function t_json_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject; m: TJSONData;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  m := FindMember(o, Args[1].Str);
  if m = nil then
  begin
    Err := MakeError(peRuntime, 'no such json member');
    Exit;
  end;
  Result := RegJson(m, False, JsonLevelOf(Args[0]) + 1);   // borrowed from the parent tree
end;
function t_json_has(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  Result := ValInt(Ord(o.IndexOfName(Args[1].Str) >= 0));
end;
function t_json_count(const Args: array of TValue; out Err: TPhosphorError): TValue;
var n: TJSONData;
begin
  // object keys only -- an array (or a scalar) answers zero, not an error,
  // which reads exactly like an empty object. json_len counts an array.
  Result := ValInt(0);
  if not GetNode(Args[0], n, Err) then Exit;
  if n is TJSONObject then Result := ValInt(TJSONObject(n).Count);
end;

// --- array mutation and read ------------------------------------------------
function t_json_pushn(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TJSONArray;
begin
  Result := ValInt(0);
  if not GetArr(Args[0], a, Err) then Exit;
  if not AddItem(a, JsonLevelOf(Args[0]), NumNode(AsDouble(Args[1])), Err) then Exit;
  Result := Args[0];
end;
function t_json_pushs(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TJSONArray;
begin
  Result := ValInt(0);
  if not GetArr(Args[0], a, Err) then Exit;
  // Add(TJSONData), not Add(String). The String overload re-encodes a byte >= $80
  // on the way in -- measured: a five-byte value became seven -- while handing it
  // an explicitly built node stores exactly what it was given.
  if not AddItem(a, JsonLevelOf(Args[0]), TJSONString.Create(Args[1].Str), Err) then Exit;
  Result := Args[0];
end;
function t_json_len(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TJSONArray;
begin
  Result := ValInt(0);
  if not GetArr(Args[0], a, Err) then Exit;
  Result := ValInt(a.Count);
end;
// Array reads are 1-based. The 3-argument form answers a default for an index
// past the end; the 2-argument form treats that as an error.
function t_json_itemn(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TJSONArray; z: Integer;
begin
  Result := ValInt(0);
  if not GetArr(Args[0], a, Err) then Exit;
  z := ArgI32(Args[1]) - 1;
  if (z >= 0) and (z < a.Count) then Result := NumVal(a.Items[z])
  else if Length(Args) >= 3 then Result := Args[2]
  else Err := MakeError(peRuntime, Format('json array index %d out of bounds 1..%d',
    [z + 1, a.Count]));
end;
function t_json_items(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TJSONArray; z: Integer;
begin
  Result := ValStr('');
  if not GetArr(Args[0], a, Err) then Exit;
  z := ArgI32(Args[1]) - 1;
  if (z >= 0) and (z < a.Count) then Result := ValStr(StrVal(a.Items[z]))
  else if Length(Args) >= 3 then Result := Args[2]
  else Err := MakeError(peRuntime, Format('json array index %d out of bounds 1..%d',
    [z + 1, a.Count]));
end;

// --- type introspection -----------------------------------------------------
function t_json_isobj(const Args: array of TValue; out Err: TPhosphorError): TValue;
var n: TJSONData;
begin
  Result := ValInt(0);
  if not GetNode(Args[0], n, Err) then Exit;
  Result := ValInt(Ord(n.JSONType = jtObject));
end;
function t_json_isarr(const Args: array of TValue; out Err: TPhosphorError): TValue;
var n: TJSONData;
begin
  Result := ValInt(0);
  if not GetNode(Args[0], n, Err) then Exit;
  Result := ValInt(Ord(n.JSONType = jtArray));
end;
function t_json_typename(const Args: array of TValue; out Err: TPhosphorError): TValue;
var n: TJSONData; s: String;
begin
  Result := ValStr('');
  if not GetNode(Args[0], n, Err) then Exit;
  case n.JSONType of
    jtObject:  s := 'object';
    jtArray:   s := 'array';
    jtNumber:  s := 'number';
    jtString:  s := 'string';
    jtBoolean: s := 'boolean';
    jtNull:    s := 'null';
  else
    s := 'unknown';
  end;
  Result := ValStr(s);
end;

// --- dotted path ------------------------------------------------------------
function NavPath(Root: TJSONData; const Path: String; out Node: TJSONData): Boolean;
var start, i, plen: Integer; part: String; cur: TJSONData;
begin
  cur := Root;
  plen := Length(Path);
  start := 1;
  for i := 1 to plen + 1 do
    if (i > plen) or (Path[i] = '.') then
    begin
      part := Copy(Path, start, i - start);
      if not (cur is TJSONObject) then Exit(False);
      cur := TJSONObject(cur).Find(part);
      if cur = nil then Exit(False);
      start := i + 1;
    end;
  Node := cur;
  Result := True;
end;
function t_json_paths(const Args: array of TValue; out Err: TPhosphorError): TValue;
var root, n: TJSONData;
begin
  Result := ValStr('');
  if not GetNode(Args[0], root, Err) then Exit;
  if NavPath(root, Args[1].Str, n) then Result := ValStr(StrVal(n))
  else if Length(Args) >= 3 then Result := Args[2];
end;
function t_json_pathn(const Args: array of TValue; out Err: TPhosphorError): TValue;
var root, n: TJSONData;
begin
  Result := ValInt(0);
  if not GetNode(Args[0], root, Err) then Exit;
  if NavPath(root, Args[1].Str, n) then Result := NumVal(n)
  else if Length(Args) >= 3 then Result := Args[2];
end;

// --- serialize --------------------------------------------------------------
function t_json_stringify(const Args: array of TValue; out Err: TPhosphorError): TValue;
var n: TJSONData; txt: String;
begin
  Result := ValStr('');
  if not GetNode(Args[0], n, Err) then Exit;
  case JsonTextTry(n, False, 2, 0, txt) of
    jtrBudget: begin Err := BudgetRefusal('json_stringify$'); Exit(ValStr('')); end;
    jtrWild:   begin Err := WildRefusal('json_stringify$'); Exit(ValStr('')); end;
  end;
  Result := ValStr(txt);
end;

// --- scalar constructors (each scalar is a handle too) ----------------------
function t_json_null(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := RegJson(TJSONNull.Create(), True, 1); end;
function t_json_bool(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := RegJson(TJSONBoolean.Create(AsDouble(Args[0]) <> 0), True, 1); end;
function t_json_number(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := RegJson(NumNode(AsDouble(Args[0])), True, 1); end;
function t_json_string(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := RegJson(TJSONString.Create(Args[0].Str), True, 1); end;

// --- scalar readers ---------------------------------------------------------
function t_json_value(const Args: array of TValue; out Err: TPhosphorError): TValue;
var n: TJSONData;
begin
  Result := ValInt(0);
  if not GetNode(Args[0], n, Err) then Exit;
  // NumVal for every type. The old `else Result := ValDouble(n.AsFloat)` reached
  // AsFloat on a string, object or array, and EConvertError escaped the library:
  // json_value(json_string@("hello")) aborted the program with the RTL's own
  // "Invalid float value : hello". NumVal already reads a numeric string, answers
  // 0 for anything else, and cannot raise -- which is what a READER must do.
  Result := NumVal(n);
end;
function t_json_value_s(const Args: array of TValue; out Err: TPhosphorError): TValue;
var n: TJSONData;
begin
  Result := ValStr('');
  if GetNode(Args[0], n, Err) then Result := ValStr(StrVal(n));
end;

// --- type predicates and code -----------------------------------------------
function IsType(const V: TValue; T: TJSONtype; out Err: TPhosphorError): TValue;
var n: TJSONData;
begin
  Result := ValInt(0);
  if GetNode(V, n, Err) then Result := ValInt(Ord(n.JSONType = T));
end;
function t_json_isnull(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := IsType(Args[0], jtNull, Err); end;
function t_json_isbool(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := IsType(Args[0], jtBoolean, Err); end;
function t_json_isnum(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := IsType(Args[0], jtNumber, Err); end;
function t_json_isstr(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := IsType(Args[0], jtString, Err); end;
function t_json_type(const Args: array of TValue; out Err: TPhosphorError): TValue;
var n: TJSONData;
begin
  Result := ValInt(0);
  if GetNode(Args[0], n, Err) then Result := ValInt(Ord(n.JSONType));
end;

// --- object writes: null and a nested handle --------------------------------
function t_json_setnull(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  if not SetMember(o, JsonLevelOf(Args[0]), Args[1].Str,
                   TJSONNull.Create(), Err) then Exit;
  Result := Args[0];
end;
function t_json_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject; v: TJSONData;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  if not GetNode(Args[2], v, Err) then Exit;
  // clone: the object owns its own copy
  if not SetMember(o, JsonLevelOf(Args[0]), Args[1].Str, v.Clone, Err) then Exit;
  Result := Args[0];
end;

// --- array pushes: bool, null, a handle -------------------------------------
function t_json_pushb(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TJSONArray;
begin
  Result := ValInt(0);
  if not GetArr(Args[0], a, Err) then Exit;
  if not AddItem(a, JsonLevelOf(Args[0]), TJSONBoolean.Create(AsDouble(Args[1]) <> 0), Err) then Exit;
  Result := Args[0];
end;
function t_json_pushnull(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TJSONArray;
begin
  Result := ValInt(0);
  if not GetArr(Args[0], a, Err) then Exit;
  if not AddItem(a, JsonLevelOf(Args[0]), TJSONNull.Create(), Err) then Exit;
  Result := Args[0];
end;
function t_json_push(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TJSONArray; v: TJSONData;
begin
  Result := ValInt(0);
  if not GetArr(Args[0], a, Err) then Exit;
  if not GetNode(Args[1], v, Err) then Exit;
  if not AddItem(a, JsonLevelOf(Args[0]), v.Clone, Err) then Exit;
  Result := Args[0];
end;

// --- array reads: boolean, a handle, defaults -------------------------------
function t_json_itemb(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TJSONArray; z: Integer;
begin
  Result := ValInt(0);
  if not GetArr(Args[0], a, Err) then Exit;
  z := ArgI32(Args[1]) - 1;
  if (z >= 0) and (z < a.Count) and (a.Items[z].JSONType = jtBoolean) then
    Result := ValInt(Ord(a.Items[z].AsBoolean));
end;
function t_json_item(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TJSONArray; z: Integer;
begin
  Result := ValInt(0);
  if not GetArr(Args[0], a, Err) then Exit;
  z := ArgI32(Args[1]) - 1;
  if (z < 0) or (z >= a.Count) then
  begin
    Err := MakeError(peRuntime, 'json array index out of bounds');
    Exit;
  end;
  Result := RegJson(a.Items[z], False, JsonLevelOf(Args[0]) + 1);   // borrowed child
end;

// --- object removal by key, array by position and pop -----------------------
function t_json_removeat(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TJSONArray; z: Integer;
begin
  Result := ValInt(0);
  if not GetArr(Args[0], a, Err) then Exit;
  z := ArgI32(Args[1]) - 1;
  if (z >= 0) and (z < a.Count) then
  begin
    InvalidateBorrowed(a.Items[z]);
    a.Delete(z);
  end;
  Result := Args[0];
end;
function t_json_pop(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TJSONArray;
begin
  Result := ValInt(0);
  if not GetArr(Args[0], a, Err) then Exit;
  if a.Count > 0 then
  begin
    InvalidateBorrowed(a.Items[a.Count - 1]);
    a.Delete(a.Count - 1);
  end;
  Result := Args[0];
end;

// --- keys of an object as a fresh array -------------------------------------
function t_json_keys(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject; arr: TJSONArray; i: Integer;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  arr := TJSONArray.Create();
  // Add(TJSONData), like every other array store here. The plain-string overload
  // re-encoded each name, which happened to CANCEL the loss fpjson's name hash
  // introduces on a Windows code page -- and therefore produced the wrong answer
  // where the code page is UTF-8 and nothing was lost in the first place. Two bugs
  // agreeing on one platform is not a behaviour worth keeping.
  // a fresh array of plain strings: depth 2, which no ceiling can refuse
  for i := 0 to o.Count - 1 do arr.Add(TJSONString.Create(o.Names[i]));
  Result := RegJson(arr, True, 1);   // a new owned array, and its own root
end;

// --- paths: boolean, a handle -----------------------------------------------
function t_json_pathb(const Args: array of TValue; out Err: TPhosphorError): TValue;
var root, n: TJSONData;
begin
  Result := ValInt(0);
  if not GetNode(Args[0], root, Err) then Exit;
  if NavPath(root, Args[1].Str, n) and (n.JSONType = jtBoolean) then
    Result := ValInt(Ord(n.AsBoolean));
end;
function t_json_path(const Args: array of TValue; out Err: TPhosphorError): TValue;
var root, n: TJSONData;
begin
  Result := ValInt(0);
  if not GetNode(Args[0], root, Err) then Exit;
  if not NavPath(root, Args[1].Str, n) then
  begin
    Err := MakeError(peRuntime, 'no such json path');
    Exit;
  end;
  Result := RegJson(n, False, JsonLevelOf(Args[0]) + JsonPathSegments(Args[1].Str));   // borrowed
end;

// --- clone (deep) and merge -------------------------------------------------
function t_json_clone(const Args: array of TValue; out Err: TPhosphorError): TValue;
var n: TJSONData;
begin
  Result := ValInt(0);
  if not GetNode(Args[0], n, Err) then Exit;
  Result := RegJson(n.Clone, True, 1);   // a clone owns itself: a new root
end;
{ THE TWO TREES MUST BE DISJOINT, and this used to read freed memory when they
  were not.

  `s.Count` was evaluated once and `s` dereferenced on every turn. Merging an
  object into its own ancestor means one of the source's names collides with the
  target key that OWNS the source: SetMember finds that member, correctly empties
  every borrowed handle onto it, and then Delete FREES it -- which is the node `s`
  points at. `s` is a raw local that nothing updates, so the next turn read
  `s.Names[i]` out of a destroyed TJSONObject. InvalidateBorrowed exists to protect
  HANDLES; it cannot protect this library's own local.

  Measured: an object holding one member "b", itself an object with members "b",
  "c" and "d", merged with its own "b" -- an access violation, deterministically.
  The one-member spelling answered 0 and looked fine, because the loop ended
  before the bad read, which is how this stayed invisible.

  Snapshotting the pairs first would make it not crash, and would leave a defined
  result nobody asked for: the source flattened into the target as a side effect of
  destroying it. Overlapping trees have no merge that means anything, so both
  directions are refused as a value -- the source inside the target, the target
  inside the source, and the two being the same object. NodeContains, which the
  borrow machinery already uses, answers both questions. }
function t_json_merge(const Args: array of TValue; out Err: TPhosphorError): TValue;
var t, s: TJSONObject; i: Integer;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], t, Err) then Exit;
  if not GetObj(Args[1], s, Err) then Exit;
  if NodeContains(t, s) or NodeContains(s, t) then
  begin
    Err := MakeError(peRuntime,
      'json_merge@: the two values overlap -- one is inside the other, or they ' +
      'are the same value');
    Exit;
  end;
  for i := 0 to s.Count - 1 do
    if not SetMember(t, JsonLevelOf(Args[0]), s.Names[i], s.Items[i].Clone, Err) then Exit;
  Result := Args[0];
end;

// --- pretty rendering; a handle's id as a number ----------------------------
{ THE INDENT IS AN ARGUMENT, and JsonText multiplies it by the nesting level and
  hands the product to StringOfChar once per member. json_pretty$(h, 1000000000)
  on a two-level document is therefore a pair of two-gigabyte pads per member,
  built inside one opCall. The width is derivable here -- indent times depth is
  bounded by indent times the node count -- so RULE 1 applies, and a negative
  indent (which StringOfChar would refuse outright) is clamped the way every
  other count in this engine is. }
function t_json_pretty(const Args: array of TValue; out Err: TPhosphorError): TValue;
var n: TJSONData; ind: Integer; cnt, dep, pads, want: Int64; txt: String;
begin
  Result := ValStr('');
  if not GetNode(Args[0], n, Err) then Exit;
  ind := 2;
  if Length(Args) >= 2 then ind := ArgI32(Args[1]);
  if ind < 0 then ind := 0;
  cnt := 0; dep := 0;
  JsonShape(n, 1, cnt, dep);
  pads := cnt * dep;                         // one pad per node, none deeper than dep
  if pads <= 0 then want := 0
  else if ind > High(Int64) div pads then want := High(Int64)
  else want := Int64(ind) * pads;
  if not BudgetAllows(want) then
  begin
    Err := BudgetRefusal('json_pretty$');
    Exit;
  end;
  case JsonTextTry(n, True, ind, 0, txt) of
    jtrBudget: begin Err := BudgetRefusal('json_pretty$'); Exit(ValStr('')); end;
    jtrWild:   begin Err := WildRefusal('json_pretty$'); Exit(ValStr('')); end;
  end;
  Result := ValStr(txt);
end;
function t_pnttonum(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if Args[0].Kind = vkHandle then Result := ValInt(Args[0].Hnd) else Result := ValInt(0);
end;

// --- generic value insertion (for the JSON-literal codegen) -----------------
// The literal compiler evaluates each element to a plain value and calls these,
// which pick the JSON node kind from the value's runtime kind. Both RETURN the
// container handle, so it stays on the stack between insertions.
function ValueToNode(const V: TValue; out Err: TPhosphorError): TJSONData;
begin
  Err := NoError();
  case V.Kind of
    vkInt, vkDouble: Result := NumNode(AsDouble(V));
    vkString:        Result := TJSONString.Create(V.Str);
    vkBool:          Result := TJSONBoolean.Create(V.Bl);
    vkHandle:
      if IsHandle(V.Hnd) and (HandleObj(V.Hnd) is TPhosphorJson) then
        Result := TPhosphorJson(HandleObj(V.Hnd)).Node.Clone   // literal takes a copy
      else
      begin
        Err := MakeError(peRuntime, 'not a valid json handle in a literal');
        Result := nil;
      end;
  else
    Result := TJSONNull.Create();
  end;
end;
function t_json_pushval(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TJSONArray; node: TJSONData;
begin
  Result := ValInt(0);
  if not GetArr(Args[0], a, Err) then Exit;
  node := ValueToNode(Args[1], Err);
  if node = nil then Exit;
  if not AddItem(a, JsonLevelOf(Args[0]), node, Err) then Exit;
  Result := Args[0];
end;
function t_json_setval(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject; node: TJSONData;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  node := ValueToNode(Args[2], Err);
  if node = nil then Exit;
  if not SetMember(o, JsonLevelOf(Args[0]), Args[1].Str, node, Err) then Exit;
  Result := Args[0];
end;

procedure RegisterJsonFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('json_object@:',     @t_json_object);
  Reg.Add('json_array@:',      @t_json_array);
  Reg.Add('json_parse@:$',     @t_json_parse);
  Reg.Add('json_setn@:@$n',    @t_json_setn);
  Reg.Add('json_sets@:@$$',    @t_json_sets);
  Reg.Add('json_setb@:@$n',    @t_json_setb);
  Reg.Add('json_remove@:@$',   @t_json_remove);
  Reg.Add('json_getn:@$',      @t_json_getn);
  Reg.Add('json_getn:@$n',     @t_json_getn);
  Reg.Add('json_gets$:@$',     @t_json_gets);
  Reg.Add('json_gets$:@$$',    @t_json_gets);
  Reg.Add('json_getb:@$',      @t_json_getb);
  Reg.Add('json_get@:@$',      @t_json_get);
  Reg.Add('json_has:@$',       @t_json_has);
  Reg.Add('json_count:@',      @t_json_count);
  Reg.Add('json_pushn@:@n',    @t_json_pushn);
  Reg.Add('json_pushs@:@$',    @t_json_pushs);
  Reg.Add('json_len:@',        @t_json_len);
  Reg.Add('json_itemn:@n',     @t_json_itemn);
  Reg.Add('json_itemn:@nn',    @t_json_itemn);   // 3-arg: default past the end
  Reg.Add('json_items$:@n',    @t_json_items);
  Reg.Add('json_items$:@n$',   @t_json_items);
  Reg.Add('json_itemb:@n',     @t_json_itemb);
  Reg.Add('json_item@:@n',     @t_json_item);
  Reg.Add('json_removeat@:@n', @t_json_removeat);
  Reg.Add('json_pop@:@',       @t_json_pop);
  Reg.Add('json_isobj:@',      @t_json_isobj);
  Reg.Add('json_isarr:@',      @t_json_isarr);
  Reg.Add('json_isnull:@',     @t_json_isnull);
  Reg.Add('json_isbool:@',     @t_json_isbool);
  Reg.Add('json_isnum:@',      @t_json_isnum);
  Reg.Add('json_isstr:@',      @t_json_isstr);
  Reg.Add('json_type:@',       @t_json_type);
  Reg.Add('json_typename$:@',  @t_json_typename);
  Reg.Add('json_paths$:@$',    @t_json_paths);
  Reg.Add('json_paths$:@$$',   @t_json_paths);   // 3-arg: default when absent
  Reg.Add('json_pathn:@$',     @t_json_pathn);
  Reg.Add('json_pathn:@$n',    @t_json_pathn);
  Reg.Add('json_pathb:@$',     @t_json_pathb);
  Reg.Add('json_path@:@$',     @t_json_path);
  Reg.Add('json_stringify$:@', @t_json_stringify);
  Reg.Add('json_pretty$:@',    @t_json_pretty);
  Reg.Add('json_pretty$:@n',   @t_json_pretty);  // 2-arg: explicit indent
  // scalar constructors and readers
  Reg.Add('json_null@:',       @t_json_null);
  Reg.Add('json_bool@:n',      @t_json_bool);
  Reg.Add('json_number@:n',    @t_json_number);
  Reg.Add('json_string@:$',    @t_json_string);
  Reg.Add('json_value:@',      @t_json_value);
  Reg.Add('json_value$:@',     @t_json_value_s);
  // nested handles: set into an object, push into an array
  Reg.Add('json_setnull@:@$',  @t_json_setnull);
  Reg.Add('json_set@:@$@',     @t_json_set);
  Reg.Add('json_pushb@:@n',    @t_json_pushb);
  Reg.Add('json_pushnull@:@',  @t_json_pushnull);
  Reg.Add('json_push@:@@',     @t_json_push);
  // keys, clone, merge, and a handle's id
  Reg.Add('json_keys@:@',      @t_json_keys);
  Reg.Add('json_clone@:@',     @t_json_clone);
  Reg.Add('json_merge@:@@',    @t_json_merge);
  Reg.Add('pnttonum:@',        @t_pnttonum);
  // generic value insertion, one overload per value kind (JSON-literal codegen)
  Reg.Add('json_pushval@:@n',  @t_json_pushval);
  Reg.Add('json_pushval@:@$',  @t_json_pushval);
  Reg.Add('json_pushval@:@?',  @t_json_pushval);
  Reg.Add('json_pushval@:@@',  @t_json_pushval);
  Reg.Add('json_setval@:@$n',  @t_json_setval);
  Reg.Add('json_setval@:@$$',  @t_json_setval);
  Reg.Add('json_setval@:@$?',  @t_json_setval);
  Reg.Add('json_setval@:@$@',  @t_json_setval);
end;

end.
