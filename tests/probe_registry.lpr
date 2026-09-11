{******************************************************************************
  probe_registry -- overload resolution: the order it must keep, and the cost it
  must not have

  MIT License. Copyright (c) 2026 Andre Murta.

  THE DEFECT THIS PINS. TPhosphorRegistry.IndexOfKey was a linear scan of every
  registered signature, and Resolve calls it once per widening mask -- so a call
  with k integer arguments walked the whole table 2^k times. On the console host
  (1,271 signatures with the GUI up) that was +7.5 us for a one-argument built-in
  and +21.0 us for a two-argument one, measured at 300,000 iterations on
  2026-09-11 against a 518 ms loop body with no call in it at all. It is now an
  open-addressed index maintained by EnsureSlot, and the mask loop stops on an
  exact hit: the same two programs cost +0.09 us and +0.36 us per call.

  WHY THE COST IS MEASURED HERE AND NOT IN A .bas FILE. The obvious regression
  test -- a loop written `i%` against the same loop written `i` -- measures
  NOTHING: a `for i = 1 to N` counter already arrives as an int%, so both
  spellings pay the same 2^k and the test passes with the fix removed. What can
  be measured, on any machine and without a stopwatch constant, is a RATIO
  between two resolutions that differ in exactly one property:

    - the same shape of call against a signature registered FIRST and one
      registered LAST. A scan pays for the distance; an index does not.
    - an exact one-int hit against an exact eight-int hit. 2^k masks pay for the
      arity even when the first probe already answered; stopping on it does not.

  Each leg runs for a fixed slice of time and counts how far it got, so a slow
  machine moves both legs together and the ratio is what survives. Measured on
  2026-09-11 against a table of 8,194 signatures, three ways: as the fix stands,
  with the early exit alone taken back out, and against the registry as it was.

                             fix   index only   linear scan
    first / last-registered  1.15x    1.03x        110x      limit 8x
    one int / eight ints     1.59x   19.8x         272x      limit 4x

  So each half of the change has an assertion that fails when that half alone is
  removed, which is the only reason the second column is in this table. Every run
  prints the four rates on an 'info:' line, so whoever has to revise a limit can
  see the margin that set it rather than guess at it.

  Prints "ok: N" / "fail: M" and exits non-zero on any failure. Run with --fail
  to corrupt one expectation and confirm the check can fail.
******************************************************************************}
program probe_registry;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  SysUtils, PhosphorValue, PhosphorErrors, PhosphorRegistry;

