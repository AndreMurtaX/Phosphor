rem ---------------------------------------------------------------
rem A FREE INSIDE A HANDLER COSTS WHAT IT DESTROYS, NOT WHAT LIVES
rem (2026-10-11; docs/libraries/gui-control.md, control_free).
rem
rem A free asked for while a handler runs is deferred, and every handle
rem into what will die with the object is dropped AT ONCE (27_free_in_
rem handler). Until this date that drop asked EVERY live handle whether
rem it died with the object -- for a control (ForgetDying) and for a
rem tree node or list item (GuiForgetNodes) alike -- so freeing N
rem controls in one handler of a program holding H handles cost N*H.
rem Measured on the build before: 2000 button make+free pairs in one
rem click cost 99 ms with no other handle alive and 2122 ms beside
rem 100k dict handles; 2000 tree nodes, 41 ms and 2054 ms. Now the free
rem walks what dies -- the components the object owns, theirs in turn,
rem the items under a menu item, the nodes or items a dying tree or
rem list view holds -- and looks each one up in the object index.
rem
rem THE FIRST HALF pins WHAT is dropped, since walking a different set
rem than the old scan could leave a live handle on a dead object: every
rem handle into a freed form (through a panel, a popup menu it owns, a
rem tree, a list and a main menu), a node's subtree and not its
rem siblings, a list item alone, a 300-deep submenu, and a deferred free
rem whose owner is freed after it in the same handler. The expected
rem values are control_free's documented contract (gui-control.md): the
rem freed handle and every handle into what dies with it answer "" with
rem gui_error() 1 at once, inside the handler; what does not die still
rem answers. None was read off a run.
rem
rem THE SECOND HALF pins the COST, as a ratio measured inside this run:
rem the same make+free loop, beside no ballast and beside 100k dict
rem handles. A free that scans the registry pays ~20x there (the
rem numbers above); a free that walks what dies pays the same. The bar
rem is 4x plus 150 ms, so a slow machine slows both sides alike and a
rem scheduler hiccup does not read as a regression -- each side is the
rem best of its trials. And a deep submenu against a flat one of the
rem same size, which a walk that reaches a menu item through both its
rem menu parent and its owner pays quadratically. Each of the three was
rem watched failing: the two registry ratios on the build before this
rem change (5342 and 4630 ms held against 419 and 167 bare), the menu
rem one with that skip removed (653 ms deep, 1 ms flat).
rem ---------------------------------------------------------------

host@ = form@("host", 300, 200)
btn@ = button@(host@)
mode = 0
nfree = 0
kind$ = ""

function dead_btn(b@) local s$
  gui_clearerror()
  s$ = button_caption$(b@)
  return gui_error()
end function
function dead_node(n@) local s$
  gui_clearerror()
  s$ = treenode_caption$(n@)
  return gui_error()
end function
function dead_item(i@) local s$
  gui_clearerror()
  s$ = listitem_caption$(i@)
  return gui_error()
end function
function dead_mi(m@) local s$
  gui_clearerror()
  s$ = menuitem_caption$(m@)
  return gui_error()
end function

