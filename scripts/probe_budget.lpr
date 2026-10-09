{******************************************************************************
  probe_budget -- the execution ceilings, INSIDE a library call

  MIT License. Copyright (c) 2026 Andre Murta.

  probe_limits proves the three ceilings work BETWEEN instructions. This proves
  they work inside one, which is where they did not: a library call is a single
  opCall, so until engine/PhosphorBudget.pas existed a host that set MaxSteps,
  TimeoutMs and MaxOutputBytes exactly as docs/embedding.md prescribes still
  waited for ever on one regex, one string$ or one pause.

  It is a PASCAL probe for the same reason probe_limits is: ceilings are set by
  the embedder on TPhosphorEngine, and a .bas file run by the byte-exact suite
  runner sets none.

  THREE THINGS ARE ASSERTED, and the third matters as much as the first two:

    1. THE FAULTS. Each named runaway is refused, and refused QUICKLY -- every
       check is timed, and a check that takes longer than its ceiling fails even
       if it eventually returns the right code. Without the fix these do not
       return at all, so a timing assertion is the only honest way to state it.

    2. THE LEGITIMATE ANSWERS. string$(1000000) still works and is still fast; a
       regex a real program writes still runs; the pads, dim@, buffer_new@ and
       pause all still do their jobs under a budget. A guard that refuses a
       correct answer is as serious as the crash it replaced.

    3. AN UNBUDGETED HOST IS UNTOUCHED. With no ceilings set, every one of those
       calls -- including the pattern a budgeted host refuses -- behaves exactly
       as it did before this unit existed.

  Prints "ok: N" / "fail: M" and exits non-zero on any failure. Run with --fail
  to corrupt one expectation and confirm the check can fail.
******************************************************************************}
program probe_budget;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  // The generated judge sweep (section h3) runs the real matcher under a
  // WATCHDOG THREAD, because TRegExpr cannot be interrupted: a pattern the judge
  // wrongly allows would otherwise hang the suite instead of failing it. A
  // thread on Linux needs the cthreads manager linked first.
  {$ifdef unix}cthreads,{$endif}
  RegExpr,
  SysUtils, PhosphorErrors, PhosphorEngine, PhosphorBudget,
  // Three OPT-IN packages, registered below: base64_valid is a quadratic-append
  // door of exactly the family this probe pins; gzip_decompressfile is the
  // package door whose refusal used to land AFTER its damage (ledger d14); and
  // the zip extractors trusted an archive's own size claim, or asked nothing
  // (d46, d47). All live in host/packages rather than engine/libs, so a probe
  // that only linked the engine could not reach them. host\packages is already
  // on this probe's unit path.
  Classes, PhosphorBase64Lib, PhosphorGzipLib, PhosphorZipLib;

const
  LF = #10;

var
  Ok: Integer = 0;
  Failed: Integer = 0;
  ProveFail: Boolean = False;
  Captured: String = '';

procedure Report(Pass: Boolean; const Name: String);
begin
  if Pass then Inc(Ok)
  else begin Inc(Failed); Writeln(StdErr, 'FAIL: ', Name); end;
end;

type
  { OnOutput is a method pointer, so the sink is an object -- the same shape
    host/embed/phosphorembed.lpr uses. }
  TSink = class
    procedure Take(const S: String);
  end;

procedure TSink.Take(const S: String);
begin
  Captured := Captured + S;
end;

var
  Sink: TSink;

{ Run ASource with the given ceilings and answer what happened. AElapsed is wall
  clock in ms, so a check can insist the refusal was FAST and not merely correct. }
function RunIt(const ASource: String; ASteps, ATimeoutMs: Int64;
               out ACode: TPhosphorErrorCode; out AMsg: String;
               out AElapsed: Int64): Integer;
var
  eng: TPhosphorEngine;
  t0: QWord;
begin
  Captured := '';
  eng := TPhosphorEngine.Create();
  try
    eng.OnOutput := @Sink.Take;
    RegisterBase64Funcs(eng.Registry);
    RegisterGzipFuncs(eng.Registry);
    RegisterZipFuncs(eng.Registry);
    eng.MaxSteps := ASteps;
    eng.TimeoutMs := ATimeoutMs;
    t0 := GetTickCount64();
    Result := eng.Run(ASource);
    AElapsed := Int64(GetTickCount64() - t0);
    ACode := eng.LastError.Code;
    AMsg := eng.LastError.Message;
  finally
    eng.Free;
  end;
end;

{ THE FAULT SHAPE. Under the ceilings docs/embedding.md prescribes, ASource must
  end with peLimit, and must do it inside AMaxMs. The time bound is not decoration:
  every one of these ran for hours (or for ever) before the budget existed, so a
  check that only asked for the error code would have passed a fix that merely
  made the hang report nicely at the end of it. }
procedure Refused(const AName, ASource: String; AMaxMs: Int64 = 3000);
var
  rc: Integer;
  code: TPhosphorErrorCode;
  msg: String;
  ms: Int64;
begin
  rc := RunIt(ASource, 1000000, 2000, code, msg, ms);
  if ProveFail and (AName = 'string$(1e18) is refused up front') then
  begin
    Report(rc = 0, AName + ' [--fail: expecting the wrong thing on purpose]');
    Exit;
  end;
  Report((rc <> 0) and (code = peLimit) and (ms <= AMaxMs),
         AName + ' (rc=' + IntToStr(rc) + ' code=' + IntToStr(Ord(code)) +
         ' ' + IntToStr(ms) + 'ms: ' + msg + ')');
end;

{ THE LEGITIMATE SHAPE. Under the same ceilings the script must run clean and
  print AWant. }
procedure Allowed(const AName, ASource, AWant: String; AMaxMs: Int64 = 3000);
var
  rc: Integer;
  code: TPhosphorErrorCode;
  msg: String;
  ms: Int64;
begin
  rc := RunIt(ASource, 1000000, 2000, code, msg, ms);
  Report((rc = 0) and (Captured = AWant) and (ms <= AMaxMs),
         AName + ' (rc=' + IntToStr(rc) + ' ' + IntToStr(ms) + 'ms, got "' +
         Copy(Captured, 1, 60) + '" wanted "' + Copy(AWant, 1, 60) + '" ' + msg + ')');
end;

{ THE UNBUDGETED SHAPE. No ceilings at all: the script must run clean and print
  AWant, which is what it printed before PhosphorBudget existed. }
procedure Unbudgeted(const AName, ASource, AWant: String);
var
  rc: Integer;
  code: TPhosphorErrorCode;
  msg: String;
  ms: Int64;
begin
  rc := RunIt(ASource, 0, 0, code, msg, ms);
  Report((rc = 0) and (Captured = AWant),
         AName + ' (rc=' + IntToStr(rc) + ', got "' + Copy(Captured, 1, 60) +
         '" wanted "' + Copy(AWant, 1, 60) + '" ' + msg + ')');
end;

{ THE CEILING SPLIT. The same fault under EACH ceiling on its own, because a
  rule priced against one of them is a rule the other does not have -- which is
  how string$(1e18) survived round one under a time-only budget, allocating two
  gigabytes and answering SUCCESS. }
procedure RefusedUnder(const AName, ASource: String; ASteps, ATimeoutMs: Int64;
                       AMaxMs: Int64 = 3000);
var
  rc: Integer;
  code: TPhosphorErrorCode;
  msg: String;
  ms: Int64;
begin
  rc := RunIt(ASource, ASteps, ATimeoutMs, code, msg, ms);
  Report((rc <> 0) and (code = peLimit) and (ms <= AMaxMs),
         AName + ' (steps=' + IntToStr(ASteps) + ' tmo=' + IntToStr(ATimeoutMs) +
         ' rc=' + IntToStr(rc) + ' code=' + IntToStr(Ord(code)) + ' ' +
         IntToStr(ms) + 'ms: ' + msg + ')');
end;

{ The legitimate answer under a chosen pair of ceilings. }
procedure AllowedUnder(const AName, ASource, AWant: String;
                       ASteps, ATimeoutMs: Int64; AMaxMs: Int64 = 3000);
var
  rc: Integer;
  code: TPhosphorErrorCode;
  msg: String;
  ms: Int64;
begin
  rc := RunIt(ASource, ASteps, ATimeoutMs, code, msg, ms);
  Report((rc = 0) and (Captured = AWant) and (ms <= AMaxMs),
         AName + ' (steps=' + IntToStr(ASteps) + ' tmo=' + IntToStr(ATimeoutMs) +
         ' rc=' + IntToStr(rc) + ' ' + IntToStr(ms) + 'ms, got "' +
         Copy(Captured, 1, 50) + '" wanted "' + Copy(AWant, 1, 50) + '" ' + msg + ')');
end;

{ Run once under explicit ceilings and answer what it printed ('' on failure). }
function RunOne(const ASource: String; ASteps, ATimeoutMs: Int64): String;
var rc: Integer; code: TPhosphorErrorCode; msg: String; ms: Int64;
begin
  rc := RunIt(ASource, ASteps, ATimeoutMs, code, msg, ms);
  if rc = 0 then Result := Captured else Result := '';
end;

{ A PATH A SCRIPT CAN QUOTE. In a BASIC string literal a backslash is an escape,
  so the temp directory goes in with forward slashes, which Windows accepts. }
