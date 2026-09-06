#!/usr/bin/env python3
"""Coverage report for the Phosphor libraries: tests AND documentation.

Enumerates every built-in function registered in engine/libs and host/packages
(the authoritative source is each `Reg.Add('name:sig', ...)` / `Reg.AddHost(...)`
line), then checks whether each function's name is referenced by any test program
(tests/**/*.bas) or example. Prints a per-library tally and exits non-zero if any
function is uncovered.

A handful of built-ins are reached only through SYNTAX SUGAR, never by name -- an
`a@[i]` compiles to `arr_get`/`arr_set@`, `s$[n]`/`s$[[n]]` to `strline$`/`strchar$`,
and a `[...]`/`{...}` literal to the json_*val@/json_*null@/json_array@/json_object@
builders. Those are exercised by every test that uses the sugar, so they are listed
in SUGAR_BACKED and counted as covered.

It also checks that every built-in appears in docs/function-reference.md, which calls
itself the complete catalog. That claim went stale silently once: eight dir_*/file_*
timestamp functions had never been listed, and four byte primitives plus two callfunc
spellings were added without it. A gate is cheaper than a promise.

TWO THINGS IT USED TO MISS, both of the same kind -- a check that reports clean
while seeing less than it claims:

  * eighteen registrations whose NAME IS COMPUTED (`Reg.Add(OptPaths[i] + ':', ...)`
    in PhosphorSysLib) were invisible to the literal-string scan, so every total on
    this page, and the README count it gates, was 18 short at 100%. The const array
    is now read; see CONST_STR_ARRAY.
  * a document naming a function WITHOUT its type suffix -- `arr_set` for
    `arr_set@` -- was excused as "a family shown as a prefix", which is the exact
    shape of every rename this project makes. See is_family().

Usage:  python scripts/coverage.py [--list]      (--list prints uncovered names)
"""
import re, glob, os, sys, collections

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Built-ins reached through syntax, never by name (see the module docstring).
SUGAR_BACKED = {
    'arr_get', 'arr_set@',
    'strline$', 'strchar$',
    'json_array@', 'json_object@',
    'json_pushval@', 'json_pushnull@',
    'json_setval@', 'json_setnull@',
}

# --- registrations whose NAME is computed ------------------------------------
# Two libraries register a family by walking a const array of spellings:
#
#     Names:    array[0..4]  of String = ('callfunc', 'callfunc%', ...);
#     OptPaths: array[0..17] of String = ('librarypath$', 'cachepath$', ...);
#     ...
#     Reg.AddHost(Names[s] + ':$', @f_calln);
#     Reg.Add(OptPaths[i] + ':', @t_emptypath);
#
# The literal-string scan above sees neither, because there is no literal name to
# see. The five callfunc spellings used to be listed by hand in a COMPUTED table
# and the EIGHTEEN optional-path names were not listed at all -- so every total on
# this page, and the README count this file gates, was 18 short while reporting
# 100%. They are real functions: tests/suite/25_sys.bas calls them and
# docs/libraries/sys.md documents them; only the enumeration could not see them.
#
# So the array is READ instead of transcribed. A nineteenth path added to OptPaths
# is counted the day it is added, which is the whole difference between a gate and
# a list somebody has to remember to update. A computed registration whose array
# cannot be found is reported (see UNRESOLVED) rather than skipped: silence is the
# failure this costs 18 names to learn.
CONST_STR_ARRAY = re.compile(
    r"(?is)\b([A-Za-z_]\w*)\s*:\s*array\s*\[[^\]]*\]\s*of\s+String\s*=\s*\((.*?)\)\s*;")
COMPUTED_REG = re.compile(
    r"\.Add(?:Host)?\(\s*([A-Za-z_]\w*)\s*\[[^\]]*\]\s*\+\s*'([^']*)'")

UNRESOLVED = []          # (file, array name) a computed registration names but the file does not declare

