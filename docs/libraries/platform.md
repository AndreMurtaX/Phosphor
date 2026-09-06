# platform — what machine this is, and the rest of the standard library

`engine/libs/PhosphorPlatformLib.pas` · 17 functions · always available

## What it is for

This library answers **what the program is running on**, and it carries the
remainder of StdLib — the handful of standard names that belong to no larger
subject. `os_name$`, `os_platform$` and `os_architecture$` identify the system;
`os_major`/`os_minor`/`os_build` and `os_check` describe and compare its version.
The rest is the leftovers, and they are genuinely unrelated to each other: pointer
round-trips (`number`, `isassigned`, `classname$`), `sign`, `isnull`, `pause`, and
read/write access to the process-wide format settings.

The identity answers are **exact, not guessed**. `os_name$` is decided at *compile*
time by the platform IFDEFs, and `os_platform$`/`os_architecture$` come straight
from the FPC target macros, so a Linux build cannot report Windows however it is
launched. The version numbers are different in kind: they come from the OS at
startup — `Win32MajorVersion` and friends on Windows, `/proc/sys/kernel/osrelease`
on Linux — read once, into three variables, and answered from there for the life of
the process.

Nothing in this library fails. Not one of the seventeen sets an error, blocks on
anything but `pause`, or refuses an argument. What that buys is that **the
unanswerable case has a real answer instead of an exception**: `classname$` of an
address nothing is registered at is `""`; `formatsettings$` of a name it does not
know is `""`; `os_spmajor` and `os_spminor` are always `0` because service packs
are not tracked at all. The three handle functions are the important case — each
consults the handle registry *before* dereferencing anything, so a fabricated
address is described as unknown rather than read.

Two things will surprise a caller. First, **`isassigned` means non-zero, not
alive**: it answers `1` for any handle value that is not `0`, including one
invented with `pointer@` and one whose object has already been freed. Only
`classname$` can tell you whether a handle is real. Second, **on Windows the
version numbers are the ones Windows chooses to tell an unmanifested process**:
a Windows 11 machine reports `6.2.9200`, so `os_check(10, 0)` answers `0` there.
Treat the version as a compatibility shim's answer, not as the marketing version
on the box.

## Functions

### Identity

| function | what it answers |
| --- | --- |
| `os_name$() → str` | `"Windows"`, `"macOS"` or `"Linux"`, fixed at compile time. A POSIX target that is none of those answers `"Unix"` — never `""` |
| `os_platform$() → str` | the FPC target OS string, e.g. `Win64`, `linux`, `darwin`. Finer-grained than `os_name$`, because it carries the bitness on Windows |
| `os_architecture$() → str` | the FPC target CPU string, e.g. `x86_64`, `i386`, `aarch64` |

### Version

| function | what it answers |
| --- | --- |
| `os_major() → num` | the major version, read from the OS at startup. Never below `1`: a floor is applied, so a platform the engine has no reader for (currently macOS) answers a conservative `1` rather than `0` |
| `os_minor() → num` | the minor version; `0` on a platform with no reader |
| `os_build() → num` | the build number (the third `/proc` component on Linux); `0` on a platform with no reader |
| `os_spmajor() → num` | always `0`. Service packs are not tracked, so this is not "no service pack" — it is "not known" |
| `os_spminor() → num` | always `0`, for the same reason |
| `os_check(major, minor) → num`<br>`os_check(major, minor, build) → num` | `1` if the running system is at least that version, `0` if it is below it. Compared component by component — major first, then minor, then build with `>=`. The two-argument form tests build `0`, so it is the "any build of this version" question |

### Handles

Each takes a handle and answers something about the *value*; none of them
dereferences an address it has not found in the registry first.

| function | what it answers |
| --- | --- |
| `number(h@) → num` | the handle's numeric address, the inverse of `pointer@`. `0` if the value is not a handle at all |
| `isassigned(h@) → num` | `1` when the handle is non-zero, `0` when it is zero. It does **not** check that anything lives there — a fabricated or already-freed handle answers `1` |
| `classname$(h@) → str` | the class name of the object the handle refers to, e.g. `TPhosphorBytes`. `""` when the handle is not in the registry — a number dressed up as a pointer, or a handle whose object was freed. This is the only honest liveness test in the library |

### The rest of StdLib

| function | what it answers |
| --- | --- |
| `sign(n) → num` | `-1`, `0` or `1`. Zero and NaN both answer `0`, so `sign` alone cannot distinguish "no sign" from "not a number" |
| `isnull(s$) → num` | `1` only when the string is exactly one NUL character. `""` answers `0` — an empty string is not a null one — and so does a longer string that merely contains a NUL |
| `pause(seconds) → num` | always `0`; the answer carries no information, the sleep is the point. A negative, zero or NaN argument returns immediately. Enormous values are clamped rather than raising: the ceiling is about 24 days, which a script cannot tell from forever. It blocks the engine outright |

