{******************************************************************************
  phosphorgui -- the interactive GUI host (the engine's second real consumer)

  MIT License. Copyright (c) 2026 Andre Murta.

  Runs a .bas program that builds a window and enters the message loop
  (app_run). The engine is unchanged and unaware: it sees the same registry and
  the same OnOutput seam as the console host; the GUI libraries, registered here,
  are what turn form@/button@/button_onclick@ into real LCL controls and events.

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
  Forms,
  SysUtils, Classes,
  PhosphorEngine,
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
  { The host side of the output seam: PRINT/PRINTLN text goes to stdout as raw
    bytes, the same contract the console host honours. }
  TGuiConsole = class
    procedure Output(const AText: String);
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