function ScriptPath(const AName: String): String;
begin
  Result := StringReplace(GetTempDir(False) + AName, '\', '/', [rfReplaceAll]);
end;

{ THE LIE d46 IS ABOUT, made the way an attacker makes it: take a real archive
  and rewrite the uncompressed size in its CENTRAL DIRECTORY -- the field
  TUnZipper.Examine reads and Entries[i].Size reports -- to one byte. The DEFLATE
  stream and the CRC are untouched, so extraction succeeds and produces every
  byte the stream really holds. The central header's signature is PK 1 2 and its
  uncompressed size is the four bytes at offset 24 (APPNOTE 4.3.12). Bytes are
  built with Chr() at run time: under codepage UTF8 a literal would not be one
  byte. Answers False when the archive is not the shape this expects. }
function UnderReport(const APath: String): Boolean;
var fs: TFileStream; s, sig: RawByteString; i, at: Integer;
begin
  Result := False;
  fs := TFileStream.Create(APath, fmOpenReadWrite);
  try
    SetLength(s, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(s[1], fs.Size);
    sig := Chr($50) + Chr($4B) + Chr($01) + Chr($02);
    at := 0;
    for i := 1 to Length(s) - 3 do
      if Copy(s, i, 4) = sig then at := i;
    if (at = 0) or (at + 27 > Length(s)) then Exit;
    s[at + 24] := Chr(1); s[at + 25] := Chr(0);
    s[at + 26] := Chr(0); s[at + 27] := Chr(0);
    fs.Position := 0;
    fs.WriteBuffer(s[1], Length(s));
    Result := True;
  finally
    fs.Free;
  end;
end;

{ The pattern judgement, checked directly, over the shapes real programs write
  and the shapes that blow up. }
procedure Pattern(const APattern: String; AWantBounded: Boolean);
var
  why: String;
  got: Boolean;
begin
  got := BudgetPatternBounded(APattern, why);
  Report(got = AWantBounded,
         'pattern "' + APattern + '" (bounded=' + BoolToStr(got, True) +
         ', wanted ' + BoolToStr(AWantBounded, True) + '; ' + why + ')');
end;

function Repeated(const S: String; N: Integer): String;
var i: Integer;
begin
  Result := '';
  for i := 1 to N do Result := Result + S;
end;

{ ---- THE GENERATED JUDGE SWEEP (2026-10-09, round 2) ----------------------
  Every pin above is a pattern somebody thought of. The round-2 attacker found
  two shapes nobody had -- ^(a*a*b)+$ and ^(ab?|b)+$ -- that the judge ALLOWED
  and TRegExpr ran 2^n, and a list of pins cannot say what it did not think of.
  So this half GENERATES: a grammar over the atoms a, b, c, [ab], [bc], [a-c],
  '.', a hex escape and a capital, the quantifiers ? * + and their lazy
  forms, and five counted forms (SweepQuants spells them), capturing and
  non-capturing groups of one to three branches (an empty one now and then),
  nested three deep, each body placed in one of six repeated forms, one of
  them case-folded. Every
  pattern the judge ALLOWS is then run against the real matcher on hostile
  subjects -- fourteen pump words repeated to 12..48 bytes, then a byte that
  fails -- and must stay under SweepSlowMs on every one of them. The judge's
  answer is never consulted for what is slow: the matcher's clock is the oracle.

  WHY A CLOCK AND A THREAD. TRegExpr has no step hook and no interrupt, so the
  only measure of its work is time, and a wrongly allowed pattern does not
  return at all. The length climbs in steps of four and stops at the first slow
  subject, so a 2^n pattern is caught within a factor of sixteen of the
  threshold; anything that still runs away is caught by the watchdog thread,
  which reports the pattern and ends the run rather than hang the suite.

  AND THE SWEEP IS SEEN FAILING. SweepControl runs four patterns the judge
  must refuse -- the two findings and their siblings -- through the same
  subjects and the same threshold, and demands that they be SLOW. A sweep
  whose subjects could not make a 2^n pattern slow would pass every allowed
  pattern and prove nothing.

  The seed is fixed, so a failure names a pattern that can be re-run. }
var
  WatchStart: QWord = 0;     // GetTickCount64 when the Exec in flight began; 0 = idle
  { What is in flight. The pattern is written by the main thread before the
    worker starts and only read after; the subject is two integers the worker
    writes, never a string, so the watchdog never reads a string mid-write. }
  WatchWhat: String = '';
  WatchWord: Integer = 0;
  WatchLen: Integer = 0;
  SweepSeed: QWord = 20261009;

const
  WatchLimitMs = 4000;       // one Exec past this has run away: report it and stop
  SweepSlowMs = 100;         // an allowed pattern slower than this has failed
  // \x61 is 'a' spelled as the matcher reads it; under (?i) 'A' is 'a' too
  SweepAtoms: array[0..10] of String = ('a', 'b', 'c', 'a', 'b', '[ab]', '[bc]',
                                        '[a-c]', '.', '\x61', 'A');
  // the lazy forms and every counted form on a GROUP compile to OP_LOOP
  SweepQuants: array[0..12] of String = ('', '', '', '?', '*', '+', '{2}',
                                         '{1,2}', '{0,2}', '{2,}', '*?', '+?',
                                         '{1,3}');
  SweepWords: array[0..13] of String = ('a', 'b', 'c', 'ab', 'ba', 'ac', 'bc',
                                        'aab', 'abb', 'abc', 'cab', 'aabb',
                                        'abab', 'abcc');

function Watchdog(P: Pointer): PtrInt;
var started, now: QWord;
begin
  Result := PtrInt(P);
  while True do
  begin
    Sleep(50);
    { The start is read BEFORE the clock. Read after it, a start the worker
      set in between is later than "now", and the unsigned difference wrapped
      to a run of eighteen quintillion milliseconds: two 30000-pattern runs
      reported a hang in patterns that take microseconds. }
    started := WatchStart;
    now := GetTickCount64();
    if (started <> 0) and (now > started) and (now - started > WatchLimitMs) then
    begin
      Writeln(StdErr, 'FAIL: ', WatchWhat, ' on pump word #', WatchWord,
              ' to ', WatchLen, ' bytes -- still inside the matcher after ',
              WatchLimitMs, ' ms: the judge allowed a pattern that does not end');
      Writeln('ok: ', Ok);
      Writeln('fail: ', Failed + 1);
      Halt(1);
    end;
  end;
end;

{ EVERY PATTERN IS MEASURED ON A FRESH THREAD. TRegExpr 0.987 can exhaust the
  stack two ways the sweep reaches: FillFirstCharSet recurses without end at
  COMPILE on a leading group repeated over a body that a count starting at zero
  makes nullable (a group of "a, zero to two times" taken twice), and the
  matcher recurses without end at EXEC on some nested repeats of nullable
  bodies. The first overflow in a thread arrives as EStackOverflow; the SECOND
  in the same thread is an access violation that ends the process, because
  Windows does not re-arm a thread's stack guard page. Both shapes are ones the
  judge refuses when a budget is installed; they are reported separately, as a
  defect of the library call itself, and a sweep that died of one would have
  tested nothing. A fresh thread is a fresh guard page. }
var
  MeasPattern, MeasTail, MeasWorst: String;
  MeasWords: array of String;
  MeasResult: Int64;

var
  MeasDone: Boolean = False;  // the worker reached its end, however it got there

function TimeExec(R: TRegExpr; const ASubject: String; AWord, ALen: Integer;
                  out AFaulted: Boolean): Int64;
var t0: QWord;
begin
  AFaulted := False;
  WatchWord := AWord;
  WatchLen := ALen;
  t0 := GetTickCount64();
  WatchStart := t0;
  try
    try
      R.Exec(ASubject);
    except
      // A stack overflow or an access violation is a fault. Anything else is
      // the engine declining -- 0.987 raises "loop without loop entry" on some
      // counted repeats -- which a script sees as a catchable regex error, and
      // which costs nothing.
      on EStackOverflow do AFaulted := True;
      on EAccessViolation do AFaulted := True;
      on Exception do ;
    end;
  finally
    WatchStart := 0;
  end;
  Result := Int64(GetTickCount64() - t0);
end;

function MeasureOnThread(P: Pointer): PtrInt;
var
  r: TRegExpr;
  w, len: Integer;
  s: String;
  ms: Int64;
  faulted: Boolean;
begin
  Result := PtrInt(P);
  MeasResult := -1;
  MeasWorst := '';
  r := TRegExpr.Create();
  try
    try
      r.Expression := MeasPattern;
      r.Compile;
    except
      Exit;                           // rejected, or overflowed, at compile
    end;
    MeasResult := 0;
    for w := 0 to High(MeasWords) do
    begin
      len := 12;
      while len <= 48 do
      begin
        s := '';
        while Length(s) < len do s := s + MeasWords[w];
        s := s + MeasTail;
        ms := TimeExec(r, s, w, len, faulted);
        if faulted then
        begin
          MeasResult := -2;
          MeasWorst := s;
          Exit;
        end;
        if ms > MeasResult then
        begin
          MeasResult := ms;
          MeasWorst := s;
        end;
        if ms > SweepSlowMs then Exit;
        len := len + 4;
      end;
    end;
  finally
    r.Free;
    MeasDone := True;
  end;
end;

{ The slowest match of APattern over hostile subjects built from AWords: each
  word repeated to 12, 16, ... 48 bytes, then ATail. Answers -1 when TRegExpr
  will not compile the pattern and -2 when the matcher faulted on AWorst.
  Stops at the first slow subject. }
function WorstMs(const APattern: String; const AWords: array of String;
                 const ATail: String; out AWorst: String): Int64;
var
  w: Integer;
  th: TThreadID;
begin
  MeasPattern := APattern;
  WatchWhat := 'pattern "' + APattern + '"';
  MeasDone := False;
  MeasTail := ATail;
  SetLength(MeasWords, Length(AWords));
  for w := 0 to High(AWords) do MeasWords[w] := AWords[w];
  th := BeginThread(@MeasureOnThread);
  WaitForThreadTerminate(th, 0);
  CloseThread(th);
  AWorst := MeasWorst;
  Result := MeasResult;
  // A worker that never reached its end died inside the matcher.
  if not MeasDone then Result := -2;
end;

function SweepRnd(N: Integer): Integer;
begin
  {$push}{$Q-}{$R-}
  SweepSeed := SweepSeed * QWord(6364136223846793005) + QWord(1442695040888963407);
  Result := Integer((SweepSeed shr 33) mod QWord(N));
  {$pop}
end;

function SweepSeq(ADepth: Integer): String; forward;

function SweepItem(ADepth: Integer): String;
var k, alts: Integer;
begin
  if (ADepth < 3) and (SweepRnd(4) = 0) then
  begin
    if SweepRnd(2) = 0 then Result := '(' else Result := '(?:';
    alts := 1 + SweepRnd(3);
    Result := Result + SweepSeq(ADepth + 1);
    for k := 2 to alts do Result := Result + '|' + SweepSeq(ADepth + 1);
    Result := Result + ')';
  end
  else
    Result := SweepAtoms[SweepRnd(Length(SweepAtoms))];
  Result := Result + SweepQuants[SweepRnd(Length(SweepQuants))];
end;

function SweepSeq(ADepth: Integer): String;
var k, cnt: Integer;
begin
  Result := '';
  if (ADepth > 0) and (SweepRnd(12) = 0) then Exit;   // an empty branch
  cnt := 1 + SweepRnd(3);
  for k := 1 to cnt do Result := Result + SweepItem(ADepth);
end;

function SweepPattern: String;
var b: String;
begin
  b := SweepSeq(0);
  case SweepRnd(7) of
    0, 1: Result := '^(' + b + ')+$';
    2:    Result := '^(' + b + ')*$';
    3:    Result := '(' + b + ')+$';          // unanchored: every start position
    4:    Result := '^(?:' + b + '){4}$';     // a counted repeat past the threshold
    5:    Result := '(?i)^(' + b + ')+$';     // case folded: A is a
  else
          Result := '^(' + b + '){2,}c$';
  end;
end;

{ The control: a pattern that MUST be slow on these subjects. }
procedure SweepControl(const APattern: String);
var worst: String; ms: Int64;
begin
  ms := WorstMs(APattern, SweepWords, '!', worst);
  Report(ms > SweepSlowMs, 'sweep control: "' + APattern + '" must be slow on ' +
         'the sweep''s own subjects (worst ' + IntToStr(ms) + ' ms on "' +
         worst + '") -- otherwise the sweep cannot see what it hunts');
end;

procedure JudgeSweep(ACount: Integer);
var
  k, allowed, refused, uncompiled, slow: Integer;
  p, why, worst: String;
  ms, top: Int64;
  topPat: String;
begin
  allowed := 0; refused := 0; uncompiled := 0; slow := 0; top := 0; topPat := '';
  for k := 1 to ACount do
  begin
    p := SweepPattern();
    if not BudgetPatternBounded(p, why) then
    begin
      Inc(refused);
      Continue;
    end;
    ms := WorstMs(p, SweepWords, '!', worst);
    if ms = -1 then
    begin
      Inc(uncompiled);
      Continue;
    end;
    Inc(allowed);
    if ms = -2 then
    begin
      Inc(slow);
      Report(False, 'sweep #' + IntToStr(k) + ': the judge ALLOWED "' + p +
             '" and the matcher overflowed its stack on "' + worst + '"');
      if slow >= 5 then Break;
      Continue;
    end;
    if ms > top then begin top := ms; topPat := p; end;
    if ms > SweepSlowMs then
    begin
      Inc(slow);
      Report(False, 'sweep #' + IntToStr(k) + ': the judge ALLOWED "' + p +
             '" and the matcher took ' + IntToStr(ms) + ' ms on "' + worst + '"');
      if slow >= 5 then Break;               // enough to read; stop the bleeding
    end;
  end;
  Writeln('sweep: ', ACount, ' generated, ', allowed, ' allowed and run, ',
          refused, ' refused, ', uncompiled, ' not compiled by TRegExpr; ',
          'slowest allowed ', top, ' ms ("', topPat, '")');
  Report(slow = 0, 'sweep: every allowed pattern stays under ' +
         IntToStr(SweepSlowMs) + ' ms (' + IntToStr(slow) + ' did not)');
  { BOTH DIRECTIONS. A judge that refused everything would pass the line above
    with nothing run. This grammar is mostly ambiguous by construction -- '.',
    [a-c] and the optional atoms overlap almost everything -- and the judge of
    2026-10-09 allows 564 of the 3000 (19%); the floor is a tenth, far below
    that and far above the zero a refuse-everything judge would score. The
    SAFE CORPUS below is the sharper half of this direction. }
  Report(allowed * 10 >= k, 'sweep: the judge still allows at least a ' +
         'tenth of the generated patterns (' + IntToStr(allowed) + ' of ' +
         IntToStr(k) + ')');
end;

{ THE SAFE CORPUS. Real patterns, the kind a program writes -- paths, CSV,
  IPv4/IPv6/MAC, email, hex colours, base64, escapes, dates, versions, (?i),
  (?x). Each must be ALLOWED, which is the half of the judge's contract that
  refusing too much breaks, and each is also run on hostile subjects, so the
  corpus itself is shown to be safe rather than assumed to be. }
const
  SafeWords: array[0..19] of String = ('a', '1', '.', ':', '-', '/', ',', '"',
                                       '\', 'a.', '1.', 'a:', '1,', 'a ', '%2',
                                       '#', '=', 'aa', '11', 'a1');
  SafeCorpus: array[0..63] of String = (
    '^(/[^/]+)+/?$',
    '^[A-Za-z]:\\(?:[^\\/:*?"<>|\r\n]+\\)*[^\\/:*?"<>|\r\n]*$',
    '^(\.{1,2}/)*([\w.-]+/)*[\w.-]+$',
    '^~?(/[\w.-]+)*/?$',
    '^([^,]*,)*[^,]*$',
    '^("([^"]|"")*"|[^,"]*)(,("([^"]|"")*"|[^,"]*))*$',
    '^(\s*"[^"]*"\s*,)*\s*"[^"]*"\s*$',
    '^(\d+;)*\d+$',
    '^[^\t]*(\t[^\t]*)*$',
    '^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$',
    '^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$',
    '^(\d{1,3}\.){3}\d{1,3}$',
    '^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$',
    '^(([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|' +
      '([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|' +
      '([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|' +
      '([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:(:[0-9a-fA-F]{1,4}){1,6}|' +
      ':((:[0-9a-fA-F]{1,4}){1,7}|:))$',
    '^[0-9a-fA-F:]+$',
    '^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$',
    '^([0-9a-f]{2}:)+[0-9a-f]{2}$',
    '^[0-9A-Fa-f]{4}\.[0-9A-Fa-f]{4}\.[0-9A-Fa-f]{4}$',
    '^[\w.+-]+@[\w-]+(\.[\w-]+)+$',
    '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$',
    '^(\w+\.)*\w+@(\w+\.)+\w+$',
    '^[^@\s]+@[^@\s]+\.[^@\s]+$',
    '^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$',
    '^#?([a-f0-9]{6}|[a-f0-9]{3})$',
    '(?i)^#[0-9a-f]{3,8}$',
    '^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$',
    '^[A-Za-z0-9+/]*={0,2}$',
    '^([A-Za-z0-9_-]{4})*([A-Za-z0-9_-]{2,3})?$',
    '"(?:[^"\\]|\\.)*"',
    '''(?:[^''\\]|\\.)*''',
    '^(?:[^\\]|\\[nrt\\"])*$',
    '\\u[0-9a-fA-F]{4}',
    '^(%[0-9A-Fa-f]{2}|[\w.~-])*$',
    '(?i)^(get|post|put|delete|head|options|patch)$',
    '(?i)^[a-z][a-z0-9_]*$',
    '(?i)^(?:[a-z]+-)*[a-z]+$',
    '(?i)\b(true|false|yes|no)\b',
    '(?x) ^ (\d{4}) - (\d{2}) - (\d{2}) $',
    '(?x) ^ ( [a-z]+ , )* [a-z]+ $',
    '(?x)^\s* (\w+) \s* = \s* (.*?) \s*$',
    '^\d{4}-\d{2}-\d{2}$',
    '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$',
    '^\d{2}:\d{2}(:\d{2})?$',
    '^[a-z0-9]+(?:-[a-z0-9]+)*$',
    '^(\d+\.)+\d+$',
    '^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
    '^https?://[^\s/$.?#].[^\s]*$',
    '^(https?|ftp)://([\w-]+\.)+[\w-]+(/[\w./?%&=-]*)?$',
    '^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$',
    '^-?\d+(,\d{3})*(\.\d+)?$',
    '^\+?\d{1,3}[- ]?\(?\d{3}\)?[- ]?\d{3}[- ]?\d{4}$',
    '^[A-Z]{2}\d{2}[A-Z0-9]{1,30}$',
    '^\d{5}(-\d{4})?$',
    '<[^>]+>',
    '^(<[^>]+>)+$',
    '^\s*#\s*include\s*[<"]([^>"]+)[>"]',
    '^\[([^\]]+)\]$',
    '^([^=]+)=(.*)$',
    '^(\w+)(\.\w+)*$',
    '^[_a-zA-Z][_a-zA-Z0-9]*(::[_a-zA-Z][_a-zA-Z0-9]*)*$',
    '^(\w+\s)*\w+$',
    '^([01]?\d|2[0-3]):[0-5]\d$',
    '^(\$\{[^}]+\}|[^$])*$',
    '^[\w\s,.!?''-]{1,280}$');

procedure SafeCorpusCheck;
var k: Integer; why, worst: String; ms: Int64;
begin
  for k := 0 to High(SafeCorpus) do
  begin
    Report(BudgetPatternBounded(SafeCorpus[k], why),
           'safe corpus: "' + SafeCorpus[k] + '" is allowed (' + why + ')');
    ms := WorstMs(SafeCorpus[k], SafeWords, '!', worst);
    Report((ms >= 0) and (ms <= SweepSlowMs),
           'safe corpus: "' + SafeCorpus[k] + '" compiles and is fast on hostile ' +
           'subjects (' + IntToStr(ms) + ' ms on "' + worst + '")');
  end;
end;

var
  aaa: String;
  remMs: Int64;
  ZipLie, ZipTrue: String;
  ZipOut: array[1..6] of String;
  i: Integer;
begin
  Sink := TSink.Create();
  ProveFail := (ParamCount >= 1) and (ParamStr(1) = '--fail');

  { ---- 1. THE FAULTS ------------------------------------------------------- }

  { The one the whole unit was written for. Forty characters and a nine-character
    pattern: 2^40 attempts inside TRegExpr, which has no step hook, no timeout
    property and no interrupt. Every regex entry point goes through the same
    guard, so all eight are named here rather than the one that was reported. }
  aaa := Repeated('a', 40) + '!';
  Refused('regex_find$ refuses a catastrophic pattern',
          'println regex_find$("(a+)+$", "' + aaa + '")' + LF);
  Refused('regex_findpos refuses it too',
          'println regex_findpos("(a+)+$", "' + aaa + '")' + LF);
  Refused('regex_findlen refuses it too',
          'println regex_findlen("(a+)+$", "' + aaa + '")' + LF);
  Refused('regex_groupcount refuses it too',
          'println regex_groupcount("(a+)+$", "' + aaa + '")' + LF);
  Refused('regex_group$ refuses it too',
          'println regex_group$("(a+)+$", "' + aaa + '", 0)' + LF);
  Refused('regex_findall@ refuses it too',
          'h@ = regex_findall@("(a+)+$", "' + aaa + '")' + LF);
  Refused('regex_groups@ refuses it too',
          'h@ = regex_groups@("(a+)+$", "' + aaa + '")' + LF);
  Refused('regex_split@ refuses it too',
          'h@ = regex_split@("(a+)+$", "' + aaa + '")' + LF);

  { The string builders: a size derivable from the arguments, refused up front. }
  Refused('string$(1e18) is refused up front', 'x$ = string$(1e18, 65)' + LF);
  Refused('mulstring$ over a huge count is refused',
          'x$ = mulstring$("ab", 1e18)' + LF);
  Refused('space$ over a huge count is refused', 'x$ = space$(1e18)' + LF);

  { The pad family: eleven characters of BASIC asking for two gigabytes. }
  Refused('ltab$ to a huge width is refused', 'x$ = ltab$("x", 2e9)' + LF);
  Refused('rtab$ to a huge width is refused', 'x$ = rtab$("x", 2e9)' + LF);
  Refused('lfill$ to a huge width is refused', 'x$ = lfill$("x", 2e9, 46)' + LF);
  Refused('rfill$ to a huge width is refused', 'x$ = rfill$("x", 2e9, 46)' + LF);
  Refused('center$ to a huge width is refused', 'x$ = center$("x", 2e9)' + LF);
  Refused('center$ with a fill char is refused', 'x$ = center$("x", 2e9, 46)' + LF);

  { The containers. }
  Refused('dim@ over a huge count is refused', 'a@ = dim@(500000000)' + LF);
  Refused('buffer_new@ over a huge size is refused', 'b@ = buffer_new@(1000000000)' + LF);
  Refused('buffer_resize over a huge size is refused',
          'b@ = buffer_new@(4)' + LF + 'n = buffer_resize(b@, 1000000000)' + LF);
  Refused('strings_capacity over a huge count is refused',
          'l@ = strings@()' + LF + 'n = strings_capacity(l@, 500000000)' + LF);
  Refused('json_pretty$ with a huge indent is refused',
          'j@ = json_parse@("{""a"":[1,2,3]}")' + LF +
          'println json_pretty$(j@, 1000000000)' + LF);

  { The wait. This is the purest form of the hole: one Sleep inside one opCall.
    It must come back at the TIME ceiling (2000 ms), not 24 days later, so the
    bound here is deliberately just above the ceiling. }
  Refused('pause(1e9) ends at the time ceiling', 'n = pause(1e9)' + LF, 4000);

  { AND THE ESCAPE ATTEMPT, in two halves.

    A budget refusal is an ordinary peLimit return from a library function, and
    TPhosphorVM.Fault offers any error to an installed handler -- so unlike the
    VM's own three ceilings a script CAN catch this one. (Making it fatal is a
    one-line change in Fault, which is in PhosphorVM and outside this lane; see
    the header of engine/PhosphorBudget.pas.) That catchability must not buy the
    script anything, and these two say so.

    FIRST: catching the refusal does not get the WORK. Two thousand retries, every
    one refused in constant time because the budget latches, and the total length
    of everything built is zero. }
  Allowed('catching a refusal builds nothing',
          'on error goto swallow' + LF +
          'n = 0' + LF +
          'for i = 1 to 2000' + LF +
          '  x$ = string$(1e18, 65)' + LF +
          '  n = n + len(x$)' + LF +
          'next' + LF +
          'println n' + LF +
          'end' + LF +
          'swallow:' + LF +
          'resume next' + LF, '0' + LF, 2000);

  { SECOND: retrying is not free either. Faulting, running a handler and resuming
    all cost instructions and wall clock, and BOTH are counted by the VM's own
    ceilings, which are fatal. A script that keeps trying is therefore stopped by
    the ceiling it was trying to get around -- here by the 2000 ms clock, since a
    hundred thousand fault-and-resume cycles take far longer than that. }
  Refused('retrying past the ceilings is still stopped',
          'on error goto swallow' + LF +
          'n = 0' + LF +
          'for i = 1 to 100000' + LF +
          '  x$ = string$(1e18, 65)' + LF +
          '  n = n + 1' + LF +
          'next' + LF +
          'end' + LF +
          'swallow:' + LF +
          'resume next' + LF, 6000);

  { ---- 2. THE LEGITIMATE ANSWERS, under the same ceilings ------------------- }

  { The size the brief names: a million characters must still work, and be fast.
    It is also the case that proves the pricing is not over-eager -- a million
    units against a million-step budget would have refused this if a unit and a
    step were the same thing. }
  Allowed('string$(1000000) still works and is fast',
          'println len(string$(1000000, 65))' + LF, '1000000' + LF, 1500);
  Allowed('space$(1000000) still works',
          'println len(space$(1000000))' + LF, '1000000' + LF, 1500);
  Allowed('mulstring$ at a real size still works',
          'println len(mulstring$("ab", 100000))' + LF, '200000' + LF, 1500);

  { string$ builds by SIZING ONCE now instead of appending; the ANSWER must be
    byte-identical, multi-byte characters included. chr$(233) is C3 A9, so three
    of them are six bytes and three codepoints. }
  Allowed('string$ of a multi-byte codepoint is unchanged',
          'println str$(len(string$(3, 233))) + "/" + str$(bytelen(string$(3, 233)))' + LF,
          '3/6' + LF);
  Allowed('string$ content is unchanged',
          'println string$(4, 65)' + LF, 'AAAA' + LF);
  Allowed('mulstring$ content is unchanged',
          'println mulstring$("ab", 3)' + LF, 'ababab' + LF);
  Allowed('string$ of zero is empty',
          'println "[" + string$(0, 65) + "]"' + LF, '[]' + LF);
  Allowed('string$ of a negative count is empty',
          'println "[" + string$(-5, 65) + "]"' + LF, '[]' + LF);
  Allowed('mulstring$ of an empty string is empty',
          'println "[" + mulstring$("", 1000) + "]"' + LF, '[]' + LF);

  { The patterns a real program writes. }
  { The backslash is the lexer's escape, so a regex class is spelled \\d in a
    BASIC literal -- which is also how docs/libraries/regex.md tells a reader to
    write it. }
  Allowed('a real regex still runs under a budget',
          'println regex_find$("(\\w+)@(\\w+)", "user@host")' + LF, 'user@host' + LF);
  Allowed('regex_findall@ still runs under a budget',
          'h@ = regex_findall@("\\d+", "a1 b22 c333")' + LF +
          'println strings_count(h@)' + LF, '3' + LF);
  Allowed('regex_split@ still runs under a budget',
          'h@ = regex_split@(",", "a,b,c")' + LF +
          'println strings_count(h@)' + LF, '3' + LF);
  Allowed('an anchored date pattern still runs',
          'println regex_findpos("^\\d{4}-\\d{2}-\\d{2}$", "2026-09-06")' + LF, '1' + LF);

  { The pads at real widths. }
  Allowed('ltab$ at a real width still works',
          'println "[" + ltab$("x", 5) + "]"' + LF, '[    x]' + LF);
  Allowed('center$ at a real width still works',
          'println "[" + center$("x", 5) + "]"' + LF, '[  x  ]' + LF);
  Allowed('lfill$ at a real width still works',
          'println "[" + lfill$("x", 5, 46) + "]"' + LF, '[....x]' + LF);
  Allowed('a width below the length is returned unchanged',
          'println "[" + ltab$("hello", 2) + "]"' + LF, '[hello]' + LF);

  { The containers at real sizes. }
  Allowed('dim@ at a real size still works',
          'a@ = dim@(1000)' + LF + 'println ubound(a@, 1)' + LF, '1000' + LF);
  Allowed('buffer_new@ at a real size still works',
          'b@ = buffer_new@(1024)' + LF + 'println buffer_len(b@)' + LF, '1024' + LF);
  Allowed('strings_capacity at a real size still works',
          'l@ = strings@()' + LF + 'println strings_capacity(l@, 100)' + LF, '100' + LF);
  Allowed('json_pretty$ at the default indent still works',
          'j@ = json_parse@("{""a"":1}")' + LF +
          'println len(json_pretty$(j@)) > 0' + LF, 'true' + LF);

  { A real wait still waits, and still returns. }
  Allowed('a short pause still works under a budget',
          'n = pause(0.05)' + LF + 'println n' + LF, '0' + LF);

  { A listing of a directory that exists still lists it. }
  Allowed('a directory listing still works under a budget',
          'println len(dir_getfiles$(".")) >= 0' + LF, 'true' + LF);

  { THE EDGES A GUARD WRITTEN IN A HURRY GETS WRONG. Every one of these is a
    correct answer that a size check could plausibly turn into a refusal or a
    fault: a zero size, a width that exactly equals the length, an indent of
    zero, a shrink rather than a growth, an empty subject, an empty match. They
    are here because "the guard refuses something legitimate" is the other half
    of this work and it does not announce itself. }
  Allowed('space$(0) is still the empty string',
          'println "[" + space$(0) + "]"' + LF, '[]' + LF);
  Allowed('a width that equals the length pads nothing',
          'println "[" + ltab$("hello", 5) + "]"' + LF, '[hello]' + LF);
  Allowed('center$ still splits an odd pad the same way',
          'println "[" + center$("ab", 7, 45) + "]"' + LF, '[--ab---]' + LF);
  { THE NEGATIVE HALF OF THE WIDTH AXIS, which the pad cases above never swept.
    center$ computed `w - CpLen(s)` in 32 bits from a width ArgI32 had saturated
    to Low(Integer), so a huge NEGATIVE width wrapped to a pad of 2147483647: a
    budgeted host refused a call that owed the string back unchanged, and the
    console host, which installs no budget, built a 2 GiB string (ledger d18).
    "Too long for width: returned unchanged" is the documented answer, so that is
    the expectation, for both forms and for the four siblings that compare first. }
  Allowed('center$ at a huge negative width returns the string unchanged',
          'println "[" + center$("abc", -1e18) + "]"' + LF, '[abc]' + LF);
  Allowed('center$ with a fill char at a huge negative width, unchanged too',
          'println "[" + center$("abc", -1e18, 45) + "]"' + LF, '[abc]' + LF);
  Allowed('ltab$ at a huge negative width is unchanged',
          'println "[" + ltab$("abc", -1e18) + "]"' + LF, '[abc]' + LF);
  Allowed('rtab$ at a huge negative width is unchanged',
          'println "[" + rtab$("abc", -1e18) + "]"' + LF, '[abc]' + LF);
  Allowed('lfill$ at a huge negative width is unchanged',
          'println "[" + lfill$("abc", -1e18, 46) + "]"' + LF, '[abc]' + LF);
  Allowed('rfill$ at a huge negative width is unchanged',
          'println "[" + rfill$("abc", -1e18, 46) + "]"' + LF, '[abc]' + LF);
  Allowed('json_pretty$ with an indent of zero still renders',
          'j@ = json_parse@("{""a"":1}")' + LF +
          'println len(json_pretty$(j@, 0)) > 0' + LF, 'true' + LF);
  Allowed('json_pretty$ with a wide indent still renders',
          'j@ = json_parse@("{""a"":[1,2]}")' + LF +
          'println len(json_pretty$(j@, 8)) > 0' + LF, 'true' + LF);
  Allowed('a capacity BELOW the count is still clamped, not refused',
          'l@ = strings@()' + LF + 'n = strings_add(l@, "x")' + LF +
          'println strings_capacity(l@, 0)' + LF, '1' + LF);
  Allowed('buffer_resize down to zero still works',
          'b@ = buffer_new@(8)' + LF + 'println buffer_resize(b@, 0)' + LF, '0' + LF);
  Allowed('a two-dimensional dim@ still works',
          'a@ = dim@(50, 50)' + LF + 'println arraysize(a@)' + LF, '2500' + LF);
  Allowed('pause(0) and pause of a negative are still no-ops',
          'n = pause(0)' + LF + 'm = pause(-1)' + LF + 'println n + m' + LF, '0' + LF);
  Allowed('a regex over an empty subject still answers',
          'println "[" + regex_find$("a+", "") + "]"' + LF, '[]' + LF);
  Allowed('an empty-width match still enumerates',
          'h@ = regex_findall@("a*", "bbb")' + LF +
          'println strings_count(h@)' + LF, '4' + LF);
  Allowed('regex_group$ still answers group 2',
          'println regex_group$("(a)(b)", "ab", 2)' + LF, 'b' + LF);
  Allowed('a recursive directory listing still works',
          'println len(dir_getfiles$("scripts", "*", 1)) > 0' + LF, 'true' + LF);
  Allowed('a thousand pads in a loop are not refused',
          'for i = 1 to 1000' + LF + '  x$ = ltab$("q", 60)' + LF + 'next' + LF +
          'println len(x$)' + LF, '60' + LF);
  Allowed('two hundred regexes in a loop are not refused',
          'for i = 1 to 200' + LF +
          '  x$ = regex_find$("[0-9]+", "ab 1234 cd")' + LF + 'next' + LF +
          'println x$' + LF, '1234' + LF);
  Allowed('two million-character strings in one run are not refused',
          'a$ = string$(1000000, 65)' + LF + 'b$ = string$(1000000, 66)' + LF +
          'println len(a$) + len(b$)' + LF, '2000000' + LF, 1500);

  { A HOST THAT SETS ONE CEILING AND NOT THE OTHER. The size check hangs off
    MaxSteps and the deadline off TimeoutMs, so each has to work on its own. }
  Report(RunOne('println len(string$(1000000, 65))' + LF, 0, 2000) = '1000000' + LF,
         'a time-only budget does not refuse a million-character string');
  Report(RunOne('n = pause(0.05)' + LF + 'println n' + LF, 1000000, 0) = '0' + LF,
         'a step-only budget still allows a short pause');

  { ---- 3. AN UNBUDGETED HOST IS UNTOUCHED ---------------------------------- }
  { With no ceilings set nothing consults anything: BudgetActive is False on the
    first line of every guard. The pattern a budgeted host refuses must therefore
    still RUN here -- on a short subject, so this probe cannot hang proving it. }
  Unbudgeted('an unbudgeted host still runs the refused pattern',
             'println regex_find$("(a+)+$", "aaa")' + LF, 'aaa' + LF);
  Unbudgeted('an unbudgeted host still gets string$',
             'println string$(4, 65)' + LF, 'AAAA' + LF);
  Unbudgeted('an unbudgeted host still gets a big string$ (and gets it fast)',
             'println len(string$(1000000, 65))' + LF, '1000000' + LF);
  Unbudgeted('an unbudgeted host still gets the pads',
             'println "[" + center$("x", 5) + "]"' + LF, '[  x  ]' + LF);
  { THE DOOR d18 ACTUALLY DAMAGED: with no budget, a huge negative width built a
    2 GiB string. Not run against the unrepaired engine, deliberately -- it would
    have allocated those 2 GiB on the machine running the suite; the budgeted
    cases above saw the same wrapped pad (2147483645 units) refused instead. }
  Unbudgeted('an unbudgeted host gets center$ at a huge negative width unchanged',
             'println "[" + center$("abc", -1e18) + "]"' + LF, '[abc]' + LF);
  Unbudgeted('an unbudgeted host still gets dim@',
             'a@ = dim@(1000)' + LF + 'println ubound(a@, 1)' + LF, '1000' + LF);
  Unbudgeted('an unbudgeted host still gets a short pause',
             'n = pause(0.01)' + LF + 'println n' + LF, '0' + LF);
  Unbudgeted('an unbudgeted host still gets a wide json indent',
             'j@ = json_parse@("{""a"":[1,2]}")' + LF +
             'println len(json_pretty$(j@, 8)) > 0' + LF, 'true' + LF);
  Unbudgeted('an unbudgeted host still gets a directory listing',
             'println len(dir_getfiles$("scripts")) > 0' + LF, 'true' + LF);
  Unbudgeted('an unbudgeted host still gets a million-slot capacity',
             'l@ = strings@()' + LF +
             'println strings_capacity(l@, 1000000)' + LF, '1000000' + LF);

  { ---- 4. THE PATTERN JUDGEMENT ITSELF ------------------------------------- }
  { The rule refuses a repeat of a group whose body can match the same text in
    more than one way -- decided exactly since 2026-10-09, see (h3) -- and a
    nest of counted repeats past a million. A malformed pattern is the engine's
    to reject, and is allowed through to it. (a|ab)+ used to be refused here
    for sharing a first byte between its branches; it is a code with one
    reading per subject and moved to (h3), allowed. }
  Pattern('^\d{4}-\d{2}-\d{2}$', True);
  Pattern('(\w+)@(\w+)\.(\w+)', True);
  Pattern('[a-z]+\s*=\s*(.*)', True);
  Pattern('a+', True);
  Pattern('.*', True);
  Pattern('(foo|bar)+', True);
  Pattern('(a|b|c)*', True);
  Pattern('([A-Z]|[a-z])+', True);
  Pattern('(https?|ftp)://\S+', True);
  Pattern('\b\w+\b', True);
  Pattern('(?:abc)+', True);
  Pattern('(?i)hello', True);
  Pattern('colou?r', True);
  Pattern('(ab){3}', True);
  Pattern('([0-9]{1,3}\.){3}[0-9]{1,3}', True);
  Pattern('(\.|\w)+', True);
  Pattern('[^,]*,[^,]*', True);
  Pattern('(?=.*\d)\w+', True);
  Pattern('', True);
  Pattern('(a', True);              // malformed: not ours to judge
  Pattern('[a-z', True);            // the same

  Pattern('(a+)+$', False);
  Pattern('(a*)*', False);
  Pattern('(a+)*b', False);
  Pattern('([a-zA-Z]+)*', False);
  Pattern('(\s*\w+)+$', False);
  Pattern('(\d+|\w+)*', False);
  Pattern('(x+x+)+y', False);
  Pattern('(a{0,2000}){0,2000}', False);
  Pattern('(?:(\w+)\s?)+$', False);

  { ---- ROUND TWO: the siblings the first enumeration missed ---------------- }

  { (0) THE CEILING SPLIT, ASKED OF THE UNIT DIRECTLY. BudgetRemainingMs is the
    only thing standing between a trickling network peer and the interpreter (it
    becomes the socket's IOTimeout), and the first version answered 0 -- "wait for
    ever" -- whenever the host had set no TIME ceiling, so a step-only budget got
    no read timeout at all. A step budget does bound a wait: pause() already
    prices a millisecond at BudgetUnitsPerMs, and the same rate converts what is
    left of the step allowance back into milliseconds. There is no trickling peer
    in a probe, so the unit is asked to its face. }
  BudgetBegin(0, 0);
  Report(BudgetRemainingMs() = 0,
         'BudgetRemainingMs is 0 with no ceiling at all (got ' +
         IntToStr(BudgetRemainingMs()) + ')');
  BudgetEnd;

  BudgetBegin(1000000, 0);
  remMs := BudgetRemainingMs();
  Report(remMs = (Int64(1000000) * BudgetUnitsPerStep) div BudgetUnitsPerMs,
         'a STEP-only budget still bounds a network wait (got ' +
         IntToStr(remMs) + ' ms, wanted ' +
         IntToStr((Int64(1000000) * BudgetUnitsPerStep) div BudgetUnitsPerMs) + ')');
  BudgetEnd;

  BudgetBegin(0, 2000);
  remMs := BudgetRemainingMs();
  Report((remMs > 1900) and (remMs <= 2000),
         'a TIME-only budget bounds it as it always did (got ' +
         IntToStr(remMs) + ' ms)');
  BudgetEnd;

  BudgetBegin(1000000, 2000);
  remMs := BudgetRemainingMs();
  Report((remMs > 1900) and (remMs <= 2000),
         'with BOTH set it is the smaller of the two (got ' + IntToStr(remMs) + ' ms)');
  BudgetEnd;

  { And RULE 1's ceiling, the mirror of the same split: a size test under EACH
    ceiling alone, asked of BudgetAllows directly. }
  BudgetBegin(1000000, 0);
  Report(BudgetAllows(1000000) and (not BudgetAllows(High(Int64) div 2)),
         'BudgetAllows sizes under a step-only budget');
  BudgetEnd;
  BudgetBegin(0, 2000);
  Report(BudgetAllows(1000000) and (not BudgetAllows(High(Int64) div 2)),
         'BudgetAllows sizes under a TIME-only budget too');
  BudgetEnd;
  BudgetBegin(0, 0);
  Report(BudgetAllows(High(Int64) div 2),
         'and with no ceiling at all it allows everything');
  BudgetEnd;


  { (a) THE TREE'S OTHER BACKTRACKING MATCHER. MatchGlob was a recursive star
    backtracker reached two ways -- directly, and from inside a directory walk
    whose per-entry charge is O(1) while the per-entry match was exponential.
    Neither returned inside a 45-second watchdog. Both now answer at once. }
  Allowed('path_matchespattern survives twenty stars',
          'n$ = string$(40, 97)' + LF +
          'p$ = mulstring$("*a", 20) + "*b"' + LF +
          'println path_matchespattern(n$, p$)' + LF, '0' + LF, 1000);
  Allowed('path_matchespattern still matches what it should',
          'println path_matchespattern("README.TXT", "*.txt")' + LF, '1' + LF);
  Allowed('and still says no when it should',
          'println path_matchespattern("README.TXT", "*.doc")' + LF, '0' + LF);
  Allowed('a question mark still counts characters',
          'println path_matchespattern("abc", "???"); path_matchespattern("abc", "??")' + LF,
          '10' + LF);

  { (a2) AND THE NAME MAY CONTAIN THE WILDCARDS TOO -- the axis round two's own
    sampling missed, and the reason its "4000 randomly generated pairs, BYTE
    IDENTICAL" claim could not have been true. The greedy rewrite tested the
    literal/'?' comparison BEFORE the '*' branch, so a pattern '*' landing on a
    name byte that is itself '*' was eaten as a literal pair with no star
    remembered, and 100 of the 7225 name/pattern pairs of length 0..3 over the
    four-byte alphabet a, b, star, question came back 0 where the pristine
    recursive matcher said 1. (That alphabet was written as a brace-enclosed set
    here until 2026-09-15, and a brace inside a brace comment NESTS it -- one
    "Comment level 2 found" warning, in a tree whose bar is zero warnings, which
    every runner had been printing PASS over because eight fpc invocations
    discarded their log and judged the build by whether the file appeared.) The first
    of them is the whole of glob: the pattern "*" failing to match a name. A file
    whose name contains '*' is legal on Linux and reaches this through
    dir_getfiles$. Testing '*' first is the entire fix; an exhaustive walk of
    every name and pattern of length 0..4 -- 341 x 341 = 116281 cases -- now
    differs from the pristine matcher on ZERO lines. }
  Allowed('the pattern "*" matches a name that contains a star',
          'println path_matchespattern("*a", "*")' + LF, '1' + LF);
  Allowed('a star in the NAME does not eat the star in the pattern',
          'println path_matchespattern("*ab", "*b")' + LF, '1' + LF);
  Allowed('and a star in the middle of the name is matched around',
          'println path_matchespattern("a*b", "*a*")' + LF, '1' + LF);
  Allowed('a question mark in the name is an ordinary character to match',
          'println path_matchespattern("?ab", "?b")' + LF, '0' + LF);
  Allowed('a real filename containing a star still globs by extension',
          'println path_matchespattern("re*port.txt", "*.txt")' + LF, '1' + LF);
  Allowed('and matches the bare star',
          'println path_matchespattern("re*port.txt", "*")' + LF, '1' + LF);
  Allowed('the case-insensitive form agrees',
          'println path_matchespattern("A*B", "*b", 0)' + LF, '1' + LF);
  Allowed('two stars over a starred name',
          'println path_matchespattern("*abc", "**c")' + LF, '1' + LF);

  { (b) RULE 1 UNDER EACH CEILING ALONE. The unit header's own example, refused
    whichever single ceiling the host set -- and the legitimate string of the
    same family still built under both. }
  RefusedUnder('string$(1e18) is refused under a STEP-only budget',
               'x$ = string$(1e18, 65)' + LF, 1000000, 0);
  RefusedUnder('string$(1e18) is refused under a TIME-only budget',
               'x$ = string$(1e18, 65)' + LF, 0, 2000);
  RefusedUnder('dim@ is refused under a TIME-only budget',
               'a@ = dim@(255000000)' + LF, 0, 2000);
  AllowedUnder('a million-character string still builds, step-only',
               'println len(string$(1000000, 65))' + LF, '1000000' + LF, 1000000, 0);
  AllowedUnder('a million-character string still builds, time-only',
               'println len(string$(1000000, 65))' + LF, '1000000' + LF, 0, 2000);
  AllowedUnder('and with no ceiling at all',
               'println len(string$(1000000, 65))' + LF, '1000000' + LF, 0, 0);

  { (c) THE STRING PRODUCTS. Two strings multiplied is not "already in memory". }
  Refused('replacestr$ refuses a product it cannot finish',
          's$ = string$(1000000, 97)' + LF +
          'n$ = string$(2000, 98)' + LF +
          't$ = replacestr$(s$, "a", n$)' + LF);
  Refused('instr refuses a naive search it cannot finish',
          'h$ = string$(1000000, 97)' + LF +
          'nd$ = string$(20000, 97) + "b"' + LF +
          'println instr(h$, nd$)' + LF);
  Refused('countstr refuses the same product',
          'h$ = string$(1000000, 97)' + LF +
          'nd$ = string$(20000, 97) + "b"' + LF +
          'println countstr(h$, nd$)' + LF);
  Refused('buffer_indexof refuses it too',
          'b@ = buffer_fromstr@(string$(1000000, 65))' + LF +
          'println buffer_indexof(b@, string$(20000, 65) + "B")' + LF);
  { AND ITS THREE-ARGUMENT FORM (ledger d45). One registered name, two bodies,
    and only the two-argument one asked: a third argument was a one-token escape
    from the ceiling. Asked at position 1 AND 2 -- n1 hid behind "position 1 is
    refused", because a sweep that tried only position 1 saw nothing. }
  Refused('buffer_indexof from position 1 refuses it too',
          'b@ = buffer_fromstr@(string$(1000000, 65))' + LF +
          'println buffer_indexof(b@, string$(20000, 65) + "B", 1)' + LF);
  Refused('buffer_indexof from position 2 refuses it too',
          'b@ = buffer_fromstr@(string$(1000000, 65))' + LF +
          'println buffer_indexof(b@, string$(20000, 65) + "B", 2)' + LF);
  { And the three-argument form still answers. "xyzABC" twice: ABC sits at 4
    and at 10, so from 5 the first one is skipped and the answer is 10. }
  Allowed('buffer_indexof from a position still finds the later match',
          'b@ = buffer_fromstr@("xyzABCxyzABC")' + LF +
          'println buffer_indexof(b@, "ABC", 5)' + LF, '10' + LF);
  Allowed('a short needle in a long haystack is untouched',
          'h$ = string$(1000000, 97) + "zzz"' + LF +
          'println instr(h$, "zzz"); countstr(h$, "zz"); containsstr(h$, "zzz")' + LF,
          '100000111' + LF);

  { (c2) THE NEEDLE-LENGTH AXIS. Round two's evidence for the search guard swept
    needles of length 0..6, and the band it broke starts at needle ~32 and
    document ~1 MB: 19 of 27 points on the document x needle plane were REFUSED
    for work that, unbudgeted, costs 62 ms in total. Every one of these ran clean
    before the guard existed and must run clean with it. }
  Allowed('a 32-byte needle in a 1 MB document',
          'd$ = string$(1000000, 97)' + LF +
          'println instr(d$, string$(32, 98))' + LF, '0' + LF);
  Allowed('a 256-byte needle in a 1 MB document',
          'd$ = string$(1000000, 97)' + LF +
          'println instr(d$, string$(256, 98))' + LF, '0' + LF);
  Allowed('a 4096-byte needle in a 1 MB document',
          'd$ = string$(1000000, 97)' + LF +
          'println instr(d$, string$(4096, 98))' + LF, '0' + LF);
  Allowed('an 8-byte needle in a 10 MB log',
          'd$ = string$(10000000, 97)' + LF +
          'println instr(d$, string$(8, 98))' + LF, '0' + LF);
  Allowed('a 4096-byte needle in a 10 MB log',
          'd$ = string$(10000000, 97)' + LF +
          'println instr(d$, string$(4096, 98))' + LF, '0' + LF);
  { The concrete shape the guard refused: a 300-character quotation found in a
    990 KB document, on all three of instr, countstr and replacestr$ at once. }
  Allowed('a 300-character quotation is found in a 990 KB document',
          'd$ = mulstring$("the quick brown fox jumps over the lazy dog. ", 22000)' + LF +
          'q$ = mid$(d$, 500000, 300)' + LF +
          'println instr(d$, q$); countstr(d$, q$); len(replacestr$(d$, q$, "X"))' + LF,
          '5314250542' + LF);
  Allowed('and at the buffer door, which had its own copy of the worst case',
          'd$ = mulstring$("the quick brown fox jumps over the lazy dog. ", 22000)' + LF +
          'q$ = mid$(d$, 500000, 300)' + LF +
          'b@ = buffer_fromstr@(d$)' + LF +
          'println buffer_indexof(b@, q$)' + LF, '5' + LF);
  { AND THE AMPLIFIERS STAY REFUSED. The achievable price is read off the
    haystack, so a haystack whose every position starts with the needle's first
    byte still prices at the product and is still refused. }
  Refused('instrrev refuses the same first-byte-everywhere product',
          'h$ = string$(1000000, 97)' + LF +
          'nd$ = string$(20000, 97) + "b"' + LF +
          'println instrrev(h$, nd$)' + LF);
  Refused('containsstr refuses it too',
          'h$ = string$(1000000, 97)' + LF +
          'println containsstr(h$, string$(20000, 97) + "b")' + LF);

  { (c3) THE QUADRATIC APPEND. `x := x + <piece>` in a loop is not an O(1) body,
    so Length(S) never bounded these: base64_valid, aucase$/alcase$ and reverse$
    of a 160 MB string took 78031 / 48984 / 50750 ms under a 2000 ms ceiling and
    each answered SUCCESS with islimit FALSE, and json_stringify$ of a
    one-megabyte string of quotes did not finish inside five minutes. }
  Refused('aucase$ refuses a string it cannot fold inside the budget',
          'println len(aucase$(string$(40000000, 97)))' + LF);
  Refused('alcase$ refuses the same',
          'println len(alcase$(string$(40000000, 97)))' + LF);
  Refused('reverse$ refuses the same',
          'println len(reverse$(string$(40000000, 97)))' + LF);
  Refused('base64_valid refuses the same',
          'println base64_valid(string$(40000000, 97))' + LF, 4000);
  Refused('json_stringify$ refuses a string of a million quotes',
          'j@ = json_object@()' + LF +
          'json_sets@(j@, "k", string$(1000000, 34))' + LF +
          'println len(json_stringify$(j@))' + LF, 4000);
  { and the ordinary sizes of every one of them are untouched. }
  Allowed('a one-megabyte aucase$ is still allowed',
          'println len(aucase$(string$(1000000, 97)))' + LF, '1000000' + LF);
  Allowed('a one-megabyte reverse$ is still allowed',
          'println len(reverse$(string$(1000000, 97)))' + LF, '1000000' + LF);
  Allowed('a one-megabyte base64_valid is still allowed',
          'println base64_valid(string$(1000000, 97))' + LF, '1' + LF);
  Allowed('and the answers are the ones they always gave',
          'println aucase$("abc"); alcase$("ABC"); reverse$("abc")' + LF,
          'ABCabccba' + LF);
  Allowed('json_stringify$ of an ordinary quoted string is untouched',
          'j@ = json_object@()' + LF +
          'json_sets@(j@, "k", "a" + chr$(34) + "b")' + LF +
          'println json_stringify$(j@)' + LF,
          '{"k":"a\"b"}' + LF);
  Allowed('replacestr$ with a short needle still works',
          'println replacestr$("a-b-c", "-", "+")' + LF, 'a+b+c' + LF);
  Allowed('and a replacement longer than the needle, at a sane size',
          'println bytelen(replacestr$(string$(1000, 97), "a", "xy"))' + LF, '2000' + LF);

  { The RTL's own 32-bit sizing, refused as an error rather than wrapped. FPC's
    StringReplace computes Length(S) + aCount * (New - Old) in Integer
    arithmetic (rtl/objpas/sysutils/syssr.inc), so a product past High(Integer)
    goes NEGATIVE and SetLength is handed nonsense. Refused with or without a
    budget, because an unbudgeted host has no budget to save it. }
  Unbudgeted('replacestr$ refuses a result past the RTL''s 32-bit sizing',
             'on error goto CAUGHT' + LF +
             's$ = string$(1000000, 97)' + LF +
             't$ = replacestr$(s$, "a", string$(3000, 98))' + LF +
             'println "NOT REACHED"' + LF +
             'goto DONE' + LF +
             'CAUGHT:' + LF +
             'println "caught"' + LF +
             'resume next' + LF +
             'DONE:' + LF, 'caught' + LF + 'NOT REACHED' + LF);

  { (d) ONE UNIT IS ONE BYTE. dim@ charged elements while string$ and
    buffer_new@ charged bytes, so under one ceiling a 1 GiB buffer was refused
    and a 12.2 GB array was allowed. }
  Refused('dim@ is priced in bytes, not elements',
          'a@ = dim@(255000000)' + LF);
  Allowed('a sane array is still built',
          'a@ = dim@(1000)' + LF + 'println arraysize(a@)' + LF, '1000' + LF);
  Allowed('and a two-dimensional one',
          'a@ = dim@(50, 50)' + LF + 'println arraysize(a@)' + LF, '2500' + LF);

  { (e) WHOLE-FILE I/O. The path says nothing about the size; the filesystem
    does, one line before the allocation that commits it. }
  Allowed('a small file still reads back exactly',
          'p$ = path_combine$(temppath$(), "probe_budget_r2.txt")' + LF +
          'file_writealltext(p$, "hello")' + LF +
          'println file_readalltext$(p$)' + LF +
          'file_delete(p$)' + LF, 'hello' + LF);

  { AND THE LATCH MUST NOT LEAK. GWalkSpent latches so a walk that stopped short
    cannot read as one that finished -- which means every entry point reaching a
    charged helper has to CLEAR it first. Three did not (file_copy,
    file_createempty, file_writeallbytes), and one refused write anywhere in the
    run would have made every later file_copy answer 0 for the rest of it. }
  AllowedUnder('a refused write does not poison the next file_copy',
               'p$ = path_combine$(temppath$(), "probe_budget_r2c.txt")' + LF +
               'q$ = path_combine$(temppath$(), "probe_budget_r2d.txt")' + LF +
               'file_writealltext(p$, "hello")' + LF +
               'file_delete(q$)' + LF +          // a stale target would hide the bug
               'on error goto CAUGHT' + LF +
               'big$ = string$(400000, 65)' + LF +
               'n = file_writealltext(p$, big$)' + LF +
               'CAUGHT:' + LF +
               'println file_copy(p$, q$); " "; file_readalltext$(q$)' + LF +
               'file_delete(p$)' + LF +
               'file_delete(q$)' + LF,
               '1 hello' + LF, 2000, 0);

  { (f) THE JOINS AND THE RENDERER, which were quadratic inside one opCall.
    200000 lines joined took 149875 ms and answered SUCCESS. }
  Allowed('strings_text$ joins a big list quickly',
          'l@ = strings@()' + LF +
          'strings_text(l@, mulstring$("line" + chr$(10), 100000))' + LF +
          'println bytelen(strings_text$(l@))' + LF, '500000' + LF, 2000);
  Allowed('strings_commatext$ likewise',
          'l@ = strings@()' + LF +
          'strings_text(l@, mulstring$("word" + chr$(10), 100000))' + LF +
          'println bytelen(strings_commatext$(l@))' + LF, '499999' + LF, 2000);
  Allowed('strings_sort sorts a big list quickly and correctly',
          'l@ = strings@()' + LF +
          'strings_text(l@, "c" + chr$(10) + "a" + chr$(10) + "b")' + LF +
          'strings_sort(l@)' + LF +
          'println strings_strings$(l@, 1); strings_strings$(l@, 2); strings_strings$(l@, 3)' + LF,
          'abc' + LF);
  Allowed('json_pretty$ renders a big document quickly',
          's$ = "[" + mulstring$("1,", 50000) + "1]"' + LF +
          'j@ = json_parse@(s$)' + LF +
          'println bytelen(json_pretty$(j@, 8)) > 0' + LF, 'true' + LF, 2000);
  Allowed('json_pretty$ still renders exactly what it did',
          'j@ = json_parse@("{""a"":[1,2]}")' + LF +
          'println json_stringify$(j@)' + LF, '{"a":[1, 2]}' + LF);

  { (g) THE SAME 64-BIT GUARD, THE SAME 32-BIT NARROWING, in two libraries.
    Silent wrong answers on both platforms, with or without a budget. }
  Unbudgeted('int() no longer narrows to 32 bits',
             'println int(3e9); " "; int(-3e9); " "; int(1e15); " "; int(4294967296)' + LF,
             '3000000000 -3000000000 1000000000000000 4294967296' + LF);
  Unbudgeted('int() still rounds toward negative infinity',
             'println int(3.7); " "; int(-3.7); " "; int(0); " "; int(-0.5)' + LF,
             '3 -4 0 -1' + LF);
  Unbudgeted('a json number past 2^31 survives the round trip',
             'o@ = json_object@()' + LF +
             'json_setn@(o@, "big", 3000000000)' + LF +
             'println json_getn(o@, "big"); " "; json_stringify$(o@)' + LF,
             '3000000000 {"big":3000000000}' + LF);
  Unbudgeted('and a small one still takes the small node',
             'o@ = json_object@()' + LF +
             'json_setn@(o@, "n", 42)' + LF +
             'println json_stringify$(o@)' + LF, '{"n":42}' + LF);

  { (h) THE PATTERN JUDGE, RESHAPED. The criterion is the AMBIGUITY of the
    repeated body, not its star height: a mandatory separator between iterations
    removes the ambiguity and with it the blow-up. Sixty real-world patterns went
    from 28 refused to 8; these are the ones the first version got wrong. }
  Pattern('^(/[^/]+)+$', True);                  // unix path
  Pattern('^[a-z0-9]+(?:-[a-z0-9]+)*$', True);   // slug
  Pattern('(<[^>]+>)+', True);                   // a run of tags
  Pattern('^(\d+\.)+\d+$', True);                // dotted version
  Pattern('^(\w+,)*\w+$', True);                 // comma-separated row
  Pattern('([\w-]+\.)+[a-z]{2,}', True);         // domain name
  Pattern('^(\w+\.)+\w+@(\w+\.)+\w+$', True);    // the "canonical ReDoS email"
  Pattern('^(?:[^;]*;)*[^;]*$', True);           // semicolon-separated
  Pattern('(\[[^\]]*\]\([^)]*\))+', True);       // markdown links
  Pattern('(?:\w+::)+\w+', True);                // qualified name
  Pattern('(?:\d+[hms])+', True);                // duration
  Pattern('^([A-Z][a-z]+)( [A-Z][a-z]+)*$', True);
  Pattern('(\w+)(\s*[-+*/]\s*\w+)*', True);      // separator in the MIDDLE
  Pattern('^(\w+)(\[\d*\])*$', True);
  Pattern('(?:[A-Z]{2,}_)+[A-Z]{2,}', True);
  Pattern('([^,]*,)*b', True);
  Pattern('(\r?\n)+', True);
  Pattern('(?:[0-9a-fA-F]{2}:)+[0-9a-fA-F]{2}', True);
  Pattern('^(?:[A-Za-z0-9+/]{4})*=*$', True);
  Pattern('^(?:(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\.){3}\d+$', True);

  { And the false negatives it had: a COUNTED repeat over an ambiguous body is
    the same explosion. Measured at 2703 ms and worse on a 26-character subject. }
  Pattern('(a+){10}$', False);
  Pattern('(.*a){20}$', False);
  Pattern('(a?){20}a{20}', False);
  Pattern('([A-Za-z]+\d*)+', False);
  Pattern('^\|(.+\|)+$', False);
  Pattern('(\w|\d)+#', False);
  Pattern('(([a-z])+)+$', False);
  Pattern('((a)*)*$', False);

  { THE BRANCH TABLE GAVE UP TOWARD REFUSE, WHERE EVERY OTHER GIVE-UP IN THIS
    UNIT GIVES UP TOWARD ALLOW.

    BodyUnambiguous stops recording past MaxReBranch+1 = 16 alternatives, and
    then returned the False it was initialised with -- which the caller read as
    "the body is ambiguous" rather than as "I could not judge it". So the
    SEVENTEENTH branch flipped the verdict, and the reason printed named the
    (a+)+ shape, which the pattern does not have. Its sibling give-ups do the
    opposite: the ATOM table's overflow already suppressed the refusal, and
    BranchesOverlap and UnionFirst both bail out toward "cannot judge".

    THE COUNTS ARE THE WHOLE POINT of the first two lines: sixteen and seventeen
    of the same harmless thing have to answer the same way. The class spelling
    underneath them is the same language and was allowed throughout, which is
    what made the refusal indefensible rather than merely cautious. Under the
    ceilings docs/embedding.md prescribes, a script using the method pattern got
    peLimit instead of a match, and the same script worked with the ceilings off. }
  Pattern('^(a|b|c|d|e|f|g|h|i|j|k|l|m|n|o|p)+$', True);       // 16 branches
  Pattern('^(a|b|c|d|e|f|g|h|i|j|k|l|m|n|o|p|q)+$', True);     // 17: was REFUSED
  Pattern('^(a|b|c|d|e|f|g|h|i|j|k|l|m|n|o|p|q|r|s|t|u|v|w|x|y|z)+$', True);
  Pattern('^[a-q]+$', True);                                   // the same language
  Pattern('^(GET|PUT|POST|HEAD|PATCH|TRACE|DELETE|OPTIONS|CONNECT|LINK|UNLINK|' +
          'PURGE|LOCK|UNLOCK|MOVE|MKCOL|COPY)+$', True);
  { AND THE JUDGE IS STILL A JUDGE. Suppressing a refusal it could not justify
    must not suppress the ones it can: these have sixteen branches or fewer, so
    the table did track them, and they are refused with a reason that fits. }
  Pattern('^(a+|b)+$', False);
  Pattern('^(a|b|c|d|e|f|g|h|i|j|k|l|m|n|o|ab)+$', False);

  { End to end, not just the judge in isolation. }
  Allowed('a 17-verb method alternation answers under a budget',
          'println regex_find$("^(GET|PUT|POST|HEAD|PATCH|TRACE|DELETE|OPTIONS|' +
          'CONNECT|LINK|UNLINK|PURGE|LOCK|UNLOCK|MOVE|MKCOL|COPY)+$", ' +
          '"GETPOSTCOPY")' + LF, 'GETPOSTCOPY' + LF);
  Allowed('a unix-path regex answers under a budget',
          'println regex_find$("^(/[^/]+)+$", "/usr/local/bin")' + LF,
          '/usr/local/bin' + LF);
  Allowed('a dotted-version regex answers under a budget',
          'println regex_find$("^([0-9]+\\.)+[0-9]+$", "1.2.3")' + LF, '1.2.3' + LF);
  Allowed('a domain regex answers under a budget',
          'println regex_find$("([\\w-]+\\.)+[a-z]{2,}", "www.example.com")' + LF,
          'www.example.com' + LF);

  { (h2) THE JUDGE'S OWN MISREADINGS (2026-10-09). Every refusal below is a
    pattern the judge called UNAMBIGUOUS while TRegExpr ran it 2^n -- measured
    in a generated sweep against the real matcher, each one past 400 ms at a
    26-character failing subject, while the same shape spelled plainly was
    refused in microseconds. The judge did not misjudge the shape; it misREAD
    the pattern, and a misreading produced a confident "unambiguous".

    ESCAPES WITH OPERANDS. The reader took one character after the backslash
    and the caller stepped two, so \x61 left "61" behind as two literal atoms,
    and the '6' passed for a separator. \xNN and its braced form are one byte to 0.987,
    so ^(\x61+)+$ IS ^(a+)+$; \cA is byte 01; \h is TAB SPACE NBSP, not 'h';
    \v is all four line separators, not VT alone. An escape this judge does not
    model (\u, \p, \z ...) is UNKNOWN, and unknown inside a repeat refuses. }
  Pattern('^(\x61+)+$', False);
  Pattern('^(\x{61}+)+$', False);
  Pattern('^(a|\x61)+$', False);
  Pattern('^(a|\cA|\x01)+$', False);
  Pattern('^(\h|\x20)+$', False);
  Pattern('^(\v|\n)+$', False);
  Pattern('^(\f|\v)+$', False);             // \v has FF in it: 3953 ms at n=24
  Pattern('^(a|[\x61])+$', False);
  Pattern('^([\x61-\x62]|a)+$', False);
  Pattern('^(a+)+$', False);
  Pattern('^(\p{L}+)+$', False);
  Pattern('^(\z|\z)+$', False);
  { (?i) WAS NOT READ AT ALL, so the sets of 'a' and of 'A' looked disjoint. It holds to
    the end of its enclosing group, across '|', and reaches classes too. }
  Pattern('(?i)^(a|A)+$', False);
  Pattern('^((?i)a|A)+$', False);
  Pattern('^(a|(?i)A)+$', False);
  Pattern('(?i)^([a]|A)+$', False);
  Pattern('(?i)^(a|[A])+$', False);
  Pattern('(?i)^(\x61|A)+$', False);
  { NOTHING PASSED FOR A SEPARATOR. A comment, an empty group and an empty
    non-capturing group consume nothing, and were folded in as fixed-width atoms
    with no bytes -- disjoint from everything, the perfect barrier. Under (?x)
    a blank is nothing too, and it was read as a literal space. }
  Pattern('^(a+(?#c)a+)+$', False);
  Pattern('^(a+(?:)a+)+$', False);
  Pattern('^(a+()a+)+$', False);
  Pattern('(?x)^(a+ a?)+$', False);
  { NOTHING, MATCHED TWO WAYS. Found by the same sweep once the separators
    above were honest: a body pinned by a mandatory byte is still 2^n when
    there are two ways to match the EMPTY string after it -- take an empty
    group or skip it, take the first nullable branch or the second. TRegExpr
    does not memoise, so a failing tail tries every combination. Measured at
    n=24 against the real matcher: 4188, 5907, 4828, 4859 and 4750 ms. }
  Pattern('^(c()?)+$', False);
  Pattern('^(c(a?|b?))+$', False);
  Pattern('^(c(a*)?)+$', False);
  Pattern('^(c(x?)?)+$', False);
  Pattern('^(c(|))+$', False);
  Pattern('^(c(x|y|)?)+$', False);
  Pattern('^(a\B?)+$', False);
  Pattern('^(a(?#c)?)+$', False);
  Pattern('(?x)^((a) ?)+$', False);          // the blank, quantified
  Pattern('^((a(?:)?)b)+$', False);          // carried up through a plain group
  Pattern('^(c(x|y|))+$', True);             // ONE nullable branch is one way: 0 ms
  Pattern('^(c(x?y?))+$', True);             // and so is a nullable sequence
  { AND IT IS STILL A JUDGE THAT ALLOWS. The same features, spelled over bodies
    that really are unambiguous, must not start refusing: refusing a safe
    pattern is the failure this unit's header calls the worse one. }
  Pattern('^(\d+\x2E)+\d+$', True);         // a dotted version, its dot in hex
  Pattern('^(\x41|a)+$', True);             // case-sensitive: 'A' and 'a' differ
  Pattern('^([\x00-\x1F]+;)+$', True);
  Pattern('^(\t+\n)+$', True);
  Pattern('(?i)^([a-z]+,)+$', True);
  Pattern('(?i)^(\w+\.)+\w+$', True);
  Pattern('(?i)^(a|b)+$', True);
  Pattern('(?i)(?-i)^(a|A)+$', True);       // switched off again
  Pattern('^((?i)x)(a|A)+$', True);         // (?i) ended with its group
  Pattern('(?x)^(a+ ,)+$', True);           // the blank is nothing; ',' separates
  Pattern('^(\w+(?#a comment),)+$', True);
  Refused('regex_find$ refuses ^(\x61+)+$, the (a+)+ shape in hex',
          'println regex_find$("^(\\x61+)+$", "' + aaa + '")' + LF);
  Refused('regex_find$ refuses (?i)^(a|A)+$',
          'println regex_find$("(?i)^(a|A)+$", "' + aaa + '")' + LF);
  Allowed('a case-insensitive list still answers under a budget',
          'println regex_find$("(?i)^([a-z]+,)+$", "Ab,cD,")' + LF, 'Ab,cD,' + LF);
  Allowed('a hex-spelled separator still answers under a budget',
          'println regex_find$("^(\\d+\\x2E)+\\d+$", "1.2.3")' + LF, '1.2.3' + LF);

  { (h3) AMBIGUITY THE JUDGE NEVER LOOKED FOR (2026-10-09, round 2). The judge
    asked three structural questions -- is there a separator, does the body end
    on one, does it begin on one -- and answered "unambiguous" if any said yes.
    Each question was about the wrong thing:

    INSIDE ONE ITERATION. A separator pins where an iteration ENDS. It says
    nothing about how the bytes INSIDE one are divided between two flexible
    atoms with overlapping sets: in ^(a*a*b)+$ a block of m a's splits m+1
    ways, (m+1)^k for k blocks, x4 per block and 15 s under a 2000 ms budget.
    And an unquantified inner alternation was never asked whether its branches
    overlap at all -- ^((a|a)b)+$ is 2^k.

    ACROSS THE BOUNDARY. The window rules (ii) and (iii) looked at atoms of the
    SAME branch, but the next iteration may take another: in ^(ab?|b)+$ "ab"
    is one iteration of the first branch or two of the first and the second.

    The criterion is now the one the theory names: a repeated body is refused
    when some state of its automaton has two different paths back to itself on
    the same text (exponential ambiguity, decided on the product automaton).
    Measured here, unfixed, against TRegExpr: x2 per block for the four 2^n
    shapes, ^(a|ab)+$ flat at 0 ms. }
  Pattern('^(a*a*b)+$', False);
  Pattern('^((a|a)b)+$', False);
  Pattern('^(a?a?b)+$', False);              // two optional atoms, one set
  Pattern('^(\d*\d+,)+$', False);
  Pattern('^(a+(b|b)c)+$', False);           // identical inner branches
  Pattern('^((ab|ab)c)+$', False);
  Pattern('^((a|[ab])b)+$', False);
  Pattern('^(x(a|a)?y)+$', False);
  Pattern('^((?:a|a)b){3,}$', False);
  Pattern('^(ab?|b)+$', False);
  Pattern('^(a|ba?)+$', False);
  Pattern('^(ab*|b)+$', False);
  Pattern('^(a[ab]?|b)+$', False);
  Pattern('^(ab|b|a)+$', False);
  { AND WHERE THE OLD QUESTIONS REFUSED WHAT IS NOT AMBIGUOUS. (a|ab) is a
    uniquely decodable code -- 'a' is a prefix of 'ab', and the dangling 'b'
    begins no word (Sardinas-Patterson) -- so each subject has one parse, and
    TRegExpr answers it in 0 ms at every length measured. Its branches share a
    first byte, which is all the old rule asked. }
  Pattern('(a|ab)+', True);
  Pattern('^(a|ab)+$', True);
  Pattern('^(ab|ac)+$', True);
  Pattern('^((ab|ac)d)+$', True);
  Pattern('^(a*b)+$', True);
  Pattern('^(a+b?c)+$', True);
  { A COUNT THE MATCHER DOES NOT KEEP. Found by the sweep at 30000 patterns:
    TRegExpr 0.987 keeps a counted group repeat's count in one slot per
    nesting depth and zeroes it on entry, so nested counted group repeats
    resume with each other's counts. The first pattern below has 6^4 paths
    as written and ran 219 ms on 28 a's, doubling every byte and a half.
    A counted group repeat that holds another, or sits inside one, is now read
    as a loop with no bound; a lone one keeps its exact count (the IPv4 quad,
    pinned above, is one). }
  Pattern('^(?:((a){1,2}){1,2}aa){4}$', False);
  Pattern('^(?:(a){1,2}a){3}$', False);
  Pattern('^(?:(ab){2}c)+$', True);          // a lone counted group, inside +

  { THE TABLE LIMITS WERE A DOCUMENTED BYPASS. Past 96 atoms, 16 branches or
    48 levels of nesting the old judge did not look, and "did not look" meant
    ALLOW -- so padding made any shape pass. Each of these is the (a+)+ or
    (a|a)+ shape past one of the old limits. The limits are now far past any
    real pattern (100 levels, 4096 automaton states a body, a bounded amount of
    product work), and a pattern past them is REFUSED under a budget:
    docs/embedding.md#the-ceilings-reach-inside-a-library-call-too says why. }
  Pattern('^(a+' + Repeated('c?', 100) + 'a+)+$', False);
  Pattern('^(a|b|c|d|e|f|g|h|i|j|k|l|m|n|o|p|q|a)+$', False);
  Pattern('^' + Repeated('(', 50) + 'a|a' + Repeated(')', 50) + '+$', False);
  Pattern(Repeated('(', 150) + 'a' + Repeated(')', 150), False);
  // ...and a big alternation that is a real code is still judged and allowed:
  // three hundred distinct four-letter words, every one the same length.
  aaa := '';
  for i := 0 to 299 do
  begin
    if i > 0 then aaa := aaa + '|';
    aaa := aaa + Chr(97 + i mod 26) + Chr(97 + (i div 26) mod 26) + 'x' +
           Chr(97 + (i * 7) mod 26);
  end;
  Pattern('^(?:' + aaa + ')+$', True);
  // The subjects are short enough that an unfixed judge lets the match FINISH
  // (3^12 and 2^16 attempts) and the check fails on its answer, not on a hang;
  // the refusal comes before the matcher whatever the subject's length.
  Refused('regex_find$ refuses ^(a*a*b)+$',
          'println regex_find$("^(a*a*b)+$", "' + Repeated('aab', 12) + '!")' + LF);
  Refused('regex_find$ refuses ^(ab?|b)+$',
          'println regex_find$("^(ab?|b)+$", "' + Repeated('ab', 16) + '!")' + LF);
  Allowed('and ^(a|ab)+$ answers under a budget',
          'println regex_find$("^(a|ab)+$", "aababa")' + LF, 'aababa' + LF);

  { The controls first: the sweep must be able to see a 2^n pattern. }
  BeginThread(@Watchdog);
  SweepControl('^(a*a*b)+$');
  SweepControl('^((a|a)b)+$');
  SweepControl('^(ab?|b)+$');
  SweepControl('^(a|ba?)+$');
  JudgeSweep(3000);
  SafeCorpusCheck;

  { (i) AND THE UNBUDGETED HOST IS STILL UNTOUCHED by every one of these. }
  Unbudgeted('an unbudgeted host still globs',
          'n$ = string$(12, 97)' + LF +
          'println path_matchespattern(n$, "*a*a*b")' + LF, '0' + LF);
  Unbudgeted('an unbudgeted host still searches with a long needle',
          'h$ = string$(50000, 97)' + LF +
          'println instr(h$, string$(2000, 97))' + LF, '1' + LF);
  Unbudgeted('an unbudgeted host still joins a list',
          'l@ = strings@()' + LF +
          'strings_text(l@, "a" + chr$(10) + "b")' + LF +
          'println strings_commatext$(l@)' + LF, 'a,b' + LF);
  Unbudgeted('an unbudgeted host still reads a file it wrote',
          'p$ = path_combine$(temppath$(), "probe_budget_r2b.txt")' + LF +
          'file_writealltext(p$, "x")' + LF +
          'println file_readalltext$(p$)' + LF +
          'file_delete(p$)' + LF, 'x' + LF);

  { (j) A REFUSED gzip_decompressfile LEAVES ITS DESTINATION ALONE (ledger d14),
    AND THE NEXT CALL IS NOT TOLD ABOUT IT (ledger n3).

    d14: the call inflated, WROTE the result over the destination, and only then
    asked whether the inflate had stopped on the budget -- so a refused call had
    already truncated the file to whatever fitted, and the refusal arrived after
    the damage. n3: whether it stopped was a unit global, reset only when an
    inflate began; a call whose source was missing never began one, so it read
    the PREVIOUS call's answer and reported a missing file as a budget refusal.
    The global survives from one engine to the next in a process, which is what
    the second case below relies on.

    The numbers: 1000 steps buy 1000 * 256 = 256000 units, and an inflate is
    charged one unit an output byte, so two million bytes of 'A' cannot fit and
    a few instructions of script easily do. The setup and the reads run
    unbudgeted, so only the call under test is measured. }
  Unbudgeted('gzip: the d14 fixture is made',
          'p$ = path_combine$(temppath$(), "probe_budget_d14.txt")' + LF +
          'g$ = path_combine$(temppath$(), "probe_budget_d14.gz")' + LF +
          'd$ = path_combine$(temppath$(), "probe_budget_d14.out")' + LF +
          'file_writealltext(p$, string$(2000000, 65))' + LF +
          'println gzip_compressfile(p$, g$)' + LF +
          'file_writealltext(d$, "KEEP")' + LF +
          'file_delete(p$)' + LF, '1' + LF);
  RefusedUnder('gzip_decompressfile past the budget is refused',
          'g$ = path_combine$(temppath$(), "probe_budget_d14.gz")' + LF +
          'd$ = path_combine$(temppath$(), "probe_budget_d14.out")' + LF +
          'x = gzip_decompressfile(g$, d$)' + LF, 1000, 0);
  Unbudgeted('and the refused call left its destination as it was',
          'd$ = path_combine$(temppath$(), "probe_budget_d14.out")' + LF +
          'println file_readalltext$(d$)' + LF, 'KEEP' + LF);
  Unbudgeted('a missing source after a refusal is a missing source, not a refusal',
          'g$ = path_combine$(temppath$(), "probe_budget_n3_missing.gz")' + LF +
          'd$ = path_combine$(temppath$(), "probe_budget_n3.out")' + LF +
          'println gzip_decompressfile(g$, d$)' + LF +
          'println gzip_error()' + LF, '0' + LF + '1' + LF);
  AllowedUnder('and inside the budget the same file inflates in full',
          'g$ = path_combine$(temppath$(), "probe_budget_d14.gz")' + LF +
          'd$ = path_combine$(temppath$(), "probe_budget_d14.out")' + LF +
          'println gzip_decompressfile(g$, d$)' + LF +
          'println len(file_readalltext$(d$))' + LF +
          'file_delete(g$)' + LF +
          'file_delete(d$)' + LF, '1' + LF + '2000000' + LF, 1000000, 0);

  { (k) THE ZIP EXTRACTORS PAY FOR WHAT COMES OUT, NOT FOR WHAT THE ARCHIVE SAYS
    (ledger d46), AND ALL THREE OF THEM ASK (d47).

    The archive holds two million bytes of 'A' -- a few kilobytes deflated -- and
    UnderReport rewrites its central directory to say the entry is ONE byte. The
    old guard priced that claim, found it tiny, and let the inflate run to the end
    of the stream; zip_extract and zip_extractall did not ask at all. 1000 steps
    buy 256000 units at one unit an output byte, so two million cannot fit.

    Every refusal is checked for its DAMAGE too: the entry it stopped in is a
    partial file, and the plan of record decided it is removed rather than left
    holding whatever fitted. An honest archive that admits to being too big is
    refused before a single file is created. And within a budget, and with none,
    the same lying archive still extracts in full -- a meter that refused
    everything would pass every refusal above. }
  ZipLie := ScriptPath('probe_budget_d46.zip');
  ZipTrue := ScriptPath('probe_budget_d47.zip');
  for i := 1 to 6 do
    ZipOut[i] := ScriptPath('probe_budget_d46_out' + IntToStr(i));
  Unbudgeted('zip: the d46 and d47 archives are made',
          'h@ = zip_create@("' + ZipLie + '")' + LF +
          'x = zip_addstr(h@, string$(2000000, 65), "big.txt")' + LF +
          'println zip_close(h@)' + LF +
          'h@ = zip_create@("' + ZipTrue + '")' + LF +
          'x = zip_addstr(h@, string$(2000000, 65), "big.txt")' + LF +
          'println zip_close(h@)' + LF, '1' + LF + '1' + LF);
  Report(UnderReport(StringReplace(ZipLie, '/', PathDelim, [rfReplaceAll])),
         'zip: the d46 archive now under-reports its entry');
  Unbudgeted('zip: and the archive says its entry is one byte',
          'h@ = zip_open@("' + ZipLie + '")' + LF +
          'println zip_entrysize(h@, "big.txt")' + LF, '1' + LF);
  RefusedUnder('zip_read$ of an entry that lies about its size is refused',
          'h@ = zip_open@("' + ZipLie + '")' + LF +
          's$ = zip_read$(h@, "big.txt")' + LF, 1000, 0);
  RefusedUnder('unzip_extract of an entry that lies about its size is refused',
          'x = unzip_extract("' + ZipLie + '", "' + ZipOut[1] + '")' + LF, 1000, 0);
  RefusedUnder('zip_extract of an entry that lies about its size is refused',
          'h@ = zip_open@("' + ZipLie + '")' + LF +
          'x = zip_extract(h@, "big.txt", "' + ZipOut[2] + '")' + LF, 1000, 0);
  RefusedUnder('zip_extractall of an entry that lies about its size is refused',
          'h@ = zip_open@("' + ZipLie + '")' + LF +
          'x = zip_extractall(h@, "' + ZipOut[3] + '")' + LF, 1000, 0);
  Unbudgeted('and none of the three left a partial file behind',
          'println file_exists("' + ZipOut[1] + '/big.txt")' + LF +
          'println file_exists("' + ZipOut[2] + '/big.txt")' + LF +
          'println file_exists("' + ZipOut[3] + '/big.txt")' + LF,
          '0' + LF + '0' + LF + '0' + LF);
  RefusedUnder('zip_extractall of an honest archive too big for the budget is refused',
          'h@ = zip_open@("' + ZipTrue + '")' + LF +
          'x = zip_extractall(h@, "' + ZipOut[4] + '")' + LF, 1000, 0);
  Unbudgeted('before it created anything',
          'println dir_exists("' + ZipOut[4] + '")' + LF, '0' + LF);
  AllowedUnder('within the budget the lying archive still extracts in full',
          'println unzip_extract("' + ZipLie + '", "' + ZipOut[5] + '")' + LF +
          'println len(file_readalltext$("' + ZipOut[5] + '/big.txt"))' + LF +
          'file_delete("' + ZipOut[5] + '/big.txt")' + LF,
          '1' + LF + '2000000' + LF, 1000000, 0);
  Unbudgeted('and an unbudgeted host reads it in full',
          'h@ = zip_open@("' + ZipLie + '")' + LF +
          'println len(zip_read$(h@, "big.txt"))' + LF +
          'println zip_extractall(h@, "' + ZipOut[6] + '")' + LF +
          'file_delete("' + ZipOut[6] + '/big.txt")' + LF,
          '2000000' + LF + '1' + LF);
  // Tidy up: two files and the EMPTY directories the extractions made. RemoveDir
  // is rmdir -- it cannot remove a directory that still holds anything.
  DeleteFile(StringReplace(ZipLie, '/', PathDelim, [rfReplaceAll]));
  DeleteFile(StringReplace(ZipTrue, '/', PathDelim, [rfReplaceAll]));
  for i := 1 to 6 do
    RemoveDir(StringReplace(ZipOut[i], '/', PathDelim, [rfReplaceAll]));

  Sink.Free;
  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed > 0 then Halt(1) else Halt(0);
end.
