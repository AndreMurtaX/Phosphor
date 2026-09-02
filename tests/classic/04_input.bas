rem Console INPUT / LINE INPUT / INPUT$ over piped stdin (see 04_input.in).
input "Name"; who$
input "Age", years%
input a, b
line input rest$
println ""
println "who="; who$
println "years="; years%
println "sum="; a + b
println "rest=["; rest$; "]"
