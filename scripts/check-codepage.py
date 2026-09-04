#!/usr/bin/env python3
"""Detect the {$codepage UTF8} char-concatenation class before it ships.

THE BUG THIS EXISTS FOR. A unit compiled with {$codepage UTF8} carries a code page
on its string type. Concatenating a CHAR into such a string re-encodes it, so any
byte >= 128 is mangled or replaced with '?':

    r := r + c;             // c: Char        -- DESTROYS bytes >= 128
    r := r + Copy(s, i, 1); //                -- fine, a String slice keeps its bytes

Nothing about the broken line looks wrong, it compiles without a warning, and the
damage is silent: proper$("cafe" with an acute) returned "Caf??" for months while
every suite stayed green, because no golden happened to push a non-ASCII byte
through that particular function.

This class has now been found and swept THREE times -- in the byte-primitive work,
in hex_decode$/gzip, and again by an adversarial hunt that turned up proper$,
swapcase$, PRINT USING (four sites), a lexer message and a CRT key encoder. A class
that keeps coming back does not need a fourth fix; it needs a check.

WHAT IS FLAGGED. An ACCUMULATE whose appended operand is a CHARACTER:

    <x> := <x> + <char>            r := r + c
    <x> := <char> + <x>            Result := Result + Fmt[i]
                                   s := s + Chr(b)
                                   s := s + #200

<char> means: an identifier declared Char/AnsiChar, an INDEXED identifier whose own
declared type is a string or an array of Char (indexing either yields a Char), a
Chr(...) call, or a #NNN literal >= 128. Declarations are read from the file, so an
indexed `Items[i]` on an `array of String` is correctly left alone.

A pure character CHAIN is deliberately NOT flagged: `Result := Chr(a) + Chr(b)` is
how CpUtf8 legitimately builds a UTF-8 sequence, and it is correct precisely because
no already-encoded string is one of the operands.

The rule is absolute on purpose -- ASCII-only sites are flagged too. "This one only
ever holds digits" is exactly the reasoning that let the class survive two sweeps.

KNOWN LIMIT. Only CONCATENATION is checked. Passing a Char where a String parameter
is expected converts it the same way -- StringReplace(f, QuoteChar, ...) -- and is not
detected here; those are found by reading the call sites of Char-typed fields.

Usage:  python scripts/check-codepage.py
Exit 0 when clean, 1 when a site is found.
"""
import re, os, sys, glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCAN = ['engine/*.pas', 'engine/libs/*.pas', 'host/packages/*.pas',
        'host/gui/libs/*.pas', 'host/console/*.lpr', 'host/gui/*.lpr', 'tests/*.pas']

# `a, b: Type;` in a var block, a class field, or a parameter list
DECL = re.compile(r'([A-Za-z_][\w]*(?:\s*,\s*[A-Za-z_]\w*)*)\s*:\s*'
                  r'((?:const\s+|var\s+|out\s+)?[\w\[\]., ]*?)\s*[;)=]')
ROUTINE = re.compile(r'^\s*(?:function|procedure)\s+([\w.]+)', re.I)
# EVERY assignment on the line, not just one at the start: `if c then r := r + c;`
# and `begin r := r + c; atStart := True; end` are both ordinary Pascal here, and an
# earlier version of this check anchored to the line start and therefore missed both
# -- discovered by reintroducing a known bug and watching the check stay silent.
ACC = re.compile(r'([A-Za-z_]\w*(?:\[[^\]]*\])?)\s*:=\s*([^;]+)')

STRINGY = re.compile(r'^(string|ansistring|rawbytestring|utf8string|shortstring)$', re.I)
CHARRY = re.compile(r'^(char|ansichar)$', re.I)
ARR_OF_CHAR = re.compile(r'^array\s*(\[[^\]]*\])?\s*of\s*(ansi)?char$', re.I)


def declared_types(src):
    """name -> 'char' | 'string' for every declaration in the file.

    File-wide rather than per-scope: Pascal code in this project does not reuse one
    name for a Char here and a record there, and over-approximating costs a review,
    while under-approximating costs a shipped bug.
    """
    kinds = {}
    for m in DECL.finditer(src):
        names, typ = m.group(1), m.group(2).strip()
        if CHARRY.match(typ):
            kind = 'char'
        elif STRINGY.match(typ):
            kind = 'string'
        elif ARR_OF_CHAR.match(typ):
            kind = 'string'          # indexing it also yields a Char
        else:
            continue
        for n in names.split(','):
            kinds[n.strip().lower()] = kind
    return kinds


