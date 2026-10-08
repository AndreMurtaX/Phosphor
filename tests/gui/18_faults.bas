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
rem
rem THE TRAP IS LIFTED AROUND EVERY RUN OF ASSERTIONS (2026-10-08): it
rem guards the statements under test, never an assertion. Armed over an
rem assertion, an argument that raised was skipped by `resume next` --
rem neither passed nor failed -- and the test library now fails any
rem assertion that runs while a trap is armed. So a raise in a checked
rem call aborts the run, which is a failure, and not a silent skip.
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
on error goto 0
assert_eq(raised, 0, "the largest Int64 the language has did not raise")
assert_eq(control_left(b@), 2147483647, "it saturated at High(Integer)")
on error goto trapped

test_case("faults/and a value merely past Integer does not wrap")
raised = 0
control_left@(b@, 3e9)
on error goto 0
assert_eq(raised, 0, "3e9 did not raise")
assert_eq(control_left(b@), 2147483647, "3e9 saturated instead of answering -1294967296")
on error goto trapped

test_case("faults/the negative end saturates too")
raised = 0
control_top@(b@, -1e19)
on error goto 0
assert_eq(raised, 0, "-1e19 did not raise")
assert_eq(control_top(b@), -2147483648, "it saturated at Low(Integer)")
on error goto trapped

test_case("faults/the property bridge narrows the same way")
raised = 0
control_set@(b@, "Left", 1e19)
on error goto 0
assert_eq(raised, 0, "control_set@ with 1e19 did not raise")
assert_eq(control_left(b@), 2147483647, "and saturated instead of truncating to -1")
on error goto trapped

test_case("faults/but a 64-bit property through the bridge keeps its width")
rem 2^53, the largest integer a double holds exactly, so the assertion is
rem about the PROPERTY's width and not about the number's. Tag is PtrInt.
raised = 0
control_set@(b@, "Tag", 9007199254740992)
on error goto 0
assert_eq(raised, 0, "a 53-bit tag did not raise")
assert_eq(control_tag(b@), 9007199254740992, "and was not narrowed to 32 bits")
on error goto trapped

rem --- the LCL's hard ceiling on a control's size ---------------------
rem TControl.DoSetBounds traps (RaiseGDBException -> EDivByZero) above
rem 100000, so a size past it is refused here instead.
test_case("faults/a size past the LCL's ceiling is refused, not trapped")
control_size@(b@, 40, 20)
raised = 0
gui_clearerror()
control_width@(b@, 1000000)
on error goto 0
assert_eq(raised, 0, "a million pixels wide did not raise")
assert_eq(gui_error(), 1, "it was refused")
assert_eq(control_width(b@), 40, "and the control kept the width it had")
on error goto trapped

test_case("faults/a size at the ceiling is still accepted")
gui_clearerror()
control_width@(b@, 100000)
on error goto 0
assert_eq(gui_error(), 0, "100000 is inside the limit")
assert_eq(control_width(b@), 100000, "and was applied")
on error goto trapped
control_width@(b@, 40)

test_case("faults/a form is a control, so its own size is checked too")
raised = 0
gui_clearerror()
form_width@(f@, 1000000)
on error goto 0
assert_eq(raised, 0, "form_width@ did not raise")
assert_eq(gui_error(), 1, "it was refused")
assert_eq(form_width(f@), 400, "and the window kept its size")
on error goto trapped

rem --- a grid's header/count invariant -------------------------------
test_case("faults/emptying a grid that has a header row")
g@ = stringgrid@(f@)
stringgrid_rowcount@(g@, 5)
stringgrid_fixedrows@(g@, 1)
raised = 0
gui_clearerror()
stringgrid_rowcount@(g@, 0)
on error goto 0
assert_eq(raised, 0, "rowcount 0 under a header row did not raise")
assert_eq(gui_error(), 1, "it was refused")
assert_eq(stringgrid_rowcount(g@), 5, "and the grid kept its rows")
on error goto trapped

