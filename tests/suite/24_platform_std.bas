rem ---------------------------------------------------------------
rem PlatformInfoLib and the untested half of StdLib.
rem check-coverage.py reported PlatformInfoLib 0/9 and StdLib 5/14.
rem
rem The platform answers differ per machine, so what is asserted here
rem is the shape of the answer, not its value. A suite that expects
rem "Windows" fails honestly on Linux and tells you nothing.
rem ---------------------------------------------------------------

test_case("platform/names")
assert_true(len(os_name$()), "os_name$ answers something")
assert_true(len(os_platform$()), "os_platform$ answers something")
assert_true(len(os_architecture$()), "os_architecture$ answers something")

test_case("platform/version")
rem Every supported platform reports a major version of at least one.
assert_true(os_major(), "os_major is not zero")
if os_minor() >= 0 then minor_ok = 1
assert_true(minor_ok, "os_minor is not negative")
if os_build() >= 0 then build_ok = 1
assert_true(build_ok, "os_build is not negative")
if os_spmajor() >= 0 then sp1 = 1
assert_true(sp1, "os_spmajor is not negative")
if os_spminor() >= 0 then sp2 = 1
assert_true(sp2, "os_spminor is not negative")

test_case("platform/check")
rem os_check answers whether the running system is at least the version
rem given. Version 0.0 is below everything and 9999.0 is above it.
assert_eq(os_check(0, 0), 1, "every system is at least 0.0")
assert_eq(os_check(9999, 0), 0, "and none is 9999.0")
assert_eq(os_check(0, 0, 0), 1, "the three-argument form agrees")
assert_eq(os_check(9999, 0, 0), 0, "at both ends")

test_case("std/pointer-round-trip")
rem pointer@ turns a number into a pointer and pnttonum turns it back.
rem Neither dereferences anything, which is what makes them safe to
rem exercise with an address nothing lives at.
p@ = pointer@(123456)
assert_eq(pnttonum(p@), 123456, "the number survives the trip")
assert_eq(number(p@), 123456, "number reads the same address")
assert_eq(isassigned(p@), 1, "a non-zero address counts as assigned")

n@ = pointer@(0)
assert_eq(isassigned(n@), 0, "and a zero address does not")
assert_eq(pnttonum(n@), 0, "pnttonum answers zero for it")

test_case("std/classname")
rem classname$ asks the handle registry before dereferencing, so a
rem number dressed up as a pointer answers an empty string instead of
rem reading whatever happens to be at that address.
h@ = probe_new_a@()
assert_true(len(classname$(h@)), "a registered handle has a class name")
assert_eq(classname$(p@), "", "an unregistered address answers empty rather than crashing")
probe_free(h@)

test_case("std/sign")
assert_eq(sign(42), 1, "positive")
assert_eq(sign(-42), -1, "negative")
assert_eq(sign(0), 0, "zero")
assert_eq(sign(-0.001), -1, "a small negative is still negative")

test_case("std/isnull")
assert_eq(isnull(""), 0, "an empty string is not null")
assert_eq(isnull("text"), 0, "nor is text")
assert_eq(isnull(chr$(0)), 1, "a single NUL is")

test_case("std/pause")
rem Zero seconds, because the point is that the call is reachable and
rem answers, not that the suite can time a sleep.
assert_eq(pause(0), 0, "pause answers zero")

test_case("std/formatsettings")
rem These write process-wide state, so whatever is read first is put
rem back at the end. A suite that leaves the decimal separator changed
rem breaks every file that runs after it.
was$ = formatsettings$("dateseparator")
assert_true(len(was$), "formatsettings$ reads a setting")

assert_eq(formatsettings("dateseparator", "-"), 1, "formatsettings reports success")
assert_eq(formatsettings$("dateseparator"), "-", "and the new value reads back")

formatsettings("dateseparator", was$)
assert_eq(formatsettings$("dateseparator"), was$, "the original is restored")
