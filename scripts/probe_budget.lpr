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
  SysUtils, PhosphorErrors, PhosphorEngine, PhosphorBudget,
  // One OPT-IN package, registered below: base64_valid is a quadratic-append
  // door of exactly the family this probe pins, and it lives in host/packages
  // rather than engine/libs, so a probe that only linked the engine could not
  // reach it. host\packages is already on this probe's unit path.
  PhosphorBase64Lib;

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

var
  aaa: String;
  remMs: Int64;
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
  { The rule refuses two shapes and nothing else: an unbounded repeat of a group
    that itself repeats without bound, and an unbounded repeat of an alternation
    whose branches can start on the same byte. Everything it cannot parse
    confidently is ALLOWED, because refusing a legitimate pattern is the failure
    this half must not have. }
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
  Pattern('(a|ab)+', False);
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
    remembered, and 100 of the 7225 name/pattern pairs of length 0..3 over
    {a,b,*,?} came back 0 where the pristine recursive matcher said 1. The first
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

  { End to end, not just the judge in isolation. }
  Allowed('a unix-path regex answers under a budget',
          'println regex_find$("^(/[^/]+)+$", "/usr/local/bin")' + LF,
          '/usr/local/bin' + LF);
  Allowed('a dotted-version regex answers under a budget',
          'println regex_find$("^([0-9]+\\.)+[0-9]+$", "1.2.3")' + LF, '1.2.3' + LF);
  Allowed('a domain regex answers under a budget',
          'println regex_find$("([\\w-]+\\.)+[a-z]{2,}", "www.example.com")' + LF,
          'www.example.com' + LF);

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

  Sink.Free;
  Writeln('ok: ', Ok);
  Writeln('fail: ', Failed);
  if Failed > 0 then Halt(1) else Halt(0);
end.
