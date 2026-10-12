{******************************************************************************
  Phosphor BASIC -- GUI core (shared by the GUI control packages)

  MIT License. Copyright (c) 2026 Andre Murta.

  This unit and its siblings under host/gui/libs are the SECOND consumer of the
  engine, exactly as host/console is the first. They may use the LCL; the engine
  may not, and the boundary check (which scans only engine/) keeps that true. A
  GUI package integrates through the same registry the engine libraries use --
  Reg.Add for plain functions, Reg.AddHost for the one kind that must call back
  into BASIC (an event handler).

  Two mechanisms live here:

  * Control handles. An LCL control is held in the ENGINE's handle registry (the
    same 1-based '@' ids arrays and dicts use), wrapped in a TGuiHandle so the
    registry can free every handle uniformly without double-freeing the LCL tree:
    the wrapper frees its control only when it OWNS it. A form owns its control
    tree (LCL frees children with their parent), so only the form's wrapper owns;
    a child control's wrapper does not. ResetHandles then frees each wrapper, the
    form wrapper frees the form (and LCL cascades to the children), and the child
    wrappers free nothing. This mirrors PhosphorJsonLib's owning/non-owning nodes.

  * Event delivery. An event binds to a BASIC routine by name. TGuiEventBridge
    holds the executing VM, the handler name and the sender's handle id; its Fire
    method (an LCL method pointer) runs the routine through the engine's
    host-callback seam (VM.CallUserFunc) -- the very path 48_callback proved. The
    bridge is owned by its control, so it dies with it. The reference walked a
    control's parent chain up to the form to find the engine; Phosphor hands the
    bridge the VM directly at bind time.
******************************************************************************}
unit PhosphorGuiCore;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Types, Controls, Forms,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles, PhosphorVM,
  PhosphorSandbox,   // GuiImageFileCost reads a file, so it asks the gate itself
  PhosphorIoLib;     // ...and IoSpecialKind before it opens one (round 11)

type
  { A registry entry for an LCL object. Control is a TObject so a handle can also
    wrap a non-TComponent (a TTreeNode, a TListItem), not only a control. Owns is
    true only for a top-level form (or a timer): its wrapper frees it. A child
    control, a node or an item is non-owning -- its container frees it.

    It is a TComponent for one reason: so it can receive Notification. A form owns
    its tree, so freeing the form frees its children, and a handle pointing at one
    of those children used to be left holding a dangling pointer that GuiResolveObj
    then dereferenced to ask its class -- an access violation reachable from
    ordinary BASIC, and a breach of this unit's own rule that a freed handle is
    ANSWERED, never raised. Watch() asks the control to say when it dies; the
    reference is dropped and every later use resolves to gui_error 1.

    A handle wrapping a NON-component cannot be watched itself: FreeNotification
    is a TComponent service. A TBitmap is owned by its handle and dies only
    through it. A TTreeNode or a TListItem is owned by a CONTROL, and that
    control IS a component -- so since 2026-10-05 the handle watches the control
    that holds it (Holder), and its death drops the reference exactly as a
    control's own death does. Before that, this comment said "do not free a tree
    while holding handles to its nodes", and control_free(tv@) followed by
    control_free(node@) was a double free reachable from ordinary BASIC (ledger
    n20); reading the node instead was an access violation (d10). A node can also
    die with a node above it, which no notification reports: GuiForgetNodes
    covers that, called before a node is freed.

    TGuiRef IS THE MECHANISM AND TGuiHandle IS THE ONE A PROGRAM CAN NAME. The
    other kind of TGuiRef is a free DEFERRED until an event's dispatch unwinds
    (see GuiFreeLater): it must watch and free its object exactly as a handle
    does, and it must NOT resolve -- every reader asks `is TGuiHandle`, so a
    deferred free is a different class, not a flag every reader would have to
    remember to check. }
  TGuiRef = class(TComponent)
  public
    // EXPLICIT visibility: TComponent is compiled {$M+}, so members with no section
    // default to PUBLISHED, and a plain TObject field cannot be published.
    Control: TObject;
    Owns: Boolean;
    { True only when Control WAS a TComponent at registration time, so the
      destructor never has to ask again. `c is TComponent` reads the object's VMT,
      which is a DEREFERENCE -- on a TTreeNode already destroyed with its tree that
      is the very access violation this class exists to prevent. Remembering the
      answer costs a byte and asks nothing of a dead pointer. }
    Watched: Boolean;
    { The CONTROL that owns a non-component Control -- a node's tree view, an
      item's list view -- watched in its place. nil for a component (watched
      directly) and for anything owned by its own handle. }
    Holder: TComponent;
    { WHEN Control WAS MADE: a serial GuiRegister stamps, and a deferred free
      copies from the handle it replaces. Every GuiRegister call is a
      constructor's (one handle per object, at its birth), so this orders
      objects by creation -- which is what a modal session asks before it frees
      anything (GuiFlushFreesSince). }
    Born: Int64;
    { FOUND BY ITS OBJECT (round 9): this handle's registry id, and the object
      it was registered for -- the key of the object-to-handle index, kept
      apart from Control because Control is nil'd when the object dies and the
      index entry must still be found to be removed. Set by GuiRegister only;
      0 and nil for a deferred free, which no reader looks up by object. }
    Id: Int64;
    IdxKey: Pointer;
    { Arm the death notice, when the wrapped object is able to send one. }
    procedure Watch;
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
    destructor Destroy; override;
  end;

  TGuiHandle = class(TGuiRef)
  public
    { A MOVE OF THIS CONTROL THAT HAS NOT LANDED (round 9; see GuiMoveControl).
      MoveTo: the parents asked for, by registry id, oldest first, each named
      once (asking for one again moves it to the end); 0 is "top level". The
      control goes to the LAST one still alive: a move into a parent freed
      before it lands does not happen, and the one asked before it counts
      again. MoveSeq: non-zero while a move is pending -- the stamp of this
      handle's latest place in the landing queue. TabWanted/TabSet and
      ZWanted (1 front, 2 back): settings relative to the NEW parent, asked
      while the move was pending, applied when it lands. }
    MoveTo: array of Int64;
    MoveSeq: Int64;
    TabWanted: Integer;
    TabSet: Boolean;
    ZWanted: Integer;
  end;

  { Carries one bound event back into BASIC. Owned by the control it serves; one
    bridge per event name, so a control can wire onclick AND onchange at once. }
  TGuiEventBridge = class(TComponent)
  private
    FVM: TPhosphorVM;
    FHandler: String;
    FSenderId: Int64;
    FEventName: String;   // which event this bridge serves (e.g. 'onclick')
    { Every variant funnels through this: build the argument list, call into
      BASIC, record a failing handler as error 2, and honour END. Returns what the
      handler answered so the two var-parameter events can read it. }
    function Call(const AArgs: array of TValue): TValue;
  public
    procedure Bind(AVM: TPhosphorVM; const AHandler: String; ASenderId: Int64);
    { One method per LCL event signature. The name after Fire is the signature, not
      the event: OnKeyDown and OnKeyUp are both TKeyEvent and share FireKey. }
    procedure Fire(Sender: TObject);                                        // TNotifyEvent
    procedure FireKey(Sender: TObject; var Key: Word; Shift: TShiftState);  // TKeyEvent
    procedure FireKeyPress(Sender: TObject; var Key: char);                 // TKeyPressEvent
    procedure FireMouse(Sender: TObject; Button: TMouseButton;
                        Shift: TShiftState; X, Y: Integer);                 // TMouseEvent
    procedure FireMouseMove(Sender: TObject; Shift: TShiftState;
                            X, Y: Integer);                                 // TMouseMoveEvent
    procedure FireMouseWheel(Sender: TObject; Shift: TShiftState;
                             WheelDelta: Integer; MousePos: TPoint;
                             var Handled: Boolean);                         // TMouseWheelEvent
    procedure FireClose(Sender: TObject; var CloseAction: TCloseAction);     // TCloseEvent
    procedure FireCloseQuery(Sender: TObject; var CanClose: Boolean);        // TCloseQueryEvent
    property Handler: String read FHandler;
    property EventName: String read FEventName write FEventName;
  end;

var
  { Last GUI error, in the phase-1 spirit: recorded, never raised. 0 = ok. A bad
    handle is 1; a handler that failed at run time is 2. }
  GGuiError: Integer;

