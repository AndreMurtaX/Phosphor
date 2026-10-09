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
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles, PhosphorSandbox,
  PhosphorBudget;

procedure RegisterConfigFuncs(Reg: TPhosphorRegistry);

implementation

type
  TPhosphorConfig = class
    Ini: TMemIniFile;
    FileName: String;
    Modified: Boolean;
    AutoSave: Boolean;
    Enc: TEncoding;       // the encoding the file was read in, as ReadIniValues keeps it
    OwnsEnc: Boolean;
    Bom: Boolean;
    constructor Create(const APath: String; AAuto: Boolean);
    destructor Destroy; override;
    procedure Touch;
    function Save: Boolean;
    procedure Reload;
    procedure LoadFile;
  end;

{ THE LINES THE RTL CANNOT KEEP (ledger d12).

  TMemIniFile has ONE comment marker, ';' (inifiles.pp, the Comment constant), and
  its rule for the rest is "a line I cannot parse": inside a section, a line with
  no '=' becomes a key with an EMPTY name and goes back out as "=" + the line, and
  before the first section anything that is not a ';' comment is dropped. So a
  hand-edited .ini -- which docs/libraries/config.md invites -- lost its "# top"
  and saved "# inner" as "=# inner", and cfg_keycount counted the comment as a key.

  So the file passes through a thin layer of lines on its way in and out. Coming
  in, every line the RTL would mangle is WRAPPED as a ';' comment carrying a
  private marker, which the RTL keeps untouched; going out, the marker is removed
  and the line is written exactly as it was read. A line that already begins with
  the marker is wrapped too, so the mapping is a bijection and no file can be
  unwrapped into something it did not say. The marker is a control character
  after ';' -- it lives in memory only and is never written.

  What is wrapped:
    * before the first section: anything that is not a ';' comment;
    * inside a section: a '#' line, and any line with no '=';
    * anywhere: a line that begins with the marker. }
{ A HEADER WITH A COMMENT AFTER IT -- `[s] ; note` -- is a header to a person and
  was not one to anyone else: the RTL wants a line that ENDS in ']', so the
  header was wrapped as a foreign line, the section never existed, its keys were
  unreadable, and a set appended a second `[s]` (2026-10-07). It is handed to the
  RTL as the bare `[s]`, followed by a line carrying HeadMark and the header as
  it was written, which Save puts back in the header's place. A line that
  already begins with HeadMark is wrapped, like one beginning with WrapMark. }
const
  WrapMark = ';' + #1;
  HeadMark = ';' + #2;

