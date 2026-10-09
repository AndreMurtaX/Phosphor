rem ---------------------------------------------------------------
rem DOCUMENTED SETTERS ANSWER; THEY DO NOT RAISE (2026-10-09, round 4).
rem All of this runs on a form that is NEVER shown -- the headless mode
rem gui-control.md calls first-class. Each case was seen failing on the
rem round-3 build, for the reason its comment names.
rem
rem Expected values come from the LCL source and the docs, not a run:
rem   * TCustomScrollBar starts at Min 0, Max 100 (scrollbar.inc); its
rem     SetParams RAISES when min would pass max. The sibling trackbar's
rem     FixParams pulls the min to the max instead, and gui-range.md
rem     promises the trackbar's quiet answer for the whole package.
rem   * TCustomUpDown's Min/Max/Position are SmallInt (-32768..32767),
rem     and it starts at Min 0, Max 100 (customupdown.inc).
rem   * TCustomTimer.Interval is a Cardinal; a negative count is 0.
rem   * A grid's and a tree view's MouseDown call SetFocus, which raises
rem     "Can not focus" on a form never shown; focus before form_show@ is
rem     a documented no-op, and the handler must still run.
rem   * A position is a SmallInt, a size at most 32767
rem     (PhosphorGuiCore.GuiMaxExtent); past either the setter records
rem     gui_error 1 and leaves the control where it was.
rem
rem The trap is lifted around every run of assertions.
rem ---------------------------------------------------------------

raised = 0
msg$ = ""
downs = 0
on error goto trapped

f@ = form@("ranges", 400, 300)

rem --- the scroll bar's two ends -----------------------------------
test_case("ranges/a scroll bar min past its max is pulled to the max")
sb@ = scrollbar@(f@)
raised = 0
gui_clearerror()
x@ = scrollbar_min@(sb@, 200)
on error goto 0
assert_eq(raised, 0, "scrollbar_min@ past the max did not raise")
assert_eq(gui_error(), 0, "and is not an error: it is the trackbar's rule")
assert_eq(scrollbar_min(sb@), 100, "the min became the max, 100")
assert_eq(scrollbar_max(sb@), 100, "and the max stayed 100")
on error goto trapped

test_case("ranges/a scroll bar max below its min drags the min down")
sb2@ = scrollbar@(f@)
raised = 0
x@ = scrollbar_max@(sb2@, -1)
on error goto 0
assert_eq(raised, 0, "scrollbar_max@ below the min did not raise")
assert_eq(scrollbar_max(sb2@), -1, "the max is -1")
assert_eq(scrollbar_min(sb2@), -1, "and the min followed it to -1")
on error goto trapped

test_case("ranges/and an ordinary range is untouched")
sb3@ = scrollbar@(f@)
x@ = scrollbar_max@(sb3@, 500)
x@ = scrollbar_min@(sb3@, 10)
x@ = scrollbar_position@(sb3@, 250)
on error goto 0
assert_eq(scrollbar_min(sb3@), 10, "min 10")
assert_eq(scrollbar_max(sb3@), 500, "max 500")
assert_eq(scrollbar_position(sb3@), 250, "position 250")
on error goto trapped

rem --- the up/down is a SmallInt ------------------------------------
test_case("ranges/an up/down saturates at the SmallInt ends")
ud@ = updown@(f@)
x@ = updown_max@(ud@, 40000)
x@ = updown_min@(ud@, -40000)
on error goto 0
assert_eq(updown_max(ud@), 32767, "40000 is held at 32767, not wrapped to -25536")
assert_eq(updown_min(ud@), -32768, "-40000 is held at -32768, not wrapped to 25536")
on error goto trapped
x@ = updown_position@(ud@, 70000)
on error goto 0
assert_eq(updown_position(ud@), 32767, "and a position of 70000 is 32767")
on error goto trapped

rem --- a timer's interval is a Cardinal -----------------------------
test_case("ranges/a negative timer interval is 0, not 4294967295")
t@ = timer@()
x@ = timer_interval@(t@, -1)
on error goto 0
assert_eq(timer_interval(t@), 0, "-1 is 0")
on error goto trapped
x@ = timer_interval@(t@, 250)
on error goto 0
assert_eq(timer_interval(t@), 250, "and 250 is 250")
on error goto trapped
x = control_free(t@)

rem --- a synthesised click on a control that focuses ----------------
test_case("ranges/control_mousedown@ on a grid of a hidden form")
sg@ = stringgrid@(f@)
x@ = control_tag@(sg@, 77)
x@ = control_onmousedown@(sg@, "on_down")
downs = 0
raised = 0
gui_clearerror()
r@ = control_mousedown@(sg@, 0, 5, 5, "")
on error goto 0
assert_eq(raised, 0, "a string grid did not raise 'Can not focus'")
assert_eq(gui_error(), 0, "and the refused focus is not an error")
assert_eq(downs, 1, "its handler ran once")
assert_eq(control_tag(r@), 77, "and the call answers the grid (tag 77)")
on error goto trapped

