rem ---------------------------------------------------------------
rem ConfigLib. Thirty-one registered functions, none of which had
rem ever been run by anything before this file: check-coverage.py
rem reported ConfigLib 0/31.
rem
rem A filename containing a separator is used as written, so the
rem scratch files stay under bin\ instead of landing in the user's
rem real configuration directory.
rem ---------------------------------------------------------------

f$ = "bin/p9b_cfg_a.ini"
g$ = "bin/p9b_cfg_b.ini"
file_delete(f$)
file_delete(g$)

test_case("config/open")
c@ = cfg_open@(f$)
assert_true(pnttonum(c@), "cfg_open@ answers a handle")
assert_eq(cfg_filename$(c@), f$, "the handle remembers its file")

test_case("config/string-roundtrip")
cfg_set@(c@, "User", "name", "Alice")
assert_eq(cfg_get$(c@, "User", "name", "nobody"), "Alice", "what went in comes back")
assert_eq(cfg_get$(c@, "User", "absent", "fallback"), "fallback", "a missing key answers the default")

test_case("config/default-section")
rem An empty section name means "General", so the s-suffixed calls and
rem the explicit ones are two spellings of the same place.
cfg_sets@(c@, "theme", "dark")
assert_eq(cfg_gets$(c@, "theme", "light"), "dark", "cfg_sets@ and cfg_gets$ agree")
assert_eq(cfg_get$(c@, "", "theme", "light"), "dark", "an empty section reaches the same key")

test_case("config/numbers")
cfg_setn@(c@, "Window", "width", 1024)
assert_eq(cfg_getn(c@, "Window", "width", 0), 1024, "an integer survives")
cfg_setn@(c@, "Audio", "volume", 0.75)
assert_near(cfg_getn(c@, "Audio", "volume", 0), 0.75, 0.0001, "so does a fraction")
assert_eq(cfg_getn(c@, "Audio", "absent", 42), 42, "a missing number answers the default")
cfg_setns@(c@, "runCount", 7)
assert_eq(cfg_getns(c@, "runCount", 0), 7, "the default section takes numbers too")

test_case("config/booleans")
cfg_setb@(c@, "Features", "darkMode", 1)
cfg_setb@(c@, "Features", "sound", 0)
assert_true(cfg_getb(c@, "Features", "darkMode", 0), "true survives")
assert_false(cfg_getb(c@, "Features", "sound", 1), "and so does false")
assert_true(cfg_getb(c@, "Features", "absent", 1), "a missing flag answers the default")
cfg_setbs@(c@, "firstRun", 1)
assert_true(cfg_getbs(c@, "firstRun", 0), "the default section takes flags too")

test_case("config/queries")
assert_true(cfg_exists(c@, "User", "name"), "cfg_exists finds a key it has")
assert_false(cfg_exists(c@, "User", "absent"), "and does not invent one")
assert_true(cfg_haskey(c@, "theme"), "cfg_haskey reads the default section")
assert_true(cfg_section_exists(c@, "User"), "cfg_section_exists finds a section")
assert_false(cfg_section_exists(c@, "Nowhere"), "and does not invent one")
assert_eq(cfg_keycount(c@, "Features"), 2, "cfg_keycount counts what was set")
assert_true(cfg_sectioncount(c@) - 3, "cfg_sectioncount counts the sections")

test_case("config/enumeration")
rem Both answer a newline-separated list.
secs$ = cfg_sections$(c@)
assert_true(instr(secs$, "User"), "cfg_sections$ names a section that exists")
keys$ = cfg_keys$(c@, "Window")
assert_true(instr(keys$, "width"), "cfg_keys$ names a key that exists")

test_case("config/persistence")
assert_true(cfg_modified(c@), "the handle knows it has unsaved changes")
cfg_save(c@)
assert_false(cfg_modified(c@), "and knows when it does not")
assert_true(file_exists(f$), "cfg_save writes the file")

d@ = cfg_open@(f$)
assert_eq(cfg_get$(d@, "User", "name", "nobody"), "Alice", "a second handle reads what the first wrote")

test_case("config/reload")
cfg_set@(c@, "User", "name", "Bob")
assert_eq(cfg_get$(c@, "User", "name", ""), "Bob", "the change is in memory")
cfg_reload@(c@)
assert_eq(cfg_get$(c@, "User", "name", ""), "Alice", "cfg_reload@ discards it for what is on disk")

test_case("config/deletion")
cfg_set@(c@, "Temp", "token", "secret")
assert_true(cfg_exists(c@, "Temp", "token"), "the key is there")
cfg_delete@(c@, "Temp", "token")
assert_false(cfg_exists(c@, "Temp", "token"), "cfg_delete@ removes it")

cfg_sets@(c@, "scratch", "x")
assert_true(cfg_haskey(c@, "scratch"), "the default-section key is there")
cfg_deletekey@(c@, "scratch")
assert_false(cfg_haskey(c@, "scratch"), "cfg_deletekey@ removes it")

cfg_section_delete@(c@, "Audio")
assert_false(cfg_section_exists(c@, "Audio"), "cfg_section_delete@ removes a whole section")

test_case("config/clear")
cfg_clear@(c@)
assert_eq(cfg_sectioncount(c@), 0, "cfg_clear@ empties the handle")

test_case("config/autosave")
rem With autosave on, a set reaches the disk without an explicit save.
a@ = cfg_open_auto@(g$)
assert_true(pnttonum(a@), "cfg_open_auto@ answers a handle")
cfg_sets@(a@, "written", "immediately")
assert_true(file_exists(g$), "the file appears without cfg_save")

b@ = cfg_open@(g$)
assert_eq(cfg_gets$(b@, "written", ""), "immediately", "and holds what was set")

rem The switch is reachable from BASIC as well as from the open call.
cfg_autosave@(a@, 0)
cfg_sets@(a@, "later", "value")
e@ = cfg_open@(g$)
assert_eq(cfg_gets$(e@, "later", "not yet"), "not yet", "autosave off keeps it in memory")
cfg_autosave@(a@, 1)
cfg_sets@(a@, "later", "value")
h@ = cfg_open@(g$)
assert_eq(cfg_gets$(h@, "later", "not yet"), "value", "autosave on writes it through")

test_case("config/path")
rem The platform's configuration directory. Its value differs per system,
rem so what is asserted is that there is one.
assert_true(len(cfg_path$()), "cfg_path$ answers a directory")

file_delete(f$)
file_delete(g$)
