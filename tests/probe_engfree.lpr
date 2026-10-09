{******************************************************************************
  probe_engfree -- an engine that is FREED gives back every handle its scripts
  made, and an engine that is freed never takes a handle another engine's
  session still holds.

  docs/embedding.md: `eng.Free; // frees any prepared VM -- and every live
  handle`, and under "Handles are process-wide": "Every Run, RunBytecode,
  Prepare, Finish and Free resets it". A host question, asked from Pascal, so
  the test is a host.

  THE DEFECT (2026-10-09, round 4). Destroy called Finish and ReplReset, and
  each reset the table only if ITS VM existed. A one-shot Run uses a local VM
  that is gone by the time Run returns, so neither ran: the array, dictionary,
  document or buffer the script made outlived the engine -- 915 MB for one
  `dim@(20000000)` after eng.Free -- until some later engine happened to start.
  A host that creates, runs and frees an engine per script kept the last
  script's memory for ever.

  THE FIX IS NOT "RESET IN DESTROY", and cases F and S are why. The table is
  the process's, so a reset in every Destroy would let an engine that never ran
  anything -- the console host builds a throwaway one to read the registry --
  free the live dictionaries of a session another engine is serving. An engine
  now releases the table only while it is still the last engine to have started
  work in it (PhosphorHandles' reset count), so it frees exactly what its own
  scripts made, and nothing that came after another engine took the table.

  THE CASES. "Back" means LiveHandleCount() = 0 and FPC's CurrHeapUsed within
  1 MiB of where it stood before the engine was created.
    A. Run, then Free: back. A script that holds a 1,000,000-element array, a
       dictionary, a JSON document and a buffer, and ends.
    B. A Run that FAULTS after making them: back after Free.
    C. RunBytecode: back after Free.
    D. Prepare + three CallFunctions over the same live dictionary (the
       session works), then Free: back.
    E. Run, then Finish (no Free): back -- Finish is documented to reset.
    F. A session survives an engine that did no work: A prepares, T is created
       and freed, and A's next call still reads its dictionary.
    S. A session survives an engine whose work came BEFORE it: X runs, B
       prepares, X is freed -- and B's next call still reads its dictionary.
    R. A REPL session survives its own Finish (it is not a prepared VM), and
       Free then gives everything back.
    N. A host function that creates, runs and frees an engine of its own in
       the middle of the outer run: the inner engine's Free gives back what it
       made, and the outer Free what the outer script made after it -- the
       table had no owner once the inner one was gone, and the outer run
       adopts it as it ends.
    M. Ten engines in a row, each one-shot over a 1,000,000-element array: the
       heap is back after every Free, not after the next engine's Run.
  Under the defect A, B, C, E, N and M fail (D and R freed through the VM they
  kept); under a reset-in-every-Destroy, F and S fail -- measured both ways on
  2026-10-09.

  Prints "ok: N" / "fail: M" and exits non-zero on any failure. Run with --fail
  to corrupt one expectation and confirm the check can fail.
******************************************************************************}
program probe_engfree;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  Classes, SysUtils, PhosphorValue, PhosphorErrors, PhosphorOpcodes, PhosphorCompiler,
  PhosphorBytecode, PhosphorEngine, PhosphorHandles, PhosphorRegistry;

const
  LF = #10;
  Slack = 1024 * 1024;   // what "back" forgives: allocator bookkeeping, not data
  Makes =
    'a@ = dim@(1000000)' + LF +
    'd@ = dict@()' + LF +
    'd@ = dict_set@(d@, "k", "v")' + LF +
    'j@ = json_parse@("{\"x\": [1, 2, 3]}")' + LF +
    'b@ = buffer_new@(4096)' + LF;
  Faults = Makes + 'z = 0' + LF + 'y = 1 / z' + LF;
  Session =
    'd@ = dict@()' + LF +
    'd@ = dict_set@(d@, "who", "%s")' + LF +
    'a@ = dim@(100000)' + LF +
    'end' + LF +
    'function who$()' + LF +
    '  return dict_get$(d@, "who")' + LF +
    'endfunction' + LF;

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

function HeapNow: PtrUInt;
begin
  Result := GetFPCHeapStatus().CurrHeapUsed;
end;

{ "Back": nothing live, and the heap within Slack of ABase. }
procedure CheckBack(ABase: PtrUInt; const AName: String);
var now: PtrUInt;
begin
  now := HeapNow();
  Report(LiveHandleCount() = 0, AName + ': no live handle (' +
         IntToStr(LiveHandleCount()) + ' live)');
  Report(now <= ABase + Slack, AName + ': the heap is back (' +
         IntToStr((Int64(now) - Int64(ABase)) div 1024) + ' KiB above the base)');
end;

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

procedure CaseA;
var eng: TPhosphorEngine; base: PtrUInt;
begin
  base := HeapNow();
  eng := TPhosphorEngine.Create();
  try
    Report(eng.Run(Makes) = 0, 'A: the script runs (' + eng.ErrorMessage + ')');
    Report(LiveHandleCount() >= 4, 'A: and its handles are live before Free (' +
           IntToStr(LiveHandleCount()) + ')');
    Report(HeapNow() > base + 8 * 1024 * 1024,
           'A: and the array is really on the heap before Free');
  finally
    eng.Free;
  end;
  CheckBack(base, 'A: Run then Free');
end;

procedure CaseB;
var eng: TPhosphorEngine; base: PtrUInt;
begin
  base := HeapNow();
  eng := TPhosphorEngine.Create();
  try
    Report(eng.Run(Faults) = 7, 'B: the script faults on line 7 (' +
           eng.ErrorMessage + ')');
    Report(LiveHandleCount() >= 4, 'B: with its handles live before Free');
  finally
    eng.Free;
  end;
  CheckBack(base, 'B: a faulted Run then Free');
end;

procedure CaseC;
var eng: TPhosphorEngine; base: PtrUInt; bytes: TBytesStream;
begin
  bytes := CompileToBytes(Makes);
  try
    Report(bytes <> nil, 'C: the script compiles to bytecode');
    if bytes = nil then Exit;
    base := HeapNow();
    eng := TPhosphorEngine.Create();
    try
      Report(eng.RunBytecode(bytes) = 0, 'C: the bytecode runs (' + eng.ErrorMessage + ')');
      Report(LiveHandleCount() >= 4, 'C: with its handles live before Free');
    finally
      eng.Free;
    end;
    CheckBack(base, 'C: RunBytecode then Free');
  finally
    bytes.Free;
  end;
end;

procedure CaseD;
var eng: TPhosphorEngine; base: PtrUInt; i: Integer; v: TValue;
begin
  base := HeapNow();
  eng := TPhosphorEngine.Create();
  try
    Report(eng.Prepare(Format(Session, ['D'])) = 0, 'D: the session prepares (' +
           eng.ErrorMessage + ')');
    for i := 1 to 3 do
    begin
      v := eng.CallFunction('who$', []);
      Report(ValToStr(v) = 'D', 'D: call ' + IntToStr(i) + ' reads the session''s dictionary (' +
             ValToStr(v) + ' / ' + eng.ErrorMessage + ')');
    end;
  finally
    eng.Free;
  end;
  CheckBack(base, 'D: a prepared session then Free');
end;

procedure CaseE;
var eng: TPhosphorEngine; base: PtrUInt;
begin
  base := HeapNow();
  eng := TPhosphorEngine.Create();
  try
    Report(eng.Run(Makes) = 0, 'E: the script runs');
    eng.Finish();
    { Measured before Free: the engine object itself is still allocated, which
      is a few KiB and well inside the slack. }
    CheckBack(base, 'E: Run then Finish');
  finally
    eng.Free;
  end;
end;

procedure CaseF;
var a, t: TPhosphorEngine; v: TValue;
begin
  a := TPhosphorEngine.Create();
  try
    Report(a.Prepare(Format(Session, ['A'])) = 0, 'F: A prepares');
    t := TPhosphorEngine.Create();   // an engine that does no work at all
    t.Free;
    v := a.CallFunction('who$', []);
    Report(ValToStr(v) = 'A', 'F: A''s session still reads its dictionary after an ' +
           'idle engine is freed (' + ValToStr(v) + ' / ' + a.ErrorMessage + ')');
  finally
    a.Free;
  end;
  Report(LiveHandleCount() = 0, 'F: and A''s Free gives it back');
end;

procedure CaseS;
var x, b: TPhosphorEngine; v: TValue; want: String;
begin
  want := 'B';
  if ProveFail then want := 'X';    // an answer no correct engine gives
  x := TPhosphorEngine.Create();
  b := TPhosphorEngine.Create();
  try
    Report(x.Run(Makes) = 0, 'S: X runs one-shot');
    Report(b.Prepare(Format(Session, ['B'])) = 0, 'S: B prepares after it');
    x.Free;
    x := nil;
    v := b.CallFunction('who$', []);
    Report(ValToStr(v) = want, 'S: B''s session still reads its dictionary after X, ' +
           'which worked BEFORE it, is freed (' + ValToStr(v) + ' / ' + b.ErrorMessage + ')');
  finally
    x.Free;
    b.Free;
  end;
  Report(LiveHandleCount() = 0, 'S: and B''s Free gives it back');
end;

procedure CaseR;
var eng: TPhosphorEngine; base: PtrUInt; col: TCollector;
begin
  base := HeapNow();
  col := TCollector.Create();
  try
    eng := TPhosphorEngine.Create();
    try
      eng.OnOutput := @col.Output;
      Report(eng.ReplRun('d@ = dict@()') = 0, 'R: line 1');
      Report(eng.ReplRun('d@ = dict_set@(d@, "k", "kept")') = 0, 'R: line 2');
      eng.Finish();     // there is no prepared VM; the REPL session is not one
      Report(eng.ReplRun('print dict_get$(d@, "k")') = 0, 'R: line 3 (' +
             eng.ErrorMessage + ')');
      Report(col.Text = 'kept', 'R: the session''s dictionary survives Finish (' +
             col.Text + ')');
    finally
      eng.Free;
    end;
  finally
    col.Free;
  end;
  CheckBack(base, 'R: a REPL session then Free');
end;

{ A host function that runs a whole engine of its own, inside the outer run. }
function RunInner(const Args: array of TValue; out Err: TPhosphorError): TValue;
var inner: TPhosphorEngine;
begin
  Err := NoError();
  inner := TPhosphorEngine.Create();
  try
    Result := ValInt(inner.Run('q@ = dict@()' + LF + 'q@ = dict_set@(q@, "i", "j")'));
  finally
    inner.Free;
  end;
end;

procedure CaseN;
var eng: TPhosphorEngine; base: PtrUInt;
begin
  base := HeapNow();
  eng := TPhosphorEngine.Create();
  try
    eng.Registry.Add('inner:', @RunInner);
    Report(eng.Run('r = inner()' + LF + Makes) = 0, 'N: the outer run, after the inner one, runs (' +
           eng.ErrorMessage + ')');
    Report(LiveHandleCount() >= 4, 'N: and what it made after the inner engine is live before Free');
  finally
    eng.Free;
  end;
  CheckBack(base, 'N: an engine run from a host function, then the outer Free');
end;

procedure CaseM;
var eng: TPhosphorEngine; base: PtrUInt; i: Integer;
begin
  base := HeapNow();
  for i := 1 to 10 do
  begin
    eng := TPhosphorEngine.Create();
    try
      Report(eng.Run('a@ = dim@(1000000)' + LF + 'a@[1000000] = ' + IntToStr(i)) = 0,
             'M: engine ' + IntToStr(i) + ' runs');
    finally
      eng.Free;
    end;
    CheckBack(base, 'M: after engine ' + IntToStr(i));
  end;
end;

begin
  ProveFail := (ParamCount >= 1) and (ParamStr(1) = '--fail');
  if (ParamCount > 1) or ((ParamCount = 1) and not ProveFail) then
  begin
    Writeln(StdErr, 'probe_engfree: unknown argument ', ParamStr(1));
    Halt(2);
  end;
  { A warm-up: the first engine of a process allocates what every later one
    shares (unit-level tables, the RTL's own caches). The cases measure from
    after it. }
  with TPhosphorEngine.Create() do
  try
    Run('x = 1');
  finally
    Free;
  end;
  ResetHandles();

  CaseA;
  CaseB;
  CaseC;
  CaseD;
  CaseE;
  CaseF;
  CaseS;
  CaseR;
  CaseN;
  CaseM;

  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed > 0 then Halt(1) else Halt(0);
end.