def registered_names(path):
    txt = open(path, encoding='utf-8', errors='ignore').read()
    names = set(m.group(1).lower()
                for m in re.finditer(r"\.Add(?:Host)?\(\s*'([^:']+):", txt))
    arrays = {m.group(1): re.findall(r"'((?:[^']|'')*)'", m.group(2))
              for m in CONST_STR_ARRAY.finditer(txt)}
    for m in COMPUTED_REG.finditer(txt):
        arr, tail = m.group(1), m.group(2)
        if arr not in arrays:
            entry = (os.path.basename(path), arr)
            if entry not in UNRESOLVED:
                UNRESOLVED.append(entry)
            continue
        # The literal that follows carries the rest of the spelling: ':' or ':$'
        # begins the ARGUMENT signature, so anything before it belongs to the name.
        for elem in arrays[arr]:
            names.add((elem + tail.split(':')[0]).lower())
    return names

def load_corpus():
    text = ''
    for p in glob.glob(os.path.join(ROOT, 'tests', '**', '*.bas'), recursive=True) + \
             glob.glob(os.path.join(ROOT, 'examples', '*.bas')):
        text += open(p, encoding='utf-8', errors='ignore').read().lower()
    return text

def lib_slug(path):
    """docs/libraries/<slug>.md for a library source.

    PhosphorStrLib.pas -> str ; PhosphorGuiCore.pas -> gui-core ;
    a GUI package -> gui-<name>, so a reader can tell which surface a page is."""
    base = os.path.basename(path)
    name = base[:-4]                       # drop .pas
    if name.startswith('Phosphor'):
        name = name[len('Phosphor'):]
    if name.endswith('Lib'):
        name = name[:-3]
    slug = re.sub(r'(?<!^)(?=[A-Z])', '-', name).lower()
    is_gui = os.sep + os.path.join('gui', 'libs') + os.sep in path
    if is_gui and not slug.startswith('gui'):
        slug = 'gui-' + slug
    return slug


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

    # --- per-library technical documentation -----------------------------------
    # The reference above is a catalogue of engine + package names. It says nothing
    # about the 426 GUI functions, and nothing anywhere about what a library is FOR
    # or how to use one. So each library carries its own page, and this holds every
    # page to its own library: a function that is registered and not described is a
    # function whose only documentation is its source.
    libdir = os.path.join(ROOT, 'docs', 'libraries')
    all_libs = libs + sorted(glob.glob(os.path.join(ROOT, 'host', 'gui', 'libs', '*.pas')))
    missing_pages = []
    undescribed = []
    described = 0
    lib_count = 0
    for lib in all_libs:
        names = registered_names(lib)
        if not names:
            continue
        lib_count += 1
        page = os.path.join(libdir, lib_slug(lib) + '.md')
        try:
            text = open(page, encoding='utf-8', errors='ignore').read().lower()
        except OSError:
            missing_pages.append((os.path.basename(lib), os.path.relpath(page, ROOT)))
            undescribed.extend((lib_slug(lib), n) for n in sorted(names))
            continue
        for n in sorted(names):
            if n in text:
                described += 1
            else:
                undescribed.append((lib_slug(lib), n))
    print()
    print(f"library pages: {described}/{described + len(undescribed)} names described"
          f" across {lib_count} libraries")
    if missing_pages:
        print("LIBRARIES WITH NO PAGE:")
        for src, page in missing_pages:
            print(f"  {src:<28} expected {page}")
        rc = 1
    if undescribed:
        print(f"NAMES NOT DESCRIBED IN THEIR LIBRARY PAGE ({len(undescribed)}):")
        shown = undescribed if show else undescribed[:20]
        for slug, n in shown:
            print(f"  {slug:<16} {n}")
        if not show and len(undescribed) > 20:
            print(f"  ... and {len(undescribed) - 20} more (--list to see them all)")
        rc = 1
    if not missing_pages and not undescribed:
        print("every library has a page, and every function it registers is on it.")

    # --- the guided tour's name table -----------------------------------------
    # language-reference.md carries a "standard library" map whose last column
    # names a few functions per area. Seven of them did not exist -- config@,
    # getenv$, dateadd and friends -- so a reader who copied one out of the table
    # got "unknown function" at run time. The names in that column are explicitly
    # function names, which makes them checkable; the rest of the prose is not.
    lang = os.path.join(ROOT, 'docs', 'language-reference.md')
    try:
        rows = open(lang, encoding='utf-8', errors='ignore').read().splitlines()
    except OSError:
        return rc
    missing = []
    inmap = False
    for line in rows:
        # only the map itself, found by its own header -- an operator table has the
        # same shape and its cells are not function names
        if line.replace(' ', '').startswith('|Area|Whatyouget|Afewnames|'):
            inmap = True
            continue
        if inmap and not line.strip().startswith('|'):
            inmap = False
        if not inmap or line.count('|') < 4:
            continue
        cols = [c.strip() for c in line.strip().strip('|').split('|')]
        if len(cols) != 3 or not cols[2].startswith('`'):
            continue
        for m in re.finditer(r'`([a-z_][a-z_0-9]*[$@]?)`', cols[2]):
            nm = m.group(1)
            if nm.endswith('_*') or nm in all_names:
                continue
            # a family shown as a prefix, e.g. path_* -- accept if anything matches
            if any(x.startswith(nm) for x in all_names):
                continue
            missing.append((nm, cols[0]))
    print()
    if missing:
        print("NAMED IN THE LIBRARY MAP BUT NOT REGISTERED:")
        for nm, area in missing:
            print(f"  {nm}  (row: {area})")
        rc = 1
    else:
        print("every name in the library map is a real function.")

    # --- counts stated in prose ------------------------------------------------
    # A number in a sentence is as checkable as a name in a table, and it went
    # stale in exactly the same way: README claimed "nine opt-in host packages"
    # when there were six, and architecture.md "20 isolated packages under
    # host/gui/libs/" when there were 17. Both were written true and neither was
    # ever re-measured -- nothing was watching, so nothing said.
    #
    # Only these three claims are checked. Each is unambiguous and each has ONE
    # mechanical source of truth; the rest of the prose is not checkable and is
    # not pretended to be. Number words are accepted so a sentence can read like
    # a sentence. A claim the gate can no longer FIND is also a failure: silently
    # checking nothing is the failure mode this whole file exists to avoid.
    WORDS = {'zero': 0, 'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5,
             'six': 6, 'seven': 7, 'eight': 8, 'nine': 9, 'ten': 10,
             'eleven': 11, 'twelve': 12}

    def as_int(tok):
        low = tok.lower()
        return WORDS[low] if low in WORDS else int(tok)

    def gui_names():
        names = set()
        for f in glob.glob(os.path.join(ROOT, 'host', 'gui', 'libs', '*.pas')):
            names |= registered_names(f)
        return names

    def registered_packages(*parts):
        # One Register*Funcs procedure per package. It appears in the interface
        # and again in the implementation, so count DISTINCT names.
        names = set()
        for f in glob.glob(os.path.join(ROOT, *parts)):
            txt = open(f, encoding='utf-8', errors='ignore').read()
            names |= set(re.findall(r'^procedure\s+(Register\w+Funcs)\s*\(',
                                    txt, re.M))
        return len(names)

    NUM = r'([0-9]+|[A-Za-z]+)'
    claims = [
        ('README.md',
         NUM + r'\s+built-in\s+functions',
         len(all_names),
         'built-in functions'),
        ('README.md',
         NUM + r'\s+opt-in host packages',
         registered_packages('host', 'packages', '*.pas'),
         'opt-in host packages'),
        ('docs/architecture.md',
         NUM + r'\s+isolated packages\s+under `host/gui/libs/`',
         registered_packages('host', 'gui', 'libs', '*.pas'),
         'GUI packages under host/gui/libs'),
        # README counted the engine in NAMES (682) and the GUI in registry ENTRIES
        # (321) on the same page. Both are now names, and this keeps them that way.
        ('README.md',
         NUM + r'\s+LCL GUI functions',
         len(gui_names()),
         'LCL GUI functions'),
    ]
    # --- the reverse direction: a name a DOCUMENT calls must exist -------------
    # Everything above checks registered -> documented. Nothing checked
    # documented -> registered, so a page could call a function that was renamed or
    # never built and every gate stayed green. That happened in five documents at
    # once, and three of the cases ABORT the reader's program: docs/decisions.md
    # advertised crt_gotoxy/crt_color/crt_clear, none of which exist under those
    # names, and function-reference.md documented narr_set@/sarr_set@/dict_clear@
    # as answering a handle when they answer the value. (dict_clear@ was made to
    # answer the dict on 2026-09-06, so its @ is true now; the other two still
    # answer the value written, and the page says so.)
    #
    # The signal is the CALL FORM -- a backticked `name(` beginning with a
    # lowercase letter. A variable is never followed by an open parenthesis, so
    # example code does not trip it, which is what makes this a gate rather than a
    # list of warnings to ignore.
    every = set(all_names)
    for f in glob.glob(os.path.join(ROOT, 'host', 'gui', 'libs', '*.pas')):
        every |= registered_names(f)
    # Hosts register functions too, and a document may legitimately name one: the
    # http test host adds http_get_via$ so a fallback can be proven without a real
    # network, and roadmap-phase3 says so correctly. Scanning only units made that
    # read as a ghost -- and a gate that cries wolf is a gate people learn to skip.
    for pat in (('host', 'console', '*.lpr'), ('host', 'gui', '*.lpr'),
                ('host', 'packages', '*.lpr'), ('host', 'embed', '*.lpr'),
                ('tests', '*.lpr')):
        for f in glob.glob(os.path.join(ROOT, *pat)):
            every |= registered_names(f)

    # A family shown as a PREFIX -- `path_*`, `sqlite_`, `checklist_` -- is a real
    # way to name a group in prose, and both scans below used to excuse one with
    # "some registered name starts with this". That is too generous by exactly one
    # character, and the character it gets wrong is the TYPE SUFFIX -- which is how
    # this project renames a function. 2026-09-06 moved arr_set, form_show,
    # button_click, bitbtn_click and speedbutton_click to their `@` spellings in one
    # commit; `arr_set@` starts with `arr_set`, so every page still saying `arr_set`
    # was excused as "a family". That is the shape a reader is most likely to copy
    # and least likely to doubt, and it was the one shape the gate could not see.
    #
    # A family prefix continues at a WORD boundary: the `_` that starts the next
    # word, or the `*` the document writes itself. `name` + `$@%?` is not a family;
    # it is one function spelled wrong.
    def is_family(nm):
        return nm.endswith('_') or any(x.startswith(nm + '_') for x in every)

    # Names a document writes ON PURPOSE that are not functions. Each is here for a
    # stated reason, not to silence a failure: a template placeholder, a handler
    # shape the PROGRAM defines, a host-supplied example, or a name a plan document
    # proposes for work not yet built.
    DELIBERATE = {
        # gui-components.md's uniform-surface table: x is the placeholder for any
        # control, which is the whole point of that table
        'x@', 'x_prop', 'x_prop$', 'x_prop@', 'x_onevent@', 'x_onevent$',
        'x_verb@', 'x_free',
        # handler SHAPES: the program writes these, the library only calls them
        'on_key', 'on_press', 'on_mouse', 'on_move', 'on_wheel', 'on_close',
        'on_click', 'on_change', 'on_query', 'on_timer',
        # embedding.md's worked example of a function the HOST registers
        'host_discount',
        # roadmap-phase2.md's placeholder for a per-library error slot it rejected
        'xxx_error', 'xxx_clearerror',
        # roadmap-net.md proposes names for work that does not exist yet, which is
        # what a roadmap is for
        'server_url_https$',
        # THE WRONG SPELLING, QUOTED IN ORDER TO CALL IT WRONG. A page is allowed to
        # name what a function is NOT called -- that is how a rename is explained --
        # and each of these sits next to the right spelling in the same sentence:
        #   libraries/buffer.md   "the brief wrote `buffer_new(1024)` ... the
        #                          constructor is `buffer_new@`"
        #   libraries/rag.md      "suffix included (`button_onclick@`, not
        #                          `button_onclick`)"
        #   libraries/gui-edit.md "there is no `spinedit_min`/`spinedit_max` to read
        #                          them back"
        'buffer_new', 'button_onclick', 'spinedit_min', 'spinedit_max',
    }

    # --- known-stale, recorded, owned by a page this script may not edit --------
    # DATED 2026-09-06. Each entry is a real finding of the widened rule above: a
    # document naming a function by a spelling the registry lost when that name
    # gained its type suffix. The fix is a one-word edit in a .md file; this file
    # gates, it does not write documentation.
    #
    # This is a BACKLOG, not an excuse list, and it is built so it can only shrink:
    #   * every entry is PRINTED on every run -- nothing here is quiet;
    #   * an entry that no longer occurs FAILS, so a page that gets fixed forces the
    #     line to be deleted, exactly like check-seams.py's EXEMPT;
    #   * a NEW stale mention matches no entry and fails on the spot, which is the
    #     property the gate did not have at all before today.
    # The end state is an empty table, and then no table.
    PENDING_NAMES = {
        ('docs/dev-agent-playbook.md', 'arr_set'): 'now arr_set@',
        ('docs/function-reference.md', 'arr_set'): 'now arr_set@',
        ('docs/roadmap.md', 'arr_set'): 'now arr_set@',
        ('docs/libraries/array.md', 'arr_set'): 'now arr_set@',
        ('docs/gui-components.md', 'button_click'): 'now button_click@',
        ('docs/gui-components.md', 'control_anchors'): 'now control_anchors$ / control_anchors@',
        ('docs/roadmap-phase2.md', 'button_click'): 'now button_click@',
        ('docs/roadmap-phase2.md', 'button_caption'): 'now button_caption$ / button_caption@',
        ('docs/roadmap-phase2.md', 'form_show'): 'now form_show@',
        ('docs/libraries/gui-button.md', 'button_click'): 'now button_click@; the sentence also still SAYS these are registered without a suffix, which needs rewording, not renaming',
        ('docs/libraries/gui-button.md', 'bitbtn_click'): 'now bitbtn_click@; same sentence',
        ('docs/libraries/gui-button.md', 'speedbutton_click'): 'now speedbutton_click@; same sentence',
        ('docs/libraries/gui-grid.md', 'button_click'): 'now button_click@',
        ('docs/libraries/gui-control.md', 'form_show'): 'now form_show@',
        ('docs/libraries/gui-form.md', 'form_show'): 'now form_show@; the Notes bullet also still says the name is unsuffixed, which needs rewording',
        ('docs/libraries/gui-menu.md', 'form_show'): 'now form_show@',
    }

    # A prose count known to be stale, pinned to BOTH numbers so the entry stops
    # matching the moment either the document or the registry changes -- which is
    # the point: fixing the document makes this gate FAIL and name the line to
    # delete, so the backlog cannot be quietly forgotten.
    #
    # README's "built-in functions" was the only entry, recorded when reading the
    # eighteen computed sys-path registrations moved the true total from 697 to
    # 715. The README was corrected in the same integration, so the entry is gone
    # and the ratchet did exactly what it was built to do.
    PENDING_COUNTS = {}

    # Names the LANGUAGE provides, which the registry therefore does not hold: the
    # compiler resolves these itself, so they are real and callable and absent here.
    LANGUAGE = {
        'not', 'and', 'or', 'mod',
        'eof', 'lof', 'loc', 'input$', 'print', 'println', 'input', 'line',
        'open', 'close', 'seek', 'swap', 'dim', 'sdim', 'pdim', 'data', 'read',
        'restore', 'gosub', 'return', 'error', 'resume', 'end', 'stop', 'rem',
        'function', 'endfunction', 'sub', 'endsub', 'let', 'const', 'local',
        'width', 'using', 'assert_eq', 'assert_true', 'assert_false', 'assert_near',
        'assert_int', 'assert_add_overflows', 'test_case', 'probe_new_a',
        'probe_new_b', 'probe_is_handle', 'probe_is_a', 'probe_is_b', 'probe_free',
        'probe_count', 'pointer',
    }

    docfiles = [os.path.join(ROOT, 'README.md')] + \
               sorted(glob.glob(os.path.join(ROOT, 'docs', '*.md'))) + \
               sorted(glob.glob(os.path.join(ROOT, 'docs', 'libraries', '*.md')))

    def scannable(txt):
        # The playbook's retrospective log is DATED HISTORY, and a record of a past
        # mistake has to be able to name it: the round-23 entry explains that
        # decisions.md advertised crt_gotoxy/crt_color/crt_clear, which is exactly a
        # list of names that must not exist. Gating that would forbid writing down
        # what went wrong. Sections 0-5 above the log are NORMATIVE and stay gated.
        marker = '## Retrospective log'
        i = txt.find(marker)
        return txt if i < 0 else txt[:i]
    # Statement keywords the compiler resolves itself. `if (`, `while (` and
    # `print (` are not calls, and a gate that reported them would be one nobody
    # reads. Kept short on purpose: anything not here has to be a real function.
    KEYWORDS = {
        'if', 'elseif', 'while', 'until', 'for', 'select', 'case', 'print',
        'println', 'return', 'and', 'or', 'not', 'mod', 'input', 'line',
        'open', 'close', 'write', 'read', 'data', 'dim', 'let', 'goto',
        'gosub', 'on', 'error', 'resume', 'end', 'function', 'sub', 'to',
        'step', 'then', 'else', 'do', 'loop', 'wend', 'next', 'using', 'as',
    }

    def fenced_blocks(txt):
        """Each ```basic block, with the names it declares itself.

        ONLY basic blocks. A shell command, a directory tree or a Pascal snippet
        is not Phosphor code, and reading one as Phosphor reports every English
        word followed by a parenthesis -- a gate that cries wolf is a gate people
        learn to skip.

        The FIRST WORD of the fence decides, not the whole fence: check-examples.py
        marks a syntax summary ```basic notation to be excused from compiling, and
        a block excused from compiling is not excused from naming real functions."""
        out = []
        lines = txt.splitlines()
        i = 0
        while i < len(lines):
            fence = lines[i].lstrip()
            if fence.startswith('```') and fence[3:].strip().lower().split(' ')[0] == 'basic':
                j = i + 1
                body = []
                while j < len(lines) and not lines[j].lstrip().startswith('```'):
                    body.append(lines[j])
                    j += 1
                block = '\n'.join(body)
                own = set(re.findall(r'(?im)^\s*(?:function|sub)\s+([a-z][a-z0-9_]*[$@%?]?)',
                                     block))
                out.append((i + 2, body, {o.lower() for o in own}))
                i = j
            i += 1
        return out

    ghosts = []
    for df in docfiles:
        try:
            txt = open(df, encoding='utf-8', errors='ignore').read()
        except OSError:
            continue
        rel = os.path.relpath(df, ROOT).replace('\\', '/')
        for lineno, line in enumerate(scannable(txt).splitlines(), 1):
            for m in re.finditer(r'`([a-z][a-z0-9_]*[$@%?]?)\s*\(', line):
                nm = m.group(1)
                base = nm.rstrip('?')
                if nm in every or nm.lower() in every:
                    continue
                if base in LANGUAGE or nm in LANGUAGE:
                    continue
                if nm in DELIBERATE or base in DELIBERATE:
                    continue
                # a family shown as a prefix, e.g. `path_*(`
                if is_family(nm):
                    continue
                ghosts.append((rel, lineno, nm))
    # A name written WITHOUT parentheses, under a prefix the registry really uses.
    # This is the shape the call-form rule cannot see, and the one that produced the
    # worst instance: docs/decisions.md advertised `crt_gotoxy`, `crt_color` and
    # `crt_clear` when the only registered crt_ names are crt_init and crt_done.
    prefixes = set()
    for n in every:
        u = n.find('_')
        if u > 0:
            prefixes.add(n[:u + 1])
    for df in docfiles:
        try:
            txt = open(df, encoding='utf-8', errors='ignore').read()
        except OSError:
            continue
        rel = os.path.relpath(df, ROOT).replace('\\', '/')
        for lineno, line in enumerate(scannable(txt).splitlines(), 1):
            for m in re.finditer(r'`([a-z][a-z0-9]*_[a-z0-9_]*[$@%?]?)`', line):
                nm = m.group(1)
                if nm in every or nm in DELIBERATE or nm in LANGUAGE:
                    continue
                u = nm.find('_')
                if nm[:u + 1] not in prefixes:
                    continue          # not a family this project registers
                if nm.endswith('_*') or is_family(nm):
                    continue          # a family shown as a prefix
                ghosts.append((rel, lineno, nm))

    print()
    # ...and the same question asked INSIDE the code blocks, where a reader copies
    # from. A call there needs no backtick, so the name is taken bare.
    for df in docfiles:
        try:
            txt = open(df, encoding='utf-8', errors='ignore').read()
        except OSError:
            continue
        rel = os.path.relpath(df, ROOT).replace('\\', '/')
        for first, body, own in fenced_blocks(scannable(txt)):
            for off, line in enumerate(body):
                # A comment and a string literal are not code: a println of
                # "cheese (nice)" is not a call to cheese.
                code = re.sub(r'"(?:[^"]|"")*"', '""', line)
                code = re.split(r"(?i)(?:^|\s)rem(?:\s|$)", code)[0]
                # The apostrophe is a comment too -- the language accepts both,
                # and docs/language-reference.md's quick-reference block is written
                # entirely in that style.
                code = code.split("'")[0]
                for m in re.finditer(r'(?<![`\w$@%?.])([a-z][a-z0-9_]*[$@%?]?)\s*\(', code):
                    nm = m.group(1)
                    low = nm.lower()
                    if low in KEYWORDS or low in own:
                        continue
                    if nm in every or low in every:
                        continue
                    if nm in DELIBERATE or low in DELIBERATE:
                        continue
                    if nm in LANGUAGE or low in LANGUAGE:
                        continue
                    ghosts.append((rel, first + off, nm))

    # Split what was found into what is NEW and what the backlog already records.
    # Every recorded one is still printed -- the point of writing them down is that
    # they stay visible, not that they go quiet.
    pending_seen = collections.defaultdict(list)
    fresh = []
    for rel, lineno, nm in ghosts:
        if (rel, nm) in PENDING_NAMES:
            pending_seen[(rel, nm)].append(lineno)
        else:
            fresh.append((rel, lineno, nm))
    if fresh:
        print("CALLED IN A DOCUMENT BUT NOT REGISTERED:")
        for rel, lineno, nm in fresh:
            print(f"  {rel}:{lineno}: {nm}")
        rc = 1
    else:
        print("every function a document calls is a real function"
              + (", apart from the recorded backlog below." if PENDING_NAMES
                 else "."))
    if PENDING_NAMES:
        mentions = sum(len(v) for v in pending_seen.values())
        docs_touched = len({rel for rel, _ in pending_seen})
        print(f"KNOWN-STALE NAMES STILL IN THE DOCUMENTATION "
              f"({mentions} mentions across {docs_touched} documents, recorded "
              f"2026-09-06, each a one-word edit):")
        for (rel, nm), lines in sorted(pending_seen.items()):
            where = ','.join(str(x) for x in lines)
            print(f"  {rel}:{where}: {nm} -- {PENDING_NAMES[(rel, nm)]}")
        gone = sorted(set(PENDING_NAMES) - set(pending_seen))
        if gone:
            print("BACKLOG ENTRIES THAT NO LONGER OCCUR -- delete them from "
                  "PENDING_NAMES in scripts/coverage.py:")
            for rel, nm in gone:
                print(f"  {rel}: {nm}")
            rc = 1

    print()
    bad = []
    pending_counts_seen = set()
    for relpath, pat, actual, what in claims:
        try:
            txt = open(os.path.join(ROOT, relpath), encoding='utf-8',
                       errors='ignore').read()
        except OSError:
            bad.append(f"{relpath}: not found, so its '{what}' claim is unchecked")
            continue
        m = re.search(pat, txt)
        if m is None:
            bad.append(f"{relpath}: the '{what}' claim is gone or reworded -- "
                       f"this gate is no longer checking it")
            continue
        try:
            claimed = as_int(m.group(1))
        except ValueError:
            bad.append(f"{relpath}: '{m.group(1)}' is not a number ({what})")
            continue
        if claimed != actual:
            if PENDING_COUNTS.get((relpath, what)) == (claimed, actual):
                pending_counts_seen.add((relpath, what))
                continue
            bad.append(f"{relpath}: claims {m.group(1)} {what}, there are {actual}")
    if bad:
        print("COUNTS STATED IN PROSE THAT ARE NO LONGER TRUE:")
        for b in bad:
            print(f"  {b}")
        rc = 1
    else:
        print("every count stated in prose matches what is registered"
              + (", apart from the recorded one below." if PENDING_COUNTS else "."))
    for (relpath, what), (claimed, actual) in sorted(PENDING_COUNTS.items()):
        if (relpath, what) in pending_counts_seen:
            print(f"KNOWN-STALE COUNT (recorded 2026-09-06): {relpath} says "
                  f"{claimed} {what}, there are {actual} -- reading the eighteen "
                  f"computed sys-path registrations is what moved it")
        else:
            print(f"BACKLOG ENTRY THAT NO LONGER APPLIES -- delete "
                  f"('{relpath}', '{what}') from PENDING_COUNTS in "
                  f"scripts/coverage.py")
            rc = 1

    # --- the enumeration's own honesty ----------------------------------------
    # Everything above is measured against `registered_names`, so a registration
    # that function cannot read makes every number on this page quietly wrong --
    # which is exactly what happened to eighteen of them. Two things are checked
    # here: a computed registration whose array could not be found, and a
    # SUGAR_BACKED name that is no longer registered under that spelling (the
    # compiler emits `arr_set@` now, and a set entry reading `arr_set` excuses a
    # function that does not exist while the one that does goes unexcused).
    print()
    if UNRESOLVED:
        print("COMPUTED REGISTRATIONS THIS SCRIPT COULD NOT READ:")
        for base, arr in UNRESOLVED:
            print(f"  {base}: Reg.Add({arr}[i] + ...) -- no `const {arr}: array[..] "
                  f"of String = (...)` in that file, so its names are not counted")
        rc = 1
    stale_sugar = sorted(n for n in SUGAR_BACKED if n not in all_names)
    if stale_sugar:
        print("SUGAR_BACKED NAMES THAT ARE NOT REGISTERED:")
        for n in stale_sugar:
            print(f"  {n} -- renamed or removed; the entry excuses nothing now")
        rc = 1
    if not UNRESOLVED and not stale_sugar:
        print("the enumeration reads every registration, computed ones included.")
    return rc

if __name__ == '__main__':
    sys.exit(main())
