rem ---------------------------------------------------------------
rem RagLib. Despite the name it needs no network, no HTTP, no client
rem and no embedding: it is a LOCAL retrieval index over markdown
rem files, scored by tag and function name, and it needs nothing but
rem a folder.
rem
rem So this file builds its own knowledge base under bin\ -- two
rem documents with the YAML-style headers the index reads -- rebuilds
rem the index from them and asks questions of it. Nothing leaves the
rem machine and no model is involved.
rem
rem Ported from Plan9Basic's 33_rag.bas. Two adaptations, both proven
rem rather than assumed (see rag/lookup-by-name and rag/handles):
rem   * Phosphor's instr is 1-based and answers 0 when absent (the
rem     reference's was 0-based / -1), so a "does it contain X" check
rem     is instr(...) on its own and a "not present" check is 0.
rem   * function names carry Phosphor's handle suffix @ (button@),
rem     where the Delphi reference wrote #. The suffix is data the
rem     index matches on, so the front matter and the lookup agree.
rem ---------------------------------------------------------------

kb$ = "bin/p9b_kb"
if dir_exists(kb$) <> 0 then dir_delete(kb$, 1)
dir_create(kb$)

rem Two documents, deliberately about different things, so a query can
rem be seen to pick one and not the other.
d1$ = "---" + chr$(10)
d1$ = d1$ + "id: buttondoc" + chr$(10)
d1$ = d1$ + "title: Buttons" + chr$(10)
d1$ = d1$ + "category: library" + chr$(10)
d1$ = d1$ + "tags: button, click, gui" + chr$(10)
d1$ = d1$ + "functions: button@, button_text@, button_onclick@" + chr$(10)
d1$ = d1$ + "complexity: beginner" + chr$(10)
d1$ = d1$ + "platform: all" + chr$(10)
d1$ = d1$ + "---" + chr$(10)
d1$ = d1$ + "# Buttons" + chr$(10)
d1$ = d1$ + "A button is a control that answers a click." + chr$(10)
file_writealltext(kb$ + "/buttondoc.md", d1$)

d2$ = "---" + chr$(10)
d2$ = d2$ + "id: sounddoc" + chr$(10)
d2$ = d2$ + "title: Sound" + chr$(10)
d2$ = d2$ + "category: library" + chr$(10)
d2$ = d2$ + "tags: audio, sound, media" + chr$(10)
d2$ = d2$ + "functions: media_player@, media_play" + chr$(10)
d2$ = d2$ + "complexity: intermediate" + chr$(10)
d2$ = d2$ + "platform: all" + chr$(10)
d2$ = d2$ + "---" + chr$(10)
d2$ = d2$ + "# Sound" + chr$(10)
d2$ = d2$ + "A media player holds a track and plays it." + chr$(10)
file_writealltext(kb$ + "/sounddoc.md", d2$)

test_case("rag/build")
rem rag@ opens a base and loads whatever index is there. There is none
rem yet, so the first thing to do is build one from the documents.
r@ = rag@(kb$)
assert_true(pnttonum(r@), "rag@ answers a handle even with no index yet")

rag_rebuild@(r@)
assert_eq(rag_count(r@), 2, "rag_rebuild@ indexes both documents")
assert_true(rag_funccount(r@), "and the functions their headers name")

test_case("rag/retrieval")
rem The scoring is by tag and function name, so a question about one
rem subject has to bring back that document and not the other.
b$ = rag_retrieve$(r@, "how do I handle a button click")
assert_true(instr(b$, "button"), "a question about buttons retrieves the button document")

s$ = rag_retrieve$(r@, "how do I play a sound")
assert_true(instr(s$, "media"), "and a question about sound retrieves the other one")

test_case("rag/retrieval-shapes")
rem Three renderings of the same retrieval: plain text, JSON, and one
rem cut to fit a token budget.
j$ = rag_retrieve_json$(r@, "button click")
assert_true(len(j$), "rag_retrieve_json$ answers something")
jr@ = json_parse@(j$)
assert_true(pnttonum(jr@), "which parses as JSON")

rem Both documents here are two lines long, so every budget fits them whole
rem and the two answers agree. That is the honest thing to assert at this
rem size -- the budget only has something to cut when a document is bigger
rem than it, which is what rag/budget-is-honoured below sets up.
small$ = rag_retrieve_budget$(r@, "button click", 50)
big$ = rag_retrieve_budget$(r@, "button click", 5000)
assert_true(len(small$), "rag_retrieve_budget$ answers under a small budget")
assert_eq(len(small$), len(big$), "and the same under a large one, because this document fits in both")

test_case("rag/lookup-by-name")
rem A document can be fetched by its id, and a function looked up to
rem the document that declares it -- which is the index doing its job
rem rather than a search.
doc$ = rag_doc$(r@, "buttondoc")
assert_true(instr(doc$, "Buttons"), "rag_doc$ fetches a document by id")

