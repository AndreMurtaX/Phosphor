{******************************************************************************
  Phosphor BASIC -- image library (a GUI package under host/gui/libs)

  MIT License. Copyright (c) 2026 Andre Murta.

    image@(parent@)
    image_load@(img@, path$)     load a picture; a missing file sets gui_error 6
    image_stretch@/()  image_center@/()  image_proportional@/()
    image_picwidth(img@)  image_picheight(img@)  image_empty(img@)

  Geometry/visibility come from PhosphorControlLib; this adds loading and the
  picture's own size. A load failure is recorded in gui_error(), never raised.
******************************************************************************}
unit PhosphorImageLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Controls, ExtCtrls, ComCtrls, Graphics,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorGuiCore, PhosphorSandbox;

procedure RegisterImageFuncs(Reg: TPhosphorRegistry);

implementation

const
  ERR_FILE_NOT_FOUND = 6;
  ERR_LOAD_FAILED    = 7;

function ArgOn(const V: TValue): Boolean;
begin
  case V.Kind of
    vkBool: Result := V.Bl;
    vkInt:  Result := V.Int <> 0;
    vkDouble: Result := V.Num <> 0;
  else Result := False;
  end;
end;

function f_image(const A: array of TValue; out E: TPhosphorError): TValue;
var pc: TComponent; img: TImage;
begin
  E := NoError;
  if not GuiResolve(A[0].Hnd, TWinControl, pc) then begin Result := ValHandle(0); Exit; end;
  img := TImage.Create(pc);
  img.Parent := TWinControl(pc);
  Result := ValHandle(GuiRegister(img, False));
end;

function f_load(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; cost: TGuiImageFileCost; held, settled: Int64; E2: TPhosphorError;
begin
  E := NoError;
  Result := A[0];
  if not GuiResolve(A[0].Hnd, TImage, c) then Exit;
  { A PICTURE IS A FILE. host/gui/libs was never scanned by check-sandbox.py, so
    these two read from any path a confined script named. The gate now covers
    this directory. }
  if not SandboxAllows(A[1].Str, puRead) then
  begin GGuiError := ERR_FILE_NOT_FOUND; Exit; end;
  if not FileExists(A[1].Str) then begin GGuiError := ERR_FILE_NOT_FOUND; Exit; end;
  { AND THE SIZE IS IN THE FILE. TPicture.LoadFromFile has no size pre-check at
    all -- it finds a graphic class by extension and hands it the stream. Measured
    on this tree: a FIFTY-FOUR BYTE .bmp whose header claims 30000 x 30000 took the
    host past 2.4 GB and had to be killed, with gui_error 0 and nothing raised; a
    real 200 MB 1-bit .bmp of 40000 x 40000 loaded 587 MB and reported picwidth
    40000 as if all were well. Neither is an argument the program wrote, which is
    why the argument guards above never saw them.

    Refused as a CATCHABLE error like the other sizes, not as gui_error: a picture
    that is too big to load is the same kind of answer as a bitmap that is too big
    to make, and image_empty() would otherwise be the only sign.

    AND THE CHARGE IS MADE BEFORE THE LOAD, NOT AFTER IT. The first version of this
    asked a per-file question ("could this file EVER fit?") and then charged what
    the load became, discarding the answer -- so nothing accumulated in the ledger
    and eight loads of one 560 KB picture reached 4416 MB with gui_error 0. The
    reservation below is the same charge, moved to the only place it can refuse
    anything. }
  held := GuiObjectBytes(TImage(c));
  if not GuiImageFileReserve('picture', A[1].Str, TImage(c), 0, cost, E) then Exit;
  try
    TImage(c).Picture.LoadFromFile(A[1].Str);
  except
    GGuiError := ERR_LOAD_FAILED;   // a present but unreadable/undecodable file
    // TPicture keeps the old graphic when a load raises (picture.inc assigns the
    // new one only on success), so the ledger goes back to exactly what it read
    // before the reservation.
    GuiChargeSet(TImage(c), 'picture', held, E2);
    Exit;
  end;
  if cost.Bytes >= 0 then
  begin
    // The reservation stands; correct it DOWNWARD to what the file really decoded
    // to. Two corrections, and both are downward, so neither can refuse a load
    // that has already happened: a picture smaller than its header claimed gives
    // the difference back, and the FILE's own bytes go back too -- they were part
    // of the peak, because the loader copies the file into memory before decoding
    // it, but they are not part of what stays live afterwards. Charging them for
    // ever would make a 200 MB 1-bit .bmp hold 600 MB of the budget when 400 is
    // resident, and that is a false refusal waiting to happen.
    cost.OnDisk := 0;
    settled := GuiImageBytesAt(TImage(c).Picture.Width, TImage(c).Picture.Height, cost);
    if (settled < 0) or (settled > cost.Bytes) then settled := cost.Bytes;
    GuiChargeSet(TImage(c), 'picture', settled, E2);
    Exit;
  end;
  // A HEADER THIS CANNOT READ -- TIFF is the one that matters -- reserved nothing,
  // because nothing was known to reserve. The size is known now and nowhere else,
  // so it is charged now, priced as the surface it became; and when it does not
  // fit, the picture is FREED and the load is refused in the same words the door
  // would have used. Three 200-byte .tif files each claiming 30000 x 30000 used to
  // reach 3448 MB between them with two assertions passing.
  //
  // The old picture is gone -- the load succeeded -- so its charge goes first.
  GuiChargeSet(TImage(c), 'picture', 0, E2);
  settled := GuiSurfaceBytes(TImage(c).Picture.Width, TImage(c).Picture.Height);
  if not GuiChargeSet(TImage(c), 'picture', settled, E2) then
  begin
    E := GuiImageFileTooLarge('picture', A[1].Str,
           TImage(c).Picture.Width, TImage(c).Picture.Height, settled);
    TImage(c).Picture.Clear;
  end;
end;

function f_stretch_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TImage, c) then TImage(c).Stretch := ArgOn(A[1]); Result := A[0]; end;
function f_stretch_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TImage, c) then Result := ValInt(Ord(TImage(c).Stretch)) else Result := ValInt(0); end;
function f_center_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TImage, c) then TImage(c).Center := ArgOn(A[1]); Result := A[0]; end;
function f_center_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TImage, c) then Result := ValInt(Ord(TImage(c).Center)) else Result := ValInt(0); end;
function f_proportional_set(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TImage, c) then TImage(c).Proportional := ArgOn(A[1]); Result := A[0]; end;
function f_proportional_get(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TImage, c) then Result := ValInt(Ord(TImage(c).Proportional)) else Result := ValInt(0); end;

