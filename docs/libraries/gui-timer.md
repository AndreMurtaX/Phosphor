# gui-timer — a tick, and the routine that runs on it

`host/gui/libs/PhosphorTimerLib.pas` · 9 functions · GUI package (the `phosphor`
host registers it wherever a graphical session is reachable; on a headless machine
these names are not registered at all)

## What it is for

Every other GUI package answers something the user did. This one answers time
passing: a timer is how a program does something *without* being asked — redraw a
clock, poll a directory, advance an animation, close a splash screen. The unit
header states the whole surface in five lines, and the page below is those five
lines expanded: a constructor with no parent, an interval, an enabled flag,
start/stop, and the name of a BASIC routine to run on each tick.

The one thing a caller will otherwise be surprised by is stated in the unit's own
words: **a timer only ticks under a running message loop** (`app_run()` in the
interactive host), "so a headless test checks its configuration, not its firing —
the same boundary the reference draws for the timer". A timer is not a delay and
not a thread. Configure it wherever you like; nothing fires until the program is
inside `app_run()`, or until an `app_processmessages()` gives the loop a moment.
That is why `tests/gui/06_menu_timer.bas` asserts only that the interval and the
enabled flag round-trip, while `tests/gui/17_event_loop.bas` — the one file that
enters the loop for real — is where a tick is actually observed.

There are **two constructors and one set of helpers**. `idletimer@` fires when the
application goes idle rather than on a clock, which is the shape a background task
wants: it yields to the user instead of competing with them. Both descend from the
same widgetset base, and every `timer_*` helper resolves *that base* rather than
the clock timer, so the two are interchangeable through the same seven names. Both
are also created **disabled**, explicitly and on purpose — an idle timer's
auto-enable is switched off too, so in both cases a program starts it.

The package holds the stances the rest of the GUI holds. **Errors are values**:
nothing here raises, a handle that is fabricated, freed or of the wrong class
records code `1` in the shared slot you read with `gui_error()` (sticky until
`gui_clearerror()`). **A mutator answers information rather than a success flag**
— every setter answers *its own timer back*, so calls chain and even a failed call
hands you a handle. Ownership is the one place a timer differs from a control: it
has no parent, so its **handle owns it**. It does not die with a form, it lives
until the program ends or until `control_free()` drops the handle, and a timer
left enabled keeps ticking after the window that used it is gone.

## Functions

| function | what it answers |
| --- | --- |
| `timer@() → handle` | a new clock timer, owned by its handle, parented to nothing, and **disabled** — it will not tick until `timer_start@`. Takes no arguments: an interval is a second call, not a constructor argument. It cannot fail, so there is no `0` answer to check |
| `idletimer@() → handle` | the same, but it fires when the application goes **idle** instead of on the clock — a background sweep that steps aside for the user. Also created disabled, and with its auto-enable off, so it starts only when asked. Every `timer_*` name below accepts it |
| `timer_interval@(t@, ms) → handle` | set the tick period in milliseconds and answer **the timer**, so configuration chains. The number is taken as a 32-bit count (a larger one clamps) and handed to the widgetset as given — nothing here validates it. A handle that is not a timer sets nothing, records `gui_error()` `1`, and still answers the handle you passed |
| `timer_interval(t@) → num` | the period currently set, in milliseconds. `0` for a handle that is not a timer — read `gui_error()` to tell that apart from a genuine `0` |
| `timer_enabled@(t@, on) → handle` | switch it directly: any non-zero **number** enables, `0` disables. It is a numeric slot, and Phosphor does not widen a bool into one, so pass `1`/`0` rather than `true`/`false` — or use the two verbs below, which read better. Answers the timer; a handle that is not a timer changes nothing and records error `1` |
| `timer_enabled(t@) → num` | `1` while it is running, `0` while it is not. Also `0` for a handle that is not a timer, which is the same reading as a stopped timer — `gui_error()` is where the difference lives |
| `timer_start@(t@) → handle` | enable it, and answer the timer. Starting one that is already running is harmless. Remember that this only means *eligible to tick*: with no message loop running, nothing happens yet. A bad handle records error `1` and answers what it was given |
| `timer_stop@(t@) → handle` | disable it, and answer the timer. Safe to call from inside the tick handler on the sender it was passed — that is how a one-shot timer is written, and `17_event_loop.bas` proves the sender is the live timer by doing exactly that. A bad handle records error `1` |
| `timer_ontimer@(t@, handler$) → handle` | run the named BASIC routine on each tick; it receives one argument, the sender's handle. `""` **unwires** it, and wiring again replaces the previous routine. A handler that fails at run time records error `2` instead of aborting the program — the tick still returns. Answers the timer, whether or not the handle resolved |

