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
# `function <name>(` ... up to the line that closes it. Pascal has no block
# markers a regex can trust, so the body is taken as the text between this
# function's header and the next top-level `function`/`procedure` header.
FUNC = re.compile(r'^\s*function\s+(\w+)\s*\(', re.M)


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


def bodies(text):
    """name -> body text, for every function in the file."""
    marks = [(m.start(), m.group(1)) for m in FUNC.finditer(text)]
    out = {}
    for i, (pos, name) in enumerate(marks):
        end = marks[i + 1][0] if i + 1 < len(marks) else len(text)
        out[name] = text[pos:end]
    return out


def returned_kinds(body, argsig):
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
        return set(), True
    # Re-read ONLY the last assignment; the set above is kept just to know
    # whether anything at all was resolvable.
    kinds = set()
    c = re.match(r'(Val\w+)\s*\(', last)
    if c and c.group(1) in CTOR_KIND:
        kinds.add(CTOR_KIND[c.group(1)])
    else:
        a = re.match(r'Args\[\s*(\d+)\s*\]\s*$', last)
        h = re.match(r'Args\[\s*High\(Args\)\s*\]\s*$', last)
        if a and int(a.group(1)) < len(argsig):
            kinds.add(ARG_KIND.get(argsig[int(a.group(1))]))
        elif h and argsig:
            kinds.add(ARG_KIND.get(argsig[-1]))
        else:
            sure = False
    kinds.discard(None)
    return kinds, sure


def main():
    seen = {}
    for path in sources():
        text = io.open(path, encoding='utf-8', errors='ignore').read()
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
            seen[(spec, path, line)] = (name, argsig, body)

    bad = []
    for (spec, path, line), (name, argsig, body) in sorted(seen.items()):
        if spec in EXEMPT:
            continue
        suffix = name[-1] if name and name[-1] in SUFFIX_KIND and name[-1] != '' else ''
        if suffix not in SUFFIX_KIND:
            suffix = ''
        want = SUFFIX_KIND[suffix]
        kinds, sure = returned_kinds(body, argsig)
        if not kinds:
            continue
        if want in kinds:
            continue
        if not sure:
            continue                          # an unread path might return it
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

    print('suffixes: %d registrations checked, every one returns what its name says'
          % len(seen))
    return 0


if __name__ == '__main__':
    sys.exit(main())
