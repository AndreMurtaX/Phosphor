rem ---------------------------------------------------------------
rem THE NINE MODALS (ledger d44, the last of the GUI worklist).
rem
rem dialog_execute, msgbox, msgbox_confirm, inputbox$, openfile$,
rem savefile$, openpicture$, savepicture$ and selectdir$ each wait for a
rem person, so until 2026-10-08 no test could call one. Every modal now
rem goes through a seam in PhosphorDialogLib, and this runner answers it:
rem NO DIALOG IS SHOWN. A test queues an answer with gui_test_answer(
rem accept, value$) and reads what the modal was asked to show back with
rem gui_test_asked$(field$).
rem
rem What is tested is the LIBRARY'S half, and every expected value comes
rem from its code, not from a run:
rem   * what a script passes reaches the dialog -- title, text, default,
rem     filter, initial directory, file name -- and a message box's kind
rem     and buttons are the ones the library chose (information + OK for
rem     msgbox, confirmation + Yes/No for msgbox_confirm);
rem   * each answer comes back as the right value: an accepted file
rem     dialog answers its file name and a cancelled one "", a confirm
rem     answers 1 for Yes and 0 for No, msgbox answers 0 either way;
rem   * inputbox$ answers what was typed when accepted and its DEFAULT
rem     when cancelled -- the LCL InputBox rule the unit header names;
rem   * dialog_execute answers 1 accepted / 0 cancelled, and an accepted
rem     answer lands in the dialog as a person's choice would: its file
rem     name, a colour dialog's colour, a font dialog's font name.
rem A modal with nothing queued is cancelled and COUNTED, never shown --
rem the last case proves that, so a forgotten answer cannot hang a run --
rem and the runner FAILS a file that left one unacknowledged, or left an
rem answer unused, or fed an answer to a different kind of modal than it
rem named (tests/gui/ledger/forgot.bas is the run that must fail).
rem
rem An adversarial review (2026-10-08) found two things here that could
rem not fail: a confirm DISMISSED (Esc, [X] -- mrCancel, not No) was never
rem answered, and the ledger was never read. Both are now driven: answer
rem -1 is a dismissal. It also found that "a cancelled one-shot answers
rem nothing" holds even for a library that ignored Execute's answer --
rem true, and not a gap: a real dialog leaves its name untouched on
rem cancel, and one made inside the call starts empty, so no one could
rem see that defect either. The harness does what a real dialog does.
rem ---------------------------------------------------------------

test_case("modal/msgbox")
x = gui_test_answer(1, "")
assert_eq(msgbox("saved"), 0, "msgbox answers 0")
assert_eq(gui_test_asked$("kind"), "message", "it was a message box")
assert_eq(gui_test_asked$("prompt"), "saved", "showing the text")
assert_eq(gui_test_asked$("title"), "", "untitled")
assert_eq(gui_test_asked$("type"), "information", "an information box")
assert_eq(gui_test_asked$("buttons"), "ok", "with one OK button")
x = gui_test_answer(1, "")
assert_eq(msgbox("body", "Heading"), 0, "the titled form answers 0 too")
assert_eq(gui_test_asked$("title"), "Heading", "and carries its title")
assert_eq(gui_test_asked$("prompt"), "body", "and its text")

test_case("modal/msgbox_confirm")
x = gui_test_answer(1, "")
assert_eq(msgbox_confirm("delete it?"), 1, "Yes answers 1")
assert_eq(gui_test_asked$("type"), "confirmation", "a confirmation")
assert_eq(gui_test_asked$("buttons"), "yes,no", "with Yes and No")
assert_eq(gui_test_asked$("prompt"), "delete it?", "asking the question")
x = gui_test_answer(0, "")
assert_eq(msgbox_confirm("delete it?"), 0, "No answers 0")
x = gui_test_answer(-1, "", "message")
assert_eq(msgbox_confirm("delete it?"), 0, "dismissed (Esc or the [X]) answers 0, not Yes")

test_case("modal/inputbox$")
x = gui_test_answer(1, "Ann", "input")
assert_eq(inputbox$("Your name?"), "Ann", "accepted, it answers what was typed")
assert_eq(gui_test_asked$("kind"), "input", "it was an input")
assert_eq(gui_test_asked$("prompt"), "Your name?", "with the prompt")
assert_eq(gui_test_asked$("default"), "", "and no default")
x = gui_test_answer(0, "ignored")
assert_eq(inputbox$("Your name?", "Bob"), "Bob", "cancelled, it answers the DEFAULT")
assert_eq(gui_test_asked$("default"), "Bob", "which the input was shown")
x = gui_test_answer(1, "")
assert_eq(inputbox$("Your name?", "Bob"), "", "accepted empty, it answers empty")
x = gui_test_answer(1, "typed")
assert_eq(inputbox$("Title", "Prompt", "Default"), "typed", "the three-part form")
assert_eq(gui_test_asked$("title"), "Title", "carries its title")
assert_eq(gui_test_asked$("prompt"), "Prompt", "its prompt")
assert_eq(gui_test_asked$("default"), "Default", "and its default")

