{******************************************************************************
  probe_bytecode -- a Pascal test of the .pbc on-disk bytecode (phase-3 step 4)

  Compiles a source to bytecode in memory, reads it back, and asserts that running
  the bytecode produces BYTE-IDENTICAL output to running the source directly -- the
  proof that serialization loses nothing. Then it corrupts the version byte and the
  magic and asserts each is REFUSED OUT LOUD (a non-zero result with a message), the
  guard the frozen format exists to provide.

  Prints "ok: N" / "fail: M" and exits non-zero on any failure. Run with --fail to
  corrupt one expectation and confirm the check can fail.
******************************************************************************}
program probe_bytecode;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  Classes, SysUtils, Math,
  PhosphorValue, PhosphorErrors, PhosphorOpcodes, PhosphorCompiler,
  PhosphorBytecode, PhosphorEngine, PhosphorVM, PhosphorRegistry;

type
  TCollector = class
    Text: String;
    procedure Output(const AText: String);
  end;

procedure TCollector.Output(const AText: String);
begin
  Text := Text + AText;
end;

var
  Ok: Integer = 0;
  Failed: Integer = 0;
  ProveFail: Boolean = False;

procedure Report(Pass: Boolean; const Name: String);
begin
  if Pass then Inc(Ok)
  else begin Inc(Failed); Writeln(StdErr, 'FAIL: ', Name); end;
end;

{ Compile ASource and serialize it to a rewound byte stream. }
function CompileToBytes(const ASource: String): TBytesStream;
var
  comp: TPhosphorCompiler;
  prog: TProgram;
begin
  Result := nil;
  comp := TPhosphorCompiler.Create();
  try
    if not comp.Compile(ASource, prog) then Exit;
  finally
    comp.Free;
  end;
  Result := TBytesStream.Create();
  WriteProgram(Result, prog);
  prog.Free;
  Result.Position := 0;
end;

function RunSource(const ASource: String): String;
var eng: TPhosphorEngine; col: TCollector;
begin
  eng := TPhosphorEngine.Create();
  col := TCollector.Create();
  try
    eng.OnOutput := @col.Output;
    eng.Run(ASource);
    Result := col.Text;
  finally
    eng.Free; col.Free;
  end;
end;

function RunBytes(AStream: TStream; out ARc: Integer; out AMsg: String): String;
var eng: TPhosphorEngine; col: TCollector;
begin
  eng := TPhosphorEngine.Create();
  col := TCollector.Create();
  try
    eng.OnOutput := @col.Output;
    AStream.Position := 0;
    ARc := eng.RunBytecode(AStream);
    AMsg := eng.ErrorMessage;
    Result := col.Text;
  finally
    eng.Free; col.Free;
  end;
end;

procedure CheckRoundTrip(const AName, ASource: String);
var bytes: TBytesStream; fromSrc, fromBc, msg: String; rc: Integer;
begin
  fromSrc := RunSource(ASource);
  bytes := CompileToBytes(ASource);
  if bytes = nil then begin Report(False, AName + ' (compiled)'); Exit; end;
  try
    fromBc := RunBytes(bytes, rc, msg);
    Report((rc = 0) and (Length(fromSrc) > 0) and (fromSrc = fromBc) and (not ProveFail), AName);
  finally
    bytes.Free;
  end;
end;

procedure CheckRefusal(const AName, ASource: String; ACorruptAt: Integer; ANewByte: Byte);
var bytes: TBytesStream; msg, dummy: String; rc: Integer;
begin
  bytes := CompileToBytes(ASource);
  if bytes = nil then begin Report(False, AName + ' (compiled)'); Exit; end;
  try
    bytes.Bytes[ACorruptAt] := ANewByte;   // sabotage one header byte
    dummy := RunBytes(bytes, rc, msg);
    // refused (non-zero) with a message, and no output was produced
    Report((rc <> 0) and (Length(msg) > 0) and (dummy = ''), AName);
  finally
    bytes.Free;
  end;
end;

{ Corrupt the INSTRUCTION SECTION and assert the load is refused.

  AMode 0 replaces the first instruction's opcode with one this build does not
  have; AMode 1 finds the first opPushConst and points its operand far past the
  constant pool -- the exact edit that used to be an access violation, because the
  pool is indexed without a check while running.

  The bytes are COPIED OUT, mutated, and handed back as a fresh stream: writing
  through TBytesStream.Bytes did not stick here, and a test whose sabotage silently
  fails is a test that passes for the wrong reason. Finding the right INSTRUCTION
  matters for the same reason -- the first one is an opStmt, whose operand no
  validator has any business checking. }
procedure CheckBodyRefusal(const AName, ASource: String; AMode: Integer;
                           const AWantInMsg: String = '';
                           AMaxCommitKB: Int64 = 0);
var
  src, bad: TBytesStream; buf: TBytes; msg, dummy: String;
  rc, vc, first, n, k, o, ltc: Integer;
  heapBefore, grewKB: Int64;
