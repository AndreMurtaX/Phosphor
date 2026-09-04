{******************************************************************************
  Phosphor BASIC -- HTTP client (an OPT-IN host package)

  MIT License. Copyright (c) 2026 Andre Murta.

  An opt-in package (host/packages/, RegisterHttpFuncs) over FPC's TFPHTTPClient.
  The same three functions serve both http:// and https:// -- the URL scheme selects
  TLS, no separate API. Plain HTTP needs no external library; https:// needs the
  OpenSSL runtime (libssl/libcrypto), pulled in by the opensslsockets handler in the
  uses clause -- so a host that never fetches https carries no dependency, and one
  that does gets it where OpenSSL is installed (library-gated in the test suite, like
  sqlite).

    http_get$(url$)          GET url$, return the response body
    http_status(url$)        GET url$, return the HTTP status code (0 on failure)
    http_post$(url$, body$)  POST body$ to url$, return the response body
    http_verify_peer(on%)    turn https certificate verification on (default) / off
    http_ca_file$(path$)     use a specific CA bundle for verification

  THE OFFLINE CONFIGURATION SURFACE. A request is a bag of settings until a verb is
  called: building a client, configuring it, filling in a form and encoding a string
  are all offline, and that is most of an HTTP library. A client handle (http_client@)
  is a pure config accumulator -- its own record, validated through PhosphorHandles
  like every other Phosphor handle, so a fabricated or stale id is REFUSED (IsHandle)
  rather than dereferenced. None of it touches the network:

    http_client@() / http_client@(url$)     a client handle (a config accumulator)
    http_free(c@)   http_reset(c@)          release / return it to the factory state
    http_baseurl$(c@)  http_baseurl(c@,u$)  the base url (getter / setter)
    http_timeout(c@)  http_timeout(c@,ms)   connect timeout, ms (getter / setter)
    http_responsetimeout(c@, ms)            response timeout, ms (no getter)
    http_header* / http_param* / http_cookie*   name/value bags: count/set/get/remove/clear
    http_basicauth / http_bearerauth / http_customauth / http_clearauth   auth (write-only)
    http_proxy / http_proxyauth / http_clearproxy                         proxy
    http_useragent / http_contenttype / http_accept  (with $ getters)     behaviour
    http_followredirects / http_maxredirects / http_validatessl (get+set) behaviour
    http_form@()  http_formfield / http_formfile / http_formfilenamed / http_formfiletype
    http_formurlencoded$(f@)  http_formfieldcount / http_formfilecount / http_formclear / http_formfree
    http_urlencode$ / http_urldecode$ / http_htmlencode$ / http_htmldecode$   pure encoders
    http_error()  http_clearerror()  http_strerror$(code)                 error accessors

  A header/param/cookie is a name/value bag: setting an existing name REPLACES it (it
  does not add a duplicate); header names match case-insensitively (the HTTP rule).
  The url encoder writes a space as %20 (not '+', which is form encoding) and a literal
  '+' as %2B, so the two never collide on the way back; the decoder still reads '+' as a
  space so form-spelled data keeps working. http_error() is the ioerror/valcode pattern:
  a config op on a live handle clears it, a fabricated handle sets it non-zero, and no
  op raises.

  Contract: http_get$/http_post$ return the response body for ANY status (the body of
  an error response too -- pair with http_status when the code matters). http_status
  returns the code for any response, and 0 only when the request could not complete.
  Nothing here raises: a 404 is an answer the BASIC program inspects, not an exception.

  HTTPS CERTIFICATE VERIFICATION. FPC's OpenSSL handler ships INSECURE: it accepts any
  certificate (expired, self-signed, wrong host) -- TLS that encrypts but does not
  authenticate. We turn that around: verification is ON by default (SSL_VERIFY_PEER
  plus the system CA bundle, auto-located at startup), so an expired, self-signed, or
  untrusted-CA certificate makes the connection FAIL rather than silently succeed. A
  box with no CA bundle in a standard place (e.g. Windows) fails closed until
  http_ca_file$() supplies one -- secure by default, never a blanket trust-all. A
  script that genuinely means to talk to a self-signed dev server opts out explicitly
  with http_verify_peer(0). (Known gap: this validates the certificate CHAIN, not yet
  the hostname -- a cert valid for another host would still pass; hostname
  verification is the next refinement.)

  MULTI-ADDRESS FALLBACK. FPC 3.2.2's socket layer (TInetSocket) resolves a host to
  the FIRST of its A records and connects only to that one -- if that single IP is
  down or blocked, the request fails even when the host's other IPs are healthy (as a
  round-robin CDN's routinely are). We do better: resolve ALL of a host's A records
  and try each until one connects. To dial a specific IP while still sending the
  hostname in Host: (so virtual-hosted servers route correctly), a small TFPHTTPClient
  subclass pins the connect target -- SendRequest still builds Host: from the URL.
  (The underlying socket layer is IPv4-only, so IPv6/AAAA endpoints remain out of
  reach here; that would need a hand-rolled AF_INET6 connect and is a separate step.)
******************************************************************************}
unit PhosphorHttpLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Types, StrUtils, base64, fphttpclient, opensslsockets, openssl,
  ssockets, sslsockets, sslbase, resolve, sockets, URIParser,
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles;

