{******************************************************************************
  probe_debug -- the name tables and the read-only state window

  A compiled program used to carry no variable names at all. The compiler had
  them and dropped them on the floor, so an embedder could run a script and then
  not say what a single one of its globals was called, and a `variables` request
  from any debugger was unimplementable on principle rather than by omission.

  This probe is the feature's own proof AND its demonstration: it compiles one
  fixture, prepares it, and prints every global and every live local BY NAME --
  which is exactly what an embedder dumping state after a Run wants, with no
  debugger, no seam, no socket and no protocol anywhere in it.

  What it pins, and why each one is here rather than assumed:

    * the global table is PARALLEL to the type table and the names are the
      script's own;
    * a compiler TEMPORARY interleaves with user globals in the index space, so
      no count can filter them -- the fixture puts one strictly between two user
      variables and the assertion reads the indices;
    * a temporary's name is one NO SCRIPT CAN WRITE. It used to be '__h<n>' and
      the lexer accepts '_' to start an identifier, so `__h0 = 42` and a SELECT in
      the same program shared one global and the script's value was overwritten.
      The fixture writes `__h0` and `__hello` and asserts both survive AND are
      reported as the script's, not as the compiler's;
    * a function's local names are rewritten when its body is parsed, not only
      when it is registered -- the FOR bound in `withfor` is a slot the body adds,
      and a table filled once would be short by it and say nothing;
    * StoppableLines is the set a breakpoint can be installed on, which is NOT the
      set of lines in the file: `rem`, `next`, `endfunction`, `endselect`, `case`
      and a blank line carry no boundary, `a = 1 : b = 2` carries two, and a
      function's header carries one that runs once at startup and never again;
    * and the set is ASCENDING AND DE-DUPLICATED whatever order the boundaries
      arrive in -- which no compiled fixture can test, because parse order is
      source order. A hand-built program, and the same program through the
      serializer, reach the sort the compiler never does;
    * a program either carries its names or says it does not. HasNames is False
      for anything loaded from a .pbc, and the cost of not asking -- the one real
      temporary reading as a user global -- is pinned rather than left to be met;
    * the prepared VM and program are read, never held: Run discards them;
    * the accessors answer from inside a live seam -- the frame depth, the
      function, and each local by name -- and answer for an index nobody has,
      because a host dumping state loops over counts and must not be able to take
      its own process down by asking;
    * a program read back from a .pbc carries no names, deliberately: the format
      is version 1 behind an exact-match refusal and is not being changed.

  Prints "ok: N" / "fail: M" and exits non-zero on any failure. Run with --fail to
  corrupt one expectation and confirm the check can fail.
******************************************************************************}
program probe_debug;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  Classes, SysUtils,
  PhosphorValue, PhosphorOpcodes, PhosphorCompiler,
  PhosphorBytecode, PhosphorEngine, PhosphorVM;

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

{ THE FIXTURE, and the line numbers are load-bearing: the StoppableLines
  expectation below is derived from this listing by hand, not from a run.

     1  rem a fixture whose every shape the dump has to get right
     2  total = 0
     3  __h0 = 6
     4  __hello = 5
     5  select case total
     6  case 0
     7    total = 1
     8  endselect
     9  after$ = "tail" : more% = 2
    10  end
    11  function plain(n) local acc, k
    12    acc = n * 2
    13    return acc
    14  endfunction
    15  function withfor(n) local acc, k
    16    acc = 0
    17    for k = 1 to n
    18      acc = acc + k
    19    next
    20    return acc
    21  endfunction
    22  function reports(n) local doubled
    23    doubled = n * 2
    24    println "in-frame"
    25    return doubled
    26  endfunction

  `end` on line 10 is the documented idiom: the top level stops there and the
  functions below it are called by the host. Nothing after line 10 runs on its
  own, which is what makes the frames below observable one call at a time. }
