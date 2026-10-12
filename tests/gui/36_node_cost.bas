rem ---------------------------------------------------------------
rem A NODE HANDLE COSTS THE SAME IN A BIG TREE AS IN AN EMPTY ONE.
rem
rem Until 2026-10-12 every node or item handle -- and every deferred
rem free of one -- called FreeNotification on its tree view itself.
rem The RTL keeps those in a TFPList that it SCANS on every add and
rem every remove (rtl/objpas/classes/compon.inc: IndexOf before Add,
rem Remove on the way out), so the k-th handle into one tree cost O(k)
rem to make and O(k) to drop. 35_free_cost.bas pins that a free walks
rem what dies rather than every live handle; this file pins the other
rem half -- that neither making nor dropping a reference into a tree
rem grows with the tree. Now the tree view owns one watch, and each
rem reference is linked on its list in constant time.
rem
rem The bounds are RATIOS measured in this run, so they hold on any
rem machine: the same work is timed beside an empty tree and beside a
rem big one, each the best of three, and the big one may cost at most
rem three times the small one plus 30 ms for the clock's granularity.
rem The small runs go FIRST, before the big tree exists. Measured on
rem the build before: 199 ms against 19 for the adds and 238 against
rem 10 for the pairs, both far past the bound; on the fixed build, 11
rem against 11 and 6 against 6.
rem ---------------------------------------------------------------

SMALL = 5000
BIG = 60000
PAIRS = 2000

function add_nodes(n) local i, t0, x@
  t0 = now()
  for i = 1 to n
    x@ = treenode@(tv@, "n")
  next
  return millisecondsbetween(now(), t0)
end function

rem A node made and freed PAIRS times inside one click: each free is
rem deferred, so each pair links and unlinks a handle AND a deferred
rem free on the tree.
function pairs_click(sender@) local i, n@, x
  for i = 1 to PAIRS
    n@ = treenode@(tv@, "p")
    x = control_free(n@)
  next
  return 0
end function

function time_pairs(b@) local t0
  t0 = now()
  button_click@(b@)
  return millisecondsbetween(now(), t0)
end function

function least(a, b)
  if a < b then
    return a
  end if
  return b
end function

f@ = form@("pairs", 300, 200)
b@ = button@(f@)
button_onclick@(b@, "pairs_click")

pr_small = 1e9
for r = 1 to 3
  tv@ = treeview@(f@)
  pr_small = least(pr_small, time_pairs(b@))
  x = control_free(tv@)
next
mk_small = 1e9
for r = 1 to 3
  tv@ = treeview@(f@)
  mk_small = least(mk_small, add_nodes(SMALL))
  x = control_free(tv@)
next
tv@ = treeview@(f@)
x = add_nodes(BIG)

test_case("cost/making a node handle does not grow with the tree")
mk_big = 1e9
for r = 1 to 3
  mk_big = least(mk_big, add_nodes(SMALL))
next
rem BIG, then SMALL three times
assert_eq(treeview_nodecount(tv@), BIG + 3 * SMALL, "the tree holds every node made")
assert_true(mk_big <= 3 * mk_small + 30, "beside " + str$(BIG) + " nodes: " + str$(mk_big) + " ms, beside none: " + str$(mk_small) + " ms")

test_case("cost/a node made and freed in a handler does not grow with the tree")
pr_big = 1e9
for r = 1 to 3
  pr_big = least(pr_big, time_pairs(b@))
next
assert_eq(treeview_nodecount(tv@), BIG + 3 * SMALL, "every pair left the tree as it was")
assert_true(pr_big <= 3 * pr_small + 30, "beside " + str$(BIG + 3 * SMALL) + " nodes: " + str$(pr_big) + " ms, beside none: " + str$(pr_small) + " ms")
