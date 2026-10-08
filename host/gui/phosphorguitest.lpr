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

  Exit code: 0 all passed, 1 assertions failed, 2 did not compile/run, 4 the
  message loop hung and the watchdog ended the run (see TWatchdog).

  It does enter the message loop when a test file calls app_run(), which is why
  the watchdog exists. `phosphorguitest <file.bas> --watchdog-ms N` shortens it,
  so scripts/test-gui.* can make a hang happen on purpose without waiting 30 s.
******************************************************************************}
program phosphorguitest;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  {$ifdef unix} BaseUnix, {$endif}   // fpExit, for the watchdog's immediate exit
  Interfaces,   // the LCL widgetset (win32 / gtk2), selected at build time
  Forms, Clipbrd, LCLType, ExtCtrls, StdCtrls, ComCtrls,
  SysUtils, Classes,
  PhosphorEngine, PhosphorValue, PhosphorErrors, PhosphorTestLib,
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
        if not Clipboard.HasFormat(CF_Text()) then Exit(True);
      end
      else
      begin
        Clipboard.AsText := AText;
        if Clipboard.HasFormat(CF_Text()) and (Clipboard.AsText = AText) then Exit(True);
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
      if Clipboard.HasFormat(CF_Text()) then
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

procedure WriteSummary;
var
  s: String;
begin
  s := 'passed: ' + IntToStr(AssertsPassed) + #10 +
       'failed: ' + IntToStr(AssertsFailed) + #10;
  FileWrite(StdOutputHandle, s[1], Length(s));
end;

{$ifdef windows}
procedure ExitProcess(uExitCode: Cardinal); stdcall; external 'kernel32.dll';
{$endif}

{ The process ends HERE, without running finalization. Used only by the watchdog,
  whose caller is a timer dispatch inside a stuck message loop: Halt would unwind
  through the LCL's finalization with that loop, the widgetset and live forms on
  the stack, and on gtk2 nobody has measured whether that returns. A hang is
  already fatal to the file, so there is nothing left to tidy -- the report has
  been written by the time this is called. }
procedure EndNow(ACode: Integer);
begin
  {$ifdef windows}
  ExitProcess(ACode);
  {$else}
  fpExit(ACode);
  {$endif}
end;

var
  WatchdogMs: Integer = 30000;

{ THE WATCHDOG. A test file may enter the real message loop (app_run), and a loop
  that is never asked to end does not fail -- it HANGS, which tells nobody anything
  and blocks every suite queued behind it. This timer can only fire while a message
  loop is pumping, which is exactly the stuck case.

  IT ENDS THE RUN, AND IT USED NOT TO (ledger d56). It called
  Application.Terminate, which sets a flag the LCL never clears: app_run()
  returned, the file carried on, and every later app_run() in it returned at once
  without dispatching anything -- so one hang was reported as a screenful of
  failures about timers and events that never got a loop to run in, and the case
  that actually hung was one line among them. Measured on
  tests/gui/watchdog/hang.bas before the change: `passed: 2`, the case after the
  hang counted as a pass. Now the hang is the LAST thing the file reports: the
  failures so far, the summary, and exit 4, at once. }
type
  TWatchdog = class
    procedure Bark(Sender: TObject);
  end;

procedure TWatchdog.Bark(Sender: TObject);
var
  i: Integer;
begin
  Writeln(StdErr, Format('phosphorguitest: the message loop did not end within %d ms -- ' +
                         'app_run() was entered and nothing called app_quit(); the run ' +
                         'ends here', [WatchdogMs]));
  Inc(AssertsFailed);
  if Assigned(Failures) then
    for i := 0 to Failures.Count - 1 do
      Writeln(StdErr, '  FAIL ', Failures[i]);
  Flush(StdErr);
  WriteSummary();
  EndNow(4);
end;

