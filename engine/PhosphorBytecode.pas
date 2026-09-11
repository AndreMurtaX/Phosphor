{******************************************************************************
  Phosphor BASIC -- on-disk bytecode (.pbc) reader and writer

  MIT License. Copyright (c) 2026 Andre Murta.

  Serializes a compiled TProgram to a stream and reads it back, so a script can be
  compiled once (`phosphor compile a.bas a.pbc`) and run later without the lexer or
  compiler. The format is EXPLICITLY little-endian (NtoLE/LEToN), with a fixed 8-byte
  Double, so the same .pbc runs on the Windows and Linux x86-64 targets alike.

  Frozen decisions (decisions.md, "On-disk bytecode") honoured here:
    * Opcodes carry explicit append-only numbers -- so a stored opcode byte means
      the same instruction on load. The header records the FORMAT VERSION and the
      highest opcode number; a mismatch on either is REFUSED OUT LOUD, never
      executed as the wrong opcodes.
    * TInstr stores Op/A/B/Line only (its run-time proc is derived, never written).
    * The constant pool is an explicit indexable structure (consts serialize in
      index order and reload to the same indices).

  This unit does no file I/O of its own -- it works on a TStream the host provides
  (a TFileStream for a .pbc, a TBytesStream in memory) -- and stays host-agnostic;
  the boundary check passes.
******************************************************************************}
unit PhosphorBytecode;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  Classes, SysUtils, PhosphorValue, PhosphorOpcodes, PhosphorRegistry;

const
  PBC_MAGIC   = 'PBC';   // 3 bytes at the start of every .pbc stream
  PBC_VERSION = 1;       // bump whenever the format or opcode meaning changes

{ Write AProg to AStream in the .pbc format. }
{ Every library function this program calls that AReg cannot provide, as a report
  ready to print, and the count. Empty and 0 when the program is fully satisfied.

  A call is a library call only if the program does not define the name itself:
  the VM looks in UserFuncs first and reaches the registry second, and this walks
  the same order, so a program's own functions are never reported missing.

  Only the NAME is judged. The registry can also refuse a known name given the
  wrong argument kinds, but those kinds come from values that exist only while
  running -- deciding that here would be guessing. }
function UnresolvedCalls(AProg: TProgram; AReg: TPhosphorRegistry;
                         out AReport: String): Integer;

procedure WriteProgram(AStream: TStream; AProg: TProgram);
{ Read a program from AStream. False (with AErr set) on a bad magic, an
  unsupported version, an opcode-set mismatch, or a truncated/corrupt stream. }
function ReadProgram(AStream: TStream; out AProg: TProgram; out AErr: String): Boolean;

implementation

// --- little-endian primitives -----------------------------------------------
procedure WU8(S: TStream; B: Byte);            begin S.WriteBuffer(B, 1); end;
function  RU8(S: TStream): Byte;               begin S.ReadBuffer(Result, 1); end;
procedure WI32(S: TStream; V: LongInt);        begin V := NtoLE(V); S.WriteBuffer(V, 4); end;
function  RI32(S: TStream): LongInt;           begin S.ReadBuffer(Result, 4); Result := LEToN(Result); end;
procedure WI64(S: TStream; V: Int64);          begin V := NtoLE(V); S.WriteBuffer(V, 8); end;
function  RI64(S: TStream): Int64;             begin S.ReadBuffer(Result, 8); Result := LEToN(Result); end;
procedure WDbl(S: TStream; const V: Double);   begin WI64(S, PInt64(@V)^); end;   // bit pattern, LE
function  RDbl(S: TStream): Double;            var q: Int64; begin q := RI64(S); Result := PDouble(@q)^; end;

procedure WStr(S: TStream; const V: String);
begin
  WI32(S, Length(V));
  if Length(V) > 0 then S.WriteBuffer(V[1], Length(V));
