{******************************************************************************
  phosphorgui -- the interactive GUI host (the engine's second real consumer)

  MIT License. Copyright (c) 2026 Andre Murta.

  Runs a .bas program that builds a window and enters the message loop
  (app_run). The engine is unchanged and unaware: it sees the same registry and
  the same seams as the console host; the GUI libraries, registered here, are what
  turn form@/button@/button_onclick@ into real LCL controls and events.

  ALL FOUR SEAMS ARE FILLED HERE, and that is the point of the file. This host
  once assigned only OnOutput, so `phosphor --gui interactive.bas` printed every
  INPUT prompt at once and answered each one with an empty string -- the engine's
  documented behaviour for a NIL input seam, which is right for a headless runner
  and a fabricated answer in a host with a console attached. HostServices was
  likewise nil in every host in the tree, so processmessages()/handlemessage()
  answered 0 and the clipboard answered "" in the one program written to provide
  them. scripts/check-seams.py now fails the suite if a host leaves a seam nil
  without saying why.

  Usage:  phosphorgui <file.bas>
******************************************************************************}
program phosphorgui;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  // FIRST on purpose: units initialise in this order, and the guard must speak
  // before the gtk2 widgetset opens the display in its own initialization.
  PhosphorDisplayGuard,
  Interfaces,   // the LCL widgetset for this platform
  Forms, Clipbrd, LCLType,
  SysUtils, Classes,
  PhosphorEngine, PhosphorValue,
  PhosphorGuiCore, PhosphorControlLib, PhosphorFormLib, PhosphorButtonLib,
  PhosphorLabelLib, PhosphorEditLib, PhosphorChoiceLib,
  PhosphorContainerLib, PhosphorRangeLib, PhosphorMenuLib, PhosphorTimerLib,
  PhosphorImageLib, PhosphorGridLib, PhosphorTreeListLib, PhosphorCanvasLib,
  PhosphorDialogLib, PhosphorMiscLib,
  // ...and every non-GUI package as well, so this binary is the COMPLETE runner:
  // engine + all libraries + the GUI. `phosphor --gui` hands over to it.
  PhosphorCrtLib, PhosphorBase64Lib, PhosphorZipLib, PhosphorGzipLib,
  PhosphorHttpLib, PhosphorSqliteLib;

type
  { The host side of the seams. Output goes to stdout as raw bytes, the same
    contract the console host honours; input comes from stdin, because a GUI
    program run from a terminal can still be asked a question and INPUT must not
    answer for the person at the keyboard. The pump and the clipboard are the two
    services the engine deliberately does NOT implement -- it only offers the seam
    -- and a GUI host is what fills them. }
  TGuiConsole = class
    procedure Output(const AText: String);
    function ReadLine(out ALine: String): Boolean;
    function Pump: Integer;
    function PumpOne: Integer;
    function ClipCopy(const AText: String): Boolean;
    function ClipPaste(out AText: String): Boolean;
  end;

{ INPUT / LINE INPUT / INPUT$. Answering False means end of input, which is what
  lets a program reached by a pipe or a closed stdin stop asking rather than loop.
  A plain ReadLn is deliberate: the console host's reader carries UTF-16 console
  decoding this host does not need, and a copy of it would be a second thing to
  keep in step with the first. }
function TGuiConsole.ReadLine(out ALine: String): Boolean;
begin
  ALine := '';
  if EOF(Input) then Exit(False);
  ReadLn(ALine);
  Result := True;
end;

{ processmessages(): let the widgetset dispatch whatever is waiting and carry on.
  Answers 1 because a host DID pump -- the value is what tells a script the
  service is present, and 0 is what it means when it is not. }
function TGuiConsole.Pump: Integer;
begin
  Application.ProcessMessages;
  Result := 1;
end;

{ handlemessage(): wait for one message and dispatch it. }
function TGuiConsole.PumpOne: Integer;
begin
  Application.HandleMessage;
  Result := 1;
end;

{ THE CLIPBOARD IS A CONTENDED OS RESOURCE. On Windows every access opens and
  closes it, and any other process holding it at that instant -- a clipboard
  manager, the shell, another Phosphor call a millisecond earlier -- makes the
  attempt fail. Measured here: a tight copy/paste/copy loop failed on roughly one
  access in three, with no pattern in the CONTENT at all. A single try is not a
  clipboard implementation; it is a coin flip a script has to code around. Three
  quick attempts is what turns it back into a service. If all three fail the
  answer is still False -- reported, never fabricated. }
function ClipRetryCopy(const AText: String): Boolean;
var i: Integer;
begin
  // WRITE, THEN CONFIRM. The write does not land synchronously: a paste issued
  // straight after a copy reproducibly read the PREVIOUS contents -- two bytes
  // where seventeen had just been stored -- and reported no error, because the
  // read really had succeeded. It just read the old value. copytext$ is
  // documented to answer the text it stored, so it must not answer until the
  // clipboard actually holds it.
  for i := 1 to 6 do
  begin
    try
      if AText = '' then
      begin
        // Storing the empty string is CLEARING, and it has to be done with Clear:
        // assigning '' to AsText left the previous text in place, so copytext$("")
        // reported success and the next pastetext$ answered the old value.
        Clipboard.Clear;
        if not Clipboard.HasFormat(CF_TEXT) then Exit(True);
      end
      else
      begin
        Clipboard.AsText := AText;
        if Clipboard.HasFormat(CF_TEXT) and (Clipboard.AsText = AText) then Exit(True);
      end;
    except
      on Exception do ;    // held by someone else; wait and try again
    end;
    Sleep(15);
  end;
  Result := False;
end;

function ClipRetryPaste(out AText: String): Boolean;
var i: Integer; threw: Boolean;
begin
  AText := '';
  threw := False;
  for i := 1 to 3 do
  begin
    try
      if Clipboard.HasFormat(CF_TEXT) then
      begin
        AText := Clipboard.AsText;
        Exit(True);
      end;
    except
      on Exception do threw := True;
    end;
    Sleep(15);
  end;
  // No text format after three tries. Either the clipboard genuinely holds no
  // text -- readable, and '' is the true answer -- or every attempt failed, which
  // is not the same thing and must not answer as if it were. The two are told
  // apart by PERSISTENCE: contention clears within the retries, an empty
  // clipboard does not. A clipboard held by another process for longer than that
  // reads as empty; that is the bound, and it is stated rather than hidden.
  Result := not threw;
end;

function TGuiConsole.ClipCopy(const AText: String): Boolean;
begin
  Result := ClipRetryCopy(AText);
end;

function TGuiConsole.ClipPaste(out AText: String): Boolean;
begin
  Result := ClipRetryPaste(AText);
end;

procedure TGuiConsole.Output(const AText: String);
begin
  if Length(AText) > 0 then
    FileWrite(StdOutputHandle, AText[1], Length(AText));
end;

function ReadSource(const APath: String): String;
var
  fs: TFileStream;
  len: Int64;
begin
  Result := '';
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    len := fs.Size;
    SetLength(Result, len);
    if len > 0 then fs.ReadBuffer(Result[1], len);
  finally
    fs.Free;
  end;
  if (Length(Result) >= 3) and (Result[1] = #$EF) and
     (Result[2] = #$BB) and (Result[3] = #$BF) then
    Delete(Result, 1, 3);
end;

{ A file is bytecode if it starts with the .pbc magic. }
function IsBytecode(const APath: String): Boolean;
var fs: TFileStream; buf: array[0..2] of Char;
begin
  Result := False;
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    if fs.Size >= 3 then
    begin
      fs.ReadBuffer(buf[0], 3);
      Result := (buf[0] = 'P') and (buf[1] = 'B') and (buf[2] = 'C');
    end;
  finally
    fs.Free;
  end;
end;

var
  eng: TPhosphorEngine;
  con: TGuiConsole;
  svc: THostServices;
  path: String;
  rc: Integer;
  fs: TFileStream;
begin
  if ParamCount < 1 then
  begin
    Writeln(StdErr, 'usage: phosphorgui <file.bas>');
    Halt(2);
  end;
  path := ParamStr(1);
  if not FileExists(path) then
  begin
    Writeln(StdErr, 'phosphorgui: file not found: ', path);
    Halt(2);
  end;

  Application.Initialize;

  con := TGuiConsole.Create();
  eng := TPhosphorEngine.Create();
  try
    eng.OnOutput := @con.Output;
    eng.OnInput := @con.ReadLine;
    svc.ProcessMessages := @con.Pump;
    svc.HandleMessage := @con.PumpOne;
    svc.ClipboardCopy := @con.ClipCopy;
    svc.ClipboardPaste := @con.ClipPaste;
    eng.HostServices := svc;
    RegisterGuiCoreFuncs(eng.Registry);
    RegisterControlFuncs(eng.Registry);
    RegisterFormFuncs(eng.Registry);
    RegisterButtonFuncs(eng.Registry);
    RegisterLabelFuncs(eng.Registry);
    RegisterEditFuncs(eng.Registry);
    RegisterChoiceFuncs(eng.Registry);
    RegisterContainerFuncs(eng.Registry);
    RegisterRangeFuncs(eng.Registry);
    RegisterMenuFuncs(eng.Registry);
    RegisterTimerFuncs(eng.Registry);
    RegisterImageFuncs(eng.Registry);
    RegisterGridFuncs(eng.Registry);
    RegisterTreeListFuncs(eng.Registry);
    RegisterCanvasFuncs(eng.Registry);
    RegisterDialogFuncs(eng.Registry);
    RegisterMiscFuncs(eng.Registry);
    // the same package set the console host registers
    RegisterCrtFuncs(eng.Registry);
    RegisterBase64Funcs(eng.Registry);
    RegisterZipFuncs(eng.Registry);
    RegisterGzipFuncs(eng.Registry);
    RegisterHttpFuncs(eng.Registry);
    RegisterSqliteFuncs(eng.Registry);
    // Accept a compiled .pbc as well as source: the complete runner should run
    // whatever `phosphor compile` produced, GUI programs included.
    if IsBytecode(path) then
    begin
      fs := TFileStream.Create(path, fmOpenRead or fmShareDenyNone);
      try rc := eng.RunBytecode(fs); finally fs.Free; end;
    end
    else
      rc := eng.Run(ReadSource(path));
    if rc <> 0 then
    begin
      Writeln(StdErr, Format('phosphorgui: %s:%d: %s', [path, eng.ErrorLine, eng.ErrorMessage]));
      Halt(1);
    end;
  finally
    eng.Free;
    con.Free;
  end;
end.