function on_click(s@) local i, b@, r
  if mode = 1 then
    rem A: the form, and everything it owns at every depth.
    assert_eq(control_free(f2@), 1, "A: the form is freed inside the handler")
    assert_eq(dead_btn(pb@), 1, "A: a button in a panel on it is dead at once")
    assert_eq(dead_node(n1@), 1, "A: a root node of its tree is dead")
    assert_eq(dead_node(n2@), 1, "A: and a child node")
    assert_eq(dead_item(it@), 1, "A: an item of its list view is dead")
    assert_eq(dead_mi(m1@), 1, "A: a main menu item is dead")
    assert_eq(dead_mi(m2@), 1, "A: and the submenu item under it")
    assert_eq(dead_mi(p1@), 1, "A: an item of a popup menu the panel owns is dead")
  end if
  if mode = 2 then
    rem B: a node and its subtree; then the whole tree.
    assert_eq(control_free(na@), 1, "B: a node is freed inside the handler")
    assert_eq(dead_node(na@), 1, "B: its handle is dead at once")
    assert_eq(dead_node(ng@), 1, "B: and its grandchild's")
    assert_eq(dead_node(nr@), 0, "B: its parent still answers")
    assert_eq(dead_node(nb@), 0, "B: and so does its sibling")
    assert_eq(dead_node(nc@), 0, "B: and the sibling's child")
    assert_eq(control_free(tv@), 1, "B: then the tree is freed in the same handler")
    assert_eq(dead_node(nr@), 1, "B: and the root is dead")
    assert_eq(dead_node(nc@), 1, "B: and the sibling's child")
  end if
  if mode = 3 then
    rem C: one list item, then the list.
    assert_eq(control_free(ia@), 1, "C: an item is freed inside the handler")
    assert_eq(dead_item(ia@), 1, "C: its handle is dead at once")
    assert_eq(dead_item(ib@), 0, "C: the other item still answers")
    assert_eq(control_free(lv@), 1, "C: then the list is freed")
    assert_eq(dead_item(ib@), 1, "C: and the other item is dead")
  end if
  if mode = 4 then
    rem D: a 300-deep submenu, freed from its top.
    assert_eq(control_free(top@), 1, "D: the top of a deep submenu is freed")
    assert_eq(dead_mi(mid@), 1, "D: an item halfway down is dead")
    assert_eq(dead_mi(deep@), 1, "D: and the deepest")
    assert_eq(dead_mi(other@), 0, "D: a sibling of the top still answers")
    assert_eq(control_free(mm@), 1, "D: then the whole main menu is freed")
    assert_eq(dead_mi(other@), 1, "D: and the sibling is dead")
  end if
  if mode = 5 then
    rem E: a deferred free, then its owner, then the owner's owner.
    assert_eq(control_free(eb@), 1, "E: a button is freed inside the handler")
    assert_eq(control_free(ep@), 1, "E: then the panel that owns it")
    assert_eq(dead_btn(eb2@), 1, "E: the panel's other button is dead")
    assert_eq(control_free(ef@), 1, "E: then the form that owns the panel")
  end if
  if mode = 6 then
    r = control_free(victim@)
  end if
  if mode = 9 then
    for i = 1 to nfree
      if kind$ = "button" then
        b@ = button@(cf@)
      else
        b@ = treenode@(ctv@, "n")
      end if
      r = control_free(b@)
    next
  end if
  return 0
end function
x@ = button_onclick@(btn@, "on_click")

test_case("free/a form freed in a handler takes every handle into it")
f2@ = form@("dies", 300, 200)
pan@ = panel@(f2@)
pb@ = button@(pan@)
pm@ = popupmenu@(pan@)
p1@ = menuitem@(pm@, "popup item")
tvf@ = treeview@(f2@)
n1@ = treenode@(tvf@, "root")
n2@ = treenode@(n1@, "child")
lvf@ = listview@(f2@)
it@ = listitem@(lvf@, "item")
mmf@ = mainmenu@(f2@)
m1@ = menuitem@(mmf@, "file")
m2@ = menuitem@(m1@, "open")
mode = 1
x@ = button_click@(btn@)
assert_eq(dead_btn(pb@), 1, "A: after the handler the button stays dead")
assert_eq(dead_node(n2@), 1, "A: and the child node")
assert_eq(dead_mi(p1@), 1, "A: and the popup item")
assert_eq(dead_btn(btn@), 0, "A: the handler's own button is untouched")

test_case("free/a node's subtree dies with it, its siblings do not")
tf@ = form@("tree", 300, 200)
tv@ = treeview@(tf@)
nr@ = treenode@(tv@, "root")
na@ = treenode@(nr@, "a")
ng@ = treenode@(na@, "grandchild")
nb@ = treenode@(nr@, "b")
nc@ = treenode@(nb@, "c")
mode = 2
x@ = button_click@(btn@)
assert_eq(dead_node(ng@), 1, "B: after the handler the grandchild stays dead")
assert_eq(dead_node(nb@), 1, "B: and the sibling, with its tree")
assert_eq(control_free(tf@), 1, "B: the form that held the tree is still alive to free")

