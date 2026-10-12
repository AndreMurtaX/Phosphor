rem ---------------------------------------------------------------
rem A NODE OR ITEM FREED INSIDE A HANDLER, AND WHAT DIES AROUND IT.
rem
rem Since 2026-10-12 a node or item handle no longer asks its tree view
rem or list view for a free notification of its own: the holder owns
rem one watch, every reference into it is linked on that watch's list,
rem and the holder's death drops the list (PhosphorGuiCore,
rem TGuiHolderWatch). 22_node_lifetime.bas pins the deaths at depth 0
rem and 35_free_cost.bas what a free walks. This file crosses the two
rem lifetimes the watch carries: a free inside a handler is DEFERRED --
rem dead to the program at once, its memory held by a registry entry
rem no program can name until the dispatch unwinds -- so each case
rem below crosses that held entry with a second death that must reach
rem it too: its parent node, its tree, its list, its form, and the
rem end of the program. A menu item freed in a handler rides along:
rem the item under it is owned by the menu, not by it, and the
rem control-side walk (ForgetDying) must still find it.
rem
rem Every expected value is the documented contract of control_free
rem (docs/libraries/gui-control.md): 1 for a free, 0 with gui_error()
rem 1 for a handle already dead. A node count is the arithmetic of the
rem nodes each case made and freed, written beside it. A held entry
rem that missed a death is freed TWICE when the dispatch unwinds, and
rem phosphorguitest's heap poisons a freed block, so that is a crash,
rem not a quiet pass.
rem ---------------------------------------------------------------

mode = 0
ans1 = -1
ans2 = -1
err2 = -1
cap$ = "?"

f@ = form@("watch", 300, 200)
b@ = button@(f@)
button_onclick@(b@, "on_click")

function on_click(sender@)
  ans1 = -1
  ans2 = -1
  err2 = -1
  cap$ = "?"
  gui_clearerror()
  if mode = 1 then
    rem the child first, then the parent that holds it
    ans1 = control_free(ch@)
    ans2 = control_free(par@)
    err2 = gui_error()
  end if
  if mode = 2 then
    rem the parent first: the child's handle is already dead
    ans1 = control_free(par@)
    ans2 = control_free(ch@)
    err2 = gui_error()
  end if
  if mode = 3 then
    rem a node, then the tree that holds it
    ans1 = control_free(ch@)
    ans2 = control_free(tv@)
    err2 = gui_error()
    gui_clearerror()
    cap$ = treenode_caption$(par@)
  end if
  if mode = 4 then
    rem a node, then the form that owns its tree
    ans1 = control_free(ch@)
    ans2 = control_free(g@)
    err2 = gui_error()
  end if
  if mode = 5 then
    rem an item, then the list that holds it
    ans1 = control_free(it@)
    ans2 = control_free(lv@)
    err2 = gui_error()
    gui_clearerror()
    cap$ = listitem_caption$(it2@)
  end if
  if mode = 6 then
    rem the tree first: its node's handle is already dead
    ans1 = control_free(tv@)
    ans2 = control_free(ch@)
    err2 = gui_error()
  end if
  if mode = 8 then
    rem a menu item: the item under it is owned by the MENU, so only the
    rem item above it says it dies (ForgetDying walks Items as well as
    rem what a component owns)
    ans1 = control_free(mtop@)
    cap$ = menuitem_caption$(msub@)
    err2 = gui_error()
  end if
  if mode = 7 then
    rem freed here and still held when the program ends
    ans1 = control_free(ch@)
  end if
  return 0
end function

test_case("watch/a child freed in a handler, then its parent")
tv@ = treeview@(f@)
par@ = treenode@(tv@, "parent")
ch@ = treenode@(par@, "child")
gc@ = treenode@(ch@, "grandchild")
s@ = treenode@(tv@, "sibling")
mode = 1
button_click@(b@)
assert_eq(ans1, 1, "the child is freed")
assert_eq(ans2, 1, "and then its parent")
assert_eq(err2, 0, "with no error")
rem 4 made; parent, child and grandchild go: 4 - 3 = 1
assert_eq(treeview_nodecount(tv@), 1, "the sibling alone is left once the handler is over")
gui_clearerror()
assert_eq(treenode_caption$(gc@), "", "the grandchild's handle answers nothing")
assert_true(gui_error(), "and is refused")
gui_clearerror()
assert_eq(treenode_caption$(s@), "sibling", "the sibling is untouched")
assert_eq(gui_error(), 0, "and records no error")
x = control_free(tv@)

