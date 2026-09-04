{******************************************************************************
  Phosphor BASIC -- local retrieval index over markdown files (a function package)

  MIT License. Copyright (c) 2026 Andre Murta.

  A pure-engine "RAG" library: despite the name it needs no network, no HTTP, no
  embedding model and no vector database -- it is a LOCAL retrieval index over a
  folder of markdown documents, each carrying a YAML-style front-matter header
  (id/title/category/tags/functions/complexity/platform between `---` markers),
  scored against a query by a multi-signal keyword rule (tags, title, function
  names, id) so the same question always brings back the same document. It reads
  files with the same TFileStream path IoLib uses, so the boundary stays clean
  (SysUtils/Classes/fpjson only -- no host or GUI unit).

  Ported to functional equivalence from Plan9Basic's RAGEngine/RAGLib (Delphi):
  same signals and weights, adapted to Phosphor. Two adaptations worth naming:

    * The engine handle is validated through PhosphorHandles like every other
      Phosphor handle -- a fabricated/stale id (pointer@(n)) is refused by
      IsHandle and NEVER dereferenced. Where the reference RAISED on a bad
      handle (so a running test could not provoke it), Phosphor makes the
      refusal a VALUE: the function answers 0/"" and rag_error reports the
      reason, the ioerror/valcode pattern the rest of the engine uses.
    * rag_doc$ keeps the reference's in-band error channel: a missing id
      answers the message "Error: ..." rather than an empty string, so the
      oracle's assertion that a missing id "answers a message, not nothing"
      holds byte-for-byte.
******************************************************************************}
unit PhosphorRagLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, StrUtils, fpjson,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles, PhosphorJsonLib;

procedure RegisterRagFuncs(Reg: TPhosphorRegistry);

implementation

var
  { Invariant settings for anything this index RENDERS -- see the score above. }
  RagFS: TFormatSettings;


const
  RAG_DEFAULT_MAX_TOKENS = 6000;
  RAG_CHARS_PER_TOKEN    = 4;
  RAG_MIN_RELEVANCE      = 1.0;
  RAG_HIGH_RELEVANCE     = 8.0;
  RAG_MAX_RESULTS        = 40;

type
  TStrArr = array of String;

  { One indexed document: its parsed header metadata plus a lazily-loaded,
    fully-cached content string. }
  TRagDoc = record
    Id, Title, Category, Subcategory, Complexity, Platform, Summary: String;
    FullPath: String;
    Tags, Functions, Depends: TStrArr;
    SizeBytes, TokenEstimate: Integer;
    Content: String;
    ContentLoaded: Boolean;
  end;

  { The signals extracted from a query, before any document is scored. }
  TRagAnalysis = record
    Query, Intent: String;
    Keywords, FunctionNames, LibraryHints: TStrArr;
    IsFollowUp: Boolean;
  end;

  { One scored, budget-fitted retrieval result. }
  TRagResult = record
    DocIdx: Integer;
    Score: Double;
    Truncated: Boolean;
    Content: String;
    Tokens: Integer;
  end;
  TRagResultArr = array of TRagResult;

  { The retrieval index over one folder. A handle object like every other
    Phosphor collection -- registered/validated/revoked through PhosphorHandles. }
  TPhosphorRag = class
  private
    FBasePath: String;
    FDocs: array of TRagDoc;
    FMaxTokens: Integer;
    function IndexOfId(const AId: String): Integer;
    function LoadContent(ADocIdx: Integer): String;
    function EstimateTokens(const AText: String): Integer;
    function ExtractEssential(const AContent: String; AMaxTokens: Integer): String;
    function AnalyzeQuery(const AQuery: String): TRagAnalysis;
    function ExtractKeywords(const AQuery: String): TStrArr;
    function DetectFunctionNames(const AQuery: String): TStrArr;
    function DetectIntent(const AKws: TStrArr): String;
    function DetectLibraryHints(const AQuery: String): TStrArr;
    function ScoreDocument(ADocIdx: Integer; const AAn: TRagAnalysis): Double;
  public
    constructor Create(const ABasePath: String);
    procedure Rebuild;
    function DocumentCount: Integer;
    function FunctionCount: Integer;
    function RetrieveList(const AQuery: String; AMaxTokens: Integer): TRagResultArr;
    function GetDocument(const AId: String; out AFound: Boolean): String;
    function FindByFunctions(const AFuncs: String): TRagResultArr;
    function FindByTags(const ATags: String): TRagResultArr;
    function AnalyzeJson(const AQuery: String): String;
    function Summary: String;
  end;

var
  GRagError: Integer;   // last error code; rag_error() reads it (0 = ok, 1 = bad handle)

// ============================================================================
//  Small string helpers (objfpc has no TStringHelper .Contains/.StartsWith)
// ============================================================================

procedure AddStr(var A: TStrArr; const S: String);
begin
  SetLength(A, Length(A) + 1);
  A[High(A)] := S;
end;

function HasStr(const A: TStrArr; const S: String): Boolean;
var i: Integer;
begin
  for i := 0 to High(A) do
    if A[i] = S then Exit(True);
  Result := False;
