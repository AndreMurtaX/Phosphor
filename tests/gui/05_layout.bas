rem ---------------------------------------------------------------
rem Containers hold other controls; range controls hold a value.
rem A child built on a container handle is a valid control, and the
rem page control's active page is 1-based. Headless.
rem ---------------------------------------------------------------

test_case("layout/panel holds a child")
f@ = form@("host", 500, 400)
p@ = panel@(f@)
panel_caption@(p@, "group")
assert_eq(panel_caption$(p@), "group", "panel caption round trip")
b@ = button@(p@)
button_caption@(b@, "inside")
assert_eq(gui_error(), 0, "a button built on the panel is valid")
assert_eq(button_caption$(b@), "inside", "and works")

test_case("layout/groupbox and scrollbox")
g@ = groupbox@(f@)
groupbox_caption@(g@, "options")
assert_eq(groupbox_caption$(g@), "options", "groupbox caption")
sb@ = scrollbox@(f@)
e@ = edit@(sb@)
assert_eq(gui_error(), 0, "an edit built inside a scrollbox is valid")

test_case("layout/page control tabs")
pc@ = pagecontrol@(f@)
t1@ = tabsheet@(pc@, "first")
t2@ = tabsheet@(pc@, "second")
assert_eq(pagecontrol_pagecount(pc@), 2, "two tabs added")
assert_eq(tabsheet_caption$(t1@), "first", "the first tab caption")
pagecontrol_pageindex@(pc@, 2)
assert_eq(pagecontrol_pageindex(pc@), 2, "the active page is 1-based")
btn@ = button@(t1@)
assert_eq(gui_error(), 0, "a control lives on a tab sheet")

test_case("range/trackbar")
tb@ = trackbar@(f@)
trackbar_min@(tb@, 0)
trackbar_max@(tb@, 100)
trackbar_position@(tb@, 40)
assert_eq(trackbar_position(tb@), 40, "position round trip")
assert_eq(trackbar_max(tb@), 100, "max round trip")

test_case("range/progressbar and scrollbar")
prog@ = progressbar@(f@)
progressbar_max@(prog@, 50)
progressbar_position@(prog@, 25)
assert_eq(progressbar_position(prog@), 25, "progress position round trip")
scr@ = scrollbar@(f@)
scrollbar_max@(scr@, 200)
scrollbar_position@(scr@, 80)
assert_eq(scrollbar_position(scr@), 80, "scrollbar position round trip")