const
  Fixture =
    'rem a fixture whose every shape the dump has to get right' + #10 +
    'total = 0'                        + #10 +
    '__h0 = 6'                         + #10 +
    '__hello = 5'                      + #10 +
    'select case total'                + #10 +
    'case 0'                           + #10 +
    '  total = 1'                      + #10 +
    'endselect'                        + #10 +
    'after$ = "tail" : more% = 2'      + #10 +
    'end'                              + #10 +
    'function plain(n) local acc, k'   + #10 +
    '  acc = n * 2'                    + #10 +
    '  return acc'                     + #10 +
    'endfunction'                      + #10 +
    'function withfor(n) local acc, k' + #10 +
    '  acc = 0'                        + #10 +
    '  for k = 1 to n'                 + #10 +
    '    acc = acc + k'                + #10 +
    '  next'                           + #10 +
    '  return acc'                     + #10 +
    'endfunction'                      + #10 +
    'function reports(n) local doubled'+ #10 +
    '  doubled = n * 2'                + #10 +
    '  println "in-frame"'             + #10 +
    '  return doubled'                 + #10 +
    'endfunction'                      + #10;

{ DERIVED FROM THE LISTING ABOVE, ONE LINE AT A TIME, and not from any run:
    1  rem            -- no boundary
    2  total = 0                                            2
    3  __h0 = 6                                             3
    4  __hello = 5                                          4
    5  select case total                                    5
    6  case 0         -- a case label carries none
    7    total = 1                                          7
    8  endselect      -- a block terminator carries none
    9  after$ = ... : more% = 2  -- TWO boundaries, ONE line 9
   10  end                                                 10
   11  function plain -- a header: the jump over the body, excluded
   12    acc = n * 2                                       12
   13    return acc                                        13
   14  endfunction    -- none
   15  function withfor -- header, excluded
   16    acc = 0                                           16
   17    for k = 1 to n                                    17
   18      acc = acc + k                                   18
   19    next         -- none
   20    return acc                                        20
   21  endfunction    -- none
   22  function reports -- header, excluded
   23    doubled = n * 2                                   23
   24    println "in-frame"                                24
   25    return doubled                                    25
   26  endfunction    -- none }
  ExpectedStoppable: array[0..15] of Integer =
    (2, 3, 4, 5, 7, 9, 10, 12, 13, 16, 17, 18, 20, 23, 24, 25);

{ A host that looks at the VM from inside a seam the VM called it from. The
  `println` on line 24 fires this while `reports` is still on the frame stack --
  the one moment a local is live and a test can prove the window sees it. }
type
  TFrameWatcher = class
    Eng: TPhosphorEngine;
    Seen: Boolean;
    Depth: Integer;
    FuncName: String;
    LocalDump: String;
    Text: String;
    procedure Output(const AText: String);
  end;

procedure TFrameWatcher.Output(const AText: String);
var
  vm: TPhosphorVM;
  prog: TProgram;
  fi, slot: Integer;
begin
  Text := Text + AText;
  vm := Eng.PreparedVM;
  if vm = nil then Exit;
  if vm.DbgFrameDepth <= 0 then Exit;
  Seen := True;
  Depth := vm.DbgFrameDepth;
  prog := vm.DbgProgram;
  fi := vm.DbgFrameFunc(vm.DbgFrameDepth - 1);
  if (prog <> nil) and (fi >= 0) then
  begin
    FuncName := prog.UserFuncName(fi);
    LocalDump := '';
    for slot := 0 to vm.DbgFrameLocalCount(vm.DbgFrameDepth - 1) - 1 do
    begin
      if LocalDump <> '' then LocalDump := LocalDump + ' ';
      LocalDump := LocalDump + prog.LocalName(fi, slot) + '=' +
                   ValToStr(vm.DbgLocal(vm.DbgFrameDepth - 1, slot));
    end;
  end;
end;

