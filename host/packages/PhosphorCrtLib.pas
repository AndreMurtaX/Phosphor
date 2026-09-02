{******************************************************************************
  Phosphor BASIC -- CRT / console control (an OPT-IN host package)

  MIT License. Copyright (c) 2026 Andre Murta.

  Classic-BASIC screen control for a terminal: clear, cursor positioning, colour,
  text attributes, and key input. An opt-in package (host/packages/, RegisterCrtFuncs)
  -- terminal control is host-specific, so it stays OUT of the host-agnostic engine.

  OUTPUT is done the host-agnostic way: the screen-control functions RETURN the ANSI
  escape sequence, and the program emits it with `print` (which, unlike `println`,
  adds no newline). So a control string composes with ordinary output:

      print cls$();
      print at$(3, 10); color$(11); "Hello"; reset$();
      println

  That keeps the engine's single output seam (OnOutput) the only way anything reaches
  the terminal, and makes every sequence byte-exact testable by its return value.
  ANSI is understood by Unix terminals and by the Windows console once VT processing
  is on -- call crt_init() once at startup to enable it (a no-op elsewhere).

    Screen : cls$()  clreol$()  clreos$()
    Cursor : home$()  at$(row,col)  moveup$(n) movedown$(n) moveleft$(n) moveright$(n)
             hidecursor$()  showcursor$()  savepos$()  restorepos$()
    Attrs  : reset$()  bold$()  faint$()  italic$()  underline$()  blink$()  inverse$()
    Colour : color$(fg)  color$(fg,bg)  bg$(bg)     -- 0..7 normal, 8..15 bright
             (0 black 1 red 2 green 3 yellow 4 blue 5 magenta 6 cyan 7 white)
    Setup  : crt_init()                             -- enable ANSI on Windows

  Keyboard input (inkey$/getkey$) is deliberately NOT here yet: FPC's crt unit spins
  forever on a non-interactive stdin (it broke the headless test), and doing it right
  means raw-mode terminal handling with save/restore on exit -- its own careful step.
  This package is the screen-control half, which is host-agnostic and byte-exact.
******************************************************************************}
unit PhosphorCrtLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, {$IFDEF WINDOWS}Windows,{$ENDIF}
  PhosphorValue, PhosphorErrors, PhosphorRegistry;

procedure RegisterCrtFuncs(Reg: TPhosphorRegistry);

implementation

const
  ESC = #27;

function Csi(const ABody: String): String;
begin
  Result := ESC + '[' + ABody;
end;

function NArg(const V: TValue): Integer;
begin
  Result := Round(AsDouble(V));
end;

{ ANSI SGR code for a colour index: 0..7 -> normal, 8..15 -> bright; anything else is
  the terminal default. }
function FgCode(AColor: Integer): Integer;
begin
  if (AColor >= 0) and (AColor <= 7) then Result := 30 + AColor
  else if (AColor >= 8) and (AColor <= 15) then Result := 90 + (AColor - 8)
  else Result := 39;
end;

function BgCode(AColor: Integer): Integer;
begin
  if (AColor >= 0) and (AColor <= 7) then Result := 40 + AColor
  else if (AColor >= 8) and (AColor <= 15) then Result := 100 + (AColor - 8)
  else Result := 49;
end;

{ ---- screen ---------------------------------------------------------------- }