test_case("faults/a header taller than the grid")
raised = 0
gui_clearerror()
stringgrid_fixedrows@(g@, 99)
on error goto 0
assert_eq(raised, 0, "fixedrows 99 did not raise")
assert_eq(gui_error(), 1, "it was refused")
assert_eq(stringgrid_fixedrows(g@), 1, "and the header is unchanged")
on error goto trapped

test_case("faults/a negative header")
raised = 0
gui_clearerror()
stringgrid_fixedrows@(g@, -3)
on error goto 0
assert_eq(raised, 0, "fixedrows -3 did not raise")
assert_eq(gui_error(), 1, "it was refused")
on error goto trapped

test_case("faults/a header that fits is still accepted")
gui_clearerror()
stringgrid_fixedrows@(g@, 4)
on error goto 0
assert_eq(gui_error(), 0, "4 fixed rows in a 5-row grid is legal")
assert_eq(stringgrid_fixedrows(g@), 4, "and was applied")
on error goto trapped
stringgrid_fixedrows@(g@, 1)

test_case("faults/the draw grid has the same invariant")
dg@ = drawgrid@(f@)
raised = 0
gui_clearerror()
drawgrid_fixedcols@(dg@, 99)
on error goto 0
assert_eq(raised, 0, "drawgrid fixedcols 99 did not raise")
assert_eq(gui_error(), 1, "it was refused")
on error goto trapped
raised = 0
gui_clearerror()
drawgrid_rowcount@(dg@, 0)
on error goto 0
assert_eq(raised, 0, "drawgrid rowcount 0 did not raise")
assert_eq(gui_error(), 1, "it was refused")
on error goto trapped

rem --- a selection index out of range --------------------------------
test_case("faults/restoring a saved selection against a shorter list")
lb@ = listbox@(f@)
list_add@(lb@, "alpha")
list_itemindex@(lb@, 1)
raised = 0
gui_clearerror()
list_itemindex@(lb@, 4)
on error goto 0
assert_eq(raised, 0, "an index past the end did not raise")
assert_eq(gui_error(), 1, "it was refused")
assert_eq(list_itemindex(lb@), 1, "and the selection did not move")
on error goto trapped

test_case("faults/a selection index is still 1-based and 0 still clears it")
gui_clearerror()
list_itemindex@(lb@, 0)
on error goto 0
assert_eq(gui_error(), 0, "0 means nothing selected, not out of range")
assert_eq(list_itemindex(lb@), 0, "and nothing is selected")
on error goto trapped
list_itemindex@(lb@, 1)

test_case("faults/a radio group refuses both ends")
rg@ = radiogroup@(f@, "pick")
radiogroup_add@(rg@, "alpha")
raised = 0
gui_clearerror()
radiogroup_itemindex@(rg@, 500)
on error goto 0
assert_eq(raised, 0, "500 did not raise")
assert_eq(gui_error(), 1, "it was refused")
on error goto trapped
raised = 0
gui_clearerror()
radiogroup_itemindex@(rg@, -5)
on error goto 0
assert_eq(raised, 0, "-5 did not raise")
assert_eq(gui_error(), 1, "it was refused too")
on error goto trapped

rem --- a value the property bridge cannot convert ---------------------
test_case("faults/a typo in an enum value")
l@ = label@(f@, "x")
control_set@(l@, "Alignment", "taLeftJustify")
raised = 0
gui_clearerror()
control_set@(l@, "Alignment", "taCentre")
on error goto 0
assert_eq(raised, 0, "the misspelling did not raise")
assert_eq(gui_error(), 1, "it was refused")
assert_eq(control_get$(l@, "Alignment"), "taLeftJustify", "and the property kept its value")
on error goto trapped

