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
  PhosphorValue, PhosphorErrors, PhosphorRegistry;

procedure RegisterSysFuncs(Reg: TPhosphorRegistry);

implementation

const
  ColorNames: array[0..15] of String =
    ('Black', 'Maroon', 'Green', 'Olive', 'Navy', 'Purple', 'Teal', 'Gray',
     'Silver', 'Red', 'Lime', 'Yellow', 'Blue', 'Fuchsia', 'Aqua', 'White');
  ColorVals: array[0..15] of Integer =
    (0, $000080, $008000, $008080, $800000, $800080, $808000, $808080,
     $C0C0C0, $0000FF, $00FF00, $00FFFF, $FF0000, $FF00FF, $FFFF00, $FFFFFF);

// --- process arguments ------------------------------------------------------
function t_paramcount(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValInt(ParamCount); end;
function t_paramstr(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValStr(ParamStr(Round(AsDouble(Args[0])))); end;

// --- separators -------------------------------------------------------------
function t_dirseparator(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValStr(PathDelim); end;
function t_pathseparator(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValStr(PathSep); end;
function t_altseparator(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  {$IFDEF WINDOWS} Result := ValStr('/'); {$ELSE} Result := ValStr(''); {$ENDIF}
end;

// --- known and optional paths -----------------------------------------------
function t_temppath(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValStr(GetTempDir(False)); end;
function t_homepath(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValStr(GetUserDir); end;
function t_documentspath(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValStr(IncludeTrailingPathDelimiter(GetUserDir) + 'Documents' + PathDelim); end;
// Answered but empty on desktop by design (the tests only require they return).
function t_emptypath(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValStr(''); end;

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
begin Err := NoError; Result := ValStr(GetTempFileName); end;
function t_randomfilename(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValStr(GuidHex(False)); end;
function t_guidfilename(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValStr(GuidHex(AsDouble(Args[0]) <> 0)); end;

// --- directories, files -----------------------------------------------------
function t_mkdir(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; CreateDir(Args[0].Str); Result := ValInt(1); end;
function t_rmdir(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; RemoveDir(Args[0].Str); Result := ValInt(1); end;
function t_forcedirectories(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValInt(Ord(ForceDirectories(Args[0].Str))); end;
function t_chdir(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; SetCurrentDir(Args[0].Str); Result := ValInt(1); end;
function t_fileexists(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValInt(Ord(FileExists(Args[0].Str, AsDouble(Args[1]) <> 0))); end;
function t_kill(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; DeleteFile(Args[0].Str); Result := ValInt(1); end;

// --- environment ------------------------------------------------------------
function t_environ(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValStr(GetEnvironmentVariable(Args[0].Str)); end;

// --- colours ----------------------------------------------------------------
function ColorOf(const AName: String): Integer;
var i: Integer;
begin
  for i := 0 to High(ColorNames) do
    if SameText(ColorNames[i], AName) then Exit(ColorVals[i]);
  Result := StrToIntDef(AName, 0);   // a '$rrggbb' or decimal literal also reads
end;
function t_colortostr(const Args: array of TValue; out Err: TPhosphorError): TValue;
var n, i: Integer;
begin
  Err := NoError;
  n := Round(AsDouble(Args[0]));
  for i := 0 to High(ColorVals) do
    if ColorVals[i] = n then begin Result := ValStr(ColorNames[i]); Exit; end;
  Result := ValStr('$' + IntToHex(n, 6));
end;
function t_color(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValInt(ColorOf(Args[0].Str)); end;
function t_alphacolor(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValInt(Int64(ColorOf(Args[0].Str)) or $FF000000); end;   // opaque alpha

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
