{******************************************************************************
  Phosphor BASIC -- system library (a function package)

  MIT License. Copyright (c) 2026 Andre Murta.

  Process arguments, path separators, the platform's known directories,
  generated names, directory make/remove, file existence/removal, environment
  variables and a small colour table. Many of these answer differently per
  platform and a few are empty on desktop by design, so the tests assert that a
  call returns (rather than raising) and that a value is non-empty, not any
  particular string. mkdir/rmdir/chdir answer 1; forcedirectories reports.
  Colours are a self-contained name<->number table (the engine has no GUI).
******************************************************************************}
unit PhosphorSysLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils,
  {$IFDEF WINDOWS} windirs, {$ENDIF}   // the RTL's wide special-folder reader
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorSandbox,
  PhosphorIoLib;   // IoGate: a refusal here is recorded in ioerror() too

procedure RegisterSysFuncs(Reg: TPhosphorRegistry);

{ TEXT FROM THE HOST, AS THE ENGINE'S UTF-8 (2026-10-09, round 3). Every string
  in the engine is UTF-8 bytes. On Windows the RTL's narrow readers of the
  environment and of the known folders hand back the ANSI code page instead:
  GetEnvironmentVariable(String) reads GetEnvironmentStringsA -- characters
  outside the code page become '?' -- and tags the bytes CP_OEMCP, so
  environ$("PHX_A") of 'ação日本€' answered 'aþÒo??Ç', and a non-ASCII name was
  never found at all (it was converted to OEM before the compare). GetTempDir
  reads TEMP that way, and GetUserDir and GetAppConfigDir convert the wide
  folder path to the ANSI code page. These read the wide forms and encode
  them as UTF-8; on every other platform the environment and the paths are
  already bytes and the RTL's readers are used as they are. }
function HostEnv(const AName: String): String;
function HostTempDir: String;
function HostUserDir: String;
function HostAppConfigDir: String;

implementation

{$IFDEF WINDOWS}
{ The OS's own lookup, so a name matches exactly as Windows matches it -- with
  its Unicode case folding. The RTL's wide reader, GetEnvironmentVariable
  (UnicodeString), walks the block itself and folds only a..z, so 'ção' would
  not find 'ÇÃO', which Windows calls the same variable. Declared here, from
  kernel32 -- the unit the RTL itself links -- rather than through the
  'windows' unit, which the engine boundary keeps out. }
function GetEnvironmentVariableW(lpName, lpBuffer: PWideChar; nSize: LongWord): LongWord;
  stdcall; external 'kernel32.dll' name 'GetEnvironmentVariableW';

{ UTF-16 to the engine's UTF-8: a surrogate pair is one code point, and an
  unpaired surrogate -- which a Windows environment block can hold -- is
  U+FFFD, Utf8Char's own answer for one. }
function WideToUtf8(const W: UnicodeString): String;
var i, n, cp, o: Integer; hi, lo: Word; ch, buf: String;
begin
  n := Length(W);
  SetLength(buf, 3 * n);           // a UTF-16 unit is at most 3 bytes; a pair, 4 for 2
  o := 0;
  i := 1;
  while i <= n do
  begin
    hi := Word(W[i]);
    cp := hi;
    if (hi >= $D800) and (hi <= $DBFF) and (i < n) then
    begin
      lo := Word(W[i + 1]);
      if (lo >= $DC00) and (lo <= $DFFF) then
      begin
        cp := $10000 + ((Integer(hi) - $D800) shl 10) + (Integer(lo) - $DC00);
        Inc(i);
      end;
    end;
    ch := Utf8Char(cp);
    Move(ch[1], buf[o + 1], Length(ch));
    Inc(o, Length(ch));
    Inc(i);
  end;
  Result := Copy(buf, 1, o);
end;

{ The engine's UTF-8 to UTF-16, STRICTLY: False for bytes that are not
  well-formed UTF-8 (a stray continuation byte, a truncated or overlong
  sequence, a surrogate, a code point past U+10FFFF). No variable can be named
  by such bytes, and a lenient decoder would turn them into some other name. }
function Utf8ToWide(const S: String; out W: UnicodeString): Boolean;
var i, n, k, need, o: Integer; cp, lo: LongWord; b: Byte; buf: UnicodeString;
begin
  Result := False;
  W := '';
  n := Length(S);
  SetLength(buf, n);               // never more UTF-16 units than UTF-8 bytes
  o := 0;
  i := 1;
  while i <= n do
  begin
    b := Ord(S[i]);
    if b < $80 then begin cp := b; need := 0; lo := 0; end
    else if (b >= $C2) and (b <= $DF) then begin cp := b and $1F; need := 1; lo := $80; end
    else if (b >= $E0) and (b <= $EF) then begin cp := b and $0F; need := 2; lo := $800; end
    else if (b >= $F0) and (b <= $F4) then begin cp := b and $07; need := 3; lo := $10000; end
    else Exit;
    if i + need > n then Exit;
    for k := 1 to 3 do             // the continuation bytes: at most three
    begin
      if k > need then Break;
      b := Ord(S[i + k]);
      if (b and $C0) <> $80 then Exit;
      cp := (cp shl 6) or (b and $3F);
    end;
    if (cp < lo) or (cp > $10FFFF) or ((cp >= $D800) and (cp <= $DFFF)) then Exit;
    if cp >= $10000 then
    begin
      buf[o + 1] := WideChar($D800 + ((cp - $10000) shr 10));
      buf[o + 2] := WideChar($DC00 + ((cp - $10000) and $3FF));
      Inc(o, 2);
    end
    else
    begin
      buf[o + 1] := WideChar(cp);
      Inc(o);
    end;
    Inc(i, need + 1);
  end;
  W := Copy(buf, 1, o);
  Result := True;
end;
{$ENDIF}

function HostEnv(const AName: String): String;
{$IFDEF WINDOWS}
var wn, buf: UnicodeString; got: LongWord;
begin
  Result := '';
  if not Utf8ToWide(AName, wn) then Exit;
  { One read into a buffer of the largest value Windows sets: "the maximum size
    of a user-defined environment variable is 32,767 characters"
    (SetEnvironmentVariable's documentation). The answer is the length written,
    without its NUL, or 0 for a variable that is not set. A larger answer is the
    size a longer value would need; no such value can be set, but were one read
    the RTL's own wide reader copies it whole -- the same characters, matched by
    name with a..z folding only. }
  SetLength(buf, 32768);
  got := GetEnvironmentVariableW(PWideChar(wn), PWideChar(buf), 32768);
  if got = 0 then Exit;
  if got < 32768 then
    Result := WideToUtf8(Copy(buf, 1, got))
  else
    Result := WideToUtf8(GetEnvironmentVariable(wn));
end;
{$ELSE}
begin
  Result := GetEnvironmentVariable(AName);
end;
{$ENDIF}

{ The RTL's GetTempDir(False) -- TEMP, then TMP, with a trailing separator --
  read through HostEnv on Windows. A host that installed OnGetTempDir is asked,
  as the RTL asks it. Under a sandbox, the scratch directory inside the root:
  the decision temppath$ and cfg_path$ make, made here so that no caller can
  reach the real one by forgetting it. }
function HostTempDir: String;
begin
  if SandboxActive then Exit(SandboxScratchPath);
  {$IFDEF WINDOWS}
  if Assigned(OnGetTempDir) then Exit(GetTempDir(False));
  Result := HostEnv('TEMP');
  if Result = '' then Result := HostEnv('TMP');
  if Result <> '' then Result := IncludeTrailingPathDelimiter(Result);
  {$ELSE}
  Result := GetTempDir(False);
  {$ENDIF}
end;

{ GetUserDir: the profile folder, from the RTL's wide reader on Windows; under a
  sandbox, the scratch directory, as for HostTempDir. }
function HostUserDir: String;
begin
  if SandboxActive then Exit(SandboxScratchPath);
  {$IFDEF WINDOWS}
  Result := WideToUtf8(GetWindowsSpecialDirUnicode(CSIDL_PROFILE));
  {$ELSE}
  Result := GetUserDir;
  {$ENDIF}
end;

{ GetAppConfigDir(False), spelled as the RTL spells it on Windows -- the local
  application-data folder, then the vendor's name when there is one, then the
  application's -- from the wide folder path. ApplicationName comes from
  ParamStr(0), which the RTL already answers in UTF-8. With no such folder the
  RTL's own fallback answers. }
function HostAppConfigDir: String;
{$IFDEF WINDOWS}
var w: UnicodeString;
{$ENDIF}
begin
  {$IFDEF WINDOWS}
  w := GetWindowsSpecialDirUnicode(CSIDL_LOCAL_APPDATA);
  if w = '' then Exit(GetAppConfigDir(False));
  Result := IncludeTrailingPathDelimiter(WideToUtf8(w));
  if VendorName <> '' then Result := IncludeTrailingPathDelimiter(Result + VendorName);
  Result := IncludeTrailingPathDelimiter(Result + ApplicationName);
  {$ELSE}
  Result := GetAppConfigDir(False);
  {$ENDIF}
end;

const
  ColorNames: array[0..15] of String =
    ('Black', 'Maroon', 'Green', 'Olive', 'Navy', 'Purple', 'Teal', 'Gray',
     'Silver', 'Red', 'Lime', 'Yellow', 'Blue', 'Fuchsia', 'Aqua', 'White');
  ColorVals: array[0..15] of Integer =
    (0, $000080, $008000, $008080, $800000, $800080, $808000, $808080,
     $C0C0C0, $0000FF, $00FF00, $00FFFF, $FF0000, $FF00FF, $FFFF00, $FFFFFF);

// --- process arguments ------------------------------------------------------
function t_paramcount(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(ParamCount); end;
function t_paramstr(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValStr(ParamStr(ArgI32(Args[0]))); end;

// --- separators -------------------------------------------------------------
function t_dirseparator(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValStr(PathDelim); end;
function t_pathseparator(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValStr(PathSep); end;
function t_altseparator(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  {$IFDEF WINDOWS} Result := ValStr('/'); {$ELSE} Result := ValStr(''); {$ENDIF}
end;

// --- known and optional paths -----------------------------------------------
// Under a sandbox these answer INSIDE the root. Redirecting is better than
// refusing: a script that keeps its working files in the platform's temp
// directory then runs unchanged and contained, instead of failing on its first
// write for a reason it cannot see.
function t_temppath(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if SandboxActive then Result := ValStr(SandboxScratchPath)
  else Result := ValStr(HostTempDir);
end;
function t_homepath(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if SandboxActive then Result := ValStr(SandboxScratchPath)
  else Result := ValStr(HostUserDir);
end;
function t_documentspath(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if SandboxActive then Result := ValStr(SandboxScratchPath)
  else Result := ValStr(IncludeTrailingPathDelimiter(HostUserDir) + 'Documents' + PathDelim);
end;
// Reports the cage; it cannot open it. There is no setter registered for a
// script to call -- only the host, in Pascal, can set or clear a root.
function t_sandboxroot(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValStr(SandboxRoot); end;
// Answered but empty on desktop by design (the tests only require they return).
function t_emptypath(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValStr(''); end;

// --- generated names --------------------------------------------------------
function GuidHex(WithSeparators: Boolean): String;
var g: TGUID; s: String;
begin
  CreateGUID(g);
  s := GUIDToString(g);                 // "{XXXXXXXX-XXXX-...-XXXXXXXXXXXX}"
  s := Copy(s, 2, Length(s) - 2);       // drop the braces
  if WithSeparators then Result := s
  else Result := StringReplace(s, '-', '', [rfReplaceAll]);
end;
function t_tempfilename(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if SandboxActive then Result := ValStr(SandboxScratchPath + GuidHex(False) + '.tmp')
  else Result := ValStr(GetTempFileName(HostTempDir, ''));   // the RTL's search, in the UTF-8 temp dir
end;
function t_randomfilename(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValStr(GuidHex(False)); end;
function t_guidfilename(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValStr(GuidHex(AsDouble(Args[0]) <> 0)); end;

// --- directories, files -----------------------------------------------------
// THEY ANSWER WHAT HAPPENED. Until 2026-10-07 these four answered 1 whatever
// the filesystem said -- Plan9Basic's behaviour, kept "for the oracle" -- so
// mkdir of a directory that existed, rmdir of a full one, chdir to nowhere and
// kill of a missing file all reported success and set no error. dir_create
// and dir_delete had been fixed for exactly that a month before; the classic
// names are the same operations and had been left behind. Now 1 means it
// happened, 0 means it did not, and ioerror() says which kind of 0: 3 tried
// and failed, 5 refused (see IoAnswer). tests/suite/77_sys_answers.bas.
function t_mkdir(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if not IoGate(Args[0].Str, puWrite) then begin Result := ValInt(0); Exit; end;
  Result := IoAnswer(CreateDir(Args[0].Str));
end;
function t_rmdir(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if not IoGate(Args[0].Str, puDelete) then begin Result := ValInt(0); Exit; end;
  Result := IoAnswer(RemoveDir(Args[0].Str));
end;
function t_forcedirectories(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if not IoGate(Args[0].Str, puWrite) then begin Result := ValInt(0); Exit; end;
  // Through IoAnswer like the other mutators: a success left a refusal's 5
  // standing, and a failure recorded nothing, so it read as "refused" (2026-10-07).
  Result := IoAnswer(ForceDirectories(Args[0].Str));
end;
function t_chdir(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if not IoGate(Args[0].Str, puRead) then begin Result := ValInt(0); Exit; end;
  { "" names no directory. The sandbox refuses it, but with none in force the
    RTL's ChDir returns early on '' and reports no error, so SetCurrentDir('') is
    True and this answered 1 having moved nothing (2026-10-07). Refused, as the
    reference says, with or without a sandbox. }
  if Args[0].Str = '' then Exit(IoRefused());
  Result := IoAnswer(SetCurrentDir(Args[0].Str));
end;
function t_fileexists(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if not IoGate(Args[0].Str, puRead) then begin Result := ValInt(0); Exit; end;
  Result := IoQueried(FileExists(Args[0].Str, AsDouble(Args[1]) <> 0));
end;
function t_kill(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if not IoGate(Args[0].Str, puDelete) then begin Result := ValInt(0); Exit; end;
  Result := IoAnswer(DeleteFile(Args[0].Str));
end;

// --- environment ------------------------------------------------------------
{ A NAME THAT IS NO VARIABLE ANSWERS "" (2026-10-09, round 2). The OS is not
  asked about a name nobody can have set: on Windows environ$("") answered
  "C:=C:\..." -- the empty name matched the first entry of the environment
  block, one of the hidden per-drive "=C:" entries cmd.exe keeps there. A name
  holding "=" cannot be set (the "=" ends it), and one holding NUL is read by
  the OS only up to the NUL -- a different name from the one the program
  passed, so "PATH" + chr$(0) + "X" would be asking about PATH. }
function t_environ(const Args: array of TValue; out Err: TPhosphorError): TValue;
var name: String;
begin
  Err := NoError();
  name := Args[0].Str;
  // one scan for either character
  if (name = '') or (LastDelimiter('=' + #0, name) > 0) then
    Exit(ValStr(''));
  Result := ValStr(HostEnv(name));   // UTF-8 in and out, on Windows too (round 3)
end;

// --- colours ----------------------------------------------------------------
{ A COLOUR IS AN UNSIGNED 32-BIT NUMBER (2026-10-09, round 2): $AABBGGRR, the
  alpha byte on top -- alphacolor("Red") is 4278190335, which the page has always
  shown. The literal used to be read into a SIGNED 32-bit Integer, so
  color("4294967295") was -1 and color("2147483648") -2147483648, and
  alphacolor("$80FF0000") OR-ed the alpha byte into a negative number and
  answered -65536. It is read whole now, and a literal outside 0..2^32 - 1
  names no colour: 0, as an unknown name does. }
const
  MaxColor = Int64($FFFFFFFF);

function ColorOf(const AName: String): Int64;
var i: Integer; v: Int64;
begin
  for i := 0 to High(ColorNames) do
    if SameText(ColorNames[i], AName) then Exit(ColorVals[i]);
  // a '$rrggbb' or decimal literal also reads, as the RTL's Val reads it
  if TryStrToInt64(AName, v) and (v >= 0) and (v <= MaxColor) then
    Result := v
  else
    Result := 0;
end;

{ The whole unsigned value, in hex. The number used to be narrowed by ArgI32,
  which CLAMPS: everything from 2^31 up printed "$7FFFFFFF". A negative number is
  its 32-bit pattern, as the page has always said ("$FFFFFFFF" for -1), so the
  domain is -2^31 .. 2^32 - 1; outside it no 32-bit pattern spells the number,
  and the answer is "" -- this library answers, it does not raise. }
function t_colortostr(const Args: array of TValue; out Err: TPhosphorError): TValue;
var n: Int64; i: Integer;
begin
  Err := NoError();
  n := ArgI64(Args[0]);
  if (n < Low(Integer)) or (n > MaxColor) then Exit(ValStr(''));
  n := n and MaxColor;
  for i := 0 to High(ColorVals) do
    if ColorVals[i] = n then begin Result := ValStr(ColorNames[i]); Exit; end;
  Result := ValStr('$' + IntToHex(n, 6));
end;
function t_color(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(ColorOf(Args[0].Str)); end;
function t_alphacolor(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(ColorOf(Args[0].Str) or Int64($FF000000)); end;   // opaque alpha

procedure RegisterSysFuncs(Reg: TPhosphorRegistry);
const
  OptPaths: array[0..17] of String =
    ('shareddocumentspath$', 'librarypath$', 'cachepath$', 'publicpath$',
     'picturespath$', 'sharedpicturespath$', 'camerapath$', 'sharedcamerapath$',
     'musicpath$', 'sharedmusicpath$', 'moviespath$', 'sharedmoviespath$',
     'alarmspath$', 'sharedalarmspath$', 'downloadspath$', 'shareddownloadspath$',
     'ringtonespath$', 'sharedringtonespath$');
var i: Integer;
begin
  Reg.Add('paramcount:',       @t_paramcount);
  Reg.Add('paramstr$:n',       @t_paramstr);
  Reg.Add('dirseparator$:',    @t_dirseparator);
  Reg.Add('pathseparator$:',   @t_pathseparator);
  Reg.Add('altseparator$:',    @t_altseparator);
  Reg.Add('temppath$:',        @t_temppath);
  Reg.Add('sandboxroot$:',     @t_sandboxroot);
  Reg.Add('homepath$:',        @t_homepath);
  Reg.Add('documentspath$:',   @t_documentspath);
  for i := 0 to High(OptPaths) do
    Reg.Add(OptPaths[i] + ':', @t_emptypath);
  Reg.Add('tempfilename$:',    @t_tempfilename);
  Reg.Add('randomfilename$:',  @t_randomfilename);
  Reg.Add('guidfilename$:n',   @t_guidfilename);
  Reg.Add('mkdir:$',           @t_mkdir);
  Reg.Add('rmdir:$',           @t_rmdir);
  Reg.Add('forcedirectories:$',@t_forcedirectories);
  Reg.Add('chdir:$',           @t_chdir);
  Reg.Add('fileexists:$n',     @t_fileexists);
  Reg.Add('kill:$',            @t_kill);
  Reg.Add('environ$:$',        @t_environ);
  Reg.Add('colortostr$:n',     @t_colortostr);
  Reg.Add('color:$',           @t_color);
  Reg.Add('alphacolor:$',      @t_alphacolor);
end;

end.