begin
  src := CompileToBytes(ASource);
  if src = nil then begin Report(False, AName + ' (compiled)'); Exit; end;
  try
    SetLength(buf, src.Size);
    src.Position := 0;
    if src.Size > 0 then src.ReadBuffer(buf[0], src.Size);
  finally
    src.Free;
  end;
  // magic(3) version(1) opcodeset(1) varcount(4) vartypes(vc) instrcount(4)
  vc := PLongInt(@buf[5])^;
  n := PLongInt(@buf[5 + 4 + vc])^;
  first := 5 + 4 + vc + 4;              // each instruction: op(1) A(4) B(4) line(4)
  if AMode = 0 then
    buf[first] := 200                    // an opcode this build does not have
  else if AMode = 1 then
  begin
    for k := 0 to n - 1 do
    begin
      o := first + k * 13;
      if buf[o] = Ord(opPushConst) then
      begin
        PLongInt(@buf[o + 1])^ := 16777216;
        Break;
      end;
    end;
  end
  else
  begin
    { Modes 2..9 corrupt the USER-FUNCTION TABLE, which lives at the end of the
      file: after each name come three LongInts -- entry, parameter count, local
      count -- then one type byte per local slot and one for the return type. The
      table is found by its name bytes rather than by walking every preceding
      section, which keeps this probe readable and independent of the const/data
      layout.

      MODES 4..9 ARE THE SIBLINGS OF MODES 2 AND 3, and they were missed the
      first time round because the enumeration stopped at the two fields a report
      had named. Every OTHER count in ReadProgram is bounded by MaxSaneCount and
      every other enum byte is range-checked; the local table's count and its two
      kinds of type byte were neither. Measured on the pristine reader
      (2026-09-07, peak heap during the load, from GetFPCHeapStatus):

        mode 4  ltc = 2,000,000,000   committed 7.45 GB before the read failed
        mode 5  ltc = MaxInt          committed 8.00 GB
        mode 6  local type byte 200   LOADED CLEANLY, TVarType(200) in the program
        mode 7  return type byte 200  LOADED CLEANLY, RetType = 200
        mode 8  name length 2e9       committed 1.86 GB inside RStr
        mode 9  name length -1        committed 128 MB, then a range-check error

      All eight now cost 10-70 KB and are refused with a message that names the
      function and the slot.

      Mode 2 zeroes the LOCAL count of a function that takes a parameter. That
      combination was an out-of-bounds WRITE, not merely a bad read: opCall
      resolves by name and arity, so the call matched, the frame was then sized
      from the (now empty) local table, and the argument was written into it. On
      Windows it surfaced as an access violation and -- in a binary that links the
      LCL -- a modal dialog nobody was there to click.

      Mode 3 makes the parameter count negative, the same table read the other way
      round. }
    { BACKWARDS. The name 'dbl' is in the file TWICE: once in the constant pool,
      because the call site stores the callee's name as a constant, and once in
      the function table. The pool is written first, so a forward search corrupts
      four bytes of a string constant and the function table is left untouched --
      the file then loads and runs, the check still reports a refusal because the
      output no longer matches, and nothing is being tested. Found by neutralising
      the validator and watching the check stay green anyway. }
    for k := Length(buf) - 4 downto 0 do
      if (buf[k] = Ord('d')) and (buf[k + 1] = Ord('b')) and (buf[k + 2] = Ord('l')) then
      begin
        o := k + 3;                       // just past the name: entry, pcount, ltc
        ltc := PLongInt(@buf[o + 8])^;    // as written, before any sabotage
        case AMode of
          2: PLongInt(@buf[o + 8])^ := 0;           // no locals, though it has a parameter
          3: PLongInt(@buf[o + 4])^ := -1;          // a negative parameter count
          4: PLongInt(@buf[o + 8])^ := 2000000000;  // an absurd local count
          5: PLongInt(@buf[o + 8])^ := MaxInt;      // the very top of the field
          6: buf[o + 12] := 200;                    // a local slot's TYPE byte
          7: buf[o + 12 + ltc] := 200;              // the RETURN type byte
          // The 4 bytes just BEFORE the name are RStr's length field. A string
          // length is not a count of entries, so no MaxSaneCount ever applied.
          8: PLongInt(@buf[o - 7])^ := 2000000000;
          9: PLongInt(@buf[o - 7])^ := -1;
          { MODE 10 -- THE ENTRY FIELD, SET TO ONE PAST THE LAST INSTRUCTION.

            The other nine modes make a file that is refused or that crashes.
            This one made a file that RAN, printed nothing, and exited 0.
            Valid instruction indices are 0..n-1, and the bound was written
            `Entry > AProg.Count` -- inclusive, so Entry = n slipped through.
            That form is right for a JUMP target eleven lines above it, where
            pc = Count is how a compiler spells "the program ends"; for a
            function entry it means the call pushes a frame, jumps past the
            last instruction, the dispatch loop stops, and everything after
            the call is abandoned while Run still answers True.

            Measured on the pristine loader 2026-09-10: WithFunc, whose only
            output is one println of dbl(21), loaded cleanly and printed
            nothing with rc = 0. No message, no trace, no exit code -- the one
            outcome this whole validator exists to prevent. }
          10: PLongInt(@buf[o])^ := n;
        end;
        Break;
      end;
  end;
  bad := TBytesStream.Create(buf);
  try
    heapBefore := GetFPCHeapStatus.MaxHeapUsed;
    dummy := RunBytes(bad, rc, msg);
    grewKB := (Int64(GetFPCHeapStatus.MaxHeapUsed) - heapBefore) div 1024;
    { REFUSED, not merely "did not run". `rc <> 0` on its own was too weak: a
      corrupt file that drove the VM into an access violation also fails to run,
      also sets a message, and also printed nothing -- so the check passed while
      the interpreter was crashing, which is the one outcome it exists to forbid.
      Demonstrated on 2026-09-06 by neutralising the validator and watching all
      eight checks stay green. The message has to say the LOADER refused it.
      The word is 'corrupt' rather than the full 'corrupt .pbc' because a file can
      be refused by two honest routes -- the validator's own message, and the
      stream reader when a bad length makes the next field unreadable. A negative
      parameter count takes the second route. Both are the LOADER saying no; an
      access violation is not, and says nothing of the kind. }
    Report((rc <> 0) and (dummy = '') and (Pos('corrupt', msg) > 0), AName);
    if Pos('corrupt', msg) = 0 then
      Writeln('     (message was: ', msg, ')');
    { AND REFUSED BY THE GUARD THAT IS MEANT TO REFUSE IT. A bad length is
      refused twice over -- once by the bound, and again by the stream reader
      when the next field turns out to be unreadable -- so "it was refused" does
      not distinguish a working bound from a missing one. Neutralising the ltc
      bound left every one of these green (2026-09-07). Naming the guard's own
      words in the message is what separates them. }
    if AWantInMsg <> '' then
    begin
      Report(Pos(AWantInMsg, msg) > 0, AName + ' -- refused by the bound, not by the stream');
      if Pos(AWantInMsg, msg) = 0 then
        Writeln('     (wanted "', AWantInMsg, '" in: ', msg, ')');
    end;
    { AND WITHOUT COMMITTING THE MEMORY THE FILE ASKED FOR, which is the other
      half of what these bounds buy and the half no message can show. On the
      pristine reader these same four files committed between 128 MB and 8 GB
      before failing. MaxHeapUsed is a high-water mark, so the growth across one
      load is a lower bound on what the load actually asked for. }
    if AMaxCommitKB > 0 then
    begin
      Report(grewKB <= AMaxCommitKB,
             AName + ' -- refused without committing the claimed memory');
      if grewKB > AMaxCommitKB then
        Writeln('     (the load grew the heap by ', grewKB, ' KB, budget was ',
                AMaxCommitKB, ' KB)');
    end;
  finally
    bad.Free;
  end;
end;

{ THE VALUE-KIND BYTE, WHICH WAS THE LAST ENUM BYTE IN THE FORMAT WITH NO CASE
  OF ITS OWN HERE.

  Every other enum byte a .pbc carries has been pinned above -- the opcode by
  mode 0, a local slot's type by mode 6, a return type by mode 7 -- and the
  GLOBAL variable type by the loader's own check since the body was first
  distrusted. The one byte none of them covers is the kind tag on a stored
  VALUE, and it is the one that matters most, because it is the only enum byte
  in the file that decides HOW MANY BYTES FOLLOW.

  Before RVal range-checked it (engine/PhosphorBytecode.pas, and the comment
  there records why), an unknown tag answered Default(TValue) and consumed no
  payload, so the file was not refused -- it was silently RE-CUT. Every later
  constant was then decoded out of its predecessor's bytes, the function table
  and the DATA section slid with it, and the program ran to completion, exit 0,
  printing values nobody wrote.

  Re-measured 2026-09-07 by neutralising RVal's range test and NOTHING else, on
  a program of six printlns (no user function, no DATA), poisoning one kind
  byte to 200. Both ends of the pool exit 0:

    the FIRST constant's tag   A0
                               2.35558110889262E-3128.2890460584581E-317
                               B / 222 / C / 333
    the LAST constant's tag    A / 111 / B / 222 / C / 3330

  The second is the reason this case exists. A file that prints one extra digit
  and exits 0 is the worst thing this loader can do, because the host acts on
  the value and nothing anywhere records that a byte was wrong.

  AND THIS IS WHY THE CHECK DEMANDS RVal'S OWN WORDS rather than any refusal.
  With the guard neutralised, Rich -- which the cases below use -- is still
  refused at both ends of its pool, but by an unrelated guard further down the
  file ("function 0 claims 67239936 local slots"), because the re-cut ran on
  into the function table. A case that accepted "it was refused" would have
  stayed green on a reader with no kind check at all. Watched fail, 2026-09-07:
  with the test neutralised all three go red, and the DATA case goes red with
  rc = 0 and an empty message -- the silent form, exactly.

  BOTH POOLS ARE PINNED, and not because the check is written twice: the
  constant pool and the DATA pool are read by the same RVal, so one guard
  serves both. They are here because they are the two SECTIONS whose values an
  attacker can reach, they sit at opposite ends of the file, and a re-cut that
  begins in the DATA section crosses no other section on its way out -- so it
  is the one of the three that still runs to completion, which no constant-pool
  case in this program can show. }

{ The offset of one value's KIND byte, found by WALKING the sections of a
  well-formed .pbc: AWhich 0 = the first constant, 1 = the LAST constant,
  2 = the first DATA item.

  It is a walk and not a number anyone counted, because every value in a pool is
  variable-width -- a string carries a length and its bytes, a bool one byte,
  the other three eight -- so the last constant cannot be reached except by
  decoding every constant before it, and the DATA section cannot be reached
  except across the whole function table. The widths come from the enum's own
  ordinals rather than from literals, so reordering TValueKind moves this walker
  with WVal instead of leaving it silently pointing one field to the left.

  A walker that guessed would poison some OTHER field, and the case would then
  pass on a refusal it did not cause -- the failure CheckBodyRefusal's own
  comment describes. So it answers False rather than an offset it is not sure
  of, and the caller fails the case out loud. }
function ValueKindOffset(const ABuf: TBytes; AWhich: Integer;
                         out AOff: Integer): Boolean;
var
  o, k, n, vc, nc, nf, nd, ltc: Integer;

  function Grab32(out V: Integer): Boolean;
  begin
    Result := (o >= 0) and (o + 4 <= Length(ABuf));
    if Result then begin V := PLongInt(@ABuf[o])^; Inc(o, 4); end;
  end;

  { Step over one serialized value, leaving `o` on the byte after it. }
  function SkipValue: Boolean;
  var kind: Byte; slen: Integer;
  begin
    Result := False;
    if (o < 0) or (o >= Length(ABuf)) then Exit;
    kind := ABuf[o]; Inc(o);
    case kind of
      Ord(vkDouble), Ord(vkInt), Ord(vkHandle): Inc(o, 8);
      Ord(vkBool):   Inc(o, 1);
      Ord(vkString):
        begin
          if not Grab32(slen) then Exit;
          if slen < 0 then Exit;
          Inc(o, slen);
        end;
    else
      Exit;                          // a kind this build never writes
    end;
    Result := (o >= 0) and (o <= Length(ABuf));
  end;

