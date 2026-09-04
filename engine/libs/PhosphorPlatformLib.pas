{******************************************************************************
  Phosphor BASIC -- platform info and the standard-library remainder

  MIT License. Copyright (c) 2026 Andre Murta.

  os_name$/os_platform$/os_architecture$ identify the running system; the name
  is decided at COMPILE time by FPC's platform IFDEFs (WINDOWS/DARWIN/LINUX) and
  the platform/architecture strings come from the target macros, so the answer
  is exact, not guessed. The version numbers come from the OS (Win32*Version on
  Windows, /proc on Linux), and os_check answers whether the system is at least
  a given version. The rest is StdLib: pointer round-trips (number/isassigned),
  classname$ (which consults the handle registry so a fabricated address answers
  "" rather than dereferencing), sign, isnull, pause and formatsettings.
******************************************************************************}
unit PhosphorPlatformLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles;

procedure RegisterPlatformFuncs(Reg: TPhosphorRegistry);

implementation

// --- platform identity ------------------------------------------------------
function t_os_name(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  {$IFDEF WINDOWS}
    Result := ValStr('Windows');
  {$ELSE}
    {$IFDEF DARWIN}
      Result := ValStr('macOS');
    {$ELSE}
      {$IFDEF LINUX}
        Result := ValStr('Linux');
      {$ELSE}
        Result := ValStr('Unix');
      {$ENDIF}
    {$ENDIF}
  {$ENDIF}
end;
function t_os_platform(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValStr({$I %FPCTARGETOS%}); end;
function t_os_architecture(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValStr({$I %FPCTARGETCPU%}); end;

// --- platform version -------------------------------------------------------
// FPC 3.2.2 has no TOSVersion. Windows exposes Win32MajorVersion&c through
// SysUtils (no forbidden 'windows' unit); Linux reads /proc via a plain text
// file (no forbidden 'baseunix'). Values are read once at startup.
var
  GMaj, GMin, GBld: Integer;

{$IFDEF LINUX}
function ReadFirstLine(const APath: String): String;
var f: Text;
begin
  Result := '';
  AssignFile(f, APath);
  {$push}{$I-} Reset(f); {$pop}
  if IOResult = 0 then
  begin
    if not Eof(f) then ReadLn(f, Result);
    CloseFile(f);
  end;
end;
function NthNumber(const S: String; AIdx: Integer): Integer;
var i, cnt: Integer; cur: String;
begin
  Result := 0; cnt := 0; cur := '';
  for i := 1 to Length(S) + 1 do
    if (i <= Length(S)) and (S[i] >= '0') and (S[i] <= '9') then cur := cur + S[i]
    else if cur <> '' then
    begin
      Inc(cnt);
      if cnt = AIdx then begin Result := StrToIntDef(cur, 0); Exit; end;
      cur := '';
    end;
end;
{$ENDIF}

procedure InitOsVersion;
{$IFDEF LINUX} var rel: String; {$ENDIF}
begin
  {$IFDEF WINDOWS}
    GMaj := Win32MajorVersion; GMin := Win32MinorVersion; GBld := Win32BuildNumber;
  {$ELSE}
    {$IFDEF LINUX}
      rel := ReadFirstLine('/proc/sys/kernel/osrelease');   // e.g. "6.8.0-51-generic"
      GMaj := NthNumber(rel, 1); GMin := NthNumber(rel, 2); GBld := NthNumber(rel, 3);
    {$ELSE}
      GMaj := 1; GMin := 0; GBld := 0;   // conservative default (e.g. a future macOS)
    {$ENDIF}
  {$ENDIF}
  if GMaj < 1 then GMaj := 1;   // every supported platform reports at least 1
end;

function t_os_major(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(GMaj); end;
function t_os_minor(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(GMin); end;
function t_os_build(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(GBld); end;
function t_os_spmajor(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(0); end;   // service packs not tracked
function t_os_spminor(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(0); end;

// running system >= (major, minor, build)?
function OsAtLeast(AMajor, AMinor, ABuild: Integer): Boolean;
begin
  if GMaj <> AMajor then Result := GMaj > AMajor
  else if GMin <> AMinor then Result := GMin > AMinor
  else Result := GBld >= ABuild;
end;
function t_os_check(const Args: array of TValue; out Err: TPhosphorError): TValue;
var b: Integer;
begin
  Err := NoError();
  if Length(Args) >= 3 then b := Round(AsDouble(Args[2])) else b := 0;
  Result := ValInt(Ord(OsAtLeast(Round(AsDouble(Args[0])), Round(AsDouble(Args[1])), b)));
end;

// --- StdLib: pointer round-trips --------------------------------------------
function t_number(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if Args[0].Kind = vkHandle then Result := ValInt(Args[0].Hnd) else Result := ValInt(0);
end;
function t_isassigned(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(Ord((Args[0].Kind = vkHandle) and (Args[0].Hnd <> 0)));
end;
function t_classname(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  // Consult the registry BEFORE dereferencing: a fabricated address answers ""
  // instead of reading whatever happens to live there.
  Err := NoError();
  Result := ValStr('');
  if (Args[0].Kind = vkHandle) and IsHandle(Args[0].Hnd) then
    Result := ValStr(HandleObj(Args[0].Hnd).ClassName);
end;

// --- StdLib: sign, isnull, pause --------------------------------------------
function t_sign(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: Double;
begin
  Err := NoError(); d := AsDouble(Args[0]);
  if d < 0 then Result := ValInt(-1) else if d > 0 then Result := ValInt(1) else Result := ValInt(0);
end;
function t_isnull(const Args: array of TValue; out Err: TPhosphorError): TValue;
var s: String;
begin
  Err := NoError(); s := Args[0].Str;
  Result := ValInt(Ord((Length(s) = 1) and (s[1] = #0)));
end;
function t_pause(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ms: Integer;
begin
  Err := NoError();
  ms := Round(AsDouble(Args[0]) * 1000);
  if ms > 0 then Sleep(ms);
  Result := ValInt(0);
end;

// --- StdLib: process-wide format settings by name ---------------------------
function t_formatsettings_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  case LowerCase(Args[0].Str) of
    'dateseparator':     Result := ValStr(DefaultFormatSettings.DateSeparator);
    'timeseparator':     Result := ValStr(DefaultFormatSettings.TimeSeparator);
    'decimalseparator':  Result := ValStr(DefaultFormatSettings.DecimalSeparator);
    'thousandseparator': Result := ValStr(DefaultFormatSettings.ThousandSeparator);
    'listseparator':     Result := ValStr(DefaultFormatSettings.ListSeparator);
    'shortdateformat':   Result := ValStr(DefaultFormatSettings.ShortDateFormat);
    'longdateformat':    Result := ValStr(DefaultFormatSettings.LongDateFormat);
    'shorttimeformat':   Result := ValStr(DefaultFormatSettings.ShortTimeFormat);
    'longtimeformat':    Result := ValStr(DefaultFormatSettings.LongTimeFormat);
  else
    Result := ValStr('');
  end;
end;
function t_formatsettings_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var v: String; c: Char;
begin
  Err := NoError();
  v := Args[1].Str;
  if v <> '' then c := v[1] else c := #0;
  case LowerCase(Args[0].Str) of
    'dateseparator':     DefaultFormatSettings.DateSeparator := c;
    'timeseparator':     DefaultFormatSettings.TimeSeparator := c;
    'decimalseparator':  DefaultFormatSettings.DecimalSeparator := c;
    'thousandseparator': DefaultFormatSettings.ThousandSeparator := c;
    'listseparator':     DefaultFormatSettings.ListSeparator := c;
    'shortdateformat':   DefaultFormatSettings.ShortDateFormat := v;
    'longdateformat':    DefaultFormatSettings.LongDateFormat := v;
    'shorttimeformat':   DefaultFormatSettings.ShortTimeFormat := v;
    'longtimeformat':    DefaultFormatSettings.LongTimeFormat := v;
  else
    begin Result := ValInt(0); Exit; end;
  end;
  Result := ValInt(1);
end;

procedure RegisterPlatformFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('os_name$:',          @t_os_name);
  Reg.Add('os_platform$:',      @t_os_platform);
  Reg.Add('os_architecture$:',  @t_os_architecture);
  Reg.Add('os_major:',          @t_os_major);
  Reg.Add('os_minor:',          @t_os_minor);
  Reg.Add('os_build:',          @t_os_build);
  Reg.Add('os_spmajor:',        @t_os_spmajor);
  Reg.Add('os_spminor:',        @t_os_spminor);
  Reg.Add('os_check:nn',        @t_os_check);
  Reg.Add('os_check:nnn',       @t_os_check);
  Reg.Add('number:@',           @t_number);
  Reg.Add('isassigned:@',       @t_isassigned);
  Reg.Add('classname$:@',       @t_classname);
  Reg.Add('sign:n',             @t_sign);
  Reg.Add('isnull:$',           @t_isnull);
  Reg.Add('pause:n',            @t_pause);
  Reg.Add('formatsettings$:$',  @t_formatsettings_get);
  Reg.Add('formatsettings:$$',  @t_formatsettings_set);
end;

initialization
  InitOsVersion();

end.