function Compiled(const ASource: String): TProgram;
var comp: TPhosphorCompiler;
begin
  Result := nil;
  comp := TPhosphorCompiler.Create();
  try
    if not comp.Compile(ASource, Result) then
    begin
      Writeln(StdErr, 'fixture did not compile: ', comp.ErrorMessage,
              ' at line ', comp.ErrorLine);
      Result := nil;
    end;
  finally
    comp.Free;
  end;
end;

function FuncIndex(AProg: TProgram; const AName: String): Integer;
var i: Integer;
begin
  Result := -1;
  for i := 0 to AProg.UserFuncCount - 1 do
    if AProg.UserFuncs[i].Name = AName then Exit(i);
end;

function LinesToStr(const A: TPhosphorLines): String;
var i: Integer;
begin
  Result := '';
  for i := 0 to High(A) do
  begin
    if i > 0 then Result := Result + ',';
    Result := Result + IntToStr(A[i]);
  end;
end;

function ExpectedStoppableStr: String;
var i: Integer;
begin
  Result := '';
  for i := Low(ExpectedStoppable) to High(ExpectedStoppable) do
  begin
    if i > Low(ExpectedStoppable) then Result := Result + ',';
    Result := Result + IntToStr(ExpectedStoppable[i]);
  end;
  // --fail corrupts the EXPECTATION, not the engine: the comparison must notice.
  if ProveFail then Result := Result + ',99';
end;

{ ------------------------------------------------------------------------- }

{ THE GLOBAL TABLE. Every name the script wrote, in the order the compiler
  allocated them, with the SELECT subject sitting in the middle of them. }
procedure CheckGlobals(AProg: TProgram);
var
  i, iHello, iAfter, nTemp, tempIdx, named: Integer;
  dump: String;
