rem ---------------------------------------------------------------
rem WHATEVER A SETTER ACCEPTS READS BACK IDENTICALLY AFTER A SAVE AND
rem A RELOAD, AND NOTHING ELSE IN THE FILE CHANGES (2026-10-09, round 2
rem of the adversarial loop).
rem
rem That is the property the config library's refusals exist for
rem (75_config_lines: a set that could not be read back is refused, not
rem written), and it was enforced as a LIST of shapes someone had thought
rem of. The round found one the list missed: a key beginning "[" with a
rem value holding "]" and then a comment character -- "[k" = "v] ;c" is
rem written as the line "[k=v] ;c", which the reader takes for a section
rem header with a comment after it. The set was accepted; after a reload
rem the key was gone, a section named "k=v" had appeared, and every key
rem after it in its section now belonged to that section.
rem
rem So the property is swept, not listed. Every key and every value below
rem is GENERATED from an alphabet of the characters an .ini line gives a
rem meaning to -- "[", "]", ";", "#", "=", a blank, a tab, a double quote,
rem CR, LF, NUL, a backslash, an accented letter, a lone byte 255 that is
rem no UTF-8 at all, and one plain letter -- in every combination up to a
rem length, and each pair is set between two neighbour keys in a section
rem of its own. Then the file is saved, a SECOND handle opens it, and for
rem every pair the setter accepted:
rem   * the value reads back byte for byte under the same key;
rem   * both neighbours read back unchanged, and the section holds exactly
rem     three keys -- nothing was swallowed, nothing was added;
rem and for every pair it refused, the section holds the two neighbours
rem only. The section count of the reloaded file is the number of sections
rem written, so a line read as a header shows up there too.
rem
rem Refusing everything would satisfy that, so the last case pins shapes
rem that MUST be accepted -- each the kind of value a refusal written too
rem broadly would catch. The expectations are the property itself and the
rem file text the program wrote; none was read off a run.
rem ---------------------------------------------------------------

function tok$(i)
  if i = 1 then return "["
  if i = 2 then return "]"
  if i = 3 then return ";"
  if i = 4 then return "#"
  if i = 5 then return "="
  if i = 6 then return " "
  if i = 7 then return chr$(9)
  if i = 8 then return chr$(34)
  if i = 9 then return chr$(13)
  if i = 10 then return chr$(10)
  if i = 11 then return chr$(0)
  if i = 12 then return chr$(92)
  if i = 13 then return chr$(233)
  if i = 14 then return bytestr$(255)
  return "k"
endfunction

rem Every string of length 0, 1 or 2 over the fifteen tokens: index 0 is
rem "", 1..15 one token, 16..240 two.
function s2$(i)
  if i = 0 then return ""
  if i <= 15 then return tok$(i)
  return tok$(int((i - 16) / 15) + 1) + tok$((i - 16) mod 15 + 1)
endfunction

rem Every string of exactly three tokens, 0..3374.
function s3$(i)
  return tok$(int(i / 225) + 1) + tok$(int(i / 15) mod 15 + 1) + tok$(i mod 15 + 1)
endfunction

rem The candidate of pass `ps`, number `i`.
function ckey$(ps, i)
  if ps = 1 then return s2$(int(i / 16))
  if ps = 2 then return s2$(int(i / 241))
  if i < 3375 then return "["
  return "[k"
endfunction
function cval$(ps, i)
  if ps = 1 then return s2$(i mod 16)
  if ps = 2 then return s2$(i mod 241)
  return s3$(i mod 3375)
endfunction
function csize(ps)
  if ps = 1 then return 241 * 16
  if ps = 2 then return 16 * 241
  return 2 * 3375
endfunction

function show$(s$) local i, out$
  out$ = ""
  for i = 1 to bytelen(s$)
    out$ = out$ + "<" + str$(byteat(s$, i)) + ">"
  next
  return out$
endfunction

goto start

refused:
rf = 1
resume next

start:
total = 0
rem The pairs go to the file in batches of 250 sections: the RTL finds a
rem section by walking its list, so one file of 6750 sections made each
rem lookup thousands of comparisons and the file took seconds.
batch = 250
rem (`for ... step` takes a literal, so the 250 is written there too)
for ps = 1 to 3
  test_case("config-r2/generated pass " + str$(ps))
  p$ = "bin/p9b_cfg_r2_" + str$(ps) + ".ini"
  n = csize(ps)
  ok@ = dim@(n)
  bad = 0
  badsec = 0
  badsave = 0
  first$ = ""
  for b0 = 0 to n - 1 step 250
    b1 = b0 + batch - 1
    if b1 > n - 1 then b1 = n - 1
    if file_exists(p$) <> 0 then file_delete(p$)
    c@ = cfg_open@(p$)
    for i = b0 to b1
      s$ = "s" + str$(i)
      c@ = cfg_set@(c@, s$, "nb1", "1")
      rf = 0
      on error goto refused
      c@ = cfg_set@(c@, s$, ckey$(ps, i), cval$(ps, i))
      on error goto 0
      narr_set@(ok@, i + 1, 1 - rf)
      c@ = cfg_set@(c@, s$, "nb2", "2")
    next
    x = cfg_save(c@)
    d@ = cfg_open@(p$)
    for i = b0 to b1
      s$ = "s" + str$(i)
      total = total + 1
      good = 1
      if cfg_get$(d@, s$, "nb1", "<absent>") <> "1" then good = 0
      if cfg_get$(d@, s$, "nb2", "<absent>") <> "2" then good = 0
      if narr_get(ok@, i + 1) = 1 then
        if cfg_get$(d@, s$, ckey$(ps, i), "<absent>") <> cval$(ps, i) then good = 0
        if cfg_keycount(d@, s$) <> 3 then good = 0
      else
        if cfg_keycount(d@, s$) <> 2 then good = 0
      endif
      if good = 0 then
        bad = bad + 1
        if first$ = "" then first$ = "key " + show$(ckey$(ps, i)) + " value " + show$(cval$(ps, i))
      endif
    next
    if cfg_sectioncount(d@) <> b1 - b0 + 1 then badsec = badsec + 1
    rem A second save of the reloaded file changes no byte.
    t1$ = file_readalltext$(p$)
    x = cfg_save(d@)
    if file_readalltext$(p$) <> t1$ then badsave = badsave + 1
    x = cfg_free(c@)
    x = cfg_free(d@)
  next
  file_delete(p$)
  assert_eq(bad, 0, "every accepted pair reads back and its neighbours are untouched: " + first$)
  assert_eq(badsec, 0, "and no line of any batch was read as a section header")
  assert_eq(badsave, 0, "and a second save of what was read back changes nothing")