end;

function ContainsSub(const AHay, ANeedle: String): Boolean;
begin
  Result := (ANeedle <> '') and (Pos(ANeedle, AHay) > 0);
end;

function StripFuncSuffix(const S: String): String;
begin
  Result := S;
  while (Result <> '') and (Result[Length(Result)] in ['#', '$', '@']) do
    SetLength(Result, Length(Result) - 1);
end;

function NormalizeTag(const ATag: String): String;
begin
  Result := LowerCase(Trim(ATag));
  while (Result <> '') and (Result[Length(Result)] in [',', ';']) do
    SetLength(Result, Length(Result) - 1);
end;

// Split "a, b, c" (or "[a, b, c]") into trimmed, non-empty parts.
function SplitCSV(const S: String): TStrArr;
var i, start: Integer; part, clean: String;
begin
  Result := nil;
  clean := Trim(S);
  if (clean <> '') and (clean[1] = '[') then clean := Copy(clean, 2, MaxInt);
  if (clean <> '') and (clean[Length(clean)] = ']') then clean := Copy(clean, 1, Length(clean) - 1);
  start := 1;
  for i := 1 to Length(clean) + 1 do
    if (i > Length(clean)) or (clean[i] = ',') then
    begin
      part := Trim(Copy(clean, start, i - start));
      if part <> '' then AddStr(Result, part);
      start := i + 1;
    end;
end;

// Split on any of the given single-char delimiters, dropping empties.
function SplitChars(const S: String; const Delims: TSysCharSet): TStrArr;
var i, start: Integer; part: String;
begin
  Result := nil;
  start := 1;
  for i := 1 to Length(S) + 1 do
    if (i > Length(S)) or (S[i] in Delims) then
    begin
      part := Copy(S, start, i - start);
      if part <> '' then AddStr(Result, part);
      start := i + 1;
    end;
end;

