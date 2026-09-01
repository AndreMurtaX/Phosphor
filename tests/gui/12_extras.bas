rem ---------------------------------------------------------------
rem The remaining optional controls: splitter, bevel, up/down, tool bar,
rem status bar, calendar, colour button. Headless.
rem ---------------------------------------------------------------

test_case("extras/splitter and bevel")
f@ = form@("host", 500, 400)
sp@ = splitter@(f@)
assert_eq(gui_error(), 0, "splitter@ built one")
bv@ = bevel@(f@)
bevel_shape@(bv@, 2)
assert_eq(bevel_shape(bv@), 2, "bevel shape round trip")
bevel_style@(bv@, 1)
assert_eq(bevel_style(bv@), 1, "bevel style round trip")

test_case("extras/up-down")
ud@ = updown@(f@)
updown_min@(ud@, 0)
updown_max@(ud@, 10)
updown_position@(ud@, 7)
assert_eq(updown_position(ud@), 7, "up/down position round trip")

test_case("extras/tool bar and status bar")
tb@ = toolbar@(f@)
assert_eq(gui_error(), 0, "toolbar@ built one")
b@ = button@(tb@)
assert_eq(gui_error(), 0, "a button lives on the tool bar")
sb@ = statusbar@(f@)
statusbar_text@(sb@, "Ready")
assert_eq(statusbar_text$(sb@), "Ready", "status bar text round trip")

test_case("extras/calendar")
cal@ = calendar@(f@)
rem 45351 is 2024-02-29 as a date serial (locale-independent)
calendar_date@(cal@, 45351)
assert_near(calendar_date(cal@), 45351, 0.5, "calendar date round trip")

test_case("extras/colour button")
cb@ = colorbutton@(f@)
colorbutton_color@(cb@, 255)
assert_eq(colorbutton_color(cb@), 255, "colour button colour round trip")
