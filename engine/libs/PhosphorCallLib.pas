{******************************************************************************
  Phosphor BASIC -- indirect call library (a function package under engine/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

  callfunc calls a BASIC user function chosen at run time by name, and returns
  its result. It is the language-visible face of the engine's host-callback seam
  (TPhosphorVM.CallUserFunc): the SAME re-entrant path a GUI event dispatcher
  uses to run a handler. Proving it here, headless and with no GUI at all, freezes
  the seam before phase 2's LCL host is built on top of it.

    callfunc(name$)          call name$ with no arguments
    callfunc(name$, x)       call name$ with one argument (any kind)

  The suffix on the call (none / % / $ / @ / ?) is chosen to read as the callee's
  return type -- one spelling for each of the five value kinds, so a caller writes
  `n% = callfunc%(...)` or `ok? = callfunc?(...)` and it reads right. Every spelling
  runs the same primitive, and the value that comes back is whatever the routine
  returned (its kind is checked where it is finally stored, like any other value).
  The routine runs over the caller's globals and handles,
  so it can read and change shared state -- an event handler bumping a counter is
  the canonical use.

  This package registers host-aware functions (AddHost): the VM hands each call
  the executing engine so it can re-enter BASIC. It is still host-agnostic -- the
  boundary check passes -- because "run a BASIC routine" needs no console, file or
  window, only the VM already on the stack.
******************************************************************************}
unit PhosphorCallLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorVM;

procedure RegisterCallFuncs(Reg: TPhosphorRegistry);

implementation

{ One implementation for every arity. Args[0] is the NAME; everything after it is
  handed on untouched, in order. CallByName looks in the program's routines first
  and the library second -- the order a direct call uses. }
function f_calln(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
var
  rest: array of TValue;
  i: Integer;
begin
  SetLength(rest, Length(Args) - 1);
  for i := 1 to High(Args) do rest[i - 1] := Args[i];
  Result := TPhosphorVM(AVM).CallByName(Args[0].Str, rest, Err);
end;

{ funcexists?(name$) -- can this name be called at all? Asked of the same two
  places CallByName looks, and about the NAME only. }
function f_funcexists(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValBool(TPhosphorVM(AVM).KnowsName(Args[0].Str));
end;

procedure RegisterCallFuncs(Reg: TPhosphorRegistry);
const
  { One return-suffix spelling per value kind (none / % / $ / @ / ?); all share one
    impl -- the suffix only tells the caller's reader (and the compiler) the kind. }
  Names: array[0..4] of String = ('callfunc', 'callfunc%', 'callfunc$', 'callfunc@', 'callfunc?');
  { How many arguments may follow the name. A per-KIND signature for each arity
    would be 5^n keys, and the registry is a linear scan -- so the arguments are
    registered as '*' (any kind), one key per arity instead of 5^n. Eight is
    generous: the widest thing in the whole library takes six. }
  MaxIndirectArgs = 8;
var
  s, a: Integer;
  wild: String;
begin
  for s := 0 to High(Names) do
  begin
    Reg.AddHost(Names[s] + ':$', @f_calln);
    wild := '';
    for a := 1 to MaxIndirectArgs do
    begin
      wild := wild + '*';
      Reg.AddHost(Names[s] + ':$' + wild, @f_calln);
    end;
  end;
  { A dispatch table whose names come from data cannot be checked when the
    program is packed -- a name in a dictionary is not an instruction. It can be
    checked by the PROGRAM, once, where the table is built. }
  Reg.AddHost('funcexists?:$', @f_funcexists);
end;

end.
