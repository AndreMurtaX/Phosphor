rem arr_free had the same dereference and was not even wrapped in try/except.
junk@ = pointer@(305419896)
r = arr_free(junk@)
println "must not get here: "; r