function f_picwidth(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TImage, c) then Result := ValInt(TImage(c).Picture.Width) else Result := ValInt(0); end;
function f_picheight(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; if GuiResolve(A[0].Hnd, TImage, c) then Result := ValInt(TImage(c).Picture.Height) else Result := ValInt(0); end;
function f_empty(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin
  E := NoError; Result := ValInt(1);
  if GuiResolve(A[0].Hnd, TImage, c) then
    if TImage(c).Picture.Graphic <> nil then Result := ValInt(Ord(TImage(c).Picture.Graphic.Empty));
end;

// --- a shared strip of icons ------------------------------------------------
{ TImageList is a TComponent, not a TControl: nothing shows it, and the controls
  that use it hold a reference. It is owned by its handle, so freeing the handle
  frees the list -- which means a program must outlive the controls pointing at it,
  the same rule any shared resource has. }
{ THE TWO NUMBERS ARE AN ALLOCATION -- PER ENTRY -- and this is the one the first
  version of this guard priced wrong. Like TBitmap.SetSize the list is lazy:
  imagelist@(30000, 30000) on its own costs nothing, and the first
  imagelist_addbitmap then asks for a 30000 x 30000 slot; measured, past 4 GB in
  under a second, no error, the probe had to be killed.

  The correction: an entry is 19-20 BYTES A PIXEL, not the 4 a bitmap was priced
  at. Measured on this tree, list d x d plus one entry, one probe per process:
  1024^2 -> 20 MB, 2048^2 -> 80 MB, 4096^2 -> 320 MB, 8192^2 -> 1277 MB. Sharing
  the bitmap's constant meant that imagelist@(8192, 8192) -- EXACTLY the accepted
  maximum -- still committed 1684 MB with exit 0 and gui_error 0, byte for byte
  what the unguarded build did. And eight such entries killed the host, because a
  per-entry cap says nothing about a list.

  So the entry price is GuiImageListEntryBytes, and both ends are covered: the
  constructor refuses a list whose SINGLE entry could never fit at all (a better
  place to say so, since that is where the program wrote the numbers), and every
  add charges one entry against the host's live total. Clearing the list gives it
  all back.

  The zero-argument overload keeps TImageList's own default size and never reaches
  this. }
function f_imagelist(const A: array of TValue; out E: TPhosphorError): TValue;
var il: TImageList; w, h: Integer;
begin
  E := NoError;
  Result := ValHandle(0);
  w := 0; h := 0;
  if Length(A) >= 2 then
  begin
    w := ArgI32(A[0]);
    h := ArgI32(A[1]);
    // Room for ONE entry against an empty ledger: a list this size could never
    // take a single image whatever else the host is doing, so say so here rather
    // than at the add, where the two numbers are no longer in the program's hands.
    if GuiImageListEntryBytes(w, h) > GuiMaxLiveBytes then
      if not GuiChargeRoom(Format('image list %d x %d', [w, h]),
                           GuiImageListEntryBytes(w, h), 0, E) then Exit;
  end;
  il := TImageList.Create(nil);
  if Length(A) >= 2 then
  begin
    il.Width := w;
    il.Height := h;
  end;
  Result := ValHandle(GuiRegister(il, True));
end;

{ One entry's charge, for both ways in. The list's OWN Width/Height decide it --
  TImageList scales whatever it is handed into its slot size, which is why a 32x32
  list given a 20000x20000 file still costs one 32x32 slot and not 1.7 GB... as
  long as the DECODE that precedes it is bounded, which is f_il_addfile's job. }
function ChargeOneEntry(AList: TImageList; out E: TPhosphorError): Boolean;
begin
  Result := GuiChargeAdd(AList, Format('image list entry %d x %d',
                                       [AList.Width, AList.Height]),
                         GuiImageListEntryBytes(AList.Width, AList.Height), E);
end;

function f_il_count(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := ValInt(0);
  if GuiResolve(A[0].Hnd, TImageList, c) then Result := ValInt(TImageList(c).Count); end;

function f_il_clear(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; begin E := NoError; Result := A[0];
  if GuiResolve(A[0].Hnd, TImageList, c) then
  begin
    TImageList(c).Clear;
    GuiCredit(c);   // every entry's charge goes back with the entries
  end;
end;

{ Add a picture from a file. Answers the 1-based index it took, the shape
  strings_add settled on -- a mutator returns information, not a flag. 0 means the
  file could not be read, with gui_error set. }
function f_il_addfile(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; bm: TBitmap; pic: TPicture;
    cost: TGuiImageFileCost; listheld, unknown: Int64; E2: TPhosphorError;
begin
  E := NoError; Result := ValInt(0);
  if not GuiResolve(A[0].Hnd, TImageList, c) then Exit;
  if not SandboxAllows(A[1].Str, puRead) then begin GGuiError := 1; Exit; end;
  if not FileExists(A[1].Str) then begin GGuiError := 1; Exit; end;
  // THE DECODE IS THE ALLOCATION, and it is sized by the file, not by the list.
  // Measured: this call on a real 50 MB 1-bit .bmp of 20000 x 20000 committed
  // 1731 MB into a 32 x 32 icon list with nothing reported, and on a 54-byte .bmp
  // whose header lies about being 30000 x 30000 it went past 2.4 GB and had to be
  // killed.
  //
  // AND THE DECODE IS NOT THE ONLY ONE. The first version of this asked the file
  // door only whether the file could ever fit, then charged the LIST's 32 x 32
  // slot -- 20 KB -- for a call that really commits the decode AND a full-size
  // TBitmap copy of it. At the door's own accepted maximum, a 13376-square
  // greyscale PNG, that was 2060 MB with exit 0 and both assertions passing. So
  // the reservation is the decode PLUS one full-size surface, held on the TPicture
  // for as long as the picture is alive and given back when it dies. Priced that
  // way the same call is refused, naming 1194.6 MB against the 2060 it measured.
  //
  // What is NOT modelled: TImageList.Add converts the bitmap again on its way into
  // the slot, and for an 8-bit source that lands at 11.5 bytes a pixel against the
  // 7 this prices. Swept to the boundary, the largest thing this door admits is a
  // 12383-square 8-bit grey PNG, and it costs 1768 MB. That residual is stated
  // rather than rounded away, because the alternative is worse: a third term big
  // enough to cover it refuses the 1-bit picture at the same door, which measures
  // 744 MB at ITS own maximum (13236 square) and belongs inside a 1024 MB budget.
  // Refusing that is the failure this door exists to avoid.
  pic := TPicture.Create;
  try
    if not GuiImageFileReserve('image list entry', A[1].Str, pic, 1, cost, E) then Exit;
    try
      pic.LoadFromFile(A[1].Str);
    except
      // A file that is not an image is an ANSWER, not an exception crossing into
      // BASIC -- the phase-1 contract, which this package honours like the rest.
      on E3: Exception do begin GGuiError := 1; Exit; end;
    end;
    // A header this reader has no opinion about reserved nothing; the size is
    // known now, so it is charged now and the entry refused when it does not fit.
    // Two surfaces, for the same two allocations the readable case reserves.
    if cost.Bytes < 0 then
    begin
      unknown := GuiSurfaceBytes(pic.Width, pic.Height);
      if unknown > High(Int64) div 2 then unknown := High(Int64)
      else unknown := unknown * 2;
      if not GuiChargeSet(pic, 'image list entry', unknown, E2) then
      begin
        E := GuiImageFileTooLarge('image list entry', A[1].Str,
                                  pic.Width, pic.Height, unknown);
        Exit;
      end;
    end;
    listheld := GuiObjectBytes(TImageList(c));
    if not ChargeOneEntry(TImageList(c), E) then Exit;
    bm := TBitmap.Create;
    try
      try
        bm.Assign(pic.Graphic);
        TImageList(c).Add(bm, nil);
      except
        // The entry never landed, so its charge must not stay behind it. Going
        // back to what the list held is always downward and so cannot refuse.
        GuiChargeSet(TImageList(c), 'image list entry', listheld, E2);
        raise;
      end;
      Result := ValInt(TImageList(c).Count);   // the index it took, base-1
    finally bm.Free; end;
  finally
    // The decode's charge belongs to the DECODE, not to the list: it goes back the
    // moment the picture does, whichever way out of this function was taken.
    GuiCredit(pic);
    pic.Free;
  end;
end;

{ Add an existing bitmap@ instead of a file. }
function f_il_addbitmap(const A: array of TValue; out E: TPhosphorError): TValue;
var c: TComponent; o: TObject;
begin
  E := NoError; Result := ValInt(0);
  if not GuiResolve(A[0].Hnd, TImageList, c) then Exit;
  if not GuiResolveObj(A[1].Hnd, TBitmap, o) then Exit;
  if not ChargeOneEntry(TImageList(c), E) then Exit;
  TImageList(c).Add(TBitmap(o), nil);
  Result := ValInt(TImageList(c).Count);
end;

{ Point a control at the list. Images is object-typed, so control_set@ cannot do
  it; the three LCL controls that have such a property are handled by name. }
function f_il_attach(const A: array of TValue; out E: TPhosphorError): TValue;
var lc, c: TComponent;
begin
  E := NoError; Result := A[0];
  if not GuiResolve(A[0].Hnd, TImageList, lc) then Exit;
  if not GuiResolve(A[1].Hnd, TComponent, c) then Exit;
  if c is TToolBar then TToolBar(c).Images := TImageList(lc)
  else if c is TTreeView then TTreeView(c).Images := TImageList(lc)
  else if c is TListView then TListView(c).SmallImages := TImageList(lc)
  else GGuiError := 1;   // nothing else here takes an image list
end;

procedure RegisterImageFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('imagelist@:',           @f_imagelist);
  Reg.Add('imagelist@:nn',         @f_imagelist);
  Reg.Add('imagelist_count:@',     @f_il_count);
  Reg.Add('imagelist_clear@:@',    @f_il_clear);
  Reg.Add('imagelist_addfile:@$',  @f_il_addfile);
  Reg.Add('imagelist_addbitmap:@@', @f_il_addbitmap);
  Reg.Add('imagelist_attach@:@@',  @f_il_attach);
  Reg.Add('image@:@', @f_image);
  Reg.Add('image_load@:@$', @f_load);
  Reg.Add('image_stretch@:@n', @f_stretch_set); Reg.Add('image_stretch:@', @f_stretch_get);
  Reg.Add('image_center@:@n', @f_center_set);   Reg.Add('image_center:@', @f_center_get);
  Reg.Add('image_proportional@:@n', @f_proportional_set); Reg.Add('image_proportional:@', @f_proportional_get);
  Reg.Add('image_picwidth:@', @f_picwidth);
  Reg.Add('image_picheight:@', @f_picheight);
  Reg.Add('image_empty:@', @f_empty);
end;

end.