procedure RegisterHttpFuncs(Reg: TPhosphorRegistry);

{ The core fetch, with the multi-address fallback described in the unit header.
  Exposed so the test harness can drive the fallback deterministically by forcing the
  candidate address list (real callers leave AForceAddrs empty and let the host name
  resolve). Returns the body; AStatus receives the HTTP code (0 if nothing connected). }
function HttpFetch(const AMethod, AUrl, ABody: String;
  const AForceAddrs: array of String; out AStatus: Integer;
  AConnectMs: Integer = 5000): String;

implementation

var
  { HTTPS security posture (see the unit header). Verification is ON by default;
    gCAFile is the CA bundle chain verification checks against, auto-located at
    startup. A host/script relaxes verification with http_verify_peer(0) or points at
    a different bundle with http_ca_file$(). }
  gVerifyPeer: Boolean = True;
  gCAFile: String = '';

type
  { TFPHTTPClient derives BOTH the connect target and the Host: header from the request
    URI. Overriding ConnectToServer lets us dial one chosen IP while SendRequest keeps
    building Host: from the original URI -- the seam the fallback needs. GetSocketHandler
    is the second seam: it is where the TLS handler is born, so it is where we turn on
    certificate verification and hand it the CA bundle. }
  TPinnedClient = class(TFPHTTPClient)
  public
    ConnectIP: String;
  protected
    procedure ConnectToServer(const AHost: String; APort: Integer;
      UseSSL: Boolean = False); override;
    function GetSocketHandler(const UseSSL: Boolean): TSocketHandler; override;
  end;

procedure TPinnedClient.ConnectToServer(const AHost: String; APort: Integer;
  UseSSL: Boolean);
begin
  if ConnectIP <> '' then
    inherited ConnectToServer(ConnectIP, APort, UseSSL)
  else
    inherited ConnectToServer(AHost, APort, UseSSL);
end;