## A worked example

A window that redraws a clock every second and closes itself after ten of them,
with an idle timer counting how often the application had nothing better to do.
The interesting line is the one before `app_run()`: the configuration is readable
while nothing has ticked yet.

```basic
rem   phosphor run clock.bas
remaining = 10
swept = 0

f@ = form@("Clock", 320, 150)
now@ = label@(f@, "--:--:--")
control_bounds@(now@, 20, 20, 280, 24)
msg@ = label@(f@, "closing in 10s")
control_bounds@(msg@, 20, 56, 280, 24)

rem --- a clock timer: interval, handler, and only then start ---
clock@ = timer@()
timer_interval@(clock@, 1000)
timer_ontimer@(clock@, "on_tick")

rem --- an idle timer: the same seven helpers, a different reason to fire ---
idle@ = idletimer@()
timer_interval@(idle@, 200)
timer_ontimer@(idle@, "on_idle")

rem Configuration is readable before a single tick -- this is the whole of what a
rem headless test can check, and it is worth checking.
println "every " + str$(timer_interval(clock@)) + " ms, running " + str$(timer_enabled(clock@))

timer_start@(clock@)
timer_start@(idle@)
form_show(f@)

rem Nothing above this line ticked. Everything ticks inside here.
app_run()

println "ticks left: " + str$(remaining) + ", idle sweeps: " + str$(swept)
println "clock still running? " + str$(timer_enabled(clock@)) + "  (gui_error " + str$(gui_error()) + ")"

function on_tick(sender@)
  label_caption@(now@, time$())
  remaining = remaining - 1
  if remaining <= 0 then
    rem The sender IS the timer: stopping it through the handle we were handed is
    rem what proves the two are the same object and not a copy.
    timer_stop@(sender@)
    app_quit()
  else
    label_caption@(msg@, "closing in " + str$(remaining) + "s")
  endif
  return 0
endfunction

function on_idle(sender@)
  swept = swept + 1
  return 0
endfunction
```

Two things worth noticing:

- **The `println` before `app_run()` prints `every 1000 ms, running 0`.** Interval
  and enabled are ordinary readable state, so a timer's wiring can be asserted with
  no window, no user and no loop — which is exactly what the GUI suite does with it.
- **One handler serves the timer and knows which timer it was.** `on_tick` never
  names `clock@`; it stops `sender@`. The same routine could be wired to several
  timers and each would stop itself.

## Notes

- **A stopped timer and a bad handle read the same.** `timer_enabled()` answers `0`
  for both, and `timer_interval()` answers `0` for a bad handle. That is the
  deliberate cost of *empty is a real answer*: the value is always usable, and
  `gui_error()` — cleared with `gui_clearerror()` immediately before the call whose
  outcome you mean to judge — is where the difference is recorded.
- **A timer outlives the form it was built for.** It has no parent, so closing or
  freeing the window leaves it registered and, if it was enabled, still ticking
  into a handler whose controls may be gone. Stop it, or `control_free()` its
  handle, which frees the timer with it because the handle is what owns it.
- **What is not here.** There is no one-shot flag, no elapsed-time reading, and no
  way to ask when the next tick is due. A one-shot is written the way the example
  writes it — the handler stops its own sender — and elapsed time comes from the
  date-time library, not from the timer.

## Where the rest lives

`app_run()`, `app_processmessages()`, `app_quit()`, `gui_error()` and
`gui_clearerror()` belong to the GUI core package: [gui-core.md](gui-core.md).
Which widgetset components Phosphor exposes, and which it deliberately does not,
is [gui-components.md](../gui-components.md); the reason animations are absent is
recorded there too — timer-driven property tweening is the native path.