var
  eng: TPhosphorEngine;
  GuiSvc: TGuiTestServices;
  Dog: TWatchdog;
  DogTimer: TTimer;
  gsvc: THostServices;
  path: String;
  rc, i: Integer;
{ gui_test_fire(c@, event$) -- TEST ONLY, and only in this runner: run the event a
  person's action would, so a handler bound to it can be seen to run.

  MEASURED on win32 and gtk2 alike (2026-10-08): a change made from code fires
  the handler of a radio button, a radio group, a toggle box, a spin edit and a
  track bar, but NOT of a combo box (itemindex), a list box (itemindex, onclick),
  a tab control (tabindex) or a memo (text, addline) -- and a paint box is never
  painted without a window on screen. Those bindings could be called and never
  seen to work. This calls the LCL's OWN method each user action ends in, read in
  the LCL source rather than assumed: TCustomComboBox.Change and TCustomEdit.Change
  (a memo is one) call OnChange; TTabControl.Change calls it too; TCustomListBox.
  Click is TControl.Click; TPaintBox.Paint calls OnPaint. A tray icon's click has
  no such method -- the LCL raises it from the widgetset -- so its handler is
  called directly, which proves only which event the binding wired.

  It is not part of the language: it lives in this test host, which no shipped
  binary links (CLAUDE.md: test-only stand-ins stay out of the libraries).
  Answers 1 when it ran an event and 0 for a pairing it does not know. }
type
  TFireCombo = class(TCustomComboBox);
  TFireEdit = class(TCustomEdit);
  TFireList = class(TCustomListBox);
  TFireTab = class(TTabControl);
  TFirePaint = class(TPaintBox);

function f_gui_test_fire(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent;
    ev: String;
begin
  Err := NoError();
  Result := ValInt(0);
  if not GuiResolve(Args[0].Hnd, TComponent, c) then Exit;
  ev := LowerCase(Args[1].Str);
  if (ev = 'change') and (c is TCustomComboBox) then TFireCombo(c).Change
  else if (ev = 'change') and (c is TCustomEdit) then TFireEdit(c).Change
  else if (ev = 'change') and (c is TTabControl) then TFireTab(c).Change
  else if (ev = 'click') and (c is TCustomListBox) then TFireList(c).Click
  else if (ev = 'paint') and (c is TPaintBox) then TFirePaint(c).Paint
  else if (ev = 'click') and (c is TTrayIcon) then
  begin
    if Assigned(TTrayIcon(c).OnClick) then TTrayIcon(c).OnClick(c);
  end
  else Exit;
  Result := ValInt(1);
end;

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

{ The watchdog and the host-services object live as long as the run and are
  released at the two exits that can reach them -- the three earlier Halts happen
  before either exists. ORDER MATTERS: DogTimer holds a method pointer into Dog,
  so the timer is destroyed first; freeing Dog first would leave an armed timer
  pointing at dead memory for as long as it takes to reach Halt.

  This exists because of the notes, and the notes were right. `Dog` and `GuiSvc`
  were assigned and then only ever read through `@Dog.Bark` / `@GuiSvc.Pump`,
  which FPC's dataflow does not count as a use -- so it said "assigned but never
  used", and what that was really pointing at is that nothing ever released them.
  Both notes had been live in the tree for as long as this file has existed and
  were invisible until 2026-09-15, when this runner started reading its own build
  log instead of checking whether the binary appeared. }
procedure ReleaseGuiFixtures;
begin
  FreeAndNil(DogTimer);
  FreeAndNil(Dog);
  FreeAndNil(GuiSvc);
end;

begin
  // One file, optionally followed by --watchdog-ms N. Anything else is refused
  // rather than ignored: an argument that is silently dropped reads exactly like
  // one that was obeyed.
  if (ParamCount <> 1) and not ((ParamCount = 3) and (ParamStr(2) = '--watchdog-ms') and
                                (StrToIntDef(ParamStr(3), 0) > 0)) then
  begin
    Writeln(StdErr, 'usage: phosphorguitest <file.bas> [--watchdog-ms N]');
    Halt(2);
  end;
  if ParamCount = 3 then WatchdogMs := StrToInt(ParamStr(3));
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
  DogTimer.Interval := WatchdogMs;
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
    eng.Registry.Add('gui_test_fire:@$', @f_gui_test_fire);   // test only; see above
    ResetTestState();
    rc := eng.Run(ReadSource(path));
    if rc <> 0 then
    begin
      Writeln(StdErr, Format('phosphorguitest: %s:%d: %s', [path, eng.ErrorLine, eng.ErrorMessage]));
      WriteSummary();
      ReleaseGuiFixtures();
      Halt(2);
    end;
    for i := 0 to Failures.Count - 1 do
      Writeln(StdErr, '  FAIL ', Failures[i]);
    WriteSummary();
    ReleaseGuiFixtures();
    if AssertsFailed = 0 then Halt(0) else Halt(1);
  finally
    eng.Free;
  end;
end.
