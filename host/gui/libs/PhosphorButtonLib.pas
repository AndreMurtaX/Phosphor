{******************************************************************************
  Phosphor BASIC -- button library (a GUI package under host/gui/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

    button@(parent@)             a push button on a form (or container)
    button_caption@(b@, s$)      button_caption$(b@)
    button_onclick@(b@, name$)   bind the click to a BASIC routine by name;
                                 "" unwires it. The handler is
                                 function name(sender@) ... end function.
    button_click@(b@)            fire the click programmatically -- the headless
                                 way to prove an event reaches its handler with
                                 no window shown and no message loop.

  bitbtn@ and speedbutton@ live here too and repeat that shape name for name
  (bitbtn_caption@ / bitbtn_caption$ / bitbtn_click@ / bitbtn_onclick@, and the
  same four for speedbutton, plus speedbutton_down@ / speedbutton_down and
  speedbutton_groupindex@ for the groupable toggle).

  THE @ ON button_click@ IS PART OF THE NAME. This block advertised it as
  button_click for a while, from before the suffix rule settled that a built-in's
  return type is read off its own name: it answers the button handle, so it is
  spelled with @ -- and a reader who copied the unsuffixed spelling out of this
  comment got "unknown function", the one failure mode a header comment exists to
  prevent. Checked against RegisterButtonFuncs below, which is the only authority.

  button_onclick@ is the one host-aware function here: it is handed the executing
  VM and stores it in the event bridge, so the click can later run the handler
  through VM.CallUserFunc.
******************************************************************************}
unit PhosphorButtonLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Controls, StdCtrls, Buttons,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorGuiCore;

procedure RegisterButtonFuncs(Reg: TPhosphorRegistry);

implementation

function f_button(const Args: array of TValue; out Err: TPhosphorError): TValue;
var
  pc: TComponent;
  btn: TButton;
begin
  Err := NoError;
  if not GuiResolve(Args[0].Hnd, TWinControl, pc) then
  begin
    Result := ValHandle(0);   // bad parent: gui_error set, no control made
    Exit;
  end;
  btn := TButton.Create(pc);            // owned by the parent, freed with the tree
  btn.Parent := TWinControl(pc);
  Result := ValHandle(GuiRegister(btn, False));   // non-owning wrapper
end;

function f_button_caption_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent;
begin
  Err := NoError;
  if GuiResolve(Args[0].Hnd, TButton, c) then TButton(c).Caption := Args[1].Str;
  Result := Args[0];
end;

function f_button_caption_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent;
begin
  Err := NoError;
  if GuiResolve(Args[0].Hnd, TButton, c) then Result := ValStr(TButton(c).Caption)
  else Result := ValStr('');
end;

function f_button_click(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent;
begin
  Err := NoError;
  if GuiResolve(Args[0].Hnd, TButton, c) then TButton(c).Click;
  Result := Args[0];
end;

function f_button_onclick(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
var
  c: TComponent;
begin
  Err := NoError;
  Result := Args[0];
  if not GuiResolve(Args[0].Hnd, TButton, c) then Exit;
  TButton(c).OnClick := GuiNotifyHandler(AVM, c, 'onclick', Args[1].Str, Args[0].Hnd);
end;

// --- bitmap button ----------------------------------------------------------
function f_bitbtn(const Args: array of TValue; out Err: TPhosphorError): TValue;
var pc: TComponent; b: TBitBtn;
begin
  Err := NoError;
  if not GuiResolve(Args[0].Hnd, TWinControl, pc) then begin Result := ValHandle(0); Exit; end;
  b := TBitBtn.Create(pc); b.Parent := TWinControl(pc);
  Result := ValHandle(GuiRegister(b, False));
end;
function f_bb_caption_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TBitBtn, c) then TBitBtn(c).Caption := Args[1].Str; Result := Args[0]; end;
function f_bb_caption_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TBitBtn, c) then Result := ValStr(TBitBtn(c).Caption) else Result := ValStr(''); end;
function f_bb_click(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TBitBtn, c) then TBitBtn(c).Click; Result := Args[0]; end;
function f_bb_onclick(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; Result := Args[0]; if GuiResolve(Args[0].Hnd, TBitBtn, c) then TBitBtn(c).OnClick := GuiNotifyHandler(AVM, c, 'onclick', Args[1].Str, Args[0].Hnd); end;

// --- speed button (toolbar-style, groupable toggle) -------------------------
function f_speedbutton(const Args: array of TValue; out Err: TPhosphorError): TValue;
var pc: TComponent; s: TSpeedButton;
begin
  Err := NoError;
  if not GuiResolve(Args[0].Hnd, TWinControl, pc) then begin Result := ValHandle(0); Exit; end;
  s := TSpeedButton.Create(pc); s.Parent := TWinControl(pc);
  Result := ValHandle(GuiRegister(s, False));
end;
function f_sb_caption_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TSpeedButton, c) then TSpeedButton(c).Caption := Args[1].Str; Result := Args[0]; end;
function f_sb_caption_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TSpeedButton, c) then Result := ValStr(TSpeedButton(c).Caption) else Result := ValStr(''); end;
function f_sb_down_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TSpeedButton, c) then TSpeedButton(c).Down := ArgI32(Args[1]) <> 0; Result := Args[0]; end;
function f_sb_down_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TSpeedButton, c) then Result := ValInt(Ord(TSpeedButton(c).Down)) else Result := ValInt(0); end;
function f_sb_groupindex_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TSpeedButton, c) then TSpeedButton(c).GroupIndex := ArgI32(Args[1]); Result := Args[0]; end;
function f_sb_click(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; if GuiResolve(Args[0].Hnd, TSpeedButton, c) then TSpeedButton(c).Click; Result := Args[0]; end;
function f_sb_onclick(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TComponent; begin Err := NoError; Result := Args[0]; if GuiResolve(Args[0].Hnd, TSpeedButton, c) then TSpeedButton(c).OnClick := GuiNotifyHandler(AVM, c, 'onclick', Args[1].Str, Args[0].Hnd); end;

procedure RegisterButtonFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('button@:@', @f_button);
  Reg.Add('button_caption@:@$', @f_button_caption_set);
  Reg.Add('button_caption$:@',  @f_button_caption_get);
  Reg.Add('button_click@:@',     @f_button_click);
  Reg.AddHost('button_onclick@:@$', @f_button_onclick);

  Reg.Add('bitbtn@:@', @f_bitbtn);
  Reg.Add('bitbtn_caption@:@$', @f_bb_caption_set); Reg.Add('bitbtn_caption$:@', @f_bb_caption_get);
  Reg.Add('bitbtn_click@:@', @f_bb_click);
  Reg.AddHost('bitbtn_onclick@:@$', @f_bb_onclick);

  Reg.Add('speedbutton@:@', @f_speedbutton);
  Reg.Add('speedbutton_caption@:@$', @f_sb_caption_set); Reg.Add('speedbutton_caption$:@', @f_sb_caption_get);
  Reg.Add('speedbutton_down@:@n', @f_sb_down_set); Reg.Add('speedbutton_down:@', @f_sb_down_get);
  Reg.Add('speedbutton_groupindex@:@n', @f_sb_groupindex_set);
  Reg.Add('speedbutton_click@:@', @f_sb_click);
  Reg.AddHost('speedbutton_onclick@:@$', @f_sb_onclick);
end;

end.
