{******************************************************************************
  Phosphor BASIC -- configuration (INI) library (a function package)

  MIT License. Copyright (c) 2026 Andre Murta.

  A config is a handle over a TMemIniFile bound to a file. An empty section name
  means the default section ("General"), so the s-suffixed calls and an explicit
  "" reach the same place. Numbers are stored in a FIXED (invariant) format, not
  the machine locale, so a value written on one system reads the same on another.
  The handle tracks whether it has unsaved changes; with autosave on, every set
  reaches the disk at once. Errors are RETURNED (a bad handle is rejected by
  GetConfig), never raised.
******************************************************************************}
unit PhosphorConfigLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, IniFiles,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles, PhosphorSandbox;

procedure RegisterConfigFuncs(Reg: TPhosphorRegistry);

implementation

var
  InvFS: TFormatSettings;

type
  TPhosphorConfig = class
    Ini: TMemIniFile;
    FileName: String;
    Modified: Boolean;
    AutoSave: Boolean;
    constructor Create(const APath: String; AAuto: Boolean);
    destructor Destroy; override;
    procedure Touch;
    function Save: Boolean;
    procedure Reload;
  end;

constructor TPhosphorConfig.Create(const APath: String; AAuto: Boolean);
var
  bound: String;
begin
  inherited Create();
  // AN .INI IS A FILE, and is confined like any other. Outside the sandbox root
  // no file is bound at all: the object still exists and still works in memory,
  // FileName is empty, and Save answers 0 -- an honest refusal the program can
  // see, rather than a nil handle or a write somewhere it did not ask for.
  // Until this guard, cfg_open@ + cfg_save wrote an .ini anywhere on the disk
  // while file_writealltext to the same path was refused.
  if SandboxAllows(APath, puWrite) then bound := APath else bound := '';
  FileName := bound;
  Ini := TMemIniFile.Create(bound);   // reads the file if it exists
  Modified := False;
  AutoSave := AAuto;
end;

destructor TPhosphorConfig.Destroy;
begin
  // TMemIniFile flushes pending changes when it is freed, which would recreate a
  // file the program had deleted. Drop the file binding first so that flush (on
  // the finalization sweep) writes nothing -- an explicit cfg_save is the only
  // way a config reaches disk.
  Ini.Rename('', False);
  Ini.Free;
  inherited Destroy();
end;

function TPhosphorConfig.Save: Boolean;
begin
  // No file bound means the path was refused when this was opened. Answering
  // False is what lets cfg_save report it; UpdateFile on an empty name would
  // write into the process's working directory, which is precisely the escape
  // this exists to stop.
  Result := FileName <> '';
  if not Result then Exit;
  Ini.UpdateFile;
  Modified := False;
end;

procedure TPhosphorConfig.Touch;
begin
  Modified := True;
  if AutoSave then Save();
end;

procedure TPhosphorConfig.Reload;
begin
  // Re-read from disk, discarding cached in-memory changes. Rename (to the same
  // file, Reload=True) is the reload path; freeing and re-creating would flush
  // the pending changes on the way out.
  Ini.Rename(FileName, True);
  Modified := False;
end;

// --- helpers ----------------------------------------------------------------
function GetConfig(const V: TValue; out C: TPhosphorConfig; out Err: TPhosphorError): Boolean;
begin
  C := nil;
  if (V.Kind <> vkHandle) or (not IsHandle(V.Hnd)) or (not (HandleObj(V.Hnd) is TPhosphorConfig)) then
  begin
    Err := MakeError(peRuntime, 'not a valid config handle');
    Exit(False);
  end;
  C := TPhosphorConfig(HandleObj(V.Hnd));
  Err := NoError();
  Result := True;
end;

function SecName(const S: String): String;
begin
  if S = '' then Result := 'General' else Result := S;
end;

function JoinList(L: TStrings): String;
var i: Integer;
begin
  Result := '';
  for i := 0 to L.Count - 1 do
  begin
    if i > 0 then Result := Result + #10;
    Result := Result + L[i];
  end;
