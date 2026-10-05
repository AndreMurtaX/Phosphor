rem ---------------------------------------------------------------
rem A NODE OR AN ITEM DIES WITH WHAT OWNS IT, AND ITS HANDLE SAYS SO.
rem
rem Tree nodes and list items are not components, so the LCL cannot
rem tell a handle when one dies, and until 2026-10-05 nothing else did
rem either. Free the tree, and every node handle still pointed at freed
rem memory: reading one dereferenced it (ledger d10), and freeing one
rem called Free on memory already freed -- a DOUBLE FREE (ledger n20),
rem which on Windows passes quietly and corrupts the heap for whatever
rem runs next. Every case below asks for the answer this package already
rem gives a dead CONTROL (02_control.bas): "" or 0, with gui_error() 1,
rem never a dereference.
rem
rem The deaths covered are every one this package can cause: the tree
rem or list freed directly, the form that owns them freed, a node freed
rem with a subtree under it, and a node or item freed on its own.
rem ---------------------------------------------------------------

f@ = form@("nodes", 300, 200)

test_case("node/freeing the tree invalidates every node handle")
tv@ = treeview@(f@)
n@ = treenode@(tv@, "root")
c@ = treenode@(n@, "child")
assert_eq(treenode_caption$(c@), "child", "the child answers while the tree stands")
assert_eq(control_free(tv@), 1, "the tree is freed on request")
gui_clearerror()
dead$ = treenode_caption$(n@)
assert_eq(dead$, "", "a root of the freed tree answers nothing")
assert_true(gui_error(), "and is refused, not dereferenced")
gui_clearerror()
assert_eq(treenode_childcount(c@), 0, "a child of the freed tree answers 0")
assert_true(gui_error(), "and is refused too")
gui_clearerror()
rem THE DOUBLE FREE. Before the repair this answered 1 and called Free on a
rem node the tree had already destroyed.
assert_eq(control_free(n@), 0, "freeing a node of a freed tree is refused")
assert_true(gui_error(), "and records an error")

test_case("node/freeing a node invalidates its whole subtree, and only that")
tv2@ = treeview@(f@)
p@ = treenode@(tv2@, "parent")
ch@ = treenode@(p@, "child")
gc@ = treenode@(ch@, "grandchild")
s@ = treenode@(tv2@, "sibling")
assert_eq(treeview_nodecount(tv2@), 4, "four nodes before")
assert_eq(control_free(p@), 1, "the parent is freed on request")
assert_eq(treeview_nodecount(tv2@), 1, "it took its child and grandchild with it")
gui_clearerror()
assert_eq(treenode_caption$(ch@), "", "the child's handle answers nothing")
assert_true(gui_error(), "and is refused")
gui_clearerror()
assert_eq(control_free(gc@), 0, "the grandchild cannot be freed a second time")
assert_true(gui_error(), "and says so")
gui_clearerror()
assert_eq(treenode_caption$(s@), "sibling", "the sibling outside the subtree is untouched")
assert_eq(gui_error(), 0, "and records no error")

test_case("node/a node freed directly is refused the second time")
tv3@ = treeview@(f@)
one@ = treenode@(tv3@, "one")
assert_eq(control_free(one@), 1, "the first free succeeds")
gui_clearerror()
assert_eq(control_free(one@), 0, "a second free is rejected")
assert_true(gui_error(), "and records an error")

test_case("item/freeing the list invalidates every item handle")
lv@ = listview@(f@)
it@ = listitem@(lv@, "row")
listitem_subitem@(it@, "cell")
assert_eq(listitem_caption$(it@), "row", "the item answers while the list stands")
assert_eq(control_free(lv@), 1, "the list is freed on request")
gui_clearerror()
assert_eq(listitem_caption$(it@), "", "its item answers nothing")
assert_true(gui_error(), "and is refused")
gui_clearerror()
assert_eq(listitem_subitem$(it@, 1), "", "its subitem answers nothing")
assert_true(gui_error(), "and is refused")
gui_clearerror()
assert_eq(control_free(it@), 0, "freeing an item of a freed list is refused")
assert_true(gui_error(), "and records an error")

test_case("item/an item freed directly leaves the list and is refused after")
lv2@ = listview@(f@)
a@ = listitem@(lv2@, "a")
b@ = listitem@(lv2@, "b")
assert_eq(control_free(a@), 1, "the item is freed on request")
assert_eq(listview_itemcount(lv2@), 1, "the list has one item left")
gui_clearerror()
assert_eq(listitem_caption$(b@), "b", "its neighbour is untouched")
assert_eq(gui_error(), 0, "and records no error")
gui_clearerror()
assert_eq(control_free(a@), 0, "a second free is rejected")
assert_true(gui_error(), "and records an error")

test_case("node/the form that owns the tree takes the nodes with it")
f2@ = form@("owner", 200, 100)
tv4@ = treeview@(f2@)
deep@ = treenode@(tv4@, "deep")
lv4@ = listview@(f2@)
row@ = listitem@(lv4@, "row")
assert_eq(control_free(f2@), 1, "the form is freed on request")
gui_clearerror()
assert_eq(treenode_caption$(deep@), "", "a node two owners down answers nothing")
assert_true(gui_error(), "and is refused")
gui_clearerror()
assert_eq(listitem_caption$(row@), "", "an item two owners down answers nothing")
assert_true(gui_error(), "and is refused")
gui_clearerror()
assert_eq(control_free(deep@), 0, "and cannot be freed again")
assert_true(gui_error(), "and says so")

control_free(f@)
