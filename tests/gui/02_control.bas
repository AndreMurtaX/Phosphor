rem ---------------------------------------------------------------
rem The shared control surface (PhosphorControlLib): geometry, state,
rem font and verbs that every control inherits, plus the generic
rem property bridge that reaches any published property by name through
rem RTTI. Exercised on a form and a button, headless. Adapts the shape
rem of the reference's 08_property_roundtrip and 10_geometry.
rem ---------------------------------------------------------------

f@ = form@("host", 400, 300)
b@ = button@(f@)

test_case("control/geometry helpers")
control_move@(b@, 10, 20)
assert_eq(control_left(b@), 10, "move set left")
assert_eq(control_top(b@), 20, "move set top")
control_size@(b@, 120, 32)
assert_eq(control_width(b@), 120, "size set width")
assert_eq(control_height(b@), 32, "size set height")
control_bounds@(b@, 5, 6, 100, 24)
assert_eq(control_left(b@), 5, "bounds set left")
assert_eq(control_width(b@), 100, "bounds set width")

test_case("control/state helpers")
control_enabled@(b@, 0)
assert_eq(control_enabled(b@), 0, "disabled")
control_enabled@(b@, 1)
assert_eq(control_enabled(b@), 1, "re-enabled")
control_hint@(b@, "press me")
assert_eq(control_hint$(b@), "press me", "hint round trip")
control_tag@(b@, 42)
assert_eq(control_tag(b@), 42, "tag round trip")

test_case("control/font helpers")
control_fontname@(b@, "Courier New")
assert_eq(control_fontname$(b@), "Courier New", "font name round trip")
control_fontsize@(b@, 14)
assert_eq(control_fontsize(b@), 14, "font size round trip")
control_bold@(b@, 1)
assert_eq(control_bold(b@), 1, "bold on")
control_bold@(b@, 0)
assert_eq(control_bold(b@), 0, "bold off")

test_case("control/color on the form")
control_color@(f@, 255)
assert_eq(control_color(f@), 255, "color round trip")

test_case("control/verbs run without error")
control_bringtofront@(b@)
control_sendtoback@(b@)
control_invalidate@(b@)
control_setfocus@(b@)
assert_eq(gui_error(), 0, "the geometry/paint verbs recorded no error")

test_case("control/generic property bridge")
rem Any published property, by name, with no hand-written helper.
control_set@(b@, "Caption", "Bridged")
assert_eq(control_get$(b@, "Caption"), "Bridged", "a string property through the bridge")
control_set@(b@, "Width", 77)
assert_eq(control_get(b@, "Width"), 77, "a numeric property through the bridge")
control_set@(b@, "Enabled", 0)
assert_eq(control_get(b@, "Enabled"), 0, "a boolean property through the bridge")
control_set@(b@, "Align", 5)
assert_eq(control_get$(b@, "Align"), "alClient", "an enum reads back as its name")

test_case("control/the bridge rejects an unknown property")
gui_clearerror()
control_get(b@, "NoSuchProperty")
assert_true(gui_error(), "an unknown property is recorded, not crashed")

test_case("control/free and double-free")
c2@ = button@(f@)
assert_eq(control_free(c2@), 1, "the first free succeeds")
gui_clearerror()
assert_eq(control_free(c2@), 0, "a second free is rejected")
assert_true(gui_error(), "and records an error")
