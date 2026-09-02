rem ---------------------------------------------------------------
rem HandleRegistry: the rules that let a GUI library validate a BASIC
rem pointer WITHOUT dereferencing it.
rem
rem The language lets a program fabricate a pointer with pointer@(n).
rem The old validation was "TObject(P) is TBasXxx" inside try/except,
rem which follows whatever address it is given: recoverable on Windows,
rem a hard crash on Android and Linux. These tests use the throwaway
rem probe classes in TestLib, because the real GUI libraries need a form
rem and a message loop and cannot run headless.
rem ---------------------------------------------------------------

test_case("registry/fabricated-pointer")
rem The central property: an address the program invented is never a handle.
junk@ = pointer@(1)
assert_eq(probe_is_handle(junk@), 0, "arbitrary address is not a handle")
assert_eq(probe_is_a(junk@), 0, "and is not an instance of any class")

junk2@ = pointer@(305419896)
assert_eq(probe_is_handle(junk2@), 0, "a large arbitrary address either")

test_case("registry/nil")
nil@ = pointer@(0)
assert_eq(probe_is_handle(nil@), 0, "nil is not a handle")
assert_eq(probe_is_a(nil@), 0, "nil is not an instance")

test_case("registry/registered-object")
a@ = probe_new_a@()
assert_eq(probe_is_handle(a@), 1, "a live object is a handle")
assert_eq(probe_is_a(a@), 1, "and reports its own class")

test_case("registry/class-discrimination")
rem A valid handle of the wrong class must be rejected: this is what stops
rem label_text@(aButton@) from writing through the wrong vtable.
b@ = probe_new_b@()
assert_eq(probe_is_b(b@), 1, "B is a B")
assert_eq(probe_is_a(b@), 0, "B is not an A")
assert_eq(probe_is_b(a@), 0, "A is not a B")

test_case("registry/free-revokes-the-handle")
assert_eq(probe_free(a@), 1, "freeing a live handle succeeds")
assert_eq(probe_is_handle(a@), 0, "the pointer stops being a handle")
assert_eq(probe_is_a(a@), 0, "and stops matching its class")

rem Using the stale pointer again must be refused, not followed.
assert_eq(probe_free(a@), 0, "freeing a stale handle is refused")

test_case("registry/accounting")
before = probe_count()
c@ = probe_new_a@()
d@ = probe_new_a@()
assert_eq(probe_count(), before + 2, "two registrations")
probe_free(c@)
probe_free(d@)
assert_eq(probe_count(), before, "back to the starting count")
probe_free(b@)