def adjacent_to_plus(expr, operand_re):
    """True when the operand sits directly beside a '+', i.e. is CONCATENATED.

    Adjacency is the whole point: `Ord(ch)` inside IntToHex(...) mentions a Char but
    appends a String, and flagging it would train the reader to ignore this check.
    """
    return (re.search(r'\+\s*' + operand_re, expr, re.I) is not None or
            re.search(operand_re + r'\s*\+', expr, re.I) is not None)


def char_operands(expr, kinds):
    """Character-typed operands that are CONCATENATED in this expression."""
    hits = []
    if adjacent_to_plus(expr, r'Chr\s*\('):
        hits.append('Chr(...)')
    for m in re.finditer(r'#(\d+)', expr):
        if int(m.group(1)) >= 128 and adjacent_to_plus(expr, '#' + m.group(1)):
            hits.append('#' + m.group(1))
    for m in re.finditer(r'\b([A-Za-z_]\w*)\s*\[[^\]]+\]', expr):
        name = m.group(1)
        if kinds.get(name.lower()) == 'string' and \
           adjacent_to_plus(expr, re.escape(name) + r'\s*\[[^\]]+\]'):
            hits.append(name + '[...] is a Char')
    for name, kind in kinds.items():
        if kind != 'char':
            continue
        if adjacent_to_plus(expr, r'(?<![\w.])' + re.escape(name) + r'(?![\w(\[])'):
            hits.append(name)
    return hits


def strip_block_comments(src):
    """Blank out { } and (* *) comments, KEEPING newlines so line numbers hold.

    Without this the check reads the comment that EXPLAINS the bug -- "built their
    answer with `r := r + c`" -- and reports the explanation as an instance of it.
    """
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        if src[i] == '{':
            j = src.find('}', i)
            j = n - 1 if j < 0 else j
            for k in range(i, j + 1):
                if out[k] != '\n':
                    out[k] = ' '
            i = j + 1
        elif src.startswith('(*', i):
            j = src.find('*)', i)
            j = n - 2 if j < 0 else j
            for k in range(i, min(j + 2, n)):
                if out[k] != '\n':
                    out[k] = ' '
            i = j + 2
        else:
            i += 1
    return ''.join(out)


def scan(path):
    raw = open(path, encoding='utf-8', errors='ignore').read()
    if 'codepage utf8' not in raw.lower():
        return []
    src = strip_block_comments(raw)
    kinds = declared_types(src)
    original = raw.splitlines()
    out, routine = [], '(unit level)'
    for i, line in enumerate(src.splitlines(), 1):
        bare = line.split('//')[0]
        m = ROUTINE.match(bare)
        if m:
            routine = m.group(1)
        for m in ACC.finditer(bare):
            target, expr = m.group(1), m.group(2)
            if '+' not in expr:
                continue
            base = re.escape(target.split('[')[0])
            if not re.search(r'(^|[^\w.])' + base + r'([^\w]|$)', expr, re.I):
                continue                  # not an accumulate
            if kinds.get(target.split('[')[0].lower()) == 'char':
                continue                  # assigning INTO a Char is not the bug
            rest = re.sub(r'(^|[^\w.])' + base + r'([^\w]|$)', r'\1 \2', expr,
                          count=1, flags=re.I)
            why = char_operands(rest, kinds)
            if why:
                shown = original[i - 1].strip() if i <= len(original) else line.strip()
                out.append((i, routine, shown, ', '.join(sorted(set(why)))))
                break
    return out


def main():
    files = []
    for pat in SCAN:
        files += sorted(glob.glob(os.path.join(ROOT, *pat.split('/'))))
    bad = []
    for f in files:
        for h in scan(f):
            bad.append((os.path.relpath(f, ROOT).replace('\\', '/'),) + h)
    print("codepage check: %d units scanned" % len(files))
    if not bad:
        print("no char-into-string concatenation found.")
        return 0
    print()
    print("CHAR CONCATENATED INTO A CODEPAGE STRING -- bytes >= 128 are destroyed:")
    for rel, ln, routine, text, why in bad:
        print("  %s:%d  in %s" % (rel, ln, routine))
        print("      %s" % text)
        print("      character operand: %s" % why)
    print()
    print("  fix: append a one-character SLICE -- Copy(s, i, 1) -- or build the")
    print("       result by index into a preallocated string.")
    return 1


if __name__ == '__main__':
    sys.exit(main())
