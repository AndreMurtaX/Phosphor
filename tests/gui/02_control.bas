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

test_case("control/a SET property round-trips by its identifiers")
rem gui-components.md:134 tells the reader anchors are part of the exposed layout
rem model. Anchors is tkSet, and the string form -- the very shape that works one
rem line above for the ENUM Align -- used to fall through to SetOrdProp(.., 0) and
rem write the EMPTY set: measured 7 before the call, 0 after, gui_error still 0. It
rem destroyed live state and reported success, which is worse than an error because
rem nothing looks wrong. akLeft is 2 and akRight is 4, so the set is 6.
gui_clearerror()
control_set@(b@, "Anchors", "akLeft,akRight")
assert_eq(gui_error(), 0, "setting a set by identifiers is not an error")
assert_eq(control_get(b@, "Anchors"), 6, "akLeft + akRight, not the empty set")
assert_eq(control_get$(b@, "Anchors"), "akLeft,akRight", "and it reads back in the form it went in")

test_case("control/a string into a plain ordinal is refused, not written as zero")
rem Any string reaching a non-string, non-enum, non-set property became
rem Round(ArgNum(s)) = 0 and was written in silence. Tag is an ordinary integer.
control_set@(b@, "Tag", 42)
gui_clearerror()
control_set@(b@, "Tag", "not a number")
assert_true(gui_error(), "the mistake is recorded")
assert_eq(control_get(b@, "Tag"), 42, "and the old value is still there")

test_case("control/both halves of the bridge agree about an unreadable kind")
rem Constraints is class-typed. Writing it recorded ERR_NO_PROPERTY; READING it
rem answered 0 with gui_error 0 -- indistinguishable from a property whose value is
rem really zero. The setter and the getter now say the same thing about the same
rem situation.
gui_clearerror()
control_set@(b@, "Constraints", 5)
seterr% = gui_error()
gui_clearerror()
control_get(b@, "Constraints")
geterr% = gui_error()
assert_true(seterr%, "the setter records it")
assert_true(geterr%, "and so does the getter")
assert_eq(geterr%, seterr%, "with the same code")
gui_clearerror()
control_get$(b@, "Constraints")
assert_true(gui_error(), "the string getter too")

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