dg@ = drawgrid@(f@)
x@ = control_onmousedown@(dg@, "on_down")
downs = 0
raised = 0
r@ = control_mousedown@(dg@, 0, 5, 5, "")
on error goto 0
assert_eq(raised, 0, "a draw grid did not raise")
assert_eq(downs, 1, "and its handler ran once")
on error goto trapped

test_case("ranges/control_mousedown@ on a tree view of a hidden form")
rem TCustomTreeView.MouseDown focuses BEFORE it calls the handler, so
rem the handler running is the half that a caught exception alone
rem would have lost.
tv@ = treeview@(f@)
x@ = control_onmousedown@(tv@, "on_down")
downs = 0
raised = 0
gui_clearerror()
r@ = control_mousedown@(tv@, 0, 5, 5, "")
on error goto 0
assert_eq(raised, 0, "a tree view did not raise")
assert_eq(gui_error(), 0, "and recorded nothing")
assert_eq(downs, 1, "its handler still ran, once")
on error goto trapped
rem And the binding is the program's again afterwards: a second click
rem runs the same handler once more.
r@ = control_mousedown@(tv@, 0, 5, 5, "")
on error goto 0
assert_eq(downs, 2, "a second click runs it again")
on error goto trapped
x@ = control_onmousedown@(tv@, "")
r@ = control_mousedown@(tv@, 0, 5, 5, "")
on error goto 0
assert_eq(downs, 2, "and unbound, nothing runs")
on error goto trapped

test_case("ranges/control_mouseup@ on the same controls")
x@ = control_onmouseup@(sg@, "on_down")
downs = 0
raised = 0
r@ = control_mouseup@(sg@, 0, 5, 5, "")
r@ = control_mouseup@(tv@, 0, 5, 5, "")
on error goto 0
assert_eq(raised, 0, "a release raises nothing either")
assert_eq(downs, 1, "and the bound one ran")
on error goto trapped

rem --- positions and sizes, the same on a hidden form ----------------
test_case("ranges/a position is a SmallInt")
b@ = button@(f@)
x@ = control_bounds@(b@, 10, 20, 40, 30)
gui_clearerror()
x@ = control_left@(b@, 32767)
on error goto 0
assert_eq(gui_error(), 0, "32767 is a position")
assert_eq(control_left(b@), 32767, "and was applied")
on error goto trapped
x@ = control_left@(b@, 32768)
on error goto 0
assert_eq(gui_error(), 1, "32768 is refused")
assert_eq(control_left(b@), 32767, "and the control stayed where it was")
on error goto trapped
gui_clearerror()
x@ = control_top@(b@, -32768)
on error goto 0
assert_eq(gui_error(), 0, "-32768 is a position")
assert_eq(control_top(b@), -32768, "and was applied")
on error goto trapped
x@ = control_top@(b@, -32769)
on error goto 0
assert_eq(gui_error(), 1, "-32769 is refused")
assert_eq(control_top(b@), -32768, "and the top is unchanged")
on error goto trapped
gui_clearerror()
x@ = control_move@(b@, 5, 100000)
on error goto 0
assert_eq(gui_error(), 1, "control_move@ refuses both halves")
assert_eq(control_left(b@), 32767, "the left was not moved")
on error goto trapped
gui_clearerror()
x@ = control_set@(b@, "Left", 40000)
on error goto 0
assert_eq(gui_error(), 1, "and the bridge refuses the same position")
assert_eq(control_left(b@), 32767, "keeping the old one")
on error goto trapped

test_case("ranges/a size is at most 32767")
x@ = control_bounds@(b@, 10, 20, 40, 30)
gui_clearerror()
x@ = control_width@(b@, 32767)
on error goto 0
assert_eq(gui_error(), 0, "32767 wide is accepted")
assert_eq(control_width(b@), 32767, "and applied")
on error goto trapped
x@ = control_width@(b@, 32768)
on error goto 0
assert_eq(gui_error(), 1, "32768 wide is refused")
assert_eq(control_width(b@), 32767, "and the width is unchanged")
on error goto trapped
gui_clearerror()
x@ = control_set@(b@, "Height", 40000)
on error goto 0
assert_eq(gui_error(), 1, "the bridge holds Height to it too")
assert_eq(control_height(b@), 30, "with the height unchanged")
on error goto trapped
gui_clearerror()
x@ = control_minwidth@(b@, 40000)
on error goto 0
assert_eq(gui_error(), 1, "a minimum width past it is refused")
assert_eq(control_minwidth(b@), 0, "and no constraint was set")
on error goto trapped
gui_clearerror()
x@ = control_spacing@(b@, 40000)
on error goto 0
assert_eq(gui_error(), 1, "a gap past it is refused")
assert_eq(control_spacing(b@), 0, "and none was set")
on error goto trapped
gui_clearerror()
x@ = form_width@(f@, 32768)
on error goto 0
assert_eq(gui_error(), 1, "a form is held to it as well")
assert_eq(form_width(f@), 400, "and kept its width")
on error goto trapped

end

function on_down(sender@, button%, x%, y%, mods$)
  downs = downs + 1
  return 0
endfunction

trapped:
raised = 1
msg$ = errmsg$()
resume next
