rem ===============================================================
rem crt_keys.bas -- read the keyboard with the CRT package.
rem
rem INTERACTIVE: run it in a real terminal and press keys.
rem     phosphor examples/crt_keys.bas
rem
rem getkey$() blocks until you press a key and returns it (in raw
rem mode, so keys arrive one at a time, unechoed). A normal key comes
rem back as its character; an arrow or function key as a short code
rem sequence (chr$(0)+code on Windows, an escape sequence on Unix).
rem Press 'q' to quit. crt_done() restores the terminal on the way out.
rem ===============================================================

ok% = crt_init()
print cls$();
println bold$() + color$(14) + "Keyboard demo" + reset$()
println "Press keys -- 'q' quits."
println

running% = 1
while running% = 1
  k$ = getkey$()
  if k$ = "" then
    running% = 0                 rem no terminal (piped / EOF) -- exit instead of spinning
  else
    if k$ = "q" then
      running% = 0
    else
      c% = asc(k$)
      print "  ";
      if c% >= 32 then
        println color$(10) + "'" + k$ + "'" + reset$() + "   code " + str$(c%)
      else
        println color$(11) + "control/extended" + reset$() + "   first code " + str$(c%) + ", length " + str$(len(k$))
      endif
    endif
  endif
endwhile

x% = crt_done()
println
println "bye."
