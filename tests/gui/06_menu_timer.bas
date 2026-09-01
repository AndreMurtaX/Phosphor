rem ---------------------------------------------------------------
rem Menus and a timer. A menu item chosen with menuitem_click@ fires its
rem OnClick synchronously, so a BASIC handler is reached headless. A timer
rem only ticks under a message loop, so only its configuration is checked.
rem ---------------------------------------------------------------

chosen = 0

test_case("menu/a menu bar with items")
f@ = form@("host", 400, 300)
mm@ = mainmenu@(f@)
mfile@ = menuitem@(mm@, "File")
mopen@ = menuitem@(mfile@, "Open")
assert_eq(gui_error(), 0, "a menu, a top item and a submenu item all built")
assert_eq(menuitem_caption$(mopen@), "Open", "the item caption")
menuitem_caption@(mopen@, "Open...")
assert_eq(menuitem_caption$(mopen@), "Open...", "caption round trip")

test_case("menu/choosing an item reaches its handler")
menuitem_onclick@(mopen@, "on_open")
menuitem_click@(mopen@)
assert_eq(chosen, 1, "menuitem_click ran the handler")
menuitem_click@(mopen@)
assert_eq(chosen, 2, "and again on a second choose")
menuitem_onclick@(mopen@, "")
menuitem_click@(mopen@)
assert_eq(chosen, 2, "an empty name unwired it")

test_case("timer/configuration")
t@ = timer@()
assert_eq(timer_enabled(t@), 0, "a timer starts disabled")
timer_interval@(t@, 250)
assert_eq(timer_interval(t@), 250, "interval round trip")
timer_start@(t@)
assert_eq(timer_enabled(t@), 1, "start enables it")
timer_stop@(t@)
assert_eq(timer_enabled(t@), 0, "stop disables it")

function on_open(sender@)
  chosen = chosen + 1
  return 0
endfunction
