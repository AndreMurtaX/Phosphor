#!/usr/bin/env python3
"""check-suffix.py -- a registered name's type suffix must be what it returns.

WHAT THIS EXISTS FOR. A function's return type in Phosphor comes from the SUFFIX
ON ITS OWN NAME: none = number, $ = string, % = int, @ = handle, ? = bool. That is
the whole type system for built-ins -- and nothing enforced it. TPhosphorRegistry
stores 'dict_clear@:@' as an opaque lookup key; the suffix is part of the NAME, so
an int-returning function could sit behind an @ name indefinitely, and one did.

The cost lands on the caller, at RUN time, in opStoreVar:

    x = arr_set(a@, 1, "hi")     ->  cannot store string into number variable
    h@ = narr_set@(a@, 1, 42)    ->  cannot store int into handle variable

Both used to be the documented spelling. Fifteen registrations lied when this gate
was first written, across three unrelated libraries, which is what a rule with no
check looks like after a year.

HOW IT DECIDES. For each Reg.Add('name:argsig', @fn) it reads fn's body and
collects every kind Result can take:

    ValInt / ValDouble  number      ValStr  string
    ValHandle           handle      ValBool bool
    Args[0], Args[1]...             the kind of THAT argument, read off argsig
    Args[High(Args)]                the kind of the last argument

A name is reported only when the kind its suffix promises is returned NOWHERE in
the implementation. Anything the reader cannot resolve -- a Result built by a
helper call, a variable, a with-block -- is UNKNOWN and silences the name rather
than guessing. False silence, never a false alarm: a gate that cries wolf is one
people learn to skip, and this one has to survive being run on 1300 names.

EXEMPT holds the handful that are deliberate, each with the reason. Do not add a
name to it to make a failure go away.
"""
import glob
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# A registration whose suffix disagrees with the implementation ON PURPOSE.
# Nothing is in here yet; the entry format is  'name:argsig': 'why'.
EXEMPT = {}

NUMBER, STRING, HANDLE, BOOL = 'number', 'string', 'handle', 'bool'

# The suffix on the function's OWN name -> the kind it promises to return.
# '%' is Int64 and no suffix is Double; both are the number kind to the registry,
# which widens between them, so they are one class here.
SUFFIX_KIND = {'$': STRING, '@': HANDLE, '?': BOOL, '%': NUMBER, '': NUMBER}

# A character of the ARGUMENT signature -> the kind of that argument.
ARG_KIND = {'n': NUMBER, '$': STRING, '@': HANDLE, '?': BOOL, '%': NUMBER}

CTOR_KIND = {'ValInt': NUMBER, 'ValDouble': NUMBER, 'ValNum': NUMBER,
             'ValStr': STRING, 'ValHandle': HANDLE, 'ValBool': BOOL}

# Reg.Add AND Reg.AddHost: a host-seam function carries a suffix like any other,
# and leaving AddHost out would have exempted a whole class from the rule by
# accident rather than by decision.
REG = re.compile(r"""Reg\.Add(?:Host)?\(\s*'([^']+)'\s*,\s*@(\w+)\s*\)""")
# A routine header. Pascal has no block markers a regex can trust, so a body is
# taken as the text between one header and the NEXT one -- which makes the header
# pattern load-bearing: anything it fails to recognise is not a boundary, and the
# routine it introduces is swallowed by whatever came before.
#
# It used to read `function <name>(`, and three shapes have no `(` after the name:
# a parameterless function (`function StdinIsInteractive: Boolean;`), a procedure,
# and a qualified method (`function TPhosphorCompiler.Compile(...)` -- the name is
# followed by a dot, not a parenthesis). 737 of the 1300 registrations were being
# judged on a body that ran on into the next routine; `bg$:n` and `http_strerror$:n`
# were silenced outright because the `Result :=` the reader landed on belonged to
# the parameterless function underneath them. So: function OR procedure, dotted
# name allowed, parameter list optional.
ROUTINE = re.compile(r'(?im)^[ \t]*(?:function|procedure)\s+([A-Za-z_][\w.]*)')