end;
{ THE LENGTH IS A CLAIM, NOT A FACT, and this used to believe it.

  `SetLength(Result, n)` with the n a corrupt file names commits that many bytes
  BEFORE a single one has been read: a four-byte edit turning a string length
  into 2,000,000,000 asked the allocator for 2 GB, on a 343-byte file, and only
  then failed the read. It was reported as a corrupt file rather than crashing,
  which is why an earlier pass left it alone -- but "refused after committing
  2 GB" is a poor kind of refused, and on a machine under memory pressure the
  allocation is the failure.

  It is fixed by GROWING TO WHAT ARRIVES instead of to what is claimed. The
  buffer doubles as bytes are actually read, so the memory in hand never exceeds
  twice the data the stream really had, and a length no file can satisfy costs
  64 KB before the read fails.

  A CEILING WAS THE WRONG FIX and was deliberately not used: MaxSaneCount would
  refuse a legitimate .pbc holding a string constant larger than 10 MB, which is
  unusual but not corrupt. This shape refuses nothing that a stream can actually
  deliver -- there is no number n for which a valid file now loads differently.
  It also does not need the stream's Size, so it still works on the non-seekable
  streams ReadProgram accepts. }
function RStr(S: TStream): String;
const
  FirstChunk = 65536;
var
  n, have, cap, got: LongInt;
begin
  n := RI32(S);
  Result := '';
  if n < 0 then
    raise EReadError.CreateFmt('a stored string has length %d', [n]);
  if n = 0 then Exit;
  cap := n;
  if cap > FirstChunk then cap := FirstChunk;
  SetLength(Result, cap);
  have := 0;
  while have < n do
  begin
    if have = cap then
    begin
      cap := cap * 2;                    // geometric, so this stays O(n) overall
      if (cap > n) or (cap < 0) then cap := n;
      SetLength(Result, cap);
    end;
    got := S.Read(Result[have + 1], cap - have);
    if got <= 0 then
    begin
      SetLength(Result, have);
      raise EReadError.CreateFmt('a stored string claims %d bytes and the ' +
                                 'stream ended after %d', [n, have]);
    end;
    Inc(have, got);
  end;
end;

procedure WVal(S: TStream; const V: TValue);
begin
  WU8(S, Ord(V.Kind));
  case V.Kind of
    vkDouble: WDbl(S, V.Num);
    vkInt:    WI64(S, V.Int);
    vkHandle: WI64(S, V.Hnd);
    vkBool:   WU8(S, Ord(V.Bl));
    vkString: WStr(S, V.Str);
  end;
end;
{ THE KIND BYTE IS CHECKED HERE AND THE NUMBER IS NOT, AND THE SPLIT IS THE
  POINT.

  A kind cannot be judged later, because it decides HOW MANY BYTES FOLLOW. The
  `else` branch used to answer Default(TValue) for an unknown byte and read no
  payload at all, so every later field in the file was off by up to eight bytes:
  the rest of the pool, the function table and the DATA section were then decoded
  from the middle of a value. The file was not refused, it was silently
  reinterpreted -- and it also left a TValue whose Kind is a number no
  TValueKind names travelling through the engine. A raise here is caught by
  ReadProgram and reported as a corrupt file, which is what it is.

  A non-finite DOUBLE is the opposite case: it does not disturb the stream at
  all, so it can be judged on the finished program, where the offender can be
  named by index. ValidateProgram sweeps both value pools for it -- see the
  comment on that function. }
function RVal(S: TStream): TValue;
var raw: Byte;
begin
  raw := RU8(S);
  if raw > Ord(High(TValueKind)) then
    raise EReadError.CreateFmt('a stored value has kind %d, and this build ' +
                               'knows 0..%d', [raw, Ord(High(TValueKind))]);
  case TValueKind(raw) of
    vkDouble: Result := ValDouble(RDbl(S));
    vkInt:    Result := ValInt(RI64(S));
    vkHandle: Result := ValHandle(RI64(S));
    vkBool:   Result := ValBool(RU8(S) <> 0);
    vkString: Result := ValStr(RStr(S));
  else
    Result := Default(TValue);
  end;
end;

// --- the program -------------------------------------------------------------
{ The five spellings of the indirect call, one per return kind. }
function IsIndirectCall(const AName: String): Boolean;
var n: String;
begin
  n := LowerCase(AName);
  Result := (n = 'callfunc') or (n = 'callfunc%') or (n = 'callfunc$') or
            (n = 'callfunc@') or (n = 'callfunc?');
end;