rem A missing id answers the ERROR MESSAGE, not an empty string, and a
rem caller cannot tell it from a document whose content happens to
rem start that way. rag_doc$ keeps this in-band string channel from the
rem reference (Phosphor's separate rag_error reports handle/folder
rem faults, not a missing id), so the wart is worth knowing about.
assert_true(instr(rag_doc$(r@, "nosuchdoc"), "Error:"), "a missing id answers a message, not nothing")

rem These two take what they are named after: rag_functions$ takes
rem FUNCTION NAMES and rag_tags$ takes TAGS, each comma-separated, and
rem both answer the documents that declare them. Neither takes a
rem document id, which is the obvious misreading.
fn$ = rag_functions$(r@, "button_onclick@")
assert_true(instr(fn$, "Buttons"), "rag_functions$ finds the document that declares a function")

tg$ = rag_tags$(r@, "audio")
assert_true(instr(tg$, "Sound"), "rag_tags$ finds the document carrying a tag")
rem Phosphor's instr answers 0 when absent (the reference's was -1). The
rem base is proven, not assumed: a see-check-fail confirmed instr of a
rem missing substring is 0 here, not -1.
assert_eq(instr(tg$, "Buttons"), 0, "and not the one that does not")

test_case("rag/analysis-and-summary")
an$ = rag_analyze$(r@, "how do I handle a button click")
assert_true(len(an$), "rag_analyze$ explains what it made of a question")

sm$ = rag_summary$(r@)
assert_true(len(sm$), "rag_summary$ describes the base")
assert_true(instr(sm$, "2"), "naming how many documents are in it")

test_case("rag/budget-is-honoured")
rem A document far larger than the small budget, in a base of its own so the
rem counts asserted above are left alone.
rem
rem This pins a defect fixed on 2026-08-22 and the wrong diagnosis that went
rem with it. The budget looked ignored -- 10 tokens and 100000 tokens both
rem answered 111 characters -- and a comment here said so. It was not ignored.
rem Retrieve honoured it on the FIRST call and then wrote the truncated text
rem back into the document cache with ContentLoaded set, so every later
rem retrieve, whatever its budget, answered out of the shrunken copy. Asking
rem in the other order proved it: 6394 characters, then 111.
rem
rem Hence the two assertions. The first says the budget cuts. The second says
rem asking small first does not cost the caller the large answer afterwards --
rem which is the half that was broken, and the half a single-call test misses.
rem Phosphor caches the FULL content and truncates a local copy, so the cache
rem cannot be poisoned.
bigkb$ = "bin/p9b_kb_big"
if dir_exists(bigkb$) <> 0 then dir_delete(bigkb$, 1)
dir_create(bigkb$)

bd$ = "---" + chr$(10)
bd$ = bd$ + "id: bigdoc" + chr$(10)
bd$ = bd$ + "title: Buttons" + chr$(10)
bd$ = bd$ + "category: library" + chr$(10)
bd$ = bd$ + "tags: button, click, gui" + chr$(10)
bd$ = bd$ + "functions: button@, button_text@" + chr$(10)
bd$ = bd$ + "complexity: beginner" + chr$(10)
bd$ = bd$ + "platform: all" + chr$(10)
bd$ = bd$ + "---" + chr$(10)
bd$ = bd$ + "# Buttons" + chr$(10)
for bi = 1 to 120
  bd$ = bd$ + "A button is a control that answers a click, line " + str$(bi) + "." + chr$(10)
next
file_writealltext(bigkb$ + "/bigdoc.md", bd$)

big@ = rag@(bigkb$)
rag_rebuild@(big@)

rem Small budget first, deliberately -- that is the order that used to poison
rem the cache.
tight$ = rag_retrieve_budget$(big@, "button click", 10)
loose$ = rag_retrieve_budget$(big@, "button click", 100000)

if len(tight$) < len(loose$) then cut_ok = 1
assert_true(cut_ok, "a small budget answers less than a large one")
if len(loose$) > 5000 then full_ok = 1
assert_true(full_ok, "and the large one still answers the whole document after the small one")

rag_free(big@)
dir_delete(bigkb$, 1)

test_case("rag/handles")
rem The language lets a program fabricate a handle with pointer@(n).
rem Where Plan9Basic could only COMMENT on the refusal -- its validator
rem raised, so a running test could not provoke it without halting --
rem Phosphor makes the refusal a value: the registry refuses to follow
rem the fabricated address, rag_count answers 0, and rag_error reads the
rem reason. This is the round-3 handle discipline, now visible.
junk@ = pointer@(305419896)
assert_eq(rag_count(junk@), 0, "a fabricated handle answers 0, never dereferenced")
assert_eq(rag_error(), 1, "and the refusal is a value the program can read")
assert_eq(rag_count(r@), 2, "the real handle still answers")