test_case("faults/a typo in a set value, through both spellings")
control_anchors@(b@, "akLeft,akTop")
raised = 0
gui_clearerror()
control_set@(b@, "Anchors", "akNope")
on error goto 0
assert_eq(raised, 0, "control_set@ with a bad anchor did not raise")
assert_eq(gui_error(), 1, "it was refused")
on error goto trapped
raised = 0
gui_clearerror()
control_anchors@(b@, "garbage")
on error goto 0
assert_eq(raised, 0, "control_anchors@ with a bad anchor did not raise")
assert_eq(gui_error(), 1, "it was refused")
rem Read back in TAnchorKind's declaration order (akTop, akLeft, akRight,
rem akBottom), which is what GetSetProp answers -- not the order they went in.
assert_eq(control_anchors$(b@), "akTop,akLeft", "and the anchors are unchanged")
on error goto trapped

test_case("faults/an ordinal the control itself bounds-checks")
raised = 0
gui_clearerror()
control_set@(lb@, "ItemIndex", 500)
on error goto 0
assert_eq(raised, 0, "the bridge did not raise")
assert_eq(gui_error(), 1, "it was refused")
on error goto trapped

test_case("faults/a component name the RTL rejects")
raised = 0
gui_clearerror()
control_set@(b@, "Name", "not a name")
on error goto 0
assert_eq(raised, 0, "an invalid name did not raise")
assert_eq(gui_error(), 1, "it was refused")
on error goto trapped

test_case("faults/and a name already taken by a sibling")
gui_clearerror()
control_set@(b@, "Name", "dup")
on error goto 0
assert_eq(gui_error(), 0, "the first control took the name")
on error goto trapped
raised = 0
gui_clearerror()
control_set@(l@, "Name", "dup")
on error goto 0
assert_eq(raised, 0, "the duplicate did not raise")
assert_eq(gui_error(), 1, "it was refused")
on error goto trapped

rem --- a date the calendar has no day for -----------------------------
test_case("faults/a date outside the Gregorian calendar")
cal@ = calendar@(f@)
calendar_date@(cal@, 45000)
raised = 0
gui_clearerror()
calendar_date@(cal@, -1000000)
on error goto 0
assert_eq(raised, 0, "a date before year 1 did not raise")
assert_eq(gui_error(), 1, "it was refused")
on error goto trapped
raised = 0
gui_clearerror()
calendar_date@(cal@, 1e12)
on error goto 0
assert_eq(raised, 0, "a date past year 9999 did not raise")
assert_eq(gui_error(), 1, "it was refused")
assert_near(calendar_date(cal@), 45000, 1, "and the calendar kept its date")
on error goto trapped

rem --- a handle whose control is gone is REFUSED, not reported freed --
rem The two shapes above are exceptions that reached BASIC. This one and
rem the next are the quieter fault: nothing raises, nothing is refused,
rem and the program is told something untrue.
rem
rem control_free answered 1 with gui_error 0 for a stale child handle. It
rem was reporting the release of the handle WRAPPER, which survives its
rem control, rather than the destruction of a control, which had already
rem happened when the form died. So a program that freed a form and then
rem looped over its children was told it had destroyed every one, while
rem every other reader of the same handle answered ""/0 with gui_error 1.
rem gui-control.md has always said otherwise: "0 with gui_error() = 1 for
rem a stale, doubly-freed or fabricated handle".
test_case("faults/a stale child handle is refused by control_free, not reported freed")
sf@ = form@("stale", 200, 100)
sp@ = panel@(sf@)
sb@ = button@(sp@)
raised = 0
gui_clearerror()
on error goto 0
assert_eq(control_free(sf@), 1, "the form is freed, and it owned the tree")
assert_eq(gui_error(), 0, "with nothing recorded")
on error goto trapped
gui_clearerror()
on error goto 0
assert_eq(control_free(sp@), 0, "the child handle names nothing left to destroy")
assert_eq(gui_error(), 1, "and says so")
on error goto trapped
gui_clearerror()
on error goto 0
assert_eq(control_width(sp@), 0, "which is the answer control_width already gave")
assert_eq(gui_error(), 1, "with the same code -- the readers agree now")
on error goto trapped
gui_clearerror()
on error goto 0
assert_eq(control_free(sb@), 0, "the grandchild is refused too")
assert_eq(gui_error(), 1, "one level down makes no difference")
assert_eq(raised, 0, "and none of it raised")
on error goto trapped