{ The callee name of an indirect call, when it was written at the call site.

  Arguments are compiled in order and opCall carries their COUNT, not their
  width, so the first argument's instruction cannot be found by subtracting the
  count: for `callfunc("f", "a" + "b")` that lands on `push "b"` and would report
  a function named b. The walk back therefore crosses only instructions that push
  exactly one value and consume none, and gives up on anything else -- so a call
  is either understood exactly or left alone. False silence, never false alarm. }
function LiteralIndirectTarget(AProg: TProgram; ACallAt: Integer;
                               out AName: String): Boolean;
var
  argc, k, at: Integer;
  op: TOpcode;
  v: TValue;
begin
  Result := False;
  AName := '';
  argc := AProg.Instr(ACallAt).B;
  if argc < 1 then Exit;              // no name argument at all
  at := ACallAt;
  for k := 1 to argc do
  begin
    Dec(at);
    if at < 0 then Exit;
    op := AProg.Instr(at).Op;
    if (op <> opPushConst) and (op <> opLoadVar) and (op <> opLoadLocal) then
      Exit;                           // a compound argument: stop guessing
  end;
  // `at` is now the first argument's instruction, exactly.
  if AProg.Instr(at).Op <> opPushConst then Exit;
  v := AProg.Consts.Get(AProg.Instr(at).A);
  if v.Kind <> vkString then Exit;
  AName := v.Str;
  Result := AName <> '';
end;

function UnresolvedCalls(AProg: TProgram; AReg: TPhosphorRegistry;
                         out AReport: String): Integer;
var
  i, j: Integer;
  ins: TInstr;
  name, lit: String;
  seen: array of String;
  isNew: Boolean;
begin
  Result := 0;
  AReport := '';
  SetLength(seen, 0);
  for i := 0 to AProg.Count - 1 do
  begin
    ins := AProg.Instr(i);
    if ins.Op <> opCall then Continue;
    name := AProg.Consts.Get(ins.A).Str;
    lit := '';
    // An INDIRECT call whose callee is written at the call site. The name is a
    // constant in the pool like any other, so it is as checkable as a direct
    // call -- and only then. See LiteralIndirectTarget for why the walk back is
    // as cautious as it is.
    if IsIndirectCall(name) and LiteralIndirectTarget(AProg, i, lit) then
    begin
      if (AProg.FindUserFunc(lit, ins.B - 1) < 0) and (not AReg.HasName(lit)) then
      begin
        isNew := True;
        for j := 0 to High(seen) do
          if seen[j] = lit then begin isNew := False; Break; end;
        if isNew then
        begin
          SetLength(seen, Length(seen) + 1);
          seen[High(seen)] := lit;
          Inc(Result);
          AReport := AReport + '    ' + lit + '   (named at line ' +
                     IntToStr(ins.Line) + ', called indirectly)' + LineEnding;
        end;
      end;
      Continue;   // the callfunc name itself is real; the callee has been judged
    end;
    // The program's own functions are resolved before the registry is consulted.
    if AProg.FindUserFunc(name, ins.B) >= 0 then Continue;
    if AReg.HasName(name) then Continue;
    // Report each name ONCE, at the first line that calls it: a name used in a
    // loop is one problem, not fifty.
    isNew := True;
    for j := 0 to High(seen) do
      if seen[j] = name then begin isNew := False; Break; end;
    if not isNew then Continue;
    SetLength(seen, Length(seen) + 1);
    seen[High(seen)] := name;
    Inc(Result);
    AReport := AReport + '    ' + name + '   (first called at line ' +
               IntToStr(ins.Line) + ')' + LineEnding;
  end;
end;

procedure WriteProgram(AStream: TStream; AProg: TProgram);
var
  i, j: Integer;
  ins: TInstr;
