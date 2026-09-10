rem A source file truncated in the middle of a string literal -- a cut-off
rem download, a generator killed mid-write, an editor that saved no final
rem newline.
rem
rem THIS FILE DELIBERATELY HAS NO TRAILING NEWLINE, and that is the whole test.
rem The string scanner reported `unterminated string` on the two paths it could
rem see (a bare newline inside the literal, and a backslash as the final byte).
rem When the loop simply RAN OUT OF SOURCE it fell through and pushed an ordinary
rem tkString -- and because the pending run is flushed only at a quote or an
rem escape, the token was EMPTY as well. So the identical text one byte apart
rem gave two different answers: with a final newline, `unterminated string` and
rem exit 1; without one, a clean exit 0 and a last statement silently rewritten
rem to `println ""`. `phosphor compile` accepted it too.
rem
rem If a tool ever adds a newline to the end of this file it stops testing that:
rem it becomes the other spelling, which was already refused. Check the last byte
rem before trusting a pass.
rem
rem MUST fail.
println "one"
println "two"
println "three