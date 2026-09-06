rem A run of unary minus signs, which recurses on another path around ParseExpr.
rem
rem ParseUnary calls itself for each leading '-' or '+', so a RUN of them is a
rem run of stack frames that the parenthesis guard never counted: `print` and
rem 300000 minus signs killed the process with a stack overflow long after that
rem guard was in place -- silently, uncatchably, with an embedding host going
rem down with the script. (ParseSignedPrimary, the exponent's own rule, does the
rem same thing for `2 ^ ---...1`; probe_limits covers that one from Pascal, where
rem the exact message can be asserted.)
rem
rem 300 signs: absurd to write, and far short of a crash. Before the fix this
rem file compiled, printed -1 and exited 0, so it fails without the fix.
println ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------1
