rem ---------------------------------------------------------------
rem Common dialogs: their CONFIGURATION only. A dialog's Execute is
rem modal and would block a headless run, so it (and the one-shot
rem msgbox/openfile$/... helpers) belong to the interactive host; here
rem we round-trip the properties a program sets before showing one.
rem ---------------------------------------------------------------

test_case("dialog/open dialog configuration")
d@ = opendialog@()
assert_eq(gui_error(), 0, "opendialog@ built a dialog")
dialog_title@(d@, "Choose a file")
assert_eq(dialog_title$(d@), "Choose a file", "title round trip")
dialog_filter@(d@, "Text|*.txt|All|*.*")
assert_eq(dialog_filter$(d@), "Text|*.txt|All|*.*", "filter round trip")
dialog_filename@(d@, "notes.txt")
assert_eq(dialog_filename$(d@), "notes.txt", "filename round trip")
dialog_initialdir@(d@, "bin")
assert_eq(dialog_initialdir$(d@), "bin", "initial dir round trip")

test_case("dialog/save dialog shares the file configuration")
s@ = savedialog@()
dialog_filename@(s@, "out.dat")
assert_eq(dialog_filename$(s@), "out.dat", "save dialog filename")

test_case("dialog/select-directory and colour dialogs")
sd@ = selectdirdialog@()
dialog_title@(sd@, "Pick a folder")
assert_eq(dialog_title$(sd@), "Pick a folder", "select-dir title")
cd@ = colordialog@()
colordialog_color@(cd@, 255)
assert_eq(colordialog_color(cd@), 255, "colour dialog colour round trip")
