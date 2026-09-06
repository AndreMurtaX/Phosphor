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
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles;

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
function JsonRegisterNode(ANode: TJSONData; AOwns: Boolean): Int64;
function JsonNodeFromHandle(AHandleId: Int64; out ANode: TJSONData): Boolean;

implementation

type
  { Wraps one fpjson node. Owns=True for a root built or parsed here; Owns=False
    for a child handed out by json_get@ (its node belongs to the parent tree). }
  TPhosphorJson = class
    Node: TJSONData;
    Owns: Boolean;
    destructor Destroy; override;
  end;

destructor TPhosphorJson.Destroy;
begin
  if Owns and (Node <> nil) then Node.Free;
  inherited Destroy();
end;

function JsonRegisterNode(ANode: TJSONData; AOwns: Boolean): Int64;
var w: TPhosphorJson;
begin
  w := TPhosphorJson.Create();
  w.Node := ANode;
  w.Owns := AOwns;
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

function RegJson(N: TJSONData; AOwns: Boolean): TValue;
begin
  Result := ValHandle(JsonRegisterNode(N, AOwns));
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

function NumNode(d: Double): TJSONData;
begin
  if (Frac(d) = 0) and (Abs(d) < 9.2e18) then Result := TJSONIntegerNumber.Create(Round(d))
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

procedure InvalidateBorrowed(ANode: TJSONData);
var
  i: Int64;
  o: TObject;
  w: TPhosphorJson;
begin
  if ANode = nil then Exit;
  for i := 1 to HandleCount do
  begin
    o := HandleAt(i);
    if not (o is TPhosphorJson) then Continue;
    w := TPhosphorJson(o);
    if (not w.Owns) and NodeContains(ANode, w.Node) then
      w.Node := nil;
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

procedure SetMember(O: TJSONObject; const K: String; V: TJSONData);
var idx: Integer;
begin
  idx := O.IndexOfName(K);
  if idx >= 0 then
  begin
    InvalidateBorrowed(O.Items[idx]);
    O.Delete(idx);
  end;
  O.Add(K, V);
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
    Result := Result + Copy(S, runStart, Length(S) - runStart + 1);
end;

function JsonText(N: TJSONData; APretty: Boolean; AIndent, ALevel: Integer): String;
var
  i: Integer;
  pad, padIn, sep: String;
  o: TJSONObject;
  a: TJSONArray;
