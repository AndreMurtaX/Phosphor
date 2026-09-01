rem ---------------------------------------------------------------
rem Choice controls: check box, radio button, combo box, list box.
rem State round-trips, 1-based item/selection indices, and a check box's
rem onchange reaching a BASIC handler. Headless.
rem ---------------------------------------------------------------

changes = 0

test_case("choice/checkbox state")
f@ = form@("host", 400, 300)
cb@ = checkbox@(f@)
checkbox_caption@(cb@, "accept")
assert_eq(checkbox_caption$(cb@), "accept", "caption round trip")
checkbox_checked@(cb@, 1)
assert_eq(checkbox_checked(cb@), 1, "checked on")
checkbox_checked@(cb@, 0)
assert_eq(checkbox_checked(cb@), 0, "checked off")

test_case("choice/checkbox onchange")
checkbox_onchange@(cb@, "on_change")
checkbox_checked@(cb@, 1)
assert_eq(changes, 1, "toggling checked ran the handler")
checkbox_onchange@(cb@, "")
checkbox_checked@(cb@, 0)
assert_eq(changes, 1, "an empty name unwired it")

test_case("choice/radio button state")
r1@ = radiobutton@(f@)
r2@ = radiobutton@(f@)
radio_checked@(r1@, 1)
assert_eq(radio_checked(r1@), 1, "a radio button can be checked")
radio_caption@(r2@, "option two")
assert_eq(radio_caption$(r2@), "option two", "and carries a caption")

test_case("choice/combobox items are 1-based")
c@ = combobox@(f@)
combo_add@(c@, "red")
combo_add@(c@, "green")
combo_add@(c@, "blue")
assert_eq(combo_count(c@), 3, "three items")
assert_eq(combo_item$(c@, 2), "green", "the second item, 1-based")
combo_itemindex@(c@, 3)
assert_eq(combo_itemindex(c@), 3, "itemindex is 1-based")
combo_clear@(c@)
assert_eq(combo_count(c@), 0, "clear empties it")

test_case("choice/listbox")
lb@ = listbox@(f@)
list_add@(lb@, "one")
list_add@(lb@, "two")
assert_eq(list_count(lb@), 2, "two items")
assert_eq(list_item$(lb@, 1), "one", "first item, 1-based")
list_itemindex@(lb@, 2)
assert_eq(list_itemindex(lb@), 2, "selection is 1-based")
assert_eq(list_selected$(lb@), "two", "selected text follows the index")

function on_change(sender@)
  changes = changes + 1
  return 0
endfunction