begin
  AStream.WriteBuffer(PBC_MAGIC[1], 3);
  WU8(AStream, PBC_VERSION);
  WU8(AStream, Ord(High(TOpcode)));   // opcode-set guard

  WI32(AStream, AProg.VarCount);
  for i := 0 to AProg.VarCount - 1 do WU8(AStream, Ord(AProg.VarTypes[i]));

  WI32(AStream, AProg.Count);
  for i := 0 to AProg.Count - 1 do
  begin
    ins := AProg.Instr(i);
    WU8(AStream, Ord(ins.Op)); WI32(AStream, ins.A); WI32(AStream, ins.B); WI32(AStream, ins.Line);
  end;

  WI32(AStream, AProg.Consts.Count);
  for i := 0 to AProg.Consts.Count - 1 do WVal(AStream, AProg.Consts.Get(i));

  WI32(AStream, AProg.UserFuncCount);
  for i := 0 to AProg.UserFuncCount - 1 do
  begin
    WStr(AStream, AProg.UserFuncs[i].Name);
    WI32(AStream, AProg.UserFuncs[i].Entry);
    WI32(AStream, AProg.UserFuncs[i].ParamCount);
    WI32(AStream, Length(AProg.UserFuncs[i].LocalTypes));
    for j := 0 to High(AProg.UserFuncs[i].LocalTypes) do WU8(AStream, Ord(AProg.UserFuncs[i].LocalTypes[j]));
    WU8(AStream, Ord(AProg.UserFuncs[i].RetType));
  end;

  WI32(AStream, AProg.DataCount);
  for i := 0 to AProg.DataCount - 1 do WVal(AStream, AProg.DataPool[i]);
end;


const
  { A ceiling on any count read from a file, applied BEFORE allocating for it. No
    real program has ten million of anything, and a corrupt length field otherwise
    asks the loader for an absurd allocation before anything can check it. }
  MaxSaneCount = 10000000;

