{******************************************************************************
  Phosphor BASIC -- regular-expression library (a function package)

  MIT License. Copyright (c) 2026 Andre Murta.

  Thin wrappers over the RTL's TRegExpr. Throughout, the PATTERN comes first and
  the text second (the opposite of instr and most of StrLib). Positions are
  1-based and absence is 0 -- the same base as instr in this engine. Group 0 is
  the whole match; the find-list functions answer a string-list handle, which
  StrListLib reads back. A malformed pattern is RETURNED as an error, not raised.
******************************************************************************}
unit PhosphorRegexLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, RegExpr,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles, PhosphorStrListLib;

procedure RegisterRegexFuncs(Reg: TPhosphorRegistry);

implementation

function t_regex_find(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TRegExpr;
begin
  Result := ValStr('');
  Err := NoError();
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
  Err := NoError();
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
  Err := NoError();
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
  Err := NoError();
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
  Err := NoError();
  n := Round(AsDouble(Args[2]));   // group number, 0 = whole match
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
var r: TRegExpr; sl: TPhosphorStringList;
begin
  Result := ValInt(0);
  Err := NoError();
  sl := TPhosphorStringList.Create();
  r := TRegExpr.Create();
  try
    try
      r.Expression := Args[0].Str;
      if r.Exec(Args[1].Str) then
        repeat sl.Add(r.Match[0]); until not r.ExecNext;
    except
      on E: Exception do begin sl.Free; sl := nil; Err := MakeError(peRuntime, 'regex error: ' + E.Message); end;
    end;
  finally
    r.Free;
  end;
  if sl <> nil then Result := ValHandle(RegisterHandle(sl));
end;

function t_regex_groups(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TRegExpr; sl: TPhosphorStringList; i: Integer;
begin
  Result := ValInt(0);
  Err := NoError();
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
  Err := NoError();
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
