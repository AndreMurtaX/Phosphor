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
    opPrintUsing = 55  // A = value count; pop A values + the format$: emit formatted
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
    (ParamCount of them), then declared locals. RetType is from the name suffix. }
  TUserFunc = record
    Name: String;
    Entry: Integer;
    ParamCount: Integer;
    LocalTypes: array of TVarType;
    RetType: TVarType;
  end;

  TProgram = class
  private
    FInstrs: array of TInstr;
    FCount: Integer;
  public
    Consts: TConstPool;
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
    function AddUserFunc(const AName: String; AEntry, AParamCount: Integer;
                         const ALocalTypes: array of TVarType; ARetType: TVarType): Integer;
    function FindUserFunc(const AName: String; AArgCount: Integer): Integer;
    procedure AddData(const V: TValue);
    property Count: Integer read FCount;
  end;

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
  inherited Create;
  Consts := TConstPool.Create;
  FCount := 0;
end;

destructor TProgram.Destroy;
begin
  Consts.Free;
  inherited Destroy;
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

function TProgram.AddUserFunc(const AName: String; AEntry, AParamCount: Integer;
  const ALocalTypes: array of TVarType; ARetType: TVarType): Integer;
var i: Integer;
begin
  if UserFuncCount = Length(UserFuncs) then
    SetLength(UserFuncs, (UserFuncCount + 1) * 2);
  UserFuncs[UserFuncCount].Name := LowerCase(AName);
  UserFuncs[UserFuncCount].Entry := AEntry;
  UserFuncs[UserFuncCount].ParamCount := AParamCount;
  SetLength(UserFuncs[UserFuncCount].LocalTypes, Length(ALocalTypes));
  for i := 0 to High(ALocalTypes) do
    UserFuncs[UserFuncCount].LocalTypes[i] := ALocalTypes[i];
  UserFuncs[UserFuncCount].RetType := ARetType;
  Result := UserFuncCount;
  Inc(UserFuncCount);
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
    (Ord(opLocFile) = 54) and (Ord(opPrintUsing) = 55);
end;

end.