function IsWrapped(const S: String): Boolean;
begin
  Result := (Length(S) >= 2) and (S[1] = ';') and (S[2] = #1);
end;

function IsHeadMarked(const S: String): Boolean;
begin
  Result := (Length(S) >= 2) and (S[1] = ';') and (S[2] = #2);
end;

function IsHeader(const T: String): Boolean;
begin
  Result := (Length(T) >= 2) and (T[1] = '[') and (T[Length(T)] = ']');
end;

{ `[name]` followed by a comment: AHeader is the `[name]` part. The first ']'
  whose remainder is a ';' or '#' comment ends the header. }
function IsCommentedHeader(const T: String; out AHeader: String): Boolean;
var p: Integer;
    rest: String;
begin
  Result := False;
  AHeader := '';
  if (T = '') or (T[1] <> '[') then Exit;
  for p := 2 to Length(T) - 1 do
    if T[p] = ']' then
    begin
      rest := TrimLeft(Copy(T, p + 1, MaxInt));
      if (rest <> '') and (rest[1] in [';', '#']) then
      begin
        AHeader := Copy(T, 1, p);
        Exit(True);
      end;
    end;
end;

procedure WrapForeign(L: TStrings);
var
  i: Integer;
  t, hdr: String;
  inSection: Boolean;
  outL: TStringList;
begin
  inSection := False;
  outL := TStringList.Create();
  try
    for i := 0 to L.Count - 1 do
    begin
      t := Trim(L[i]);
      if t = '' then begin outL.Add(L[i]); Continue; end;
      if IsWrapped(t) or IsHeadMarked(t) then begin outL.Add(WrapMark + L[i]); Continue; end;
      if IsHeader(t) then begin inSection := True; outL.Add(L[i]); Continue; end;
      if IsCommentedHeader(t, hdr) then
      begin
        inSection := True;
        outL.Add(hdr);
        outL.Add(HeadMark + L[i]);
        Continue;
      end;
      if (t[1] <> ';') and                                 // the RTL keeps those
         ((not inSection) or (t[1] = '#') or (Pos('=', t) = 0)) then
        outL.Add(WrapMark + L[i])
      else
        outL.Add(L[i]);
    end;
    L.Assign(outL);
  finally
    outL.Free;
  end;
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
  // The RTL is given NO file name: it never reads or writes the disk itself, so
  // every byte in and out goes through the line layer above.
  Ini := TMemIniFile.Create('');
  Enc := nil;
  OwnsEnc := False;
  Bom := False;
  LoadFile();
  Modified := False;
  AutoSave := AAuto;
end;

destructor TPhosphorConfig.Destroy;
begin
  // TMemIniFile flushes pending changes when it is freed. It holds no file name
  // now, so that flush has nowhere to go -- an explicit cfg_save is the only way
  // a config reaches disk, as it always was.
  Ini.Free;
  if OwnsEnc then Enc.Free;
  inherited Destroy();
end;

{ Read the bound file the way TIniFile.ReadIniValues does -- same BOM handling,
  same encoding detection -- then wrap what the RTL would mangle, and hand it the
  lines. No file, or none bound, is an empty config. }
procedure TPhosphorConfig.LoadFile;
var
  sl: TStringList;
begin
  sl := TStringList.Create();
  try
    // Asked HERE, where the file is read -- the path was judged at cfg_open@, and
    // that judgement is not this read. (check-sandbox.py named both halves of the
    // line layer the day they were written; the RTL used to do this read, out of
    // the gate's sight.)
    if (FileName <> '') and SandboxAllows(FileName, puRead) and FileExists(FileName) then
    begin
      sl.Options := sl.Options + [soPreserveBOM];
      sl.LoadFromFile(FileName, nil);
      if OwnsEnc then Enc.Free;
      if TEncoding.IsStandardEncoding(sl.Encoding) then
      begin
        Enc := sl.Encoding;
        OwnsEnc := False;
      end
      else
      begin
        Enc := sl.Encoding.Clone;
        OwnsEnc := True;
      end;
      Bom := sl.WriteBOM;
      WrapForeign(sl);
    end;
    Ini.SetStrings(sl);
  finally
    sl.Free;
  end;
end;

function TPhosphorConfig.Save: Boolean;
var
  raw, sl: TStringList;
  i: Integer;
  prevBlank, headerIsComment: Boolean;
  d: String;
begin
  // No file bound means the path was refused when this was opened. Answering
  // False is what lets cfg_save report it; writing on an empty name would land
  // in the process's working directory, which is precisely the escape this
  // exists to stop. (This refusal used to sit in front of Ini.UpdateFile; it
  // sits in front of the line layer's writer now, unchanged.)
  Result := (FileName <> '') and SandboxAllows(FileName, puWrite);
  if not Result then Exit;
  raw := TStringList.Create();
  sl := TStringList.Create();
  try
    Ini.GetStrings(raw);
    { GetStrings and UpdateFile disagree about ONE blank line: UpdateFile writes
      none after a section whose header is a comment (the comments before the
      first section), GetStrings writes one after every section. UpdateFile's
      rule is what every .ini this library ever saved was written with, so it is
      the one kept -- a Phosphor-authored file comes out byte for byte as before.
      A header is the first line or a line after a blank: the RTL keeps no blank
      line INSIDE a section, so a blank is always a separator. }
    prevBlank := True;
    headerIsComment := False;
    for i := 0 to raw.Count - 1 do
    begin
      if raw[i] = '' then
      begin
        if not headerIsComment then sl.Add('');
        prevBlank := True;
        Continue;
      end;
      if prevBlank then headerIsComment := raw[i][1] = ';';
      prevBlank := False;
      { A commented header's own text replaces the bare header the RTL kept --
        which is the line just written, since a section's first line is its
        HeadMark. Were it ever not, the text is written where it stands rather
        than lost. }
      if IsHeadMarked(raw[i]) then
      begin
        if (sl.Count > 0) and IsHeader(Trim(sl[sl.Count - 1])) then
          sl[sl.Count - 1] := Copy(raw[i], 3, MaxInt)
        else
          sl.Add(Copy(raw[i], 3, MaxInt));
      end
      else if IsWrapped(raw[i]) then sl.Add(Copy(raw[i], 3, MaxInt))
      else sl.Add(raw[i]);
    end;
    sl.WriteBOM := Bom;
    d := ExtractFilePath(FileName);
    if (d <> '') and not ForceDirectories(d) then
      raise EInOutError.CreateFmt('could not create %s', [d]);
    sl.SaveToFile(FileName, Enc);
  finally
    sl.Free;
    raw.Free;
  end;
  Modified := False;
end;

procedure TPhosphorConfig.Touch;
begin
  Modified := True;
  if AutoSave then Save();
end;

procedure TPhosphorConfig.Reload;
begin
  // Re-read from disk, discarding cached in-memory changes, through the same
  // line layer the first read went through.
  LoadFile();
  Modified := False;
end;

{ WHAT CANNOT BE WRITTEN AND READ BACK AS ITSELF IS REFUSED, AS A VALUE (ledger
  d12, the attack plan's decision 6: errors are values in this engine, and an
  escape would invent a convention a hand editor cannot see). Each rule below was
  MEASURED on the unfixed build before it was written, by writing the thing and
  reading it back:
    * a newline in a section, key or value -- the value came back cut at it, and
      the rest was a loose line the next save mangled;
    * a section beginning ';' -- written without brackets, reloaded as a comment,
      its keys gone;
    * a key beginning ';' -- written WITHOUT its value, as a comment;
    * a key beginning '#' -- it round-tripped through the RTL, but the line layer
      above reads a '#' line as a comment, which is what a hand editor means by it;
    * a key containing '=' -- read back as a shorter key holding the rest;
    * an empty key -- never written at all;
    * leading or trailing blanks on a key or a value -- the reader trims them.
  A value ending in a backslash was suspected (ifoEscapeLineFeeds) and measured to
  survive, so it is NOT refused. Answers '' when the triple can be stored.

  The number and flag setters used to skip the value half (their values are
  written by this library, never by the program). They now hand over the text
  they will write, so every setter's line is judged by the same questions --
  the header question below is about the LINE, and a rule that holds for one
  door and is assumed for the others is how the last shape was missed. }
function UnstorableWhy(const Sec, Key, Val: String): String;
var line, hdr: String;
  function HasNewline(const S: String): Boolean;
  begin
    Result := (Pos(#10, S) > 0) or (Pos(#13, S) > 0);
  end;
begin
  Result := '';
  if HasNewline(Sec) then Exit('the section name contains a line break');
  if (Sec <> '') and (Sec[1] = ';') then Exit('a section name may not begin with ";", which makes it a comment');
  if Key = '' then Exit('the key is empty');
  if HasNewline(Key) then Exit('the key contains a line break');
  if Key[1] = ';' then Exit('a key may not begin with ";", which makes it a comment');
  if Key[1] = '#' then Exit('a key may not begin with "#", which makes it a comment');
  if Pos('=', Key) > 0 then Exit('a key may not contain "=", which ends it');
  if Trim(Key) <> Key then Exit('a key may not begin or end with blanks, which the reader trims');
  if HasNewline(Val) then Exit('the value contains a line break');
  if Trim(Val) <> Val then Exit('a value may not begin or end with blanks, which the reader trims');
  { THE LINE IS JUDGED BY THE READER THAT WILL READ IT, not by a list of shapes.
    `[k` = `v]` is written `[k=v]`, a header line (2026-10-07), and a rule for
    exactly that shape was added -- the only one of 4050 triples a sweep wrote
    that did not read back. The sweep's values were too short to hold the next
    one: `[k` = `v] ;c` is written `[k=v] ;c`, which WrapForeign reads as a
    header with a comment after it, so the key was gone after a reload, a
    section `k=v` had appeared, and every key after it in its section now
    belonged to that one (2026-10-09). Both are now one question, asked of the
    line that will be written, through the two functions the load path asks:
    would IsHeader or IsCommentedHeader take it for a section header?
    tests/suite/86_config_roundtrip.bas sweeps it. }
  line := Trim(Key + '=' + Val);
  if IsHeader(line) or IsCommentedHeader(line, hdr) then
    Exit('a key beginning "[" with this value is written as a line the reader takes for a section header');
end;

function Storable(const AWho, Sec, Key, Val: String;
                  out Err: TPhosphorError): Boolean;
var why: String;
begin
  why := UnstorableWhy(Sec, Key, Val);
  Result := why = '';
  if not Result then
    Err := MakeError(peRuntime, AWho + ': cannot be stored in an .ini and read back -- ' + why);
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

{ cfg_free(c@) -- give a config back. LENIENT, like dict_free: 1 when this call
  freed it, 0 for a handle that is stale, already freed, or not a config. What
  was not saved is DISCARDED, never written: an explicit cfg_save is the only
  way a config reaches disk (TPhosphorConfig.Destroy says why), and freeing is
  not a save. Until 2026-10-08 nothing freed a config at all. }
function t_cfg_free(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(0);
  if (Args[0].Kind <> vkHandle) or (not IsHandle(Args[0].Hnd)) then Exit;
  if not (HandleObj(Args[0].Hnd) is TPhosphorConfig) then Exit;
  if FreeHandle(Args[0].Hnd) then Result := ValInt(1);
end;

function SecName(const S: String): String;
begin
  if S = '' then Result := 'General' else Result := S;
end;

{ QUADRATIC APPEND, charged as it goes (RULE 2). One append per section or key,
  and the answer is copied each time, so an ini with many keys costs O(n * total)
  where the walk that produced the list cost O(n). BudgetSpent() is what the two
  callers report; the half-built answer is never returned. }
function JoinList(L: TStrings): String;
var i: Integer;
begin
  Result := '';
  for i := 0 to L.Count - 1 do
  begin
    if not BudgetAppend(Length(Result)) then begin Result := ''; Exit; end;
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
  if not Storable('cfg_set@', Args[1].Str, Args[2].Str, Args[3].Str, Err) then Exit;
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
  if not Storable('cfg_sets@', '', Args[1].Str, Args[2].Str, Err) then Exit;
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

{ A NUMBER MUST COME BACK AS THE NUMBER THAT WENT IN, and FloatToStr alone cannot
  promise that. It formats with 15 significant digits, and an IEEE double needs 17
  to round-trip; cfg_setns@ of the user id 1234567890123457 wrote
  "1.23456789012346E15" and cfg_getns read back 1234567890123460. The loss is
  deterministic, so every machine read the same wrong number -- which is exactly
  why a byte-exact golden over an .ini file never noticed.

  The remedy used to live here, as a private ladder over FloatToStr and Str(V:24).
  It lives in PhosphorValue.NumToInv now, because it was never a config problem:
  str$ and println were losing the same digits through the same RTL cap, and one
  formatter cannot drift from itself. Read that comment for the measurement.

  What moving it changed here, and it is an improvement: the fallback keeps
  ffGeneral's shape instead of always writing an exponent, so the id above is now
  stored as 1234567890123457 rather than 1.2345678901234570E+015. Both read back
  to the same Double -- an .ini written by an older build still loads exactly --
  and the plain form is the one a person can edit. }
procedure WriteNum(c: TPhosphorConfig; const Sec, Key: String; V: Double);
begin
  c.Ini.WriteString(Sec, Key, NumToInv(V));
  c.Touch();
end;
{ THE READER THE WRITER PROVED AGAINST, and since 2026-10-09 that is
  load-bearing. WriteNum spells a value with NumToInv, which keeps a spelling
  only when PhosphorValue.ReadNumberText -- the engine's one, correctly rounded
  reader of number text -- brings it back as the same Double. This used to be
  TryStrToFloat (FPC's Val), which matched while the writer verified with Val
  too; once the writer verifies with a correctly rounded reader, Val reads about
  one value in 10000 of what it writes as the neighbouring Double (measured in
  tests/probe_value.lpr's sweep: 2 of 20000). Reading with anything but the
  writer's reader is how "exactly the number that went in" quietly stops being
  true. Text that is not a number still reads as 0, as before. }
function ReadNum(c: TPhosphorConfig; const Sec, Key: String; const Def: TValue): TValue;
var
  r: TNumberText;
begin
  if not c.Ini.ValueExists(Sec, Key) then Exit(Def);
  r := ReadNumberText(TrimNumberSpace(c.Ini.ReadString(Sec, Key, '')));
  if r.Ok then Result := ValDouble(r.Value) else Result := ValDouble(0);
end;
function t_cfg_setn(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorConfig;
begin
  Result := Args[0];
  if not GetConfig(Args[0], c, Err) then Exit;
  if not Storable('cfg_setn@', Args[1].Str, Args[2].Str, NumToInv(AsDouble(Args[3])), Err) then Exit;
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
  if not Storable('cfg_setns@', '', Args[1].Str, NumToInv(AsDouble(Args[2])), Err) then Exit;
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
  if not Storable('cfg_setb@', Args[1].Str, Args[2].Str, IntToStr(Ord(AsDouble(Args[3]) <> 0)), Err) then Exit;
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
  if not Storable('cfg_setbs@', '', Args[1].Str, IntToStr(Ord(AsDouble(Args[2]) <> 0)), Err) then Exit;
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
    if BudgetSpent() then
    begin Err := BudgetRefusal('cfg_sections$'); Result := ValStr(''); end;
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
    if BudgetSpent() then
    begin Err := BudgetRefusal('cfg_keys$'); Result := ValStr(''); end;
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
  Reg.Add('cfg_free:@',           @t_cfg_free);
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

end.