def sources():
    out = []
    for pat in ('engine/**/*.pas', 'host/**/*.pas', 'tests/**/*.pas'):
        out += glob.glob(os.path.join(ROOT, pat), recursive=True)
    # Dedupe on the normcased path -- the same file reached by two patterns would
    # otherwise be read twice and every finding in it reported twice -- but KEEP
    # the original spelling, because a lower-cased path is not a link a reader can
    # click.
    seen, keep = set(), []
    for p in out:
        k = os.path.normcase(os.path.abspath(p))
        if k not in seen:
            seen.add(k)
            keep.append(os.path.abspath(p))
    return sorted(keep)


def mask_comments(text):
    """The same text with every comment blanked to spaces, newlines kept.

    Offsets and line numbers survive, so a caller can still report a line. This
    is here because the header pattern above is only as good as the text it runs
    on: PhosphorEngine.pas wraps a paragraph so that a line begins "function is
    unknown, or it fails. }", and reading that as a routine header would split a
    body in half at a sentence. Blanking comments also means a commented-out
    `Result :=` no longer votes on what a function returns, which it should not.

    String literals are kept -- REG reads the registration name out of one -- so
    the scan has to know where a string starts to avoid taking the apostrophe in
    a comment, or the '{' in a literal, for something it is not."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "'":                       # a string literal: skipped, not blanked
            i += 1
            while i < n and text[i] != "'" and text[i] != '\n':
                i += 1
            i += 1
            continue
        if c == '/' and i + 1 < n and text[i + 1] == '/':
            while i < n and text[i] != '\n':
                out[i] = ' '
                i += 1
            continue
        if c == '{':                       # also swallows {$...} directives
            while i < n and text[i] != '}':
                if text[i] != '\n':
                    out[i] = ' '
                i += 1
            if i < n:
                out[i] = ' '
                i += 1
            continue
        if c == '(' and i + 1 < n and text[i + 1] == '*':
            while i + 1 < n and not (text[i] == '*' and text[i + 1] == ')'):
                if text[i] != '\n':
                    out[i] = ' '
                i += 1
            for _ in range(2):
                if i < n:
                    out[i] = ' '
                    i += 1
            continue
        i += 1
    return ''.join(out)


def bodies(text):
    """name -> body text, for every routine in the file.

    A qualified method is keyed by its full `TClass.Method` spelling, which keeps
    it out of the plain-name namespace a registration's `@fn` looks in -- a method
    cannot be registered that way, and letting `TFoo.Run` answer to `Run` would
    hand the reader the wrong body."""
    marks = [(m.start(), m.group(1)) for m in ROUTINE.finditer(text)]
    out = {}
    for i, (pos, name) in enumerate(marks):
        end = marks[i + 1][0] if i + 1 < len(marks) else len(text)
        out[name] = text[pos:end]
    return out


def kind_of(expr, argsig):
    """The kind of one expression, or None when it cannot be told."""
    c = re.match(r'(Val\w+)\s*\(', expr)
    if c:
        return CTOR_KIND.get(c.group(1))
    a = re.match(r'Args\[\s*(\d+)\s*\]\s*$', expr)
    if a and int(a.group(1)) < len(argsig):
        return ARG_KIND.get(argsig[int(a.group(1))])
    if re.match(r'Args\[\s*High\(Args\)\s*\]\s*$', expr) and argsig:
        return ARG_KIND.get(argsig[-1])
    return None


def returned_kinds(body, argsig, helpers=None):
    """The kind of the LAST `Result :=` in the body, which is this codebase's
    success path.

    Not every assignment: the house pattern opens with a PLACEHOLDER before the
    guards --

        Result := ValInt(0);
        if not GetArr(Args[0], a, Err) then Exit;
        ...
        Result := Args[High(Args)];

    -- so collecting every assignment made ValInt(0) count as a legitimate
    number return, and arr_set:@n$ (which promises a number and answers the
    string it wrote) passed the gate on the strength of its own error path. The
    last assignment is the answer a successful call gives back."""
    kinds = set()
    sure = True
    last = None
    for m in re.finditer(r'Result\s*:=\s*([^;]+);', body):
        expr = m.group(1).strip()
        last = expr
        c = re.match(r'(Val\w+)\s*\(', expr)
        if c and c.group(1) in CTOR_KIND:
            kinds.add(CTOR_KIND[c.group(1)])
            continue
        a = re.match(r'Args\[\s*(\d+)\s*\]\s*$', expr)
        if a:
            i = int(a.group(1))
            kinds.add(ARG_KIND.get(argsig[i], None) if i < len(argsig) else None)
            continue
        if re.match(r'Args\[\s*High\(Args\)\s*\]\s*$', expr):
            kinds.add(ARG_KIND.get(argsig[-1], None) if argsig else None)
            continue
        sure = False          # a helper call, a variable, something else
    kinds.discard(None)
    if last is None:
        return set(), False
    # Re-read ONLY the last assignment; the scan above is kept just for its side
    # effect of finding `last`.
    kinds = set()
    k = kind_of(last, argsig)
    if k is None and helpers is not None:
        # ONE level of indirection: `Result := DoDim(akNumeric, Args, Err);` is
        # the house shape for a family of names sharing one worker, and leaving
        # it unread silenced dim@/sdim@/pdim@ and every function like them --
        # 263 registrations the gate counted as "checked" while judging nothing.
        # The helper is read only if EVERY assignment in it agrees on one kind,
        # so a worker that can answer two kinds still says nothing.
        call = re.match(r'(\w+)\s*\(', last)
        if call and call.group(1) in helpers:
            inner = helpers[call.group(1)]
            got = {kind_of(m.group(1).strip(), argsig)
                   for m in re.finditer(r'Result\s*:=\s*([^;]+);', inner)}
            if len(got) == 1 and None not in got:
                k = got.pop()
    # `sure` is decided HERE and nowhere else: the verdict rests on the last
    # assignment alone, so an earlier one the scan could not read says nothing
    # about it. Leaving the scan's `sure` in place silenced every function whose
    # answer came through a helper -- the resolution above found the kind and the
    # stale flag threw it away.
    sure = k is not None
    if sure:
        kinds.add(k)
    return kinds, sure


def main():
    seen = {}
    for path in sources():
        raw = io.open(path, encoding='utf-8', errors='ignore').read()
        # Comments are blanked in place, so offsets and line numbers still line up
        # with the file on disk -- and a registration written inside a comment is
        # no longer read as one.
        text = mask_comments(raw)
        fns = bodies(text)
        for m in REG.finditer(text):
            spec, impl = m.group(1), m.group(2)
            if ':' not in spec:
                continue
            name, argsig = spec.split(':', 1)
            body = fns.get(impl)
            if body is None:
                continue                      # registered from another unit
            line = text[:m.start()].count('\n') + 1
            # fns rides along: it is this file's other functions, the only
            # helper candidates a `Result := Worker(...)` can name.
            seen[(spec, path, line)] = (name, argsig, body, fns)

    bad = []
    judged = 0
    for (spec, path, line), (name, argsig, body, fns) in sorted(seen.items()):
        if spec in EXEMPT:
            continue
        suffix = name[-1] if name and name[-1] in SUFFIX_KIND and name[-1] != '' else ''
        if suffix not in SUFFIX_KIND:
            suffix = ''
        want = SUFFIX_KIND[suffix]
        kinds, sure = returned_kinds(body, argsig, fns)
        if not sure or not kinds:
            continue                          # indeterminate: say nothing
        judged += 1
        if want in kinds:
            continue
        rel = os.path.relpath(path, ROOT).replace(os.sep, '/')
        bad.append((rel, line, spec, want, sorted(kinds)))

    if bad:
        print('NAMES WHOSE SUFFIX IS NOT WHAT THEY RETURN:')
        for rel, line, spec, want, got in bad:
            print('  %s:%d  %s' % (rel, line, spec))
            print('      the name promises %-7s the body returns %s'
                  % (want, ', '.join(got)))
        print('')
        print('A caller storing the result into a correctly-typed variable gets')
        print('"cannot store X into Y variable" at run time. Fix the name or the')
        print('return -- and if the disagreement is deliberate, put it in EXEMPT')
        print('with the reason.')
        return 1

    # Say how many were actually JUDGED, not just how many were looked at. A gate
    # that reports 1230 while resolving 967 of them is overstating its own reach,
    # and the number a reader trusts should be the smaller one.
    print('suffixes: %d of %d registrations resolved, every one returns what its '
          'name says (%d indeterminate and reported on by nothing)'
          % (judged, len(seen), len(seen) - judged))
    return 0


if __name__ == '__main__':
    sys.exit(main())
