rem ---------------------------------------------------------------
rem A tree view of nodes and a report list view of items. Nodes and
rem items are handles too (they ride on the generalized handle
rem registry). Headless.
rem ---------------------------------------------------------------

test_case("tree/nodes and children")
f@ = form@("host", 500, 400)
tv@ = treeview@(f@)
root@ = treenode@(tv@, "root")
assert_eq(gui_error(), 0, "a root node was added")
assert_eq(treenode_caption$(root@), "root", "its caption")
c1@ = treenode@(root@, "child one")
c2@ = treenode@(root@, "child two")
assert_eq(treenode_childcount(root@), 2, "the root has two children")
assert_eq(treeview_nodecount(tv@), 3, "three nodes in all")
treenode_caption@(c1@, "renamed")
assert_eq(treenode_caption$(c1@), "renamed", "a node caption round trips")

test_case("list/columns, items and subitems")
lv@ = listview@(f@)
listview_addcolumn@(lv@, "name")
listview_addcolumn@(lv@, "size")
it@ = listitem@(lv@, "file.txt")
listitem_subitem@(it@, "1 KB")
assert_eq(gui_error(), 0, "a column and an item were added")
assert_eq(listview_itemcount(lv@), 1, "one item")
assert_eq(listitem_caption$(it@), "file.txt", "item caption")
assert_eq(listitem_subitem$(it@, 1), "1 KB", "the first subitem, 1-based")
it2@ = listitem@(lv@, "other.txt")
assert_eq(listview_itemcount(lv@), 2, "a second item")
