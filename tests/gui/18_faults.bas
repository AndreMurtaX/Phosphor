rem ---------------------------------------------------------------
rem NO EXCEPTION CROSSES INTO BASIC -- the GUI packages' headline rule,
rem tested rather than asserted in prose.
rem
rem Every case here KILLED the interpreter before this file existed.
rem Three shapes, all reachable from ordinary programs:
rem
rem   * an LCL refusal raised through a setter: a grid emptied while it
rem     still has a header row, a saved selection restored against a
rem     shorter list, a misspelled property value. The message a
rem     programmer got was LCL-internal ("FixedRows can't be >
rem     RowCount") and named nothing they had written.
rem   * a hardware trap: PhosphorControlLib rounded a program's number
rem     with Round(), which traps on anything past Int64 and wrapped in
rem     silence below that -- control_left@(b@, 3e9) answered
rem     -1294967296.
rem   * a use-after-free: control_free inside form_onclose@ destroyed
rem     the form that TCustomForm.Close was still standing on.
rem
rem THE FILE IS WRITTEN SO A RETURNING BUG FAILS RATHER THAN ABORTING
rem THE RUNNER, the way tests/suite/54 guards its loops: `on error goto`
rem catches anything that still raises, records it in `raised`, and
rem `resume next` carries on -- so the summary still prints and names
rem the case. Each case therefore asserts TWO things: that nothing was
rem raised, and that gui_error() gave the answer the packages promise.
rem
rem gui_error 1 is the contract here, not err(): docs/libraries/gui-core.md
rem defines 1 as "an index outside the control's range, or an operation
rem the control refused", which is every case below.
rem ---------------------------------------------------------------

raised = 0
freed = 0

on error goto trapped

f@ = form@("faults", 400, 300)

rem --- the arithmetic trap and the silent wrap ------------------------
test_case("faults/a number too large for Integer saturates, never traps")
b@ = button@(f@)
raised = 0
gui_clearerror()
n% = 9223372036854775807
control_left@(b@, n%)
assert_eq(raised, 0, "the largest Int64 the language has did not raise")
assert_eq(control_left(b@), 2147483647, "it saturated at High(Integer)")

test_case("faults/and a value merely past Integer does not wrap")
raised = 0
control_left@(b@, 3e9)
assert_eq(raised, 0, "3e9 did not raise")
assert_eq(control_left(b@), 2147483647, "3e9 saturated instead of answering -1294967296")

test_case("faults/the negative end saturates too")
raised = 0
control_top@(b@, -1e19)
assert_eq(raised, 0, "-1e19 did not raise")
assert_eq(control_top(b@), -2147483648, "it saturated at Low(Integer)")

test_case("faults/the property bridge narrows the same way")
raised = 0
control_set@(b@, "Left", 1e19)
assert_eq(raised, 0, "control_set@ with 1e19 did not raise")
assert_eq(control_left(b@), 2147483647, "and saturated instead of truncating to -1")

test_case("faults/but a 64-bit property through the bridge keeps its width")
rem 2^53, the largest integer a double holds exactly, so the assertion is
rem about the PROPERTY's width and not about the number's. Tag is PtrInt.
raised = 0
control_set@(b@, "Tag", 9007199254740992)
assert_eq(raised, 0, "a 53-bit tag did not raise")
assert_eq(control_tag(b@), 9007199254740992, "and was not narrowed to 32 bits")

rem --- the LCL's hard ceiling on a control's size ---------------------
rem TControl.DoSetBounds traps (RaiseGDBException -> EDivByZero) above
rem 100000, so a size past it is refused here instead.
test_case("faults/a size past the LCL's ceiling is refused, not trapped")
control_size@(b@, 40, 20)
raised = 0
gui_clearerror()
control_width@(b@, 1000000)
assert_eq(raised, 0, "a million pixels wide did not raise")
assert_eq(gui_error(), 1, "it was refused")
assert_eq(control_width(b@), 40, "and the control kept the width it had")

test_case("faults/a size at the ceiling is still accepted")
gui_clearerror()
control_width@(b@, 100000)
assert_eq(gui_error(), 0, "100000 is inside the limit")
assert_eq(control_width(b@), 100000, "and was applied")
control_width@(b@, 40)

test_case("faults/a form is a control, so its own size is checked too")
raised = 0
gui_clearerror()
form_width@(f@, 1000000)
assert_eq(raised, 0, "form_width@ did not raise")
assert_eq(gui_error(), 1, "it was refused")
assert_eq(form_width(f@), 400, "and the window kept its size")

rem --- a grid's header/count invariant -------------------------------
test_case("faults/emptying a grid that has a header row")
g@ = stringgrid@(f@)
stringgrid_rowcount@(g@, 5)
stringgrid_fixedrows@(g@, 1)
raised = 0
gui_clearerror()
stringgrid_rowcount@(g@, 0)
assert_eq(raised, 0, "rowcount 0 under a header row did not raise")
assert_eq(gui_error(), 1, "it was refused")
assert_eq(stringgrid_rowcount(g@), 5, "and the grid kept its rows")

test_case("faults/a header taller than the grid")
raised = 0
gui_clearerror()
stringgrid_fixedrows@(g@, 99)
assert_eq(raised, 0, "fixedrows 99 did not raise")
assert_eq(gui_error(), 1, "it was refused")
assert_eq(stringgrid_fixedrows(g@), 1, "and the header is unchanged")

test_case("faults/a negative header")
raised = 0
gui_clearerror()
stringgrid_fixedrows@(g@, -3)
assert_eq(raised, 0, "fixedrows -3 did not raise")
assert_eq(gui_error(), 1, "it was refused")

test_case("faults/a header that fits is still accepted")
gui_clearerror()
stringgrid_fixedrows@(g@, 4)
assert_eq(gui_error(), 0, "4 fixed rows in a 5-row grid is legal")
assert_eq(stringgrid_fixedrows(g@), 4, "and was applied")
stringgrid_fixedrows@(g@, 1)

test_case("faults/the draw grid has the same invariant")
dg@ = drawgrid@(f@)
raised = 0
gui_clearerror()
drawgrid_fixedcols@(dg@, 99)
assert_eq(raised, 0, "drawgrid fixedcols 99 did not raise")
assert_eq(gui_error(), 1, "it was refused")
raised = 0
gui_clearerror()
drawgrid_rowcount@(dg@, 0)
assert_eq(raised, 0, "drawgrid rowcount 0 did not raise")
assert_eq(gui_error(), 1, "it was refused")

rem --- a selection index out of range --------------------------------
test_case("faults/restoring a saved selection against a shorter list")
lb@ = listbox@(f@)
list_add@(lb@, "alpha")
list_itemindex@(lb@, 1)
raised = 0
gui_clearerror()
list_itemindex@(lb@, 4)
assert_eq(raised, 0, "an index past the end did not raise")
assert_eq(gui_error(), 1, "it was refused")
assert_eq(list_itemindex(lb@), 1, "and the selection did not move")

test_case("faults/a selection index is still 1-based and 0 still clears it")
gui_clearerror()
list_itemindex@(lb@, 0)
assert_eq(gui_error(), 0, "0 means nothing selected, not out of range")
assert_eq(list_itemindex(lb@), 0, "and nothing is selected")
list_itemindex@(lb@, 1)

test_case("faults/a radio group refuses both ends")
rg@ = radiogroup@(f@, "pick")
radiogroup_add@(rg@, "alpha")
raised = 0
gui_clearerror()
radiogroup_itemindex@(rg@, 500)
assert_eq(raised, 0, "500 did not raise")
assert_eq(gui_error(), 1, "it was refused")
raised = 0
gui_clearerror()
radiogroup_itemindex@(rg@, -5)
assert_eq(raised, 0, "-5 did not raise")
assert_eq(gui_error(), 1, "it was refused too")

rem --- a value the property bridge cannot convert ---------------------
test_case("faults/a typo in an enum value")
l@ = label@(f@, "x")
control_set@(l@, "Alignment", "taLeftJustify")
raised = 0
gui_clearerror()
control_set@(l@, "Alignment", "taCentre")
assert_eq(raised, 0, "the misspelling did not raise")
assert_eq(gui_error(), 1, "it was refused")
assert_eq(control_get$(l@, "Alignment"), "taLeftJustify", "and the property kept its value")

test_case("faults/a typo in a set value, through both spellings")
control_anchors@(b@, "akLeft,akTop")
raised = 0
gui_clearerror()
control_set@(b@, "Anchors", "akNope")
assert_eq(raised, 0, "control_set@ with a bad anchor did not raise")
assert_eq(gui_error(), 1, "it was refused")
raised = 0
gui_clearerror()
control_anchors@(b@, "garbage")
assert_eq(raised, 0, "control_anchors@ with a bad anchor did not raise")
assert_eq(gui_error(), 1, "it was refused")
rem Read back in TAnchorKind's declaration order (akTop, akLeft, akRight,
rem akBottom), which is what GetSetProp answers -- not the order they went in.
assert_eq(control_anchors$(b@), "akTop,akLeft", "and the anchors are unchanged")

