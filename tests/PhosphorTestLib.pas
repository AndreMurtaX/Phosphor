{******************************************************************************
  PhosphorTestLib -- assertion package for the headless test runner

  MIT License. Copyright (c) 2026 Andre Murta.

  Ported from Plan9Basic's tests/TestLib.pas: same idea (assert_* functions that
  always evaluate, count passes and failures, and let execution continue so one
  run reports every problem), adapted to Phosphor -- the ':' registry separator
  and the five-kind TValue. Added for Phosphor's founding-divergence probe:

    assert_true(?) / assert_false(?)   accept a bool VALUE (distinct '?' slot),
                                       proving comparison flows as a bool.
    assert_int(%%)                     both args are int% (dispatch to the '%'
                                       slot IS the proof the value stayed int).
    assert_add_overflows(%%)           the checked add of two int64s overflows,
                                       proving overflow is a catchable result and
                                       not a silent promotion.

  Also the HANDLE-REGISTRY probes (probe_new_a@/probe_new_b@/probe_is_handle/
  probe_is_a/probe_is_b/probe_free/probe_count). They live HERE, on the runner
  side, because they are throwaway stand-ins for the real GUI objects (which need
  a form + a message loop and cannot run headless). Each is backed by a trivial
  TProbeA/TProbeB registered in the engine's handle registry, so a library can
  validate/discriminate/revoke a BASIC handle WITHOUT dereferencing a fabricated
  address -- reusing IsHandle/HandleObj/FreeHandle, the same path that already
  rejects fabricated array/dict/stringlist handles. The live count is tracked
  runner-side (the registry keeps no live total), incremented on register and
  decremented only when a live probe is actually freed.

  This is host/test tooling, not engine code.
******************************************************************************}
unit PhosphorTestLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Math, PhosphorValue, PhosphorErrors, PhosphorRegistry,
  PhosphorHandles;

var
  AssertsPassed: Integer = 0;
  AssertsFailed: Integer = 0;
  Failures: TStringList = nil;
  CurrentCase: String = '';

procedure RegisterTestFuncs(Reg: TPhosphorRegistry);
procedure ResetTestState;

implementation

uses
  PhosphorBudget,   // BudgetActive, for test_budget_active
  PhosphorVM;       // ErrTrapLive, for the trap guard on every assert_*

type
  { Two distinct throwaway classes registered in the handle registry, so a probe
    handle can be discriminated by class (is-this-handle-a-TProbeA) exactly the
    way a real GUI library discriminates a button from a label. They carry no
    state -- their identity is the whole point. }
  TProbeA = class end;
  TProbeB = class end;

var
  ProbeLiveCount: Integer = 0;  // live probe instances the runner has registered

{ THE SAME FORMATTER THE ENGINE USES, because a failure message that rounds is
  useless for exactly the defect it is most likely to be reporting: with
  FloatToStr's 15 digits, "expected 1.00000044600002, got 1.00000044600002" was a
  real possible output of assert_eq on two Doubles 2.2e-15 apart. }
function NumStr(const V: Double): String;
begin
  Result := NumToInv(V);
end;

{ WHAT assert_eq FORGIVES, AND WHAT IT MUST NOT (ledger d57).

  It used to forgive 1e-12 of the larger magnitude, with 1.0 as the floor -- a
  RELATIVE tolerance, so the slack grew with the number. At 9.007e15, where this
  tree asserts 64-bit buffer reads and PtrInt properties, that is +/-9007: a
  mutation of nine thousand passed, and every big-integer assertion in the suite
  was a range check wearing an equals sign.

  Two cases now, because they are two different questions:
    * BOTH VALUES INTEGRAL -- equality between integers has no rounding to
      forgive, so it is exact. This is what the big-integer assertions mean.
    * OTHERWISE -- a computed fraction may differ from the literal written
      beside it by its last bits; four units in the last place of the larger
      magnitude (4 * 2^-52, relative) forgive that and nothing a person would
      notice. Near zero the old absolute floor of 1e-12 stays, so sin(pi)
      still equals 0.
  A computed value one ULP off an integral literal is not integral itself, so it
  takes the second branch and is still forgiven. }
