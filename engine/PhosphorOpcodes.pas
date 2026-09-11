{******************************************************************************
  Phosphor BASIC -- opcodes, instruction record, constant pool, program

  MIT License. Copyright (c) 2026 Andre Murta.

  Bytecode discipline frozen now (decisions.md, "On-disk bytecode"), long before
  the on-disk packer exists:

    * Opcodes carry EXPLICIT numbers, assigned by APPEND only, never reordered.
      A later .pbc on disk would otherwise execute the wrong opcode silently.
      VerifyOpcodeNumbering() asserts the numbering and is called at startup, so
      a reorder fails loudly instead of quietly.
    * TInstr separates STORED fields (serialize straight to disk) from DERIVED
      ones (recomputed on load). Today every field is stored; the call target is
      resolved at run time through the registry (the analogue of the reference's
      recomputed `proc`), so nothing derived needs storing yet.
    * The constant pool is an explicit, indexable structure (the `A` field is an
      index into it).
******************************************************************************}
unit PhosphorOpcodes;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, PhosphorValue;

type
  { Append only. The literal after each name IS the on-disk opcode number. }
  TOpcode = (
    opNop      = 0,
    opPushConst= 1,   // A = constant-pool index -> push that value
    opPop      = 2,   // discard the top of stack (an expression statement's result)
    opCall     = 3,   // A = const index of the name string, B = argument count
    opPrint    = 4,   // pop 1, emit its text (no newline)
    opPrintLn  = 5,   // pop 1, emit its text + LF
    opNeg      = 6,   // unary minus
    opAdd      = 7,
    opSub      = 8,
    opMul      = 9,
    opDivReal  = 10,  // /
    opDivInt   = 11,  // \
    opPow      = 12,  // ^
    opMod      = 13,
    opEQ       = 14,
    opNE       = 15,
    opLT       = 16,
    opLE       = 17,
    opGT       = 18,
    opGE       = 19,
    opLoadVar  = 20,  // A = variable index -> push its value
    opStoreVar = 21,  // A = variable index -> pop and store (type-checked)
    opJumpIfFalse = 22, // pop a bool; if false, jump to A
    opAnd      = 23,
    opOr       = 24,
    opNot      = 25,
    opJump     = 26,  // unconditional jump to A
    opHalt     = 27,  // stop execution (END)
    opGosub    = 28,  // push the return address (next instr), jump to A
    opReturn   = 29,  // pop the return address, jump there
    opLoadLocal  = 30, // A = local slot -> push current frame's local
    opStoreLocal = 31, // A = local slot -> pop and store into current frame
    opRetFunc    = 32, // return from a user function (value already on the stack)
    opReadData   = 33, // push the next DATA item, advance the data pointer
    opRestore    = 34, // reset the data pointer to the first item
    opDup2       = 35, // duplicate the top two stack values (for a@[i] op= x)
    opStmt       = 36, // marks a statement boundary (records a clean resume point)
    opSetErrHandler = 37, // A = handler pc, or -1 to disable (on error goto 0)
    opResume     = 38, // A = 0 retry the failing statement, 1 continue at the next
    opDupN       = 39, // duplicate the top A stack values (for a@[i,j,..] op= x)
    opTrace      = 40, // pop 1 value; VM's trace flag := (value <> 0)
    opBreakpoint = 41, // A = operand count; pop A operand values + the message,
                       //   report-and-continue (never blocks; see PhosphorVM)
    // --- classic console input (INPUT / LINE INPUT / INPUT$) -----------------
    opInputLine  = 42, // read one console line into the input buffer (via OnInput)
    opInputField = 43, // A = type code (0 num,1 str,2 int,3 bool): next comma-field
                       //   of the input buffer, coerced -> push
    opInputAll   = 44, // push the whole remaining input-buffer line as a string
    opInputChars = 45, // pop count; read that many console characters -> push string
    // --- classic file I/O over #-numbered channels ---------------------------
    opOpenFile   = 46, // A = mode (0 input,1 output,2 append); pop channel#, pop path$
    opCloseFile  = 47, // A: 0 = pop channel# and close it; 1 = close every channel
    opPrintFile  = 48, // pop value, pop channel#: write the value's text to the file
    opFileField  = 49, // A = type code; pop channel#: next field of the file -> push
    opFileLine   = 50, // pop channel#: next whole line of the file -> push string
    opFileChars  = 51, // pop count, pop channel#: read that many chars -> push string
    opEofFile    = 52, // pop channel#: push true if the read cursor is at/after end
    opLofFile    = 53, // pop channel#: push the file length in bytes (int)
    opLocFile    = 54, // pop channel#: push the 1-based read/write cursor (int)
    // --- formatted output ----------------------------------------------------
    opPrintUsing = 55, // A = value count; pop A values + the format$: emit formatted
    opSeekFile   = 56  // pop position (1-based), pop channel#: move the file cursor
  );

  { STORED: Op, A, B, Line. DERIVED: none yet (the call target is resolved
    through the registry at run time, not stored). }
  TInstr = record
    Op: TOpcode;
    A: Integer;
    B: Integer;
    Line: Integer;  // 1-based source line, for error reporting
  end;

  TConstPool = class
  private
    FItems: array of TValue;
    FCount: Integer;
  public
    function Add(const V: TValue): Integer;
    function Get(Index: Integer): TValue;
    property Count: Integer read FCount;
  end;

  { A user-defined function. Locals are the frame slots: parameters first
    (ParamCount of them), then declared locals. RetType is from the name suffix.

    LocalNames is PARALLEL TO LocalTypes BY CONSTRUCTION -- the two doors that
    write the table, AddUserFunc and SetUserFuncLocals, size the names to the
    types and can do nothing else. It is not serialized (see PhosphorBytecode),
    so a program read back from a .pbc carries empty names; ask LocalName, which
    is the one read that decides, rather than indexing this directly. }
  TUserFunc = record
    Name: String;
    Entry: Integer;
    ParamCount: Integer;
    LocalTypes: array of TVarType;
    LocalNames: array of String;
    RetType: TVarType;
  end;

  { The lines of a program a statement boundary actually lands on. Declared here
    rather than borrowed from the RTL's Types unit on purpose: Types pulls in
    Windows on a 64-bit Windows build, and the engine is dependency-free. }
  TPhosphorLines = array of Integer;

  TProgram = class
  private
    { The name of each global, by the same index as VarTypes -- what an embedder
      dumping state, or a debugger's variables pane, has to have and what the
      compiler used to throw away.

      PRIVATE, and that is the mechanism rather than the tidiness. This started as
      a public field whose comment asked callers to fill it beside VarTypes and to
      read it through GlobalName; both halves of that are rules a reader keeps, and
      nothing could tell when one was not kept. Private to this unit means the two
      doors below are the only way a name gets IN, and GlobalName is the only way
      one comes OUT. }
    FVarNames: array of String;
    FHasNames: Boolean;
    FInstrs: array of TInstr;
    FCount: Integer;
  public
    Consts: TConstPool;
    { The global table. VarTypes stays a public field because the VM reads it on
      the hot store path and an embedder reads it too -- but it is WRITTEN through
      SetGlobalTable or SetGlobalTableUnnamed, which are the only routines that can
      reach the names beside it. A writer that fills this field directly gets a
      program whose HasNames is False: the names are then absent and SAY they are
      absent, which is the safe half of the failure rather than a table of blanks
      that reads like a program whose variables have no names. }
    VarCount: Integer;              // number of distinct global variables
    VarTypes: array of TVarType;    // declared type of each global (by index)
    UserFuncs: array of TUserFunc;
    UserFuncCount: Integer;
    DataPool: array of TValue;      // DATA items, in source order
    DataCount: Integer;
    constructor Create;
    destructor Destroy; override;
    function Emit(Op: TOpcode; A, B, Line: Integer): Integer;
    procedure Patch(Index, NewA: Integer);   // set A of an already-emitted instr
    function Instr(Index: Integer): TInstr;
    { ALocalNames is REQUIRED, not defaulted. A default of [] is the unsafe value
      here -- it is what a caller who simply forgot would pass -- and a table that
      lost its names silently is the defect this whole surface exists to close.
      A caller with no names to give says so by passing [] in writing. }
    function AddUserFunc(const AName: String; AEntry, AParamCount: Integer;
                         const ALocalTypes: array of TVarType;
                         const ALocalNames: array of String; ARetType: TVarType): Integer;
    function FindUserFunc(const AName: String; AArgCount: Integer): Integer;
    { Replace a function's local table. The compiler registers a function BEFORE
      parsing its body -- recursion needs the name to exist -- and the body can add
      locals the table did not have (a FOR bound is one). The NAMES travel through
      the same door as the types for exactly that reason: populated only at
      AddUserFunc time they would be short by every slot the body added, and
      nothing would say so. }
    procedure SetUserFuncLocals(AIndex: Integer; const ALocalTypes: array of TVarType;
                                const ALocalNames: array of String);
    { THE TWO DOORS ONTO THE GLOBAL TABLE, and there are two of them so that a
      caller filling the types cannot say NOTHING about the names. Each sizes the
      names to the types and sets VarCount from the same length, so no two of the
      three can disagree; neither has a default, because the omission this whole
      surface exists to close is exactly the one a default would hide.

      SetGlobalTable is the compiler's door: the types and the names together.
      HasNames answers True afterwards even for a program with no globals at all --
      its functions' locals are still named, and the flag is about the program.

      SetGlobalTableUnnamed is the loader's, and its verb IS the point. A .pbc does
      not carry names (the format is version 1 behind an exact-match refusal and is
      not being changed), so the answer with no names in it has to be asked for by
      name rather than arrived at by leaving an argument out. }
    procedure SetGlobalTable(const ATypes: array of TVarType;
                             const ANames: array of String);
    procedure SetGlobalTableUnnamed(const ATypes: array of TVarType);
    procedure AddData(const V: TValue);
    { READ-ONLY NAME LOOKUP -- the read that decides, so nothing else indexes the
      name tables. Every one of these answers for an index out of range instead of
      faulting: a host dumping state loops over counts it read a moment ago, and a
      program loaded from a .pbc has VarCount globals and no names at all. }
    function GlobalName(AIndex: Integer): String;
    function LocalName(AFuncIndex, ASlot: Integer): String;
    { The name of a user function by its index -- what DbgFrameFunc answers with.
      Here for the same reason as the two above: a caller handed an index should
      never have to reach into UserFuncs itself to turn it into a name. }
    function UserFuncName(AFuncIndex: Integer): String;
    { True when the slot is a temporary the COMPILER made, not a name the script
      wrote -- a SELECT subject, a SWAP scratch, a FOR bound. One predicate for
      both tables: hidden globals interleave with user globals in the index space,
      so there is no count to filter by, and the local table hides them the same
      way in a different place. }
    function GlobalIsTemporary(AIndex: Integer): Boolean;
    function LocalIsTemporary(AFuncIndex, ASlot: Integer): Boolean;
    function LocalCount(AFuncIndex: Integer): Integer;
    { ASK THIS BEFORE DUMPING STATE: True when the program carries the names of the
      things it declares. Every program the compiler built does; no program read
      back from a .pbc does.

      It matters because the two filters degrade QUIETLY without it. With no names,
      GlobalName answers '' for every index and so GlobalIsTemporary answers False
      for every index -- including the SELECT subjects and SWAP scratches that are
      certainly in the table. Nothing is wrong there and nothing can be: there is
      no name to judge. But a host that renders the loop in docs/embedding.md
      without asking shows the compiler's own scratch variables as the script's,
      under a blank name, and has no way to tell. When this is False, say "names
      unavailable" and render the values by index. }
    property HasNames: Boolean read FHasNames;
    { EVERY LINE A BREAKPOINT CAN BE INSTALLED ON, ascending and without repeats.

      The set is the lines carried by opStmt, which is not the set of lines in the
      file: `next`, `endfunction`, `rem` and a blank line emit no boundary at all,
      and `a = 1 : b = 2` emits two on one line. A function's HEADER line does
      carry one -- but that boundary is the jump OVER the body, executed once as
      the program steps past the definition and never when the function is called,
      so a breakpoint there fires at startup and looks broken. It is left out, by
      the entry point of each user function rather than by guessing at the shape,
      and a line that also carries a real statement still enters the set. }
    function StoppableLines: TPhosphorLines;
    property Count: Integer read FCount;
  end;

const
  { A COMPILER TEMPORARY'S NAME MUST BE ONE NO SCRIPT CAN WRITE, and the prefix is
    how that is guaranteed. The lexer's IsIdentStart accepts a letter or '_', so
    the old '__h' prefix was forgeable: measured on 2026-09-11, a program whose
    first line was `__h0 = 42` and whose second was a top-level SELECT printed 7
    for `__h0`, because VarIndex found the user's name already in the table and
    handed the SELECT subject the SAME GLOBAL. '#' cannot begin an identifier, so
    a generated name can no longer collide with one -- and the filter below stops
    being a guess about what a name looks like. }
  TemporaryNamePrefix = '#h';

{ True for a name the compiler generated for itself. The one definition of the
  rule: the generator builds names from TemporaryNamePrefix and this reads them,
  so the two cannot drift. }
function IsTemporaryName(const AName: String): Boolean;

function VerifyOpcodeNumbering: Boolean;

implementation

function TConstPool.Add(const V: TValue): Integer;
begin
  if FCount = Length(FItems) then
    SetLength(FItems, (FCount + 1) * 2);
  FItems[FCount] := V;
  Result := FCount;
  Inc(FCount);
end;

function TConstPool.Get(Index: Integer): TValue;
begin
  Result := FItems[Index];
end;

constructor TProgram.Create;
begin
  inherited Create();
  Consts := TConstPool.Create();
  FCount := 0;
end;

destructor TProgram.Destroy;
begin
  Consts.Free;
  inherited Destroy();
end;

function TProgram.Emit(Op: TOpcode; A, B, Line: Integer): Integer;
begin
  if FCount = Length(FInstrs) then
    SetLength(FInstrs, (FCount + 1) * 2);
  FInstrs[FCount].Op := Op;
  FInstrs[FCount].A := A;
  FInstrs[FCount].B := B;
  FInstrs[FCount].Line := Line;
  Result := FCount;
  Inc(FCount);
end;

procedure TProgram.Patch(Index, NewA: Integer);
begin
  FInstrs[Index].A := NewA;
end;

function TProgram.Instr(Index: Integer): TInstr;
begin
  Result := FInstrs[Index];
end;

{ THE NAMES ARE SIZED TO THE TYPES, ALWAYS, at both doors.

  Length(LocalNames) = Length(LocalTypes) is not a rule a caller has to keep; it
  is what these two routines do. A caller with fewer names than slots -- the .pbc
  reader, which has none -- gets the remaining slots named '', and a caller with
  more is truncated to the slots that exist. So the parallel read LocalName can
  never index past the end, whatever a caller passes. }
procedure CopyLocalTable(var AFunc: TUserFunc; const ATypes: array of TVarType;
                         const ANames: array of String);
var i: Integer;
begin
  SetLength(AFunc.LocalTypes, Length(ATypes));
  SetLength(AFunc.LocalNames, Length(ATypes));
  for i := 0 to High(ATypes) do
  begin
    AFunc.LocalTypes[i] := ATypes[i];
    if i <= High(ANames) then AFunc.LocalNames[i] := ANames[i]
    else AFunc.LocalNames[i] := '';
  end;
end;

function TProgram.AddUserFunc(const AName: String; AEntry, AParamCount: Integer;
  const ALocalTypes: array of TVarType; const ALocalNames: array of String;
  ARetType: TVarType): Integer;
begin
  if UserFuncCount = Length(UserFuncs) then
    SetLength(UserFuncs, (UserFuncCount + 1) * 2);
  UserFuncs[UserFuncCount].Name := LowerCase(AName);
  UserFuncs[UserFuncCount].Entry := AEntry;
  UserFuncs[UserFuncCount].ParamCount := AParamCount;
  CopyLocalTable(UserFuncs[UserFuncCount], ALocalTypes, ALocalNames);
  UserFuncs[UserFuncCount].RetType := ARetType;
  Result := UserFuncCount;
  Inc(UserFuncCount);
end;

procedure TProgram.SetUserFuncLocals(AIndex: Integer; const ALocalTypes: array of TVarType;
  const ALocalNames: array of String);
begin
  if (AIndex < 0) or (AIndex >= UserFuncCount) then Exit;
  CopyLocalTable(UserFuncs[AIndex], ALocalTypes, ALocalNames);
end;

{ One loop fills both tables and the count, so a caller cannot leave the three at
  different lengths. Names shorter than the types fill with '' instead of raising:
  the read side already answers an absent name honestly, index by index, and a
  partial table is not worth a second failure mode. }
procedure TProgram.SetGlobalTable(const ATypes: array of TVarType;
                                  const ANames: array of String);
var i: Integer;
begin
  VarCount := Length(ATypes);
  SetLength(VarTypes, Length(ATypes));
  SetLength(FVarNames, Length(ATypes));
  for i := 0 to High(ATypes) do
  begin
    VarTypes[i] := ATypes[i];
    if i <= High(ANames) then FVarNames[i] := ANames[i]
    else FVarNames[i] := '';
  end;
  FHasNames := True;
end;

{ The same table with the names declared absent rather than forgotten. }
procedure TProgram.SetGlobalTableUnnamed(const ATypes: array of TVarType);
var i: Integer;
begin
  VarCount := Length(ATypes);
  SetLength(VarTypes, Length(ATypes));
  SetLength(FVarNames, 0);
  for i := 0 to High(ATypes) do VarTypes[i] := ATypes[i];
  FHasNames := False;
end;

function TProgram.GlobalName(AIndex: Integer): String;
begin
  if (AIndex < 0) or (AIndex > High(FVarNames)) then Exit('');
  Result := FVarNames[AIndex];
end;

function TProgram.LocalCount(AFuncIndex: Integer): Integer;
begin
  if (AFuncIndex < 0) or (AFuncIndex >= UserFuncCount) then Exit(0);
  Result := Length(UserFuncs[AFuncIndex].LocalTypes);
end;

function TProgram.LocalName(AFuncIndex, ASlot: Integer): String;
begin
  if (AFuncIndex < 0) or (AFuncIndex >= UserFuncCount) then Exit('');
  if (ASlot < 0) or (ASlot > High(UserFuncs[AFuncIndex].LocalNames)) then Exit('');
  Result := UserFuncs[AFuncIndex].LocalNames[ASlot];
end;

function TProgram.UserFuncName(AFuncIndex: Integer): String;
begin
  if (AFuncIndex < 0) or (AFuncIndex >= UserFuncCount) then Exit('');
  Result := UserFuncs[AFuncIndex].Name;
end;

function TProgram.GlobalIsTemporary(AIndex: Integer): Boolean;
begin
  Result := IsTemporaryName(GlobalName(AIndex));
end;

function TProgram.LocalIsTemporary(AFuncIndex, ASlot: Integer): Boolean;
begin
  Result := IsTemporaryName(LocalName(AFuncIndex, ASlot));
end;

{ Heapsort, in place: O(n log n), no recursion, and no allocation of its own.

  The obvious alternative -- a flag table indexed by LINE NUMBER -- allocates over
  a field nothing bounds. A .pbc carries each instruction's Line straight from the
  file and ValidateProgram does not check it, so one corrupt instruction claiming
  line 2,000,000,000 would ask for a two-gigabyte table. This sizes everything by
  the instruction count instead, which the loader has already bounded.

  WHICH INPUT ACTUALLY REACHES THIS, because it is not the obvious one and a
  reviewer who assumes the obvious one calls the routine dead. No program the
  COMPILER builds arrives here unsorted: ParseStatement emits one boundary per
  statement in parse order and parse order is source order -- measured over every
  .bas in this tree, zero non-ascending. A .pbc is the input that can arrive in any
  order, and it is a real one: ReadProgram takes each Line from the file and
  ValidateProgram bounds INDICES -- constants, variables, jump targets, local slots
  -- and never a line number nor the order of anything.

  So do not simplify this away on the strength of the compiler alone, and do not
  trust a fixture compiled from source to be testing it: tests/probe_debug builds
  the unsorted shape by hand and then again through the serializer, precisely
  because nothing compiled can tell this routine from `Exit`. The de-duplication
  below compares ADJACENT entries, so it is correct only on what this returns --
  the two are one contract and are tested as one. }
procedure SortLines(var A: TPhosphorLines; N: Integer);
var
  start, last, root, child, t: Integer;
begin
  if N < 2 then Exit;
  start := N div 2;
  last := N - 1;
  while last > 0 do
  begin
    if start > 0 then Dec(start)
    else
    begin
      t := A[last]; A[last] := A[0]; A[0] := t;
      Dec(last);
    end;
    root := start;
    while (root * 2 + 1) <= last do
    begin
      child := root * 2 + 1;
      if (child + 1 <= last) and (A[child] < A[child + 1]) then Inc(child);
      if A[root] >= A[child] then Break;
      t := A[root]; A[root] := A[child]; A[child] := t;
      root := child;
    end;
  end;
end;

function TProgram.StoppableLines: TPhosphorLines;
var
  i, n, hdr: Integer;
  skip: array of Boolean;
  raw: TPhosphorLines;
begin
  Result := nil;
  if FCount = 0 then Exit;
  { The function-header boundaries, named by the TABLE rather than recognised by
    shape. ParseStatement emits the boundary; ParseFunction's first emission is
    the jump over the body, and the entry point is the instruction after it -- so
    the header's boundary is two before the entry. Both opcodes are checked, so a
    hand-built or loaded program whose entry means something else is not misread. }
  SetLength(skip, FCount);
  for i := 0 to UserFuncCount - 1 do
  begin
    hdr := UserFuncs[i].Entry - 2;
    if (hdr >= 0) and (hdr + 1 < FCount) and
       (FInstrs[hdr].Op = opStmt) and (FInstrs[hdr + 1].Op = opJump) then
      skip[hdr] := True;
  end;
  SetLength(raw, FCount);
  n := 0;
  for i := 0 to FCount - 1 do
  begin
    if (FInstrs[i].Op <> opStmt) or skip[i] or (FInstrs[i].Line <= 0) then Continue;
    raw[n] := FInstrs[i].Line;
    Inc(n);
  end;
  if n = 0 then Exit;
  SortLines(raw, n);
  { Ascending and without repeats: `a = 1 : b = 2` is two boundaries on one line,
    and a line a breakpoint can be set on is one entry however many it carries. }
  SetLength(Result, n);
  Result[0] := raw[0];
  hdr := 1;
  for i := 1 to n - 1 do
    if raw[i] <> raw[i - 1] then
    begin
      Result[hdr] := raw[i];
      Inc(hdr);
    end;
  SetLength(Result, hdr);
end;

function TProgram.FindUserFunc(const AName: String; AArgCount: Integer): Integer;
var i: Integer; ln: String;
begin
  ln := LowerCase(AName);
  for i := 0 to UserFuncCount - 1 do
    if (UserFuncs[i].Name = ln) and (UserFuncs[i].ParamCount = AArgCount) then
      Exit(i);
  Result := -1;
end;

procedure TProgram.AddData(const V: TValue);
begin
  if DataCount = Length(DataPool) then
    SetLength(DataPool, (DataCount + 1) * 2);
  DataPool[DataCount] := V;
  Inc(DataCount);
end;

function IsTemporaryName(const AName: String): Boolean;
begin
  Result := (Length(AName) > Length(TemporaryNamePrefix)) and
            (Copy(AName, 1, Length(TemporaryNamePrefix)) = TemporaryNamePrefix);
end;

{ Fires if an opcode was renumbered or reordered -- the silent-format-break the
  discipline exists to prevent. Called at engine startup. }
function VerifyOpcodeNumbering: Boolean;
begin
  Result :=
    (Ord(opNop) = 0) and (Ord(opPushConst) = 1) and (Ord(opPop) = 2) and
    (Ord(opCall) = 3) and (Ord(opPrint) = 4) and (Ord(opPrintLn) = 5) and
    (Ord(opNeg) = 6) and (Ord(opAdd) = 7) and (Ord(opSub) = 8) and
    (Ord(opMul) = 9) and (Ord(opDivReal) = 10) and (Ord(opDivInt) = 11) and
    (Ord(opPow) = 12) and (Ord(opMod) = 13) and (Ord(opEQ) = 14) and
    (Ord(opNE) = 15) and (Ord(opLT) = 16) and (Ord(opLE) = 17) and
    (Ord(opGT) = 18) and (Ord(opGE) = 19) and (Ord(opLoadVar) = 20) and
    (Ord(opStoreVar) = 21) and (Ord(opJumpIfFalse) = 22) and (Ord(opAnd) = 23) and
    (Ord(opOr) = 24) and (Ord(opNot) = 25) and (Ord(opJump) = 26) and
    (Ord(opHalt) = 27) and (Ord(opGosub) = 28) and (Ord(opReturn) = 29) and
    (Ord(opLoadLocal) = 30) and (Ord(opStoreLocal) = 31) and (Ord(opRetFunc) = 32) and
    (Ord(opReadData) = 33) and (Ord(opRestore) = 34) and (Ord(opDup2) = 35) and
    (Ord(opStmt) = 36) and (Ord(opSetErrHandler) = 37) and (Ord(opResume) = 38) and
    (Ord(opDupN) = 39) and (Ord(opTrace) = 40) and (Ord(opBreakpoint) = 41) and
    (Ord(opInputLine) = 42) and (Ord(opInputField) = 43) and (Ord(opInputAll) = 44) and
    (Ord(opInputChars) = 45) and (Ord(opOpenFile) = 46) and (Ord(opCloseFile) = 47) and
    (Ord(opPrintFile) = 48) and (Ord(opFileField) = 49) and (Ord(opFileLine) = 50) and
    (Ord(opFileChars) = 51) and (Ord(opEofFile) = 52) and (Ord(opLofFile) = 53) and
    (Ord(opLocFile) = 54) and (Ord(opPrintUsing) = 55) and (Ord(opSeekFile) = 56);
end;

end.
