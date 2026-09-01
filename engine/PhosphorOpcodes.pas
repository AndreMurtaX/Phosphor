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
    opNot      = 25
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

  TProgram = class
  private
    FInstrs: array of TInstr;
    FCount: Integer;
  public
    Consts: TConstPool;
    VarCount: Integer;              // number of distinct variables
    VarTypes: array of TVarType;    // declared type of each variable (by index)
    constructor Create;
    destructor Destroy; override;
    function Emit(Op: TOpcode; A, B, Line: Integer): Integer;
    procedure Patch(Index, NewA: Integer);   // set A of an already-emitted instr
    function Instr(Index: Integer): TInstr;
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
    (Ord(opOr) = 24) and (Ord(opNot) = 25);
end;

end.
