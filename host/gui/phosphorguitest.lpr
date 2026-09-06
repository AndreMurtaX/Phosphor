{******************************************************************************
  phosphorguitest -- the headless GUI suite runner (a GUI-linked host)

  MIT License. Copyright (c) 2026 Andre Murta.

  The counterpart of phosphortest for the GUI packages. It links the LCL (which
  the engine may not) and registers the GUI libraries alongside the test library,
  then runs one GUI .bas file and reports the assertion tally byte-exact, exactly
  as phosphortest does. It NEVER shows a window or enters the message loop: GUI
  tests construct controls, round-trip properties, and fire events with
  button_click, all headless. Application.Initialize brings up the widgetset (on
  Windows win32, no display; on Linux gtk2, against the session's live display,
  set by the test script) so controls can be built.

  Exit code: 0 all passed, 1 assertions failed, 2 did not compile/run.
******************************************************************************}
program phosphorguitest;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  Interfaces,   // the LCL widgetset (win32 / gtk2), selected at build time
  Forms, Clipbrd, LCLType, ExtCtrls,
  SysUtils, Classes,
  PhosphorEngine, PhosphorValue, PhosphorTestLib,
  PhosphorGuiCore, PhosphorControlLib, PhosphorFormLib, PhosphorButtonLib,
  PhosphorLabelLib, PhosphorEditLib, PhosphorChoiceLib,
  PhosphorContainerLib, PhosphorRangeLib, PhosphorMenuLib, PhosphorTimerLib,
  PhosphorImageLib, PhosphorGridLib, PhosphorTreeListLib, PhosphorCanvasLib,
  PhosphorDialogLib, PhosphorMiscLib;

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

{ The host services, as a TEST RUNNER can honestly provide them.

  processmessages() and the clipboard are the real thing -- the widgetset is up,
  so a .bas test can drive them and see a host answer rather than the
  absent-service answer that tests/suite/17_host_services pins headlessly.

  handlemessage() is deliberately NOT the real thing here, and this is the
  interesting one. Application.HandleMessage WAITS for a message; in an unattended
  runner with no window and nobody clicking, that wait never ends and the suite
  hangs. So this runner reports that it CANNOT handle one -- which is precisely
  what the seam's 0 means, and is true: it cannot, not without hanging. The
  interactive host (phosphorgui) installs the real, blocking one. A test asserting
  the difference is tests/gui/16_host_services. }
type
  TGuiTestServices = class
    function Pump: Integer;
    function PumpOne: Integer;
    function ClipCopy(const AText: String): Boolean;
    function ClipPaste(out AText: String): Boolean;
  end;

function TGuiTestServices.Pump: Integer;
begin
  Application.ProcessMessages;
  Result := 1;
end;

function TGuiTestServices.PumpOne: Integer;
begin
  Result := 0;   // see the note above: waiting here would be a hang, not a test
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

function TGuiTestServices.ClipCopy(const AText: String): Boolean;
begin
  Result := ClipRetryCopy(AText);
end;

function TGuiTestServices.ClipPaste(out AText: String): Boolean;
begin
  Result := ClipRetryPaste(AText);
end;

{ THE WATCHDOG. A test file may now enter the real message loop (app_run), and a
  loop that is never asked to end does not fail -- it HANGS, which tells nobody
  anything and blocks every suite queued behind it. This timer can only fire while
  a message loop is pumping, which is exactly the stuck case; it reports the file
  as failed and ends the process rather than waiting for a human to notice. }
type
  TWatchdog = class
    procedure Bark(Sender: TObject);
  end;

procedure TWatchdog.Bark(Sender: TObject);
begin
  Writeln(StdErr, 'phosphorguitest: the message loop did not end within 30s -- ' +
                  'app_run() was entered and nothing called app_quit()');
  Inc(AssertsFailed);
  Application.Terminate;
end;

procedure WriteSummary;
var
  s: String;
begin
  s := 'passed: ' + IntToStr(AssertsPassed) + #10 +
       'failed: ' + IntToStr(AssertsFailed) + #10;
  FileWrite(StdOutputHandle, s[1], Length(s));
end;

var
  eng: TPhosphorEngine;
  GuiSvc: TGuiTestServices;
  Dog: TWatchdog;
  DogTimer: TTimer;
  gsvc: THostServices;
  path: String;
  rc, i: Integer;
{ Turns an escaped exception into a reported failure. A class method rather than a
  free procedure because Application.OnException wants a method pointer. }
type
  TGuiTestCrash = class
    class procedure Report(Sender: TObject; E: Exception);
  end;

class procedure TGuiTestCrash.Report(Sender: TObject; E: Exception);
begin
  Writeln(StdErr, 'phosphorguitest: unhandled ', E.ClassName, ': ', E.Message);
  Flush(StdErr);
  Halt(3);   // never a dialog, never a wait
end;

begin
  if ParamCount < 1 then
  begin
    Writeln(StdErr, 'usage: phosphorguitest <file.bas>');
    Halt(2);
  end;
  path := ParamStr(1);
  if not FileExists(path) then
  begin
    Writeln(StdErr, 'phosphorguitest: file not found: ', path);
    Halt(2);
  end;

  // An exception that escapes into the LCL raises its default handler, which is a
  // MODAL DIALOG -- and a headless suite then waits on it forever. A hang gives no
  // message, no exit code and no file name; a failure gives all three. This is the
  // difference between a suite that reports a bad afternoon and one that eats it.
  Application.OnException := @TGuiTestCrash.Report;
  Application.Initialize;   // bring up the widgetset before any form is built

  eng := TPhosphorEngine.Create();
  // A TEST RUNNER IS ALWAYS SANDBOXED, with no flag to turn it off. The suite
  // exists to run code that is being changed, which is exactly the code most
  // likely to name a path it did not mean to; on 2026-09-05 an unbounded run of a
  // defective dir_delete erased thirteen projects outside this checkout. The
  // working directory is the root -- every test writes under bin/ , which is
  // inside it -- so nothing a test names can resolve outside the checkout.
  eng.SandboxRoot := GetCurrentDir;

  // THE HOST SERVICES, so a .bas test can assert them. This runner is the only
  // program in the tree that both has a widgetset and runs test files, which makes
  // it the only place processmessages()/handlemessage() and the clipboard can be
  // checked against a real host rather than against their absent-service answers
  // (tests/suite/17_host_services pins those, headless, under phosphortest).
  Dog := TWatchdog.Create();
  DogTimer := TTimer.Create(nil);
  DogTimer.Interval := 30000;
  DogTimer.OnTimer := @Dog.Bark;
  DogTimer.Enabled := True;

  GuiSvc := TGuiTestServices.Create();
  gsvc.ProcessMessages := @GuiSvc.Pump;
  gsvc.HandleMessage := @GuiSvc.PumpOne;
  gsvc.ClipboardCopy := @GuiSvc.ClipCopy;
  gsvc.ClipboardPaste := @GuiSvc.ClipPaste;
  eng.HostServices := gsvc;

  try
    RegisterTestFuncs(eng.Registry);
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
    ResetTestState();
    rc := eng.Run(ReadSource(path));
    if rc <> 0 then
    begin
      Writeln(StdErr, Format('phosphorguitest: %s:%d: %s', [path, eng.ErrorLine, eng.ErrorMessage]));
      WriteSummary();
      Halt(2);
    end;
    for i := 0 to Failures.Count - 1 do
      Writeln(StdErr, '  FAIL ', Failures[i]);
    WriteSummary();
    if AssertsFailed = 0 then Halt(0) else Halt(1);
  finally
    eng.Free;
  end;
end.