### Process format settings

`formatsettings$` and `formatsettings` read and write the process-wide RTL format
settings by name, case-insensitively. The nine known names are `dateseparator`,
`timeseparator`, `decimalseparator`, `thousandseparator`, `listseparator`,
`shortdateformat`, `longdateformat`, `shorttimeformat` and `longtimeformat`.

| function | what it answers |
| --- | --- |
| `formatsettings$(name$) → str` | the current value of that setting — one character for the separators, the whole pattern for the formats. `""` for a name it does not know |
| `formatsettings(name$, value$) → num` | `1` when the name was recognised and written, `0` when it was not — and when it answers `0`, nothing changed. The answer is about the *name*, not about the write, which cannot fail. For a separator only the **first** character of `value$` is used, so `"abc"` sets `a`; an empty `value$` sets NUL rather than leaving the old value in place |

## A worked example

A startup banner that says exactly what it is running on, decides whether the
machine is new enough for a fast path, and then asks the two questions a handle
can be asked. Every line below is real output from a Windows 11 box.

```basic
rem What are we running on, and is it new enough?
println "phosphor on " + os_name$() + " (" + os_platform$() + "/" + os_architecture$() + ")"
println "version " + str$(os_major()) + "." + str$(os_minor()) + "." + str$(os_build())
println "service pack " + str$(os_spmajor()) + "." + str$(os_spminor())

if os_check(10, 0) = 1 then
  println "fast path: enabled"
else
  println "fast path: off (needs 10.0 or later)"
endif

rem What the machine's locale says, and what an unknown name says.
println "date separator is '" + formatsettings$("dateseparator") + "'"
println "unknown setting reads '" + formatsettings$("nosuchsetting") + "'"
println "writing an unknown name answers " + str$(formatsettings("nosuchsetting", "x"))

rem A real handle, then a number wearing a handle's clothes.
b@ = buffer_new@(16)
println "real  class '" + classname$(b@) + "', assigned " + str$(isassigned(b@))
buffer_free(b@)

fake@ = pointer@(123456)
println "fake  class '" + classname$(fake@) + "', assigned " + str$(isassigned(fake@))
println "fake  number " + str$(number(fake@)) + ", pnttonum " + str$(pnttonum(fake@))

println "isnull(chr$(0)) = " + str$(isnull(chr$(0))) + ", isnull of empty = " + str$(isnull(""))
pause(0.05)
```

```
phosphor on Windows (Win64/x86_64)
version 6.2.9200
service pack 0.0
fast path: off (needs 10.0 or later)
date separator is '/'
unknown setting reads ''
writing an unknown name answers 0
real  class 'TPhosphorBytes', assigned 1
fake  class '', assigned 1
fake  number 123456, pnttonum 123456
isnull(chr$(0)) = 1, isnull of empty = 0
```

Two things worth noticing:

- **`fast path: off` on Windows 11.** That is the version shim, not a bug: the
  process is unmanifested, so Windows reports `6.2.9200`. If you need to gate a
  feature on a modern Windows, gate it on `os_platform$()` or on the feature
  itself — `os_check` is trustworthy for "is this kernel at least X" on Linux and
  for comparing against the number the OS actually reports, not for "is this
  Windows 10 or later".
- **`assigned 1`, `class ''`.** The fabricated handle is assigned and its address
  reads back intact through both `number` and `pnttonum`, yet it has no class,
  because the registry was consulted before anything was dereferenced. That
  ordering is the whole reason a bad handle prints an empty string here instead of
  taking the process down.

## Notes

**Writing a format setting does not change how Phosphor formats anything.** The
string, config, JSON and date libraries each snapshot `DefaultFormatSettings` at
startup into a pinned, locale-invariant copy, precisely so that the same program
produces the same bytes on every machine. So after `formatsettings("decimalseparator", ",")`
succeeds and `formatsettings$("decimalseparator")` reads back `,`, `str$(1.5)` is
still `1.5` and `formatdatetime$` is unmoved. What the pair is for is *inspecting*
the machine's locale and cooperating with host code that shares the process — not
for steering the engine's own conversions.

Because the setting is process-wide, a program that writes one should read the old
value first and put it back, the way the suite in
`tests/suite/24_platform_std.bas` does. The version variables, by contrast, are
read once at startup and never written, so nothing a program does can move them.