end;

// --- constructors and handle info -------------------------------------------
function t_cfg_open(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValHandle(RegisterHandle(TPhosphorConfig.Create(Args[0].Str, False))); end;
function t_cfg_open_auto(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValHandle(RegisterHandle(TPhosphorConfig.Create(Args[0].Str, True))); end;
function t_cfg_filename(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig;
begin
  Result := ValStr('');
  if GetConfig(Args[0], c, Err) then Result := ValStr(c.FileName);
end;
function t_cfg_path(const Args: array of TValue; out Err: TPhosphorError): TValue;
var d: String;
begin
  Err := NoError();
  // Under a sandbox the config directory is inside the root, like temppath$ --
  // a script that writes its settings where cfg_path$ points then stays contained
  // instead of reaching the real user profile.
  if SandboxActive then begin Result := ValStr(SandboxScratchPath); Exit; end;
  d := GetAppConfigDir(False);
  if d = '' then d := GetTempDir;
  Result := ValStr(d);
end;

// --- string get/set ---------------------------------------------------------
function t_cfg_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig;
begin
  Result := Args[0];
  if not GetConfig(Args[0], c, Err) then Exit;
  c.Ini.WriteString(SecName(Args[1].Str), Args[2].Str, Args[3].Str);
  c.Touch();
end;
function t_cfg_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig; sec: String;
begin
  Result := Args[3];
  if not GetConfig(Args[0], c, Err) then Exit;
  sec := SecName(Args[1].Str);
  if c.Ini.ValueExists(sec, Args[2].Str) then Result := ValStr(c.Ini.ReadString(sec, Args[2].Str, ''));
end;
function t_cfg_sets(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig;
begin
  Result := Args[0];
  if not GetConfig(Args[0], c, Err) then Exit;
  c.Ini.WriteString('General', Args[1].Str, Args[2].Str);
  c.Touch();
end;
function t_cfg_gets(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig;
begin
  Result := Args[2];
  if not GetConfig(Args[0], c, Err) then Exit;
  if c.Ini.ValueExists('General', Args[1].Str) then Result := ValStr(c.Ini.ReadString('General', Args[1].Str, ''));
end;

// --- number get/set (invariant format) --------------------------------------
procedure WriteNum(c: TPhosphorConfig; const Sec, Key: String; V: Double);
begin
  c.Ini.WriteString(Sec, Key, FloatToStr(V, InvFS));
  c.Touch();
end;
function ReadNum(c: TPhosphorConfig; const Sec, Key: String; const Def: TValue): TValue;
begin
  if c.Ini.ValueExists(Sec, Key) then
    Result := ValDouble(StrToFloatDef(c.Ini.ReadString(Sec, Key, ''), 0, InvFS))
  else
    Result := Def;
end;
function t_cfg_setn(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig;
begin
  Result := Args[0];
  if not GetConfig(Args[0], c, Err) then Exit;
  WriteNum(c, SecName(Args[1].Str), Args[2].Str, AsDouble(Args[3]));
end;
function t_cfg_getn(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig;
begin
  Result := Args[3];
  if not GetConfig(Args[0], c, Err) then Exit;
  Result := ReadNum(c, SecName(Args[1].Str), Args[2].Str, Args[3]);
end;
function t_cfg_setns(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig;
begin
  Result := Args[0];
  if not GetConfig(Args[0], c, Err) then Exit;
  WriteNum(c, 'General', Args[1].Str, AsDouble(Args[2]));
end;
function t_cfg_getns(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig;
begin
  Result := Args[2];
  if not GetConfig(Args[0], c, Err) then Exit;
  Result := ReadNum(c, 'General', Args[1].Str, Args[2]);
end;

// --- boolean get/set ("1"/"0") ----------------------------------------------
function ReadBool(c: TPhosphorConfig; const Sec, Key: String; const Def: TValue): TValue;
begin
  if c.Ini.ValueExists(Sec, Key) then
    Result := ValInt(Ord(c.Ini.ReadString(Sec, Key, '0') = '1'))
  else
    Result := Def;
end;
function t_cfg_setb(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig;
begin
  Result := Args[0];
  if not GetConfig(Args[0], c, Err) then Exit;
  c.Ini.WriteString(SecName(Args[1].Str), Args[2].Str, IntToStr(Ord(AsDouble(Args[3]) <> 0)));
  c.Touch();
end;
function t_cfg_getb(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig;
begin
  Result := Args[3];
  if not GetConfig(Args[0], c, Err) then Exit;
  Result := ReadBool(c, SecName(Args[1].Str), Args[2].Str, Args[3]);
end;
function t_cfg_setbs(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig;
begin
  Result := Args[0];
  if not GetConfig(Args[0], c, Err) then Exit;
  c.Ini.WriteString('General', Args[1].Str, IntToStr(Ord(AsDouble(Args[2]) <> 0)));
  c.Touch();
end;
function t_cfg_getbs(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig;
begin
  Result := Args[2];
  if not GetConfig(Args[0], c, Err) then Exit;
  Result := ReadBool(c, 'General', Args[1].Str, Args[2]);
end;

// --- queries ----------------------------------------------------------------
function t_cfg_exists(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig;
begin
  Result := ValInt(0);
  if not GetConfig(Args[0], c, Err) then Exit;
  Result := ValInt(Ord(c.Ini.ValueExists(SecName(Args[1].Str), Args[2].Str)));
end;
function t_cfg_haskey(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig;
begin
  Result := ValInt(0);
  if not GetConfig(Args[0], c, Err) then Exit;
  Result := ValInt(Ord(c.Ini.ValueExists('General', Args[1].Str)));
end;
function t_cfg_section_exists(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig;
begin
  Result := ValInt(0);
  if not GetConfig(Args[0], c, Err) then Exit;
  Result := ValInt(Ord(c.Ini.SectionExists(Args[1].Str)));
end;
function t_cfg_keycount(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig; l: TStringList;
begin
  Result := ValInt(0);
  if not GetConfig(Args[0], c, Err) then Exit;
  l := TStringList.Create();
  try
    c.Ini.ReadSection(Args[1].Str, l);
    Result := ValInt(l.Count);
  finally
    l.Free;
  end;
end;
function t_cfg_sectioncount(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig; l: TStringList;
begin
  Result := ValInt(0);
  if not GetConfig(Args[0], c, Err) then Exit;
  l := TStringList.Create();
  try
    c.Ini.ReadSections(l);
    Result := ValInt(l.Count);
  finally
    l.Free;
  end;
end;

// --- enumeration (newline-separated) ----------------------------------------
function t_cfg_sections(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig; l: TStringList;
begin
  Result := ValStr('');
  if not GetConfig(Args[0], c, Err) then Exit;
  l := TStringList.Create();
  try
    c.Ini.ReadSections(l);
    Result := ValStr(JoinList(l));
  finally
    l.Free;
  end;
end;
function t_cfg_keys(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig; l: TStringList;
begin
  Result := ValStr('');
  if not GetConfig(Args[0], c, Err) then Exit;
  l := TStringList.Create();
  try
    c.Ini.ReadSection(Args[1].Str, l);
    Result := ValStr(JoinList(l));
  finally
    l.Free;
  end;
end;

// --- persistence ------------------------------------------------------------
function t_cfg_modified(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig;
begin
  Result := ValInt(0);
  if not GetConfig(Args[0], c, Err) then Exit;
  Result := ValInt(Ord(c.Modified));
end;
function t_cfg_save(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig;
begin
  Result := ValInt(0);
  if not GetConfig(Args[0], c, Err) then Exit;
  Result := ValInt(Ord(c.Save()));
end;
function t_cfg_reload(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig;
begin
  Result := Args[0];
  if not GetConfig(Args[0], c, Err) then Exit;
  c.Reload();
end;

// --- deletion ---------------------------------------------------------------
function t_cfg_delete(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig;
begin
  Result := Args[0];
  if not GetConfig(Args[0], c, Err) then Exit;
  c.Ini.DeleteKey(SecName(Args[1].Str), Args[2].Str);
  c.Touch();
end;
function t_cfg_deletekey(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig;
begin
  Result := Args[0];
  if not GetConfig(Args[0], c, Err) then Exit;
  c.Ini.DeleteKey('General', Args[1].Str);
  c.Touch();
end;
function t_cfg_section_delete(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig;
begin
  Result := Args[0];
  if not GetConfig(Args[0], c, Err) then Exit;
  c.Ini.EraseSection(Args[1].Str);
  c.Touch();
end;
function t_cfg_clear(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig;
begin
  Result := Args[0];
  if not GetConfig(Args[0], c, Err) then Exit;
  c.Ini.Clear();
  c.Touch();
end;

// --- autosave ---------------------------------------------------------------
function t_cfg_autosave(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig;
begin
  Result := Args[0];
  if not GetConfig(Args[0], c, Err) then Exit;
  c.AutoSave := AsDouble(Args[1]) <> 0;
end;

procedure RegisterConfigFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('cfg_open@:$',          @t_cfg_open);
  Reg.Add('cfg_open_auto@:$',     @t_cfg_open_auto);
  Reg.Add('cfg_filename$:@',      @t_cfg_filename);
  Reg.Add('cfg_path$:',           @t_cfg_path);
  Reg.Add('cfg_set@:@$$$',        @t_cfg_set);
  Reg.Add('cfg_get$:@$$$',        @t_cfg_get);
  Reg.Add('cfg_sets@:@$$',        @t_cfg_sets);
  Reg.Add('cfg_gets$:@$$',        @t_cfg_gets);
  Reg.Add('cfg_setn@:@$$n',       @t_cfg_setn);
  Reg.Add('cfg_getn:@$$n',        @t_cfg_getn);
  Reg.Add('cfg_setns@:@$n',       @t_cfg_setns);
  Reg.Add('cfg_getns:@$n',        @t_cfg_getns);
  Reg.Add('cfg_setb@:@$$n',       @t_cfg_setb);
  Reg.Add('cfg_getb:@$$n',        @t_cfg_getb);
  Reg.Add('cfg_setbs@:@$n',       @t_cfg_setbs);
  Reg.Add('cfg_getbs:@$n',        @t_cfg_getbs);
  Reg.Add('cfg_exists:@$$',       @t_cfg_exists);
  Reg.Add('cfg_haskey:@$',        @t_cfg_haskey);
  Reg.Add('cfg_section_exists:@$',@t_cfg_section_exists);
  Reg.Add('cfg_keycount:@$',      @t_cfg_keycount);
  Reg.Add('cfg_sectioncount:@',   @t_cfg_sectioncount);
  Reg.Add('cfg_sections$:@',      @t_cfg_sections);
  Reg.Add('cfg_keys$:@$',         @t_cfg_keys);
  Reg.Add('cfg_modified:@',       @t_cfg_modified);
  Reg.Add('cfg_save:@',           @t_cfg_save);
  Reg.Add('cfg_reload@:@',        @t_cfg_reload);
  Reg.Add('cfg_delete@:@$$',      @t_cfg_delete);
  Reg.Add('cfg_deletekey@:@$',    @t_cfg_deletekey);
  Reg.Add('cfg_section_delete@:@$', @t_cfg_section_delete);
  Reg.Add('cfg_clear@:@',         @t_cfg_clear);
  Reg.Add('cfg_autosave@:@n',     @t_cfg_autosave);
end;

initialization
  InvFS := DefaultFormatSettings;
  InvFS.DecimalSeparator := '.';
  InvFS.ThousandSeparator := #0;

end.
