rem ---------------------------------------------------------------
rem GUI events reach their BASIC handlers, and the handle registry
rem rejects a fabricated or wrong-class handle -- all headless, with no
rem window shown and no message loop. button_click fires the click
rem synchronously, and the handler runs through the engine's host-
rem callback seam (the same CallUserFunc that 48_callback proved).
rem ---------------------------------------------------------------

clicks = 0

test_case("events/a click reaches its handler")
f@ = form@()
b@ = button@(f@)
button_onclick@(b@, "on_click")
assert_eq(gui_error(), 0, "binding the event recorded no error")
button_click@(b@)
button_click@(b@)
assert_eq(clicks, 2, "two clicks ran the handler twice")

test_case("events/the handler is handed the sender it fired on")
rem on_click writes a caption THROUGH the sender handle it was given; if
rem that changed this very button, the sender is b@ -- a live handle, not
rem a copy.
assert_eq(button_caption$(b@), "was clicked", "the handler mutated the button it was handed")

test_case("events/clearing the name unwires it")
button_onclick@(b@, "")
clicks = 0
button_click@(b@)
assert_eq(clicks, 0, "an empty name stops the event")

test_case("events/handle validation")
gui_clearerror()
junk@ = pointer@(305419896)
r$ = button_caption$(junk@)
assert_true(gui_error(), "a fabricated handle is rejected")
assert_eq(r$, "", "and returns no content")

gui_clearerror()
r2$ = button_caption$(f@)
assert_true(gui_error(), "a form is not a button")

gui_clearerror()
button_caption@(b@, "ok")
assert_eq(gui_error(), 0, "the good path records no error")

function on_click(sender@)
  clicks = clicks + 1
  button_caption@(sender@, "was clicked")
  return 0
endfunction
