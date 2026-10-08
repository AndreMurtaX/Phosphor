rem ---------------------------------------------------------------
rem DICTIONARIES, JSON AND CONFIGS CAN BE FREED (2026-10-08).
rem
rem Until this date nothing in the language freed a dictionary, a JSON
rem value or a config: each lived until the run ended, so under a host's
rem MaxHandles a loop that made one per pass was refused at the ceiling
rem even when it kept only the last. dict_free, json_free and cfg_free
rem give one back.
rem
rem Every expected value comes from the rule the three share with
rem strings_free and buffer_free -- LENIENT: 1 when this call freed the
rem handle, 0 for one that is stale, already freed, or of another kind,
rem so freeing twice is answered and never raised -- and from what each
rem frees:
rem   * a pdict@ holds handles' ids, not the handles: they outlive it;
rem   * a JSON document goes with every view borrowed into it (json_get@,
rem     json_item@, json_path@) and with no other document's, and freeing
rem     a view frees only that view;
rem   * a config is discarded, never saved: freeing is not cfg_save.
rem A handle used after it is freed fails with its library's own "not a
rem valid ... handle", caught here and read back.
rem
rem THE ERROR TRAP IS ARMED ONLY AROUND A STATEMENT EXPECTED TO FAIL. Armed
rem for the whole file, an assertion whose own argument raised was skipped
rem by `resume next` -- neither passed nor failed -- and a mutation that
rem freed another document's view passed the first draft of this file so.
rem ---------------------------------------------------------------

raised = 0
msg$ = ""

test_case("free/dict")
d@ = dict@()
d@ = dict_set@(d@, "k", 1)
assert_eq(dict_free(d@), 1, "a dictionary is freed")
assert_eq(dict_free(d@), 0, "and a second free answers 0, it does not raise")
raised = 0
on error goto trapped
x = dict_count(d@)
on error goto 0
assert_eq(raised, 1, "a freed dictionary cannot be used")
assert_eq(msg$, "not a valid dictionary handle", "and says so in its own words")
s@ = sdict@()
assert_eq(dict_free(s@), 1, "an sdict@ is freed by the same name")
l@ = strings@()
p@ = pdict@()
p@ = dict_set@(p@, "list", l@)
assert_eq(dict_free(p@), 1, "a pdict@ is freed")
assert_eq(strings_count(l@), 0, "and the list it held is still there: it held the id")
assert_eq(dict_free(l@), 0, "dict_free leaves a handle of another kind alone")
assert_eq(strings_free(l@), 1, "which is still live for its own free")

test_case("free/json")
q$ = chr$(34)
doc@ = json_parse@("[{" + q$ + "n" + q$ + ":1},{" + q$ + "n" + q$ + ":2}]")
other@ = json_parse@("[{" + q$ + "n" + q$ + ":5}]")
ov@ = json_item@(other@, 1)
one@ = json_item@(doc@, 1)
two@ = json_item@(doc@, 2)
assert_eq(json_free(one@), 1, "a view is freed")
assert_eq(json_len(doc@), 2, "and the document it was borrowed from is untouched")
assert_eq(json_getn(two@, "n"), 2, "and so is another view of that document")
assert_eq(json_free(doc@), 1, "the document is freed")
assert_eq(json_free(two@), 0, "and took its view with it: there is nothing left to free")
raised = 0
on error goto trapped
x = json_getn(two@, "n")
on error goto 0
assert_eq(raised, 1, "a view of a freed document cannot be used")
assert_eq(msg$, "not a valid json handle", "and says so")
assert_eq(json_free(doc@), 0, "a second free of the document answers 0")
assert_eq(json_getn(ov@, "n"), 5, "and a view into ANOTHER document is still that document's")
k@ = dict@()
assert_eq(json_free(k@), 0, "json_free leaves a handle of another kind alone")
assert_eq(dict_free(k@), 1, "which its own free still takes")
c@ = json_object@()
assert_eq(json_free(d@), 0, "json_free leaves a stale handle alone")
assert_eq(json_free(c@), 1, "and a constructed object is a document too")

test_case("free/cfg")
p$ = "bin/p9b_cfg_free.ini"
if fileexists(p$, 0) <> 0 then x = kill(p$)
g@ = cfg_open@(p$)
g@ = cfg_set@(g@, "s", "k", "v")
assert_eq(cfg_free(g@), 1, "a config is freed")
assert_eq(fileexists(p$, 0), 0, "and what was not saved is discarded, not written")
assert_eq(cfg_free(g@), 0, "a second free answers 0")
raised = 0
on error goto trapped
x = cfg_keycount(g@, "s")
on error goto 0
assert_eq(raised, 1, "a freed config cannot be used")
assert_eq(msg$, "not a valid config handle", "and says so")
h@ = dict@()
assert_eq(cfg_free(h@), 0, "cfg_free leaves a handle of another kind alone")
assert_eq(dict_free(h@), 1, "which its own free still takes")
end

trapped:
raised = 1
msg$ = errmsg$()
resume next