const
  { The filler registry the timings run against. Big enough that a linear scan
    is unmistakable and small enough that building it costs nothing. }
  FILLER = 8192;
  { Keys registered one at a time, looking every one of them up again after each
    registration. 1,200 crosses eight of the index's growth boundaries. }
  GROW_N = 1200;
  { How long one timing leg runs. Long enough that the 15.6 ms Windows tick is
    a few per cent of it. }
  LEG_MS = 250;
  { The two ratios. See the header for what each side of them measured. }
  POS_LIMIT  = 8;
  MASK_LIMIT = 4;

var
  Ok: Integer = 0;
  Failed: Integer = 0;
  ProveFail: Boolean = False;
  Sink: Int64 = 0;      { keeps a timing loop from being optimised away }

procedure Report(Pass: Boolean; const Name: String);
begin
  if Pass then Inc(Ok)
  else begin Inc(Failed); Writeln(StdErr, 'FAIL: ', Name); end;
end;

{ ---------------------------------------------------------------------------
  Identities. Resolve answers WHICH slot won, and the only way to read that from
  outside is to call what it handed back, so each overload under test is a
  separate function returning its own number. }

function R01(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(1); end;
function R02(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(2); end;
function R03(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(3); end;
function R04(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(4); end;
function R05(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(5); end;
function R06(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(6); end;
function R07(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(7); end;
function R08(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(8); end;
function R09(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(9); end;
function R10(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(10); end;
function R11(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(11); end;
function R12(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(12); end;

{ The one function the thousands of generated slots share. It cannot know which
  slot called it -- but TRegEntry can, and it names the slot in the error it
  raises for a narrowed NaN, which is a public path (PhosphorValue.NanNarrowed).
  So this reports its own registered NAME through the guard, and the growth test
  reads it back. }
function RName(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  SetNanNarrowed(True);
  Result := Default(TValue);
end;

{ ---------------------------------------------------------------------------
  Asking. A code letter names a kind, in the registry's own alphabet. }

function KindOfCode(C: Char): TValueKind;
begin
  if C = '%' then Result := vkInt
  else if C = '$' then Result := vkString
  else if C = '@' then Result := vkHandle
  else if C = '?' then Result := vkBool
  else Result := vkDouble;
end;

procedure KindsOf(const ACodes: String; var AKinds: array of TValueKind);
var
  i: Integer;
begin
  for i := 1 to Length(ACodes) do AKinds[i - 1] := KindOfCode(ACodes[i]);
end;

{ Resolve AName for arguments of those kinds, call whatever won, and answer the
  number it returned: 0 when nothing resolved, -1 when the call reported an
  error. }
function Pick(R: TPhosphorRegistry; const AName, ACodes: String): Int64;
var
  kinds: array of TValueKind;
  args: array of TValue;
  i: Integer;
  res: TResolvedFunc;
  e: TPhosphorError;
  v: TValue;
begin
  SetLength(kinds, Length(ACodes));
  SetLength(args, Length(ACodes));
  KindsOf(ACodes, kinds);
  for i := 0 to High(kinds) do
  begin
    args[i] := Default(TValue);
    args[i].Kind := kinds[i];
  end;
  res := R.Resolve(AName, kinds);
  if not res.Found then Exit(0);
  e := NoError();
  v := res.Func(args, e);
  if IsError(e) then Exit(-1);
  Result := v.Int;
end;

{ The registered NAME of the slot that won, read out of the guard's own message.
  Empty when nothing resolved. }
function PickName(R: TPhosphorRegistry; const AName, ACodes: String): String;
var
  kinds: array of TValueKind;
  args: array of TValue;
  res: TResolvedFunc;
  e: TPhosphorError;
  p: Integer;
begin
  Result := '';
  SetLength(kinds, Length(ACodes));
  SetLength(args, Length(ACodes));
  KindsOf(ACodes, kinds);
  res := R.Resolve(AName, kinds);
  if not res.Found then Exit;
  e := NoError();
  res.Func(args, e);
  p := Pos(' was given', e.Message);
  if p > 1 then Result := Copy(e.Message, 1, p - 1);
end;

{ ---------------------------------------------------------------------------
  Timing. }

{ How many times a second this registry can resolve AName for those kinds.

  The rate is computed from the elapsed time ACTUALLY measured rather than from
  the nominal budget, so the 15.6 ms granularity of the Windows tick cancels
  instead of biasing the answer. The clock is read every 64 iterations: often
  enough to bound the overshoot, seldom enough that reading it is not what gets
  measured. }
function Rate(R: TPhosphorRegistry; const AName, ACodes: String): Int64;
var
  kinds: array of TValueKind;
  i: Integer;
  n, hits: Int64;
  t0, el: QWord;
begin
  SetLength(kinds, Length(ACodes));
  KindsOf(ACodes, kinds);
  n := 0;
  hits := 0;
  t0 := GetTickCount64();
  repeat
    for i := 1 to 64 do
      if R.Resolve(AName, kinds).Found then Inc(hits);
    Inc(n, 64);
    el := GetTickCount64() - t0;
  until el >= QWord(LEG_MS);
  if el = 0 then el := 1;
  Sink := Sink + hits;
  Result := n * 1000 div Int64(el);
end;

{ ---------------------------------------------------------------------------
  1. THE ORDER RESOLUTION MUST KEEP. Every expectation below is derived from the
  rule in PhosphorRegistry's header -- an int% binds to '%' exactly or to 'n' by
  widening, fewest widenings win, and '*' is considered only after every exact
  reading has failed -- and never from a run. }

procedure OrderRules;
var
  reg: TPhosphorRegistry;
begin
  reg := TPhosphorRegistry.Create();
  try
    { g has both spellings of one numeric argument. }
    reg.Add('g:%', @R01);
    reg.Add('g:n', @R02);
    { h has only the widening one. }
    reg.Add('h:n', @R03);
    { t forces a TIE: two ways to widen exactly one of two ints. }
    reg.Add('t:n%', @R04);
    reg.Add('t:%n', @R05);
    { u is the exact-hit-first shape the mask loop now stops on. }
    reg.Add('u:%%', @R06);
    reg.Add('u:nn', @R07);
    { m SEPARATES "stop on an exact hit" FROM "stop on any hit". Three int
      arguments; 'm:nn%' widens two of them and is reached at mask 3, 'm:%%n'
      widens one and is reached at mask 4. Fewest widenings wins, so the answer
      is the one found SECOND -- and a mask loop that broke on any hit rather
      than on the one that widens nothing would answer the first. Neither the
      registry as it was nor the registry as it is can tell those two apart
      anywhere else: no name in the shipped host is registered densely enough
      for the order of the masks to matter, so without this line the new Break
      is pinned by a comment and nothing else. }
    reg.Add('m:nn%', @R01);
    reg.Add('m:%%n', @R02);

    { v pits a wildcard against exact readings of the same name and arity. }
    reg.Add('v:n', @R08);
    reg.Add('v:*', @R09);
    { w is every other code at once, and takes no widening at all. }
    reg.Add('w:$@?', @R10);
    { Same signature twice: the second registration must REPLACE the first, not
      hide behind it in a second slot. }
    reg.Add('z:n', @R11);
    reg.Add('z:n', @R12);
    { The name is case-insensitive; the signature is stored lowercased. }
    reg.Add('MixedCase:$', @R01);

    Report(Pick(reg, 'g', '%') = 1, 'an int binds to % exactly, not to n');
    Report(Pick(reg, 'g', 'n') = 2, 'a Double binds to n');
    Report(Pick(reg, 'h', '%') = 3, 'an int widens to n when only n is offered');
    Report(Pick(reg, 'h', 'n') = 3, 'a Double still binds n');
    { Both readings widen exactly one argument, so the cost cannot separate
      them. The engine enumerates masks 0..2^k-1 and keeps only a STRICTLY
      better one, and the mask that widens the first int is 1 while the one that
      widens the second is 2 -- so the first reading stands. }
    Report(Pick(reg, 't', '%%') = 4, 'a tie on widenings goes to the lower mask');
    Report(Pick(reg, 't', 'n%') = 4, 'Double then int reads t:n% exactly');
    Report(Pick(reg, 't', '%n') = 5, 'int then Double reads t:%n exactly');
    Report(Pick(reg, 'u', '%%') = 6, 'two ints take the exact :%% over :nn');
    Report(Pick(reg, 'u', 'nn') = 7, 'two Doubles take :nn');
    Report(Pick(reg, 'u', '%n') = 7, 'one of each widens the int into :nn');
    Report(Pick(reg, 'm', '%%%') = 2,
      'the fewest widenings wins even when a costlier reading is found first');
    Report(Pick(reg, 'v', 'n') = 8, 'an exact reading beats a wildcard');
    Report(Pick(reg, 'v', '%') = 8, 'a WIDENED exact reading still beats a wildcard');
    Report(Pick(reg, 'v', '$') = 9, 'a wildcard answers what no exact reading can');
    Report(Pick(reg, 'w', '$@?') = 10, 'string, handle and bool bind exactly');
    Report(Pick(reg, 'w', '$@n') = 0, 'a kind that matches nothing resolves to nothing');
    Report(Pick(reg, 'z', 'n') = 12, 'a repeated signature REPLACES, never shadows');
    Report(Pick(reg, 'MIXEDCASE', '$') = 1, 'the name is case-insensitive');
    { Nothing is registered wider than three arguments here, so a four-argument
      call cannot match and must not be searched for. }
    Report(Pick(reg, 'w', '$@?$') = 0, 'a call wider than anything registered finds nothing');
    Report(Pick(reg, 'nosuchname', 'n') = 0, 'an unregistered name finds nothing');
    Report(Pick(reg, '', '') = 0, 'the empty name finds nothing');
    Report(reg.HasName('g') and reg.HasName('G'), 'HasName still answers, either case');
    Report(not reg.HasName('gg'), 'HasName does not answer for a longer name');
  finally
    reg.Free;
  end;
end;

{ ---------------------------------------------------------------------------
  2. GROWTH. The index is rebuilt whenever it would pass half full, and the
  parallel arrays it is rebuilt from are OVER-ALLOCATED -- Length(FKeys) is up to
  twice FCount and the tail holds empty strings. So: register one key at a time
  and after EVERY registration look up every key registered so far, by name,
  through the guard that names the slot it reached. A rebuild that dropped an
  entry, or one that indexed the empty tail, shows up on the next line. }

procedure Growth;
var
  reg: TPhosphorRegistry;
  i, j, bad: Integer;
  nm: String;
begin
  reg := TPhosphorRegistry.Create();
  try
    bad := 0;
    for i := 0 to GROW_N - 1 do
    begin
      reg.Add('g' + Format('%.4d', [i]) + ':$', @RName);
      for j := 0 to i do
      begin
        nm := 'g' + Format('%.4d', [j]);
        if PickName(reg, nm, '$') <> nm then Inc(bad);
      end;
    end;
    Report(bad = 0, Format('every key stays reachable across every rebuild (%d lost)', [bad]));
    Report(PickName(reg, 'g' + Format('%.4d', [GROW_N]), '$') = '',
      'a key that was never registered is not found');
    Report(PickName(reg, '', '$') = '', 'the empty key is not found');
    { The over-allocated tail is empty strings; a lookup for one must miss. }
    Report(not reg.HasName(''), 'the empty name is not in the table');
  finally
    reg.Free;
  end;
end;

{ ---------------------------------------------------------------------------
  3. THE COST. The two ratios below measured 110x and 272x against the registry
  as it was, and 1.15x and 1.59x against the one that replaced it. See the
  header for the third column, which is what keeps the second leg honest. }

procedure Cost;
var
  reg: TPhosphorRegistry;
  i: Integer;
  rFirst, rLast, r1, r8: Int64;
begin
  reg := TPhosphorRegistry.Create();
  try
    { Two exact hits that differ only in how many integer arguments they take.
      Registered FIRST, and next to each other, so that neither is favoured by
      position and so that what the second one pays for is only the widening
      probes that follow the one that already answered.

      EIGHT rather than two or four, because at four the difference between one
      probe and sixteen is only 1.5x of a resolution once the table is indexed --
      inside the noise a limit has to leave room for -- and this leg has to be
      able to see the early exit go missing, not just the index. Eight integer
      arguments is a shape the language really has: callfunc is registered out to
      nine. Measured both ways: 1.6x with the early exit, 20x without it. }
    reg.Add('zq1:%', @R02);
    reg.Add('zq8:%%%%%%%%', @R03);
    for i := 0 to FILLER - 1 do
      reg.Add('p' + Format('%.6d', [i]) + ':$', @R01);

    Report(Pick(reg, 'p000000', '$') = 1, 'the first-registered key still answers');
    Report(Pick(reg, Format('p%.6d', [FILLER - 1]), '$') = 1, 'the last-registered key still answers');
    Report(Pick(reg, 'zq1', '%') = 2, 'the one-int signature still answers');
    Report(Pick(reg, 'zq8', '%%%%%%%%') = 3, 'the eight-int signature still answers');

    rFirst := Rate(reg, 'p000000', '$');
    rLast := Rate(reg, Format('p%.6d', [FILLER - 1]), '$');
    if ProveFail then rLast := rLast div 1000;
    Report((rFirst <= rLast * POS_LIMIT) and (rLast <= rFirst * POS_LIMIT),
      Format('where a key sits in the table does not change what it costs to find '
           + '(first %d/s, last %d/s, limit %dx)', [rFirst, rLast, POS_LIMIT]));

    r1 := Rate(reg, 'zq1', '%');
    r8 := Rate(reg, 'zq8', '%%%%%%%%');
    Report(r1 <= r8 * MASK_LIMIT,
      Format('an exact hit costs one probe, not 2^k of them '
           + '(1 int %d/s, 8 ints %d/s, limit %dx)', [r1, r8, MASK_LIMIT]));

    { The four rates, on stdout, on every run. The tally above is what the suite
      reads; this is for whoever has to judge the margin later, because a limit
      without the measurement beside it is a number nobody can revise. }
    Writeln(Format('info: resolve/s  first %d  last %d  1int %d  8int %d',
      [rFirst, rLast, r1, r8]));
  finally
    reg.Free;
  end;
end;

begin
  ProveFail := (ParamCount >= 1) and (ParamStr(1) = '--fail');
  OrderRules();
  Growth();
  Cost();
  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Sink < 0 then Writeln('sink: ', Sink);   { never taken; keeps Sink live }
  if Failed = 0 then Halt(0) else Halt(1);
end.
