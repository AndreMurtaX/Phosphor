rem ===============================================================
rem Phosphor BASIC -- interactive GUI demo.
rem   Run it:   phosphor run examples/gui_demo.bas
rem A GUI program needs no flag and no second binary: phosphor brings the
rem widgetset up itself wherever a graphical session is reachable.
rem A window with a menu, a few controls, a live canvas drawing, and
rem events wired to BASIC handlers. Close it from File > Quit or the X.
rem ===============================================================

greetings = 0

f@ = form@("Phosphor BASIC — GUI demo", 470, 400)

rem --- a menu bar ---
mm@ = mainmenu@(f@)
mfile@ = menuitem@(mm@, "File")
mquit@ = menuitem@(mfile@, "Quit")
menuitem_onclick@(mquit@, "on_quit")

rem --- name label + edit ---
lbl@ = label@(f@, "Your name:")
control_move@(lbl@, 20, 22)
control_fontsize@(lbl@, 11)
name@ = edit@(f@)
control_bounds@(name@, 120, 18, 220, 28)
edit_text@(name@, "world")

rem --- an option ---
chk@ = checkbox@(f@)
checkbox_caption@(chk@, "Add an exclamation")
control_bounds@(chk@, 20, 60, 220, 24)
checkbox_checked@(chk@, 1)

rem --- the button that does the work ---
b@ = button@(f@)
button_caption@(b@, "Greet")
control_bounds@(b@, 20, 96, 130, 36)
button_onclick@(b@, "on_greet")

rem --- a status line the handler updates ---
status@ = label@(f@)
control_move@(status@, 20, 144)
control_fontsize@(status@, 13)
label_caption@(status@, "Type a name and press Greet.")

rem --- a canvas drawing, shown in an image on the form ---
bm@ = bitmap@(430, 130)
canvas_brushcolor@(bm@, 16777215)          rem white background
canvas_fillrect@(bm@, 0, 0, 430, 130)
canvas_pencolor@(bm@, 0)                    rem black outlines
canvas_brushcolor@(bm@, 65535)              rem yellow rectangle
canvas_rectangle@(bm@, 10, 10, 205, 120)
canvas_brushcolor@(bm@, 65280)              rem green ellipse
canvas_ellipse@(bm@, 220, 10, 420, 120)
canvas_textout@(bm@, 30, 55, "drawn by Phosphor BASIC")
pic@ = image@(f@)
control_bounds@(pic@, 20, 180, 430, 130)
image_setbitmap@(pic@, bm@)

form_show@(f@)
app_run()

function on_greet(sender@)
  greetings = greetings + 1
  msg$ = "Hello, " + edit_text$(name@)
  if checkbox_checked(chk@) = 1 then msg$ = msg$ + "!"
  msg$ = msg$ + "   (greeted " + str$(greetings) + " time"
  if greetings <> 1 then msg$ = msg$ + "s"
  msg$ = msg$ + ")"
  label_caption@(status@, msg$)
  return 0
end function

function on_quit(sender@)
  app_quit()
  return 0
end function