next
rem 3856 + 3856 + 6750: the generated pairs, every one of which was judged.
assert_eq(total, 14462, "every generated pair was judged")

test_case("config-r2/a section name is swept the same way")
rem Every section name of length 0..2 holds k=v, and a neighbour section
rem after it holds x=1. "" is General, which is a section name like any.
p$ = "bin/p9b_cfg_r2_sec.ini"
if file_exists(p$) <> 0 then file_delete(p$)
c@ = cfg_open@(p$)
ok@ = dim@(241)
for i = 0 to 240
  rf = 0
  on error goto refused
  c@ = cfg_set@(c@, s2$(i), "k", "v")
  on error goto 0
  narr_set@(ok@, i + 1, 1 - rf)
  c@ = cfg_set@(c@, "n" + str$(i), "x", "1")
next
assert_eq(cfg_save(c@), 1, "the file is written")
d@ = cfg_open@(p$)
bad = 0
nsec = 0
first$ = ""
for i = 0 to 240
  good = 1
  if cfg_get$(d@, "n" + str$(i), "x", "<absent>") <> "1" then good = 0
  if cfg_keycount(d@, "n" + str$(i)) <> 1 then good = 0
  nsec = nsec + 1
  if narr_get(ok@, i + 1) = 1 then
    nsec = nsec + 1
    if cfg_get$(d@, s2$(i), "k", "<absent>") <> "v" then good = 0
    if s2$(i) <> "" and cfg_keycount(d@, s2$(i)) <> 1 then good = 0
  endif
  if good = 0 then
    bad = bad + 1
    if first$ = "" then first$ = "section " + show$(s2$(i))
  endif
next
assert_eq(bad, 0, "every accepted section name reads back with its key, and its neighbour is untouched: " + first$)
assert_eq(cfg_sectioncount(d@), nsec, "and exactly the sections written are there")
x = cfg_free(c@)
x = cfg_free(d@)
file_delete(p$)

test_case("config-r2/the defect the round found, by name")
rem "[k" = "v] ;c" is the line "[k=v] ;c". Either the setter refuses it, or
rem it reads back -- and in neither case does the key after it move.
p$ = "bin/p9b_cfg_r2_named.ini"
if file_exists(p$) <> 0 then file_delete(p$)
c@ = cfg_open@(p$)
c@ = cfg_set@(c@, "s", "a", "1")
rf = 0
on error goto refused
c@ = cfg_set@(c@, "s", "[k", "v] ;c")
on error goto 0
c@ = cfg_set@(c@, "s", "z", "2")
x = cfg_save(c@)
d@ = cfg_open@(p$)
assert_eq(cfg_get$(d@, "s", "z", "<absent>"), "2", "the key after it is still in its section")
assert_eq(cfg_section_exists(d@, "k=v"), 0, "and no section named k=v appeared")
if rf = 0 then
  assert_eq(cfg_get$(d@, "s", "[k", "<absent>"), "v] ;c", "accepted, so it reads back")
else
  assert_eq(cfg_exists(d@, "s", "[k"), 0, "refused, so it was never written")
endif
x = cfg_free(c@)
x = cfg_free(d@)
file_delete(p$)

test_case("config-r2/and what can be read back is still accepted")
rem Each of these is the kind of pair a refusal written too broadly would
rem catch: the comment and header characters INSIDE a key or a value, a
rem key beginning "[" whose line is no header, a quoted value, a value
rem ending in a backslash, and non-ASCII text.
p$ = "bin/p9b_cfg_r2_ok.ini"
if file_exists(p$) <> 0 then file_delete(p$)
c@ = cfg_open@(p$)
keys$ = "k;|k#|k]|k[|[k|[k|[k|k|k|k|k|k|k|k" + chr$(233)
vals$ = "v|v|v|v|v|v]x|[v|a=b|#x|;x|[s]|" + chr$(34) + "q" + chr$(34) + "|v" + chr$(92) + "|" + chr$(233)
rf = 0
nref = 0
for i = 1 to 14
  rf = 0
  on error goto refused
  c@ = cfg_set@(c@, "ok" + str$(i), word$(keys$, i, "|"), word$(vals$, i, "|"))
  on error goto 0
  nref = nref + rf
next
assert_eq(nref, 0, "none of the fourteen is refused")
x = cfg_save(c@)
d@ = cfg_open@(p$)
bad = 0
for i = 1 to 14
  if cfg_get$(d@, "ok" + str$(i), word$(keys$, i, "|"), "<absent>") <> word$(vals$, i, "|") then bad = bad + 1
next
assert_eq(bad, 0, "and all fourteen read back")
x = cfg_free(c@)
x = cfg_free(d@)
file_delete(p$)