begin
  if N = nil then Exit('null');
  case N.JSONType of
    jtString:
      Result := '"' + JsonEscape(TJSONString(N).AsString) + '"';
    jtObject:
      begin
        o := TJSONObject(N);
        if o.Count = 0 then Exit('{}');            // inline, in both modes
        if APretty then
        begin
          pad := StringOfChar(' ', AIndent * (ALevel + 1));
          padIn := StringOfChar(' ', AIndent * ALevel);
          Result := '{' + #10;
          sep := '';
          for i := 0 to o.Count - 1 do
          begin
            Result := Result + sep + pad + '"' + JsonEscape(o.Names[i]) + '" : ' +
                      JsonText(o.Items[i], True, AIndent, ALevel + 1);
            sep := ',' + #10;
          end;
          Result := Result + #10 + padIn + '}';
        end
        else
        begin
          // COMPACT, the word the reference uses. It used to emit '{ ', ' : ' and
          // ' }', while the array branch below was already compact -- so objects
          // were the inconsistency, not the format. json_pretty$ is the readable
          // rendering; this one is the one that goes over a wire.
          Result := '{';
          for i := 0 to o.Count - 1 do
          begin
            if i > 0 then Result := Result + ',';
            Result := Result + '"' + JsonEscape(o.Names[i]) + '":' +
                      JsonText(o.Items[i], False, AIndent, 0);
          end;
          Result := Result + '}';
        end;
      end;
    jtArray:
      begin
        a := TJSONArray(N);
        if APretty then
        begin
          padIn := StringOfChar(' ', AIndent * ALevel);
          if a.Count = 0 then Exit('[' + #10 + padIn + ']');
          pad := StringOfChar(' ', AIndent * (ALevel + 1));
          Result := '[' + #10;
          sep := '';
          for i := 0 to a.Count - 1 do
          begin
            Result := Result + sep + pad + JsonText(a.Items[i], True, AIndent, ALevel + 1);
            sep := ',' + #10;
          end;
          Result := Result + #10 + padIn + ']';
        end
        else
        begin
          if a.Count = 0 then Exit('[]');
          Result := '[';
          for i := 0 to a.Count - 1 do
          begin
            if i > 0 then Result := Result + ', ';
            Result := Result + JsonText(a.Items[i], False, AIndent, 0);
          end;
          Result := Result + ']';
        end;
      end;
  else
    // numbers, booleans, null: ASCII, so fpjson's own rendering is safe here and
    // keeps the output identical to what it has always been.
    Result := N.AsJSON;
  end;
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
begin Err := NoError(); Result := RegJson(TJSONObject.Create(), True); end;

function t_json_array(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := RegJson(TJSONArray.Create(), True); end;

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
  serializer emits: .NET's JSON reader stops at 64. }
const
  MaxJsonDepth = 256;

{ True when AText nests deeper than ALimit, with APos set to the character that
  crossed it. Brackets inside a string literal are text, not structure, so the
  scan tracks string state and its backslash escapes; unbalanced closers are left
  to the parser, which reports them far better than a depth scan could. Only
  nesting counts, so a long FLAT document -- 100k sibling elements -- is
  unaffected however long it gets, exactly as a long non-nested expression is. }
function JsonNestsTooDeep(const AText: String; ALimit: Integer;
  out APos: Int64): Boolean;
var
  i, depth: Int64;
  inStr, esc: Boolean;
begin
  APos := 0;
  depth := 0;
  inStr := False;
  esc := False;
  for i := 1 to Length(AText) do
  begin
    if inStr then
    begin
      if esc then esc := False
      else if AText[i] = '\' then esc := True
      else if AText[i] = '"' then inStr := False;
      Continue;
    end;
    case AText[i] of
      '"': inStr := True;
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

function t_json_parse(const Args: array of TValue; out Err: TPhosphorError): TValue;
var
  d: TJSONData;
  pos: Int64;
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
    d := GetJSON(Args[0].Str, False);
  except
    on E: Exception do
    begin
      Err := MakeError(peRuntime, 'invalid json: ' + E.Message);
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
  Err := NoError();
  Result := RegJson(d, True);
end;

// --- object mutation --------------------------------------------------------
function t_json_setn(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  SetMember(o, Args[1].Str, NumNode(AsDouble(Args[2])));
  Result := Args[0];
end;
function t_json_sets(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  SetMember(o, Args[1].Str, TJSONString.Create(Args[2].Str));
  Result := Args[0];
end;
function t_json_setb(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  SetMember(o, Args[1].Str, TJSONBoolean.Create(AsDouble(Args[2]) <> 0));
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
  Result := RegJson(m, False);   // borrowed: belongs to the parent tree
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
  a.Add(NumNode(AsDouble(Args[1])));
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
  a.Add(TJSONString.Create(Args[1].Str));
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
var n: TJSONData;
begin
  Result := ValStr('');
  if not GetNode(Args[0], n, Err) then Exit;
  Result := ValStr(JsonText(n, False, 2, 0));
end;

// --- scalar constructors (each scalar is a handle too) ----------------------
function t_json_null(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := RegJson(TJSONNull.Create(), True); end;
function t_json_bool(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := RegJson(TJSONBoolean.Create(AsDouble(Args[0]) <> 0), True); end;
function t_json_number(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := RegJson(NumNode(AsDouble(Args[0])), True); end;
function t_json_string(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := RegJson(TJSONString.Create(Args[0].Str), True); end;

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
  SetMember(o, Args[1].Str, TJSONNull.Create());
  Result := Args[0];
end;
function t_json_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject; v: TJSONData;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  if not GetNode(Args[2], v, Err) then Exit;
  SetMember(o, Args[1].Str, v.Clone);   // clone: the object owns its own copy
  Result := Args[0];
end;

// --- array pushes: bool, null, a handle -------------------------------------
function t_json_pushb(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TJSONArray;
begin
  Result := ValInt(0);
  if not GetArr(Args[0], a, Err) then Exit;
  a.Add(TJSONBoolean.Create(AsDouble(Args[1]) <> 0));
  Result := Args[0];
end;
function t_json_pushnull(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TJSONArray;
begin
  Result := ValInt(0);
  if not GetArr(Args[0], a, Err) then Exit;
  a.Add(TJSONNull.Create());
  Result := Args[0];
end;
function t_json_push(const Args: array of TValue; out Err: TPhosphorError): TValue;
var a: TJSONArray; v: TJSONData;
begin
  Result := ValInt(0);
  if not GetArr(Args[0], a, Err) then Exit;
  if not GetNode(Args[1], v, Err) then Exit;
  a.Add(v.Clone);
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
  Result := RegJson(a.Items[z], False);   // borrowed child
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
  for i := 0 to o.Count - 1 do arr.Add(TJSONString.Create(o.Names[i]));
  Result := RegJson(arr, True);   // a new owned array
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
  Result := RegJson(n, False);   // borrowed
end;

// --- clone (deep) and merge -------------------------------------------------
function t_json_clone(const Args: array of TValue; out Err: TPhosphorError): TValue;
var n: TJSONData;
begin
  Result := ValInt(0);
  if not GetNode(Args[0], n, Err) then Exit;
  Result := RegJson(n.Clone, True);
end;
function t_json_merge(const Args: array of TValue; out Err: TPhosphorError): TValue;
var t, s: TJSONObject; i: Integer;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], t, Err) then Exit;
  if not GetObj(Args[1], s, Err) then Exit;
  for i := 0 to s.Count - 1 do
    SetMember(t, s.Names[i], s.Items[i].Clone);
  Result := Args[0];
end;

// --- pretty rendering; a handle's id as a number ----------------------------
function t_json_pretty(const Args: array of TValue; out Err: TPhosphorError): TValue;
var n: TJSONData;
begin
  Result := ValStr('');
  if not GetNode(Args[0], n, Err) then Exit;
  if Length(Args) >= 2 then
    Result := ValStr(JsonText(n, True, ArgI32(Args[1]), 0))
  else
    Result := ValStr(JsonText(n, True, 2, 0));
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
  a.Add(node);
  Result := Args[0];
end;
function t_json_setval(const Args: array of TValue; out Err: TPhosphorError): TValue;
var o: TJSONObject; node: TJSONData;
begin
  Result := ValInt(0);
  if not GetObj(Args[0], o, Err) then Exit;
  node := ValueToNode(Args[2], Err);
  if node = nil then Exit;
  SetMember(o, Args[1].Str, node);
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
