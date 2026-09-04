#!/usr/bin/env python3
"""Coverage report for the Phosphor libraries: tests AND documentation.

Enumerates every built-in function registered in engine/libs and host/packages
(the authoritative source is each `Reg.Add('name:sig', ...)` / `Reg.AddHost(...)`
line), then checks whether each function's name is referenced by any test program
(tests/**/*.bas) or example. Prints a per-library tally and exits non-zero if any
function is uncovered.

A handful of built-ins are reached only through SYNTAX SUGAR, never by name -- an
`a@[i]` compiles to `arr_get`/`arr_set`, `s$[n]`/`s$[[n]]` to `strline$`/`strchar$`,
and a `[...]`/`{...}` literal to the json_*val@/json_*null@/json_array@/json_object@
builders. Those are exercised by every test that uses the sugar, so they are listed
in SUGAR_BACKED and counted as covered.

It also checks that every built-in appears in docs/function-reference.md, which calls
itself the complete catalog. That claim went stale silently once: eight dir_*/file_*
timestamp functions had never been listed, and four byte primitives plus two callfunc
spellings were added without it. A gate is cheaper than a promise.

Usage:  python scripts/coverage.py [--list]      (--list prints uncovered names)
"""
import re, glob, os, sys, collections

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Built-ins reached through syntax, never by name (see the module docstring).
SUGAR_BACKED = {
    'arr_get', 'arr_set',
    'strline$', 'strchar$',
    'json_array@', 'json_object@',
    'json_pushval@', 'json_pushnull@',
    'json_setval@', 'json_setnull@',
}

# Functions registered under computed names (a loop over a Names[] array) that the
# literal-string scan cannot see. Kept explicit so the enumeration stays complete.
COMPUTED = {
    'PhosphorCallLib.pas': ['callfunc', 'callfunc%', 'callfunc$', 'callfunc@', 'callfunc?'],
}

def registered_names(path):
    txt = open(path, encoding='utf-8', errors='ignore').read()
    names = set(m.group(1).lower()
                for m in re.finditer(r"\.Add(?:Host)?\(\s*'([^:']+):", txt))
    names |= set(n.lower() for n in COMPUTED.get(os.path.basename(path), []))
    return names

def load_corpus():
    text = ''
    for p in glob.glob(os.path.join(ROOT, 'tests', '**', '*.bas'), recursive=True) + \
             glob.glob(os.path.join(ROOT, 'examples', '*.bas')):
        text += open(p, encoding='utf-8', errors='ignore').read().lower()
    return text

def is_referenced(name, corpus):
    esc = re.escape(name)
    # a call `name(` or a bare token boundary (covers statements/args)
    return (re.search(r'(^|[^a-z0-9_$%@])' + esc + r'\s*\(', corpus) is not None or
            re.search(r'(^|[^a-z0-9_$%@])' + esc + r'(?![a-z0-9_$%@])', corpus) is not None)

def main():
    show = '--list' in sys.argv
    corpus = load_corpus()
    libs = sorted(glob.glob(os.path.join(ROOT, 'engine', 'libs', '*.pas'))) + \
           sorted(glob.glob(os.path.join(ROOT, 'host', 'packages', '*.pas')))
    total = covered = 0
    uncovered_all = []
    print(f"{'library':<26}{'fns':>5}{'covered':>9}{'gap':>5}")
    print('-' * 45)
    for lib in libs:
        names = registered_names(lib)
        if not names:
            continue
        cov = 0
        uncovered = []
        for n in sorted(names):
            if n in SUGAR_BACKED or is_referenced(n, corpus):
                cov += 1
            else:
                uncovered.append(n)
        total += len(names)
        covered += cov
        uncovered_all += [(os.path.basename(lib), n) for n in uncovered]
        flag = '' if not uncovered else '  <-- ' + ', '.join(uncovered)
        print(f"{os.path.basename(lib):<26}{len(names):>5}{cov:>9}{len(uncovered):>5}"
              + (flag if show else ''))
    print('-' * 45)
    pct = (100 * covered // total) if total else 0
    print(f"{'TOTAL':<26}{total:>5}{covered:>9}{total-covered:>5}")
    print(f"\ncoverage: {covered}/{total} = {pct}%  "
          f"({len(SUGAR_BACKED)} sugar-backed counted as covered)")
    rc = 0
    if uncovered_all:
        print()
        print("UNTESTED:")
        for lib, n in uncovered_all:
            print(f"  {lib}: {n}")
        rc = 1
    else:
        print("every registered function is exercised by a test.")

    # --- documentation gate ----------------------------------------------------
    # The reference calls itself the complete catalog; hold it to that.
    ref = os.path.join(ROOT, 'docs', 'function-reference.md')
    try:
        doc = open(ref, encoding='utf-8', errors='ignore').read().lower()
    except OSError:
        print()
        print("function-reference.md not found -- gate skipped")
        return rc
    all_names = set()
    for lib in libs:
        all_names |= registered_names(lib)
    undocumented = sorted(n for n in all_names if n not in doc)
    print()
    print(f"documented: {len(all_names) - len(undocumented)}/{len(all_names)}"
          f" in docs/function-reference.md")
    if undocumented:
        print("UNDOCUMENTED:")
        for n in undocumented:
            print(f"  {n}")
        rc = 1
    else:
        print("every registered function is in the reference.")
    return rc

if __name__ == '__main__':
    sys.exit(main())