function f_cls(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  Result := ValStr(Csi('2J') + Csi('H'));   // clear all, cursor home
end;

function f_clreol(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError; Result := ValStr(Csi('K'));
end;

function f_clreos(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError; Result := ValStr(Csi('J'));
end;

{ ---- cursor ---------------------------------------------------------------- }

function f_home(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError; Result := ValStr(Csi('H'));
end;

function f_at(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;   // row;col are 1-based, like ANSI and like Phosphor's own indices
  Result := ValStr(Csi(IntToStr(NArg(Args[0])) + ';' + IntToStr(NArg(Args[1])) + 'H'));
end;

function f_moveup(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError; Result := ValStr(Csi(IntToStr(NArg(Args[0])) + 'A'));
end;

function f_movedown(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError; Result := ValStr(Csi(IntToStr(NArg(Args[0])) + 'B'));
end;

function f_moveright(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError; Result := ValStr(Csi(IntToStr(NArg(Args[0])) + 'C'));
end;

function f_moveleft(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError; Result := ValStr(Csi(IntToStr(NArg(Args[0])) + 'D'));
end;

function f_hidecursor(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError; Result := ValStr(Csi('?25l'));
end;

function f_showcursor(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError; Result := ValStr(Csi('?25h'));
end;

function f_savepos(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError; Result := ValStr(ESC + '7');
end;

function f_restorepos(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError; Result := ValStr(ESC + '8');
end;

{ ---- attributes ------------------------------------------------------------ }

function f_reset(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError; Result := ValStr(Csi('0m'));
end;

function f_bold(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError; Result := ValStr(Csi('1m'));
end;

function f_faint(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError; Result := ValStr(Csi('2m'));
end;

function f_italic(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError; Result := ValStr(Csi('3m'));
end;

function f_underline(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError; Result := ValStr(Csi('4m'));
end;

function f_blink(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError; Result := ValStr(Csi('5m'));
end;

function f_inverse(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError; Result := ValStr(Csi('7m'));
end;

{ ---- colour ---------------------------------------------------------------- }

function f_color1(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError; Result := ValStr(Csi(IntToStr(FgCode(NArg(Args[0]))) + 'm'));
end;

function f_color2(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  Result := ValStr(Csi(IntToStr(FgCode(NArg(Args[0]))) + ';' +
                       IntToStr(BgCode(NArg(Args[1]))) + 'm'));
end;

function f_bg(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError; Result := ValStr(Csi(IntToStr(BgCode(NArg(Args[0]))) + 'm'));
end;

{ ---- setup ----------------------------------------------------------------- }

{ Enable ANSI/VT escape processing so the sequences render. On Windows 10+ the console
  needs ENABLE_VIRTUAL_TERMINAL_PROCESSING turned on; elsewhere ANSI already works.
  Returns 1 if VT output is available, 0 if it could not be enabled. }
function f_crt_init(const Args: array of TValue; out Err: TPhosphorError): TValue;
{$IFDEF WINDOWS}
const
  ENABLE_VT = $0004;   // ENABLE_VIRTUAL_TERMINAL_PROCESSING
var
  h: THandle;
  mode: DWORD;
begin
  Err := NoError;
  Result := ValInt(0);
  h := GetStdHandle(STD_OUTPUT_HANDLE);
  if (h <> INVALID_HANDLE_VALUE) and GetConsoleMode(h, mode) then
    if SetConsoleMode(h, mode or ENABLE_VT) then
      Result := ValInt(1);
end;
{$ELSE}
begin
  Err := NoError; Result := ValInt(1);   // ANSI already understood
end;
{$ENDIF}

procedure RegisterCrtFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('cls$:',          @f_cls);
  Reg.Add('clreol$:',       @f_clreol);
  Reg.Add('clreos$:',       @f_clreos);
  Reg.Add('home$:',         @f_home);
  Reg.Add('at$:nn',         @f_at);
  Reg.Add('moveup$:n',      @f_moveup);
  Reg.Add('movedown$:n',    @f_movedown);
  Reg.Add('moveright$:n',   @f_moveright);
  Reg.Add('moveleft$:n',    @f_moveleft);
  Reg.Add('hidecursor$:',   @f_hidecursor);
  Reg.Add('showcursor$:',   @f_showcursor);
  Reg.Add('savepos$:',      @f_savepos);
  Reg.Add('restorepos$:',   @f_restorepos);
  Reg.Add('reset$:',        @f_reset);
  Reg.Add('bold$:',         @f_bold);
  Reg.Add('faint$:',        @f_faint);
  Reg.Add('italic$:',       @f_italic);
  Reg.Add('underline$:',    @f_underline);
  Reg.Add('blink$:',        @f_blink);
  Reg.Add('inverse$:',      @f_inverse);
  Reg.Add('color$:n',       @f_color1);
  Reg.Add('color$:nn',      @f_color2);
  Reg.Add('bg$:n',          @f_bg);
  Reg.Add('crt_init:',      @f_crt_init);
end;

end.