test_case("rag/a query is UTF-8, so its words are codepoints and not bytes")
rem ExtractKeywords kept only ['a'..'z','0'..'9','_','#','$','@',' '] and
rem overwrote every OTHER BYTE with a space. Every byte of a multi-byte UTF-8
rem sequence is >= 128, so a Cyrillic, Greek, Chinese, Hebrew or Arabic word was
rem erased to nothing and an accented Latin word was cut at the accent. Keywords
rem are the sole input to three of the four scoring signals, so every document
rem scored below the relevance floor and rag_retrieve$ answered NOTHING for a
rem query in any non-Latin script -- while rag_tags$ found the same document by
rem the same word, which is how the index was proven to be holding it.
rem
rem This base is its own, so the counts asserted above are left alone, and its
rem documents are category `guide` rather than `library`: the library-hint signal
rem greps the RAW query and applies only to `library`, and a first probe with
rem that category appeared to work and hid all of this.
ukb$ = "bin/p9b_kb_utf8"
if dir_exists(ukb$) <> 0 then dir_delete(ukb$, 1)
dir_create(ukb$)

u1$ = "---" + chr$(10)
u1$ = u1$ + "id: zapiski" + chr$(10)
u1$ = u1$ + "title: Записки" + chr$(10)
u1$ = u1$ + "category: guide" + chr$(10)
u1$ = u1$ + "tags: записки, текст" + chr$(10)
u1$ = u1$ + "functions: zap_read" + chr$(10)
u1$ = u1$ + "---" + chr$(10)
u1$ = u1$ + "# Zapiski" + chr$(10)
u1$ = u1$ + "telo" + chr$(10)
file_writealltext(ukb$ + "/zap.md", u1$)

u2$ = "---" + chr$(10)
u2$ = u2$ + "id: conf" + chr$(10)
u2$ = u2$ + "title: Ajuste" + chr$(10)
u2$ = u2$ + "category: guide" + chr$(10)
u2$ = u2$ + "tags: configuração, botão" + chr$(10)
u2$ = u2$ + "functions: conf_set" + chr$(10)
u2$ = u2$ + "---" + chr$(10)
u2$ = u2$ + "# Ajuste" + chr$(10)
u2$ = u2$ + "corpo" + chr$(10)
file_writealltext(ukb$ + "/conf.md", u2$)

u@ = rag@(ukb$)
rag_rebuild@(u@)
assert_eq(rag_count(u@), 2, "both documents are indexed")

rem q$ builds the fragment rag_analyze$ renders for a one-word keyword list, so
rem the assertion reads the KEYWORDS and not the echoed query -- the echoed query
rem carries the same word in the same quotes and would pass with no keywords at all.
dq$ = chr$(34)
cyr$ = "записки"
kw1$ = dq$ + "keywords" + dq$ + ":[" + dq$ + cyr$ + dq$ + "]"
assert_true(instr(rag_tags$(u@, cyr$), "Zapiski"), "rag_tags$ finds the document by its exact Cyrillic tag, so the index holds the word")
assert_true(instr(rag_analyze$(u@, cyr$), kw1$), "and the query keeps the whole word as its one keyword")
assert_true(instr(rag_retrieve$(u@, cyr$), "Zapiski"), "so retrieval brings back the document that tag belongs to")

rem Portuguese degraded differently: "configuração" came out as "configura",
rem the accented tail destroyed and the leftover single letter dropped.
pt$ = "configuração"
kw2$ = dq$ + "keywords" + dq$ + ":[" + dq$ + pt$ + dq$ + "]"
assert_true(instr(rag_analyze$(u@, pt$), kw2$), "an accented Latin word survives whole rather than being cut at the accent")
assert_true(instr(rag_retrieve$(u@, pt$), "Ajuste"), "and retrieves the document carrying it as a tag")

rem THE OTHER DIRECTION, and it is why this fix classifies CODEPOINTS rather than
rem bytes. Keeping every byte >= 128 would make a no-break space a word
rem character, gluing the words on either side of it into one token: measured,
rem the two ids below came back as the single keyword "zapiski conf", which
rem matches neither id, and only one of the two documents was found. These two
rem assertions do not fail against the original defect -- they pin the answer
rem against the simpler repair, which is a different wrong one.
nbsp$ = bytestr$(194) + bytestr$(160)
kw3$ = dq$ + "keywords" + dq$ + ":[" + dq$ + "zapiski" + dq$ + ", " + dq$ + "conf" + dq$ + "]"
assert_true(instr(rag_analyze$(u@, "zapiski" + nbsp$ + "conf"), kw3$), "a no-break space separates two words rather than gluing them")
both$ = rag_retrieve$(u@, "zapiski" + nbsp$ + "conf")
assert_true(instr(both$, "Zapiski") > 0 and instr(both$, "Ajuste") > 0, "so both documents the two ids name come back")
assert_true(instr(rag_analyze$(u@, "zapiski conf"), kw3$), "and the ASCII space spelling of the same question is unchanged")

rag_free(u@)
dir_delete(ukb$, 1)

rag_free(r@)
dir_delete(kb$, 1)
