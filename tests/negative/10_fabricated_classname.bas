rem ---------------------------------------------------------------
rem classname$ used to be one line with no check whatsoever -- not
rem even for nil -- casting whatever number it was given to TObject
rem and reading the class name from it.
rem
rem It answers an empty string for a pointer the registry does not
rem know, so this file provokes the remaining failure: nil, which is
rem still an error rather than an answer. MUST fail.
rem ---------------------------------------------------------------
n = strings_count(pointer@(0))
println "must not get here: "; n
