{******************************************************************************
  Phosphor BASIC -- display guard for the GUI host

  MIT License. Copyright (c) 2026 Andre Murta.

  On Linux the LCL gtk2 widgetset opens the X display in the `Interfaces` unit's
  INITIALIZATION section -- before the program's main body runs. With no display
  reachable the process dies there, printing gtk's own bare
  "Gtk-WARNING **: cannot open display:", which says nothing about Phosphor and
  nothing about what to do instead.

  This unit exists to speak first. Pascal initializes units in the order of the
  program's uses clause, so listing it BEFORE `Interfaces` in phosphorgui.lpr gets
  its initialization section in ahead of the widgetset's: it checks for a session
  and, finding none, explains the problem and halts cleanly -- gtk is never reached.

  Windows needs no display for the win32 widgetset, so there the guard does nothing.
******************************************************************************}
unit PhosphorDisplayGuard;

{$mode objfpc}{$H+}{$J-}

interface

const
  { Exit code for "a GUI program was asked for, but there is no display". Distinct
    from 1 (program error) and 2 (usage), so a script can tell the cases apart. }
  EXIT_NO_DISPLAY = 3;

{ True when a graphical session looks reachable. Always True on Windows. }
function DisplayAvailable: Boolean;

implementation

uses
  SysUtils;

function DisplayAvailable: Boolean;
begin
  {$IFDEF UNIX}
  // X11 sets DISPLAY; Wayland sets WAYLAND_DISPLAY. A session under either is enough
  // for the widgetset to start. (A DISPLAY that is set but broken still fails later,
  // in gtk -- this guard catches the common case, an ssh session or a service with
  // no session at all, which is where the bare gtk message is most confusing.)
  Result := (GetEnvironmentVariable('DISPLAY') <> '') or
            (GetEnvironmentVariable('WAYLAND_DISPLAY') <> '');
  {$ELSE}
  Result := True;
  {$ENDIF}
end;

{$IFDEF UNIX}
initialization
  if not DisplayAvailable() then
  begin
    Writeln(StdErr, 'phosphorgui: no graphical session is available.');
    Writeln(StdErr, '  A GUI program needs a display, and neither DISPLAY nor');
    Writeln(StdErr, '  WAYLAND_DISPLAY is set in this environment (a plain ssh');
    Writeln(StdErr, '  session, a service, or a container usually has none).');
    Writeln(StdErr, '');
    Writeln(StdErr, '  Run it from a desktop session, or point it at one:');
    Writeln(StdErr, '      DISPLAY=:0 phosphor --gui <file>');
    Writeln(StdErr, '  For a console program, no display is needed:');
    Writeln(StdErr, '      phosphor run <file>');
    Flush(StdErr);
    Halt(EXIT_NO_DISPLAY);
  end;
{$ENDIF}

end.