function TPinnedClient.GetSocketHandler(const UseSSL: Boolean): TSocketHandler;
begin
  Result := inherited GetSocketHandler(UseSSL);   // the registered OpenSSL handler
  if UseSSL and (Result is TSSLSocketHandler) then
  begin
    { VerifyPeerCert => SSL_VERIFY_PEER, and CertCA.FileName is LoadVerifyLocations'd
      into the context (see opensslsockets InitContext/InitSslKeys). Together that
      makes SSL_connect FAIL on an expired, self-signed, or untrusted-CA certificate,
      instead of FPC's default of accepting anything. }
    TSSLSocketHandler(Result).VerifyPeerCert := gVerifyPeer;
    if gVerifyPeer and (gCAFile <> '') then
      TSSLSocketHandler(Result).CertificateData.CertCA.FileName := gCAFile;
  end;
end;

{ A dotted-quad literal is used as-is; a name is resolved. Same "first byte zero =>
  needs lookup" test the socket layer itself applies. }
function IsIPv4Literal(const AHost: String): Boolean;
begin
  Result := StrToHostAddr(AHost).s_bytes[1] <> 0;
end;

{ All of a host's A records, dotted, in resolver order. THostResolver resolves the
  whole set even though the socket layer would use only the first. }
function ResolveAllA(const AHost: String): TStringDynArray;
var
  r: THostResolver;
  i: Integer;
begin
  Result := nil;
  r := THostResolver.Create(nil);
  try
    if r.NameLookup(AHost) then
      for i := 0 to r.AddressCount - 1 do
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := HostAddrToStr(r.Addresses[i]);
      end;
  finally
    r.Free;
  end;
end;

function HttpFetch(const AMethod, AUrl, ABody: String;
  const AForceAddrs: array of String; out AStatus: Integer;
  AConnectMs: Integer = 5000): String;
var
  addrs: TStringDynArray;
  uri: TURI;
  host, body: String;
  i: Integer;
  connected: Boolean;

  { One attempt against a single connect target ('' = dial the URL's host as written).
    AConnected separates a connection-level failure (try the next address) from a
    completed exchange, whatever its status code (stop and report it). }
  function Attempt(const AConnectIP: String; out AConnected: Boolean): String;
  var
    c: TPinnedClient;
    resp: TStringStream;
  begin
    Result := '';
    AConnected := False;
    AStatus := 0;
    resp := TStringStream.Create('');
    c := TPinnedClient.Create(nil);
    try
      c.ConnectIP := AConnectIP;
      c.ConnectTimeout := AConnectMs;         // ms; don't hang forever on a dead IP
      if CompareText(AMethod, 'POST') = 0 then
        c.RequestBody := TStringStream.Create(ABody);
      try
        try
          { [] as allowed-codes => every status is accepted (no raise), so the body of
            an error response is read into the stream too. }
          c.HTTPMethod(UpperCase(AMethod), AUrl, resp, []);
          AConnected := True;
        except
          on E: ESocketError do AConnected := False;   // dead address -> try the next
          on E: Exception do AConnected := True;        // reached; keep its answer
        end;
        AStatus := c.ResponseStatusCode;
        if AConnected then Result := resp.DataString;
      finally
        if Assigned(c.RequestBody) then
        begin
          c.RequestBody.Free;
          c.RequestBody := nil;
        end;
      end;
    finally
      c.Free;
      resp.Free;
    end;
  end;

begin
  Result := '';
  AStatus := 0;

  if Length(AForceAddrs) > 0 then
  begin
    SetLength(addrs, Length(AForceAddrs));
    for i := 0 to High(AForceAddrs) do addrs[i] := AForceAddrs[i];
  end
  else
  begin
    uri := ParseURI(AUrl);
    host := uri.Host;
    if (host = '') or IsIPv4Literal(host) or (LowerCase(uri.Protocol) = 'https') then
    begin
      { Dial the URL's host as written. For https this is deliberate: pinning a
        resolved IP would make the TLS layer see an IP for SNI and certificate
        hostname verification instead of the real name, breaking the handshake --
        the fallback is reconciled with TLS in a later step (docs/roadmap-net.md). }
      SetLength(addrs, 1);
      addrs[0] := '';
    end
    else
    begin
      addrs := ResolveAllA(host);
      if Length(addrs) = 0 then
      begin
        SetLength(addrs, 1);
        addrs[0] := '';               // resolution empty -> let the client try
      end;
    end;
  end;

  for i := 0 to High(addrs) do
  begin
    body := Attempt(addrs[i], connected);
    if connected then
    begin
      Result := body;
      Exit;
    end;
  end;
  { nothing connected: Result '' and AStatus 0 (from the last Attempt) }
end;

function f_http_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var status: Integer;
begin
  Err := NoError();
  Result := ValStr(HttpFetch('GET', Args[0].Str, '', [], status));
end;

function f_http_status(const Args: array of TValue; out Err: TPhosphorError): TValue;
var status: Integer;
begin
  Err := NoError();
  HttpFetch('GET', Args[0].Str, '', [], status);
  Result := ValInt(status);
end;

function f_http_post(const Args: array of TValue; out Err: TPhosphorError): TValue;
var status: Integer;
begin
  Err := NoError();
  Result := ValStr(HttpFetch('POST', Args[0].Str, Args[1].Str, [], status));
end;

{ http_verify_peer(on%) -- turn https certificate verification on (default) or off.
  Off is a deliberate, explicit choice for a self-signed dev server; it is never the
  default. Returns the value it set. }
function f_http_verify_peer(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  gVerifyPeer := AsDouble(Args[0]) <> 0;
  Result := ValInt(Ord(gVerifyPeer));
end;

{ http_ca_file$(path$) -- point verification at a specific CA bundle (PEM). Mainly for
  platforms without a system bundle in a standard place (e.g. Windows). Returns path$. }
function f_http_ca_file(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  gCAFile := Args[0].Str;
  Result := ValStr(gCAFile);
end;

{ ===========================================================================
  THE OFFLINE CONFIGURATION SURFACE
  A client handle is a config accumulator (its own record), a form handle collects
  fields and files, and the encoders are pure. Nothing here reaches the network.
  =========================================================================== }

const
  HTTP_OK      = 0;
  HTTP_EHANDLE = 1;   // an invalid / fabricated client or form handle

var
  gHttpErr: Integer = 0;   // ioerror/valcode: last config-op result, read by http_error

type
  { A name/value bag with replace-on-duplicate semantics, backed by two parallel
    TStringLists so an empty value is stored as a value (TStringList.Values[]:='' would
    DELETE the entry -- the classic trap). CaseSensitive is off for header names (the
    HTTP rule) and on for params/cookies. }
  TKVBag = class
  private
    FNames: TStringList;
    FVals: TStringList;
  public
    constructor Create(ACaseSensitive: Boolean);
    destructor Destroy; override;
    procedure SetVal(const AName, AValue: String);
    function GetVal(const AName: String): String;
    function RemoveName(const AName: String): Boolean;
    procedure Clear;
    function Count: Integer;
    function NameAt(AIndex: Integer): String;
    function ValueAt(AIndex: Integer): String;
  end;

  { The client: a bag of settings a verb would later act on. Owned entirely here; its
    destructor frees only its own bags (no handle deref), so it is safe under
    PhosphorHandles' ResetHandles at Run start and at finalization. }
  TPhosphorHttpClient = class
  public
    BaseUrl: String;
    ConnectTimeout: Integer;
    ResponseTimeout: Integer;
    Headers: TKVBag;
    Params: TKVBag;
    Cookies: TKVBag;
    UserAgent: String;
    ContentType: String;
    Accept: String;
    FollowRedirects: Boolean;
    MaxRedirects: Integer;
    ValidateSSL: Boolean;
    AuthHeader: String;
    ProxyHost: String;
    ProxyPort: Integer;
    ProxyUser: String;
    ProxyPass: String;
    constructor Create(const ABaseUrl: String);
    destructor Destroy; override;
    procedure ResetToFactory;
  end;

  { One file field of a multipart form: which form field it fills, the disk path, the
    name it is sent under, and its stated content type. }
  TFormFile = class
  public
    FieldName: String;
    Path: String;
    FileName: String;
    ContentType: String;
  end;

  { A form: text fields (a bag) plus file fields (a list). The url-encoded rendering
    walks the TEXT fields only -- a file cannot be url-encoded into a query string. }
  TPhosphorHttpForm = class
  public
    Fields: TKVBag;
    Files: TFPList;   // of TFormFile
    constructor Create;
    destructor Destroy; override;
    procedure AddFile(const AField, APath, AFileName, AContentType: String);
    procedure ClearAll;
  end;

{ TKVBag }

constructor TKVBag.Create(ACaseSensitive: Boolean);
begin
  FNames := TStringList.Create();
  FNames.CaseSensitive := ACaseSensitive;   // IndexOf honours this in FPC
  FVals := TStringList.Create();
end;

destructor TKVBag.Destroy;
begin
  FNames.Free;
  FVals.Free;
  inherited Destroy();
end;

procedure TKVBag.SetVal(const AName, AValue: String);
var i: Integer;
begin
  i := FNames.IndexOf(AName);
  if i >= 0 then
    FVals[i] := AValue
  else
  begin
    FNames.Add(AName);
    FVals.Add(AValue);
  end;
end;

function TKVBag.GetVal(const AName: String): String;
var i: Integer;
begin
  i := FNames.IndexOf(AName);
  if i >= 0 then Result := FVals[i] else Result := '';
end;

function TKVBag.RemoveName(const AName: String): Boolean;
var i: Integer;
begin
  i := FNames.IndexOf(AName);
  Result := i >= 0;
  if Result then
  begin
    FNames.Delete(i);
    FVals.Delete(i);
  end;
end;

procedure TKVBag.Clear;
begin
  FNames.Clear();
  FVals.Clear();
end;

function TKVBag.Count: Integer;
begin
  Result := FNames.Count;
end;

function TKVBag.NameAt(AIndex: Integer): String;
begin
  Result := FNames[AIndex];
end;

function TKVBag.ValueAt(AIndex: Integer): String;
begin
  Result := FVals[AIndex];
end;

{ TPhosphorHttpClient }

constructor TPhosphorHttpClient.Create(const ABaseUrl: String);
begin
  Headers := TKVBag.Create(False);   // header names are case-insensitive
  Params  := TKVBag.Create(True);
  Cookies := TKVBag.Create(True);
  BaseUrl := ABaseUrl;
  ResetToFactory();                    // leaves BaseUrl intact
end;

destructor TPhosphorHttpClient.Destroy;
begin
  Headers.Free;
  Params.Free;
  Cookies.Free;
  inherited Destroy();
end;

procedure TPhosphorHttpClient.ResetToFactory;
begin
  Headers.Clear();
  Params.Clear();
  Cookies.Clear();
  ConnectTimeout := 0;
  ResponseTimeout := 0;
  UserAgent := '';
  ContentType := '';
  Accept := '';
  FollowRedirects := True;
  MaxRedirects := 5;
  ValidateSSL := True;
  AuthHeader := '';
  ProxyHost := '';
  ProxyPort := 0;
  ProxyUser := '';
  ProxyPass := '';
  { BaseUrl is the client's identity: reset returns it to how it left the factory,
    which is with the base url it was constructed with, so BaseUrl is left intact. }
end;

{ TPhosphorHttpForm }

constructor TPhosphorHttpForm.Create;
begin
  Fields := TKVBag.Create(True);
  Files := TFPList.Create();
end;

destructor TPhosphorHttpForm.Destroy;
begin
  ClearAll();
  Fields.Free;
  Files.Free;
  inherited Destroy();
end;

procedure TPhosphorHttpForm.AddFile(const AField, APath, AFileName, AContentType: String);
var ff: TFormFile;
begin
  ff := TFormFile.Create();
  ff.FieldName := AField;
  ff.Path := APath;
  ff.FileName := AFileName;
  ff.ContentType := AContentType;
  Files.Add(ff);
end;

procedure TPhosphorHttpForm.ClearAll;
var i: Integer;
begin
  Fields.Clear();
  for i := 0 to Files.Count - 1 do
    TObject(Files[i]).Free;
  Files.Clear();
end;

{ ---- handle resolution ----------------------------------------------------- }
function GetClient(AId: Int64; out AC: TPhosphorHttpClient): Boolean;
var o: TObject;
begin
  o := HandleObj(AId);           // nil for a fabricated / stale id (never dereferenced)
  Result := o is TPhosphorHttpClient;
  if Result then AC := TPhosphorHttpClient(o) else AC := nil;
end;

function GetForm(AId: Int64; out AF: TPhosphorHttpForm): Boolean;
var o: TObject;
begin
  o := HandleObj(AId);
  Result := o is TPhosphorHttpForm;
  if Result then AF := TPhosphorHttpForm(o) else AF := nil;
end;

{ ---- pure encoders --------------------------------------------------------- }
{ RFC-3986 percent-encoding: unreserved (A-Z a-z 0-9 - _ . ~) pass through, everything
  else becomes %XX in UPPER hex. A space is %20 (not '+'), a literal '+' is %2B. }
function DoUrlEncode(const S: String): String;
var i: Integer; ch: Char;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    ch := S[i];
    if ((ch >= 'A') and (ch <= 'Z')) or ((ch >= 'a') and (ch <= 'z')) or
       ((ch >= '0') and (ch <= '9')) or (ch = '-') or (ch = '_') or
       (ch = '.') or (ch = '~') then
      Result := Result + ch
    else
      Result := Result + '%' + IntToHex(Ord(ch), 2);
  end;
end;

function HexNibble(ch: Char; out v: Integer): Boolean;
begin
  Result := True;
  case ch of
    '0'..'9': v := Ord(ch) - Ord('0');
    'a'..'f': v := Ord(ch) - Ord('a') + 10;
    'A'..'F': v := Ord(ch) - Ord('A') + 10;
  else
    begin v := 0; Result := False; end;
  end;
end;

{ Decode: %XX -> the byte; '+' -> a space (so form-spelled data still reads); anything
  else literal. %2B therefore comes back as '+', keeping it distinct from an encoded
  space on the round trip. }
function DoUrlDecode(const S: String): String;
var i, h1, h2, n: Integer; ch: Char; r: RawByteString;
begin
  // Build the bytes by INDEXED assignment into a RawByteString (output is never
  // longer than the input, so Length(S) is a safe upper bound). Concatenating
  // `Result + Chr(b)` under {$codepage UTF8} re-encodes a %XX byte >= 128 into its
  // multi-byte UTF-8 form (or '?'), which corrupted every percent-encoded non-ASCII
  // byte -- the same trap hex_decode$ and the gzip header avoid the same way.
  SetLength(r, Length(S));
  n := 0;
  i := 1;
  while i <= Length(S) do
  begin
    ch := S[i];
    if (ch = '%') and (i + 2 <= Length(S)) and
       HexNibble(S[i + 1], h1) and HexNibble(S[i + 2], h2) then
    begin
      Inc(n); r[n] := Chr(h1 * 16 + h2);
      Inc(i, 3);
    end
    else if ch = '+' then
    begin
      Inc(n); r[n] := ' ';
      Inc(i);
    end
    else
    begin
      Inc(n); r[n] := ch;
      Inc(i);
    end;
  end;
  SetLength(r, n);
  Result := r;
end;

{ Escape the five markup-significant characters. '&' MUST be first so it does not
  re-escape the ampersands the others introduce. }
{ Append S's bytes into raw buffer R at K (bytes written so far). Indexed writes
  keep a byte >= 128 intact; `R := R + S` re-encodes it through the UTF-8 codepage. }
procedure RawAppend(var R: RawByteString; var K: Integer; const S: String);
var j: Integer;
begin
  for j := 1 to Length(S) do begin Inc(K); R[K] := S[j]; end;
end;

function DoHtmlEncode(const S: String): String;
var i, k: Integer; ch: Char; r: RawByteString;
begin
  SetLength(r, Length(S) * 6);   // worst case: every character becomes '&quot;'
  k := 0;
  for i := 1 to Length(S) do
  begin
    ch := S[i];
    case ch of
      '&': RawAppend(r, k, '&amp;');
      '<': RawAppend(r, k, '&lt;');
      '>': RawAppend(r, k, '&gt;');
      '"': RawAppend(r, k, '&quot;');
      '''': RawAppend(r, k, '&#39;');
    else
      begin Inc(k); r[k] := ch; end;
    end;
  end;
  SetLength(r, k);
  Result := r;
end;

{ Reverse the five named/numeric entities above; an unknown entity is left verbatim. }
function DoHtmlDecode(const S: String): String;
var i, semi, k: Integer; ent, low: String; r: RawByteString;
begin
  SetLength(r, Length(S));   // decoding never lengthens the text
  k := 0;
  i := 1;
  while i <= Length(S) do
  begin
    if S[i] = '&' then
    begin
      semi := PosEx(';', S, i + 1);
      if (semi > 0) and (semi - i <= 10) then
      begin
        ent := Copy(S, i, semi - i + 1);   // includes the '&' and the ';'
        low := LowerCase(ent);
        if low = '&amp;' then begin Inc(k); r[k] := '&'; end
        else if low = '&lt;' then begin Inc(k); r[k] := '<'; end
        else if low = '&gt;' then begin Inc(k); r[k] := '>'; end
        else if low = '&quot;' then begin Inc(k); r[k] := '"'; end
        else if (low = '&apos;') or (low = '&#39;') or (low = '&#039;') then begin Inc(k); r[k] := ''''; end
        else RawAppend(r, k, ent);         // unknown entity: leave it as it was
        i := semi + 1;
        Continue;
      end;
    end;
    Inc(k); r[k] := S[i];
    Inc(i);
  end;
  SetLength(r, k);
  Result := r;
end;

{ ---- client lifecycle ------------------------------------------------------ }
function f_http_client(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValHandle(RegisterHandle(TPhosphorHttpClient.Create('')));
  gHttpErr := HTTP_OK;
end;

function f_http_client_url(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValHandle(RegisterHandle(TPhosphorHttpClient.Create(Args[0].Str)));
  gHttpErr := HTTP_OK;
end;

function f_http_free(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin FreeHandle(Args[0].Hnd); Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_reset(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin c.ResetToFactory(); Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

{ ---- base url -------------------------------------------------------------- }
function f_http_baseurl_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin Result := ValStr(c.BaseUrl); gHttpErr := HTTP_OK; end
  else begin Result := ValStr(''); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_baseurl_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin c.BaseUrl := Args[1].Str; Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

{ ---- timeouts (ms) --------------------------------------------------------- }
function f_http_timeout_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin Result := ValInt(c.ConnectTimeout); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_timeout_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin c.ConnectTimeout := Round(AsDouble(Args[1])); Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_responsetimeout_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin c.ResponseTimeout := Round(AsDouble(Args[1])); Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

{ ---- headers --------------------------------------------------------------- }
function f_http_headercount(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin Result := ValInt(c.Headers.Count); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_header_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin c.Headers.SetVal(Args[1].Str, Args[2].Str); Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_header_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin Result := ValStr(c.Headers.GetVal(Args[1].Str)); gHttpErr := HTTP_OK; end
  else begin Result := ValStr(''); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_headerremove(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin Result := ValInt(Ord(c.Headers.RemoveName(Args[1].Str))); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_headerclear(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin c.Headers.Clear(); Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

{ ---- query parameters ------------------------------------------------------ }
function f_http_paramcount(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin Result := ValInt(c.Params.Count); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_param_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin c.Params.SetVal(Args[1].Str, Args[2].Str); Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_param_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin Result := ValStr(c.Params.GetVal(Args[1].Str)); gHttpErr := HTTP_OK; end
  else begin Result := ValStr(''); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_paramremove(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin Result := ValInt(Ord(c.Params.RemoveName(Args[1].Str))); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_paramclear(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin c.Params.Clear(); Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

{ ---- cookies --------------------------------------------------------------- }
function f_http_cookiecount(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin Result := ValInt(c.Cookies.Count); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_cookie_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin c.Cookies.SetVal(Args[1].Str, Args[2].Str); Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_cookie_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin Result := ValStr(c.Cookies.GetVal(Args[1].Str)); gHttpErr := HTTP_OK; end
  else begin Result := ValStr(''); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_cookieremove(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin Result := ValInt(Ord(c.Cookies.RemoveName(Args[1].Str))); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_cookieclear(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin c.Cookies.Clear(); Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

{ ---- authentication (write-only: no credential is readable back) ----------- }
function f_http_basicauth(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin
    c.AuthHeader := 'Basic ' + EncodeStringBase64(Args[1].Str + ':' + Args[2].Str);
    Result := ValInt(1); gHttpErr := HTTP_OK;
  end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_bearerauth(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin c.AuthHeader := 'Bearer ' + Args[1].Str; Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_customauth(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin c.AuthHeader := Args[1].Str; Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_clearauth(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin c.AuthHeader := ''; Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

{ ---- proxy ----------------------------------------------------------------- }
function f_http_proxy(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin
    c.ProxyHost := Args[1].Str; c.ProxyPort := Round(AsDouble(Args[2]));
    Result := ValInt(1); gHttpErr := HTTP_OK;
  end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_proxyauth(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin
    c.ProxyUser := Args[1].Str; c.ProxyPass := Args[2].Str;
    Result := ValInt(1); gHttpErr := HTTP_OK;
  end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_clearproxy(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin
    c.ProxyHost := ''; c.ProxyPort := 0; c.ProxyUser := ''; c.ProxyPass := '';
    Result := ValInt(1); gHttpErr := HTTP_OK;
  end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

{ ---- behaviour flags (setters + getters) ----------------------------------- }
function f_http_useragent_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin c.UserAgent := Args[1].Str; Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_useragent_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin Result := ValStr(c.UserAgent); gHttpErr := HTTP_OK; end
  else begin Result := ValStr(''); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_contenttype_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin c.ContentType := Args[1].Str; Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_contenttype_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin Result := ValStr(c.ContentType); gHttpErr := HTTP_OK; end
  else begin Result := ValStr(''); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_accept_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin c.Accept := Args[1].Str; Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_accept_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin Result := ValStr(c.Accept); gHttpErr := HTTP_OK; end
  else begin Result := ValStr(''); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_followredirects_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin c.FollowRedirects := AsDouble(Args[1]) <> 0; Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_followredirects_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin Result := ValInt(Ord(c.FollowRedirects)); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_maxredirects_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin c.MaxRedirects := Round(AsDouble(Args[1])); Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_maxredirects_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin Result := ValInt(c.MaxRedirects); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_validatessl_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin c.ValidateSSL := AsDouble(Args[1]) <> 0; Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_validatessl_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin Result := ValInt(Ord(c.ValidateSSL)); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

{ ---- forms ----------------------------------------------------------------- }
function f_http_form(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValHandle(RegisterHandle(TPhosphorHttpForm.Create()));
  gHttpErr := HTTP_OK;
end;

function f_http_formfieldcount(const Args: array of TValue; out Err: TPhosphorError): TValue;
var f: TPhosphorHttpForm;
begin
  Err := NoError();
  if GetForm(Args[0].Hnd, f) then
  begin Result := ValInt(f.Fields.Count); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_formfilecount(const Args: array of TValue; out Err: TPhosphorError): TValue;
var f: TPhosphorHttpForm;
begin
  Err := NoError();
  if GetForm(Args[0].Hnd, f) then
  begin Result := ValInt(f.Files.Count); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_formfield(const Args: array of TValue; out Err: TPhosphorError): TValue;
var f: TPhosphorHttpForm;
begin
  Err := NoError();
  if GetForm(Args[0].Hnd, f) then
  begin f.Fields.SetVal(Args[1].Str, Args[2].Str); Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

{ Render the TEXT fields as name=value pairs joined by '&', each half url-encoded. A
  file field carries no url-encodable value, so it is deliberately skipped. }
function f_http_formurlencoded(const Args: array of TValue; out Err: TPhosphorError): TValue;
var f: TPhosphorHttpForm; s: String; i: Integer;
begin
  Err := NoError();
  if not GetForm(Args[0].Hnd, f) then
  begin Result := ValStr(''); gHttpErr := HTTP_EHANDLE; Exit; end;
  s := '';
  for i := 0 to f.Fields.Count - 1 do
  begin
    if i > 0 then s := s + '&';
    s := s + DoUrlEncode(f.Fields.NameAt(i)) + '=' + DoUrlEncode(f.Fields.ValueAt(i));
  end;
  Result := ValStr(s);
  gHttpErr := HTTP_OK;
end;

function f_http_formfile(const Args: array of TValue; out Err: TPhosphorError): TValue;
var f: TPhosphorHttpForm;
begin
  Err := NoError();
  if GetForm(Args[0].Hnd, f) then
  begin
    { The name it is sent under defaults to the disk file's own name. }
    f.AddFile(Args[1].Str, Args[2].Str, ExtractFileName(Args[2].Str), '');
    Result := ValInt(1); gHttpErr := HTTP_OK;
  end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_formfilenamed(const Args: array of TValue; out Err: TPhosphorError): TValue;
var f: TPhosphorHttpForm;
begin
  Err := NoError();
  if GetForm(Args[0].Hnd, f) then
  begin f.AddFile(Args[1].Str, Args[2].Str, Args[3].Str, ''); Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_formfiletype(const Args: array of TValue; out Err: TPhosphorError): TValue;
var f: TPhosphorHttpForm;
begin
  Err := NoError();
  if GetForm(Args[0].Hnd, f) then
  begin f.AddFile(Args[1].Str, Args[2].Str, Args[3].Str, Args[4].Str); Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_formclear(const Args: array of TValue; out Err: TPhosphorError): TValue;
var f: TPhosphorHttpForm;
begin
  Err := NoError();
  if GetForm(Args[0].Hnd, f) then
  begin f.ClearAll(); Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_formfree(const Args: array of TValue; out Err: TPhosphorError): TValue;
var f: TPhosphorHttpForm;
begin
  Err := NoError();
  if GetForm(Args[0].Hnd, f) then
  begin FreeHandle(Args[0].Hnd); Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

{ ---- pure encoders (BASIC entry points) ------------------------------------ }
function f_http_urlencode(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValStr(DoUrlEncode(Args[0].Str)); end;

function f_http_urldecode(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValStr(DoUrlDecode(Args[0].Str)); end;

function f_http_htmlencode(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValStr(DoHtmlEncode(Args[0].Str)); end;

function f_http_htmldecode(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValStr(DoHtmlDecode(Args[0].Str)); end;

{ ---- error accessors ------------------------------------------------------- }
function f_http_error(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); Result := ValInt(gHttpErr); end;

function f_http_clearerror(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin Err := NoError(); gHttpErr := HTTP_OK; Result := ValInt(0); end;

function f_http_strerror(const Args: array of TValue; out Err: TPhosphorError): TValue;
var code: Integer;
begin
  Err := NoError();
  code := Round(AsDouble(Args[0]));
  case code of
    HTTP_OK:      Result := ValStr('no error');
    HTTP_EHANDLE: Result := ValStr('invalid handle');
  else
    Result := ValStr('unknown error');
  end;
end;

procedure RegisterHttpFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('http_get$:$',       @f_http_get);
  Reg.Add('http_status:$',     @f_http_status);
  Reg.Add('http_post$:$$',     @f_http_post);
  Reg.Add('http_verify_peer:n', @f_http_verify_peer);
  Reg.Add('http_ca_file$:$',   @f_http_ca_file);

  { --- the offline configuration surface --- }
  // client handle (a config accumulator)
  Reg.Add('http_client@:',        @f_http_client);
  Reg.Add('http_client@:$',       @f_http_client_url);
  Reg.Add('http_free:@',          @f_http_free);
  Reg.Add('http_reset:@',         @f_http_reset);
  // base url
  Reg.Add('http_baseurl$:@',      @f_http_baseurl_get);
  Reg.Add('http_baseurl:@$',      @f_http_baseurl_set);
  // timeouts (getter + setter share the name, split by arity)
  Reg.Add('http_timeout:@',       @f_http_timeout_get);
  Reg.Add('http_timeout:@n',      @f_http_timeout_set);
  Reg.Add('http_responsetimeout:@n', @f_http_responsetimeout_set);
  // headers
  Reg.Add('http_headercount:@',   @f_http_headercount);
  Reg.Add('http_header:@$$',      @f_http_header_set);
  Reg.Add('http_header$:@$',      @f_http_header_get);
  Reg.Add('http_headerremove:@$', @f_http_headerremove);
  Reg.Add('http_headerclear:@',   @f_http_headerclear);
  // query parameters
  Reg.Add('http_paramcount:@',    @f_http_paramcount);
  Reg.Add('http_param:@$$',       @f_http_param_set);
  Reg.Add('http_param$:@$',       @f_http_param_get);
  Reg.Add('http_paramremove:@$',  @f_http_paramremove);
  Reg.Add('http_paramclear:@',    @f_http_paramclear);
  // cookies
  Reg.Add('http_cookiecount:@',   @f_http_cookiecount);
  Reg.Add('http_cookie:@$$',      @f_http_cookie_set);
  Reg.Add('http_cookie$:@$',      @f_http_cookie_get);
  Reg.Add('http_cookieremove:@$', @f_http_cookieremove);
  Reg.Add('http_cookieclear:@',   @f_http_cookieclear);
  // authentication
  Reg.Add('http_basicauth:@$$',   @f_http_basicauth);
  Reg.Add('http_bearerauth:@$',   @f_http_bearerauth);
  Reg.Add('http_customauth:@$',   @f_http_customauth);
  Reg.Add('http_clearauth:@',     @f_http_clearauth);
  // proxy
  Reg.Add('http_proxy:@$n',       @f_http_proxy);
  Reg.Add('http_proxyauth:@$$',   @f_http_proxyauth);
  Reg.Add('http_clearproxy:@',    @f_http_clearproxy);
  // behaviour flags (setters + getters)
  Reg.Add('http_useragent:@$',    @f_http_useragent_set);
  Reg.Add('http_useragent$:@',    @f_http_useragent_get);
  Reg.Add('http_contenttype:@$',  @f_http_contenttype_set);
  Reg.Add('http_contenttype$:@',  @f_http_contenttype_get);
  Reg.Add('http_accept:@$',       @f_http_accept_set);
  Reg.Add('http_accept$:@',       @f_http_accept_get);
  Reg.Add('http_followredirects:@n', @f_http_followredirects_set);
  Reg.Add('http_followredirects:@',  @f_http_followredirects_get);
  Reg.Add('http_maxredirects:@n', @f_http_maxredirects_set);
  Reg.Add('http_maxredirects:@',  @f_http_maxredirects_get);
  Reg.Add('http_validatessl:@n',  @f_http_validatessl_set);
  Reg.Add('http_validatessl:@',   @f_http_validatessl_get);
  // forms
  Reg.Add('http_form@:',          @f_http_form);
  Reg.Add('http_formfieldcount:@',@f_http_formfieldcount);
  Reg.Add('http_formfilecount:@', @f_http_formfilecount);
  Reg.Add('http_formfield:@$$',   @f_http_formfield);
  Reg.Add('http_formurlencoded$:@', @f_http_formurlencoded);
  Reg.Add('http_formfile:@$$',    @f_http_formfile);
  Reg.Add('http_formfilenamed:@$$$', @f_http_formfilenamed);
  Reg.Add('http_formfiletype:@$$$$', @f_http_formfiletype);
  Reg.Add('http_formclear:@',     @f_http_formclear);
  Reg.Add('http_formfree:@',      @f_http_formfree);
  // pure encoders
  Reg.Add('http_urlencode$:$',    @f_http_urlencode);
  Reg.Add('http_urldecode$:$',    @f_http_urldecode);
  Reg.Add('http_htmlencode$:$',   @f_http_htmlencode);
  Reg.Add('http_htmldecode$:$',   @f_http_htmldecode);
  // error accessors
  Reg.Add('http_error:',          @f_http_error);
  Reg.Add('http_clearerror:',     @f_http_clearerror);
  Reg.Add('http_strerror$:n',     @f_http_strerror);
end;

{ The first CA bundle found in the usual places, or '' if none. On a box with no
  system bundle (e.g. Windows), verification stays on but has nothing to trust, so
  https fails closed until http_ca_file$() supplies one or http_verify_peer(0) opts
  out -- deliberately secure-by-default rather than silently trusting everything. }
function LocateCABundle: String;
const
  CANDIDATES: array[1..5] of String = (
    '/etc/ssl/certs/ca-certificates.crt',   // Debian, Ubuntu
    '/etc/pki/tls/certs/ca-bundle.crt',     // RHEL, Fedora, CentOS
    '/etc/ssl/ca-bundle.pem',               // openSUSE
    '/etc/ssl/cert.pem',                    // Alpine, some BSD
    '/usr/local/share/certs/ca-root-nss.crt'); // FreeBSD
var
  i: Integer;
begin
  Result := '';
  for i := Low(CANDIDATES) to High(CANDIDATES) do
    if FileExists(CANDIDATES[i]) then
      Exit(CANDIDATES[i]);
end;

initialization
  {$IFDEF UNIX}
  { FPC 3.2.2's OpenSSL loader predates OpenSSL 3 -- its Unix soname list (openssl.pp
    DLLVersions) tries libssl.so, .1.1, .1.0.x, .0.9.x, but never .so.3. On a box that
    ships ONLY OpenSSL 3 (e.g. current Debian/Ubuntu -- no 1.1), https then fails to
    load the library at all. OpenSSL 3 kept the 1.1 API this client uses, so teach the
    loader the '.3' soname by claiming the oldest, effectively-dead slot. The list is
    tried in order, so real 1.1 boxes still match '.1.1' first; only a 3-only box falls
    through to '.3'. Windows loads by DLL name, not this list, so this is Unix-only. }
  openssl.DLLVersions[High(openssl.DLLVersions)] := '.3';
  {$ENDIF}
  gCAFile := LocateCABundle();

end.
