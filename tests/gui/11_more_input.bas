rem ---------------------------------------------------------------
rem The optional controls added to the existing families: static text,
rem spin and float-spin edits, mask edit, toggle box, check list box,
rem bitmap button, speed button. Headless.
rem ---------------------------------------------------------------

hits = 0

test_case("more/static text")
f@ = form@("host", 500, 520)
st@ = statictext@(f@, "read only")
assert_eq(statictext_caption$(st@), "read only", "statictext caption")
statictext_caption@(st@, "changed")
assert_eq(statictext_caption$(st@), "changed", "round trip")

test_case("more/spin edit")
sp@ = spinedit@(f@)
spinedit_min@(sp@, 0)
spinedit_max@(sp@, 100)
spinedit_value@(sp@, 42)
assert_eq(spinedit_value(sp@), 42, "spin value round trip")

test_case("more/float spin edit")
fs@ = floatspinedit@(f@)
floatspinedit_decimals@(fs@, 2)
floatspinedit_value@(fs@, 3.14)
assert_near(floatspinedit_value(fs@), 3.14, 0.001, "float spin value round trip")

test_case("more/mask edit")
me@ = maskedit@(f@)
maskedit_mask@(me@, "00/00/0000")
assert_eq(maskedit_mask$(me@), "00/00/0000", "mask round trip")

test_case("more/toggle box")
tg@ = togglebox@(f@)
togglebox_caption@(tg@, "toggle")
assert_eq(togglebox_caption$(tg@), "toggle", "togglebox caption")
togglebox_checked@(tg@, 1)
assert_eq(togglebox_checked(tg@), 1, "checked on")

test_case("more/check list box")
cl@ = checklistbox@(f@)
checklist_add@(cl@, "apples")
checklist_add@(cl@, "pears")
checklist_add@(cl@, "plums")
assert_eq(checklist_count(cl@), 3, "three items")
assert_eq(checklist_item$(cl@, 2), "pears", "the second item, 1-based")
checklist_checked@(cl@, 2, 1)
assert_eq(checklist_checked(cl@, 2), 1, "the second item is checked")
assert_eq(checklist_checked(cl@, 1), 0, "and the first is not")

test_case("more/bitmap and speed buttons")
bb@ = bitbtn@(f@)
bitbtn_caption@(bb@, "OK")
bitbtn_onclick@(bb@, "on_hit")
bitbtn_click@(bb@)
assert_eq(hits, 1, "the bitbtn click reached the handler")
sd@ = speedbutton@(f@)
speedbutton_groupindex@(sd@, 1)
speedbutton_down@(sd@, 1)
assert_eq(speedbutton_down(sd@), 1, "speedbutton down state round trip")

function on_hit(sender@)
  hits = hits + 1
  return 0
endfunction
