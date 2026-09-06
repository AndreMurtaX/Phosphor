# host — the event pump and the clipboard, asked of whatever host is there

`engine/libs/PhosphorHostLib.pas` · 5 functions · always available (the *answers*
depend on the host)

## What it is for

Two things a program eventually wants from the machine it runs on are an **event
pump** and the **system clipboard**. In a lesser design the functions that provide
them would reach into a windowing framework, and that import would drag a whole GUI
dependency into anything that used `left$()`. This library is the language-visible
face of the alternative: the engine's **host-services seam**, a record of method
pointers on the VM (`ProcessMessages`, `HandleMessage`, `ClipboardCopy`,
`ClipboardPaste`) that a host fills in and a headless runner leaves nil.

**Empty is a real answer, not a failure.** With no seam installed, `processmessages`
and `handlemessage` answer `0`, and the clipboard pair answer `""`. Nothing here
pretends, and nothing here crashes: the guarding invariant of the whole unit is that
asking an absent service **never dereferences a nil method**. Every function tests
`Assigned` before calling.

A missing clipboard is, on top of that, **an error the script can see**. The
clipboard pair leave a code behind that `strerror()` reads back — the same
last-error-as-a-value pattern as `ioerror()` and `valcode()`, never an exception —
so a program can offer a fallback ("copy this by hand") instead of being surprised
by an empty string. Reading `strerror()` is in fact the *only* way to tell an empty
clipboard from an absent one, because both read back as `""`.

Four of the five register as **host-aware** (`AddHost`) because they consult the
executing VM's seam; `strerror` is a plain function, since it only reads a
module-level code. Host-aware is not the same as host-*dependent*: the unit itself
touches no console, file or window, which is exactly why the string library no
longer needs a window to run.

## Functions

| function | what it answers |
| --- | --- |
| `processmessages() → num` | `1` when a host's event pump ran, `0` when no host installed one. It is not a one-shot — call it as often as you like; where there is no pump the call is a cheap `0` and cannot fault |
| `handlemessage() → num` | `1` when the host waited for and dispatched one message, `0` when it could not — no seam at all, or a host that has one but will not block (an unattended runner reports `0` rather than hanging forever) |
| `copytext$(s$) → str` | the text it actually stored on the host clipboard. `""` when there is no clipboard service, or when the host could not confirm the store — and `strerror()` is then non-zero. Storing `""` on a real clipboard is a *success*: it answers `""` with `strerror()` still `0` |
| `pastetext$() → str` | the host clipboard's current text. `""` when there is no clipboard service (`strerror()` non-zero) **and** when the clipboard is genuinely empty (`strerror()` `0`). The string alone does not distinguish them |
| `strerror() → num` | the last host-services error code: `0` clear, `1` "the previous clipboard call did not get through" — no clipboard service, or one that could not confirm the transfer. Written *only* by `copytext$`/`pastetext$`, each of which sets it to `0` on success and `1` on failure; `processmessages`/`handlemessage` never touch it, so it is never stale for a reason you did not cause |

## A worked example

Offering some text to the user through the clipboard, and degrading honestly when
there is nowhere to put it. The same program runs under the shipped `phosphor` host
(which copies for real and reports a pump) and under a runner with no seam at all
(which takes the fallback path and reports none) — no conditional compilation.

```basic
rem Put text on the clipboard if this host has one; otherwise print it
rem so the user can copy it by hand. Answers what was stored, "" if nothing.

function offer$(text$) local stored$
  stored$ = copytext$(text$)
  if strerror() = 0 then
    println "copied " + str$(len(stored$)) + " characters to the clipboard"
    return stored$
  endif
  println "no clipboard on this host -- here it is, copy it by hand:"
  println text$
  return ""
endfunction

got$ = offer$("phosphor: host services, five of them")

rem Give a host with an event loop a chance to repaint while we work.
rem Where there is none, processmessages() is a cheap 0 and this is
rem simply a loop.
pumped = 0
for i = 1 to 3
  pumped = pumped + processmessages()
next

if pumped = 0 then
  println "headless: nothing pumped"
else
  println "a host pumped " + str$(pumped) + " times"
endif

rem handlemessage() is deliberately NOT called here. Where a host really
rem provides it, it WAITS for one message -- and this program has no
rem window for a message to arrive at, so the wait would never end. It
rem belongs inside an event loop, where its 0 ("this host cannot wait")
rem is the signal to stop looping.

rem Reading back: "" is ambiguous, strerror() is what resolves it.
back$ = pastetext$()
if back$ <> "" then
  println "the clipboard holds: " + back$
else
  if strerror() = 0 then
    println "the clipboard is empty"
  else
    println "there is no clipboard to read"
  endif
endif
```

Two things worth noticing:

- **The branch is on `strerror()`, not on the string.** `copytext$` answering `""`
  could mean "there is no clipboard" or "you asked me to store an empty string, and
  I did". Only the error code separates them, and that is the whole reason it exists.
- **`handlemessage` is the one that blocks.** In a host that provides it for real it
  waits — under the shipped `phosphor` host, a program with no window that calls it
  never comes back. A `0` from it is a runner saying *I cannot wait for you*, not
  *there was no message*, and it is the only one of the five that can cost you time.

## Notes / Where the rest lives

The platform work is not here. `PhosphorHostLib` only asks the seam; the methods are
installed by a host. The one shipped host, `phosphor`, fills all four **whenever a
graphical session is reachable** — always on Windows, and on Unix when `DISPLAY` or
`WAYLAND_DISPLAY` is set — so on a normal desktop the clipboard really is the
machine's clipboard. The headless test runner installs none, on purpose.
`scripts/check-seams.py` fails the build when a host leaves an engine seam nil
without a written reason, after the round where the one program meant to provide an
event loop left all four methods nil and `processmessages()` answered `0` inside a
running GUI.

That clipboard is the machine's, not your program's. Its host implementation
write-then-confirms with a bounded retry, because the OS clipboard is contended and
a plain assignment silently loses — and `copytext$("")` really *clears* it rather
than storing nothing. A program that borrows the clipboard should read it with
`pastetext$()` first and put the contents back when it is done, the way
`tests/gui/16_host_services.bas` does.

`strerror()` is the host-services last-error slot and nothing else. The other
subsystems keep their own: `ioerror()` and `iostrerror$()` for file I/O,
`http_error()` for HTTP, `sqlite_error()` for the database. They do not share state,
and a clipboard failure never shows up in any of them.

Both halves of this library are pinned by tests, deliberately: `tests/suite/17_host_services.bas`
runs with the seam empty and asserts the absent-service answers, and
`tests/gui/16_host_services.bas` runs under a host that fills it and round-trips the
clipboard, including multi-byte text across the platform's own encoding boundary.