function NumEquals(const A, B: Double): Boolean;
var
  Eps, M: Double;
begin
  if A = B then Exit(True);
  if IsNan(A) or IsNan(B) or IsInfinite(A) or IsInfinite(B) then Exit(False);
  if (Frac(A) = 0) and (Frac(B) = 0) then Exit(False);
  M := Max(Abs(A), Abs(B));
  Eps := 4 * 2.220446049250313E-16 * M;
  if M < 1.0 then Eps := Max(Eps, 1E-12);
  Result := Abs(A - B) <= Eps;
end;

procedure RecordPass;
begin
  Inc(AssertsPassed);
end;

procedure RecordFail(const Msg: String);
var
  Where: String;
begin
  Inc(AssertsFailed);
  if CurrentCase <> '' then Where := CurrentCase + ': ' else Where := '';
  if Assigned(Failures) then
    Failures.Add(Where + Msg);
end;

procedure Check(Ok: Boolean; const Msg, Generated: String);
begin
  if Ok then RecordPass()
  else if Msg <> '' then RecordFail(Msg + ' -- ' + Generated)
  else RecordFail(Generated);
end;

// --- bound functions --------------------------------------------------------
function t_test_case(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  CurrentCase := Args[0].Str;
  Result := ValInt(1);
end;

function t_assert_true(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean;
begin
  Err := NoError();
  ok := AsDouble(Args[0]) <> 0;
  Check(ok, '', 'expected true, got false');
  Result := ValInt(Ord(ok));
end;

function t_assert_true_msg(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean;
begin
  Err := NoError();
  ok := AsDouble(Args[0]) <> 0;
  Check(ok, Args[1].Str, 'expected true, got false');
  Result := ValInt(Ord(ok));
end;

function t_assert_true_bool(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Check(Args[0].Bl, '', 'expected true, got false');
  Result := ValInt(Ord(Args[0].Bl));
end;

// The bool-with-a-message form. Every other assertion had one; this one did not,
// so `assert_true(a% > b%, "why")` -- the natural way to write a comparison -- was
// a "no function assert_true:?$" error, and the test had to be reworded around the
// harness. A gap in the harness costs more than a gap in a library: it silently
// shapes what tests get written.
function t_assert_true_bool_msg(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Check(Args[0].Bl, Args[1].Str, 'expected true, got false');
  Result := ValInt(Ord(Args[0].Bl));
end;

function t_assert_false(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean;
begin
  Err := NoError();
  ok := AsDouble(Args[0]) = 0;
  Check(ok, '', 'expected false, got true');
  Result := ValInt(Ord(ok));
end;

function t_assert_false_msg(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean;
begin
  Err := NoError();
  ok := AsDouble(Args[0]) = 0;
  Check(ok, Args[1].Str, 'expected false, got true');
  Result := ValInt(Ord(ok));
end;

function t_assert_false_bool(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Check(not Args[0].Bl, '', 'expected false, got true');
  Result := ValInt(Ord(not Args[0].Bl));
end;

function t_assert_false_bool_msg(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Check(not Args[0].Bl, Args[1].Str, 'expected false, got true');
  Result := ValInt(Ord(not Args[0].Bl));
end;

function t_assert_eq_num(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean;
begin
  Err := NoError();
  ok := NumEquals(AsDouble(Args[0]), AsDouble(Args[1]));
  Check(ok, '', 'expected ' + NumStr(AsDouble(Args[1])) + ', got ' + NumStr(AsDouble(Args[0])));
  Result := ValInt(Ord(ok));
end;

function t_assert_eq_num_msg(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean;
begin
  Err := NoError();
  ok := NumEquals(AsDouble(Args[0]), AsDouble(Args[1]));
  Check(ok, Args[2].Str, 'expected ' + NumStr(AsDouble(Args[1])) + ', got ' + NumStr(AsDouble(Args[0])));
  Result := ValInt(Ord(ok));
end;

{ Byte-for-byte string equality.

  `A = B` on two AnsiStrings is CODE-PAGE AWARE: when the operands' dynamic code
  pages differ, FPC converts one before comparing, and the conversion can change
  the bytes. Two strings holding the identical five bytes 99 97 102 195 169 then
  compared unequal -- while the VM's own `=`, which compares bytes, called them
  equal. An assertion that disagrees with the language it is testing is worse than
  no assertion. }
function SameBytes(const A, B: String): Boolean;
var i: Integer;
begin
  Result := Length(A) = Length(B);
  if not Result then Exit;
  for i := 1 to Length(A) do
    if A[i] <> B[i] then Exit(False);
end;

function t_assert_eq_str(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean;
begin
  Err := NoError();
  ok := SameBytes(Args[0].Str, Args[1].Str);
  Check(ok, '', 'expected "' + Args[1].Str + '", got "' + Args[0].Str + '"');
  Result := ValInt(Ord(ok));
end;

function t_assert_eq_str_msg(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean;
begin
  Err := NoError();
  ok := SameBytes(Args[0].Str, Args[1].Str);
  Check(ok, Args[2].Str, 'expected "' + Args[1].Str + '", got "' + Args[0].Str + '"');
  Result := ValInt(Ord(ok));
end;

function t_assert_near(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean;
begin
  Err := NoError();
  ok := Abs(AsDouble(Args[0]) - AsDouble(Args[1])) <= Abs(AsDouble(Args[2]));
  Check(ok, '', 'expected ' + NumStr(AsDouble(Args[1])) + ' +/- ' + NumStr(AsDouble(Args[2])) +
               ', got ' + NumStr(AsDouble(Args[0])));
  Result := ValInt(Ord(ok));
end;

function t_assert_near_msg(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean;
begin
  Err := NoError();
  ok := Abs(AsDouble(Args[0]) - AsDouble(Args[1])) <= Abs(AsDouble(Args[2]));
  Check(ok, Args[3].Str, 'expected ' + NumStr(AsDouble(Args[1])) + ' +/- ' + NumStr(AsDouble(Args[2])) +
                         ', got ' + NumStr(AsDouble(Args[0])));
  Result := ValInt(Ord(ok));
end;

// The value stayed an int% -- dispatch to the '%%' slot only happens for int args.
function t_assert_int(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean;
begin
  Err := NoError();
  ok := Args[0].Int = Args[1].Int;
  Check(ok, '', 'expected int ' + IntToStr(Args[1].Int) + ', got ' + IntToStr(Args[0].Int));
  Result := ValInt(Ord(ok));
end;

{ AND ITS MESSAGE FORM (ledger d57). assert_int was `:%%` alone, so an int% check
  that wanted to say why had two choices: put the reason in a rem, or fall back on
  assert_eq -- which compared the two as Doubles with a slack that grew with the
  number. The second is how big-integer assertions became range checks. }
function t_assert_int_msg(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean;
begin
  Err := NoError();
  ok := Args[0].Int = Args[1].Int;
  Check(ok, Args[2].Str, 'expected int ' + IntToStr(Args[1].Int) + ', got ' + IntToStr(Args[0].Int));
  Result := ValInt(Ord(ok));
end;

// The checked add of two int64s overflows -- a catchable result, not a raise
// and not a silent double.
function t_assert_add_overflows(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: Int64; ok: Boolean;
begin
  Err := NoError();
  ok := not TryAddI64(Args[0].Int, Args[1].Int, r);
  Check(ok, '', 'expected overflow for ' + IntToStr(Args[0].Int) + ' + ' + IntToStr(Args[1].Int));
  Result := ValInt(Ord(ok));
end;

{ NO ASSERTION RUNS UNDER A LIVE ERROR TRAP (2026-10-08).

  A file that armed `on error goto h` for its whole length, with a handler that
  recorded the message and did `resume next`, SKIPPED every assertion whose own
  argument raised: the fault happened before the assert_* call, the handler
  swallowed it, and the statement was neither a pass nor a failure. A defect that
  made an asserted call fail therefore passed in silence -- a mutation that freed
  another document's JSON view survived tests/suite/78_free_handles.bas so.

  The read that decides is the VM's own (ErrTrapLive: the two fields Fault reads
  before it takes a fault), so this cannot disagree with what a fault would do.
  An assertion that runs while it is true is a FAILURE, recorded and not raised
  -- a raise would be swallowed by the very trap it is reporting. Arm the trap
  around the statement expected to fail and disarm it before asserting.

  What this cannot see is an assertion that is never CALLED: its argument raises,
  the trap takes the fault, and the assert_* routine -- where this check lives --
  never runs. Such a file fails only if some OTHER assertion runs while the same
  trap is armed; one whose armed stretch holds that single assertion and nothing
  else passes in silence. The GUI runner closes the same hole for event handlers
  separately: a handler's fault is counted there whether or not a trap is armed. }
function TrapGuard(AVM: TObject; AFunc: TPhosphorFunc; const Args: array of TValue;
                   out Err: TPhosphorError): TValue;
begin
  if TPhosphorVM(AVM).ErrTrapLive() then
  begin
    Err := NoError();
    RecordFail('an assertion ran while an ON ERROR trap was armed -- one whose ' +
               'argument raised would have been skipped, not failed; arm the ' +
               'trap only around the statement expected to fail');
    Exit(ValInt(0));
  end;
  Result := AFunc(Args, Err);
end;

function h_assert_true(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := TrapGuard(AVM, @t_assert_true, Args, Err); end;
function h_assert_true_msg(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := TrapGuard(AVM, @t_assert_true_msg, Args, Err); end;
function h_assert_true_bool(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := TrapGuard(AVM, @t_assert_true_bool, Args, Err); end;
function h_assert_true_bool_msg(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := TrapGuard(AVM, @t_assert_true_bool_msg, Args, Err); end;
function h_assert_false(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := TrapGuard(AVM, @t_assert_false, Args, Err); end;
function h_assert_false_msg(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := TrapGuard(AVM, @t_assert_false_msg, Args, Err); end;
function h_assert_false_bool(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := TrapGuard(AVM, @t_assert_false_bool, Args, Err); end;
function h_assert_false_bool_msg(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := TrapGuard(AVM, @t_assert_false_bool_msg, Args, Err); end;
function h_assert_eq_num(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := TrapGuard(AVM, @t_assert_eq_num, Args, Err); end;
function h_assert_eq_num_msg(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := TrapGuard(AVM, @t_assert_eq_num_msg, Args, Err); end;
function h_assert_eq_str(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := TrapGuard(AVM, @t_assert_eq_str, Args, Err); end;
function h_assert_eq_str_msg(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := TrapGuard(AVM, @t_assert_eq_str_msg, Args, Err); end;
function h_assert_near(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := TrapGuard(AVM, @t_assert_near, Args, Err); end;
function h_assert_near_msg(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := TrapGuard(AVM, @t_assert_near_msg, Args, Err); end;
function h_assert_int(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := TrapGuard(AVM, @t_assert_int, Args, Err); end;
function h_assert_int_msg(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := TrapGuard(AVM, @t_assert_int_msg, Args, Err); end;
function h_assert_add_overflows(AVM: TObject; const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Result := TrapGuard(AVM, @t_assert_add_overflows, Args, Err); end;

// --- handle-registry probes -------------------------------------------------
// A live probe handle is a real registry id; a fabricated one (pointer@(n)) is
// not, and IsHandle tells them apart WITHOUT dereferencing the address.

function t_probe_new_a(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValHandle(RegisterHandle(TProbeA.Create()));
  Inc(ProbeLiveCount);
end;

function t_probe_new_b(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValHandle(RegisterHandle(TProbeB.Create()));
  Inc(ProbeLiveCount);
end;

// Live registry id of ANY kind -> a handle; a fabricated/stale/nil id is not.
function t_probe_is_handle(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(Ord((Args[0].Kind = vkHandle) and IsHandle(Args[0].Hnd)));
end;

// Class discrimination: a live handle reports ONLY its own class. This is the
// check that stops a wrong-class handle from writing through the wrong vtable.
function t_probe_is_a(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(Ord((Args[0].Kind = vkHandle) and IsHandle(Args[0].Hnd)
                       and (HandleObj(Args[0].Hnd) is TProbeA)));
end;

function t_probe_is_b(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(Ord((Args[0].Kind = vkHandle) and IsHandle(Args[0].Hnd)
                       and (HandleObj(Args[0].Hnd) is TProbeB)));
end;

// Revoke: free a live probe handle (1) and invalidate its id; a fabricated or
// already-stale handle is refused (0), never followed.
function t_probe_free(const Args: array of TValue; out Err: TPhosphorError): TValue;
var ok: Boolean; obj: TObject;
begin
  Err := NoError();
  ok := False;
  if (Args[0].Kind = vkHandle) and IsHandle(Args[0].Hnd) then
  begin
    obj := HandleObj(Args[0].Hnd);
    ok := (obj is TProbeA) or (obj is TProbeB);
  end;
  if ok then
  begin
    FreeHandle(Args[0].Hnd);
    Dec(ProbeLiveCount);
  end;
  Result := ValInt(Ord(ok));
end;

function t_probe_count(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(ProbeLiveCount);
end;

{ IS THE RUN'S BUDGET LIVE? 1 when the host installed a ceiling, 0 when every
  meter is inert. A HARNESS question, not a language one -- which is why it lives
  here and nowhere a shipped binary links. It exists for ledger n17: the package
  runner installed no ceiling, so every BudgetAllows/BudgetCharge in every package
  answered "go ahead" without measuring anything, and a broken meter could not
  fail a single package test. tests/packages/12_budget_live.bas and
  13_http_budget_live.bas (one per runner) assert this is 1. }
function t_test_budget_active(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(Ord(BudgetActive()));
end;

procedure RegisterTestFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('test_case:$', @t_test_case);

  Reg.AddHost('assert_true:n',   @h_assert_true);
  Reg.AddHost('assert_true:n$',  @h_assert_true_msg);
  Reg.AddHost('assert_true:?',   @h_assert_true_bool);
  Reg.AddHost('assert_true:?$',  @h_assert_true_bool_msg);
  Reg.AddHost('assert_false:n',  @h_assert_false);
  Reg.AddHost('assert_false:n$', @h_assert_false_msg);
  Reg.AddHost('assert_false:?',  @h_assert_false_bool);
  Reg.AddHost('assert_false:?$', @h_assert_false_bool_msg);

  Reg.AddHost('assert_eq:nn',    @h_assert_eq_num);
  Reg.AddHost('assert_eq:nn$',   @h_assert_eq_num_msg);
  Reg.AddHost('assert_eq:$$',    @h_assert_eq_str);
  Reg.AddHost('assert_eq:$$$',   @h_assert_eq_str_msg);

  Reg.AddHost('assert_near:nnn',  @h_assert_near);
  Reg.AddHost('assert_near:nnn$', @h_assert_near_msg);

  Reg.AddHost('assert_int:%%',            @h_assert_int);
  Reg.AddHost('assert_int:%%$',           @h_assert_int_msg);
  Reg.AddHost('assert_add_overflows:%%',  @h_assert_add_overflows);

  Reg.Add('probe_new_a@:',   @t_probe_new_a);
  Reg.Add('probe_new_b@:',   @t_probe_new_b);
  Reg.Add('probe_is_handle:@', @t_probe_is_handle);
  Reg.Add('probe_is_a:@',    @t_probe_is_a);
  Reg.Add('probe_is_b:@',    @t_probe_is_b);
  Reg.Add('probe_free:@',    @t_probe_free);
  Reg.Add('probe_count:',    @t_probe_count);
  Reg.Add('test_budget_active:', @t_test_budget_active);
end;

procedure ResetTestState;
begin
  AssertsPassed := 0;
  AssertsFailed := 0;
  CurrentCase := '';
  ProbeLiveCount := 0;
  if Assigned(Failures) then Failures.Clear();
end;

initialization
  Failures := TStringList.Create();

finalization
  FreeAndNil(Failures);

end.
