rem ---------------------------------------------------------------
rem GUI smoke test: build a form and a button and round-trip their
rem properties. Nothing is displayed -- the controls are constructed
rem headless and freed with the handle registry at the end of the run.
rem
rem Adapted from Plan9Basic tests/gui/00_smoke to Phosphor conventions:
rem the handle suffix is '@' (not '#'), a setter returns the handle, and
rem the button's text property is its LCL name, caption.
rem ---------------------------------------------------------------

test_case("gui/form")
f@ = form@()
assert_eq(gui_error(), 0, "form@ built a form with no error")
form_caption@(f@, "test caption")
assert_eq(form_caption$(f@), "test caption", "caption round trip")
form_width@(f@, 800)
assert_eq(form_width(f@), 800, "width round trip")
form_height@(f@, 600)
assert_eq(form_height(f@), 600, "height round trip")

test_case("gui/form-with-arguments")
g@ = form@("titled", 320, 240)
assert_eq(form_caption$(g@), "titled", "the constructor took a caption")
assert_eq(form_width(g@), 320, "and a width")
assert_eq(form_height(g@), 240, "and a height")

test_case("gui/button")
b@ = button@(f@)
assert_eq(gui_error(), 0, "button@ built a button on the form")
button_caption@(b@, "click")
assert_eq(button_caption$(b@), "click", "caption round trip")