const
  { THE LCL'S OWN CEILING ON A CONTROL'S SIZE, AND IT ENFORCES IT BY TRAPPING.
    lcl/include/control.inc, TControl.DoSetBounds, first statement:

        if (AWidth>100000) or (AHeight>100000) then BoundsOutOfBounds;

    and BoundsOutOfBounds calls RaiseGDBException, which raises EDivByZero ON
    PURPOSE so a debugger stops on it. So a program that asked for a control a
    million pixels wide -- an ordinary number, no arithmetic needed to reach it --
    died with "Division by zero", a message with nothing in it about size, about
    bounds, or about the line that asked. Every path into DoSetBounds is affected:
    Width, Height, SetBounds, and a form's own w/h. Checked here first, so the
    answer is gui_error 1 and no resize.

    AND 100000 WAS THE WRONG NUMBER, because it is only the ceiling of a control
    that has no WINDOW yet (2026-10-09, round 4). Once its form is shown, a
    control's bounds travel through TWinControl.SendMoveSizeMessages
    (lcl/include/wincontrol.inc), which raises ELayoutException for a width or
    height outside Word and for a left or top outside SmallInt -- so on a shown
    form control_left@(b@, 100000) raised "Position range overflow" and
    control_height@(b@, 70000) "Size range overflow", from setters documented
    never to raise, and the LCL kept the out-of-range value, so later realigns
    of that form raised again. Worse, a spin edit cannot be realized wider than
    about 32780 pixels on win32: control_width@(spin@, 32768..65535) made
    TWinControl.WMSize see bounds that never converge and raise from INSIDE the
    window procedure, where Application.HandleException ended the process -- no
    error trap could see it. So the one ceiling became 32767: a legal SmallInt
    coordinate, a legal Word size, and a size every control kind realizes --
    ON WIN32. GTK2 does not: its SetWidgetSizeAndPosition caps a widget at
    MaxSize = 32000 (lcl/interfaces/gtk2/gtk2proc.inc, "some limit to spot
    endless loops and bad values"), so a 32767-wide checkbox on a shown Linux
    form was realized 32000 wide, WMSize saw bounds that never converge, and
    the host died of an unhandled ELayoutException -- the first Linux run of
    tests/gui/29_shown_form.bas, the same day. The ceiling is the SMALLER of the
    two widgetsets' limits, one number on both OSes: 32000.
    GuiMinPos / GuiMaxPos are the coordinate range beside it. }
  GuiMaxExtent = 32000;
  GuiMinPos = -32768;
  GuiMaxPos = 32767;

  { AND THE CEILING THE LCL DOES NOT HAVE: A SIZE THAT BECOMES AN ALLOCATION.

    GuiMaxExtent above is about a number the LCL itself refuses. Everything below
    is about numbers it ACCEPTS, and then spends the machine's memory on. Measured
    on this tree, one probe per process, peak working set, floor 11 MB:

      bitmap@(20000, 20000)          + one canvas_fillrect@   2.3 GB committed
      imagelist@(30000, 30000)       + one imagelist_addbitmap  >4 GB, killed
      stringgrid_rowcount@(g@, 2e7)                             >2.5 GB, killed
      drawgrid_rowcount@(dg@, 2e7)                              >2.5 GB, killed
      control_set@(g@, "RowCount", 2e7)                         >2.5 GB, killed
      image_load@ of a 54-BYTE .bmp whose header says 30000x30000 >2.4 GB, killed
      imagelist_addfile of a 50 MB 1-bit .bmp                     1.7 GB, no error

    None of those reported anything at all. Ordinary integers -- no arithmetic
    needed to reach them, no overflow, nothing a type check would catch -- and the
    embedder's process is gone. That is not a crash the program can see and it is
    not an error it can catch; it is the host swapping until somebody kills it.

    THREE THINGS THIS COSTS, AND THE FIRST TWO ARE WHY A PER-OBJECT DIMENSION CAP
    IS NOT ENOUGH. An earlier version of this guard bounded each object's
    dimensions against one shared "256 MB of 4-byte pixels" constant. Measured
    against that guard, with every value INSIDE it and no error reported:

      imagelist@(8192,8192) + one entry     1684 MB   (an entry is not 4 B/px)
      ten bitmap@(8192,8192), each drawn    2132 MB   (each one was under the cap)
      ten grids at the accepted cell limit  >2200 MB, killed

    So the numbers here are a MEASURED COST PER UNIT, one per kind, and the policy
    is a single LIVE TOTAL that all of them are charged against -- see the ledger
    below. A cap that each object passes on its own is not a bound on the host.

  THE COST MODELS, MEASURED ON THIS TREE (deltas over an 11 MB floor, one probe
  per process; the fit is stated beside the figure it came from):

    surface (TBitmap)      4096^2 -> 99 MB, 5793^2 -> 197 MB, 8192^2 -> 393 MB
                           = 5.9 B/px; and 1 x 16777216 -> 161 MB, 1 x 67108864
                           -> 641 MB = 9.55 B/px, the extra being 3.65 B a ROW.
                           Rounded up to 6 B/px + 4 B/row. NOT 4 B/px: the win32
                           widgetset keeps more than the pixels.
    image-list ENTRY       list 1024^2 -> 20 MB an entry, 2048^2 -> 80 MB,
                           4096^2 -> 320 MB, 8192^2 -> 1277 MB = 19.0-19.1 B/px,
                           charged PER ENTRY. Rounded up to 20. This is the
                           number the old guard got wrong by 5x.
    grid                   150 B a ROW, 8 B a CELL, 296 B a COLUMN. The row term
                           comes from the only clean pair in the data -- 100 x 1e6
                           and 50 x 2e6 are both 100 M cells and differ only in a
                           million rows, costing 959 MB and 1107 MB, so a row is
                           148 B -- and the cell term from putting that back:
                           (959 - 148)/100e6 = 8.1 B. A row is nineteen cells,
                           which is why the old cell-product bound refused a
                           100 x 21000 sheet costing 21 MB and admitted a
                           1 x 2000000 column costing 305 MB.

                           THE COLUMN TERM WAS VERY NEARLY LEFT OUT, and a test
                           written for something else is what found it. An earlier
                           draft said in a comment that "with no rows there is no
                           grid, whatever the column count says" and priced columns
                           at nothing. Measured: a five-row grid given 2,000,000
                           columns costs 672 MB, and 20,000,000 would have been
                           6.7 GB straight through a guard that had just been
                           rewritten to stop that. The number is the plateau of a
                           column sweep on the unpatched build -- 250 k -> 296 B,
                           500 k -> 296, 1 M -> 293, 2 M -> 291, 2.5 M -> 290.

                           THIS MODEL IS NOT EXACT AND THE ERROR IS STATED, because
                           the last version of this comment presented arithmetic as
                           measurement and was 2.3x-6.6x out. Over the swept plane
                           it runs between 0.63x and 1.04x of the measured cost. It
                           under-charges most at 1000 x 100000, pricing 815 MB
                           against a measured 1010 MB, and over-charges a little in
                           the many-column corner (100 x 1e6 prices 950 MB against
                           915 MB) -- so it is a bound within about a third either
                           way, and it is not presented as more than that.

  THE POLICY, and it is one number: at most GuiMaxLiveBytes of GUI surface may be
  LIVE AT ONCE. 1 GB is far past any real GUI program -- a full 4K frame buffer is
  3840 x 2160 x 6 = 47 MB, so twenty of them fit -- and far below the 2.5-4 GB
  where these probes killed the host. It is a choice, not a measurement, and it is
  the only choice here; every other number above is a measured cost.

  AND WHAT THAT POLICY COSTS IN PRACTICE, MEASURED RATHER THAN ESTIMATED, because
  the version of this comment that stated 256 MB was really agreeing to 1.7 GB.
  Swept over 107 generated sizes -- 23 bitmap squares from 0 to 16384 including the
  boundary band, 12 shapes of one fixed pixel count, and the 12x6 plane of grid
  column and row counts -- the largest peak the NUMERIC doors admit is 1057 MB (a
  13374-square bitmap) and 974 MB (a 1000 x 100000 grid) against the stated
  1024 MB, so over those doors the policy holds to about 3%.

  THAT SENTENCE USED TO BE THE WHOLE CLAIM AND IT WAS 6.5x OPTIMISTIC, because the
  two doors a size arrives through a FILE were outside the sweep that produced it:
  one imagelist_addfile at the file gate's own accepted maximum really admitted
  2060 MB, and twelve image_load@ of one 560 KB picture admitted 6617 MB, because
  that gate compared against the budget instead of the ledger and no load was ever
  charged. Both are closed below, and the file doors are now swept as their own
  plane -- format x declared depth x declared size x repeat count, 72 cases walked
  one pixel either side of every format-and-depth boundary, 30 real pictures
  measured against the unguarded build, and 23 repeat counts.

  WHAT THE FILE DOORS ADMIT AT THEIR OWN MAXIMUM, measured at the boundary rather
  than estimated from the middle:

    image_load@         1102 MB   (a 23170-square 16-bit .bmp: 7.6% over)
    imagelist_addfile   1768 MB   (a 12383-square 8-bit grey PNG: 73% over)

  The first is the same 3-to-8% the numeric doors run at. The second is not, and
  the reason is stated rather than rounded away: imagelist_addfile is priced on the
  decode and the full-size copy it makes of it -- both real, both measured -- and
  TImageList.Add then converts that copy again on its way into the slot, which for
  an 8-bit source costs another 4.5 bytes a pixel. A third term big enough to cover
  that would refuse a 1-bit picture at the same door that measures 744 MB at ITS
  maximum, and refusing something that costs 744 MB out of 1024 is the failure this
  whole door exists to avoid. So the door is left under-priced by a measured amount
  in one corner rather than made to refuse a legitimate picture. }
  GuiSurfaceBytesPerPixel   = 6;
  GuiSurfaceBytesPerRow     = 4;
  GuiImageListBytesPerPixel = 20;
  GuiGridBytesPerRow        = 150;
  GuiGridBytesPerCell       = 8;
  GuiGridBytesPerCol        = 296;

  GuiMaxLiveBytes = Int64(1024) * 1024 * 1024;   // 1 GB

  { What the one policy number means in each kind's own units, when nothing else
    is live. Not used by the checks -- those price the thing and compare bytes --
    but this is the table a reader needs to see what the budget actually allows,
    and tests/gui/19 pins the four edges it names.

      a surface   178,956,970 px  = 13376 square, or 2.9 times a 4K frame
      a list ENTRY 53,687,091 px  =  7327 square, per entry and per list
      a grid        7,158,278 rows in one column, or 134,217,728 cells spread
                    over more -- 1342 columns by 100,000 rows, say }
  GuiMaxSurfacePixels   = GuiMaxLiveBytes div GuiSurfaceBytesPerPixel;    // 178956970
  GuiMaxImageListPixels = GuiMaxLiveBytes div GuiImageListBytesPerPixel;  //  53687091
  GuiMaxGridRows        = GuiMaxLiveBytes div GuiGridBytesPerRow;         //   7158278
  GuiMaxGridCells       = GuiMaxLiveBytes div GuiGridBytesPerCell;        // 134217728

{ True when this width and height are a size TControl will accept; records
  gui_error 1 and answers False when they are not. Pass the dimension that is NOT
  changing as the control's current one -- that is what the LCL sees, since every
  setter routes through the four-argument SetBounds. }
function GuiExtentOk(AWidth, AHeight: Integer): Boolean;
{ The same answer for a position: True when both lie in GuiMinPos..GuiMaxPos,
  else gui_error 1 and False. }
function GuiPosOk(ALeft, ATop: Integer): Boolean;

{ EVERY SIZE THE LCL WORKS OUT FOR ITSELF IS HELD TO THE SAME CEILING.
  A setter can be checked; an AUTOSIZE cannot -- a check box captioned with
  100000 spaces asked TControl.DoSetBounds for a width past 100000 once its form
  was shown, which raised EDivByZero ("Division by zero") from checkbox_caption@
  and left the form raising it again on every later constructor and move. Nor
  can an alignment, an anchor or a parent's constraint. All of those reach the
  size through TControl.ChangeBounds, which asks the control's ConstrainedResize
  hook before DoSetBounds; this installs one on AObj (when it is a control) that
  caps the maximum at GuiMaxExtent. It does not touch Constraints, so
  control_maxwidth still reads what the program wrote. GuiRegister calls it for
  every control a handle is made for. }
procedure GuiCapSizes(AObj: TObject);

{ --- what a thing costs -----------------------------------------------------
  Each answers the modelled cost in bytes, and each is total: a dimension at or
  below zero counts as ZERO, because that is what the framework makes of it. That
  is not a detail -- bitmap@(-5, -5) and bitmap@(-100000, -100000) have always
  been the harmless empty bitmap, and (-100000) * (-100000) is 10^10, so a guard
  that multiplied first would have turned them into an error.

  Each SATURATES at High(Int64) rather than overflowing, so a caller may compare
  the answer against a budget without checking anything first. }
function GuiSurfaceBytes(AWidth, AHeight: Int64): Int64;
function GuiImageListEntryBytes(AWidth, AHeight: Int64): Int64;
function GuiGridBytes(ACols, ARows: Int64): Int64;

{ --- the ledger: what is live now -------------------------------------------
  A per-object cap answers "is this one object too big". It does not answer "is
  this host about to die", which is the question the crashes were asking: ten
  bitmaps each inside the cap came to 2132 MB, and eight image-list entries each
  inside it killed the process. So every surface is CHARGED here when it is made
  and CREDITED when it dies, and the charge is refused when it would push the live
  total past GuiMaxLiveBytes.

  Crediting is the half that must not be got wrong: a charge that is never
  credited is a slow false refusal, which is worse than the leak it replaced. The
  two ways a charged object can die are both covered --
    * a TComponent (an image list, a grid) sends FreeNotification, whoever frees
      it, so a grid credited when its parent form is freed needs no cooperation
      from the handle layer at all;
    * a TBitmap is not a TComponent and cannot send one, but it is always OWNED by
      its handle, so TGuiHandle.Destroy credits it while the pointer is still
      certainly live.
  tests/gui/19 pins that BEHAVIOURALLY rather than by reading a counter -- it makes
  and frees a bitmap at the budget's own edge two hundred times over and asserts
  the two hundredth still succeeds. A missing credit fails on the second.

  GuiChargeRoom asks WITHOUT charging (for a gate that runs before a write may or
  may not happen); GuiChargeSet and GuiChargeAdd record. AReplacing is the object's
  own current charge, which is being replaced rather than added to -- a grid that
  goes from 1000 rows to 1001 costs one more row, not another whole grid.

  The store is a flat array and lookup is a linear scan. The function registry's
  own SIGNATURE lookup no longer is, but two scans of this shape remain on the
  per-call path and both were measured on 2026-09-11: TPhosphorRegistry.HasName,
  which answers a name-PREFIX question no signature index can, at about 100 us a
  call; and TProgram.FindUserFunc, at 5.73 ns per declared routine per call --
  +2.29 us with 400 routines merely declared, nine times what the indexed registry
  lookup now costs.
  It holds one entry per LIVE charged surface, which is a handful in any real
  program; measured at the unreasonable end, 20,000 simultaneously live bitmaps
  cost 1.6 s against the unguarded build's 1.4 s. If that ever stops being true the
  fix is a hash, not a smaller budget. }
function GuiChargeRoom(const AWhat: String; ABytes, AReplacing: Int64;
                       out E: TPhosphorError): Boolean;
{ Room for ABytes as AObj's TOTAL (replacing whatever it holds now), recording it
  when there is. }
function GuiChargeSet(AObj: TObject; const AWhat: String; ABytes: Int64;
                      out E: TPhosphorError): Boolean;
{ Room for ABytes IN ADDITION to what AObj already holds (an image-list entry). }
function GuiChargeAdd(AObj: TObject; const AWhat: String; ABytes: Int64;
                      out E: TPhosphorError): Boolean;
{ Give back everything AObj holds. Safe on an object that was never charged, and
  safe to call twice. }
procedure GuiCredit(AObj: TObject);
{ What one object holds, so a package re-pricing something it already charged for
  (a grid whose row count changed) can pass its own current charge as ARewriting
  instead of paying twice. }
function GuiObjectBytes(AObj: TObject): Int64;

{ --- the property bridge's gate ---------------------------------------------
  control_set@ writes ANY published property by name through RTTI, so every guard
  a named setter carries has a second way in beside it. For the guards that answer
  by RAISING inside the LCL that does not matter -- f_prop_set catches those and
  records gui_error 1. It matters for the one kind of refusal the LCL never makes:
  an allocation it is happy to perform. stringgrid_rowcount@ is bounded above;
  control_set@(g@, "RowCount", 20000000) reached the same allocation with the
  bound sitting one function away, unused.

  A package that owns such a property installs a GATE here (in its unit's
  initialization, so linking the package is what arms it -- no registration order
  to get wrong) and the bridge asks every gate before it writes an ordinal. The
  bridge is handed the CANONICAL name from the RTTI record, never the string the
  program typed, so no spelling of the property can walk past a gate. }
type
  TGuiPropGate = function(AObject: TObject; const AProp: String; AValue: Int64;
                          out E: TPhosphorError): Boolean;
  { And the other half of it. A gate runs BEFORE the write, which is the only
    place it can refuse -- but the ledger must record what the object ACTUALLY
    became, and only the write knows whether it happened (SetOrdProp may still
    raise, and f_prop_set catches that). So the bridge reports back afterwards,
    and the package re-reads the object rather than trusting the value it gated. }
  TGuiPropWritten = procedure(AObject: TObject; const AProp: String);

procedure GuiAddPropGate(AGate: TGuiPropGate);
procedure GuiAddPropWritten(AHook: TGuiPropWritten);
{ True when every installed gate allows this write; False fills E with the first
  gate's refusal. }
function GuiPropGatesAllow(AObject: TObject; const AProp: String; AValue: Int64;
                           out E: TPhosphorError): Boolean;
{ Tell every installed hook that the write went through. }
procedure GuiPropWasWritten(AObject: TObject; const AProp: String);

{ --- a size that arrives in a FILE rather than in an argument ----------------
  image_load@ and imagelist_addfile take no dimensions at all: the allocation is
  sized by the picture's own header, and TPicture.LoadFromFile has no pre-check of
  any kind (lcl/include/picture.inc -> the graphic class's LoadFromStream). So a
  FIFTY-FOUR BYTE .bmp whose header claims 30000 x 30000 took this host past
  2.4 GB and had to be killed, with nothing reported -- the cheapest crash in the
  tree, and reachable from any script allowed to read a file it wrote itself.

  THE FIRST VERSION OF THIS DOOR PRICED EVERY FORMAT AT A SURFACE'S 6 BYTES A
  PIXEL AND ASKED ONLY WHETHER THAT FIT THE WHOLE BUDGET, and both halves of that
  were wrong. It compared against GuiMaxLiveBytes instead of the LEDGER, so twelve
  loads of one 560 KB picture reached 6617 MB with nothing refused and nothing
  recorded; and 6 B/px is the cost of a 32-bit surface, not of an 8-bit greyscale
  PNG, so it refused a 30000-square grey PNG that really costs 874 MB inside a
  1024 MB budget. Both are fixed here, and the second one is fixed by MEASUREMENT:

  WHAT A LOAD ACTUALLY COSTS, swept over 22 generated 12000-square pictures (144
  megapixels each) against the unguarded build, one probe per process, peak
  working set with the 11 MB floor taken off:

    PNG grey 1/2/4/8/16 bit ->  1.06 / 2.0 / 3.9 / 7.8 / 15.4 bits a pixel
    PNG grey+alpha 8 ------->  15.4        PNG rgb 8 --------->  30.7
    PNG rgb 16 ------------->  46          PNG rgba 8/16 ----->  30.7 / 61
    PNG PALETTE 1, 4 and 8 ->  30.6 EACH   JPEG 1 and 3 comp ->  30.7 / 30.9
    BMP 1/4/8/16/24/32 ----->  3.0 / 27.8 / 31.6 / 31.6 / 46.8 / 62
    GIF 8 ------------------>  48

  Two things in that table are why a "read the bit depth" rule is not enough on
  its own. A PALETTE image costs the same 32 bits a pixel whatever depth its
  header declares -- 1-bit and 8-bit palettes measured 30.6 bits alike, because
  the decoder expands both to a 32-bit surface -- so pricing a 1-bit palette PNG
  at one bit would have under-charged it THIRTY-TWO fold. And a BMP is read into
  memory whole before it is decoded, so its cost is its FILE SIZE plus its decoded
  size: 1-bit measured 3.0 bits a pixel, which is 1 (the file) + 2 (the decode).
  So the model is (decoded bits x pixels) + (bytes on disk), the decoded depth
  comes from the table below, and the disk term is read rather than guessed.

  Checked against two files it was not fitted to: `big1bit.bmp` (20000 square,
  50 MB) prices 150 MB against 157 measured, and `big40000.bmp` (40000 square,
  200 MB) prices 600 MB against 587. Over the whole swept plane the model runs
  between 0.954x and 1.045x of the measured cost.

  Answers the pixel count a file's header DECLARES, without decoding it, or -1
  when this reader cannot tell. Recognised: BMP, PNG, GIF and JPEG, whose headers
  state their dimensions AND their depth in fixed places. -1 means "no opinion"
  and the caller must allow the load -- refusing every format we cannot pre-read
  would break the ones that work today (XPM, PNM, ICO, CUR, ICNS, TIFF); of those
  only TIFF can state a large size in a small file, and what happens to it now is
  the second half of GuiImageFileReserve's contract. }
type
  { What a file says it will cost. Bytes is -1 when the header was unreadable;
    every other field is then meaningless. }
  TGuiImageFileCost = record
    W, H: Int64;        // the declared dimensions, for the message
    Pixels: Int64;      // their product, likewise
    Bits: Int64;        // bits a pixel THE DECODE will use, not what the file stores
    OnDisk: Int64;      // the file's own size: it is read into memory before it decodes
    Bytes: Int64;       // the two together, or -1 for "no opinion"
  end;

function GuiImageFileCost(const APath: String): TGuiImageFileCost;
{ The same price for dimensions known some other way -- what a load actually
  decoded to, so a reservation can be corrected downward afterwards. }
function GuiImageBytesAt(AW, AH: Int64; const ACost: TGuiImageFileCost): Int64;

{ The policy over that reading, and it is the ledger's, not a per-file cap: what
  the header declares is RESERVED against AObj before anything is allocated, on
  top of everything else that is live, and refused with a catchable error naming
  the file and the size it claimed when it does not fit. ACopies is how many
  further full-size surfaces the caller will build from the decode before it is
  done -- 0 for image_load@, 1 for imagelist_addfile, which copies the decoded
  picture into a TBitmap before the list scales it.

  A header we cannot read reserves NOTHING and is allowed, exactly as before; the
  caller must then charge what the load became and undo it if that does not fit,
  because that is the only moment an unreadable format's size is ever known. }
function GuiImageFileReserve(const AWhat, APath: String; AObj: TObject;
                             ACopies: Integer; out ACost: TGuiImageFileCost;
                             out E: TPhosphorError): Boolean;
{ The refusal that door gives, so a caller settling a charge AFTER an unreadable
  header's load can answer in the same words. }
function GuiImageFileTooLarge(const AWhat, APath: String;
                              AW, AH, ABytes: Int64): TPhosphorError;

{ Register AObj under a fresh '@' handle; AOwns ties its lifetime here. }
function GuiRegister(AObj: TObject; AOwns: Boolean): Int64;
{ Resolve a handle to an object of (at least) AClass. Records GGuiError and
  returns False on a fabricated, freed or wrong-class handle. }
function GuiResolveObj(AId: Int64; AClass: TClass; out AObj: TObject): Boolean;
{ The common case: AClass is a TComponent subclass, so the object is a TComponent. }
function GuiResolve(AId: Int64; AClass: TClass; out AComp: TComponent): Boolean;
{ The bridge serving AControl's AEventName, created on demand (one per event). }
function GuiBridgeOf(AControl: TComponent; const AEventName: String): TGuiEventBridge;
{ Wire a TNotifyEvent by BASIC function name: find/create the bridge for AEvent,
  bind it, and return the method to assign to the control's event property -- or
  nil when AHandler is '' (which unwires). One line per event in a control lib. }
function GuiNotifyHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TNotifyEvent;
{ The same one line per event, for the other seven signatures. Each returns nil for
  an empty handler name, which unwires. }
function GuiKeyHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TKeyEvent;
function GuiKeyPressHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TKeyPressEvent;
function GuiMouseHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TMouseEvent;
function GuiMouseMoveHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TMouseMoveEvent;
function GuiMouseWheelHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TMouseWheelEvent;
function GuiCloseHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TCloseEvent;
function GuiCloseQueryHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TCloseQueryEvent;

{ --- objects the LCL is standing on ----------------------------------------
  This said a handler is usually the last thing that touches its sender, and
  that is FALSE -- see "a free asked for while an event is being dispatched"
  below, which is now what keeps every handler's free safe. This list stays for
  the one case that is REFUSED rather than deferred, and is pinned so by
  tests/gui/18_faults.bas. CLOSING A FORM: TCustomForm.Close runs OnCloseQuery, then OnClose, and then keeps working
  on the same form -- it writes CloseAction, hides the window, unwinds through
  fields of the object. control_free inside an onclose handler destroyed the form
  underneath that, and the LCL walked on into freed memory: an access violation
  reachable from an idiom the documentation itself invites ("dispose of the window
  when it closes"). TGuiHandle.Watch closes the other half of this hole -- a handle
  left pointing at a control its parent freed; this closes the half where the
  FRAMEWORK, not the program, is the one still holding the pointer.

  So a close bridge marks its sender as in use for the length of the callback, and
  control_free REFUSES a control on that list, answering gui_error 1 the way every
  other refused operation in this package does. The window is still freed -- by
  ResetHandles at the end of the program, which is where a form's handle has always
  freed it. }
function GuiInUse(AObj: TObject): Boolean;
{ Bracket a callback during which AObj must survive. Always in a try/finally. }
procedure GuiEnterCallback(AObj: TObject);
procedure GuiLeaveCallback(AObj: TObject);

{ --- a free asked for while an event is being dispatched --------------------
  THE CLOSE PATH WAS NOT THE ONLY ONE THE LCL STANDS ON (round 3, 2026-10-09).
  The note above was right about TCustomForm.Close and wrong that a handler is
  usually the last thing to touch its sender. TButtonControl.Click is
  DoOnChange and THEN `inherited Click` on the same object; TCustomCheckBox.
  SetState goes on reading LAction and FState after the change event; a list
  box's Click calls Changed on itself; a radio group's change arrives from
  inside one of its own radio buttons. So control_free of the sender -- or of
  the form that owns it, or of anything else the dispatcher touches on its way
  out -- inside checkbox_checked@, radio_checked@, togglebox_checked@,
  edit_text@, spinedit_value@, radiogroup_itemindex@ or a list's click freed
  memory the LCL was about to read. On the release heap that read stale bytes
  and passed; on a heap that poisons freed blocks it was an access violation.

  Guarding the sender alone, the way GuiInUse guards a closing form, could not
  close the class: the object the LCL reads next need not be the sender, and
  which one it is depends on LCL internals per control. What CAN be known
  exactly is WHEN no LCL frame of the program's is on the stack: never while a
  BASIC handler is running -- every handler reaches BASIC through GuiCallBack,
  which counts -- and always when a GUI function is entered with that count at
  zero, because a GUI function at depth zero was called by the program's own
  top-level code.

  So a free asked for during a dispatch is DEFERRED: for the program it happens
  at once -- the handle is dead, and so is every handle into what will die with
  the object, exactly as if it had been freed -- and the memory goes when the
  next GUI function runs at depth zero, or the message loop finishes a message,
  or the program ends (the deferred object is held by a registry entry no
  program can name, so ResetHandles frees it like any other). A control whose
  handle is dead raises no further events into BASIC (GuiCallBack). }
{ True while a BASIC event handler is running, at any depth. }
function GuiInDispatch: Boolean;
{ True while a handler is running for an event AObj sent -- at any depth, so a
  handler that clicks something else is still inside AObj's event. For the
  operations that DESTROY a control's internal children rather than the control
  itself, which no deferral can cover: radiogroup_clear frees the radio buttons
  the group's change event is raised from (PhosphorChoiceLib). }
function GuiDispatchingFrom(AObj: TObject): Boolean;
{ Free AHandle's object later, and every handle that names it or anything that
  dies with it NOW. The caller still releases AHandle's own registry entry. Only
  for an object some LCL frame might be standing on: a component, or a node or
  item (a handle with a Holder). }
procedure GuiFreeLater(AHandle: TGuiHandle);
{ Free whatever GuiFreeLater deferred, if no handler is running; otherwise do
  nothing. Safe to call from any GUI function at its entry. }
procedure GuiFlushFrees;

{ Call a BASIC routine the way an event bridge does: record a failing handler as
  error 2, honour END, and answer what the routine returned. Exposed because a
  package may own an event signature GuiCore must not know about -- Grids'
  TDrawCellEvent is the first -- and duplicating this would duplicate the two rules
  that matter. }
function GuiCallBack(AVM: TPhosphorVM; const AHandler: String;
  const AArgs: array of TValue): TValue;

type
  { A HANDLER THAT FAILED, TOLD TO THE HOST. The package's own rule stands -- the
    tick returns, gui_error() answers 2, the program carries on -- but until
    2026-10-05 that was ALL that happened: a packed GUI application whose handler
    faulted said nothing on any stream, and tests/gui_pack_test.py showed it. A
    library must not decide where a diagnostic goes, so it hands the fault to the
    host through this one hook and the host decides. nil (the default) is the old
    behaviour exactly, which is what a headless test host wants. }
  TGuiHandlerFaultProc = procedure(const AHandler: String; ALine: Integer;
    const AMessage: String) of object;

var
  { Set by the host that runs the program; read only inside GuiCallBack. }
  GuiOnHandlerFault: TGuiHandlerFaultProc = nil;

{ The modifier keys as the short string the handler receives: "S", "C", "A", joined
  by spaces in that order, so all three read "S C A" exactly as the plan specified.
  A program tests one with instr(mods$, "C") > 0. }
function GuiModsStr(Shift: TShiftState): String;

{ THE ONE WAY OUT OF app_run's LOOP, and the only thing that may take it.

  Setting the flag is not enough, which is the whole of the defect this closes.
  app_run blocks inside Application.HandleMessage, which dispatches the pending
  queue and then waits in Idle(Wait=True) for a message that may never arrive. A
  flag set from a timer callback is therefore read only if something ELSE happens
  to wake the loop -- and with no window shown, nothing does. Measured: a timer
  that stops itself and then calls app_quit() hung 5 runs out of 5.

  So leaving is a flag AND a wake. The wake goes through the LCL's own mechanism
  rather than a platform message: QueueAsyncCall ends by calling WakeMainThread,
  which the widgetset assigns (win32object.inc:160), and the queued no-op also
  gives AppProcessMessages something to dispatch -- so the loop makes a pass and
  re-reads the flag even where the wake itself is a no-op.

  END in a handler calls this too (GuiCallBack). A closed window does NOT: it
  only requests (GuiWindowLeaving), and app_run decides. Application.Terminate
  is never used: it sets a flag the LCL
  gives no public way to clear, so it turns "give me back control" into a one-way
  door for the whole process. }
{ Is any window OTHER than AExcept still on screen?

  Answered HERE because the answer needs TGuiHandle, which is this unit's. The
  handle registry does not hold a TForm -- GuiRegister wraps every object in a
  TGuiHandle so it can be told when the object dies -- so a caller walking the
  live handles and testing `is TForm` finds nothing, ever. That is what the first
  version of the last-window check did, and closing one of two shown forms still
  left the message loop.

  Screen.CustomForms was tried before that and is also wrong here: measured
  headless, a form the script had shown was not in it. The registry is where this
  host's own windows live, which is the set the question is about. }
function GuiOtherFormShown(AExcept: TObject): Boolean;

{ IS AObj A WINDOW ON SCREEN -- the one predicate every "the last window" question
  asks (round 7, 2026-10-11): a form, VISIBLE, not in a modal session, and
  TOP-LEVEL. A form placed inside another (control_parent@) is a control of that
  window, not a window: counting it kept app_run running, with nothing on
  screen, after the window it was embedded in was closed. Top-level in the
  PROGRAM'S view (GuiEffectiveParent, round 9): a move it asked for counts
  whether or not it has landed, as in every other reader. }
function GuiIsShownWindow(AObj: TObject): Boolean;

procedure GuiLeaveLoop;

{ "THE LAST WINDOW WAS CLOSED" IS A QUESTION, NOT AN ORDER (round-6 review).
  A form's close used to set the loop's quit flag the moment nothing else was
  shown -- a LATCH, decided while a handler was still running. A handler that
  closes one window and then shows the next (a wizard's next page), or one that
  closes a window inside a modal dialog and shows the main window once the dialog
  is answered, left app_run with its window on screen and nothing dispatching it.
  The closer now only REQUESTS; app_run asks again, when it reads the request,
  whether any window is still shown, and ends only if none is. app_quit stays an
  order.

  WHO REQUESTS (round 7, 2026-10-11): every window that LEAVES THE SCREEN by
  being closed or freed -- whether or not another is shown at that moment,
  because that is app_run's question to answer, once every handler has
  returned. The closer used to ask it at close time, so "close A, then hide B"
  in one handler left app_run running with nothing on screen while "hide B,
  then close A" ended it. And only a window that WAS on screen: closing a form
  that was never shown closes no window, and it used to end the loop of a
  timer-driven program that had none. Hiding is not closing -- a program that
  hides its last window to the tray keeps its loop. Call it with the form
  BEFORE it goes; it does nothing for anything GuiIsShownWindow refuses. }
procedure GuiWindowLeaving(AObj: TObject);
procedure GuiLastWindowClosed;

{ A FORM WHOSE HOST IS FREED BECOMES A HIDDEN TOP-LEVEL FORM (round 8; round
  9, 2026-10-11). A form owns itself, so freeing the window or panel it is
  embedded in does not free it: TWinControl.Destroy destroys the host's window
  (the embedded one goes with it) and then only UNPARENTS its children --
  "controls are freed by the owner" (wincontrol.inc). Left to that, the form
  was Visible, top-level and with no window on screen: GuiIsShownWindow counted
  it, app_run never ended, and form_visible answered 1.

  Call it when control_free is asked -- inside a handler AFTER GuiFreeLater, so
  the handles of what dies are already dead and a move into the dying tree no
  longer counts. Every form placed in a container that dies with AObj, while
  the form itself does not, and whose pending move (if any) does not take it to
  a living parent first, is HIDDEN and MOVED TO THE TOP LEVEL -- through
  GuiMoveControl, so it lands at once unless a walk may stand on the list it
  leaves. Round 8 only hid it, at request time, and left it inside the dying
  host until the free: form_show@ in the same handler re-showed it INSIDE that
  host, the free then unparented it, and the round-8 state was back (round 9).
  Now form_show@ shows a top-level form, as the documentation promised. And a
  form whose pending move went INTO the dying tree is not touched: that move
  does not land, so it stays where it is (round 8 hid such a form, the only
  window on screen, without asking app_run, and the loop never ended).

  The forms are found by walking what the free DESTROYS -- the components AObj
  owns, and the controls each dying container holds -- never the live handles:
  round 8 walked every live handle on every free of a windowed control, so
  freeing N buttons in a program holding H handles cost N*H (round 9). }
procedure GuiReleaseOrphanedForms(AObj: TObject);

{ WHERE A MOVE LANDS, AND WHEN (round 8; rebuilt in round 9, 2026-10-11).

  THE WALKS. The LCL walks a parent's control list by index with its bound
  read once, and calls the program from inside the walk. Measured in the
  source: TRadioButton.ApplyChanges (radiobutton.inc; no window handle yet)
  and ClearSiblingRadioButtons (win32callback.inc; with one) uncheck each
  sibling of a radio being checked, and a sibling's onchange runs BASIC;
  TWinControl.PaintControls (wincontrol.inc) reads Count once and paints each
  graphic child, and a paintbox's onpaint runs BASIC. Moving a control OUT of a
  walked list shortened it under the loop: "List index (2) out of bounds",
  raised into the program (round 8).

  WHICH LISTS A WALK CAN BE ON. Every one of those walks reaches BASIC through
  an event of a control IN the list it walks -- the sibling, the painted child
  -- or beneath one (a nested realign). The events this package raises are a
  closed set (click, change, key, mouse, paint, cell drawn, close, tick), and
  none is raised from a walk of some other control's list. So while handlers
  run, the lists that can be under a walk are those of each running handler's
  SENDER and of its ancestors. A move takes the control out of its current
  parent's list, and re-creates the windows of the control and everything
  under it; so a move is BLOCKED exactly when the control, or the parent it
  would leave, is a running sender or an ancestor of one. A move into a list
  is never blocked: it APPENDS (TWinControl.Insert inserts at ControlCount),
  past a bound a walk read before, as making a control does.

  An unblocked move LANDS AT ONCE, as at depth 0, whatever is running. Round
  8 deferred every move asked inside any handler, and the program's view (what
  it asked) and the LCL's (what had landed) then disagreed for the rest of the
  handler: a form made visible after a deferred embed was a top-level window
  until the move landed, and its landing ended a tray program's app_run; the
  only window, moved into a host freed in the same handler, was hidden and
  app_run never asked; a tab order set after the move was lost; a control moved
  into a dialog by the click that opens it was not there while the dialog was
  up. A tray program's timer has no control sender, and a button's click
  blocks only the lists of the button's own ancestors.

  A blocked move WAITS, on the control's handle (MoveTo), and so does every
  later move of that control, so a control's moves land in the order asked. It
  lands at the next GUI function at depth 0, once the message loop has
  dispatched a message, or -- inside a modal session -- between the session's
  messages as soon as nothing running under the session blocks it. A move that
  waited lands after moves of other controls asked later that did not.

  WAITING MOVES LAND AS ONE STEP (round 10). Each control's waiting moves
  land at its latest place in the queue, and every one of them was judged a
  cycle against the program's view when it was asked. Landed one by one
  against the tree as it physically stands, a legitimate sequence was refused
  at landing: A to main, then B into A, then A to main AGAIN re-queued A
  behind B, B's landing found A still physically inside B, and B stayed where
  it was with gui_error 1 on an unrelated later call. So a move that would
  place a control inside itself only because another waiting move has not
  landed yet waits for that one, within the same landing; only a move still a
  cycle once nothing else can land (a parent freed meanwhile let an earlier
  ask count again) is refused, the latest asked first. And the tab chains
  come out as the program was told (GuiTabOrder): each parent's chain is
  computed BEFORE anything moves, in queue order (each control at its latest
  ask), and imposed after -- so the order the moves physically landed in
  cannot show.

  THE PROGRAM'S VIEW IS THE TRUTH. While a move waits, every reader in this
  package answers with the parent asked for (GuiEffectiveParent): the
  last-window question (GuiIsShownWindow), the forms a free leaves without a
  host, form_showmodal's refusal, the cycle check, control_taborder. A window
  on screen moved into another stops being a window when the move is ASKED,
  and asks app_run then (GuiWindowLeaving); the landing asks nothing. A move
  into a control freed before it lands does not happen, and the move of that
  control asked before it counts again.

  BOUNDED: a control's waiting moves name each parent once, so a handler that
  moves two controls back and forth holds two entries, not one per pass; the
  landing queue is compacted as it grows; and a move costs a walk up each
  running sender's chain plus the cycle check, never a scan of what waits.
  (Reading a tab order while moves wait does scan them, once per read: the
  answer is where the control lands, and that depends on every one.)

  The caller has resolved both handles and refused a cycle (GuiWouldCycle,
  pending moves counted) and a modal form; both are asked again when a waiting
  move lands, and a refusal then records gui_error 1. AParentId 0 with AParent
  nil moves the control to the top level (GuiReleaseOrphanedForms only). }
procedure GuiMoveControl(AChildId, AParentId: Int64; AChild: TControl;
  AParent: TWinControl);
{ The parent AObj has in the program's view: the last parent a waiting move of
  it asks for that is still alive (nil for the top level), else its parent now. }
function GuiEffectiveParent(AObj: TObject): TWinControl;
{ The handle of AObj when a move of it is waiting, else nil: what a setter
  relative to the new parent (control_taborder@, control_bringtofront@,
  control_sendtoback@) records instead of applying to the old one. }
function GuiMovePending(AObj: TObject): TGuiHandle;
{ Would placing AChild in AParent make AChild its own ancestor? APending walks
  the parents pending moves will give, which is the state a deferred move
  lands into. }
function GuiWouldCycle(AChild: TObject; AParent: TWinControl;
  APending: Boolean): Boolean;
{ THE TAB ORDER IN THE PROGRAM'S VIEW (round 10). With nothing waiting, the
  LCL's own (TWinControl.GetTabOrder: the index in the parent's FTabList).
  With moves waiting, where AObj will be once they land: the chain of the
  parent it was asked into, replayed through every waiting move in the order
  they land -- a control leaving that parent drops out, one arriving is
  appended (TWinControl.Insert), a position set while waiting is applied as
  UpdateTabOrder applies it -- and LandMoves imposes that same chain. Round 9
  answered the OLD position when the move went back to the control's own
  parent, and the same "end of chain" for two controls arriving in one. A
  control asked to the top level answers its own (an unparented control's
  TabOrder is only remembered). }
function GuiTabOrder(AObj: TWinControl): Integer;

{ RADIO EXCLUSIVITY IS THE LIBRARY'S (round 10). Siblings in one parent are
  exclusive -- TRadioButton.ApplyChanges unchecks each one when the radios
  have no window, ClearSiblingRadioButtons does on win32 and the radio's group
  on gtk2 when they have -- but each of those walks covers only its own half.
  On a form that was shown and then hidden, a radio made in it, or moved into
  it, has no window while its siblings have one: win32 sent the uncheck to a
  window that is not there, gtk2 grouped the new radio with nothing, and two
  radios of one panel read checked (round 10; Linux after radio_checked@,
  both OSes after a move). Checked here, after the widgetset has had its say:
  GuiRadioRealize first gives the radio being CHECKED, when its parent has a
  window, a window of its own (so gtk2 groups it -- a gtk radio cannot be
  unchecked alone; never an unchecked one, which on gtk2 would be created
  active when it starts a group of its own), and
  GuiRadioExclusive then unchecks every sibling still checked. A move of a
  checked radio is a check too: the one arriving wins, which is what each
  widgetset does once the window exists. Siblings are PHYSICAL ones -- the
  LCL's own walk, which nothing here can stop, is too. }
procedure GuiRadioRealize(R: TControl);
procedure GuiRadioExclusive(R: TControl);

{ A MODAL SESSION'S OWN FREES (round 5, 2026-10-10). GuiFlushFrees runs only at
  dispatch depth 0, and a modal opened from a handler never returns there until
  it closes -- so every control a handler freed inside a long-lived dialog stayed
  in memory, and charged to the GUI's ledger, until the dialog ended. A modal
  session takes a mark when it starts and, between its messages and only when no
  handler is running inside it, frees what may be freed.

  WHAT MAY BE FREED IS WHAT WAS BORN INSIDE THE SESSION (round 7, 2026-10-11).
  The mark is a BIRTH mark, not a place in the queue. Under the session lies the
  whole dispatch chain that opened it, and what that chain stands on cannot be
  listed: round 6 kept the running handlers' SENDERS, and a radio button whose
  SetState was running under the session -- no handler's sender; the LCL itself
  called the sibling's change handler from inside its loop over the parent's
  controls -- was freed beneath it (an access violation), and freeing a SIBLING
  shortened the list that loop was walking (list index out of bounds). An object
  made after the session began cannot be under it: every frame below was entered
  before the object existed. And nothing older dies with a younger one, because
  a component's owner is fixed when it is made and is made first (control_parent@
  moves the parent, never the owner; a node's or a menu item's children are made
  after it). What is older stays pending, for GuiFlushFrees at depth 0 -- which
  bounds what a long session holds to what existed before it opened; the
  unbounded case, a dialog that makes and frees in a loop, is all newborn. }
function GuiPendingMark: Integer;
function GuiBirthMark: Int64;
function GuiDispatchDepth: Integer;
procedure GuiFlushFreesSince(ABirthMark: Int64; ADepth: Integer);

{ END IN A HANDLER ENDS EVERY MODAL SESSION TOO (round 5). GuiLeaveLoop sets the
  flag app_run's loop reads, and LCL's ShowModal loop reads only ModalResult and
  Application.Terminated -- so a program that said END while a modal form was up
  waited for a person forever, its handlers refused by the halted VM. Each form
  in a modal session is answered mrCancel, exactly what [X] would do. A modal
  session run by a test hook asks the VM itself after every round. }
procedure GuiEndModals;

procedure RegisterGuiCoreFuncs(Reg: TPhosphorRegistry);

{ BEFORE A TREE NODE OR A LIST ITEM IS FREED: every handle naming it -- and, for a
  node, naming any node beneath it -- is dropped, so nothing is left pointing into
  the subtree the free is about to destroy. No notification can report that
  death: nodes are not components, and their tree view is still alive.

  SAFE TO WALK BECAUSE OF AN INVARIANT, not because of luck: every non-nil
  Control in the registry points at a live object. A component is watched
  directly, a node or item through its Holder, and this routine covers the one
  death neither reports. That is what lets `is TTreeNode` and HasAsParent read
  each Control below without reading freed memory. }
procedure GuiForgetNodes(AObj: TObject);

implementation

uses
  ComCtrls,   // TTreeNode / TListItem: what a non-component handle can wrap
  Menus,      // TMenuItem: a menu item dies with the item above it, not its owner
  StdCtrls;   // TRadioButton: sibling exclusivity (GuiRadioExclusive)

// --- the object -> handle index (see TGuiRef.Id) ----------------------------
{ ONE HANDLE PER OBJECT, FOUND BY THE OBJECT (round 9). Every GuiRegister is a
  constructor's, so an object has at most one TGuiHandle, and a reader that
  holds the object -- a parent met walking up a chain, a form met walking a
  dying tree -- asks this index for it in constant time instead of scanning the
  live handles. Open addressing over a power-of-two table, deleted by backward
  shift so every probe chain stays whole.

  An entry is trusted only after it is CHECKED: the id must still name a
  TGuiHandle whose Control is that very object (HandleOf). An object that dies
  leaves its entry behind until its handle is destroyed, and its address may
  be reused meanwhile; the check refuses such an entry, and a reused address
  that is registered again simply overwrites it. }
type
  TGuiIdxSlot = record
    Key: Pointer;
    Id: Int64;
  end;

var
  GIdx: array of TGuiIdxSlot;
  GIdxCount: Integer = 0;

{$push}{$Q-}{$R-}
function IdxHome(AKey: Pointer; AMask: Integer): Integer;
begin
  // Objects are 16-byte aligned: drop the dead low bits, then spread the rest.
  Result := Integer(((PtrUInt(AKey) shr 4) * PtrUInt(2654435761)) and PtrUInt(AMask));
end;
{$pop}

procedure IdxPlace(AKey: Pointer; AId: Int64);
var i, m: Integer;
begin
  m := High(GIdx);
  i := IdxHome(AKey, m);
  while (GIdx[i].Key <> nil) and (GIdx[i].Key <> AKey) do i := (i + 1) and m;
  if GIdx[i].Key = nil then Inc(GIdxCount);
  GIdx[i].Key := AKey;
  GIdx[i].Id := AId;
end;

procedure IdxPut(AKey: Pointer; AId: Int64);
var
  old: array of TGuiIdxSlot;
  i: Integer;
begin
  if (Length(GIdx) = 0) or ((GIdxCount + 1) * 2 > Length(GIdx)) then
  begin
    old := GIdx;
    GIdx := nil;
    if Length(old) = 0 then SetLength(GIdx, 64) else SetLength(GIdx, Length(old) * 2);
    GIdxCount := 0;
    for i := 0 to High(old) do
      if old[i].Key <> nil then IdxPlace(old[i].Key, old[i].Id);
  end;
  IdxPlace(AKey, AId);
end;

function IdxFind(AKey: Pointer): Int64;
var i, m: Integer;
begin
  Result := 0;
  if (GIdxCount = 0) or (Length(GIdx) = 0) then Exit;
  m := High(GIdx);
  i := IdxHome(AKey, m);
  while GIdx[i].Key <> nil do
  begin
    if GIdx[i].Key = AKey then Exit(GIdx[i].Id);
    i := (i + 1) and m;
  end;
end;

{ Remove AKey only while it still maps to AId: a reused address registered
  again belongs to the new object's handle, not to the one being destroyed. }
procedure IdxRemove(AKey: Pointer; AId: Int64);
var i, j, m, home: Integer;
begin
  { Length too, not only the count: a handle the registry destroys after this
    unit's globals are finalized finds the table already gone. }
  if (GIdxCount = 0) or (Length(GIdx) = 0) or (AKey = nil) then Exit;
  m := High(GIdx);
  i := IdxHome(AKey, m);
  while (GIdx[i].Key <> nil) and (GIdx[i].Key <> AKey) do i := (i + 1) and m;
  if (GIdx[i].Key <> AKey) or (GIdx[i].Id <> AId) then Exit;
  GIdx[i].Key := nil;
  Dec(GIdxCount);
  j := i;
  while True do
  begin
    j := (j + 1) and m;
    if GIdx[j].Key = nil then Break;
    home := IdxHome(GIdx[j].Key, m);
    { Slot j may move back into the hole at i unless its home lies cyclically
      in (i, j] -- then a probe from home never passes i. }
    if ((i < j) and ((home <= i) or (home > j))) or
       ((i > j) and (home <= i) and (home > j)) then
    begin
      GIdx[i] := GIdx[j];
      GIdx[j].Key := nil;
      i := j;
    end;
  end;
end;

{ The live handle of AObj, or nil. }
function HandleOf(AObj: TObject): TGuiHandle;
var
  id: Int64;
  o: TObject;
begin
  Result := nil;
  if AObj = nil then Exit;
  id := IdxFind(AObj);
  if id = 0 then Exit;
  o := HandleObj(id);
  if (o is TGuiHandle) and (TGuiHandle(o).Control = AObj) then
    Result := TGuiHandle(o);
end;

procedure TGuiRef.Watch;
begin
  Watched := Control is TComponent;   // asked ONCE, while the pointer is certainly live
  if Watched then
    TComponent(Control).FreeNotification(Self)
  else if Control is TTreeNode then
    Holder := TTreeNode(Control).TreeView
  else if Control is TListItem then
    Holder := TListItem(Control).ListView;
  if Holder <> nil then
    Holder.FreeNotification(Self);
end;

procedure TGuiRef.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  // The control this handle names is going away. Drop the reference NOW, while the
  // pointer is still valid to compare -- after this the handle is stale, which is a
  // state the resolver already knows how to refuse.
  if (Operation = opRemove) and (AComponent = Control) then
    Control := nil;
  // AND SO IS THE CONTROL THAT HOLDS A NODE OR AN ITEM, which takes the node or
  // item with it. Dropped the same way, for the same reason.
  if (Operation = opRemove) and (Holder <> nil) and (AComponent = Holder) then
  begin
    Control := nil;
    Holder := nil;
  end;
end;

procedure GuiForgetNodes(AObj: TObject);
var
  id: Int64;
  i: Integer;
  o: TObject;
  h: TGuiRef;
  dies: Boolean;
begin
  if AObj = nil then Exit;
  id := FirstLiveHandle();
  for i := 1 to LiveHandleCount() do
  begin
    if id = 0 then Break;
    o := HandleObj(id);
    if o is TGuiRef then
    begin
      h := TGuiRef(o);
      dies := (h.Control <> nil) and (h.Holder <> nil) and
              ((h.Control = AObj) or
               ((AObj is TTreeNode) and (h.Control is TTreeNode) and
                TTreeNode(h.Control).HasAsParent(TTreeNode(AObj))));
      if dies then
      begin
        h.Holder.RemoveFreeNotification(h);
        h.Holder := nil;
        h.Control := nil;
      end;
    end;
    id := NextLiveHandle(id);
  end;
end;

destructor TGuiRef.Destroy;
var
  c: TObject;
begin
  // Take the reference away from the field FIRST. Freeing the control re-enters
  // Notification, and finding Control already nil there is what keeps that path
  // from mattering.
  c := Control;
  Control := nil;
  // Out of the object index (a no-op for a deferred free, which is not in it).
  IdxRemove(IdxKey, Id);
  IdxKey := nil;
  // Watched, not `c is TComponent`: a non-component handle (a TTreeNode, a
  // TListItem) may already have died with its container, and testing its class
  // would dereference it. Where Watched is true and the control has died, the
  // notification already set Control to nil, so c is nil here and nothing is asked.
  if Watched and (c <> nil) then
    TComponent(c).RemoveFreeNotification(Self);
  // A Holder still set is a live control: its notification would have nil'd it.
  if Holder <> nil then
  begin
    Holder.RemoveFreeNotification(Self);
    Holder := nil;
  end;
  if Owns and (c <> nil) then
  begin
    // THE LEDGER'S OTHER CREDIT PATH, and the only one a TBitmap has: it is not a
    // TComponent, so it cannot send FreeNotification, and nothing else would ever
    // hear that these 393 MB came back. Credited BEFORE the free, while the
    // pointer is certainly live -- GuiCredit calls RemoveFreeNotification on a
    // component, which a dead one cannot answer. Crediting a component here too is
    // harmless: its notification got there first and this finds nothing.
    GuiCredit(c);
    c.Free;
  end;
  inherited Destroy;
end;

procedure TGuiEventBridge.Bind(AVM: TPhosphorVM; const AHandler: String; ASenderId: Int64);
begin
  FVM := AVM;
  FHandler := AHandler;
  FSenderId := ASenderId;
end;

// --- objects the LCL is standing on (see the interface note) -----------------
var
  { A stack, not a single slot: a close handler may close a second form, so two
    forms can be in use at once and the inner one must not un-protect the outer. }
  GInUse: array of TObject;

procedure GuiEnterCallback(AObj: TObject);
begin
  SetLength(GInUse, Length(GInUse) + 1);
  GInUse[High(GInUse)] := AObj;
end;

procedure GuiLeaveCallback(AObj: TObject);
begin
  // Popped by IDENTITY. Enter and Leave are always paired in a try/finally, so the
  // top IS AObj; saying so keeps a future unpaired call from silently unprotecting
  // somebody else's form instead of failing visibly here.
  if (Length(GInUse) > 0) and (GInUse[High(GInUse)] = AObj) then
    SetLength(GInUse, Length(GInUse) - 1);
end;

function GuiInUse(AObj: TObject): Boolean;
var
  i: Integer;
begin
  if AObj = nil then Exit(False);
  for i := 0 to High(GInUse) do
    if GInUse[i] = AObj then Exit(True);
  Result := False;
end;

// --- frees deferred until the dispatch unwinds (see the interface note) ------
type
  { A deferred free: the same watcher a handle is, so the object it holds can die
    under it -- with its form, its tree, or a free at depth zero -- and leave a
    nil behind instead of a dangling pointer. Never a TGuiHandle, so no reader
    resolves it and control_free refuses it. Owns, always: it exists to free. }
  TGuiPendingFree = class(TGuiRef)
  end;

var
  { How many BASIC handlers are running right now. Every one is entered through
    GuiCallBack, so this is exact. }
  GDispatchDepth: Integer = 0;
  { The registry ids of the deferred frees, in the order they were asked for. }
  GPending: array of Int64;
  { The sender of each handler now running, outermost first; nil where the
    callback had none. Alive while its handler runs -- a deferred free keeps
    every one of them alive until the stack is empty -- so MoveBlocked may
    walk up from it. }
  GSenders: array of TObject;
  { The last serial GuiRegister stamped (TGuiRef.Born). }
  GBirths: Int64 = 0;

function GuiInDispatch: Boolean;
begin
  Result := GDispatchDepth > 0;
end;

function GuiDispatchingFrom(AObj: TObject): Boolean;
var
  i: Integer;
begin
  if AObj = nil then Exit(False);
  for i := 0 to High(GSenders) do
    if GSenders[i] = AObj then Exit(True);
  Result := False;
end;

{ Does AComp die when AObj is freed? A component is freed by its OWNER, so the
  owner chain is the whole answer for a control -- LCL's TWinControl.Destroy only
  UNPARENTS its children ("controls are freed by the owner", wincontrol.inc) --
  except for a menu item, which TMenuItem.Destroy frees along with the items
  under it while their owner is the menu. Every step is a single parent, so this
  is linear in the depth of the tree, never in its size. }
function DiesWith(AComp: TComponent; AObj: TObject): Boolean;
var
  m: TMenuItem;
begin
  while AComp <> nil do
  begin
    if AComp = AObj then Exit(True);
    if AComp is TMenuItem then
    begin
      m := TMenuItem(AComp).Parent;
      while m <> nil do
      begin
        if m = AObj then Exit(True);
        m := m.Parent;
      end;
    end;
    AComp := AComp.Owner;
  end;
  Result := False;
end;

{ Drop every reference -- a program's handle or another deferred free -- to AObj
  or to anything that dies with it, as the free notifications would when it is
  really freed. Run while everything is still alive, which is what lets each
  Control and Holder be asked its owner: the registry's invariant (every non-nil
  Control is live) holds until this returns. }
procedure ForgetDying(AObj: TComponent);
var
  id: Int64;
  i: Integer;
  o: TObject;
  h: TGuiRef;
begin
  id := FirstLiveHandle();
  for i := 1 to LiveHandleCount() do
  begin
    if id = 0 then Break;
    o := HandleObj(id);
    if o is TGuiRef then
    begin
      h := TGuiRef(o);
      if (h.Control <> nil) and
         ((h.Watched and DiesWith(TComponent(h.Control), AObj)) or
          ((h.Holder <> nil) and DiesWith(h.Holder, AObj))) then
      begin
        if h.Watched then TComponent(h.Control).RemoveFreeNotification(h);
        if h.Holder <> nil then h.Holder.RemoveFreeNotification(h);
        h.Holder := nil;
        h.Control := nil;
      end;
    end;
    id := NextLiveHandle(id);
  end;
end;

procedure GuiFreeLater(AHandle: TGuiHandle);
var
  obj: TObject;
  p: TGuiPendingFree;
begin
  obj := AHandle.Control;
  if obj = nil then Exit;
  // What dies with it is dead to the program NOW -- AHandle itself included,
  // since it names the object.
  if AHandle.Holder <> nil then
    GuiForgetNodes(obj)
  else if AHandle.Watched then
    ForgetDying(TComponent(obj));
  // ...and its memory is held by an entry nobody can name, until it is safe.
  p := TGuiPendingFree.Create(nil);
  p.Control := obj;
  p.Born := AHandle.Born;   // the OBJECT's birth, not this entry's
  p.Owns := True;
  p.Watch;
  SetLength(GPending, Length(GPending) + 1);
  GPending[High(GPending)] := RegisterHandle(p);
end;

// --- moves that wait for a walk to finish (see GuiMoveControl) -------------
type
  { One place in the landing queue: a handle by registry id, never by pointer
    (an id is never issued twice, so a handle freed meanwhile resolves to
    nothing), and the stamp it had when queued -- a control moved again is
    queued again, and only its latest place is the live one. }
  TGuiQueued = record
    Id, Seq: Int64;
  end;

var
  GQueue: array of TGuiQueued;
  GQueueLen: Integer = 0;
  GCompactAt: Integer = 64;
  GMoveStamp: Int64 = 0;

{ The live object a program's handle names, if it is an AClass; else nil. }
function LiveObj(AId: Int64; AClass: TClass): TObject;
var o: TObject;
begin
  Result := nil;
  o := HandleObj(AId);
  if (o is TGuiHandle) and (TGuiHandle(o).Control <> nil) and
     TGuiHandle(o).Control.InheritsFrom(AClass) then
    Result := TGuiHandle(o).Control;
end;

procedure ClearMove(AHandle: TGuiHandle);
begin
  AHandle.MoveTo := nil;
  AHandle.MoveSeq := 0;
  AHandle.TabSet := False;
  AHandle.TabWanted := 0;
  AHandle.ZWanted := 0;
end;

{ Where AHandle's waiting moves take its control: True with the last parent
  asked for that is still alive (nil for the top level), False when none is.
  A dead parent never comes back -- its id is never issued again -- so it is
  dropped for good, and this costs one step per parent ever dropped. }
function ResolveTarget(AHandle: TGuiHandle; out AParent: TWinControl): Boolean;
var t: Int64;
begin
  AParent := nil;
  while Length(AHandle.MoveTo) > 0 do
  begin
    t := AHandle.MoveTo[High(AHandle.MoveTo)];
    if t = 0 then Exit(True);
    AParent := TWinControl(LiveObj(t, TWinControl));
    if AParent <> nil then Exit(True);
    SetLength(AHandle.MoveTo, Length(AHandle.MoveTo) - 1);
  end;
  Result := False;
end;

{ Could a walk be standing on the list AChild would leave? See GuiMoveControl:
  AChild, or its parent, is a running handler's sender or an ancestor of one.
  The senders are live (a deferred free keeps each one alive while its handler
  runs) and so is every parent of a live control, so the chains read here are
  live. }
function MoveBlocked(AChild: TControl): Boolean;
var
  i: Integer;
  w: TControl;
  par: TWinControl;
begin
  par := AChild.Parent;
  for i := 0 to High(GSenders) do
    if GSenders[i] is TControl then
    begin
      w := TControl(GSenders[i]);
      while w <> nil do
      begin
        if (w = AChild) or ((par <> nil) and (w = par)) then Exit(True);
        w := w.Parent;
      end;
    end;
  Result := False;
end;

function GuiMovePending(AObj: TObject): TGuiHandle;
begin
  Result := nil;
  if GQueueLen = 0 then Exit;   // nothing waits: no lookup at all
  Result := HandleOf(AObj);
  if (Result <> nil) and (Result.MoveSeq = 0) then Result := nil;
end;

function GuiEffectiveParent(AObj: TObject): TWinControl;
var h: TGuiHandle;
begin
  Result := nil;
  if not (AObj is TControl) then Exit;
  h := GuiMovePending(AObj);
  if (h <> nil) and ResolveTarget(h, Result) then Exit;
  Result := TControl(AObj).Parent;
end;

function GuiWouldCycle(AChild: TObject; AParent: TWinControl;
  APending: Boolean): Boolean;
var
  w: TWinControl;
  steps, limit: Int64;
begin
  { The pending chain can loop even though every move was refused a cycle
    when asked: a move whose new parent then dies lets an EARLIER move of the
    same control count again. No real chain is longer than the number of live
    handles plus the unregistered tops, so a walk past that is a loop -- and a
    loop is a cycle, refused. }
  limit := LiveHandleCount() + 64;
  steps := 0;
  w := AParent;
  while w <> nil do
  begin
    if w = AChild then Exit(True);
    Inc(steps);
    if steps > limit then Exit(True);
    if APending then w := GuiEffectiveParent(w) else w := w.Parent;
  end;
  Result := False;
end;

{ The move itself, at a moment no walk can stand on the list it leaves. It asks
  app_run nothing: a window that stops being one asked when the move was asked
  (GuiMoveControl), which is when the program's view changed. }
procedure GuiRadioRealize(R: TControl);
begin
  if not (R is TRadioButton) then Exit;
  if (R.Parent = nil) or not R.Parent.HandleAllocated then Exit;
  if TWinControl(R).HandleAllocated then Exit;
  { Only where the parent has a window already: that is a place a window can
    be made without realizing anything new (an unshown form's tree has none,
    and the LCL's own handle-less walk covers it). }
  try
    TWinControl(R).HandleNeeded;
  except
    on Exception do ;   // no window: the walk below still covers the state
  end;
end;

procedure GuiRadioExclusive(R: TControl);
var
  p: TWinControl;
  sibs: array of TRadioButton;
  i, n: Integer;
begin
  if not (R is TRadioButton) then Exit;
  p := R.Parent;
  if (p = nil) or not TRadioButton(R).Checked then Exit;
  { A snapshot: unchecking a sibling runs its onchange, which may make,
    move or free controls of p (a move out of p waits and a free is
    deferred while it runs -- see GuiMoveControl -- but a control made is
    appended). Each is asked again before it is touched. }
  n := 0;
  SetLength(sibs, p.ControlCount);
  for i := 0 to p.ControlCount - 1 do
    if (p.Controls[i] is TRadioButton) and (p.Controls[i] <> R) then
    begin
      sibs[n] := TRadioButton(p.Controls[i]);
      Inc(n);
    end;
  for i := 0 to n - 1 do
  begin
    if not TRadioButton(R).Checked then Exit;   // a handler chose another
    if (sibs[i].Parent = p) and sibs[i].Checked then
      try
        sibs[i].Checked := False;
      except
        on Exception do GGuiError := 1;
      end;
  end;
end;

procedure DoMove(AChild: TControl; AParent: TWinControl);
begin
  try
    AChild.Parent := AParent;
  except
    // The LCL refuses some pairings itself (EInvalidOperation): recorded,
    // never raised into the program.
    on Exception do begin GGuiError := 1; Exit; end;
  end;
  { A checked radio arriving is a check: it wins (see GuiRadioExclusive).
    Only a CHECKED one is given a window here: on gtk2 a radio whose window
    starts a group of its own is created active, and an unchecked one would
    then read checked (a gtk radio cannot be unchecked alone). }
  if (AChild is TRadioButton) and (AParent <> nil) and TRadioButton(AChild).Checked then
  begin
    GuiRadioRealize(AChild);
    GuiRadioExclusive(AChild);
  end;
end;

{ What the program set relative to the new parent while the move waited --
  the front/back of it. The tab position is imposed by LandMoves. }
procedure ApplyZ(AChild: TControl; AZ: Integer);
begin
  try
    if AZ = 1 then AChild.BringToFront
    else if AZ = 2 then AChild.SendToBack;
  except
    on Exception do GGuiError := 1;
  end;
end;

{ Keep only the queue's live places, in order: the queue grows by one place
  per waiting request, and this keeps it within twice what is waiting. }
procedure CompactQueue;
var
  i, n: Integer;
  o: TObject;
begin
  n := 0;
  for i := 0 to GQueueLen - 1 do
  begin
    o := HandleObj(GQueue[i].Id);
    if (o is TGuiHandle) and (TGuiHandle(o).MoveSeq = GQueue[i].Seq) then
    begin
      GQueue[n] := GQueue[i];
      Inc(n);
    end;
  end;
  GQueueLen := n;
  GCompactAt := 2 * n + 64;
end;

procedure Enqueue(AHandle: TGuiHandle; AId: Int64);
begin
  if GQueueLen >= GCompactAt then CompactQueue;
  Inc(GMoveStamp);
  AHandle.MoveSeq := GMoveStamp;
  if GQueueLen >= Length(GQueue) then SetLength(GQueue, 2 * GQueueLen + 16);
  GQueue[GQueueLen].Id := AId;
  GQueue[GQueueLen].Seq := GMoveStamp;
  Inc(GQueueLen);
end;

procedure GuiMoveControl(AChildId, AParentId: Int64; AChild: TControl;
  AParent: TWinControl);
var
  h: TGuiHandle;
  o: TObject;
  i, j: Integer;
begin
  { A window on screen placed inside another stops being a window NOW, in the
    program's view, landed or not: asked here, before the move is recorded. }
  if AParent <> nil then GuiWindowLeaving(AChild);
  o := HandleObj(AChildId);
  if o is TGuiHandle then h := TGuiHandle(o) else h := nil;
  if ((h = nil) or (h.MoveSeq = 0)) and not MoveBlocked(AChild) then
  begin
    DoMove(AChild, AParent);
    Exit;
  end;
  if h = nil then Exit;   // every caller passes the child's live handle
  // Each parent once, the latest last (see TGuiHandle.MoveTo).
  for i := 0 to High(h.MoveTo) do
    if h.MoveTo[i] = AParentId then
    begin
      for j := i to High(h.MoveTo) - 1 do h.MoveTo[j] := h.MoveTo[j + 1];
      SetLength(h.MoveTo, Length(h.MoveTo) - 1);
      Break;
    end;
  SetLength(h.MoveTo, Length(h.MoveTo) + 1);
  h.MoveTo[High(h.MoveTo)] := AParentId;
  Enqueue(h, AChildId);
end;

{ ONE WAITING MOVE, read off its handle while it is still waiting: what
  LandMoves does with it and what GuiTabOrder replays. Read from a live
  place of the queue only (the handle alive, the place its latest). }
type
  TGuiLanding = record
    Id, Seq: Int64;
    Ctl: TControl;
    Has: Boolean;          // a target still alive (nil target: the top level)
    Target: TWinControl;
    TabSet: Boolean;
    Tab, Z: Integer;
  end;
  TGuiLandings = array of TGuiLanding;
  TGuiWinList = array of TWinControl;

function ReadLanding(const AQ: TGuiQueued; out L: TGuiLanding): Boolean;
var
  o: TObject;
  h: TGuiHandle;
begin
  Result := False;
  L.Id := AQ.Id;
  L.Seq := AQ.Seq;
  L.Ctl := nil;
  L.Has := False;
  L.Target := nil;
  L.TabSet := False;
  L.Tab := 0;
  L.Z := 0;
  o := HandleObj(AQ.Id);
  if not (o is TGuiHandle) then Exit;
  h := TGuiHandle(o);
  if (h.MoveSeq <> AQ.Seq) or not (h.Control is TControl) then Exit;
  L.Ctl := TControl(h.Control);
  L.Has := ResolveTarget(h, L.Target);
  L.TabSet := h.TabSet;
  L.Tab := h.TabWanted;
  L.Z := h.ZWanted;
  Result := True;
end;

{ Does the landing of L physically move its control? Not when its target is
  where it is, and not for a form in a modal session (refused at landing). }
function LandingMoves(const L: TGuiLanding): Boolean;
begin
  Result := L.Has and (L.Target <> L.Ctl.Parent) and
    not ((L.Ctl is TCustomForm) and (fsModal in TCustomForm(L.Ctl).FormState));
end;

{ AParent's tab chain as it stands: its windowed children in FTabList order,
  which is what TabOrder indexes (TWinControl.GetTabOrder). }
function TabChain(AParent: TWinControl): TGuiWinList;
var
  i, n, k, extra: Integer;
  w: TControl;
  spill: TGuiWinList;
begin
  Result := nil;
  n := 0;
  for i := 0 to AParent.ControlCount - 1 do
    if AParent.Controls[i] is TWinControl then Inc(n);
  SetLength(Result, n);
  for i := 0 to n - 1 do Result[i] := nil;
  spill := nil;
  extra := 0;
  for i := 0 to AParent.ControlCount - 1 do
  begin
    w := AParent.Controls[i];
    if not (w is TWinControl) then Continue;
    k := TWinControl(w).TabOrder;
    if (k >= 0) and (k < n) and (Result[k] = nil) then
      Result[k] := TWinControl(w)
    else
    begin
      SetLength(spill, extra + 1);   // never expected: kept, never dropped
      spill[extra] := TWinControl(w);
      Inc(extra);
    end;
  end;
  k := 0;
  for i := 0 to n - 1 do
    if (Result[i] = nil) and (k < extra) then
    begin
      Result[i] := spill[k];
      Inc(k);
    end;
end;

procedure ChainRemove(var L: TGuiWinList; W: TWinControl);
var i, j: Integer;
begin
  for i := 0 to High(L) do
    if L[i] = W then
    begin
      for j := i to High(L) - 1 do L[j] := L[j + 1];
      SetLength(L, Length(L) - 1);
      Exit;
    end;
end;

procedure ChainAppend(var L: TGuiWinList; W: TWinControl);
begin
  SetLength(L, Length(L) + 1);
  L[High(L)] := W;
end;

{ W to position V, as TWinControl.UpdateTabOrder puts it: out of the chain,
  then in at V -- at the end when V is negative or past it. }
procedure ChainPlace(var L: TGuiWinList; W: TWinControl; V: Integer);
var j: Integer;
begin
  ChainRemove(L, W);
  if (V < 0) or (V >= Length(L)) then
  begin
    ChainAppend(L, W);
    Exit;
  end;
  SetLength(L, Length(L) + 1);
  for j := High(L) downto V + 1 do L[j] := L[j - 1];
  L[V] := W;
end;

{ AParent's chain once the landings AL[0..ACount-1] have landed, in that
  order, each placed where it was asked to be. }
function LandedChain(AParent: TWinControl; const AL: TGuiLandings;
  ACount: Integer): TGuiWinList;
var
  i: Integer;
  x: TWinControl;
  after: TWinControl;
begin
  Result := TabChain(AParent);
  for i := 0 to ACount - 1 do
  begin
    if not (AL[i].Ctl is TWinControl) then Continue;
    x := TWinControl(AL[i].Ctl);
    after := x.Parent;
    if LandingMoves(AL[i]) then
    begin
      if x.Parent = AParent then ChainRemove(Result, x);
      if AL[i].Target = AParent then ChainAppend(Result, x);
      after := AL[i].Target;
    end;
    if AL[i].TabSet and (after = AParent) then ChainPlace(Result, x, AL[i].Tab);
  end;
end;

function GuiTabOrder(AObj: TWinControl): Integer;
var
  lp: TWinControl;
  al: TGuiLandings;
  n, i: Integer;
  chain: TGuiWinList;
begin
  Result := AObj.TabOrder;
  if GQueueLen = 0 then Exit;
  lp := GuiEffectiveParent(AObj);
  if lp = nil then Exit;
  SetLength(al, GQueueLen);
  n := 0;
  for i := 0 to GQueueLen - 1 do
    if ReadLanding(GQueue[i], al[n]) then Inc(n);
  chain := LandedChain(lp, al, n);
  for i := 0 to High(chain) do
    if chain[i] = AObj then Exit(i);
end;

{ Land the waiting moves, each control's at its latest place in the queue.
  AInSession: a move still blocked by a handler running under the session
  waits on, ahead of anything queued while this ran.

  A move whose target is, right now, inside the control itself is one whose
  way out is another waiting move that has not landed yet (each was refused a
  cycle against the program's view when asked): it waits for the next pass.
  A pass that lands nothing leaves only real cycles -- a target freed
  meanwhile let an earlier ask count again -- and the latest asked of them is
  refused (gui_error 1) before the next pass. Each pass lands or refuses one
  at least, so this ends; it costs a pass per move that had to wait, which
  only such a sequence makes. }
procedure LandMoves(AInSession: Boolean);
var
  q, kept, rest: array of TGuiQueued;
  land: TGuiLandings;
  waiting, still: array of Integer;
  landed: array of Boolean;
  parents: TGuiWinList;
  chains: array of TGuiWinList;
  n, nk, nr, nl, nw, ns, np, i, j, k: Integer;
  o: TObject;
  h: TGuiHandle;
  c: TControl;
  p: TWinControl;
  progress: Boolean;
  fin: TGuiWinList;

  procedure AddParent(AP: TWinControl);
  var t: Integer;
  begin
    if AP = nil then Exit;
    for t := 0 to np - 1 do
      if parents[t] = AP then Exit;
    SetLength(parents, np + 1);
    parents[np] := AP;
    Inc(np);
  end;

  { The handle of land[AIdx] when that place is still its live one -- a
    handler run by a landing may have asked for it again, or freed it. }
  function LiveHandle(AIdx: Integer): TGuiHandle;
  var ob: TObject;
  begin
    Result := nil;
    ob := HandleObj(land[AIdx].Id);
    if (ob is TGuiHandle) and (TGuiHandle(ob).MoveSeq = land[AIdx].Seq) and
       (TGuiHandle(ob).Control = land[AIdx].Ctl) then
      Result := TGuiHandle(ob);
  end;

begin
  if GQueueLen = 0 then Exit;
  // Off the queue first: a landing can fire a handler that asks for another.
  q := GQueue;
  n := GQueueLen;
  GQueue := nil;
  GQueueLen := 0;
  GCompactAt := 64;
  kept := nil;
  nk := 0;
  SetLength(land, n);
  nl := 0;
  for i := 0 to n - 1 do
  begin
    o := HandleObj(q[i].Id);
    if not (o is TGuiHandle) then Continue;          // the control was freed
    h := TGuiHandle(o);
    if h.MoveSeq <> q[i].Seq then Continue;          // an older place of it
    if not (h.Control is TControl) then begin ClearMove(h); Continue; end;
    c := TControl(h.Control);
    if AInSession and MoveBlocked(c) then
    begin
      SetLength(kept, nk + 1);
      kept[nk] := q[i];
      Inc(nk);
      Continue;
    end;
    if ReadLanding(q[i], land[nl]) then Inc(nl);
  end;

  // The chains the program was told, before anything moves (GuiTabOrder).
  parents := nil;
  np := 0;
  for i := 0 to nl - 1 do
    if land[i].Ctl is TWinControl then
    begin
      AddParent(land[i].Ctl.Parent);
      if land[i].Has then AddParent(land[i].Target);
    end;
  SetLength(chains, np);
  for k := 0 to np - 1 do chains[k] := LandedChain(parents[k], land, nl);

  // The moves.
  SetLength(landed, nl);
  SetLength(waiting, nl);
  for i := 0 to nl - 1 do
  begin
    landed[i] := False;
    waiting[i] := i;
  end;
  nw := nl;
  SetLength(still, nl);
  while nw > 0 do
  begin
    progress := False;
    ns := 0;
    for j := 0 to nw - 1 do
    begin
      i := waiting[j];
      h := LiveHandle(i);
      if h = nil then Continue;   // asked again meanwhile: it waits in the new queue
      c := land[i].Ctl;
      if ResolveTarget(h, p) and (p <> c.Parent) then
      begin
        if (c is TCustomForm) and (fsModal in TCustomForm(c).FormState) then
        begin
          ClearMove(h);
          GGuiError := 1;   // what was asked can no longer be done
          progress := True;
          Continue;
        end;
        if (p <> nil) and GuiWouldCycle(c, p, False) then
        begin
          still[ns] := i;   // inside itself only until another lands
          Inc(ns);
          Continue;
        end;
        ClearMove(h);
        DoMove(c, p);
      end
      else
        ClearMove(h);
      landed[i] := True;
      progress := True;
    end;
    if (ns > 0) and not progress then
    begin
      // Nothing can land: a real cycle. The latest asked is refused.
      h := LiveHandle(still[ns - 1]);
      if h <> nil then ClearMove(h);
      GGuiError := 1;
      Dec(ns);
    end;
    for j := 0 to ns - 1 do waiting[j] := still[j];
    nw := ns;
  end;

  // Front or back in the new parent, in ask order.
  for i := 0 to nl - 1 do
    if landed[i] and (land[i].Z <> 0) then ApplyZ(land[i].Ctl, land[i].Z);

  { The tab chains, as told: what each parent holds now, in the order told,
    and anything it holds that the program was not told of after them. }
  for k := 0 to np - 1 do
  begin
    fin := nil;
    for i := 0 to High(chains[k]) do
      if chains[k][i].Parent = parents[k] then ChainAppend(fin, chains[k][i]);
    chains[k] := TabChain(parents[k]);   // reused: what it holds now
    for i := 0 to High(chains[k]) do
    begin
      j := 0;
      while (j <= High(fin)) and (fin[j] <> chains[k][i]) do Inc(j);
      if j > High(fin) then ChainAppend(fin, chains[k][i]);
    end;
    for i := 0 to High(fin) do
      try
        if fin[i].TabOrder <> i then fin[i].TabOrder := i;
      except
        on Exception do GGuiError := 1;
      end;
  end;

  if nk = 0 then Exit;
  // What waits goes back AHEAD of anything a landing queued meanwhile.
  rest := GQueue;
  nr := GQueueLen;
  GQueue := nil;
  SetLength(GQueue, nk + nr + 16);
  for i := 0 to nk - 1 do GQueue[i] := kept[i];
  for i := 0 to nr - 1 do GQueue[nk + i] := rest[i];
  GQueueLen := nk + nr;
  GCompactAt := 2 * GQueueLen + 64;
end;

type
  TGuiFormList = array of TCustomForm;

{ The forms a free of AObj leaves without a host: each form held by a container
  that dies with AObj, the form itself not dying. Walks what the free destroys
  -- the components AObj owns, all the way down, and the controls each dying
  container holds -- with a stack of its own, never the live handles. }
function OrphanFormsOf(AObj: TComponent): TGuiFormList;
var
  stack: array of TComponent;
  sp, i, n: Integer;
  comp: TComponent;
  c: TControl;
begin
  Result := nil;
  n := 0;
  SetLength(stack, 16);
  stack[0] := AObj;
  sp := 1;
  while sp > 0 do
  begin
    Dec(sp);
    comp := stack[sp];
    if comp is TWinControl then
      for i := 0 to TWinControl(comp).ControlCount - 1 do
      begin
        c := TWinControl(comp).Controls[i];
        if (c is TCustomForm) and not DiesWith(c, AObj) then
        begin
          SetLength(Result, n + 1);
          Result[n] := TCustomForm(c);
          Inc(n);
        end;
      end;
    for i := 0 to comp.ComponentCount - 1 do
    begin
      if sp >= Length(stack) then SetLength(stack, 2 * Length(stack));
      stack[sp] := comp.Components[i];
      Inc(sp);
    end;
  end;
end;

procedure GuiReleaseOrphanedForms(AObj: TObject);
var
  list: TGuiFormList;
  i: Integer;
  f: TCustomForm;
  h: TGuiHandle;
  p: TWinControl;
begin
  if not (AObj is TWinControl) then Exit;   // only a container holds a form
  list := OrphanFormsOf(TComponent(AObj));
  for i := 0 to High(list) do
  begin
    f := list[i];
    h := HandleOf(f);
    { A waiting move that takes it to a living parent, or to the top level,
      lands before the free does: then it is not left without a host. }
    if (h <> nil) and (h.MoveSeq <> 0) and ResolveTarget(h, p) then Continue;
    try
      f.Visible := False;
    except
      on Exception do ;   // hiding is housekeeping; the free goes on
    end;
    if h <> nil then
      GuiMoveControl(h.Id, 0, f, nil)
    else if not MoveBlocked(f) then
      DoMove(f, nil);
  end;
end;

{ AT THE FREE ITSELF, after every move that could land has landed (round 9).
  GuiReleaseOrphanedForms judged each form when the free was ASKED, and left
  alone one whose waiting move takes it to a living parent; if that parent is
  freed too before the move lands, the move does not happen and the form is
  still held by the host dying now -- an orphan nobody released. It is
  released here, as the rule says: hidden, and a top-level form, rather than
  left Visible with no window by TWinControl.Destroy. Nothing stands on the
  list it leaves: at depth 0 nothing runs, and what a modal session frees was
  born inside it, which no frame below the session can be walking. }
procedure SettleOrphansAtFree(AObj: TObject);
var
  list: TGuiFormList;
  i: Integer;
begin
  if not (AObj is TWinControl) then Exit;
  list := OrphanFormsOf(TComponent(AObj));
  for i := 0 to High(list) do
  begin
    try
      list[i].Visible := False;
    except
      on Exception do ;   // hiding is housekeeping; the free goes on
    end;
    DoMove(list[i], nil);
  end;
end;

function GuiPendingMark: Integer;
begin
  Result := Length(GPending);
end;

function GuiBirthMark: Int64;
begin
  Result := GBirths;
end;

function GuiDispatchDepth: Integer;
begin
  Result := GDispatchDepth;
end;

procedure GuiFlushFreesSince(ABirthMark: Int64; ADepth: Integer);
var
  list, kept: array of Int64;
  i: Integer;
  o: TObject;
begin
  if GDispatchDepth > ADepth then Exit;
  LandMoves(True);   // before the frees, as at depth 0 (GuiFlushFrees)
  if Length(GPending) = 0 then Exit;
  list := GPending;
  GPending := nil;   // off the list first, as GuiFlushFrees does
  kept := nil;
  for i := 0 to High(list) do
  begin
    { ONLY WHAT WAS BORN INSIDE THE SESSION (see the interface note). Round 6
      kept an entry only when a running handler's SENDER died with it -- the
      timer whose tick opened the modal -- which is one of the things under the
      session, not the class of them. An entry whose object already died (its
      form went first) holds nothing and may go. }
    o := HandleObj(list[i]);
    if (o is TGuiRef) and (TGuiRef(o).Control <> nil) and
       (TGuiRef(o).Born <= ABirthMark) then
    begin
      SetLength(kept, Length(kept) + 1);
      kept[High(kept)] := list[i];
    end
    else
    begin
      if o is TGuiRef then SettleOrphansAtFree(TGuiRef(o).Control);
      FreeHandle(list[i]);
    end;
  end;
  { Put back AHEAD of anything a destructor above queued meanwhile, in the
    order they were asked for. }
  list := GPending;
  GPending := kept;
  for i := 0 to High(list) do
  begin
    SetLength(GPending, Length(GPending) + 1);
    GPending[High(GPending)] := list[i];
  end;
end;

procedure GuiEndModals;
var i: Integer;
begin
  for i := Screen.CustomFormCount - 1 downto 0 do
    if fsModal in Screen.CustomForms[i].FormState then
      Screen.CustomForms[i].ModalResult := mrCancel;
end;

procedure GuiFlushFrees;
var
  list: array of Int64;
  i: Integer;
  o: TObject;
begin
  if GDispatchDepth > 0 then Exit;
  { The deferred moves land FIRST, in the order asked: one into a parent the
    program freed afterwards then finds that parent's handle dead and does not
    land, rather than landing in a parent already gone. }
  LandMoves(False);
  if Length(GPending) = 0 then Exit;
  // Taken off the list FIRST: freeing a form can run a destructor that reaches a
  // GUI function, and that must find nothing left to flush rather than this list.
  list := GPending;
  GPending := nil;
  for i := 0 to High(list) do
  begin
    o := HandleObj(list[i]);
    if o is TGuiRef then SettleOrphansAtFree(TGuiRef(o).Control);
    FreeHandle(list[i]);   // a no-op for an id ResetHandles already took
  end;
end;

{ An event of a control whose handle is dead does not reach BASIC: the program
  freed it, so as far as the program knows it no longer exists. Every bridge
  passes its sender's handle first; anything else passes through. }
function SenderDead(const AArgs: array of TValue): Boolean;
var
  o: TObject;
begin
  Result := False;
  if (Length(AArgs) = 0) or (AArgs[0].Kind <> vkHandle) then Exit;
  o := HandleObj(AArgs[0].Hnd);
  Result := not ((o is TGuiHandle) and (TGuiHandle(o).Control <> nil));
end;

function GuiCallBack(AVM: TPhosphorVM; const AHandler: String;
  const AArgs: array of TValue): TValue;
var
  err: TPhosphorError;
  handler: String;
begin
  Result := ValInt(0);
  { OUR OWN COPY OF THE NAME (round 6). AHandler is const, usually the bridge's
    FHandler: a handler that re-binds its own event (or frees its sender, whose
    bridge goes with it) drops the last reference while this call still reads it,
    and the fault report printed whatever the freed memory held. }
  handler := AHandler;
  if (AVM = nil) or (handler = '') then Exit;
  { A HALTED SESSION RUNS NOTHING, AND THAT IS NOT A FAULT (round 6): END inside
    a modal closes it, and the close asks onclosequery and onclose, which the
    halted VM refuses -- reported as two handler faults with "the program
    carries on", about a program that had just ended. }
  if AVM.Halted then Exit;
  if SenderDead(AArgs) then Exit;
  Inc(GDispatchDepth);
  // The sender is live here (SenderDead said so) or there is none; either way
  // the slot is popped in the finally, so the stack is exactly the senders of
  // the handlers now running, outermost first.
  SetLength(GSenders, GDispatchDepth);
  if (Length(AArgs) > 0) and (AArgs[0].Kind = vkHandle) then
    GSenders[GDispatchDepth - 1] := TGuiHandle(HandleObj(AArgs[0].Hnd)).Control
  else
    GSenders[GDispatchDepth - 1] := nil;
  try
    Result := AVM.CallUserFunc(handler, AArgs, err);
  finally
    Dec(GDispatchDepth);
    SetLength(GSenders, GDispatchDepth);
  end;
  if IsError(err) then
  begin
    GGuiError := 2;   // a handler that failed is recorded, not raised
    { ...and REPORTED, by whoever the host says. ErrorLine is the faulting
      statement's line: CallUserFunc copies LastError out of the ExecFrom that
      set both. }
    if Assigned(GuiOnHandlerFault) then
      GuiOnHandlerFault(handler, AVM.ErrorLine, err.Message);
  end;
  { A handler that says END means the program is over. The engine records that
    instead of quietly ending only the handler's own activation, so the window it
    was clicked in has to go too -- otherwise `end` in a click handler is a
    statement that does nothing, which is a worse answer than the bug it replaced.

    IT LEAVES THE LOOP; IT DOES NOT TERMINATE THE APPLICATION. This was the third
    caller of Application.Terminate in the GUI, and the same objection applies to
    it as to the other two: that flag has no public way to be cleared, so a host
    running one script after another -- which is the whole embedding story -- got
    a dead GUI for every script after the first one that said `end` in a handler.
    Found while fixing the other two rather than reported, and closed with them
    because it is the same mechanism and not a third bug.

    Nothing is lost by the narrower answer: AVM.Halted is already set, so when
    this library call returns, the dispatch loop sees it and ends the program.
    Leaving the message loop is exactly what has to happen here; ending the
    process is what happens next, on its own. }
  if AVM.Halted then
  begin
    GuiLeaveLoop;
    GuiEndModals;
  end;
end;

function TGuiEventBridge.Call(const AArgs: array of TValue): TValue;
begin
  Result := GuiCallBack(FVM, FHandler, AArgs);
end;

procedure TGuiEventBridge.Fire(Sender: TObject);
begin
  Call([ValHandle(FSenderId)]);
end;

procedure TGuiEventBridge.FireKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  // Key stays a var parameter in the LCL signature, but the handler's answer does
  // NOT write to it: a routine that falls off its end would swallow the keystroke.
  Call([ValHandle(FSenderId), ValInt(Key), ValStr(GuiModsStr(Shift))]);
end;

procedure TGuiEventBridge.FireKeyPress(Sender: TObject; var Key: char);
begin
  Call([ValHandle(FSenderId), ValStr(Key)]);
end;

procedure TGuiEventBridge.FireMouse(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  // mbLeft/mbRight/mbMiddle are 0/1/2 by declaration order, which is the encoding
  // the plan specified.
  Call([ValHandle(FSenderId), ValInt(Ord(Button)), ValInt(X), ValInt(Y),
        ValStr(GuiModsStr(Shift))]);
end;

procedure TGuiEventBridge.FireMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Integer);
begin
  Call([ValHandle(FSenderId), ValInt(X), ValInt(Y), ValStr(GuiModsStr(Shift))]);
end;

procedure TGuiEventBridge.FireMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
var
  v: TValue;
begin
  v := Call([ValHandle(FSenderId), ValInt(WheelDelta), ValInt(MousePos.X),
             ValInt(MousePos.Y), ValStr(GuiModsStr(Shift))]);
  // Only an explicit boolean true claims the wheel. A number, or no return at all,
  // leaves LCL's default handling in place.
  if (v.Kind = vkBool) and v.Bl then
    Handled := True;
end;

procedure TGuiEventBridge.FireClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  // Notification only. Rewriting CloseAction from a return value would turn a
  // handler that forgets to answer into one that changes what closing means.
  // The sender is marked in use because TCustomForm.Close keeps working on it
  // after this returns -- see the note on GuiInUse.
  GuiEnterCallback(Sender);
  try
    Call([ValHandle(FSenderId)]);
  finally
    GuiLeaveCallback(Sender);
  end;
end;

procedure TGuiEventBridge.FireCloseQuery(Sender: TObject; var CanClose: Boolean);
var
  v: TValue;
begin
  // Same protection as FireClose, and needed even more here: this handler runs
  // BEFORE the close proper, so everything the form does afterwards is ahead of it.
  GuiEnterCallback(Sender);
  try
    v := Call([ValHandle(FSenderId)]);
  finally
    GuiLeaveCallback(Sender);
  end;
  // Only an explicit boolean false vetoes. A handler that falls off its end must
  // not be able to make a window impossible to close -- that is the one failure
  // here a program cannot recover from.
  if (v.Kind = vkBool) and (not v.Bl) then
    CanClose := False;
end;

function GuiModsStr(Shift: TShiftState): String;
const
  NAMES: array[0..2] of String = ('S', 'C', 'A');
var
  i: Integer;
  present: array[0..2] of Boolean;
begin
  present[0] := ssShift in Shift;
  present[1] := ssCtrl in Shift;
  present[2] := ssAlt in Shift;
  Result := '';
  for i := 0 to 2 do
    if present[i] then
    begin
      if Result <> '' then Result := Result + ' ';
      Result := Result + NAMES[i];
    end;
end;

function GuiExtentOk(AWidth, AHeight: Integer): Boolean;
begin
  // Only the upper end is the LCL's: a negative width is absorbed by the control,
  // not trapped, so it stays the caller's business as it always was.
  Result := (AWidth <= GuiMaxExtent) and (AHeight <= GuiMaxExtent);
  if not Result then GGuiError := 1;
end;

function GuiPosOk(ALeft, ATop: Integer): Boolean;
begin
  Result := (ALeft >= GuiMinPos) and (ALeft <= GuiMaxPos) and
            (ATop >= GuiMinPos) and (ATop <= GuiMaxPos);
  if not Result then GGuiError := 1;
end;

type
  { The protected hook, reached the standard way: a type that is never
    instantiated, so a cast can name a member of an instance we already hold. }
  TCapAccess = class(TControl);

  { One object for the whole process; its method is the ConstrainedResize hook. }
  TGuiSizeCap = class
    procedure Cap(Sender: TObject; var MinWidth, MinHeight,
                  MaxWidth, MaxHeight: TConstraintSize);
  end;

var
  GSizeCap: TGuiSizeCap;

procedure TGuiSizeCap.Cap(Sender: TObject; var MinWidth, MinHeight,
                          MaxWidth, MaxHeight: TConstraintSize);
begin
  // 0 is the LCL's "no maximum", so it is the case that matters most.
  if (MaxWidth = 0) or (MaxWidth > GuiMaxExtent) then MaxWidth := GuiMaxExtent;
  if (MaxHeight = 0) or (MaxHeight > GuiMaxExtent) then MaxHeight := GuiMaxExtent;
  if MinWidth > GuiMaxExtent then MinWidth := GuiMaxExtent;
  if MinHeight > GuiMaxExtent then MinHeight := GuiMaxExtent;
end;

procedure GuiCapSizes(AObj: TObject);
begin
  if not (AObj is TControl) or (GSizeCap = nil) then Exit;
  TCapAccess(AObj).OnConstrainedResize := @GSizeCap.Cap;
end;

{ Clamped at zero because that is what the framework makes of a negative size, and
  because it is what keeps the product below from being a large POSITIVE number
  built out of two negatives: (-100000) * (-100000) is 10^10, and refusing on that
  would turn today's harmless empty bitmap into an error. }
function AtLeastZero(const N: Int64): Int64;
begin
  if N < 0 then Result := 0 else Result := N;
end;

{ EACH UNIT COUNT IS BOUNDED BEFORE IT IS PRICED, which is what keeps every one of
  these inside an Int64. A dimension arrives as an Integer, so the PRODUCT of two
  is at most (2^31-1)^2 < 2^62 and cannot overflow; multiplying that product by a
  per-unit cost can. So the count is compared against a ceiling first, and only a
  count that passed is multiplied.

  THE CEILING IS THE OVERFLOW BOUNDARY, NOT THE BUDGET, and that is deliberate. It
  would have been simpler to saturate anything past the budget -- the comparison
  comes out the same either way -- but then a refusal could not state what the
  thing actually costs, and imagelist@(8192, 8192) reported "8796093022207.9 MB"
  instead of the 1280 MB it really wants. Everything reachable prices exactly;
  only a size built from two near-maximum Integers saturates, and that one is
  described in words instead of printed. }
const
  { 2^55-ish: larger than any product a pair of Integers can make and still be
    priced (the dearest unit here is 160 B), far smaller than where Int64 ends. }
  GuiCostCeiling = High(Int64) div 256;

function GuiSurfaceBytes(AWidth, AHeight: Int64): Int64;
var
  w, h, px: Int64;
begin
  w := AtLeastZero(AWidth);
  h := AtLeastZero(AHeight);
  px := w * h;                                  // both <= 2^31, so this fits
  // NO PIXELS, NO ROWS. The per-row term is real (a 1-pixel-wide column measured
  // at 9.55 B/px against a square bitmap's 5.9), but it must not be charged on its
  // own: bitmap@(0, 2000000000) allocates nothing at all in the LCL, and pricing
  // its two billion empty rows at 4 bytes each would have refused 8 GB for a
  // bitmap that costs nothing. Same reason bitmap@(-5, -5) stays free.
  if px = 0 then Exit(0);
  if px > GuiCostCeiling then Exit(High(Int64));
  Result := px * GuiSurfaceBytesPerPixel + h * GuiSurfaceBytesPerRow;
end;

{ AND THIS ONE IS PRICED BY MAGNITUDE, NOT CLAMPED AT ZERO -- the one place where
  the "a negative size is an empty thing" rule of the other two is simply false.
  TBitmap clamps: bitmap@(-100000, -100000) commits nothing, which is why clamping
  is right there and why refusing it would be a regression. TImageList does not
  clamp; it keeps the sign and then spends the magnitude. Measured on the
  UNPATCHED build, imagelist@(-d, -d) plus one 8x8 entry:

      -1024 -> 0 MB     -4096 -> 280 MB     -8192 -> 1281 MB
      -16384 -> killed past 1780 MB        -100000 -> killed past 1557 MB

  which is the +d curve exactly. A guard that clamped these to zero priced the
  whole family at nothing and left the crash standing, so the magnitude is what is
  charged. (A MIXED pair is not this: imagelist@(-8192, 8192) already answers
  "Range check error" from inside the LCL, catchable, and stays that way.)

  Abs on an Int64 holding at most an Integer cannot overflow. }
function GuiImageListEntryBytes(AWidth, AHeight: Int64): Int64;
var
  px: Int64;
begin
  px := Abs(AWidth) * Abs(AHeight);
  if px > GuiCostCeiling then Exit(High(Int64));
  Result := px * GuiImageListBytesPerPixel;
end;

{ A grid costs three things, and the third one was very nearly left out.

  An earlier draft of this stopped at rows and cells and said, in a comment, "with
  no rows there is no grid, whatever the column count says -- so an enormous
  ColCount on an empty grid is free". That was asserted, not measured, and it is
  false: a grid with ZERO ROWS and 2,000,000 columns costs 672 MB, identically on
  the patched and unpatched builds. Priced at zero, 20,000,000 empty columns would
  have been 6.7 GB through a guard that had just been rewritten to stop exactly
  this.

  So: 150 bytes a ROW, 8 a CELL, and GuiGridBytesPerCol a COLUMN -- 296, the
  plateau of the column sweep the constant's own comment tabulates. (This comment
  said 336 twice while the constant said 296, which is the defect class the grid
  item was raised for in the first place; the number here is now the constant's
  name, so the two cannot drift apart again.) Adding the third term leaves the
  whole swept plane where it was -- 20000 x 1000 goes from 160 MB modelled to
  167 MB against 175 MB measured, which is closer -- and closes the empty-grid
  door. }
function GuiGridBytes(ACols, ARows: Int64): Int64;
var
  c, r, cells: Int64;
begin
  c := AtLeastZero(ACols);
  r := AtLeastZero(ARows);
  if r = 0 then Exit(c * GuiGridBytesPerCol);   // c <= 2^31, so this fits
  cells := c * r;
  if cells > GuiCostCeiling then Exit(High(Int64));
  Result := r * GuiGridBytesPerRow + cells * GuiGridBytesPerCell +
            c * GuiGridBytesPerCol;
end;

// --- the ledger --------------------------------------------------------------
type
  TGuiChargeRec = record
    Obj: TObject;
    Bytes: Int64;
  end;

  { The one thing in this unit that exists only to be told about a death. A charged
    TComponent is asked to notify it, so a grid freed with its parent form -- which
    no handle owns and nothing here would otherwise hear about -- gives its bytes
    back without any cooperation from the handle layer. }
  TGuiLedgerWatch = class(TComponent)
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  end;

var
  GCharges: array of TGuiChargeRec;
  GChargeCount: Integer;
  GLiveBytes: Int64;
  GLedgerWatch: TGuiLedgerWatch;

function ChargeIndex(AObj: TObject): Integer;
var
  i: Integer;
begin
  for i := 0 to GChargeCount - 1 do
    if GCharges[i].Obj = AObj then Exit(i);
  Result := -1;
end;

function GuiObjectBytes(AObj: TObject): Int64;
var
  i: Integer;
begin
  i := ChargeIndex(AObj);
  if i < 0 then Result := 0 else Result := GCharges[i].Bytes;
end;

{ MB with one decimal, for a message a reader can check against Task Manager. Done
  by hand rather than with a float format so the text is the same on every locale
  -- the suite compares these messages byte for byte. }
function MbStr(const B: Int64): String;
begin
  Result := IntToStr(B div (1024 * 1024)) + '.' +
            IntToStr(((B mod (1024 * 1024)) * 10) div (1024 * 1024)) + ' MB';
end;

function GuiChargeRoom(const AWhat: String; ABytes, AReplacing: Int64;
                       out E: TPhosphorError): Boolean;
begin
  E := NoError;
  // ABytes saturates at High(Int64) for a count past its own ceiling, so the sum
  // is never formed: a request bigger than the whole budget is already settled,
  // and only a request that fits gets added to what is live.
  Result := (ABytes <= GuiMaxLiveBytes) and
            (GLiveBytes - AReplacing + ABytes <= GuiMaxLiveBytes);
  if Result then Exit;
  // AND THE MESSAGE NEVER PRINTS THE SATURATION. GuiSurfaceBytes and friends
  // answer High(Int64) for a size past their ceiling -- correct as a comparison,
  // and 8796093022207.9 MB as a sentence. A number a reader cannot check is worse
  // than no number, so a saturated cost is described rather than printed.
  if ABytes = High(Int64) then
    E := MakeError(peRuntime, Format(
      '%s is too large: it is past anything this host could hold, let alone the ' +
      '%s it allows for GUI surfaces',
      [AWhat, MbStr(GuiMaxLiveBytes)]))
  else
    E := MakeError(peRuntime, Format(
      '%s is too large: it needs %s and %s of the %s this host allows for GUI ' +
      'surfaces is already in use',
      [AWhat, MbStr(ABytes), MbStr(GLiveBytes - AReplacing), MbStr(GuiMaxLiveBytes)]));
end;

procedure Record_(AObj: TObject; ABytes: Int64);
var
  i: Integer;
begin
  i := ChargeIndex(AObj);
  if i < 0 then
  begin
    if ABytes = 0 then Exit;
    if GChargeCount >= Length(GCharges) then
      SetLength(GCharges, Length(GCharges) * 2 + 16);
    i := GChargeCount;
    Inc(GChargeCount);
    GCharges[i].Obj := AObj;
    GCharges[i].Bytes := 0;
    // Ask to be told when it dies. A TBitmap cannot answer; TGuiHandle.Destroy
    // credits that one instead (see the note in the interface).
    if AObj is TComponent then
      TComponent(AObj).FreeNotification(GLedgerWatch);
  end;
  GLiveBytes := GLiveBytes - GCharges[i].Bytes + ABytes;
  GCharges[i].Bytes := ABytes;
end;

function GuiChargeSet(AObj: TObject; const AWhat: String; ABytes: Int64;
                      out E: TPhosphorError): Boolean;
begin
  Result := GuiChargeRoom(AWhat, ABytes, GuiObjectBytes(AObj), E);
  if Result then Record_(AObj, ABytes);
end;

function GuiChargeAdd(AObj: TObject; const AWhat: String; ABytes: Int64;
                      out E: TPhosphorError): Boolean;
var
  held: Int64;
begin
  held := GuiObjectBytes(AObj);
  if ABytes > GuiMaxLiveBytes then
    Result := GuiChargeRoom(AWhat, ABytes, 0, E)     // saturated: refuse and say so
  else
    Result := GuiChargeRoom(AWhat, held + ABytes, held, E);
  if Result then Record_(AObj, held + ABytes);
end;

{ Idempotent on purpose: an owned TComponent is credited by its notification AND
  then by TGuiHandle.Destroy, and the second call must find nothing. }
procedure GuiCredit(AObj: TObject);
var
  i: Integer;
begin
  i := ChargeIndex(AObj);
  if i < 0 then Exit;
  GLiveBytes := GLiveBytes - GCharges[i].Bytes;
  if (AObj is TComponent) and (GLedgerWatch <> nil) then
    TComponent(AObj).RemoveFreeNotification(GLedgerWatch);
  GCharges[i] := GCharges[GChargeCount - 1];   // order does not matter here
  Dec(GChargeCount);
end;

procedure TGuiLedgerWatch.Notification(AComponent: TComponent; Operation: TOperation);
var
  i: Integer;
begin
  inherited Notification(AComponent, Operation);
  if Operation <> opRemove then Exit;
  // NOT GuiCredit: RemoveFreeNotification on a component already in its destructor
  // is both pointless and a re-entry into the list being walked.
  i := ChargeIndex(AComponent);
  if i < 0 then Exit;
  GLiveBytes := GLiveBytes - GCharges[i].Bytes;
  GCharges[i] := GCharges[GChargeCount - 1];
  Dec(GChargeCount);
end;

// --- a size that arrives in a file -------------------------------------------
{ Big-endian and little-endian readers over a fixed header buffer. Every access is
  bounds-checked against how much was actually read, because the whole point is a
  file that is SHORTER than its header claims -- the 54-byte bomb is exactly that. }
function BeU16(const B: array of Byte; N, I: Integer): Int64;
begin
  if I + 1 >= N then Exit(-1);
  Result := (Int64(B[I]) shl 8) or B[I + 1];
end;

function BeU32(const B: array of Byte; N, I: Integer): Int64;
begin
  if I + 3 >= N then Exit(-1);
  Result := (Int64(B[I]) shl 24) or (Int64(B[I + 1]) shl 16) or
            (Int64(B[I + 2]) shl 8) or B[I + 3];
end;

function LeU16(const B: array of Byte; N, I: Integer): Int64;
begin
  if I + 1 >= N then Exit(-1);
  Result := (Int64(B[I + 1]) shl 8) or B[I];
end;

function LeI32(const B: array of Byte; N, I: Integer): Int64;
begin
  if I + 3 >= N then Exit(-1);
  Result := Int32((LongWord(B[I + 3]) shl 24) or (LongWord(B[I + 2]) shl 16) or
                  (LongWord(B[I + 1]) shl 8) or B[I]);
end;

{ THE DECODED DEPTH OF A BMP, from its biBitCount. Not the same number: the LCL
  gives a 4- or 8-bit BMP a 24-bit surface and a 1-bit BMP a 2-bit one (the mono
  bitmap and its mask), which is why this is a measured table and not a formula.
  Anything unrecognised -- a 2-bit Windows CE bitmap, a BI_JPEG stub -- is priced
  at the deepest surface the LCL makes, because under-charging is the failure that
  admits a bomb and over-charging is only ever a refusal we can see. }
function BmpDecodedBits(ABits: Int64): Int64;
begin
  case ABits of
     1: Result := 2;
     4, 8, 24: Result := 24;
    16: Result := 16;
    32: Result := 32;
  else Result := 32;
  end;
end;

{ And of a PNG, from IHDR's bit depth and COLOUR TYPE together. The colour type is
  the half a "read the bit depth" rule would have missed: type 3 is a palette, and
  a palette is expanded to a 32-bit surface whatever depth it declares -- measured
  at 30.6 bits a pixel for 1-, 4- and 8-bit palettes alike. }
function PngDecodedBits(ABitDepth, AColourType: Int64): Int64;
begin
  case AColourType of
    0: Result := ABitDepth;                        // grey
    4: Result := ABitDepth * 2;                    // grey + alpha
    2: Result := ABitDepth * 3;                    // rgb, and 8-bit rgb becomes 32
    6: Result := ABitDepth * 4;                    // rgba
    3: Result := 32;                               // PALETTE: always a 32-bit surface
  else Result := ABitDepth * 4;                    // no such type; price the worst
  end;
  if (AColourType <> 0) and (AColourType <> 4) and (Result < 32) then Result := 32;
end;

function GuiImageFileCost(const APath: String): TGuiImageFileCost;
var
  fs: TFileStream;
  buf: array[0..4095] of Byte;
  n, i, marker: Integer;
  seg, dib, bd, ct: Int64;
begin
  Result.W := -1; Result.H := -1; Result.Pixels := -1;
  Result.Bits := -1; Result.OnDisk := 0; Result.Bytes := -1;
  { THE GATE IS ASKED HERE TOO, not only by the two callers. Both of them do check
    -- but this function opens a file, so it must be safe to call from anywhere,
    and scripts/check-sandbox.py is right to insist rather than take the callers on
    trust. Refusing here answers "no opinion", which makes the caller load the file
    the ordinary way and meet the sandbox's own refusal there. }
  if not SandboxAllows(APath, puRead) then Exit;
  // Nor opened when it is a FIFO or a device (round 11); both callers refuse it.
  if IoSpecialKind(APath) <> '' then Exit;
  try
    fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  except
    Exit;              // unreadable: FileExists/LoadFromFile answer that, not this
  end;
  try
    // The file is copied into memory before it is decoded, so its own size is part
    // of the peak -- a 549 MB 32-bit BMP measured 1118 MB, which is the two halves.
    Result.OnDisk := fs.Size;
    n := fs.Read(buf, SizeOf(buf));
  finally
    fs.Free;
  end;
  if n < 8 then Exit;

  // BMP: 'BM', then a DIB header whose SIZE says which shape it is.
  if (buf[0] = $42) and (buf[1] = $4D) then
  begin
    dib := LeI32(buf, n, 14);
    if dib = 12 then                       // BITMAPCOREHEADER: 16-bit dimensions
    begin
      Result.W := LeU16(buf, n, 18);
      Result.H := LeU16(buf, n, 20);
      Result.Bits := BmpDecodedBits(LeU16(buf, n, 24));
    end
    else if dib >= 40 then                 // BITMAPINFOHEADER and every successor
    begin
      Result.W := LeI32(buf, n, 18);
      Result.H := LeI32(buf, n, 22);
      if Result.H < 0 then Result.H := -Result.H;  // top-down: same size
      Result.Bits := BmpDecodedBits(LeU16(buf, n, 28));
    end;
  end
  // PNG: the signature, then IHDR's width, height, bit depth and colour type.
  else if (n >= 26) and (buf[0] = $89) and (buf[1] = $50) and (buf[2] = $4E) and
          (buf[3] = $47) and (buf[4] = $0D) and (buf[5] = $0A) and
          (buf[6] = $1A) and (buf[7] = $0A) then
  begin
    Result.W := BeU32(buf, n, 16);
    Result.H := BeU32(buf, n, 20);
    bd := buf[24];
    ct := buf[25];
    if (bd >= 1) and (bd <= 16) then Result.Bits := PngDecodedBits(bd, ct);
  end
  // GIF: 'GIF8', then the logical screen's width and height, little-endian 16-bit.
  // THE PACKED BYTE AT OFFSET 10 IS DELIBERATELY NOT PRICED FROM. It states the
  // global colour table's depth, and that does not predict the cost: a GIF is a
  // palette, and a palette is expanded to a 32-bit surface whatever depth it
  // declares -- the same thing the PNG measurements show, where 1-, 4- and 8-bit
  // palettes all landed on 30.6 bits a pixel. An 8-bit-palette GIF measured 48
  // bits a pixel all told, and since 8 is the deepest palette a GIF can carry, no
  // GIF can cost more than that one measured number.
  else if (n >= 11) and (buf[0] = $47) and (buf[1] = $49) and (buf[2] = $46) and
          (buf[3] = $38) then
  begin
    Result.W := LeU16(buf, n, 6);
    Result.H := LeU16(buf, n, 8);
    Result.Bits := 40;                     // 48 measured, less the file term below
  end
  // JPEG: walk the segment chain to the first SOFn, which carries the dimensions,
  // the sample PRECISION (byte 4 of the segment) and the component count (byte 9).
  // Not SOF4/SOF8/SOFC -- those markers are tables, not frame headers.
  else if (buf[0] = $FF) and (buf[1] = $D8) then
  begin
    i := 2;
    while i + 3 < n do
    begin
      if buf[i] <> $FF then Break;         // out of step: say nothing rather than guess
      marker := buf[i + 1];
      if marker = $FF then begin Inc(i); Continue; end;    // fill bytes are legal
      if (marker = $D8) or ((marker >= $D0) and (marker <= $D9)) then
      begin Inc(i, 2); Continue; end;                      // no length field
      seg := BeU16(buf, n, i + 2);
      if seg < 2 then Break;
      if ((marker >= $C0) and (marker <= $CF)) and
         (marker <> $C4) and (marker <> $C8) and (marker <> $CC) then
      begin
        Result.H := BeU16(buf, n, i + 5);
        Result.W := BeU16(buf, n, i + 7);
        // Both a greyscale and a three-component JPEG measured 30.7 bits a pixel:
        // the decoder makes a 32-bit surface of either. A 12-bit-precision frame
        // is priced by its own arithmetic, which is never below that.
        if i + 9 < n then bd := Int64(buf[i + 4]) * buf[i + 9] else bd := 32;
        if bd < 32 then bd := 32;
        Result.Bits := bd;
        Break;
      end;
      i := i + 2 + Integer(seg);
    end;
  end;

  if (Result.W <= 0) or (Result.H <= 0) or (Result.Bits <= 0) then
  begin
    Result.W := -1; Result.H := -1; Result.Bits := -1;
    Exit;                                  // no opinion; the caller must allow it
  end;
  Result.Pixels := Result.W * Result.H;    // both came from at most 32 bits
  Result.Bytes := GuiImageBytesAt(Result.W, Result.H, Result);
end;

function GuiImageBytesAt(AW, AH: Int64; const ACost: TGuiImageFileCost): Int64;
var
  w, h, rowbytes: Int64;
begin
  if ACost.Bits <= 0 then Exit(-1);
  w := AtLeastZero(AW);
  h := AtLeastZero(AH);
  if (w = 0) or (h = 0) then Exit(ACost.OnDisk);
  // A row is padded to four bytes, the way every raw image in the LCL is laid out.
  // w <= 2^32 and Bits <= 64, so the product is at most 2^38 and cannot overflow.
  rowbytes := ((w * ACost.Bits + 31) div 32) * 4;
  if rowbytes > GuiCostCeiling div h then Exit(High(Int64));
  Result := rowbytes * h + ACost.OnDisk;
end;

function GuiImageFileTooLarge(const AWhat, APath: String;
                              AW, AH, ABytes: Int64): TPhosphorError;
begin
  // A SATURATED COST IS DESCRIBED, NEVER PRINTED, for the same reason the ledger's
  // own message describes one: "8796093022207.9 MB" is a number no reader can
  // check against anything.
  if ABytes = High(Int64) then
    Result := MakeError(peRuntime, Format(
      '%s is too large: %s says it is %d x %d, which is past anything this host ' +
      'could hold, let alone the %s it allows for GUI surfaces',
      [AWhat, ExtractFileName(APath), AW, AH, MbStr(GuiMaxLiveBytes)]))
  else
    Result := MakeError(peRuntime, Format(
      '%s is too large: %s says it is %d x %d, which needs %s and %s of the %s this ' +
      'host allows for GUI surfaces is already in use',
      [AWhat, ExtractFileName(APath), AW, AH, MbStr(ABytes),
       MbStr(GLiveBytes), MbStr(GuiMaxLiveBytes)]));
end;

function GuiImageFileReserve(const AWhat, APath: String; AObj: TObject;
                             ACopies: Integer; out ACost: TGuiImageFileCost;
                             out E: TPhosphorError): Boolean;
var
  want, held: Int64;
begin
  E := NoError;
  ACost := GuiImageFileCost(APath);
  if ACost.Bytes < 0 then Exit(True);      // no opinion; not our call to refuse
  want := ACost.Bytes;
  if ACopies > 0 then
  begin
    // Each copy is a full-size TBitmap, priced the way every other bitmap here is.
    if GuiSurfaceBytes(ACost.W, ACost.H) > (GuiCostCeiling - want) div ACopies then
      want := High(Int64)
    else
      want := want + ACopies * GuiSurfaceBytes(ACost.W, ACost.H);
  end;
  // AND IT IS RESERVED, not merely asked about. The charge that used to run after
  // the load could not refuse anything and was thrown away, so twelve loads of one
  // picture reached 6.6 GB with the ledger still reading the first one. The old
  // picture is not freed until the new one has decoded, so what this asks for is
  // what AObj already holds PLUS the new load -- which is the true peak, and which
  // lets the caller restore exactly what it held when the load raises.
  held := GuiObjectBytes(AObj);
  if (want = High(Int64)) or (held > High(Int64) - want) then
    Result := GuiChargeSet(AObj, AWhat, High(Int64), E)
  else
    Result := GuiChargeSet(AObj, AWhat, held + want, E);
  if not Result then
    E := GuiImageFileTooLarge(AWhat, APath, ACost.W, ACost.H, want);
end;

// --- the property bridge's gate ---------------------------------------------
var
  GPropGates: array of TGuiPropGate;
  GPropWritten: array of TGuiPropWritten;

procedure GuiAddPropGate(AGate: TGuiPropGate);
var
  i: Integer;
begin
  if AGate = nil then Exit;
  // Idempotent: a unit initialization runs once per process, but a host that links
  // a package twice under different names must not end up asking twice.
  for i := 0 to High(GPropGates) do
    if GPropGates[i] = AGate then Exit;
  SetLength(GPropGates, Length(GPropGates) + 1);
  GPropGates[High(GPropGates)] := AGate;
end;

procedure GuiAddPropWritten(AHook: TGuiPropWritten);
var
  i: Integer;
begin
  if AHook = nil then Exit;
  for i := 0 to High(GPropWritten) do
    if GPropWritten[i] = AHook then Exit;
  SetLength(GPropWritten, Length(GPropWritten) + 1);
  GPropWritten[High(GPropWritten)] := AHook;
end;

function GuiPropGatesAllow(AObject: TObject; const AProp: String; AValue: Int64;
                           out E: TPhosphorError): Boolean;
var
  i: Integer;
begin
  E := NoError;
  for i := 0 to High(GPropGates) do
    if not GPropGates[i](AObject, AProp, AValue, E) then Exit(False);
  Result := True;
end;

procedure GuiPropWasWritten(AObject: TObject; const AProp: String);
var
  i: Integer;
begin
  for i := 0 to High(GPropWritten) do
    GPropWritten[i](AObject, AProp);
end;

function GuiRegister(AObj: TObject; AOwns: Boolean): Int64;
var
  h: TGuiHandle;
begin
  GuiFlushFrees();               // a constructor at depth 0 is a safe point
  h := TGuiHandle.Create(nil);   // owned by the phosphor handle registry, not the LCL
  h.Control := AObj;
  h.Owns := AOwns;
  Inc(GBirths);
  h.Born := GBirths;             // every caller is a constructor: see TGuiRef.Born
  h.Watch;                       // tell me when you die
  GuiCapSizes(AObj);             // and never grow past what a window can hold
  Result := RegisterHandle(h);
  h.Id := Result;                // found by its object from now on (HandleOf)
  h.IdxKey := AObj;
  IdxPut(AObj, Result);
end;

function GuiResolveObj(AId: Int64; AClass: TClass; out AObj: TObject): Boolean;
var
  o: TObject;
  h: TGuiHandle;
begin
  AObj := nil;
  // Every GUI function resolves its handle, so this is where a free deferred by
  // a handler is finished: at depth 0 no LCL frame of the program's is on the
  // stack. A deferred object is named by no live handle, so freeing it here can
  // never pull the object about to be resolved out from under this call.
  GuiFlushFrees();
  o := HandleObj(AId);
  if not (o is TGuiHandle) then
  begin
    GGuiError := 1;   // fabricated, freed, or not a GUI handle at all
    Exit(False);
  end;
  h := TGuiHandle(o);
  if (h.Control = nil) or not h.Control.InheritsFrom(AClass) then
  begin
    GGuiError := 1;   // a valid handle, but of the wrong class
    Exit(False);
  end;
  AObj := h.Control;
  Result := True;
end;

function GuiResolve(AId: Int64; AClass: TClass; out AComp: TComponent): Boolean;
var
  o: TObject;
begin
  AComp := nil;
  Result := GuiResolveObj(AId, AClass, o);
  if Result then AComp := TComponent(o);   // AClass is a TComponent subclass here
end;

function GuiBridgeOf(AControl: TComponent; const AEventName: String): TGuiEventBridge;
var
  i: Integer;
begin
  for i := 0 to AControl.ComponentCount - 1 do
    if (AControl.Components[i] is TGuiEventBridge) and
       (TGuiEventBridge(AControl.Components[i]).EventName = AEventName) then
      Exit(TGuiEventBridge(AControl.Components[i]));
  Result := TGuiEventBridge.Create(AControl);   // owned by the control
  Result.EventName := AEventName;
end;

{ Find-or-create the bridge for this event and bind it, or nil for an empty name.
  Every factory below is the same three lines with a different method taken. }
function BoundBridge(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TGuiEventBridge;
begin
  if AHandler = '' then Exit(nil);   // an empty name unwires the event
  Result := GuiBridgeOf(AControl, AEvent);
  Result.Bind(TPhosphorVM(AVM), AHandler, ASenderId);
end;

function GuiNotifyHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TNotifyEvent;
var b: TGuiEventBridge;
begin
  Result := nil;
  b := BoundBridge(AVM, AControl, AEvent, AHandler, ASenderId);
  if b <> nil then Result := @b.Fire;
end;

function GuiKeyHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TKeyEvent;
var b: TGuiEventBridge;
begin
  Result := nil;
  b := BoundBridge(AVM, AControl, AEvent, AHandler, ASenderId);
  if b <> nil then Result := @b.FireKey;
end;

function GuiKeyPressHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TKeyPressEvent;
var b: TGuiEventBridge;
begin
  Result := nil;
  b := BoundBridge(AVM, AControl, AEvent, AHandler, ASenderId);
  if b <> nil then Result := @b.FireKeyPress;
end;

function GuiMouseHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TMouseEvent;
var b: TGuiEventBridge;
begin
  Result := nil;
  b := BoundBridge(AVM, AControl, AEvent, AHandler, ASenderId);
  if b <> nil then Result := @b.FireMouse;
end;

function GuiMouseMoveHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TMouseMoveEvent;
var b: TGuiEventBridge;
begin
  Result := nil;
  b := BoundBridge(AVM, AControl, AEvent, AHandler, ASenderId);
  if b <> nil then Result := @b.FireMouseMove;
end;

function GuiMouseWheelHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TMouseWheelEvent;
var b: TGuiEventBridge;
begin
  Result := nil;
  b := BoundBridge(AVM, AControl, AEvent, AHandler, ASenderId);
  if b <> nil then Result := @b.FireMouseWheel;
end;

function GuiCloseHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TCloseEvent;
var b: TGuiEventBridge;
begin
  Result := nil;
  b := BoundBridge(AVM, AControl, AEvent, AHandler, ASenderId);
  if b <> nil then Result := @b.FireClose;
end;

function GuiCloseQueryHandler(AVM: TObject; AControl: TComponent;
  const AEvent, AHandler: String; ASenderId: Int64): TCloseQueryEvent;
var b: TGuiEventBridge;
begin
  Result := nil;
  b := BoundBridge(AVM, AControl, AEvent, AHandler, ASenderId);
  if b <> nil then Result := @b.FireCloseQuery;
end;

// --- app_* : the message loop, for the interactive host ---------------------
type
  { QueueAsyncCall wants a method, so the no-op needs an owner. It does nothing
    on purpose: the value is in the POSTING, which wakes the loop and gives it a
    pass to make. }
  TLoopWaker = class
    procedure Nudge(Data: PtrInt);
  end;

var
  GAppQuit: Boolean = False;   // set by GuiLeaveLoop, read by the loop below
  GLastClosed: Boolean = False;   // set by GuiLastWindowClosed; asked again by the loop
  GWaker: TLoopWaker = nil;

procedure TLoopWaker.Nudge(Data: PtrInt);
begin
  // Deliberately empty. See GuiLeaveLoop.
end;

function GuiIsShownWindow(AObj: TObject): Boolean;
begin
  Result := (AObj is TForm) and TForm(AObj).Visible and
            (GuiEffectiveParent(AObj) = nil) and
            not (fsModal in TForm(AObj).FormState);
end;

procedure GuiWindowLeaving(AObj: TObject);
begin
  if GuiIsShownWindow(AObj) then GuiLastWindowClosed;
end;

function GuiOtherFormShown(AExcept: TObject): Boolean;
var
  id: Int64;
  i: Integer;
  o: TObject;
begin
  Result := False;
  id := FirstLiveHandle();
  { Counted by LiveHandleCount rather than run to the list's end: this is called
    from a form's OnClose, so it walks a structure that is being taken apart. }
  for i := 1 to LiveHandleCount() do
  begin
    if id = 0 then Break;
    o := HandleObj(id);
    { A form in a modal session is not counted (round 6): its answer never ends
      the loop, by design, so counting it meant closing the main window from
      inside a dialog left app_run running with nothing on screen. Nor is a form
      embedded in another (round 7): see GuiIsShownWindow. }
    if (o is TGuiHandle) and (TGuiHandle(o).Control <> nil) and
       (TGuiHandle(o).Control <> AExcept) and
       GuiIsShownWindow(TGuiHandle(o).Control) then
      Exit(True);
    id := NextLiveHandle(id);
  end;
end;

procedure GuiLeaveLoop;
begin
  GAppQuit := True;
  if GWaker = nil then GWaker := TLoopWaker.Create;
  Application.QueueAsyncCall(@GWaker.Nudge, 0);
end;

procedure GuiLastWindowClosed;
begin
  GLastClosed := True;
  if GWaker = nil then GWaker := TLoopWaker.Create;
  Application.QueueAsyncCall(@GWaker.Nudge, 0);
end;

function f_app_run(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  // OUR OWN LOOP, not Application.Run. app_quit used to call
  // Application.Terminate, which sets a flag the LCL gives no public way to
  // clear -- so once a program had left the loop, every later app_run() in that
  // process returned instantly, having dispatched nothing. A host that runs one
  // script after another, or an embedder driving the engine between loops, got a
  // GUI that silently stopped being a GUI. This loop is left by app_quit (END in
  // a handler calls the same GuiLeaveLoop), by a window leaving the screen when
  // none is left once every handler has returned (GuiWindowLeaving), and by
  // Application.Terminated should an embedder set it -- nothing here does. The
  // application stays usable for a later app_run whichever way it leaves.
  GAppQuit := False;
  GLastClosed := False;
  while (not GAppQuit) and (not Application.Terminated) do
  begin
    { DISPATCH AND WAIT ARE SPLIT, AND THE FLAG IS READ BETWEEN THEM.

      This used to be one call to Application.HandleMessage, which is
      AppProcessMessages followed by Idle(Wait=True) with nothing in between --
      and that is where app_quit() was lost. A script's app_quit runs inside a
      dispatched event: the timer fires during AppProcessMessages, the callback
      sets the flag, and HandleMessage then walks straight into Idle and blocks
      in AppWaitMessage for a message that, with no window shown, never comes.
      The flag was set, correct, and unread. Measured: the loop hung 5 runs out
      of 5, and instrumenting the callback showed it had run and quit had been
      called.

      Waking it from app_quit does not fix it either, and that was tried: Idle
      does ProcessAsyncCallQueue BEFORE AppWaitMessage (application.inc:471), so
      a queued nudge is consumed on the way IN to the wait rather than releasing
      it. The wake is kept in GuiLeaveLoop for the host that calls app_quit from
      outside a dispatched event, but it is not what closes this.

      Reading the flag between the two is. Nothing is polled and nothing is
      slept: Idle still blocks exactly as before whenever the loop should keep
      running. }
    Application.ProcessMessages;
    GuiFlushFrees();   // every message has been dispatched: nothing stands on them
    if GAppQuit or Application.Terminated then Break;
    { Every handler has returned: a window one of them showed after closing
      another is on screen now, and this is the moment to ask. }
    if GLastClosed then
    begin
      GLastClosed := False;
      if not GuiOtherFormShown(nil) then Break;
    end;
    Application.Idle(True);
  end;
  GuiFlushFrees();
  Result := ValInt(0);
end;
function f_app_processmessages(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  Application.ProcessMessages;
  GuiFlushFrees();   // inside a handler this does nothing; see GuiFlushFrees
  Result := ValInt(0);
end;
function f_app_quit(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  // Leave the loop; do NOT terminate the application. "Stop showing this window
  // and give me back control" is what a script means here, and terminating made
  // that a one-way door for the whole process.
  // Setting the flag alone was not enough: the loop had to be WOKEN to read it.
  GuiLeaveLoop;
  Result := ValInt(0);
end;

// --- the shared GUI error state ---------------------------------------------
function f_gui_error(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; Result := ValInt(GGuiError); end;
function f_gui_clearerror(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError; GGuiError := 0; Result := ValInt(0); end;

procedure RegisterGuiCoreFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('app_run:', @f_app_run);
  Reg.Add('app_processmessages:', @f_app_processmessages);
  Reg.Add('app_quit:', @f_app_quit);
  Reg.Add('gui_error:', @f_gui_error);
  Reg.Add('gui_clearerror:', @f_gui_clearerror);
end;

initialization
  GGuiError := 0;
  // Built here rather than lazily: a charge may be recorded from any package's
  // function, and a nil watcher would silently drop the notification that credits
  // a grid when its form dies -- a leak that only shows up as a false refusal
  // twenty minutes into a long-running host.
  GLedgerWatch := TGuiLedgerWatch.Create(nil);
  GSizeCap := TGuiSizeCap.Create;

finalization
  FreeAndNil(GSizeCap);   // every control holding its method died with the handles
  // Charged objects that outlive this unit (they do not: the engine's handle
  // registry is torn down first) would notify a freed watcher. Drop the list and
  // the watcher together.
  GChargeCount := 0;
  GLiveBytes := 0;
  SetLength(GCharges, 0);
  FreeAndNil(GLedgerWatch);

end.