begin
  Result := False;
  AOff := -1;
  o := 5;                            // magic(3) version(1) opcode-set(1)
  if not Grab32(vc) then Exit;
  if vc < 0 then Exit;
  Inc(o, vc);                        // one type byte per global
  if not Grab32(n) then Exit;
  if (n < 0) or (n > (MaxInt div 13)) then Exit;
  Inc(o, n * 13);                    // op(1) A(4) B(4) line(4)
  if not Grab32(nc) then Exit;
  if nc < 0 then Exit;
  if AWhich <= 1 then
  begin
    for k := 0 to nc - 1 do
    begin
      if ((AWhich = 0) and (k = 0)) or ((AWhich = 1) and (k = nc - 1)) then
      begin
        AOff := o;
        Exit(o < Length(ABuf));
      end;
      if not SkipValue() then Exit;
    end;
    Exit;                            // an empty pool: there is no tag to poison
  end;
  for k := 0 to nc - 1 do
    if not SkipValue() then Exit;
  if not Grab32(nf) then Exit;       // the user-function table
  if nf < 0 then Exit;
  for k := 0 to nf - 1 do
  begin
    if not Grab32(n) then Exit;      // the name's length, then its bytes
    if n < 0 then Exit;
    Inc(o, n);
    Inc(o, 8);                       // entry, parameter count
    if not Grab32(ltc) then Exit;
    if ltc < 0 then Exit;
    Inc(o, ltc);                     // one type byte per local slot
    Inc(o, 1);                       // the return type
  end;
  if not Grab32(nd) then Exit;
  if nd <= 0 then Exit;              // no DATA section to poison
  AOff := o;
  Result := (o >= 0) and (o < Length(ABuf));
end;

{ Poison one value's kind byte and assert the LOADER refused the file.

  The message must carry RVal's own words. "It was refused" is not enough and
  never was: a re-cut file is also refused a moment later, by the stream reader,
  when some field further on turns out to be unreadable -- and that refusal
  happens whether or not the kind byte was ever checked. Naming the guard is
  what separates a working check from a file that fell over on its own, and it
  is the same distinction CheckBodyRefusal draws for the bounded counts. }
procedure CheckValueKindRefusal(const AName, ASource: String; AWhich: Integer);
const
  Want = 'a stored value has kind 200';
var
  src, bad: TBytesStream;
  buf: TBytes;
  msg, dummy: String;
  rc, off: Integer;
begin
  src := CompileToBytes(ASource);
  if src = nil then begin Report(False, AName + ' (compiled)'); Exit; end;
  try
    SetLength(buf, src.Size);
    src.Position := 0;
    if src.Size > 0 then src.ReadBuffer(buf[0], src.Size);
  finally
    src.Free;
  end;
  if not ValueKindOffset(buf, AWhich, off) then
  begin
    Report(False, AName + ' -- the walker did not reach that kind byte');
    Exit;
  end;
  buf[off] := 200;                   // a tag no TValueKind has
  bad := TBytesStream.Create(buf);
  try
    dummy := RunBytes(bad, rc, msg);
    Report((rc <> 0) and (dummy = '') and (Pos(Want, msg) > 0), AName);
    if Pos(Want, msg) = 0 then
      Writeln('     (rc was ', rc, ', message was: ', msg, ')');
  finally
    bad.Free;
  end;
end;

{ ----------------------------------------------------------------------------
  HAND-BUILT .pbc FILES: instructions the compiler never emits.

  Everything above corrupts a COMPILED program, which can only reach the shapes a
  compiler produces. A .pbc is untrusted input, and an attacker writes the bytes
  directly -- so these build a TProgram instruction by instruction, serialize it,
  and load it the way the host would.

  Each of the four below PASSES ValidateProgram and used to kill the interpreter
  once running: exit 3, "unhandled EAccessViolation", nothing a program could
  catch and nothing an embedding host could survive. The loader cannot refuse
  them, because each depends on a fact the file does not contain -- how deep the
  value stack is, or whether an activation frame is live -- so the dispatch loop
  refuses them instead, with the engine's own catchable error. (2026-09-06.)
  ---------------------------------------------------------------------------- }