// Split into lines on LF, tolerating CRLF (a trailing CR is dropped).
function SplitLinesLF(const S: String): TStrArr;
var i, start: Integer; part: String;
begin
  Result := nil;
  start := 1;
  for i := 1 to Length(S) + 1 do
    if (i > Length(S)) or (S[i] = #10) then
    begin
      part := Copy(S, start, i - start);
      if (part <> '') and (part[Length(part)] = #13) then SetLength(part, Length(part) - 1);
      AddStr(Result, part);
      start := i + 1;
    end;
end;

function ReadFileText(const APath: String): String;
var fs: TFileStream; len: Int64;
begin
  Result := '';
  if not FileExists(APath) then Exit;
  try
    fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      len := fs.Size;
      SetLength(Result, len);
      if len > 0 then fs.ReadBuffer(Result[1], len);
    finally
      fs.Free;
    end;
  except
    Result := '';
  end;
end;

// ============================================================================
//  TPhosphorRag
// ============================================================================

constructor TPhosphorRag.Create(const ABasePath: String);
begin
  inherited Create();
  FBasePath := ABasePath;
  FMaxTokens := RAG_DEFAULT_MAX_TOKENS;
  SetLength(FDocs, 0);
end;

function TPhosphorRag.IndexOfId(const AId: String): Integer;
var i: Integer; low: String;
begin
  low := LowerCase(AId);
  for i := 0 to High(FDocs) do
    if LowerCase(FDocs[i].Id) = low then Exit(i);
  Result := -1;
end;

function TPhosphorRag.EstimateTokens(const AText: String): Integer;
begin
  if AText = '' then Result := 0
  else Result := Length(AText) div RAG_CHARS_PER_TOKEN;
  if (AText <> '') and (Result < 1) then Result := 1;
end;

// Parse the YAML-style front-matter of one markdown file into a document.
function ParseHeader(const AFullPath: String): TRagDoc;
var content, header, line, key, value: String; lines: TStrArr;
    endMarker, colon, i: Integer;
begin
  Result := Default(TRagDoc);
  Result.FullPath := AFullPath;
  content := ReadFileText(AFullPath);
  Result.SizeBytes := Length(content);
  Result.TokenEstimate := Result.SizeBytes div RAG_CHARS_PER_TOKEN;

  if Copy(content, 1, 3) <> '---' then
  begin
    // No header: minimal metadata from the filename stem.
    Result.Id := LowerCase(ChangeFileExt(ExtractFileName(AFullPath), ''));
    Result.Title := Result.Id;
    Result.Category := 'library';
    SetLength(Result.Tags, 1); Result.Tags[0] := Result.Id;
    Exit;
  end;

  endMarker := PosEx('---', content, 4);
  if endMarker <= 0 then Exit;
  header := Copy(content, 4, endMarker - 4);
  lines := SplitLinesLF(header);

  for i := 0 to High(lines) do
  begin
    line := Trim(lines[i]);
    if line = '' then Continue;
    colon := Pos(':', line);
    if colon <= 0 then Continue;
    key := Trim(LowerCase(Copy(line, 1, colon - 1)));
    value := Trim(Copy(line, colon + 1, MaxInt));

    if key = 'id' then Result.Id := value
    else if key = 'title' then Result.Title := value
    else if key = 'category' then Result.Category := LowerCase(value)
    else if key = 'subcategory' then Result.Subcategory := LowerCase(value)
    else if key = 'tags' then Result.Tags := SplitCSV(value)
    else if key = 'functions' then Result.Functions := SplitCSV(value)
    else if key = 'depends' then Result.Depends := SplitCSV(value)
    else if key = 'complexity' then Result.Complexity := LowerCase(value)
    else if key = 'platform' then Result.Platform := LowerCase(value)
    else if key = 'summary' then Result.Summary := value;
  end;

  if Result.Id = '' then
    Result.Id := LowerCase(ChangeFileExt(ExtractFileName(AFullPath), ''));
end;

procedure TPhosphorRag.Rebuild;
var sr: TSearchRec; base: String; doc: TRagDoc;
begin
  SetLength(FDocs, 0);
  if not DirectoryExists(FBasePath) then Exit;   // an empty/missing folder = no docs, not a fault
  base := IncludeTrailingPathDelimiter(FBasePath);
  if FindFirst(base + '*.md', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Attr and faDirectory) <> 0 then Continue;
      doc := ParseHeader(base + sr.Name);
      if doc.Id = '' then Continue;
      SetLength(FDocs, Length(FDocs) + 1);
      FDocs[High(FDocs)] := doc;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function TPhosphorRag.DocumentCount: Integer;
begin
  Result := Length(FDocs);
end;

// Distinct (case-insensitive) function names across all documents.
function TPhosphorRag.FunctionCount: Integer;
var i, j: Integer; seen: TStringList;
begin
  seen := TStringList.Create();
  try
    seen.Sorted := True;
    seen.Duplicates := dupIgnore;
    seen.CaseSensitive := False;
    for i := 0 to High(FDocs) do
      for j := 0 to High(FDocs[i].Functions) do
        if FDocs[i].Functions[j] <> '' then
          seen.Add(LowerCase(FDocs[i].Functions[j]));
    Result := seen.Count;
  finally
    seen.Free;
  end;
end;

// Read a document's body, stripping the front-matter, caching the FULL text so
// a later budget-truncated retrieve can never poison the cache with a cut copy.
function TPhosphorRag.LoadContent(ADocIdx: Integer): String;
var raw: String; endMarker: Integer;
begin
  if FDocs[ADocIdx].ContentLoaded then Exit(FDocs[ADocIdx].Content);
  raw := ReadFileText(FDocs[ADocIdx].FullPath);
  if Copy(raw, 1, 3) = '---' then
  begin
    endMarker := PosEx('---', raw, 4);
    if endMarker > 0 then raw := Trim(Copy(raw, endMarker + 3, MaxInt));
  end;
  FDocs[ADocIdx].Content := raw;
  FDocs[ADocIdx].ContentLoaded := True;
  Result := raw;
end;

// ---- query analysis --------------------------------------------------------

function TPhosphorRag.ExtractKeywords(const AQuery: String): TStrArr;
const
  STOP: array[0..59] of String = (
    'a','an','the','is','are','was','were','be','been','being',
    'have','has','had','do','does','did','will','would','could',
    'should','may','might','shall','can','need','dare','ought',
    'i','me','my','we','our','you','your','he','she','it',
    'they','them','that','this','these','those','what','which',
    'who','whom','where','when','why','how','of','in','to',
    'for','with','on','at','from','by');
var cleaned, lw: String; i, k: Integer; words: TStrArr; isStop: Boolean;
begin
  Result := nil;
  cleaned := LowerCase(AQuery);
  for i := 1 to Length(cleaned) do
    if not (cleaned[i] in ['a'..'z', '0'..'9', '_', '#', '$', '@', ' ']) then
      cleaned[i] := ' ';
  words := SplitChars(cleaned, [' ']);
  for k := 0 to High(words) do
  begin
    lw := Trim(words[k]);
    if Length(lw) < 2 then Continue;
    isStop := False;
    for i := 0 to High(STOP) do
      if lw = STOP[i] then begin isStop := True; Break; end;
    if isStop then Continue;
    if (lw = 'create') or (lw = 'make') or (lw = 'build') or (lw = 'want') or
       (lw = 'need') or (lw = 'please') or (lw = 'help') or (lw = 'show') or
       (lw = 'using') or (lw = 'like') or (lw = 'just') or (lw = 'some') then Continue;
    if not HasStr(Result, lw) then AddStr(Result, lw);
  end;
end;

function TPhosphorRag.DetectFunctionNames(const AQuery: String): TStrArr;
var words: TStrArr; k: Integer; lw: String;
  function InIndex(const AName: String): Boolean;
  var i, j: Integer;
  begin
    for i := 0 to High(FDocs) do
      for j := 0 to High(FDocs[i].Functions) do
        if LowerCase(FDocs[i].Functions[j]) = AName then Exit(True);
    Result := False;
  end;
begin
  Result := nil;
  words := SplitChars(LowerCase(AQuery), [' ', ',', ';', '(', ')']);
  for k := 0 to High(words) do
  begin
    lw := Trim(words[k]);
    if lw = '' then Continue;
    if lw[Length(lw)] in ['#', '$', '@'] then
    begin
      if not HasStr(Result, lw) then AddStr(Result, lw);
      Continue;
    end;
    if InIndex(lw) then begin if not HasStr(Result, lw) then AddStr(Result, lw); Continue; end;
    if InIndex(lw + '@') then begin if not HasStr(Result, lw + '@') then AddStr(Result, lw + '@'); end
    else if InIndex(lw + '#') then begin if not HasStr(Result, lw + '#') then AddStr(Result, lw + '#'); end
    else if InIndex(lw + '$') then begin if not HasStr(Result, lw + '$') then AddStr(Result, lw + '$'); end;
  end;
end;

function TPhosphorRag.DetectIntent(const AKws: TStrArr): String;
var best: Double; bestName: String;
  function Sc(const words: array of String): Double;
  var i, j: Integer; s: Double; kw, iw: String;
  begin
    s := 0;
    for i := 0 to High(AKws) do
    begin
      kw := AKws[i];
      for j := 0 to High(words) do
      begin
        iw := words[j];
        if kw = iw then s := s + 1.0
        else if (Pos(iw, kw) > 0) or (Pos(kw, iw) > 0) then s := s + 0.5;
      end;
    end;
    Sc := s;
  end;
  procedure Consider(const AName: String; AScore: Double);
  begin
    if AScore > best then begin best := AScore; bestName := AName; end;
  end;
begin
  best := 0; bestName := '';
  Consider('gui', Sc(['form','window','button','gui','app','applet','interface','screen',
    'dialog','visual','click','menu','toolbar','panel','label','edit','checkbox',
    'combobox','listbox','image','widget','layout','control','textbox','input',
    'display','radio','switch','slider','trackbar','progress','grid','table','memo',
    'speedbutton','tab']));
  Consider('console', Sc(['console','text','print','println','input','command','cli',
    'terminal','output','prompt','stdin','stdout','hello']));
  Consider('data', Sc(['file','json','csv','xml','read','write','parse','data','load',
    'save','import','export','config','ini','array','dictionary','list','sort',
    'filter','record','struct']));
  Consider('network', Sc(['http','api','request','web','fetch','download','url','post',
    'get','rest','endpoint','server','client','upload','socket','response','header']));
  Consider('database', Sc(['database','sqlite','query','table','sql','crud','record',
    'field','select','insert','update','delete','schema','row','column','index']));
  Consider('animation', Sc(['animate','move','fade','rotate','transition','effect','tween',
    'interpolate','keyframe','timeline','color','glow','blur','ripple','swirl']));
  Consider('game', Sc(['game','score','player','collision','sprite','level','enemy',
    'health','lives','random','physics','bounce']));
  Consider('system', Sc(['os','platform','environment','system','process','execute','shell',
    'directory','path','date','time','clipboard','regex','timer','base64','gzip','zip']));
  Consider('shape', Sc(['draw','shape','circle','rectangle','ellipse','line','arc','pie',
    'path','polygon','round','canvas','paint','graphic']));
  if best >= 1.0 then Result := bestName else Result := '';
end;

function TPhosphorRag.DetectLibraryHints(const AQuery: String): TStrArr;
var lq, lowId: String; i: Integer;
begin
  Result := nil;
  lq := LowerCase(AQuery);
  for i := 0 to High(FDocs) do
  begin
    if FDocs[i].Category <> 'library' then Continue;
    lowId := LowerCase(FDocs[i].Id);
    if (lowId <> '') and (Pos(lowId, lq) > 0) and not HasStr(Result, FDocs[i].Id) then
      AddStr(Result, FDocs[i].Id);
  end;
end;

function TPhosphorRag.AnalyzeQuery(const AQuery: String): TRagAnalysis;
var lq: String;
begin
  Result := Default(TRagAnalysis);
  Result.Query := AQuery;
  Result.Keywords := ExtractKeywords(AQuery);
  Result.FunctionNames := DetectFunctionNames(AQuery);
  Result.Intent := DetectIntent(Result.Keywords);
  Result.LibraryHints := DetectLibraryHints(AQuery);
  lq := LowerCase(AQuery);
  Result.IsFollowUp := (Pos('also', lq) > 0) or (Pos('change', lq) > 0) or
    (Pos('modify', lq) > 0) or (Pos('add to', lq) > 0) or (Pos('update', lq) > 0);
end;

// ---- scoring (multi-signal, no embeddings) ---------------------------------
//   tag x3.0 + title x2.5 + function x5.0 + id x3.0 + library-hint x10 + lang boost
function TPhosphorRag.ScoreDocument(ADocIdx: Integer; const AAn: TRagAnalysis): Double;
var doc: TRagDoc; score: Double; tagHits, titleHits, funcHits, idHits, i, j: Integer;
    normTag, lowId, lowTitle, kw, lfn, ldf, stripped: String;
begin
  doc := FDocs[ADocIdx];
  score := 0;
  lowId := LowerCase(doc.Id);
  lowTitle := LowerCase(doc.Title);

  // Signal 1: tag matches (3.0)
  tagHits := 0;
  for i := 0 to High(AAn.Keywords) do
  begin
    kw := AAn.Keywords[i];
    for j := 0 to High(doc.Tags) do
    begin
      normTag := NormalizeTag(doc.Tags[j]);
      if kw = normTag then Inc(tagHits)
      else if (Length(kw) >= 3) and (ContainsSub(normTag, kw) or ContainsSub(kw, normTag)) then Inc(tagHits);
    end;
  end;
  score := score + tagHits * 3.0;

  // Signal 2: title keyword matches (2.5)
  titleHits := 0;
  for i := 0 to High(AAn.Keywords) do
    if ContainsSub(lowTitle, AAn.Keywords[i]) then Inc(titleHits);
  score := score + titleHits * 2.5;

  // Signal 3: function name matches (5.0 -- highest)
  funcHits := 0;
  for i := 0 to High(AAn.FunctionNames) do
  begin
    lfn := LowerCase(AAn.FunctionNames[i]);
    for j := 0 to High(doc.Functions) do
    begin
      ldf := LowerCase(doc.Functions[j]);
      if lfn = ldf then Inc(funcHits)
      else begin
        stripped := StripFuncSuffix(lfn);
        if (stripped <> '') and (Pos(stripped, ldf) = 1) then Inc(funcHits);
      end;
    end;
  end;
  score := score + funcHits * 5.0;

  // Signal 4: direct id match in keywords (3.0)
  idHits := 0;
  for i := 0 to High(AAn.Keywords) do
  begin
    kw := AAn.Keywords[i];
    if lowId = kw then idHits := idHits + 2
    else if (Length(kw) >= 3) and ContainsSub(lowId, kw) then Inc(idHits);
  end;
  score := score + idHits * 3.0;

  // Signal 5: explicit library hint (10.0 -- the user named the lib)
  for i := 0 to High(AAn.LibraryHints) do
    if LowerCase(AAn.LibraryHints[i]) = lowId then begin score := score + 10.0; Break; end;

  // Signal 6: language rules always useful -- small baseline boost
  if doc.Category = 'language' then
  begin
    score := score + 0.5;
    if (lowId = 'conventions') or (lowId = 'syntax') then score := score + 1.0;
  end;

  Result := score;
end;

// Keep headers/tables/code and essential lines until the token budget is spent.
function TPhosphorRag.ExtractEssential(const AContent: String; AMaxTokens: Integer): String;
var lines: TStrArr; i, curTokens: Integer; line, tl, head, tail: String;
    inEssential: Boolean; sb: TStringList;
begin
  lines := SplitLinesLF(AContent);
  sb := TStringList.Create();
  try
    curTokens := 0;
    inEssential := True;
    for i := 0 to High(lines) do
    begin
      line := lines[i];
      tl := Trim(line);
      head := Copy(tl, 1, 1);
      tail := Copy(tl, 1, 3);
      if head = '#' then
      begin
        inEssential := True;
        sb.Add(line); curTokens := curTokens + EstimateTokens(line);
        Continue;
      end;
      if head = '|' then
      begin
        sb.Add(line); curTokens := curTokens + EstimateTokens(line);
        if curTokens >= AMaxTokens then Break;
        Continue;
      end;
      if (tail = '```') or (head = '''') then
      begin
        inEssential := True;
        sb.Add(line); curTokens := curTokens + EstimateTokens(line);
        if curTokens >= AMaxTokens then Break;
        Continue;
      end;
      if inEssential then
      begin
        sb.Add(line); curTokens := curTokens + EstimateTokens(line);
        if (tl = '') and (curTokens > AMaxTokens div 2) then inEssential := False;
      end;
      if curTokens >= AMaxTokens then Break;
    end;
    if curTokens >= AMaxTokens then sb.Add('... (truncated for token budget)');
    // Join with explicit LF (never TStringList.Text: that appends a platform
    // line ending, which would drift between Windows and Linux).
    Result := '';
    for i := 0 to sb.Count - 1 do Result := Result + sb[i] + #10;
  finally
    sb.Free;
  end;
end;

// Core retrieval: score, sort, fit to budget, load & truncate content.
function TPhosphorRag.RetrieveList(const AQuery: String; AMaxTokens: Integer): TRagResultArr;
var an: TRagAnalysis; budget, i, j, tokensUsed, docTokens, remaining, sel: Integer;
    scoreIdx: array of Integer; scoreVal: array of Double;
    selIdx: array of Integer; ti: Integer; td: Double;
    content: String; res: TRagResult;
begin
  Result := nil;
  if AMaxTokens <= 0 then AMaxTokens := FMaxTokens;
  budget := AMaxTokens;
  an := AnalyzeQuery(AQuery);

  // Phase 1: score every document, keep those above the relevance floor.
  SetLength(scoreIdx, 0); SetLength(scoreVal, 0);
  for i := 0 to High(FDocs) do
  begin
    td := ScoreDocument(i, an);
    if td >= RAG_MIN_RELEVANCE then
    begin
      SetLength(scoreIdx, Length(scoreIdx) + 1);
      SetLength(scoreVal, Length(scoreVal) + 1);
      scoreIdx[High(scoreIdx)] := i;
      scoreVal[High(scoreVal)] := td;
    end;
  end;

  // Sort by score descending (insertion sort -- stable, tiny n).
  for i := 1 to High(scoreVal) do
  begin
    td := scoreVal[i]; ti := scoreIdx[i]; j := i - 1;
    while (j >= 0) and (scoreVal[j] < td) do
    begin
      scoreVal[j + 1] := scoreVal[j]; scoreIdx[j + 1] := scoreIdx[j]; Dec(j);
    end;
    scoreVal[j + 1] := td; scoreIdx[j + 1] := ti;
  end;

  // Phase 2: select within the token budget (a highly-relevant over-budget doc
  // is admitted truncated, exactly once, using the remaining budget).
  SetLength(selIdx, 0);
  tokensUsed := 0;
  for i := 0 to High(scoreIdx) do
  begin
    if Length(selIdx) >= RAG_MAX_RESULTS then Break;
    docTokens := FDocs[scoreIdx[i]].TokenEstimate;
    if tokensUsed + docTokens <= budget then
    begin
      SetLength(selIdx, Length(selIdx) + 1); selIdx[High(selIdx)] := i;
      tokensUsed := tokensUsed + docTokens;
    end
    else if (scoreVal[i] >= RAG_HIGH_RELEVANCE) and (tokensUsed < budget) then
    begin
      SetLength(selIdx, Length(selIdx) + 1); selIdx[High(selIdx)] := i;
      tokensUsed := budget;
    end;
  end;

  // Phase 3: build results, loading full content and truncating a local copy.
  remaining := budget;
  for i := 0 to High(selIdx) do
  begin
    sel := selIdx[i];
    content := LoadContent(scoreIdx[sel]);
    docTokens := EstimateTokens(content);
    res := Default(TRagResult);
    res.DocIdx := scoreIdx[sel];
    res.Score := scoreVal[sel];
    if docTokens > remaining then
    begin
      content := ExtractEssential(content, remaining);
      docTokens := EstimateTokens(content);
      res.Truncated := True;
    end
    else
      res.Truncated := False;
    res.Content := content;
    res.Tokens := docTokens;
    remaining := remaining - docTokens;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := res;
  end;
end;

function TPhosphorRag.GetDocument(const AId: String; out AFound: Boolean): String;
var idx: Integer;
begin
  idx := IndexOfId(AId);
  AFound := idx >= 0;
  if AFound then Result := LoadContent(idx)
  else Result := 'Error: document not found: ' + AId;
end;

function TPhosphorRag.FindByFunctions(const AFuncs: String): TRagResultArr;
var names: TStrArr; picked: array of Integer; k, i, j: Integer; res: TRagResult;
  function AlreadyPicked(AIdx: Integer): Boolean;
  var m: Integer;
  begin
    for m := 0 to High(picked) do if picked[m] = AIdx then Exit(True);
    Result := False;
  end;
begin
  Result := nil;
  SetLength(picked, 0);
  names := SplitChars(AFuncs, [',', ' ']);
  for k := 0 to High(names) do
    for i := 0 to High(FDocs) do
      for j := 0 to High(FDocs[i].Functions) do
        if (LowerCase(FDocs[i].Functions[j]) = LowerCase(names[k])) and not AlreadyPicked(i) then
        begin
          SetLength(picked, Length(picked) + 1); picked[High(picked)] := i;
        end;
  for k := 0 to High(picked) do
  begin
    res := Default(TRagResult);
    res.DocIdx := picked[k];
    res.Score := 5.0;
    res.Content := LoadContent(picked[k]);
    res.Tokens := EstimateTokens(res.Content);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := res;
  end;
end;

function TPhosphorRag.FindByTags(const ATags: String): TRagResultArr;
var tags: TStrArr; picked: array of Integer; k, i, j: Integer; nt: String; res: TRagResult;
  function AlreadyPicked(AIdx: Integer): Boolean;
  var m: Integer;
  begin
    for m := 0 to High(picked) do if picked[m] = AIdx then Exit(True);
    Result := False;
  end;
begin
  Result := nil;
  SetLength(picked, 0);
  tags := SplitCSV(ATags);
  for k := 0 to High(tags) do
  begin
    nt := NormalizeTag(tags[k]);
    for i := 0 to High(FDocs) do
      for j := 0 to High(FDocs[i].Tags) do
        if (NormalizeTag(FDocs[i].Tags[j]) = nt) and not AlreadyPicked(i) then
        begin
          SetLength(picked, Length(picked) + 1); picked[High(picked)] := i;
        end;
  end;
  for k := 0 to High(picked) do
  begin
    res := Default(TRagResult);
    res.DocIdx := picked[k];
    res.Score := 3.0;
    res.Content := LoadContent(picked[k]);
    res.Tokens := EstimateTokens(res.Content);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := res;
  end;
end;

function TPhosphorRag.AnalyzeJson(const AQuery: String): String;
var an: TRagAnalysis; obj: TJSONObject; kw, fn, hint: TJSONArray; i: Integer;
begin
  an := AnalyzeQuery(AQuery);
  obj := TJSONObject.Create();
  try
    obj.Add('query', an.Query);
    obj.Add('intent', an.Intent);
    obj.Add('is_followup', an.IsFollowUp);
    // TJSONArray.Add(String) is the one fpjson overload that re-encodes a byte
    // >= $80 on the way in (measured: five bytes stored as seven). The object's
    // two-argument Add is byte-exact and is left as it is.
    kw := TJSONArray.Create();
    for i := 0 to High(an.Keywords) do kw.Add(TJSONString.Create(an.Keywords[i]));
    obj.Add('keywords', kw);
    fn := TJSONArray.Create();
    for i := 0 to High(an.FunctionNames) do fn.Add(TJSONString.Create(an.FunctionNames[i]));
    obj.Add('function_names', fn);
    hint := TJSONArray.Create();
    for i := 0 to High(an.LibraryHints) do hint.Add(TJSONString.Create(an.LibraryHints[i]));
    obj.Add('library_hints', hint);
    Result := JsonText(obj, False, 2, 0);
  finally
    obj.Free;
  end;
end;

function TPhosphorRag.Summary: String;
var i, funcCount, tagCount: Integer; seenF, seenT: TStringList; nl: String;
begin
  nl := #10;
  seenF := TStringList.Create();
  seenT := TStringList.Create();
  try
    seenF.Sorted := True; seenF.Duplicates := dupIgnore; seenF.CaseSensitive := False;
    seenT.Sorted := True; seenT.Duplicates := dupIgnore; seenT.CaseSensitive := False;
    for i := 0 to High(FDocs) do
    begin
      for funcCount := 0 to High(FDocs[i].Functions) do
        if FDocs[i].Functions[funcCount] <> '' then seenF.Add(LowerCase(FDocs[i].Functions[funcCount]));
      for tagCount := 0 to High(FDocs[i].Tags) do
        if FDocs[i].Tags[tagCount] <> '' then seenT.Add(NormalizeTag(FDocs[i].Tags[tagCount]));
    end;
    funcCount := seenF.Count;
    tagCount := seenT.Count;
  finally
    seenF.Free; seenT.Free;
  end;
  Result := '=== RAG Engine Index Summary ===' + nl +
    'Base path: ' + FBasePath + nl +
    'Documents: ' + IntToStr(Length(FDocs)) + nl +
    'Functions indexed: ' + IntToStr(funcCount) + nl +
    'Tags indexed: ' + IntToStr(tagCount) + nl +
    'Max tokens: ' + IntToStr(FMaxTokens) + nl;
end;

// ============================================================================
//  Bound functions -- the handle is validated through PhosphorHandles; a
//  fabricated/stale id is refused (GRagError := 1) and never dereferenced.
// ============================================================================

function AsRag(const V: TValue; out ARag: TPhosphorRag): Boolean;
begin
  ARag := nil;
  Result := (V.Kind = vkHandle) and IsHandle(V.Hnd) and (HandleObj(V.Hnd) is TPhosphorRag);
  if Result then ARag := TPhosphorRag(HandleObj(V.Hnd));
  if Result then GRagError := 0 else GRagError := 1;
end;

// Combine results into the "### Title\n<content>" block form, LF-joined.
function RenderResults(ARag: TPhosphorRag; const AResults: TRagResultArr; AWithScore, AWithTruncNote: Boolean): String;
var i: Integer; doc: TRagDoc; title: String;
begin
  Result := '';
  for i := 0 to High(AResults) do
  begin
    doc := ARag.FDocs[AResults[i].DocIdx];
    if Result <> '' then Result := Result + #10 + #10;
    if AWithScore then
      // RagFS, not the machine's settings: the score went through
      // DefaultFormatSettings, so the same index answered "score: 3.0" on one
      // machine and "score: 3,0" on another, and a caller parsing it back got a
      // different number or none.
      title := Format('### %s (score: %.1f)', [doc.Title, AResults[i].Score], RagFS)
    else
      title := '### ' + doc.Title;
    Result := Result + title + #10 + AResults[i].Content;
    if AWithTruncNote and AResults[i].Truncated then Result := Result + #10 + '(truncated)';
  end;
end;

function t_rag_create(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TPhosphorRag;
begin
  Err := NoError();
  GRagError := 0;
  r := TPhosphorRag.Create(Args[0].Str);
  Result := ValHandle(RegisterHandle(r));
end;

function t_rag_free(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if (Args[0].Kind = vkHandle) and IsHandle(Args[0].Hnd) and (HandleObj(Args[0].Hnd) is TPhosphorRag) then
  begin
    FreeHandle(Args[0].Hnd);
    GRagError := 0;
    Result := ValInt(1);
  end
  else
  begin
    GRagError := 1;
    Result := ValInt(0);
  end;
end;

function t_rag_rebuild(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TPhosphorRag;
begin
  Err := NoError();
  if AsRag(Args[0], r) then r.Rebuild();
  Result := Args[0];   // return the handle so calls can chain
end;

function t_rag_count(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TPhosphorRag;
begin
  Err := NoError();
  if AsRag(Args[0], r) then Result := ValInt(r.DocumentCount()) else Result := ValInt(0);
end;

function t_rag_funccount(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TPhosphorRag;
begin
  Err := NoError();
  if AsRag(Args[0], r) then Result := ValInt(r.FunctionCount()) else Result := ValInt(0);
end;

function t_rag_retrieve(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TPhosphorRag;
begin
  Err := NoError();
  if AsRag(Args[0], r) then
    Result := ValStr(RenderResults(r, r.RetrieveList(Args[1].Str, 0), False, True))
  else Result := ValStr('');
end;

function t_rag_retrieve_budget(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TPhosphorRag;
begin
  Err := NoError();
  if AsRag(Args[0], r) then
    Result := ValStr(RenderResults(r, r.RetrieveList(Args[1].Str, ArgI32(Args[2])), False, False))
  else Result := ValStr('');
end;

function t_rag_retrieve_json(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TPhosphorRag; results: TRagResultArr; arr: TJSONArray; obj: TJSONObject; i: Integer; doc: TRagDoc;
begin
  Err := NoError();
  if not AsRag(Args[0], r) then begin Result := ValStr('[]'); Exit; end;
  results := r.RetrieveList(Args[1].Str, 0);
  arr := TJSONArray.Create();
  try
    for i := 0 to High(results) do
    begin
      doc := r.FDocs[results[i].DocIdx];
      obj := TJSONObject.Create();
      obj.Add('id', doc.Id);
      obj.Add('title', doc.Title);
      obj.Add('category', doc.Category);
      obj.Add('score', results[i].Score);
      obj.Add('tokens', results[i].Tokens);
      obj.Add('truncated', results[i].Truncated);
      obj.Add('content', results[i].Content);
      arr.Add(obj);
    end;
    Result := ValStr(JsonText(arr, False, 2, 0));
  finally
    arr.Free;
  end;
end;

function t_rag_doc(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TPhosphorRag; found: Boolean;
begin
  Err := NoError();
  if AsRag(Args[0], r) then Result := ValStr(r.GetDocument(Args[1].Str, found))
  else Result := ValStr('Error: invalid RAG handle');
end;

function t_rag_functions(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TPhosphorRag;
begin
  Err := NoError();
  if AsRag(Args[0], r) then Result := ValStr(RenderResults(r, r.FindByFunctions(Args[1].Str), False, False))
  else Result := ValStr('');
end;

function t_rag_tags(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TPhosphorRag;
begin
  Err := NoError();
  if AsRag(Args[0], r) then Result := ValStr(RenderResults(r, r.FindByTags(Args[1].Str), True, False))
  else Result := ValStr('');
end;

function t_rag_analyze(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TPhosphorRag;
begin
  Err := NoError();
  if AsRag(Args[0], r) then Result := ValStr(r.AnalyzeJson(Args[1].Str)) else Result := ValStr('');
end;

function t_rag_summary(const Args: array of TValue; out Err: TPhosphorError): TValue;
var r: TPhosphorRag;
begin
  Err := NoError();
  if AsRag(Args[0], r) then Result := ValStr(r.Summary) else Result := ValStr('');
end;

function t_rag_error(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(GRagError);
end;

procedure RegisterRagFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('rag@:$',                   @t_rag_create);
  Reg.Add('rag_free:@',               @t_rag_free);
  Reg.Add('rag_rebuild@:@',           @t_rag_rebuild);
  Reg.Add('rag_retrieve$:@$',         @t_rag_retrieve);
  Reg.Add('rag_retrieve_json$:@$',    @t_rag_retrieve_json);
  Reg.Add('rag_retrieve_budget$:@$n', @t_rag_retrieve_budget);
  Reg.Add('rag_doc$:@$',              @t_rag_doc);
  Reg.Add('rag_functions$:@$',        @t_rag_functions);
  Reg.Add('rag_tags$:@$',             @t_rag_tags);
  Reg.Add('rag_analyze$:@$',          @t_rag_analyze);
  Reg.Add('rag_count:@',              @t_rag_count);
  Reg.Add('rag_funccount:@',          @t_rag_funccount);
  Reg.Add('rag_summary$:@',           @t_rag_summary);
  Reg.Add('rag_error:',               @t_rag_error);
end;

initialization
  GRagError := 0;
  RagFS := DefaultFormatSettings;
  RagFS.DecimalSeparator := '.';
  RagFS.ThousandSeparator := #0;

end.