begin
  { The name table is PRIVATE, so this asks the question through the read that
    decides rather than through a Length: a compiled program says it carries names,
    and every index the count admits answers one. Stronger than comparing two
    lengths, which a table of the right size full of '' would also satisfy. }
  Report(AProg.HasNames, 'a compiled program says it carries its names');
  named := 0;
  for i := 0 to AProg.VarCount - 1 do
    if AProg.GlobalName(i) <> '' then Inc(named);
  CheckInt(named, AProg.VarCount, 'every global the compiler declared has a name');

  dump := '';
  for i := 0 to AProg.VarCount - 1 do
  begin
    if dump <> '' then dump := dump + ' ';
    if AProg.GlobalIsTemporary(i) then dump := dump + '<temp>'
    else dump := dump + AProg.GlobalName(i);
  end;
  { Written out here so the assertion carries its own answer: the compiler
    allocates a global at the name's FIRST appearance, and the SELECT subject is
    allocated where the SELECT is compiled -- after __hello and before after$. }
  CheckStr(dump, 'total __h0 __hello <temp> after$ more%',
           'every global, in index order, with the temporary in its place');

  iHello := -1; iAfter := -1; nTemp := 0; tempIdx := -1;
  for i := 0 to AProg.VarCount - 1 do
  begin
    if AProg.GlobalName(i) = '__hello' then iHello := i;
    if AProg.GlobalName(i) = 'after$' then iAfter := i;
    if AProg.GlobalIsTemporary(i) then begin Inc(nTemp); tempIdx := i; end;
  end;
  CheckInt(nTemp, 1, 'the fixture has exactly one compiler temporary');
  { THE POINT OF THE FIXTURE. A filter built on a COUNT -- "the last n are
    hidden", "the first n are hidden" -- cannot be right, because the temporary is
    neither first nor last. It is strictly between two of the script's own. }
  Report((iHello >= 0) and (iAfter >= 0) and (tempIdx > iHello) and (tempIdx < iAfter),
         'the temporary sits BETWEEN two user globals, so no count can filter it');

  { A NAME SHAPED LIKE A TEMPORARY IS STILL THE SCRIPT'S. Both of these are legal
    identifiers -- PhosphorLexer.IsIdentStart accepts '_' -- and a filter that
    read them as the compiler's would hide a variable the user is looking for. }
  for i := 0 to AProg.VarCount - 1 do
    if (AProg.GlobalName(i) = '__h0') or (AProg.GlobalName(i) = '__hello') then
      Report(not AProg.GlobalIsTemporary(i),
             'a user global named ' + AProg.GlobalName(i) + ' is not a temporary');
end;

{ THE LOCAL TABLES. `plain` has only what its header declares; `withfor` has one
  more slot than its header declares, because the FOR bound is added while the
  body is parsed. Both must be named, and named in full. }
procedure CheckLocals(AProg: TProgram);
var
  i, slot, fi: Integer;
  dump: String;
begin
  for i := 0 to AProg.UserFuncCount - 1 do
    CheckInt(Length(AProg.UserFuncs[i].LocalNames),
             Length(AProg.UserFuncs[i].LocalTypes),
             'function "' + AProg.UserFuncs[i].Name +
             '": the local names are parallel to the local types');

  fi := FuncIndex(AProg, 'plain');
  dump := '';
  for slot := 0 to AProg.LocalCount(fi) - 1 do
  begin
    if dump <> '' then dump := dump + ' ';
    if AProg.LocalIsTemporary(fi, slot) then dump := dump + '<temp>'
    else dump := dump + AProg.LocalName(fi, slot);
  end;
  // Parameters first, then the `local` list -- the frame layout TUserFunc records.
  CheckStr(dump, 'n acc k', 'plain: three slots, all the header''s own');

  fi := FuncIndex(AProg, 'withfor');
  dump := '';
  for slot := 0 to AProg.LocalCount(fi) - 1 do
  begin
    if dump <> '' then dump := dump + ' ';
    if AProg.LocalIsTemporary(fi, slot) then dump := dump + '<temp>'
    else dump := dump + AProg.LocalName(fi, slot);
  end;
  { THE SLOT THE BODY ADDED. `withfor` declares the same three names as `plain`
    and has four slots: the FOR loop's bound is a temporary allocated while the
    body was being parsed, long after the function was registered. A name table
    written only at registration time is short by exactly this entry -- and short
    silently, which is why it is asserted by NAME and not by length alone. }
  CheckStr(dump, 'n acc k <temp>',
           'withfor: the FOR bound the body added is present and flagged');
end;

procedure CheckStoppable(AProg: TProgram);
begin
  { `rem`, `case`, `endselect`, `next` and `endfunction` carry no boundary; the
    two statements on line 9 carry one line between them; the three function
    headers carry a boundary that is the jump over the body. }
  CheckStr(LinesToStr(AProg.StoppableLines), ExpectedStoppableStr,
           'StoppableLines is the boundary set, de-duplicated, without the headers');
end;

{ THE ORDER THE BOUNDARIES ARRIVE IN, which the fixture above cannot reach.

  StoppableLines publishes two properties -- ascending, and without repeats -- and
  they are load-bearing TOGETHER: the de-duplication compares ADJACENT entries, so
  it is correct only on a sorted array. Nothing above tests the sorting half, and
  not because the fixture is small. Every program this COMPILER builds arrives
  sorted already: ParseStatement emits one boundary per statement in parse order
  and parse order is source order, measured over every .bas in this tree. Turn the
  sort into `Exit` and the fixture above cannot tell -- which makes it a routine
  indistinguishable from its broken version, a trap for whoever edits it next.

  A .pbc is the input that CAN arrive in any order. ReadProgram takes each
  instruction's Line straight from the file, and ValidateProgram bounds INDICES --
  constants, variables, jump targets, local slots -- and never Line, nor the order
  of anything. So this builds the shape by hand, the way probe_bytecode builds its
  own fixtures, asserts the answer, and then asserts it a SECOND time through the
  serializer: the first says the sort works, the second says the input it works on
  is one a real host can actually be handed. }
procedure CheckScrambledBoundaries;
const
  { Ten boundaries, deliberately unsorted, with 3, 10 and 25 each appearing twice
    and NEVER next to each other -- so a de-duplication running without the sort
    keeps both copies of all three and the two halves are tested together. }
  Raw: array[0..9] of Integer = (40, 10, 25, 10, 99, 3, 25, 7, 3, 80);
  { Derived from Raw by hand: its distinct values, ascending. Not read off a run. }
  Want = '3,7,10,25,40,80,99';
var
  p, back: TProgram;
  st: TBytesStream;
  err: String;
  i: Integer;
begin
  back := nil;
  p := TProgram.Create();
  try
    { A boundary and the statement it opens, the shape the compiler emits: opStmt
      carries the line and the pc its statement ends at. No user function is
      registered, so nothing here is excluded as a function header. }
    for i := Low(Raw) to High(Raw) do
    begin
      p.Emit(opStmt, p.Count + 2, 0, Raw[i]);
      p.Emit(opNop, 0, 0, Raw[i]);
    end;
    p.Emit(opHalt, 0, 0, Raw[High(Raw)]);

    CheckStr(LinesToStr(p.StoppableLines), Want,
             'StoppableLines is ascending and de-duplicated whatever order the ' +
             'boundaries arrive in');

    st := TBytesStream.Create();
    try
      WriteProgram(st, p);
      st.Position := 0;
      if not ReadProgram(st, back, err) then
      begin
        Report(False, 'out-of-order boundaries survive a .pbc round trip (' + err + ')');
        back := nil;
      end;
    finally
      st.Free;
    end;
    if back = nil then Exit;
    { THE REACHABILITY HALF. The loader accepted those lines in that order, so the
      sort is defending an input a host can be handed and not a hypothetical one. }
    CheckStr(LinesToStr(back.StoppableLines), Want,
             'a .pbc really can carry its boundaries out of order, and the loaded ' +
             'program still answers the set in order');
  finally
    back.Free;
    p.Free;
  end;
end;

{ THE TWO GUARDS INSIDE StoppableLines THAT NO COMPILED FIXTURE CAN REACH, and
  which nothing held until this procedure existed. They are the same class the
  sort above is in -- code only a hand-written or loaded .pbc can arrive at -- and
  the same argument applies: a routine indistinguishable from its broken version
  is a trap for whoever edits it next.

  GUARD ONE, THE opJump HALF OF THE FUNCTION-HEADER EXCLUSION. A function's header
  line carries a boundary whose code is the JUMP OVER THE BODY, executed once as
  the program steps past the definition and never when the function is called, so
  a breakpoint there fires at startup and looks broken. It is excluded by the
  TABLE -- the boundary two before each entry point -- and BOTH opcodes are
  checked: the boundary must be an opStmt and the instruction after it must be the
  jump. Everything the compiler emits satisfies both, so only a program built
  another way can tell the pair from the first half alone. Here the instruction
  before the entry is an opNop, so the pair does NOT match and line 40 must stay
  IN the set: a header exclusion that fired on the opStmt alone would silently
  drop a line a breakpoint belongs on.

  GUARD TWO, THE Line <= 0 FILTER. A .pbc carries each instruction's Line straight
  from the file and ValidateProgram never looks at it, so 0 and a negative are
  both arrivable. Neither is a line any editor can show, and a set containing one
  is a breakpoint a user can never reach. Lines 0 and -5 are here and neither may
  appear.

  Asserted twice, as the sort is: once on the program built by hand, and once
  through the serializer, so the second says the input really is one a host can be
  handed rather than one only this file can make. }
procedure CheckStoppableGuards;
const
  { Derived from the construction below, by hand:
      line 12 -- an ordinary boundary                                      kept
      line  0 -- a boundary with no line                                dropped
      line -5 -- a boundary with a negative line                        dropped
      line 40 -- the boundary two before `notafunc`'s entry, but the
                 instruction after it is an opNop and not the jump over a
                 body, so the header exclusion does not apply             kept
      line 44 -- the entry point's own first statement                    kept }
  Want = '12,40,44';
var
  p, back: TProgram;
  st: TBytesStream;
  err, wanted: String;
  entry: Integer;
begin
  back := nil;
  p := TProgram.Create();
  try
    p.Emit(opStmt, 0, 0, 12);       // 0: an ordinary boundary
    p.Emit(opNop, 0, 0, 12);        // 1
    p.Emit(opStmt, 0, 0, 0);        // 2: no line at all
    p.Emit(opNop, 0, 0, 0);         // 3
    p.Emit(opStmt, 0, 0, -5);       // 4: a negative line
    p.Emit(opNop, 0, 0, -5);        // 5
    p.Emit(opStmt, 0, 0, 40);       // 6: two before the entry -- but see 7
    p.Emit(opNop, 0, 0, 40);        // 7: an opNop, NOT the jump over a body
    p.Emit(opStmt, 0, 0, 44);       // 8: the entry point
    entry := 8;
    p.Emit(opHalt, 0, 0, 44);       // 9
    p.SetGlobalTableUnnamed([]);
    p.AddUserFunc('notafunc', entry, 0, [], [], vtNumber);

    { --fail corrupts the EXPECTATION here too, the way it does for the scrambled
      set: an assertion nobody has watched fail is not known to be able to. }
    wanted := Want;
    if ProveFail then wanted := wanted + ',99';
    CheckStr(LinesToStr(p.StoppableLines), wanted,
             'StoppableLines keeps a header-shaped boundary whose successor is ' +
             'not the jump over a body, and drops every line of 0 or less');

    st := TBytesStream.Create();
    try
      WriteProgram(st, p);
      st.Position := 0;
      if not ReadProgram(st, back, err) then
      begin
        Report(False, 'the guard fixture survives a .pbc round trip (' + err + ')');
        back := nil;
      end;
    finally
      st.Free;
    end;
    if back = nil then Exit;
    { THE REACHABILITY HALF. The loader accepted a boundary with no line and one
      with a negative line, so both guards are defending an input a host can be
      handed and not a hypothetical one. }
    CheckStr(LinesToStr(back.StoppableLines), wanted,
             'and a .pbc really can carry both shapes, with the loaded program ' +
             'answering the same set');
  finally
    back.Free;
    p.Free;
  end;
end;

{ WHAT THE PREPARED PAIR ANSWERS AFTER SOMETHING ELSE RAN. Run, RunBytecode and the
  next Prepare all open by calling Finish, which frees the prepared VM and the
  prepared program. A host that cached the program pointer is holding a freed
  object; the properties themselves answer nil. That is what the doc block over
  PreparedVM promises, and a promise in a comment is the one thing in this piece
  nothing could tell from its wrong version -- so it is asserted here. }
procedure CheckPreparationDiscarded;
var
  eng: TPhosphorEngine;
  rc: Integer;
begin
  eng := TPhosphorEngine.Create();
  try
    rc := eng.Prepare('first = 1' + #10 + 'end' + #10);
    if rc <> 0 then
    begin
      Report(False, 'the one-global fixture prepares (' + eng.ErrorMessage + ')');
      Exit;
    end;
    if eng.PreparedProgram = nil then
    begin
      Report(False, 'a prepared engine offers its program');
      Exit;
    end;
    CheckStr(eng.PreparedProgram.GlobalName(0), 'first',
             'the prepared program names its only global');
    rc := eng.Run('second = 2' + #10);
    CheckInt(rc, 0, 'an unrelated Run on the same engine succeeds');
    Report(eng.PreparedProgram = nil,
           'Run discarded the preparation: the program property answers nil');
    Report(eng.PreparedVM = nil,
           'Run discarded the preparation: the VM property answers nil');
  finally
    eng.Free;
  end;
end;

{ A .pbc CARRIES NO NAMES, ON PURPOSE. The format is version 1 behind an
  exact-match refusal (PhosphorBytecode), so adding a section would make this
  build refuse every file an earlier one wrote. What must hold is that asking is
  still SAFE and that everything not made of names survives. }
procedure CheckRoundTrip(AProg: TProgram);
var
  st: TBytesStream;
  back: TProgram;
  err: String;
  i, slot, named, nTemp: Integer;
begin
  st := TBytesStream.Create();
  try
    WriteProgram(st, AProg);
    st.Position := 0;
    if not ReadProgram(st, back, err) then
    begin
      Report(False, 'the fixture round-trips through .pbc (' + err + ')');
      Exit;
    end;
  finally
    st.Free;
  end;
  try
    named := 0;
    for i := 0 to back.VarCount - 1 do
      if back.GlobalName(i) <> '' then Inc(named);
    for i := 0 to back.UserFuncCount - 1 do
    begin
      CheckInt(Length(back.UserFuncs[i].LocalNames),
               Length(back.UserFuncs[i].LocalTypes),
               'loaded function "' + back.UserFuncs[i].Name +
               '": the name table is still parallel to the type table');
      for slot := 0 to back.LocalCount(i) - 1 do
        if back.LocalName(i, slot) <> '' then Inc(named);
    end;
    CheckInt(named, 0, 'a program loaded from a .pbc carries no names at all');

    { AND IT SAYS SO, which is the difference between a missing table and a table
      that looks like a program whose variables happen to have no names. }
    Report(not back.HasNames, 'a program loaded from a .pbc reports HasNames False');

    { WHAT THAT COSTS, PINNED HERE rather than left for a host to discover. The
      fixture has exactly one compiler temporary -- asserted above, strictly
      between two user globals -- and after the round trip the filter reports NONE,
      because there is no name to judge. Nothing is broken and nothing can be; the
      point is that a host looping over a loaded program without asking HasNames
      first shows the compiler's own SELECT subject as one of the script's
      variables and has no way to tell. This assertion is what makes that a
      documented answer instead of a surprise. }
    nTemp := 0;
    for i := 0 to back.VarCount - 1 do
      if back.GlobalIsTemporary(i) then Inc(nTemp);
    CheckInt(nTemp, 0,
             'with no names there is nothing to filter by: the temporary that IS ' +
             'there reads as a user global');

    { And the line set is a property of the INSTRUCTIONS, which do survive -- so
      the loaded program answers the same set. This is the expectation derived a
      second way: through the serializer rather than from the compiler. }
    CheckStr(LinesToStr(back.StoppableLines), ExpectedStoppableStr,
             'the loaded program reports the same stoppable lines');
  finally
    back.Free;
  end;
end;

{ THE WINDOW ITSELF: an embedder prepares a script and dumps its state by name,
  then calls a routine and looks at the live frame from inside a seam. }
procedure CheckPreparedState;
var
  eng: TPhosphorEngine;
  w: TFrameWatcher;
  prog: TProgram;
  vm: TPhosphorVM;
  rc, i: Integer;
  dump: String;
  v: TValue;
begin
  eng := TPhosphorEngine.Create();
  w := TFrameWatcher.Create();
  try
    w.Eng := eng;
    eng.OnOutput := @w.Output;
    rc := eng.Prepare(Fixture);
    if rc <> 0 then
    begin
      Report(False, 'the fixture prepares (' + eng.ErrorMessage + ')');
      Exit;
    end;
    Report(True, 'the fixture prepares');

    prog := eng.PreparedProgram;
    vm := eng.PreparedVM;
    Report((prog <> nil) and (vm <> nil), 'a prepared engine offers its VM and program');
    if (prog = nil) or (vm = nil) then Exit;

    { THE EMBEDDER'S DUMP, which is the whole point of the piece: name = value for
      every global the script wrote, after the top level has run. }
    dump := '';
    for i := 0 to vm.DbgGlobalCount - 1 do
    begin
      if prog.GlobalIsTemporary(i) then Continue;
      if dump <> '' then dump := dump + ' ';
      dump := dump + prog.GlobalName(i) + '=' + ValToStr(vm.DbgGlobal(i));
    end;
    { Derived from the fixture, not from a run: total is assigned 0 and then 1 by
      the SELECT arm, __h0 is 6 and __hello is 5 (and the SELECT must not have
      taken __h0 for itself), after$ is "tail" and more% is 2. }
    CheckStr(dump, 'total=1 __h0=6 __hello=5 after$=tail more%=2',
             'every global by name and value, after the top level ran');

    CheckInt(vm.DbgFrameDepth, 0, 'no frame is live between calls');

    { AN INDEX NOBODY HAS. A host loops over counts it read a moment ago; an
      accessor that faulted would take down a process that was only asking. }
    v := vm.DbgGlobal(-1);
    Report((v.Kind = vkDouble) and (v.Num = 0),
           'DbgGlobal(-1) answers a default, not a fault');
    v := vm.DbgGlobal(vm.DbgGlobalCount + 1000);
    Report((v.Kind = vkDouble) and (v.Num = 0),
           'DbgGlobal(past the end) answers a default, not a fault');
    v := vm.DbgLocal(0, 0);
    Report((v.Kind = vkDouble) and (v.Num = 0),
           'DbgLocal with no frame live answers a default');
    CheckInt(vm.DbgFrameFunc(0), -1, 'DbgFrameFunc with no frame live answers -1');
    CheckInt(vm.DbgFrameLocalCount(5), 0, 'DbgFrameLocalCount past the end answers 0');
    CheckStr(prog.GlobalName(-1), '', 'GlobalName(-1) answers an empty name');
    CheckStr(prog.LocalName(999, 0), '', 'LocalName of a function that is not there');
    CheckStr(prog.UserFuncName(-1), '', 'UserFuncName(-1) answers an empty name');

    { AND THE LIVE FRAME. `reports` prints on its line 24, which calls OnOutput
      while its activation is still on the stack. }
    { 21 * 2. Asserted through the engine's own renderer rather than on a Kind:
      whether a numeric slot holds the product as an exact Int64 or as a Double is
      the value model's business and not this probe's, and ValToStr is what a host
      would show either way. }
    v := eng.CallFunction('reports', [ValInt(21)]);
    CheckStr(ValToStr(v), '42', 'reports(21) answers 42');
    Report(w.Seen, 'the seam saw a live frame');
    CheckInt(w.Depth, 1, 'one activation was live inside the call');
    CheckStr(w.FuncName, 'reports', 'the live frame names the function it runs');
    CheckStr(w.LocalDump, 'n=21 doubled=42',
             'every local of the live frame, by name and value');
    CheckInt(vm.DbgFrameDepth, 0, 'the frame is gone once the call returned');
  finally
    eng.Free;
    w.Free;
  end;
end;

var
  prog: TProgram;
begin
  ProveFail := (ParamCount >= 1) and (ParamStr(1) = '--fail');

  prog := Compiled(Fixture);
  if prog = nil then
  begin
    Writeln('ok: 0');
    Writeln('fail: 1');
    Halt(1);
  end;
  try
    CheckGlobals(prog);
    CheckLocals(prog);
    CheckStoppable(prog);
    CheckRoundTrip(prog);
  finally
    prog.Free;
  end;
  CheckScrambledBoundaries();
  CheckStoppableGuards();
  CheckPreparedState();
  CheckPreparationDiscarded();

  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed > 0 then Halt(1) else Halt(0);
end.