test_case("watch/a parent freed in a handler takes the child's handle at once")
tv@ = treeview@(f@)
par@ = treenode@(tv@, "parent")
ch@ = treenode@(par@, "child")
mode = 2
button_click@(b@)
assert_eq(ans1, 1, "the parent is freed")
assert_eq(ans2, 0, "the child's handle was already dead in the handler")
assert_eq(err2, 1, "and says so")
assert_eq(treeview_nodecount(tv@), 0, "both are gone once the handler is over")
x = control_free(tv@)

test_case("watch/a node freed in a handler, then its tree")
tv@ = treeview@(f@)
par@ = treenode@(tv@, "parent")
ch@ = treenode@(par@, "child")
mode = 3
button_click@(b@)
assert_eq(ans1, 1, "the node is freed")
assert_eq(ans2, 1, "and then its tree")
assert_eq(err2, 0, "with no error")
assert_eq(cap$, "", "the tree's other node was dead in the handler")
gui_clearerror()
assert_eq(control_free(par@), 0, "and cannot be freed after it")
assert_true(gui_error(), "and says so")

test_case("watch/a node freed in a handler, then the form that owns its tree")
g@ = form@("owner", 200, 100)
tv@ = treeview@(g@)
par@ = treenode@(tv@, "parent")
ch@ = treenode@(par@, "child")
mode = 4
button_click@(b@)
assert_eq(ans1, 1, "the node is freed")
assert_eq(ans2, 1, "and then the form")
assert_eq(err2, 0, "with no error")
gui_clearerror()
assert_eq(treenode_caption$(par@), "", "the tree's other node answers nothing")
assert_true(gui_error(), "and is refused")

test_case("watch/an item freed in a handler, then its list")
lv@ = listview@(f@)
it@ = listitem@(lv@, "one")
it2@ = listitem@(lv@, "two")
mode = 5
button_click@(b@)
assert_eq(ans1, 1, "the item is freed")
assert_eq(ans2, 1, "and then its list")
assert_eq(err2, 0, "with no error")
assert_eq(cap$, "", "the list's other item was dead in the handler")
gui_clearerror()
assert_eq(control_free(it2@), 0, "and cannot be freed after it")
assert_true(gui_error(), "and says so")

test_case("watch/a tree freed in a handler takes its node's handle at once")
tv@ = treeview@(f@)
ch@ = treenode@(tv@, "node")
mode = 6
button_click@(b@)
assert_eq(ans1, 1, "the tree is freed")
assert_eq(ans2, 0, "its node's handle was already dead in the handler")
assert_eq(err2, 1, "and says so")

test_case("watch/a node handle outlives its tree's handle")
rem The tree's handle is freed with control_free's own order -- the
rem handle's object is nil'd BEFORE the tree is destroyed -- and the
rem node handle, made after it, is the one asked last.
tv@ = treeview@(f@)
par@ = treenode@(tv@, "parent")
assert_eq(control_free(tv@), 1, "the tree is freed")
gui_clearerror()
assert_eq(treenode_childcount(par@), 0, "its node answers 0")
assert_true(gui_error(), "and is refused")

test_case("watch/a menu item freed in a handler takes the item under it at once")
mm@ = mainmenu@(f@)
mtop@ = menuitem@(mm@, "File")
msub@ = menuitem@(mtop@, "Open")
mode = 8
button_click@(b@)
assert_eq(ans1, 1, "the item is freed")
assert_eq(cap$, "", "the item under it was dead in the handler")
assert_eq(err2, 1, "and was refused")
gui_clearerror()
assert_eq(control_free(msub@), 0, "and cannot be freed after it")
assert_true(gui_error(), "and says so")

test_case("watch/a node freed in a handler is still held when the program ends")
rem Nothing at depth 0 runs after this click, so the held entry, the
rem node handles beside it, the tree and the form are all released by
rem the registry's own teardown, one handle at a time in the order they
rem were made: the form first, which takes the tree and so the watch.
tv@ = treeview@(f@)
par@ = treenode@(tv@, "parent")
ch@ = treenode@(par@, "child")
other@ = treenode@(tv@, "other")
lv@ = listview@(f@)
it@ = listitem@(lv@, "row")
mode = 7
button_click@(b@)
assert_eq(ans1, 1, "the node is freed")
