rem A program that needs the GUI, and only just: it makes a form and reads its
rem caption back. No window is shown and no message loop is entered, so this
rem says whether the GUI functions are REGISTERED -- which is the whole question
rem the single binary answers at startup.
f@ = form@()
form_caption@(f@, "registrado")
println "gui ok: " + form_caption$(f@)