rem --- a call that SUCCEEDS must not clear the sticky slot ------------
rem gui-core.md defines the slot: "sticky, like err(). Nothing clears it
rem but gui_clearerror() -- a later successful call does not", which is
rem what makes "read it once after the whole sequence" a legal shape.
rem The canvas resolver used to probe TBitmap, then TPaintBox, then
rem TCustomControl, writing a blanket zero between attempts to undo the
rem wrong-class error its own failed probe had recorded. That zero could
rem not tell its own error from the program's, so a successful drawing
rem call on any of ten handle kinds turned an earlier real failure into
rem "none failed". Poisoned with 3 rather than 1 on purpose: 3 tells
rem "the earlier code survived" apart from "this call recorded one".
test_case("faults/a successful canvas call leaves gui_error alone")
pbx@ = paintbox@(f@)
bmx@ = bitmap@(8, 8)
nbx@ = label@(f@, "no canvas here")
raised = 0
gui_clearerror()
pz = control_get(f@, "NoSuchPropertyAtAll")
on error goto 0
assert_eq(gui_error(), 3, "an unpublished property records 3")
on error goto trapped
canvas_pencolor@(pbx@, 255)
on error goto 0
assert_eq(gui_error(), 3, "a successful draw on a paint box does not erase it")
on error goto trapped
canvas_rectangle@(f@, 0, 0, 4, 4)
on error goto 0
assert_eq(gui_error(), 3, "nor one on a windowed control that paints itself")
on error goto trapped
canvas_lineto@(bmx@, 3, 3)
on error goto 0
assert_eq(gui_error(), 3, "nor one on a bitmap, which never did")
on error goto trapped
gui_clearerror()
canvas_pencolor@(nbx@, 255)
on error goto 0
assert_eq(gui_error(), 1, "while a control with no canvas is still refused")
assert_eq(raised, 0, "and none of it raised")
on error goto trapped

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
on error goto 0
assert_eq(raised, 0, "closing did not raise")
assert_eq(freed, 1, "the handler ran and asked for the free")
assert_eq(gui_error(), 1, "the free was refused while the close was unwinding")
on error goto trapped
gui_clearerror()
on error goto 0
assert_eq(form_caption$(c@), "closes", "and the form is still there to answer")
assert_eq(gui_error(), 0, "through a handle that still resolves")
on error goto 0

test_case("faults/a handler fault provoked on purpose is acknowledged, and the file passes")
rem THE PASS SIDE OF THE LEDGER (2026-10-08, second adversarial round).
rem tests/gui/ledger/forgot.bas shows an unacknowledged handler fault
rem FAILS a run; nothing showed an acknowledged one does not. A
rem gui_test_handler_faults() that answered the count and never cleared
rem it passed every runner -- and would fail THIS file at its end, which
rem is the point of putting the case in a file that must pass. The
rem expected values are the rule's: two clicks on a handler that divides
rem by zero are two faults, each sets gui_error() to 2, and reading the
rem count clears it.
fz = 0
fb@ = button@(f@)
button_onclick@(fb@, "on_divide")
gui_clearerror()
button_click@(fb@)
assert_eq(gui_error(), 2, "a handler that faulted is recorded as 2, not raised")
button_click@(fb@)
assert_eq(gui_test_handler_faults(), 2, "both faults are counted")
assert_eq(gui_test_handler_faults(), 0, "and reading the count cleared it")
button_onclick@(fb@, "")

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

function on_divide(sender@)
  y = 1 / fz
  return 0
endfunction
