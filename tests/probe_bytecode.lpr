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
  Classes, SysUtils,
  PhosphorValue, PhosphorErrors, PhosphorOpcodes, PhosphorCompiler,
  PhosphorBytecode, PhosphorEngine;

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
procedure CheckBodyRefusal(const AName, ASource: String; AMode: Integer);
var
  src, bad: TBytesStream; buf: TBytes; msg, dummy: String;
  rc, vc, first, n, k, o: Integer;
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
    { Modes 2 and 3 corrupt the USER-FUNCTION TABLE, which lives at the end of the
      file: after each name come three LongInts -- entry, parameter count, local
      count. The table is found by its name bytes rather than by walking every
      preceding section, which keeps this probe readable and independent of the
      const/data layout.

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
        if AMode = 2 then
          PLongInt(@buf[o + 8])^ := 0     // no locals, though it has a parameter
        else
          PLongInt(@buf[o + 4])^ := -1;   // a negative parameter count
        Break;
      end;
  end;
  bad := TBytesStream.Create(buf);
  try
    dummy := RunBytes(bad, rc, msg);
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
  finally
    bad.Free;
  end;
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

  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed > 0 then Halt(1) else Halt(0);
end.
