{******************************************************************************
  Phosphor BASIC -- regular-expression library (a function package)

  MIT License. Copyright (c) 2026 Andre Murta.

  Thin wrappers over the RTL's TRegExpr. Throughout, the PATTERN comes first and
  the text second (the opposite of instr and most of StrLib). Positions are
  1-based and absence is 0 -- the same base as instr in this engine. Group 0 is
  the whole match; the find-list functions answer a string-list handle, which
  StrListLib reads back. A malformed pattern is RETURNED as an error, not raised.

  THE ONE LIBRARY CALL THAT COULD NOT BE STOPPED. Everything below runs inside a
  single opCall, and the VM tests MaxSteps and TimeoutMs only BETWEEN
  instructions -- so a host that set every ceiling docs/embedding.md prescribes
  still waited for ever on

      regex_find$("(a+)+$", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!")

  forty characters and a nine-character pattern, 2^40 attempts. Worse than the
  string builders, this one cannot be charged as it goes: TRegExpr's matcher is a
  recursive backtracker with no step hook, no timeout property and no interrupt,
  so between Exec and its return there is no line of our code that runs at all.

  So this library obeys RULE 3 of PhosphorBudget: when -- and only when -- a host
  installed a budget, the PATTERN is judged before Exec is called, and one whose
  worst case is unbounded work is refused with a catchable error naming the
  construct. Every entry point below goes through RegexGuard, so there is no
  spelling of "run a regex" that skips the judgement; the find-all loop, which IS
  ours, charges the budget per match on top of that.

  A host that sets no ceilings gets exactly what it got before: RegexGuard's
  first line is BudgetActive, and every pattern that ran yesterday runs today.
******************************************************************************}
unit PhosphorRegexLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, RegExpr,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles, PhosphorStrListLib,
  PhosphorBudget;

procedure RegisterRegexFuncs(Reg: TPhosphorRegistry);

implementation

{ The gate every entry point asks before it builds a TRegExpr. False = do not
  run this match; Err carries the refusal.

  Charging first and judging second is deliberate: a run whose budget is already
  spent gets the ordinary "budget spent" message rather than a lecture about its
  pattern, and the charge accounts for compiling the pattern and scanning the
  subject once, which is what a WELL-BEHAVED pattern costs. }
function RegexGuard(const AFn, APattern, AText: String;
                    out Err: TPhosphorError): Boolean;
var
  why: String;
begin
  Err := NoError();
  Result := True;
  if not BudgetActive() then Exit;      // no budget installed: unchanged behaviour
  if not BudgetCharge(Int64(Length(APattern)) + Length(AText)) then
  begin
    Err := BudgetRefusal(AFn);
    Exit(False);
  end;
  if not BudgetPatternBounded(APattern, why) then
  begin
    Err := MakeError(peLimit, AFn +
      ': this pattern cannot be bounded by an execution budget -- ' + why +
      ', and the matcher cannot be interrupted once it starts');
    Exit(False);
  end;
end;

function t_regex_find(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TRegExpr;
begin
  Result := ValStr('');
  if not RegexGuard('regex_find$', Args[0].Str, Args[1].Str, Err) then Exit;
  r := TRegExpr.Create();
  try
    try
      r.Expression := Args[0].Str;
      if r.Exec(Args[1].Str) then Result := ValStr(r.Match[0]);
    except on E: Exception do Err := MakeError(peRuntime, 'regex error: ' + E.Message); end;
  finally
    r.Free;
  end;
end;

function t_regex_findpos(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TRegExpr;
begin
  Result := ValInt(0);
  if not RegexGuard('regex_findpos', Args[0].Str, Args[1].Str, Err) then Exit;
  r := TRegExpr.Create();
  try
    try
      r.Expression := Args[0].Str;
      if r.Exec(Args[1].Str) then Result := ValInt(r.MatchPos[0]);   // 1-based
    except on E: Exception do Err := MakeError(peRuntime, 'regex error: ' + E.Message); end;
  finally
    r.Free;
  end;
end;

function t_regex_findlen(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TRegExpr;
begin
  Result := ValInt(0);
  if not RegexGuard('regex_findlen', Args[0].Str, Args[1].Str, Err) then Exit;
  r := TRegExpr.Create();
  try
    try
      r.Expression := Args[0].Str;
      if r.Exec(Args[1].Str) then Result := ValInt(r.MatchLen[0]);
    except on E: Exception do Err := MakeError(peRuntime, 'regex error: ' + E.Message); end;
  finally
    r.Free;
  end;
end;

function t_regex_groupcount(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TRegExpr;
begin
  Result := ValInt(0);
  if not RegexGuard('regex_groupcount', Args[0].Str, Args[1].Str, Err) then Exit;
  r := TRegExpr.Create();
  try
    try
      r.Expression := Args[0].Str;
      if r.Exec(Args[1].Str) then Result := ValInt(r.SubExprMatchCount + 1);  // + group 0
    except on E: Exception do Err := MakeError(peRuntime, 'regex error: ' + E.Message); end;
  finally
    r.Free;
  end;
end;

function t_regex_group(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TRegExpr; n: Integer;
begin
  Result := ValStr('');
  if not RegexGuard('regex_group$', Args[0].Str, Args[1].Str, Err) then Exit;
  n := ArgI32(Args[2]);   // group number, 0 = whole match
  r := TRegExpr.Create();
  try
    try
      r.Expression := Args[0].Str;
      if r.Exec(Args[1].Str) and (n >= 0) and (n <= r.SubExprMatchCount) then
        Result := ValStr(r.Match[n]);
    except on E: Exception do Err := MakeError(peRuntime, 'regex error: ' + E.Message); end;
  finally
    r.Free;
  end;
end;

function t_regex_findall(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TRegExpr; sl: TPhosphorStringList; spent: Boolean;
begin
  Result := ValInt(0);
  if not RegexGuard('regex_findall@', Args[0].Str, Args[1].Str, Err) then Exit;
  spent := False;
  sl := TPhosphorStringList.Create();
  r := TRegExpr.Create();
  try
    try
      r.Expression := Args[0].Str;
      if r.Exec(Args[1].Str) then
        repeat
          sl.Add(r.Match[0]);
          // RULE 2: THIS loop is ours, so it is charged as it goes. An empty-width
          // match on a long subject iterates once per character, and the list it
          // builds is one string per iteration -- neither is visible to the VM.
          if not BudgetCharge(Int64(1) + Length(r.Match[0])) then
          begin
            spent := True;
            Break;
          end;
        until not r.ExecNext;
    except
      on E: Exception do begin sl.Free; sl := nil; Err := MakeError(peRuntime, 'regex error: ' + E.Message); end;
    end;
  finally
    r.Free;
  end;
  if spent then
  begin
    sl.Free;
    sl := nil;
    Err := BudgetRefusal('regex_findall@');
  end;
  if sl <> nil then Result := ValHandle(RegisterHandle(sl));
end;

function t_regex_groups(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TRegExpr; sl: TPhosphorStringList; i: Integer;
begin
  Result := ValInt(0);
  if not RegexGuard('regex_groups@', Args[0].Str, Args[1].Str, Err) then Exit;
  sl := TPhosphorStringList.Create();
  r := TRegExpr.Create();
  try
    try
      r.Expression := Args[0].Str;
      if r.Exec(Args[1].Str) then
        for i := 0 to r.SubExprMatchCount do sl.Add(r.Match[i]);   // group 0 first
    except
      on E: Exception do begin sl.Free; sl := nil; Err := MakeError(peRuntime, 'regex error: ' + E.Message); end;
    end;
  finally
    r.Free;
  end;
  if sl <> nil then Result := ValHandle(RegisterHandle(sl));
end;

function t_regex_split(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TRegExpr; sl: TPhosphorStringList; tmp: TStringList; i: Integer;
begin
  Result := ValInt(0);
  if not RegexGuard('regex_split@', Args[0].Str, Args[1].Str, Err) then Exit;
  sl := TPhosphorStringList.Create();
  r := TRegExpr.Create();
  tmp := TStringList.Create();
  try
    try
      r.Expression := Args[0].Str;
      r.Split(Args[1].Str, tmp);
      for i := 0 to tmp.Count - 1 do sl.Add(tmp[i]);
    except
      on E: Exception do begin sl.Free; sl := nil; Err := MakeError(peRuntime, 'regex error: ' + E.Message); end;
    end;
  finally
    r.Free;
    tmp.Free;
  end;
  if sl <> nil then Result := ValHandle(RegisterHandle(sl));
end;

procedure RegisterRegexFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('regex_find$:$$',      @t_regex_find);
  Reg.Add('regex_findpos:$$',    @t_regex_findpos);
  Reg.Add('regex_findlen:$$',    @t_regex_findlen);
  Reg.Add('regex_groupcount:$$', @t_regex_groupcount);
  Reg.Add('regex_group$:$$n',    @t_regex_group);
  Reg.Add('regex_findall@:$$',   @t_regex_findall);
  Reg.Add('regex_groups@:$$',    @t_regex_groups);
  Reg.Add('regex_split@:$$',     @t_regex_split);
end;

end.
