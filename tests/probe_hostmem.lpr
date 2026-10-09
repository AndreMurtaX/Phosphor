{******************************************************************************
  probe_hostmem -- MaxMemoryBytes charges a SESSION for what its script adds,
  and not for what the HOST allocates between calls into it.

  docs/embedding.md: "MaxMemoryBytes is measured from where the heap stood when
  the run began, so it bounds what the script adds and not how much your
  application was already holding", and "the ceilings are cumulative over a
  prepared session (Prepare + all its CallFunctions)". Both halves are a host's
  question, asked from Pascal, so the test is a host.

  THE DEFECT (2026-10-09). The VM samples its heap floor once per session
  (TPhosphorVM.Run sets FHeapBase; RunFrom keeps it) and RoomFor charges
  "process heap now minus the floor". Nothing re-sampled between a host's calls,
  so every byte the HOST allocated between two CallFunctions -- or between two
  REPL lines -- was charged to the script: a prepared session whose script
  allocates nothing was refused with "memory limit exceeded" on its third call,
  because the host had built 12 MB of its own data in between.

  THE FIX IS NOT A RE-BASE, and the second half of this probe is why. Re-sampling
  the floor at each call would forgive the script everything it already holds,
  and a script could then take any amount of memory by splitting the work across
  calls -- the ceiling would be per call, which the docs say it is not. What the
  VM does instead is the debug seam's rule one level up: the heap is marked when
  a host-initiated execution ends and read when the next one begins, and the
  floor moves UP by what grew in between, while no script code ran.

  THE CASES. Ceiling 8 MiB (8388608 bytes). The host allocates 4 MiB before
  every call, 24..40 MiB in all, and holds it.
    A. a script that allocates nothing, six calls: all six must succeed.
    B. a script that keeps one more 1,000,000-byte string per call, with the
       host allocating nothing: refused on the call that takes it past 8388608
       bytes -- the ninth by arithmetic (9,000,000 > 8,388,608 > 8,000,000), and
       the probe accepts the 7th to 10th, for the allocator's own overhead.
    C. B with the host's 4 MiB before every call: refused at the SAME call as B
       would be (7th to 10th) -- the host's bytes are not the script's, and the
       script's bytes still accumulate. Under the defect it is refused on call 2
       or 3; under a re-base it is never refused.
    R. C through the REPL door (ReplRun), one line per call.
  And a check that the host's GetMem really moved the heap figure the VM reads,
  so case A cannot pass by measuring nothing.

  Prints "ok: N" / "fail: M" and exits non-zero on any failure. Run with --fail
  to corrupt one expectation and confirm the check can fail.
******************************************************************************}
program probe_hostmem;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  SysUtils, PhosphorErrors, PhosphorEngine, PhosphorValue;

const
  LF = #10;
  Ceiling = 8 * 1024 * 1024;
  HostBlock = 4 * 1024 * 1024;
  MaxCalls = 12;

var
  Ok: Integer = 0;
  Failed: Integer = 0;
  ProveFail: Boolean = False;
  Blocks: array of Pointer;

procedure Report(Pass: Boolean; const Name: String);
begin
  if Pass then Inc(Ok)
  else begin Inc(Failed); Writeln(StdErr, 'FAIL: ', Name); end;
end;

