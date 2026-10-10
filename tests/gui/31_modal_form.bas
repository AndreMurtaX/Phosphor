rem ---------------------------------------------------------------
rem MODAL FORMS: form_showmodal waits inside the call until the form is
rem answered, and answers its result.
rem
rem In this runner no form is ever shown: gui_test_modal(fn$) queues a
rem function that runs INSIDE the next modal form, with its handle, and
rem does what a person would -- types, presses buttons. The form's
rem ModalResult when it returns is what form_showmodal answers.
rem
rem EXPECTED VALUES, from the LCL, not from a run:
rem   - the modal results are the LCL's mr* constants (System.UITypes):
rem     mrNone 0, mrOk 1, mrCancel 2, mrYes 6, mrNo 7;
rem   - TCustomButton.Click sets the parent form's ModalResult to the
rem     button's own when that is not mrNone (lcl/include/buttons.inc, TCustomButton.Click),
rem     and an ordinary button's is mrNone, so it leaves the form open;
rem   - TCustomForm.ShowModal refuses a form that is already visible or
rem     not enabled (RaiseShowModalImpossible, include/customform.inc);
rem     the library answers that as every GUI refusal: 0, gui_error 1.
rem   - ROUND 5 (2026-10-10): inside its session a modal form is VISIBLE
rem     and modal (ShowModal: Include(fsModal); Show), so a second
rem     form_showmodal of it is refused; TCustomForm.Close on a modal form
rem     sets mrCancel (2); a non-zero result goes through CloseModal --
rem     CloseQuery, then DoClose -- and a veto sets it back to 0, so the
rem     form stays open for the next round (the next queued function, as a
rem     person tries again). A form parented inside another is refused:
rem     its buttons would answer the top form (GetParentForm).
rem ---------------------------------------------------------------

main@ = form@("main", 300, 200)
dlg@ = form@("Your name", 300, 150)
nm@ = edit@(dlg@)
ok@ = button@(dlg@)
button_caption@(ok@, "OK")
button_modalresult@(ok@, 1)
cancel@ = button@(dlg@)
button_caption@(cancel@, "Cancel")
button_modalresult@(cancel@, 2)
plain@ = button@(dlg@)
button_caption@(plain@, "Check")
okclicks = 0
button_onclick@(ok@, "on_ok")

test_case("modal/a button carries the result it answers")
assert_eq(button_modalresult(ok@), 1, "OK's modal result is 1")
assert_eq(button_modalresult(plain@), 0, "an ordinary button's is 0 (mrNone)")

test_case("modal/the program works inside the form, and OK answers 1")
inside = 0
gui_test_modal("type_and_ok")
r = form_showmodal(dlg@)
assert_eq(r, 1, "OK answers 1")
assert_eq(inside, 1, "the queued function ran inside the modal session")
assert_eq(edit_text$(nm@), "Ada", "what was typed in the form is there after it")
assert_eq(okclicks, 1, "and OK's own click handler ran, as a person's click runs it")
assert_eq(form_visible(dlg@), 0, "the form is not left shown")

test_case("modal/Cancel answers 2, and a form can be shown modally again")
gui_test_modal("press_cancel")
assert_eq(form_showmodal(dlg@), 2, "Cancel answers 2")

test_case("modal/a handler can answer the form itself")
gui_test_modal("answer_yes")
assert_eq(form_showmodal(dlg@), 6, "form_modalresult@ answers 6 (mrYes)")
assert_eq(form_modalresult(dlg@), 6, "and the form keeps the value it answered")

test_case("modal/an ordinary button leaves the form open")
gui_test_modal("plain_then_ok")
assert_eq(form_showmodal(dlg@), 1, "Check changed nothing; OK then answered 1")

test_case("modal/one modal form inside another")
second@ = form@("Second", 200, 100)
yes@ = button@(second@)
button_modalresult@(yes@, 6)
gui_test_modal("open_second")
gui_test_modal("press_yes")
assert_eq(form_showmodal(dlg@), 1, "the outer form answered 1 after the inner one closed")
assert_eq(inner, 6, "the inner form answered 6 to the code inside the outer one")