test_case("free/a list item alone, then its list")
lf@ = form@("list", 300, 200)
lv@ = listview@(lf@)
ia@ = listitem@(lv@, "a")
ib@ = listitem@(lv@, "b")
mode = 3
x@ = button_click@(btn@)
assert_eq(dead_item(ia@), 1, "C: after the handler the item stays dead")
assert_eq(control_free(lf@), 1, "C: the form is still alive to free")

test_case("free/a deep submenu dies from its top")
mf@ = form@("menu", 300, 200)
mm@ = mainmenu@(mf@)
top@ = menuitem@(mm@, "top")
other@ = menuitem@(mm@, "other")
cur@ = top@
for i = 1 to 300
  cur@ = menuitem@(cur@, "level " + str$(i))
  if i = 150 then
    mid@ = cur@
  end if
next
deep@ = cur@
mode = 4
x@ = button_click@(btn@)
assert_eq(dead_mi(deep@), 1, "D: after the handler the deepest stays dead")
assert_eq(control_free(mf@), 1, "D: the form is still alive to free")

test_case("free/a deferred free, then what owns it, in one handler")
ef@ = form@("owners", 300, 200)
ep@ = panel@(ef@)
eb@ = button@(ep@)
eb2@ = button@(ep@)
mode = 5
x@ = button_click@(btn@)
assert_eq(dead_btn(eb@), 1, "E: after the handler the first button stays dead")
assert_eq(dead_btn(eb2@), 1, "E: and the second")
assert_eq(gui_test_pending(), 0, "E: and every deferred free has run")

test_case("free/the cost of a free does not grow with the live handles")
cf@ = form@("cost", 300, 200)
ctv@ = treeview@(cf@)
mode = 9
nfree = 4000

function cost(k$, trials) local t, best, t0
  kind$ = k$
  best = -1
  for t = 1 to trials
    t0 = now()
    x@ = button_click@(btn@)
    t0 =(now() - t0) * 86400000
    if best < 0 or t0 < best then
      best = t0
    end if
  next
  return best
end function

bare_b = cost("button", 3)
bare_n = cost("node", 3)
for i = 1 to 100000
  x@ = dict@()
next
held_b = cost("button", 2)
held_n = cost("node", 2)
assert_true(held_b <= 4 * bare_b + 150, "a button free beside 100k handles costs what it costs beside none (" + str$(int(bare_b)) + " ms bare, " + str$(int(held_b)) + " ms held)")
assert_true(held_n <= 4 * bare_n + 150, "and so does a node free (" + str$(int(bare_n)) + " ms bare, " + str$(int(held_n)) + " ms held)")

rem A DEEP SUBMENU COSTS WHAT A FLAT ONE DOES. A menu item dies with
rem its menu parent AND with its owner -- the menu, for every item --
rem so the walk reaches each item twice when both die, and a walk that
rem followed both would walk a D-deep chain D times over. Measured
rem with that skip removed: 6000 items freed with their menu, 1 ms
rem flat, ~600 ms as one chain. Same bar as above.
test_case("free/a deep submenu frees in the time a flat menu does")
victim@ = btn@
mode = 6

function menu_cost(deep, n) local mf@, mm@, cur@, i, t0, r
  mf@ = form@("menu cost", 300, 200)
  mm@ = mainmenu@(mf@)
  cur@ = menuitem@(mm@, "top")
  for i = 1 to n
    if deep = 1 then
      cur@ = menuitem@(cur@, "x")
    else
      x@ = menuitem@(mm@, "x")
    end if
  next
  victim@ = mm@
  t0 = now()
  x@ = button_click@(btn@)
  t0 = (now() - t0) * 86400000
  r = control_free(mf@)
  return t0
end function

flat_m = menu_cost(0, 6000)
deep_m = menu_cost(1, 6000)
assert_true(deep_m <= 4 * flat_m + 100, "a 6000-deep submenu frees as fast as 6000 flat items (" + str$(int(flat_m)) + " ms flat, " + str$(int(deep_m)) + " ms deep)")