{ The host's own allocation between calls: 4 MiB, kept until the end. }
procedure HostAllocates;
var p: Pointer;
begin
  GetMem(p, HostBlock);
  FillChar(p^, HostBlock, 1);
  SetLength(Blocks, Length(Blocks) + 1);
  Blocks[High(Blocks)] := p;
end;

procedure HostFrees;
var i: Integer;
begin
  for i := 0 to High(Blocks) do FreeMem(Blocks[i]);
  Blocks := nil;
end;

const
  NoAlloc =
    'function f()' + LF +
    '  return len("abc")' + LF +
    'endfunction' + LF;
  Grows =
    'keep@ = sdim@(50)' + LF +
    'k = 0' + LF +
    'function grow()' + LF +
    '  k = k + 1' + LF +
    '  keep@[k] = string$(1000000, 65)' + LF +
    '  return k' + LF +
    'endfunction' + LF;

{ Prepare AScript, then call AFunc up to MaxCalls times (the host allocating
  before each when AHost). Answers the 1-based call that was refused with
  peLimit, 0 if none was, or -1 if a call failed any other way. }
function FirstRefusal(const AScript, AFunc: String; AHost: Boolean): Integer;
var
  eng: TPhosphorEngine;
  i: Integer;
begin
  Result := 0;
  eng := TPhosphorEngine.Create();
  try
    eng.MaxMemoryBytes := Ceiling;
    if eng.Prepare(AScript) <> 0 then
    begin
      Writeln(StdErr, '  (Prepare failed: ', eng.ErrorMessage, ')');
      Exit(-1);
    end;
    for i := 1 to MaxCalls do
    begin
      if AHost then HostAllocates();
      eng.CallFunction(AFunc, []);
      if eng.LastError.Code = peLimit then Exit(i);
      if eng.LastError.Code <> peNone then
      begin
        Writeln(StdErr, '  (call ', i, ' failed: ', eng.ErrorMessage, ')');
        Exit(-1);
      end;
    end;
  finally
    eng.Free;
    HostFrees();
  end;
end;

{ The same through the REPL: one session, one line per "call". }
function FirstReplRefusal(AHost: Boolean): Integer;
var
  eng: TPhosphorEngine;
  i: Integer;
begin
  Result := 0;
  eng := TPhosphorEngine.Create();
  try
    eng.MaxMemoryBytes := Ceiling;
    if (eng.ReplRun('keep@ = sdim@(50)') <> 0) or (eng.ReplRun('k = 0') <> 0) then
    begin
      Writeln(StdErr, '  (REPL setup failed: ', eng.ErrorMessage, ')');
      Exit(-1);
    end;
    for i := 1 to MaxCalls do
    begin
      if AHost then HostAllocates();
      eng.ReplRun('k = k + 1 : keep@[k] = string$(1000000, 65)');
      if eng.LastError.Code = peLimit then Exit(i);
      if eng.LastError.Code <> peNone then
      begin
        Writeln(StdErr, '  (line ', i, ' failed: ', eng.ErrorMessage, ')');
        Exit(-1);
      end;
    end;
  finally
    eng.Free;
    HostFrees();
  end;
end;

var
  before: PtrUInt;
  r, lo: Integer;

begin
  ProveFail := (ParamCount >= 1) and (ParamStr(1) = '--fail');
  if (ParamCount > 1) or ((ParamCount = 1) and not ProveFail) then
  begin
    Writeln(StdErr, 'probe_hostmem: unknown argument ', ParamStr(1));
    Halt(2);
  end;
  lo := 7;
  if ProveFail then lo := 11;          // a window no correct engine lands in

  { The measurement is real: the figure RoomFor reads moves with a host GetMem. }
  before := GetFPCHeapStatus().CurrHeapUsed;
  HostAllocates();
  Report(GetFPCHeapStatus().CurrHeapUsed >= before + HostBlock,
         'a host GetMem of 4 MiB moves CurrHeapUsed by at least 4 MiB');
  HostFrees();

  r := FirstRefusal(NoAlloc, 'f', True);
  Report(r = 0, 'A: a script that allocates nothing survives 12 calls with the ' +
         'host adding 4 MiB before each (refused at call ' + IntToStr(r) + ')');

  r := FirstRefusal(Grows, 'grow', False);
  Report((r >= lo) and (r <= 10), 'B: a script keeping 1,000,000 more bytes per ' +
         'call is refused at call 7..10 of an 8 MiB ceiling (refused at call ' +
         IntToStr(r) + ')');

  r := FirstRefusal(Grows, 'grow', True);
  Report((r >= lo) and (r <= 10), 'C: the same with the host adding 4 MiB before ' +
         'each call is refused at call 7..10 too (refused at call ' + IntToStr(r) + ')');

  r := FirstReplRefusal(True);
  Report((r >= lo) and (r <= 10), 'R: the same through ReplRun, one line per ' +
         'call, is refused at line 7..10 (refused at line ' + IntToStr(r) + ')');

  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed > 0 then Halt(1) else Halt(0);
end.