test_case("modal/a modal form cannot be freed while it is modal")
gui_test_modal("try_free")
assert_eq(form_showmodal(dlg@), 1, "it answered normally")
assert_eq(freed, 0, "control_free of it, from inside, answered 0")
assert_eq(freeerr, 1, "and recorded gui_error 1")

test_case("modal/inside its session the form is visible and already modal")
gui_test_modal("look_inside")
assert_eq(form_showmodal(dlg@), 1, "it answered 1")
assert_eq(seenvisible, 1, "inside, form_visible answered 1")
assert_eq(again, 0, "a second form_showmodal of it answered 0")
assert_eq(againerr, 1, "and recorded gui_error 1")
assert_eq(form_visible(dlg@), 0, "and it is hidden when the session ends")

test_case("modal/form_close@ on a modal form answers 2")
gui_test_modal("close_it")
assert_eq(form_showmodal(dlg@), 2, "closing it answered 2 (mrCancel)")

test_case("modal/onclosequery can veto an answer, and the next round goes on")
vdlg@ = form@("Validating", 200, 100)
vok@ = button@(vdlg@)
button_modalresult@(vok@, 1)
form_onclosequery@(vdlg@, "may_close?")
form_onclose@(vdlg@, "on_vclose")
allow? = false
queries = 0
closes = 0
gui_test_modal("press_vok")
gui_test_modal("allow_and_press_vok")
assert_eq(form_showmodal(vdlg@), 1, "the second OK answered 1")
assert_eq(queries, 2, "onclosequery was asked twice: once vetoing, once allowing")
assert_eq(closes, 1, "onclose ran once, for the answer that closed it")
assert_eq(afterveto, 0, "after the veto the result was back to 0")

test_case("modal/a form inside another form is refused")
inner@ = form@("Inner", 100, 60)
control_parent@(inner@, main@)
gui_clearerror()
assert_eq(form_showmodal(inner@), 0, "a parented form answers 0")
assert_eq(gui_error(), 1, "and records gui_error 1")

test_case("modal/a form the LCL cannot make modal is refused, not raised")
form_show@(main@)
gui_clearerror()
assert_eq(form_showmodal(main@), 0, "a form already shown answers 0")
assert_eq(gui_error(), 1, "and records gui_error 1")
third@ = form@("Disabled", 200, 100)
control_enabled@(third@, 0)
gui_clearerror()
assert_eq(form_showmodal(third@), 0, "a disabled form answers 0")
assert_eq(gui_error(), 1, "and records gui_error 1")
gui_clearerror()
assert_eq(form_showmodal(nm@), 0, "an edit is not a form: 0")
assert_eq(gui_error(), 1, "recorded")
end

function on_ok(s@)
  okclicks = okclicks + 1
  return 0
endfunction

function type_and_ok(f@)
  inside = 1
  edit_text@(nm@, "Ada")
  button_click@(ok@)
  return 0
endfunction

function press_cancel(f@)
  button_click@(cancel@)
  return 0
endfunction

function answer_yes(f@)
  form_modalresult@(f@, 6)
  return 0
endfunction

function plain_then_ok(f@)
  button_click@(plain@)
  assert_eq(form_modalresult(f@), 0, "inside: an ordinary button left the result 0")
  button_click@(ok@)
  return 0
endfunction

function open_second(f@)
  inner = form_showmodal(second@)
  button_click@(ok@)
  return 0
endfunction

function press_yes(f@)
  button_click@(yes@)
  return 0
endfunction

function look_inside(f@)
  seenvisible = form_visible(f@)
  gui_clearerror()
  again = form_showmodal(f@)
  againerr = gui_error()
  button_click@(ok@)
  return 0
endfunction

function close_it(f@)
  form_close@(f@)
  return 0
endfunction

function may_close?(f@)
  queries = queries + 1
  return allow?
endfunction

function on_vclose(f@)
  closes = closes + 1
  return 0
endfunction

function press_vok(f@)
  button_click@(vok@)
  return 0
endfunction

function allow_and_press_vok(f@)
  afterveto = form_modalresult(f@)
  allow? = true
  button_click@(vok@)
  return 0
endfunction

function try_free(f@)
  gui_clearerror()
  freed = control_free(f@)
  freeerr = gui_error()
  button_click@(ok@)
  return 0
endfunction