test_case("faults/an ordinal the control itself bounds-checks")
raised = 0
gui_clearerror()
control_set@(lb@, "ItemIndex", 500)
assert_eq(raised, 0, "the bridge did not raise")
assert_eq(gui_error(), 1, "it was refused")

test_case("faults/a component name the RTL rejects")
raised = 0
gui_clearerror()
control_set@(b@, "Name", "not a name")
assert_eq(raised, 0, "an invalid name did not raise")
assert_eq(gui_error(), 1, "it was refused")

test_case("faults/and a name already taken by a sibling")
gui_clearerror()
control_set@(b@, "Name", "dup")
assert_eq(gui_error(), 0, "the first control took the name")
raised = 0
gui_clearerror()
control_set@(l@, "Name", "dup")
assert_eq(raised, 0, "the duplicate did not raise")
assert_eq(gui_error(), 1, "it was refused")

rem --- a date the calendar has no day for -----------------------------
test_case("faults/a date outside the Gregorian calendar")
cal@ = calendar@(f@)
calendar_date@(cal@, 45000)
raised = 0
gui_clearerror()
calendar_date@(cal@, -1000000)
assert_eq(raised, 0, "a date before year 1 did not raise")
assert_eq(gui_error(), 1, "it was refused")
raised = 0
gui_clearerror()
calendar_date@(cal@, 1e12)
assert_eq(raised, 0, "a date past year 9999 did not raise")
assert_eq(gui_error(), 1, "it was refused")
assert_near(calendar_date(cal@), 45000, 1, "and the calendar kept its date")

rem --- freeing the object the LCL is standing on ----------------------
rem LAST ON PURPOSE. Before the fix this ran the handler, freed the form
rem underneath TCustomForm.Close, and took an access violation as the
rem close unwound -- so anything after it would have been running on a
rem corrupted heap.
test_case("faults/disposing a form from inside its own onclose")
c@ = form@("closes", 200, 100)
form_onclose@(c@, "cleanup")
raised = 0
gui_clearerror()
form_close@(c@)
assert_eq(raised, 0, "closing did not raise")
assert_eq(freed, 1, "the handler ran and asked for the free")
assert_eq(gui_error(), 1, "the free was refused while the close was unwinding")
gui_clearerror()
assert_eq(form_caption$(c@), "closes", "and the form is still there to answer")
assert_eq(gui_error(), 0, "through a handle that still resolves")

end

trapped:
rem Anything that still RAISES lands here. The flag turns it into a
rem failed assertion at the case that caused it, rather than an abort
rem with no summary; `resume next` keeps the remaining cases running.
raised = 1
resume next

function cleanup(sender@)
  freed = 1
  control_free(sender@)
  return 0
endfunction
