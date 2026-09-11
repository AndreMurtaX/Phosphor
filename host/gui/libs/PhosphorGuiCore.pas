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
  PhosphorSandbox;   // GuiImageFileCost reads a file, so it asks the gate itself

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

    A handle wrapping a NON-component (a TBitmap, a TTreeNode, a TListItem) cannot
    be watched: FreeNotification is a TComponent service. Those keep the older,
    weaker guarantee -- do not free a tree while holding handles to its nodes. }
  TGuiHandle = class(TComponent)
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
    { Arm the death notice, when the wrapped object is able to send one. }
    procedure Watch;
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
    destructor Destroy; override;
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
    answer is gui_error 1 and no resize. }
  GuiMaxExtent = 100000;

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
  A handler is usually the last thing that touches its sender: TControl.Click
  calls the notify event and returns, so a program may free the control it was
  just handed and nothing dereferences it afterwards. CLOSING A FORM is not like
  that. TCustomForm.Close runs OnCloseQuery, then OnClose, and then keeps working
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

{ Call a BASIC routine the way an event bridge does: record a failing handler as
  error 2, honour END, and answer what the routine returned. Exposed because a
  package may own an event signature GuiCore must not know about -- Grids'
  TDrawCellEvent is the first -- and duplicating this would duplicate the two rules
  that matter. }
function GuiCallBack(AVM: TPhosphorVM; const AHandler: String;
  const AArgs: array of TValue): TValue;

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

  form_show@'s closer calls this too, for the LAST window only; see
  PhosphorFormLib. Application.Terminate is never used: it sets a flag the LCL
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

procedure GuiLeaveLoop;

procedure RegisterGuiCoreFuncs(Reg: TPhosphorRegistry);

implementation

procedure TGuiHandle.Watch;
begin
  Watched := Control is TComponent;   // asked ONCE, while the pointer is certainly live
  if Watched then
    TComponent(Control).FreeNotification(Self);
end;

procedure TGuiHandle.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  // The control this handle names is going away. Drop the reference NOW, while the
  // pointer is still valid to compare -- after this the handle is stale, which is a
  // state the resolver already knows how to refuse.
  if (Operation = opRemove) and (AComponent = Control) then
    Control := nil;
end;

destructor TGuiHandle.Destroy;
var
  c: TObject;
begin
  // Take the reference away from the field FIRST. Freeing the control re-enters
  // Notification, and finding Control already nil there is what keeps that path
  // from mattering.
  c := Control;
  Control := nil;
  // Watched, not `c is TComponent`: a non-component handle (a TTreeNode, a
  // TListItem) may already have died with its container, and testing its class
  // would dereference it. Where Watched is true and the control has died, the
  // notification already set Control to nil, so c is nil here and nothing is asked.
  if Watched and (c <> nil) then
    TComponent(c).RemoveFreeNotification(Self);
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

function GuiCallBack(AVM: TPhosphorVM; const AHandler: String;
  const AArgs: array of TValue): TValue;
var
  err: TPhosphorError;
begin
  Result := ValInt(0);
  if (AVM = nil) or (AHandler = '') then Exit;
  Result := AVM.CallUserFunc(AHandler, AArgs, err);
  if IsError(err) then
    GGuiError := 2;   // a handler that failed is recorded, not raised
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
    GuiLeaveLoop;
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
  h := TGuiHandle.Create(nil);   // owned by the phosphor handle registry, not the LCL
  h.Control := AObj;
  h.Owns := AOwns;
  h.Watch;                       // tell me when you die
  Result := RegisterHandle(h);
end;

function GuiResolveObj(AId: Int64; AClass: TClass; out AObj: TObject): Boolean;
var
  o: TObject;
  h: TGuiHandle;
begin
  AObj := nil;
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
  GWaker: TLoopWaker = nil;

procedure TLoopWaker.Nudge(Data: PtrInt);
begin
  // Deliberately empty. See GuiLeaveLoop.
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
    if (o is TGuiHandle) and (TGuiHandle(o).Control <> nil) and
       (TGuiHandle(o).Control <> AExcept) and
       (TGuiHandle(o).Control is TForm) and
       TForm(TGuiHandle(o).Control).Visible then
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

function f_app_run(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  // OUR OWN LOOP, not Application.Run. app_quit used to call
  // Application.Terminate, which sets a flag the LCL gives no public way to
  // clear -- so once a program had left the loop, every later app_run() in that
  // process returned instantly, having dispatched nothing. A host that runs one
  // script after another, or an embedder driving the engine between loops, got a
  // GUI that silently stopped being a GUI. This loop is left by app_quit AND by
  // the application terminating (which is what closing the last window does), and
  // leaves the application usable either way.
  GAppQuit := False;
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
    if GAppQuit or Application.Terminated then Break;
    Application.Idle(True);
  end;
  Result := ValInt(0);
end;
function f_app_processmessages(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  Application.ProcessMessages;
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

finalization
  // Charged objects that outlive this unit (they do not: the engine's handle
  // registry is torn down first) would notify a freed watcher. Drop the list and
  // the watcher together.
  GChargeCount := 0;
  GLiveBytes := 0;
  SetLength(GCharges, 0);
  FreeAndNil(GLedgerWatch);

end.