test_case("modal/the one-shot file dialogs")
x = gui_test_answer(1, "chosen.txt")
assert_eq(openfile$(), "chosen.txt", "an accepted open answers the file")
assert_eq(gui_test_asked$("kind"), "topendialog", "through an open dialog")
x = gui_test_answer(0, "", "topendialog")
assert_eq(openfile$("Text|*.txt"), "", "a cancelled open answers nothing")
assert_eq(gui_test_asked$("filter"), "Text|*.txt", "the filter reached the dialog")
x = gui_test_answer(1, "out.txt")
assert_eq(savefile$("Text|*.txt"), "out.txt", "an accepted save answers the file")
assert_eq(gui_test_asked$("kind"), "tsavedialog", "through a save dialog")
assert_eq(gui_test_asked$("filter"), "Text|*.txt", "with the filter")
x = gui_test_answer(0, "")
assert_eq(savefile$(), "", "a cancelled save answers nothing")
x = gui_test_answer(1, "pic.png")
assert_eq(openpicture$("PNG|*.png"), "pic.png", "an accepted picture open answers the file")
assert_eq(gui_test_asked$("kind"), "topenpicturedialog", "through the picture dialog")
assert_eq(gui_test_asked$("filter"), "PNG|*.png", "with the filter")
x = gui_test_answer(0, "")
assert_eq(openpicture$(), "", "cancelled, nothing")
x = gui_test_answer(1, "shot.png")
assert_eq(savepicture$("PNG|*.png"), "shot.png", "an accepted picture save answers the file")
assert_eq(gui_test_asked$("kind"), "tsavepicturedialog", "through the picture save dialog")
x = gui_test_answer(0, "")
assert_eq(savepicture$(), "", "cancelled, nothing")
x = gui_test_answer(1, "somewhere")
assert_eq(selectdir$(), "somewhere", "an accepted folder answers the folder")
assert_eq(gui_test_asked$("kind"), "tselectdirectorydialog", "through the folder dialog")
x = gui_test_answer(0, "")
assert_eq(selectdir$(), "", "cancelled, nothing")

test_case("modal/dialog_execute")
d@ = opendialog@()
d@ = dialog_title@(d@, "Pick one")
d@ = dialog_filter@(d@, "All|*.*")
d@ = dialog_initialdir@(d@, "bin")
d@ = dialog_filename@(d@, "start.txt")
x = gui_test_answer(1, "picked.txt")
assert_eq(dialog_execute(d@), 1, "accepted answers 1")
assert_eq(gui_test_asked$("title"), "Pick one", "the dialog showed its title")
assert_eq(gui_test_asked$("filter"), "All|*.*", "its filter")
assert_eq(gui_test_asked$("initialdir"), "bin", "its initial directory")
assert_eq(gui_test_asked$("filename"), "start.txt", "and the file name it was given")
assert_eq(dialog_filename$(d@), "picked.txt", "and holds the file chosen")
x = gui_test_answer(0, "never.txt")
assert_eq(dialog_execute(d@), 0, "cancelled answers 0")
assert_eq(dialog_filename$(d@), "picked.txt", "and changes nothing")
c@ = colordialog@()
x = gui_test_answer(1, "255")
assert_eq(dialog_execute(c@), 1, "a colour chosen")
assert_eq(colordialog_color(c@), 255, "is the dialog's colour")
fd@ = fontdialog@()
x = gui_test_answer(1, "Courier New")
assert_eq(dialog_execute(fd@), 1, "a font chosen")
assert_eq(fontdialog_fontname$(fd@), "Courier New", "is the dialog's font")

test_case("modal/nothing queued is cancelled, never shown")
before = gui_test_asked()
assert_eq(gui_test_unanswered(), 0, "every modal so far had its answer")
assert_eq(openfile$(), "", "a modal with no answer queued is cancelled")
assert_eq(gui_test_unanswered(), 1, "and counted")
assert_eq(gui_test_asked() - before, 1, "it was asked, once, and nothing waited for a person")
assert_eq(gui_test_acknowledge(), 1, "acknowledged here, so the ledger does not fail the run for it")
assert_eq(gui_test_unanswered(), 0, "and the count is clear")
