rem A block terminator standing complete before `else` on the one-line if form.
rem The orphan check fired only when the next token ended the LINE, so
rem `if c then next else ...` slipped through and `next` went back to being the
rem silent no-op the check exists to stop -- in exactly one place, which is the
rem kind of gap a rule gets when its discriminator is "end of line" rather than
rem "end of statement".
println "this line runs"
if 1 = 1 then next else println "unreached"