{ ------------------------------------------------------------------------------
  A .pbc IS UNTRUSTED INPUT.

  The header was checked -- magic, format version, opcode-set size -- and then
  every count and every operand in the body was believed. A file whose header is
  intact and whose body is not is exactly what a truncated download, a bad disk or
  a deliberately edited file looks like, and it drove the interpreter out of
  bounds: changing one opPushConst operand to 0x01000000 was enough for an access
  violation, because the constant pool is indexed without a check at run time.

  Everything the VM will index is therefore verified HERE, once, before the
  program runs: a constant index against the pool, a variable index against the
  variable table, a jump target against the instruction count, a function entry
  against the same. What cannot be checked statically -- a local slot, which
  depends on the frame -- is at least checked for a negative.

  AND EACH OF THOSE BOUNDS IS INCLUSIVE OR EXCLUSIVE ON PURPOSE, because one
  of them was not and it cost a silent no-op (2026-09-10). Written out:

    constant index (opPushConst, opCall)     0 .. Consts.Count-1   EXCLUSIVE
    variable index (opLoadVar/opStoreVar)    0 .. VarCount-1       EXCLUSIVE
    jump target (opJump/JumpIfFalse/Gosub)   0 .. Count            INCLUSIVE --
        Count is not an instruction; it is where the dispatch loop STOPS, which
        is what a compiler emits for "and then the program ends".
    handler target (opSetErrHandler)        -1 .. Count            INCLUSIVE --
        -1 disables the handler; Count is the same end-of-program position.
    local slot (opLoadLocal/opStoreLocal)    0 .. maxLocals-1      EXCLUSIVE
    function entry                           0 .. Count-1          EXCLUSIVE --
        a called function must have an instruction to run; see the check itself.
    operand counts (DupN/Breakpoint/PrintUsing, opCall's argc)  >= 0 only, and
        the VM bounds the rest against the stack it actually has.

  And everything the VM will COMPUTE ON, which is the half this pass did not have
  (2026-09-06): every index in the file was bounded and not one VALUE was looked
  at, so a stored Double could be +Inf or a NaN. See the pool sweep below.

  The alternative was bounds-checking every index in the dispatch loop, which
  would cost every program a little to protect against a file almost no program
  loads. Validating once, at the boundary, costs the load and nothing after it.

  WHERE THIS PASS STOPS, AND WHY (2026-09-06). Three crashes that a valid-looking
  .pbc could still reach are guarded in the DISPATCH LOOP instead, not here:
  opDupN/opDup2 reading below the bottom of the value stack, and
  opLoadLocal/opStoreLocal running with no activation frame. Each needs a fact
  this pass cannot have -- how deep the value stack is, and whether a frame is
  live -- and neither is a property of the INSTRUCTION. Both are properties of
  the PATH that reached it, and there is no sound cheap path analysis to do here:
  opGosub/opReturn choose a return address at run time, an ON ERROR handler is
  entered from any faulting instruction with the stack reset to its install
  point, `resume` re-enters mid-statement, and the host can re-enter the VM at
  any function entry through CallUserFunc. An abstract-depth pass would have to
  be either unsound or strict enough to reject what the compiler emits.

  So the rule this file follows is: STATIC where the instruction carries the
  answer, RUN TIME where only the running VM does -- and run time means a
  catchable engine error, never a trap. Do not try to move those four here.
  ------------------------------------------------------------------------------ }
function ValidateProgram(AProg: TProgram; out AErr: String): Boolean;
var
  i, maxLocals: Integer;
  ins: TInstr;

  function Bad(const AWhat: String; AIndex, ALimit: Integer): Boolean;
  begin
    AErr := Format('corrupt .pbc: instruction %d has %s %d, outside 0..%d',
                   [i, AWhat, AIndex, ALimit - 1]);
    Result := False;
  end;

begin
  AErr := '';
  Result := False;
  if AProg.VarCount < 0 then
  begin AErr := 'corrupt .pbc: negative variable count'; Exit; end;
  if Length(AProg.VarTypes) <> AProg.VarCount then
  begin AErr := 'corrupt .pbc: the variable table does not match its count'; Exit; end;

  { EVERY VALUE, NOT ONLY EVERY INDEX -- the half of this pass that was missing.

    A stored Double is eight raw bytes that RDbl reinterprets, and nothing looked
    at what they meant. Every OTHER field in the file was bounded and this one
    was believed, so a single flipped bit -- a truncated download, a bad disk,
    fifteen seconds with a hex editor -- put +Inf or a NaN into the constant pool
    of a program that then loaded and ran. The first operator to touch it raised
    the unmasked invalid-operation trap: exit 217, "unhandled EInvalidOp",
    nothing `on error goto` could see, nothing an embedding host could survive.
    A packed .exe carries the same exposure, because the stub loads its payload
    through this same reader.

    The rule broken is PhosphorValue's founding invariant -- no TValue ever holds
    a non-finite Double -- and a .pbc is the one input that can break it without
    passing through the lexer, which checks its literals. So it is checked here.

    THIS SWEEP IS COMPLETE, and the reason is structural rather than a list of
    places to remember: a TProgram holds TValues in exactly two members, the
    constant pool and the DATA pool (PhosphorOpcodes, TProgram), and both are
    walked in full. It does not matter which reader put a value there. }
  for i := 0 to AProg.Consts.Count - 1 do
    if not IsFiniteVal(AProg.Consts.Get(i)) then
    begin
      AErr := Format('corrupt .pbc: constant %d is %s, which is not a finite ' +
                     'number and cannot be a Phosphor value',
                     [i, ValToStr(AProg.Consts.Get(i))]);
      Exit(False);
    end;
  for i := 0 to AProg.DataCount - 1 do
    if not IsFiniteVal(AProg.DataPool[i]) then
    begin
      AErr := Format('corrupt .pbc: DATA item %d is %s, which is not a finite ' +
                     'number and cannot be a Phosphor value',
                     [i, ValToStr(AProg.DataPool[i])]);
      Exit(False);
    end;

  { The widest local table any frame can have. Computed before the instruction
    pass, because that pass bounds every local slot against it. }
  maxLocals := 0;
  for i := 0 to AProg.UserFuncCount - 1 do
    if Length(AProg.UserFuncs[i].LocalTypes) > maxLocals then
      maxLocals := Length(AProg.UserFuncs[i].LocalTypes);

  for i := 0 to AProg.Count - 1 do
  begin
    ins := AProg.Instr(i);
    case ins.Op of
      opPushConst, opCall:
        if (ins.A < 0) or (ins.A >= AProg.Consts.Count) then
          Exit(Bad('constant index', ins.A, AProg.Consts.Count));
      opLoadVar, opStoreVar:
        if (ins.A < 0) or (ins.A >= AProg.VarCount) then
          Exit(Bad('variable index', ins.A, AProg.VarCount));
      opJump, opJumpIfFalse, opGosub:
        if (ins.A < 0) or (ins.A > AProg.Count) then
          Exit(Bad('jump target', ins.A, AProg.Count + 1));
      opSetErrHandler:
        // -1 disables the handler; anything else is a pc
        if (ins.A < -1) or (ins.A > AProg.Count) then
          Exit(Bad('handler target', ins.A, AProg.Count + 1));
      opLoadLocal, opStoreLocal:
        { A local slot cannot be checked against ITS OWN function here -- nothing
          in the file says which function an instruction belongs to. It can be
          checked against the LARGEST local table in the program, which is a real
          bound and costs one pass: no slot index above it can ever be valid in
          any frame. A wild index from a corrupt file is caught; one that is
          merely too large for its own function is not -- the VM now bounds the
          slot against the frame it actually lands in, which is the only place
          that number exists (PhosphorVM, opLoadLocal). Nor does this say whether
          a frame exists at all when the instruction runs; the VM refuses that
          too. Both are noted in the policy comment above. }
        if (ins.A < 0) or (ins.A >= maxLocals) then
        begin
          { "outside 0..-1" is what the general message says when the program
            declares no locals at all, and it reads like a bug in the checker
            rather than a fact about the file. }
          if maxLocals = 0 then
            AErr := Format('corrupt .pbc: instruction %d reads local slot %d, ' +
                           'but no function in this program declares any locals',
                           [i, ins.A])
          else
            Bad('local slot', ins.A, maxLocals);
          Exit(False);
        end;
      opDupN, opBreakpoint, opPrintUsing:
        if ins.A < 0 then
          Exit(Bad('operand', ins.A, 0));
    end;
    if ins.Op = opCall then
      if ins.B < 0 then
        Exit(Bad('argument count', ins.B, 0));
  end;

  for i := 0 to AProg.UserFuncCount - 1 do
  begin
    { A FUNCTION ENTRY IS AN INSTRUCTION INDEX, SO THE BOUND IS EXCLUSIVE -- and
      it was written inclusive, `> AProg.Count`, which let Entry = Count through.

      That form is right eleven lines up for a JUMP target: pc = Count is how a
      compiler spells "fall off the end", the dispatch loop stops, and the
      program has finished. It is wrong for a function entry, where the loop
      stopping means the call never runs, never returns, and abandons everything
      after it while Run still answers True. Measured 2026-09-10 on a .pbc whose
      one user function had its Entry set to the instruction count: the file
      loaded, the program that should print two lines printed nothing, and the
      process exited 0. "Runs and does nothing, successfully" is the single
      outcome this validator exists to prevent, and it was the one it produced.

      A function must have at least one instruction to enter, so Count is out. }
    if (AProg.UserFuncs[i].Entry < 0) or (AProg.UserFuncs[i].Entry >= AProg.Count) then
    begin
      { "outside 0..-1" reads like a bug in the checker rather than a fact about
        the file, the same way it did for the local-slot message above. }
      if AProg.Count = 0 then
        AErr := Format('corrupt .pbc: function %d starts at instruction %d, but ' +
                       'this program has no instructions',
                       [i, AProg.UserFuncs[i].Entry])
      else
        AErr := Format('corrupt .pbc: function %d starts at instruction %d, ' +
                       'outside the program''s 0..%d',
                       [i, AProg.UserFuncs[i].Entry, AProg.Count - 1]);
      Exit;
    end;
    { A FUNCTION'S LOCAL TABLE MUST HOLD ITS PARAMETERS, and this one is not
      theoretical: it was an out-of-bounds WRITE, found 2026-09-06 by flipping the
      local-slot count of a one-parameter function from 1 to 0 in a .pbc.

      opCall resolves by name AND arity, so a match guarantees argc = ParamCount --
      and nothing guaranteed the frame had room for them. The call path sizes the
      frame from LocalTypes (`SetLength(Locals, Length(LocalTypes))`) and then
      writes `Locals[i]` for each argument, so a table shorter than the parameter
      list writes past the allocation. That reached the LCL as an access violation
      and, in a binary that links Forms, a modal dialog on a machine with nobody
      watching. }
    if AProg.UserFuncs[i].ParamCount < 0 then
    begin
      AErr := Format('corrupt .pbc: function %d has a negative parameter count (%d)',
                     [i, AProg.UserFuncs[i].ParamCount]);
      Exit;
    end;
    if Length(AProg.UserFuncs[i].LocalTypes) < AProg.UserFuncs[i].ParamCount then
    begin
      AErr := Format('corrupt .pbc: function %d takes %d parameters but has room ' +
                     'for %d locals', [i, AProg.UserFuncs[i].ParamCount,
                     Length(AProg.UserFuncs[i].LocalTypes)]);
      Exit;
    end;
  end;
  Result := True;
end;

function ReadProgram(AStream: TStream; out AProg: TProgram; out AErr: String): Boolean;
var
  magic: array[0..2] of Char;
  ver, maxop: Byte;
  i, j, n, vc, ltc: Integer;
  op: TOpcode;
  a, b, ln: LongInt;
  fname: String;
  entry, pcount: LongInt;
  raw: Byte;
  lts: array of TVarType;
  gts: array of TVarType;
  rt: TVarType;
begin
  AProg := nil;
  AErr := '';
  Result := False;
  try
    if AStream.Read(magic[0], 3) <> 3 then begin AErr := 'not a Phosphor bytecode file (too short)'; Exit; end;
    if (magic[0] <> 'P') or (magic[1] <> 'B') or (magic[2] <> 'C') then
    begin AErr := 'not a Phosphor bytecode file (bad magic)'; Exit; end;
    ver := RU8(AStream);
    if ver <> PBC_VERSION then
    begin AErr := Format('unsupported .pbc format version %d (this build reads version %d)', [ver, PBC_VERSION]); Exit; end;
    maxop := RU8(AStream);
    if maxop <> Ord(High(TOpcode)) then
    begin AErr := Format('this .pbc was built for a different opcode set (%d vs %d) -- recompile it', [maxop, Ord(High(TOpcode))]); Exit; end;

    AProg := TProgram.Create();

    vc := RI32(AStream);
    if (vc < 0) or (vc > MaxSaneCount) then
    begin
      AErr := Format('corrupt .pbc: variable count %d', [vc]);
      AProg.Free; AProg := nil; Exit(False);
    end;
    { vc is already bounded by MaxSaneCount above, which is what this length rests
      on. The types are collected here and installed in one call, so the count and
      the table cannot part company. }
    SetLength(gts, vc);
    for i := 0 to vc - 1 do
    begin
      raw := RU8(AStream);
      if raw > Ord(High(TVarType)) then
      begin
        AErr := Format('corrupt .pbc: variable %d has type %d, and this build knows 0..%d',
                       [i, raw, Ord(High(TVarType))]);
        AProg.Free; AProg := nil; Exit(False);
      end;
      gts[i] := TVarType(raw);
    end;
    { THE FILE CARRIES NO NAMES, AND THIS IS WHERE THAT IS SAID OUT LOUD rather
      than left to be inferred from an argument nobody passed. The format is
      version 1 behind an exact-match refusal (:571), so adding a name section
      would make this build reject every .pbc an earlier one wrote and every
      `phosphor pack` of one. TProgram.HasNames answers False from here, which is
      how a host learns that its variables pane has nothing to show and that the
      temporary filter has nothing to filter by. }
    AProg.SetGlobalTableUnnamed(gts);

    n := RI32(AStream);
    if (n < 0) or (n > MaxSaneCount) then
    begin
      AErr := Format('corrupt .pbc: a section claims %d entries', [n]);
      AProg.Free; AProg := nil; Exit(False);
    end;
    for i := 0 to n - 1 do
    begin
      raw := RU8(AStream);
      if raw > Ord(High(TOpcode)) then
      begin
        AErr := Format('corrupt .pbc: instruction %d has opcode %d, and this build ' +
                       'knows 0..%d', [i, raw, Ord(High(TOpcode))]);
        AProg.Free; AProg := nil; Exit(False);
      end;
      op := TOpcode(raw); a := RI32(AStream); b := RI32(AStream); ln := RI32(AStream);
      AProg.Emit(op, a, b, ln);
    end;

    n := RI32(AStream);
    if (n < 0) or (n > MaxSaneCount) then
    begin
      AErr := Format('corrupt .pbc: a section claims %d entries', [n]);
      AProg.Free; AProg := nil; Exit(False);
    end;
    for i := 0 to n - 1 do AProg.Consts.Add(RVal(AStream));

    n := RI32(AStream);
    if (n < 0) or (n > MaxSaneCount) then
    begin
      AErr := Format('corrupt .pbc: a section claims %d entries', [n]);
      AProg.Free; AProg := nil; Exit(False);
    end;
    for i := 0 to n - 1 do
    begin
      fname := RStr(AStream);
      entry := RI32(AStream);
      pcount := RI32(AStream);
      ltc := RI32(AStream);
      { THE LOCAL TABLE OF A USER FUNCTION -- the one count and the two enum
        bytes this reader was still believing.

        Every other count in this function is bounded by MaxSaneCount before it
        is allocated for, and every other enum byte -- the opcode, the GLOBAL
        variable type, and (since the pool sweep) the value kind -- is checked
        against the range this build knows. The local table was neither, and it
        is read from the same untrusted bytes:

          ltc unbounded   `SetLength(lts, 2000000000)` commits 2 GB from a
                          four-byte edit, on a 343-byte file, before the read
                          that fails it (measured 2026-09-07).
          the type bytes   a 200 here LOADED CLEANLY and put TVarType(200) into
                          the program. Nothing crashed -- DefaultValue and
                          StoreCheck both have an `else` -- but every store into
                          that slot then answers "cannot store number into ?
                          local", a message about a type no source can spell,
                          and the value travelling through the engine is an enum
                          outside its own declared range.

        Both are checked here rather than in ValidateProgram because ltc decides
        HOW MANY BYTES FOLLOW -- the same reason RVal checks its kind byte at
        read time -- and once ltc is trusted the type bytes are right there. }
      if (ltc < 0) or (ltc > MaxSaneCount) then
      begin
        AErr := Format('corrupt .pbc: function %d claims %d local slots', [i, ltc]);
        AProg.Free; AProg := nil; Exit(False);
      end;
      SetLength(lts, ltc);
      for j := 0 to ltc - 1 do
      begin
        raw := RU8(AStream);
        if raw > Ord(High(TVarType)) then
        begin
          AErr := Format('corrupt .pbc: function %d, local slot %d has type %d, ' +
                         'and this build knows 0..%d',
                         [i, j, raw, Ord(High(TVarType))]);
          AProg.Free; AProg := nil; Exit(False);
        end;
        lts[j] := TVarType(raw);
      end;
      raw := RU8(AStream);
      if raw > Ord(High(TVarType)) then
      begin
        AErr := Format('corrupt .pbc: function %d returns type %d, and this ' +
                       'build knows 0..%d', [i, raw, Ord(High(TVarType))]);
        AProg.Free; AProg := nil; Exit(False);
      end;
      rt := TVarType(raw);
      { NO LOCAL NAMES, SAID OUT LOUD. The format does not carry them and is not
        being changed to: PBC_VERSION is 1 and the version test at the top of this
        function is exact-match, so a bump makes this build refuse every .pbc an
        earlier one wrote and makes `phosphor pack` refuse the same files. Names
        exist to serve a host that COMPILED the program in-process, which is the
        only path that has them. A program read back from disk answers '' for
        every name, which LocalName and GlobalName are written to do. }
      AProg.AddUserFunc(fname, entry, pcount, lts, [], rt);
    end;

    n := RI32(AStream);
    if (n < 0) or (n > MaxSaneCount) then
    begin
      AErr := Format('corrupt .pbc: a section claims %d entries', [n]);
      AProg.Free; AProg := nil; Exit(False);
    end;
    for i := 0 to n - 1 do AProg.AddData(RVal(AStream));

    // Everything the VM will index, checked once, before it runs.
    if not ValidateProgram(AProg, AErr) then
    begin
      AProg.Free; AProg := nil; Exit(False);
    end;
    Result := True;
  except
    on E: Exception do
    begin
      AErr := 'corrupt or truncated .pbc (' + E.Message + ')';
      if AProg <> nil then begin AProg.Free; AProg := nil; end;
      Result := False;
    end;
  end;
end;

end.