{ Run a hand-built program and assert it was refused with a catchable engine
  error rather than a trap.

  THE RUN IS WRAPPED. Without the guards these programs took the process down,
  and a probe that dies prints no "ok:/fail:" line at all -- the suite would
  report the crash, but as a probe that "did not build or did not run", which
  says nothing about which case broke. Catching the exception turns the crash
  into a named FAILURE, which is what a regression test owes its reader.

  `rc <> 0` alone would be too weak, for the reason CheckBodyRefusal spells out:
  a crashing run also sets a non-zero code and prints nothing. The message has to
  be the VM's own refusal. }
procedure CheckVmRefusal(const AName: String; AProg: TProgram);
var bytes: TBytesStream; msg, outp: String; rc: Integer;
begin
  bytes := TBytesStream.Create();
  try
    try
      WriteProgram(bytes, AProg);
    finally
      AProg.Free;
    end;
    try
      outp := RunBytes(bytes, rc, msg);
    except
      on E: Exception do
      begin
        Report(False, AName + '  [the VM raised ' + E.ClassName + ': ' + E.Message + ']');
        Exit;
      end;
    end;
    Report((rc <> 0) and (outp = '') and (Pos('corrupt bytecode', msg) > 0), AName);
    if Pos('corrupt bytecode', msg) = 0 then
      Writeln('     (rc was ', rc, ', message was: ', msg, ')');
  finally
    bytes.Free;
  end;
end;

{ The refusal must be CATCHABLE, not merely fatal -- that is the house rule the
  whole class exists to defend (decisions.md: a library fault is an error VALUE,
  never a process death). This program installs an ON ERROR handler, faults, and
  must print from the handler and exit 0. }
procedure CheckVmFaultIsCatchable(const AName: String; AProg: TProgram; const AWant: String);
var bytes: TBytesStream; msg, outp: String; rc: Integer;
begin
  bytes := TBytesStream.Create();
  try
    try
      WriteProgram(bytes, AProg);
    finally
      AProg.Free;
    end;
    try
      outp := RunBytes(bytes, rc, msg);
    except
      on E: Exception do
      begin
        Report(False, AName + '  [the VM raised ' + E.ClassName + ': ' + E.Message + ']');
        Exit;
      end;
    end;
    Report((rc = 0) and (outp = AWant), AName);
    if outp <> AWant then
      Writeln('     (rc was ', rc, ', output was: ', outp, ')');
  finally
    bytes.Free;
  end;
end;

{ DUPN asking for a million values with an empty stack. ValidateProgram checks
  the operand only for a negative, which this is not. }
function ProgDupNUnderflow: TProgram;
begin
  Result := TProgram.Create();
  Result.Emit(opDupN, 1000000, 0, 1);
end;

{ DUP2 with an empty stack. It carries no operand at all, so there is nothing for
  the loader to look at even in principle. }
function ProgDup2Underflow: TProgram;
begin
  Result := TProgram.Create();
  Result.Emit(opDup2, 0, 0, 1);
end;

{ LOADLOCAL in the MAIN BODY, where no frame exists. The unused function is there
  only so the program declares a local and the slot passes the loader's bound
  (which is the widest local table in the file -- see ValidateProgram). }
function ProgLoadLocalNoFrame: TProgram;
begin
  Result := TProgram.Create();
  Result.Emit(opLoadLocal, 0, 0, 1);
  Result.Emit(opHalt, 0, 0, 1);
  Result.Emit(opRetFunc, 0, 0, 2);                            // entry 2: never called
  Result.AddUserFunc('never', 2, 0, [vtNumber], vtNumber);
end;

{ STORELOCAL in the main body: the same missing frame, but a WRITE through it. }
function ProgStoreLocalNoFrame: TProgram;
begin
  Result := TProgram.Create();
  Result.Consts.Add(ValStr('x'));
  Result.Emit(opPushConst, 0, 0, 1);
  Result.Emit(opStoreLocal, 0, 0, 1);
  Result.Emit(opHalt, 0, 0, 1);
  Result.Emit(opRetFunc, 0, 0, 2);                            // entry 3: never called
  Result.AddUserFunc('never', 3, 0, [vtString], vtString);
end;

{ A slot legal for the WIDEST function in the file and wild for the one actually
  running: main calls f, which has one local, and f's body reads slot 4. The
  loader accepts it (a five-local function exists); only the frame knows better. }
function ProgLocalSlotBeyondFrame: TProgram;
begin
  Result := TProgram.Create();
  Result.Consts.Add(ValStr('f'));
  Result.Emit(opCall, 0, 0, 1);
  Result.Emit(opPop, 0, 0, 1);
  Result.Emit(opHalt, 0, 0, 1);
  Result.Emit(opLoadLocal, 4, 0, 2);                          // entry 3: f's body
  Result.Emit(opRetFunc, 0, 0, 2);
  Result.AddUserFunc('f', 3, 0, [vtNumber], vtNumber);
  Result.AddUserFunc('never', 3, 0,
                     [vtNumber, vtNumber, vtNumber, vtNumber, vtNumber], vtNumber);
end;

{ ----------------------------------------------------------------------------
  A .pbc WHOSE VALUE POOLS CARRY WHAT THE INVARIANT FORBIDS.

  Everything above corrupts an INDEX. These corrupt a VALUE: eight bytes that
  RDbl reinterprets as a Double, and that ValidateProgram checked in no way at
  all. PhosphorValue's founding invariant is that no TValue ever holds a
  non-finite Double, and TPhosphorVM.Run cites it as the reason it is safe to
  leave the FPU's INVALID-OPERATION trap unmasked -- so a .pbc was the one input
  that could break the premise the VM runs on.

  The programs below are the two-line BASIC that does it: store the constant,
  then compare it. Before 2026-09-06 the NaN cases were exit 217, "unhandled
  EInvalidOp", past any `on error goto`; the infinity cases were WORSE in a
  quieter way -- they loaded and ran, leaving +/-Inf in a variable for whatever
  touched it next. A packed .exe carries the identical exposure, because its stub
  loads its payload through this same reader.

  One flipped bit is all it takes: 0x7FF8000000000000 differs from an ordinary
  number in its exponent field alone.
  ---------------------------------------------------------------------------- }
function PoisonBits(k: Integer): Double;
var q: QWord;
begin
  case k of
    0: q := QWord($7FF8000000000000);   // a quiet NaN
    1: q := QWord($7FF0000000000000);   // +Infinity
  else q := QWord($FFF0000000000000);   // -Infinity
  end;
  Result := PDouble(@q)^;
end;

{ x = <poison> : if x < 1 then ... -- a store and a compare, nothing else. }
function ProgPoisonConst(k: Integer): TProgram;
begin
  Result := TProgram.Create();
  Result.VarCount := 1;
  SetLength(Result.VarTypes, 1);
  Result.VarTypes[0] := vtNumber;
  Result.Consts.Add(ValDouble(PoisonBits(k)));
  Result.Consts.Add(ValInt(1));
  Result.Emit(opPushConst, 0, 0, 1);
  Result.Emit(opStoreVar, 0, 0, 1);
  Result.Emit(opLoadVar, 0, 0, 2);
  Result.Emit(opPushConst, 1, 0, 2);
  Result.Emit(opLT, 0, 0, 2);
  Result.Emit(opPop, 0, 0, 2);
  Result.Emit(opHalt, 0, 0, 2);
end;

{ The SAME hole through the other door: `data <poison>` / `read x`. The DATA pool
  is written and read by the same WVal/RVal pair, so a checker that swept only
  the constant pool would have left this one open -- which is why the sweep is
  written over both of TProgram's value-bearing members. }
function ProgPoisonData(k: Integer): TProgram;
begin
  Result := TProgram.Create();
  Result.VarCount := 1;
  SetLength(Result.VarTypes, 1);
  Result.VarTypes[0] := vtNumber;
  Result.AddData(ValDouble(PoisonBits(k)));
  Result.Consts.Add(ValInt(1));
  Result.Emit(opReadData, 0, 0, 1);
  Result.Emit(opStoreVar, 0, 0, 1);
  Result.Emit(opLoadVar, 0, 0, 2);
  Result.Emit(opPushConst, 0, 0, 2);
  Result.Emit(opLT, 0, 0, 2);
  Result.Emit(opPop, 0, 0, 2);
  Result.Emit(opHalt, 0, 0, 2);
end;

{ A program the loader must ACCEPT: the same shape, carrying the largest and
  smallest magnitudes a Double has. A refusal here would mean the sweep had been
  written to reject numbers rather than non-numbers, which is the failure that
  mirrors the crash. }
function ProgExtremeButFinite: TProgram;
begin
  Result := TProgram.Create();
  Result.VarCount := 1;
  SetLength(Result.VarTypes, 1);
  Result.VarTypes[0] := vtNumber;
  Result.Consts.Add(ValDouble(1.7976931348623157e308));    // MaxDouble
  Result.Consts.Add(ValDouble(4.9406564584124654e-324));   // the smallest denormal
  Result.Consts.Add(ValDouble(-0.0));                      // negative zero
  Result.Consts.Add(ValStr('finite'));
  Result.AddData(ValDouble(-1.7976931348623157e308));
  Result.Emit(opPushConst, 0, 0, 1);
  Result.Emit(opStoreVar, 0, 0, 1);
  Result.Emit(opPushConst, 1, 0, 1);
  Result.Emit(opStoreVar, 0, 0, 1);
  Result.Emit(opPushConst, 2, 0, 1);
  Result.Emit(opStoreVar, 0, 0, 1);
  Result.Emit(opReadData, 0, 0, 1);
  Result.Emit(opStoreVar, 0, 0, 1);
  Result.Emit(opPushConst, 3, 0, 1);
  Result.Emit(opPrintLn, 0, 0, 1);
  Result.Emit(opHalt, 0, 0, 1);
end;

{ THE OVER-REFUSAL PIN FOR RStr, and the reason its guard is a growth loop and
  not a ceiling.

  RStr used to commit the length a corrupt file CLAIMED before reading a byte of
  it; the obvious fix is MaxSaneCount, the ceiling every count in this reader
  already uses. That fix would refuse this program: a single string constant of
  two hundred thousand characters is unusual, and not corrupt. So the length is
  not capped at all -- the buffer grows to what the stream actually delivers --
  and this exists to prove the growth loop reproduces the string EXACTLY, well
  past the 64 KB first chunk and across two doublings.

  It is checked as a ROUND TRIP rather than by asserting a value, because
  CheckRoundTrip compares running the source with running the bytecode byte for
  byte: a growth loop that dropped a chunk in the middle would keep the length
  right and change the content, and this catches that. The program prints the
  length and both ends of the constant. }
function BigStringSource: String;
var big: String;
begin
  big := StringOfChar('x', 200000);
  big[1] := 'A';
  big[Length(big)] := 'Z';
  Result := 's$ = "' + big + '"' + #10 +
            'println str$(len(s$))' + #10 +
            'println left$(s$, 3)' + #10 +
            'println right$(s$, 3)' + #10 +
            'println str$(len(s$ + s$))' + #10;
end;

{ Refused BY THE LOADER, which is a stronger claim than "did not run": a crash
  also fails to run and also prints nothing. The message must be the loader's
  own, and must name the pool entry so the file can be repaired. }
procedure CheckLoadRefusal(const AName: String; AProg: TProgram; const AWhere: String);
var bytes: TBytesStream; msg, outp: String; rc: Integer;
begin
  bytes := TBytesStream.Create();
  try
    try
      WriteProgram(bytes, AProg);
    finally
      AProg.Free;
    end;
    try
      outp := RunBytes(bytes, rc, msg);
    except
      on E: Exception do
      begin
        Report(False, AName + '  [the load raised ' + E.ClassName + ': ' + E.Message + ']');
        Exit;
      end;
    end;
    Report((rc <> 0) and (outp = '') and (Pos('corrupt .pbc', msg) > 0) and
           (Pos(AWhere, msg) > 0), AName);
    if (Pos('corrupt .pbc', msg) = 0) or (Pos(AWhere, msg) = 0) then
      Writeln('     (rc was ', rc, ', message was: ', msg, ')');
  finally
    bytes.Free;
  end;
end;

{ ...and its mirror: this one must LOAD and RUN. }
procedure CheckLoadAccepted(const AName: String; AProg: TProgram; const AWant: String);
var bytes: TBytesStream; msg, outp: String; rc: Integer;
begin
  bytes := TBytesStream.Create();
  try
    try
      WriteProgram(bytes, AProg);
    finally
      AProg.Free;
    end;
    try
      outp := RunBytes(bytes, rc, msg);
    except
      on E: Exception do
      begin
        Report(False, AName + '  [the load raised ' + E.ClassName + ': ' + E.Message + ']');
        Exit;
      end;
    end;
    Report((rc = 0) and (outp = AWant), AName);
    if (rc <> 0) or (outp <> AWant) then
      Writeln('     (rc was ', rc, ', message was: ', msg, ', output was: ', outp, ')');
  finally
    bytes.Free;
  end;
end;

{ ----------------------------------------------------------------------------
  A COUNT TAKEN FROM AN OPERAND, WHICH IS THEN THE SIZE OF AN ALLOCATION.

  DUPN was given its bound on 2026-09-06 and its three siblings were not. Each of
  these passes ValidateProgram -- which refuses a negative operand and has no
  upper bound to offer, because the only honest one is how deep the value stack
  is, which the file does not say -- and each then sizes an allocation from a
  number the FILE chose.

  THE COUNT BELOW IS DELIBERATELY MODEST, and that is worth explaining, because
  the obvious thing to write is MaxInt. `CALL f, 2 000 000 000` was measured against
  the unfixed VM on 2026-09-06: SetLength did not fail and did not raise. It
  COMMITTED the 96 GB -- the process was observed holding 101,573,304 KB -- and the
  machine paged itself to a standstill until the probe was killed by hand. So the
  worst case is not an EOutOfMemory that reaches the host as "unhandled"; it is a
  denial of service on the box the host runs on, and a regression test must not be
  a way to reproduce that on a developer's machine. A million is already more
  values than any stack in this VM has ever held, which is the whole of what the
  bound claims, and an unfixed VM still fails these checks -- just cheaply, with
  "no function nosuchfunction" or a clean exit 0 where a refusal was required.
  ---------------------------------------------------------------------------- }

{ CALL with an argument count no stack has ever held. B is the count; it sizes the
  argument and kind arrays before a single value is popped.

  Five thousand, not a million, and for a second reason on top of the one above:
  an unfixed VM does not stop at the allocation. It pops the count, fails to
  resolve, and builds the "no function name:kinds" message by concatenating one
  kind letter at a time -- quadratic in the count. At a million the probe was
  still running after seven minutes; it has to FAIL, not hang, or a regression
  stalls the suite instead of reporting itself. The bound being pinned is
  argc <= FSP, and FSP is zero here, so five thousand tests it exactly as well. }
function ProgCallArgcHuge: TProgram;
begin
  Result := TProgram.Create();
  Result.Consts.Add(ValStr('nosuchfunction'));
  Result.Emit(opCall, 0, 5000, 1);
  Result.Emit(opHalt, 0, 0, 1);
end;

{ BREAKPOINT with an operand count no stack has ever held. }
function ProgBreakpointCountHuge: TProgram;
begin
  Result := TProgram.Create();
  Result.Emit(opBreakpoint, 1000000, 0, 1);
  Result.Emit(opHalt, 0, 0, 1);
end;

{ PRINT USING with a value count no stack has ever held. }
function ProgPrintUsingCountHuge: TProgram;
begin
  Result := TProgram.Create();
  Result.Emit(opPrintUsing, 1000000, 0, 1);
  Result.Emit(opHalt, 0, 0, 1);
end;

{ SETERRHANDLER's A MEANS TWO DIFFERENT THINGS, and the loader only ever checks
  one of them.

  B = 0 (`on error goto`) makes A a pc; B = 1 (`on error call`) makes A an index
  into the CONSTANT POOL, where the handler's name is. ValidateProgram checks A
  as a pc in both cases, so this program -- 4001 instructions, one constant, a
  call-mode handler naming "constant" 4000 -- is accepted whole: 4000 is a
  perfectly good pc. The first fault then read Consts.Get(4000), 192 KB past a
  two-element array, and refcounted whatever Str field it landed on.

  The padding is the point: A has to be big enough to be past the pool and small
  enough to be a legal pc, and the loader's one check cannot tell those apart. }
function ProgErrHandlerCallBadConst: TProgram;
var i: Integer;
begin
  Result := TProgram.Create();
  Result.Consts.Add(ValStr('h'));       // the pool holds exactly one entry
  Result.Emit(opSetErrHandler, 4000, 1, 1);   // "call the function named by const 4000"
  Result.Emit(opStmt, 0, 0, 1);
  Result.Emit(opDup2, 0, 0, 1);         // faults, which is what reads the pool
  Result.Emit(opHalt, 0, 0, 1);
  for i := 4 to 4000 do
    Result.Emit(opNop, 0, 0, 1);        // ...so that pc 4000 exists and A passes the loader
end;

{ SETERRHANDLER with a mode that is neither goto (0) nor call (1). B was assigned
  straight into the handler mode and only ever compared against 1, so 7 quietly
  meant "goto" -- with A still read as a pc, and a fault then jumping to it. With
  A = 0 that jump lands back on this very instruction, which re-arms the handler,
  which faults again: the program does not crash, it never ends. }
function ProgErrHandlerBadMode: TProgram;
begin
  Result := TProgram.Create();
  Result.Emit(opSetErrHandler, 0, 7, 1);
  Result.Emit(opHalt, 0, 0, 1);
end;

{ THE VALUE STACK ITSELF IS AN ALLOCATION THE PROGRAM SIZES.

  Every bound above is per-instruction: DUPN copies at most FSP values, CALL pops
  at most FSP. None of them bounds what a LOOP does, and the stack only ever grew.
  This program pushes a thousand values and then runs `DUPN 1000` forever, adding a
  thousand slots a pass, and the array doubles under it until SetLength cannot be
  served -- which, as measured above, is not a clean EOutOfMemory but tens of
  gigabytes of committed memory and a machine that stops responding.

  Push refuses to grow past MaxStackDepth instead, and the refusal is a FATAL
  limit, the same shape as the step and output budgets: `on error` must not be
  able to sit on top of a resource ceiling. So it is not a "corrupt bytecode"
  refusal and does not go through CheckVmRefusal.

  THE STEP BUDGET IS PART OF THE TEST, not scaffolding. It is what makes this
  check safe to run against a VM where the ceiling has been regressed away: 10000
  instructions is roughly 3300 passes, so a broken build stops at 3.3 million
  slots -- 160 MB, a few hundred milliseconds -- and reports the WRONG message
  rather than eating the machine. A correct build needs about 3000 instructions to
  reach the ceiling and so never sees the budget at all. }
function ProgStackGrowsForever: TProgram;
var i: Integer;
begin
  Result := TProgram.Create();
  Result.Consts.Add(ValInt(1));
  for i := 0 to 999 do
    Result.Emit(opPushConst, 0, 0, 1);   // pc 0..999: a thousand values to copy
  Result.Emit(opDupN, 1000, 0, 1);       // pc 1000: +1000 slots
  Result.Emit(opJump, 1000, 0, 1);       // pc 1001: again, for ever
end;

{ Run a hand-built program under a step budget and assert the run stopped with a
  message containing AWant. Used for the fatal LIMIT refusals, which are not
  "corrupt bytecode" and must not be catchable. }
procedure CheckVmLimit(const AName: String; AProg: TProgram; ASteps: Int64;
  const AWant: String);
var
  bytes: TBytesStream; eng: TPhosphorEngine; col: TCollector;
  rc: Integer; msg: String;
begin
  bytes := TBytesStream.Create();
  try
    try
      WriteProgram(bytes, AProg);
    finally
      AProg.Free;
    end;
    eng := TPhosphorEngine.Create();
    col := TCollector.Create();
    try
      eng.OnOutput := @col.Output;
      eng.MaxSteps := ASteps;
      bytes.Position := 0;
      try
        rc := eng.RunBytecode(bytes);
      except
        on E: Exception do
        begin
          Report(False, AName + '  [the VM raised ' + E.ClassName + ': ' + E.Message + ']');
          Exit;
        end;
      end;
      msg := eng.ErrorMessage;
    finally
      eng.Free; col.Free;
    end;
    Report((rc <> 0) and (Pos(AWant, msg) > 0), AName);
    if Pos(AWant, msg) = 0 then
      Writeln('     (rc was ', rc, ', message was: ', msg, ')');
  finally
    bytes.Free;
  end;
end;

{ THE PUBLIC VM ENTRY POINT, not the loader.

  TPhosphorVM.Run(AProg) is public, and an embedder that assembles a TProgram by
  hand -- or a future front end that builds one in memory, as TPhosphorEngine.Run
  already does -- never passes through ReadProgram and so is never validated.
  Every check above goes through RunBytecode and therefore measures the LOADER as
  much as the VM; these four go straight in, which is the only way to reach the
  operand bounds at PUSHCONST, LOADVAR, STOREVAR and CALL. Without them each of
  these programs is an unchecked array read -- and STOREVAR an unchecked WRITE --
  past the end of the constant pool or the globals. }
procedure CheckVmDirect(const AName: String; AProg: TProgram; const AWant: String);
var
  vm: TPhosphorVM; reg: TPhosphorRegistry; col: TCollector; okrun: Boolean; msg: String;
begin
  vm := TPhosphorVM.Create();
  reg := TPhosphorRegistry.Create();
  col := TCollector.Create();
  try
    vm.Registry := reg;
    vm.OnOutput := @col.Output;
    try
      okrun := vm.Run(AProg);
    except
      on E: Exception do
      begin
        Report(False, AName + '  [the VM raised ' + E.ClassName + ': ' + E.Message + ']');
        Exit;
      end;
    end;
    msg := vm.LastError.Message;
    Report((not okrun) and (Pos(AWant, msg) > 0), AName);
    if Pos(AWant, msg) = 0 then
      Writeln('     (ok was ', okrun, ', message was: ', msg, ')');
  finally
    col.Free; reg.Free; vm.Free; AProg.Free;
  end;
end;

function ProgPushConstPastPool: TProgram;
begin
  Result := TProgram.Create();
  Result.Consts.Add(ValInt(1));      // a one-entry pool
  Result.Emit(opPushConst, 4096, 0, 1);
  Result.Emit(opHalt, 0, 0, 1);
end;

function ProgLoadVarPastGlobals: TProgram;
begin
  Result := TProgram.Create();
  Result.VarCount := 1;
  SetLength(Result.VarTypes, 1);
  Result.VarTypes[0] := vtNumber;
  Result.Emit(opLoadVar, 4096, 0, 1);
  Result.Emit(opHalt, 0, 0, 1);
end;

function ProgStoreVarPastGlobals: TProgram;
begin
  Result := TProgram.Create();
  Result.VarCount := 1;
  SetLength(Result.VarTypes, 1);
  Result.VarTypes[0] := vtNumber;
  Result.Consts.Add(ValInt(7));
  Result.Emit(opPushConst, 0, 0, 1);
  Result.Emit(opStoreVar, 4096, 0, 1);   // an unchecked WRITE, not merely a read
  Result.Emit(opHalt, 0, 0, 1);
end;

function ProgCallNamePastPool: TProgram;
begin
  Result := TProgram.Create();
  Result.Consts.Add(ValInt(1));
  Result.Emit(opCall, 4096, 0, 1);       // A names the callee; the pool holds one
  Result.Emit(opHalt, 0, 0, 1);
end;

{ ROUND TWO. A SOURCE program under a step budget, asserted to have stopped on a
  named ceiling. The three structures below need no crafted bytecode at all --
  plain BASIC reaches every one of them -- so they are checked from source, but
  they still belong here rather than in a .bas: a .bas that runs out of memory is
  a machine on its knees, and the runner only asks whether the exit code was
  non-zero, so it would go green either way.

  THE STEP BUDGET IS PART OF THE TEST, exactly as at ProgStackGrowsForever. A
  correct build reaches the GOSUB ceiling in under 4 000 000 instructions and the
  recursion ceiling in under 2 000 000 (measured), so a correct build never sees
  the budget; a build with the ceiling regressed away stops at those counts having
  committed about 8 MB and 66 MB respectively, in milliseconds, and reports the
  WRONG message. }
procedure CheckSourceLimit(const AName, ASource: String; ASteps: Int64;
  const AWant: String);
var
  eng: TPhosphorEngine; col: TCollector; rc: Integer; msg: String;
begin
  eng := TPhosphorEngine.Create();
  col := TCollector.Create();
  try
    eng.OnOutput := @col.Output;
    eng.MaxSteps := ASteps;
    try
      rc := eng.Run(ASource);
    except
      on E: Exception do
      begin
        Report(False, AName + '  [the VM raised ' + E.ClassName + ': ' + E.Message + ']');
        Exit;
      end;
    end;
    msg := eng.ErrorMessage;
    Report((rc <> 0) and (Pos(AWant, msg) > 0), AName);
    if Pos(AWant, msg) = 0 then
      Writeln('     (rc was ', rc, ', message was: ', msg, ')');
  finally
    eng.Free; col.Free;
  end;
end;

{ THE HOST SEAM, which is where the rest of round two lives. docs/embedding.md
  tells a host to Prepare once and then CallFunction per event; everything below
  goes through exactly that pair, because that is the door whose guarantees were
  never the same as Run's. Each check answers a question a .bas cannot ask. }
procedure CheckSeamSurvives(const AName, ASource, AFunc: String;
  const AArg: TValue; const AWantErrPart: String);
var
  eng: TPhosphorEngine; col: TCollector; v: TValue; msg: String;
begin
  eng := TPhosphorEngine.Create();
  col := TCollector.Create();
  try
    eng.OnOutput := @col.Output;
    if eng.Prepare(ASource) <> 0 then
    begin
      Report(False, AName + '  [Prepare failed: ' + eng.ErrorMessage + ']');
      Exit;
    end;
    try
      v := eng.CallFunction(AFunc, [AArg]);
    except
      on E: Exception do
      begin
        Report(False, AName + '  [the VM raised ' + E.ClassName + ': ' + E.Message + ']');
        Exit;
      end;
    end;
    msg := eng.ErrorMessage;
    if AWantErrPart = '' then
      Report(msg = '', AName)
    else
      Report(Pos(AWantErrPart, msg) > 0, AName);
    if (AWantErrPart <> '') and (Pos(AWantErrPart, msg) = 0) then
      Writeln('     (result was ', ValToStr(v), ', message was: ', msg, ')');
  finally
    eng.Free; col.Free;
  end;
end;

{ A host dispatching events: many callbacks that FAIL, then one that cannot. The
  failing ones each used to leave a value on the stack -- CallUserFunc put the
  FRAME level back and not the stack pointer -- so the good one eventually died on
  a ceiling nothing in any script had reached, and stayed dead. 200 000 is far
  short of the 1 048 576 it took to reach the ceiling; what is asserted is that the
  stack does not move at all, which is checked by the good call still working AND
  by the heap not having grown. }
procedure CheckSeamNoLeak(const AName: String; ACount: Integer);
var
  eng: TPhosphorEngine; col: TCollector; v: TValue; i: Integer;
  before, after: PtrUInt; ok: Boolean;
begin
  eng := TPhosphorEngine.Create();
  col := TCollector.Create();
  try
    eng.OnOutput := @col.Output;
    if eng.Prepare(
      'function boom(x) local a'#10 +
      '  a = 1 + nosuchfunction(x)'#10 +
      '  return a'#10 +
      'endfunction'#10 +
      'function fine(x)'#10 +
      '  return x + 1'#10 +
      'endfunction'#10) <> 0 then
    begin
      Report(False, AName + '  [Prepare failed: ' + eng.ErrorMessage + ']');
      Exit;
    end;
    eng.CallFunction('boom', [ValInt(1)]);        // warm the stack to its floor
    before := GetHeapStatus.TotalAllocated;
    for i := 1 to ACount do
      eng.CallFunction('boom', [ValInt(i)]);
    after := GetHeapStatus.TotalAllocated;
    v := eng.CallFunction('fine', [ValInt(41)]);
    // AsDouble, not v.Kind: `x + 1` on an int% argument answers an int%, and a
    // check that insisted on vkDouble failed on the arithmetic rather than on
    // the thing it was written to measure.
    ok := (eng.ErrorMessage = '') and (v.Kind in [vkInt, vkDouble]) and
          (AsDouble(v) = 42.0);
    ok := ok and (after <= before);
    Report(ok, AName);
    if not ok then
      Writeln('     (fine(41) gave ', ValToStr(v), ' err "', eng.ErrorMessage,
              '"; heap ', before, ' -> ', after, ')');
  finally
    eng.Free; col.Free;
  end;
end;

{ The same DUP2 underflow, but with `on error goto` installed: the handler must
  run, print, and the program must finish normally. }
function ProgDup2Caught: TProgram;
begin
  Result := TProgram.Create();
  Result.Consts.Add(ValStr('caught'));
  Result.Emit(opSetErrHandler, 4, 0, 1);                      // handler at pc 4
  Result.Emit(opStmt, 0, 0, 1);
  Result.Emit(opDup2, 0, 0, 1);                               // faults
  Result.Emit(opHalt, 0, 0, 1);
  Result.Emit(opPushConst, 0, 0, 2);                          // pc 4: the handler
  Result.Emit(opPrintLn, 0, 0, 2);
  Result.Emit(opHalt, 0, 0, 2);
end;

{ ROUND THREE. The frame-ceiling refusals; see the comment inside. A procedure
  rather than inline code in the main block because the sources are BUILT with a
  loop, and a program block's variables are globals, which objfpc will not use as
  a for-loop counter. }
procedure CheckFrameSlotLimits;
var
  s: String;
  i: Integer;
begin
    { ROUND THREE. THE OTHER FRAME CEILING, AND THE TWO WAYS A FRAME GETS WIDE.

      Round two enforced ONE number -- a depth of MaxFrameSlots div the widest local
      table in the whole PROGRAM -- and that made an uncalled function's width every
      other function's ceiling: 5 242 slots anywhere in the file refused an unrelated
      depth-200 recursion, and 20 000 `for` loops refused a plain non-recursive chain
      of sixty distinct functions. 60_stack_operands.bas pins that those now run.
      Pinned HERE is the half a .bas cannot pin, because a ceiling is a fatal error
      that ends the file rather than failing an assertion: that the slot budget is
      still enforced, on the frames actually held, by both routes into a frame width.

      Widths are BUILT here rather than written out: 5 000 locals is 30 KB of source,
      and a loop that emits it says what the number is for.

      THE STEP BUDGET IS PART OF THE TEST, as above: each of these reaches its
      ceiling in a few thousand instructions, so a correct build never sees the
      budget, while a build with the slot ceiling regressed away runs to the DEPTH
      ceiling instead and reports the wrong message. }
    s := 'function wide(n) local v1';
    for i := 2 to 5000 do s := s + ',v' + IntToStr(i);
    s := s + #10 + '  if n <= 0 then return 0' + #10 +
         '  return 1 + wide(n - 1)' + #10 + 'endfunction' + #10 +
         'println wide(4000)' + #10;
    CheckSourceLimit('refuse at run time: 5000-local frames past the slot budget',
                     s, 2000000, 'local slot limit exceeded');

    // The same budget reached with no `local` list at all: every `for` loop inside a
    // function allocates a hidden slot (__forN), so 5 000 of them are 5 000 slots.
    // The recursion goes FIRST and the loops sit behind it, unreached: the width is
    // a static property of the body, but running 5 000 loops per frame for 200
    // frames is 5 000 000 instructions and the step budget -- which is here to catch
    // exactly the build that never reaches a ceiling -- would fire first.
    s := 'function wide2(n) local acc' + #10 + '  acc = 0' + #10 +
         '  if n > 0 then return 1 + wide2(n - 1)' + #10;
    for i := 1 to 5000 do
      s := s + '  for j' + IntToStr(i) + ' = 1 to 1' + #10 + '  next' + #10;
    s := s + '  return acc' + #10 + 'endfunction' + #10 +
         'println wide2(4000)' + #10;
    CheckSourceLimit('refuse at run time: 5000 FOR loops past the same budget',
                     s, 2000000, 'local slot limit exceeded');

    { AND THE FRAMES A RETURNED CALL LEAVES BEHIND ARE PART OF THAT BUDGET. A frame's
      Locals array is only replaced when a later call lands on the same index, so a
      wide call made one level SHALLOWER each time strands a wide array at every index
      it used. Counting only the LIVE frames never sees them: with 20 000 locals in
      wide3 this program holds no more than ~20 300 slots live, a fiftieth of the
      budget, and 300 iterations of it held 1 378,7 MB on the build with no ceiling at
      all (measured 2026-09-07, and 1 368,6 MB on a build that counted only the live
      prefix). Counting what is HELD refuses it after ten. }
    s := 'function wide3() local v1';
    for i := 2 to 20000 do s := s + ',v' + IntToStr(i);
    s := s + #10 + '  v1 = 1' + #10 + '  return v1' + #10 + 'endfunction' + #10 +
         'function down(k)' + #10 + '  if k <= 0 then return wide3()' + #10 +
         '  return down(k - 1)' + #10 + 'endfunction' + #10 +
         'for i = 300 to 1 step -1' + #10 + '  x = down(i)' + #10 + 'next' + #10 +
         'println "survived"' + #10;
    CheckSourceLimit('refuse at run time: wide frames left behind by returned calls',
                     s, 2000000, 'local slot limit exceeded');
end;

const
  Rich =
    'data 10, 20, 30'                                          + #10 +
    'function dbl(n)'                                          + #10 +
    '  return n * 2'                                           + #10 +
    'end function'                                             + #10 +
    'for i = 1 to 3'                                           + #10 +
    '  read v'                                                 + #10 +
    '  println "item " + str$(i) + " = " + str$(dbl(v))'       + #10 +
    'next'                                                     + #10 +
    'println "done: " + str$(2 + 3 * 4)'                       + #10;
  Simple = 'println "hello"' + #10 + 'println 42 * 10' + #10;
  { A one-parameter function and NOTHING ELSE after it in the file.
    Rich cannot be used for the user-function modes: WriteProgram puts the
    DATA section AFTER the function table, so zeroing a local count shifts
    the data-count read and the stream reader refuses the file before the
    program is ever built -- the check then passed without the validator
    doing anything, which is how this was found. With no data section the
    corrupt table loads cleanly and reaches the VM, which is the case that
    was an out-of-bounds write. }
  WithFunc =
    'function dbl(n)'          + #10 +
    '  return n * 2'           + #10 +
    'end function'             + #10 +
    'println str$(dbl(21))'    + #10;

begin
  ProveFail := (ParamCount >= 1) and (ParamStr(1) = '--fail');

  CheckRoundTrip('round-trip: a rich program (data/read/func/for/strings)', Rich);
  CheckRoundTrip('round-trip: a simple program', Simple);

  // The header is 3 magic bytes, then version (index 3), then the opcode-set byte.
  CheckRefusal('refuse: a wrong version byte',  Simple, 3, 99);
  CheckRefusal('refuse: a bad magic byte',      Simple, 0, Ord('X'));

  // THE BODY, not only the header. A file whose header is intact and whose body is
  // not is what a truncated download or an edited file looks like, and every count
  // and operand past the header used to be believed: one changed opPushConst
  // operand was an access violation, because the constant pool is indexed without a
  // check while running. These corrupt the FIRST INSTRUCTION's opcode byte and its
  // A operand, at offsets computed from the format rather than guessed.
  CheckBodyRefusal('refuse: an opcode this build does not have', Simple, 0);
  CheckBodyRefusal('refuse: a constant index past the pool', Simple, 1);
  // WithFunc: these two need a program that has a user function and no data.
  CheckBodyRefusal('refuse: a function with no room for its parameter', WithFunc, 2);
  CheckBodyRefusal('refuse: a negative parameter count', WithFunc, 3);
  { The siblings of those two, in the same four fields of the same table. Modes
    6 and 7 LOADED CLEANLY on the pristine reader; 4, 5, 8 and 9 committed
    between 128 MB and 8 GB before failing. See CheckBodyRefusal. }
  CheckBodyRefusal('refuse: an absurd local-slot count', WithFunc, 4,
                   'local slots', 16384);
  CheckBodyRefusal('refuse: a local-slot count of MaxInt', WithFunc, 5,
                   'local slots', 16384);
  CheckBodyRefusal('refuse: a local slot whose type byte is out of range', WithFunc, 6,
                   'local slot 0 has type 200');
  CheckBodyRefusal('refuse: a return type byte out of range', WithFunc, 7,
                   'returns type 200');
  CheckBodyRefusal('refuse: a stored string claiming two billion bytes', WithFunc, 8,
                   'stored string claims', 16384);
  CheckBodyRefusal('refuse: a stored string of negative length', WithFunc, 9,
                   'stored string has length -1', 16384);
  { The tenth field of the same table, and the only one of these that used to
    produce a file that RAN. See mode 10: a function entry is an instruction
    index, so Count is out of range, and the bound said it was in. The message
    is demanded by name because "it was refused" would also be true of a reader
    that refused it for some unrelated reason further down the file. }
  CheckBodyRefusal('refuse: a function entry one past the last instruction',
                   WithFunc, 10, 'starts at instruction');
  { The last enum byte in the format without a case of its own, at both ends of
    the constant pool and in the DATA section. See CheckValueKindRefusal: on the
    pristine reader the second of these printed one wrong digit and exited 0. }
  CheckValueKindRefusal('refuse: the FIRST constant''s kind byte out of range', Rich, 0);
  CheckValueKindRefusal('refuse: the LAST constant''s kind byte out of range', Rich, 1);
  CheckValueKindRefusal('refuse: a DATA item''s kind byte out of range', Rich, 2);

  // HAND-BUILT files that PASS the loader and used to crash the VM once running.
  // Each is refused in the dispatch loop with a catchable engine error instead.
  CheckVmRefusal('refuse at run time: DUPN below the bottom of the stack', ProgDupNUnderflow());
  CheckVmRefusal('refuse at run time: DUP2 below the bottom of the stack', ProgDup2Underflow());
  CheckVmRefusal('refuse at run time: LOADLOCAL with no activation frame', ProgLoadLocalNoFrame());
  CheckVmRefusal('refuse at run time: STORELOCAL with no activation frame', ProgStoreLocalNoFrame());
  CheckVmRefusal('refuse at run time: a local slot past this frame''s locals', ProgLocalSlotBeyondFrame());
  // The three opcodes that size an allocation from an operand, which DUPN's own
  // bound was written for and then not extended to.
  CheckVmRefusal('refuse at run time: CALL with five thousand arguments and an empty stack', ProgCallArgcHuge());
  CheckVmRefusal('refuse at run time: BREAKPOINT with a million operands', ProgBreakpointCountHuge());
  CheckVmRefusal('refuse at run time: PRINT USING with a million values', ProgPrintUsingCountHuge());
  // ...and the operand whose MEANING depends on a second operand the loader
  // never consults.
  CheckVmRefusal('refuse at run time: ON ERROR CALL naming a constant past the pool',
                 ProgErrHandlerCallBadConst());
  CheckVmRefusal('refuse at run time: an ON ERROR mode that is neither goto nor call',
                 ProgErrHandlerBadMode());
  // The stack a loop grows without bound, stopped by a ceiling rather than by the
  // allocator giving up. Fatal, not catchable -- it is a resource limit.
  CheckVmLimit('refuse at run time: a loop that grows the value stack for ever',
               ProgStackGrowsForever(), 10000, 'value stack limit exceeded');
  // ...and the refusal is an ERROR VALUE, which is the whole point.
  CheckVmFaultIsCatchable('catchable: ON ERROR takes the DUP2 refusal and carries on',
                          ProgDup2Caught(), 'caught' + #10);

  { ROUND TWO. THE VALUE STACK WAS NOT THE ONLY STRUCTURE THAT DOUBLED FOR EVER,
    and the other two need no bytecode at all -- three lines of source each.
    Measured against the build that bounded only the value stack: the GOSUB return
    stack reached 1543 MB in 1,3 s and the frame stack 1020 MB in 3,3 s, both still
    doubling. The `goto` control for the first held at 2,7 MB, which is what says
    it is the structure and not incidental allocation. }
  CheckSourceLimit('refuse at run time: GOSUB that never returns',
                   'println "start"' + #10 + '1000 gosub 1000' + #10,
                   4000000, 'GOSUB nesting limit exceeded');
  CheckSourceLimit('refuse at run time: recursion that never returns',
                   'function f(n)' + #10 + '  return f(n + 1)' + #10 +
                   'endfunction' + #10 + 'println f(1)' + #10,
                   2000000, 'call depth limit exceeded');

  CheckFrameSlotLimits();

  { ROUND TWO, THE HOST SEAM. Prepare-then-CallFunction is what docs/embedding.md
    tells a host to use, and three of its guarantees were not Run's.

    (1) The FPU mask that makes overflow report instead of raise was installed by
        Run and RunFrom only, so `x * 10` on 1e308 -- ordinary BASIC arithmetic --
        died with an unhandled EOverflow at exit 217 through this door while
        reporting catchably through the other.
    (2) SafeI32 tested for NaN with `d <> d`, which on x86-64 IS the trap it was
        written to avoid; a host handing a NaN to any classic-I/O opcode killed
        the process. Three of the twelve call sites are checked here.
    (3) A callback that fails left its values on the stack. }
  CheckSeamSurvives('seam: an overflow through CallFunction reports instead of raising',
    'function ovf(x)' + #10 + '  return x * 10' + #10 + 'endfunction' + #10,
    'ovf', ValDouble(1e308), 'floating point overflow');
  CheckSeamSurvives('seam: a NaN into INPUT$ is answered, not raised',
    'function chan(x)' + #10 + '  return len(input$(x))' + #10 + 'endfunction' + #10,
    'chan', ValDouble(Math.NaN), '');
  CheckSeamSurvives('seam: a NaN into EOF is answered, not raised',
    'function eofx(x)' + #10 + '  return eof(x)' + #10 + 'endfunction' + #10,
    'eofx', ValDouble(Math.NaN), 'is not open');
  CheckSeamSurvives('seam: a NaN into CLOSE is answered, not raised',
    'function clo(x)' + #10 + '  close #x' + #10 + '  return 1' + #10 + 'endfunction' + #10,
    'clo', ValDouble(Math.NaN), 'out of range');
  CheckSeamSurvives('seam: a NaN into SEEK is answered, not raised',
    'function sk(x)' + #10 + '  seek #1, x' + #10 + '  return 1' + #10 + 'endfunction' + #10,
    'sk', ValDouble(Math.NaN), 'not open');
  CheckSeamNoLeak('seam: two hundred thousand FAILING callbacks move the value stack not at all',
                  200000);

  { ROUND TWO, THE PUBLIC VM ENTRY POINT. These four go into TPhosphorVM.Run
    directly, past ReadProgram, which is the only way to reach an operand the
    loader would have rejected. See the note at opPushConst in PhosphorVM.pas. }
  CheckVmDirect('refuse at run time: PUSHCONST past the constant pool',
                ProgPushConstPastPool(), 'outside the 1-entry pool');
  CheckVmDirect('refuse at run time: LOADVAR past the declared globals',
                ProgLoadVarPastGlobals(), 'outside the 1 this program declares');
  CheckVmDirect('refuse at run time: STOREVAR past the declared globals',
                ProgStoreVarPastGlobals(), 'outside the 1 this program declares');
  CheckVmDirect('refuse at run time: CALL naming a constant past the pool',
                ProgCallNamePastPool(), 'outside the 1-entry pool');

  { A VALUE the file may not carry, through both pools and for all three
    non-finite bit patterns. Refused at LOAD -- the only place a value can still
    be named by index and the program stopped before it exists. }
  CheckLoadRefusal('refuse: a NaN in the constant pool',
                   ProgPoisonConst(0), 'constant 0');
  CheckLoadRefusal('refuse: +Inf in the constant pool',
                   ProgPoisonConst(1), 'constant 0');
  CheckLoadRefusal('refuse: -Inf in the constant pool',
                   ProgPoisonConst(2), 'constant 0');
  CheckLoadRefusal('refuse: a NaN in the DATA pool',
                   ProgPoisonData(0), 'DATA item 0');
  CheckLoadRefusal('refuse: +Inf in the DATA pool',
                   ProgPoisonData(1), 'DATA item 0');
  CheckLoadRefusal('refuse: -Inf in the DATA pool',
                   ProgPoisonData(2), 'DATA item 0');
  { AND THE MIRROR, which matters as much: the finite values NEAREST the edge --
    MaxDouble, the smallest denormal, negative zero -- must still load and run.
    A sweep that rejected these would be a worse bug than the crash it replaced. }
  CheckLoadAccepted('accept: MaxDouble, the smallest denormal and -0.0 still load',
                    ProgExtremeButFinite(), 'finite' + #10);
  { The same mirror for the string reader: a 200,000-character constant, far past
    RStr's first chunk, must survive the round trip byte for byte. See
    BigStringSource for why the length field is not capped. }
  CheckRoundTrip('round-trip: a 200,000-character string constant', BigStringSource());

  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed > 0 then Halt(1) else Halt(0);
end.
