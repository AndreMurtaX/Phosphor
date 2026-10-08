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
    http_get$(c@, path$) / http_status(c@, path$) / http_post$(c@, path$, body$)
                             the same three on a CLIENT HANDLE: its base url, params,
                             headers, cookies, auth, timeouts, redirects and proxy are
                             all applied (see "THE CLIENT VERBS" below)
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
  with http_verify_peer(0), which turns off the NAME check below as well.

  HOSTNAME VERIFICATION (ledger m5). A valid chain is not enough: a certificate a
  trusted CA issued for ANOTHER host chains just as well. After the handshake the
  peer certificate must name the host that was dialled -- X509_check_host for a
  name, X509_check_ip_asc for a dotted quad -- or the connection is refused and
  http_error() says why (HTTP_EHOST). FPC 3.2.2 does none of this, and the obvious
  way to add it is broken in a way only the second machine shows: its
  SSL.PeerCertificate binds SSL_get_peer_certificate, which OpenSSL 3 does not
  export (a header macro there), so it answers nil after a perfectly good
  handshake on Ubuntu 24.04 while answering a certificate on a Windows box that
  loaded 1.1. Measured 2026-10-07 on both. So the four symbols are bound HERE, by
  name, from the libraries FPC already loaded -- SSL_get1_peer_certificate first,
  SSL_get_peer_certificate for 1.1 -- and a missing one REFUSES the connection:
  a check that cannot run must not read as a check that passed.

  MULTI-ADDRESS FALLBACK. FPC 3.2.2's socket layer (TInetSocket) resolves a host to
  the FIRST of its A records and connects only to that one -- if that single IP is
  down or blocked, the request fails even when the host's other IPs are healthy (as a
  round-robin CDN's routinely are). We do better: resolve ALL of a host's A records
  and try each until one connects. To dial a specific IP while still sending the
  hostname in Host: (so virtual-hosted servers route correctly), a small TFPHTTPClient
  subclass pins the connect target -- SendRequest still builds Host: from the URL.
  IPV6 (ledger m6). FPC 3.2.2's socket layer is IPv4 only -- TInetSocket opens an
  AF_INET socket and resolves A records -- and TFPHTTPClient keeps that socket in a
  PRIVATE field it creates itself, with no seam to hand it another. What it does
  give is a socket handler that is told of its socket (SetSocket, virtual) before
  the client calls the socket's Connect (virtual too), and a stream that does ALL
  its reading and writing through that handler. So an IPv6 request's handler
  re-classes the TInetSocket to TInet6Socket -- a subclass with no fields of its
  own, checked by InstanceSize, so the object is unchanged and only the VMT moves --
  whose Connect dials AF_INET6, and the handler does the I/O, plain or TLS, on that
  descriptor. The socket's Host stays the URL's, so SNI and the hostname check read
  the right name. Candidates: an IPv6 literal URL ([::1]) is dialled as itself; a
  name is tried over IPv4 first, exactly as before, and its AAAA records only when
  no IPv4 address connected -- never through a proxy. AAAA comes from netdb on Unix
  and from getaddrinfo in ws2_32 on Windows, where FPC has no IPv6 resolver.
******************************************************************************}
unit PhosphorHttpLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, Types, StrUtils, base64, fphttpclient, opensslsockets, openssl,
  ssockets, sslsockets, sslbase, resolve, sockets, URIParser,
  dynlibs, ctypes, fpopenssl,   // m5: the TLS names bound by hand, and TSSL
  PhosphorSandbox, PhosphorIoLib,   // m7: a client certificate's paths ask the gate
  PhosphorValue, PhosphorErrors, PhosphorRegistry, PhosphorHandles, PhosphorBudget;

procedure RegisterHttpFuncs(Reg: TPhosphorRegistry);

{ The core fetch, with the multi-address fallback described in the unit header.
  Exposed so the test harness can drive the fallback deterministically by forcing the
  candidate address list (real callers leave AForceAddrs empty and let the host name
  resolve). Returns the body; AStatus receives the HTTP code (0 if nothing connected). }
function HttpFetch(const AMethod, AUrl, ABody: String;
  const AForceAddrs: array of String; out AStatus: Integer;
  AConnectMs: Integer = 5000): String;

type
  THttpResolveHook = function(const AHost: String): TStringDynArray;

var
  { A TEST SEAM, nil in every shipped host, exposed for the same reason HttpFetch
    is: so the harness can drive address resolution deterministically with no
    DNS. When set, it answers a host's A records in place of the resolver. The
    proxy test needs it -- a destination that resolves somewhere the proxy is NOT
    is the only way to see a connect that went around the proxy (ledger n26). }
  HttpResolveHook: THttpResolveHook = nil;

var
  { THE SAME SEAM FOR AAAA records (ledger m6), nil in every shipped host: when set
    it answers a host's IPv6 addresses in place of the resolver, so a test can name
    a host that has ONLY an IPv6 address on any machine. }
  HttpResolve6Hook: THttpResolveHook = nil;

{ A host's IPv6 addresses (no brackets), from HttpResolve6Hook when set and the
  platform's resolver otherwise. Exported so the runner can prove the REAL resolver
  answers on each OS, which the hook would otherwise hide. }
function HttpResolveAAAA(const AHost: String): TStringDynArray;

type
  THttpTlsWithhold = function(const AName: String): Boolean;

var
  { A SECOND TEST SEAM, nil in every shipped host. When set and it answers True
    for one of the four OpenSSL names the hostname check binds by hand, that name
    is treated as missing -- the one way to reach the FAIL-CLOSED branch on a
    machine whose OpenSSL has all four, which is every machine anyone runs (ledger
    m5). Consulted once, at the first binding, like the binding itself. }
  HttpTlsWithhold: THttpTlsWithhold = nil;
  { TEST SEAM: when above 0, a request runs as if the run's budget had this many
    milliseconds left, so a test host with no TimeoutMs can watch the deadline
    bound a peer that trickles (tests/packages/21_http_hosts.bas). }
  HttpDeadlineMs: Integer = 0;

{ Whether a host is written as an address, and which family -- what decides the
  certificate check and SNI. Exported for a sweep in the package tests. }
function HttpIsIPv4Literal(const AHost: String): Boolean;
function HttpIsIPv6Literal(const AHost: String): Boolean;
{ Whether a redirect from A to B may carry what identifies the caller. }
function HttpSameOrigin(const A, B: String): Boolean;

implementation

uses
  {$IFDEF UNIX}BaseUnix, netdb{$ENDIF}
  {$IFDEF WINDOWS}winsock2{$ENDIF};

var
  { HTTPS security posture (see the unit header). Verification is ON by default;
    gCAFile is the CA bundle chain verification checks against, auto-located at
    startup. A host/script relaxes verification with http_verify_peer(0) or points at
    a different bundle with http_ca_file$(). }
  gVerifyPeer: Boolean = True;
  gCAFile: String = '';

threadvar
  { THE RUN'S DEADLINE, as a GetTickCount64 instant; 0 when no budget is installed.
    Set around one attempt by FetchHop and read by every handler's Recv. }
  gDeadline: QWord;

type
  { Raised from a read once the run's time is gone. Not an ESocketError, so the
    request counts as ANSWERED -- the fallback never re-sends it -- and the VM's
    own TimeoutMs check, which runs when this library call returns, ends the run. }
  EHttpDeadline = class(Exception);

{ A per-read socket timeout bounds a peer that goes SILENT, and nothing else: one
  that trickles a byte a second answers every read in time and held a run with
  TimeoutMs 3000 for thirty seconds (2026-10-07). The whole response is bounded
  here, on every read, by the run's own deadline. }
procedure CheckDeadline;
begin
  if (gDeadline <> 0) and (GetTickCount64() >= gDeadline) then
    raise EHttpDeadline.Create('the run''s time ran out during the response');
end;

type
  { THE TLS HANDLER EVERY https REQUEST GETS: FPC's OpenSSL handler, plus the name
    check in DoVerifyCert -- which the RTL calls right after SSL_connect, before the
    socket is used, and which FPC leaves empty. HostRefused is how a refusal gets
    back out: the socket layer turns a False here into a plain connect failure. }
  { WHAT AN IPv6 REQUEST'S HANDLER DIALS, and the descriptor it then talks over.
    Owned by that handler; TInet6Socket.Connect fills Fd. }
  T6Link = class
  public
    Ip: String;            // the IPv6 address, without brackets
    Fd: TSocket;
    FdOpen: Boolean;
    Owner: TSocketHandler;
    constructor Create(const AIp: String; AOwner: TSocketHandler);
    procedure CloseFd;
    destructor Destroy; override;
  end;

  { The class an IPv6 request's TInetSocket becomes. NO FIELDS: the instance was
    allocated as a TInetSocket, and re-classing it is sound only because the two
    are the same size -- Reclass6 checks InstanceSize and refuses otherwise. }
  TInet6Socket = class(TInetSocket)
  public
    procedure Connect; override;
  end;

  { http:// over IPv6: FPC's plain handler, reading and writing the IPv6
    descriptor instead of the stream's own (unused, AF_INET) handle. }
  TPlain6Handler = class(TSocketHandler)
  public
    Link: T6Link;
    constructor Create6(const AIp: String);
    destructor Destroy; override;
    function Recv(const Buffer; Count: Integer): Integer; override;
    function Send(const Buffer; Count: Integer): Integer; override;
  protected
    procedure SetSocket(const AStream: TSocketStream); override;
  end;

  { http:// over IPv4: exactly FPC's plain handler, plus the run's deadline. }
  TPlain4Handler = class(TSocketHandler)
  public
    function Recv(const Buffer; Count: Integer): Integer; override;
  end;

  THostCheckedHandler = class(TOpenSSLSocketHandler)
  public
    HostRefused: Boolean;
    Client: TObject;     // the TPinnedClient this request belongs to
    Link: T6Link;        // m6: set for an IPv6 request, nil for IPv4
    destructor Destroy; override;
    function Connect: Boolean; override;
    function Recv(const Buffer; Count: Integer): Integer; override;
  protected
    function DoVerifyCert: Boolean; override;
    procedure SetSocket(const AStream: TSocketStream); override;
  end;

  { TFPHTTPClient derives BOTH the connect target and the Host: header from the request
    URI. Overriding ConnectToServer lets us dial one chosen IP while SendRequest keeps
    building Host: from the original URI -- the seam the fallback needs. GetSocketHandler
    is the second seam: it is where the TLS handler is born, so it is where we turn on
    certificate verification and hand it the CA bundle. }
  TPinnedClient = class(TFPHTTPClient)
  public
    ConnectIP: String;
    ConnectIP6: String;    // m6: dial this IPv6 address (no brackets) instead
    PinHost: String;       // the host the pin is for; a redirect elsewhere is not pinned
    VerifyPeer: Boolean;   // per request: the global switch, AND a client's own
    HostRefused: Boolean;  // a TLS handler of this request refused the peer's name
    ClientCert: String;    // m7: PEM certificate to present, '' for none
    ClientKey: String;     //     and its private key (may be the same file)
  protected
    procedure ConnectToServer(const AHost: String; APort: Integer;
      UseSSL: Boolean = False); override;
    function GetSocketHandler(const UseSSL: Boolean): TSocketHandler; override;
  end;

{ A PIN IS FOR ONE HOST. A redirect to another host comes back through here with
  that host's name, and dialling the first host's address for it would reach the
  wrong server -- so the pin applies only while AHost is the host it was made for
  (PinHost), for an IPv4 pin and an IPv6 one alike. An IPv6 request passes the name
  through untouched: the handler dials the address, and the socket's Host stays the
  name for SNI and the hostname check. }
procedure TPinnedClient.ConnectToServer(const AHost: String; APort: Integer;
  UseSSL: Boolean);
var pinned: Boolean;
begin
  pinned := (PinHost = '') or SameText(AHost, PinHost);
  if not pinned then
  begin
    ConnectIP := '';
    ConnectIP6 := '';
  end;
  if ConnectIP <> '' then
    inherited ConnectToServer(ConnectIP, APort, UseSSL)
  else
    inherited ConnectToServer(AHost, APort, UseSSL);
end;

{ ---- IPv6 (ledger m6) ------------------------------------------------------ }

function ParseIPv6(const AHost: String; out A: TIn6_Addr): Boolean; forward;
function IsUnspecifiedAddr(const AHost: String): Boolean; forward;

threadvar
  { The link a re-classed socket's Connect is to use: set by the handler in
    SetSocket, taken (and cleared) by TInet6Socket.Connect, which TFPHTTPClient
    calls next, on the same thread, before anything else can intervene. }
  gPending6: T6Link;

constructor T6Link.Create(const AIp: String; AOwner: TSocketHandler);
begin
  inherited Create();
  Ip := AIp;
  Owner := AOwner;
  FdOpen := False;
end;

procedure T6Link.CloseFd;
begin
  if FdOpen then CloseSocket(Fd);
  FdOpen := False;
end;

destructor T6Link.Destroy;
begin
  CloseFd();
  inherited Destroy();
end;

{ Make AStream a TInet6Socket and leave ALink for its Connect. Refuses -- rather
  than re-class an object of another shape -- unless AStream is exactly a
  TInetSocket and the subclass is exactly its size. }
procedure Reclass6(AStream: TSocketStream; ALink: T6Link);
begin
  if (AStream.ClassType <> TInetSocket) or
     (TInet6Socket.InstanceSize <> TInetSocket.InstanceSize) then
    raise ESocketError.Create(seConnectFailed, ['[' + ALink.Ip + ']']);
  PPointer(AStream)^ := Pointer(TInet6Socket);
  gPending6 := ALink;
end;

{ TInetSocket.Connect, for AF_INET6: the same connect-timeout dance (the protected
  helpers are TInetSocket's own), the same IO timeout the stream would have set on
  its own handle, then the handler's Connect -- a no-op for http, the handshake for
  https -- and the same ESocketError on failure, so FetchCore's fallback reads an
  IPv6 failure exactly as it reads an IPv4 one. }
procedure TInet6Socket.Connect;
const
  {$IFDEF UNIX}ErrWouldBlock = ESysEInprogress;{$ENDIF}
  {$IFDEF WINDOWS}ErrWouldBlock = WSAEWOULDBLOCK;{$ENDIF}
var
  link: T6Link;
  a: TInetSockAddr6;
  isError: Boolean;
  err: Integer;
  tor: TCheckTimeoutResult;
  fds: TFDSet;
  timev: TTimeVal;
  {$IFDEF WINDOWS}opt: DWord;{$ENDIF}
  {$IFDEF UNIX}tv: TTimeVal;{$ENDIF}
begin
  link := gPending6;
  gPending6 := nil;
  if link = nil then raise ESocketError.Create(seConnectFailed, [Host]);
  FillChar(a, SizeOf(a), 0);
  { The last place an unreadable address could become `::` -- see ParseIPv6.
    FetchHop already refuses one; this is the dial itself refusing too. }
  if (not ParseIPv6(link.Ip, a.sin6_addr)) or IsUnspecifiedAddr(link.Ip) then
    raise ESocketError.Create(seConnectFailed, ['[' + link.Ip + ']']);
  link.Fd := fpSocket(AF_INET6, SOCK_STREAM, 0);
  {$IFDEF WINDOWS}if link.Fd = INVALID_SOCKET then{$ELSE}if link.Fd < 0 then{$ENDIF}
    raise ESocketError.Create(seConnectFailed, ['[' + link.Ip + ']']);
  link.FdOpen := True;
  a.sin6_family := AF_INET6;
  a.sin6_port := htons(Port);
  if ConnectTimeout > 0 then SetSocketBlockingMode(link.Fd, bmNonBlocking, @fds);
  isError := True;
  tor := ctrError;
  err := 0;
  {$IFDEF UNIX}
  err := ESysEINTR;
  while isError and ((err = ESysEINTR) or (err = ESysEAGAIN)) do
  {$ENDIF}
  begin
    isError := fpConnect(link.Fd, @a, SizeOf(a)) <> 0;
    if isError then err := SocketError;
  end;
  if ConnectTimeout > 0 then
  begin
    if isError and (err = ErrWouldBlock) then
    begin
      tor := CheckSocketConnectTimeout(link.Fd, @fds, @timev);
      isError := tor <> ctrOK;
    end;
    SetSocketBlockingMode(link.Fd, bmBlocking, @fds);
  end;
  if (not isError) and (IOTimeout > 0) then
  begin
    {$IFDEF WINDOWS}
    opt := IOTimeout;
    fpsetsockopt(link.Fd, SOL_SOCKET, SO_RCVTIMEO, @opt, 4);
    fpsetsockopt(link.Fd, SOL_SOCKET, SO_SNDTIMEO, @opt, 4);
    {$ENDIF}
    {$IFDEF UNIX}
    tv.tv_sec := IOTimeout div 1000;
    tv.tv_usec := (IOTimeout mod 1000) * 1000;
    fpsetsockopt(link.Fd, SOL_SOCKET, SO_RCVTIMEO, @tv, SizeOf(tv));
    fpsetsockopt(link.Fd, SOL_SOCKET, SO_SNDTIMEO, @tv, SizeOf(tv));
    {$ENDIF}
  end;
  if not isError then isError := not link.Owner.Connect();
  if isError then
  begin
    link.CloseFd();
    if tor = ctrTimeout then
      raise ESocketError.Create(seConnectTimeOut, [Format('[%s]:%d', [link.Ip, Port])])
    else
      raise ESocketError.Create(seConnectFailed, [Format('[%s]:%d', [link.Ip, Port])]);
  end;
end;

constructor TPlain6Handler.Create6(const AIp: String);
begin
  inherited Create();
  Link := T6Link.Create(AIp, Self);
end;

destructor TPlain6Handler.Destroy;
begin
  Link.Free;
  inherited Destroy();
end;

procedure TPlain6Handler.SetSocket(const AStream: TSocketStream);
begin
  inherited SetSocket(AStream);
  Reclass6(AStream, Link);
end;

function TPlain4Handler.Recv(const Buffer; Count: Integer): Integer;
begin
  CheckDeadline();
  Result := inherited Recv(Buffer, Count);
end;

{ TSocketHandler.Recv and Send, on the IPv6 descriptor. }
function TPlain6Handler.Recv(const Buffer; Count: Integer): Integer;
begin
  CheckDeadline();
  Result := -1;
  {$IFDEF UNIX}
  FLastError := ESysEINTR;
  while FLastError = ESysEINTR do
  {$ENDIF}
  begin
    Result := fpRecv(Link.Fd, @Buffer, Count, Socket.ReadFlags);
    if Result < 0 then FLastError := SocketError else FLastError := 0;
  end;
end;

function TPlain6Handler.Send(const Buffer; Count: Integer): Integer;
begin
  Result := -1;
  {$IFDEF UNIX}
  FLastError := ESysEINTR;
  while FLastError = ESysEINTR do
  {$ENDIF}
  begin
    Result := fpSend(Link.Fd, @Buffer, Count, Socket.WriteFlags);
    if Result < 0 then FLastError := SocketError else FLastError := 0;
  end;
end;

type
  TGetPeerCert = function(ssl: PSSL): PX509; cdecl;
  TCheckHost = function(x: PX509; chk: PAnsiChar; chklen: csize_t; flags: cuint;
                        peername: PPAnsiChar): cint; cdecl;
  TCheckIPAsc = function(x: PX509; address: PAnsiChar; flags: cuint): cint; cdecl;
  TX509Free = procedure(x: PX509); cdecl;

var
  gTlsBound: Boolean = False;
  gGetPeerCert: TGetPeerCert = nil;
  gCheckHost: TCheckHost = nil;
  gCheckIPAsc: TCheckIPAsc = nil;
  gX509Free: TX509Free = nil;

{ Bind the four names once, from the libraries FPC loaded for the handshake that is
  calling us. See the unit header for why FPC's own binding cannot be used. }
function TlsSym(AHandle: TLibHandle; const AName: String): Pointer;
begin
  if Assigned(HttpTlsWithhold) and HttpTlsWithhold(AName) then Exit(nil);
  Result := GetProcedureAddress(AHandle, AName);
end;

procedure BindTlsNames;
begin
  if gTlsBound then Exit;
  gTlsBound := True;
  gGetPeerCert := TGetPeerCert(TlsSym(SSLLibHandle, 'SSL_get1_peer_certificate'));
  if not Assigned(gGetPeerCert) then
    gGetPeerCert := TGetPeerCert(TlsSym(SSLLibHandle, 'SSL_get_peer_certificate'));
  gCheckHost := TCheckHost(TlsSym(SSLUtilHandle, 'X509_check_host'));
  gCheckIPAsc := TCheckIPAsc(TlsSym(SSLUtilHandle, 'X509_check_ip_asc'));
  gX509Free := TX509Free(TlsSym(SSLUtilHandle, 'X509_free'));
end;

{ Does the peer certificate of ASsl name AHost? A dotted quad is matched against the
  certificate's IP addresses, anything else against its DNS names (wildcards as
  OpenSSL allows them). False for an empty host, a missing certificate, an OpenSSL
  error (a negative answer), and a missing symbol -- every doubt refuses. }
function IsIPv4Literal(const AHost: String): Boolean; forward;

{ An IPv6 literal, bracketed as a URL writes it or bare. }
function Unbracket(const AHost: String): String;
begin
  Result := AHost;
  if (Length(Result) >= 2) and (Result[1] = '[') and (Result[Length(Result)] = ']') then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

{ IS THIS TEXT AN ADDRESS? Asked of the RTL's Try* parsers, which say whether they
  could READ it. The plain StrToHostAddr6 answers all zeros for text it cannot
  read, and all zeros is `::` -- so `[zzzz]`, `[1::2::3]` and `[evil.example]`
  were each dialled as `::`, five seconds apiece on Windows and, on Linux, which
  connects `::` to `::1`, a URL naming no host at all reached this machine's own
  services (2026-10-07). An address must PARSE; then it is an address. }
function ParseIPv6(const AHost: String; out A: TIn6_Addr): Boolean;
var h: String;
begin
  h := Unbracket(AHost);
  Result := (Pos(':', h) > 0) and TryStrToHostAddr6(h, A);
end;

function IsIPv6Literal(const AHost: String): Boolean;
var a: TIn6_Addr;
begin
  Result := ParseIPv6(AHost, a);
end;

{ What an IPv6 literal is dialled as: the dotted IPv4 address it maps, for
  ::ffff:a.b.c.d, and otherwise itself, bracketed -- FetchHop's candidate form. }
function MappedIPv4(const AHost: String): String;
var a: TIn6_Addr;
    i: Integer;
    mapped: Boolean;
begin
  Result := '[' + Unbracket(AHost) + ']';
  if not ParseIPv6(AHost, a) then Exit;
  mapped := (a.u6_addr8[10] = $FF) and (a.u6_addr8[11] = $FF);
  for i := 0 to 9 do
    if a.u6_addr8[i] <> 0 then mapped := False;
  if mapped then
    Result := Format('%d.%d.%d.%d', [a.u6_addr8[12], a.u6_addr8[13], a.u6_addr8[14], a.u6_addr8[15]]);
end;

{ The certificate check and SNI are about the NAME, which has no trailing dot:
  `localhost.` is the fully-qualified spelling of `localhost`, RFC 6066 section 3
  sends the HostName "without a trailing dot", and OpenSSL's X509_check_host does
  not strip one, so `https://localhost.` was refused as another host. }
function TlsName(const AHost: String): String;
begin
  Result := AHost;
  if (Result <> '') and (Result[Length(Result)] = '.') then
    SetLength(Result, Length(Result) - 1);
end;

function CertNamesHost(ASsl: PSSL; const AHost: String): Boolean;
var
  c: PX509;
  h: AnsiString;
begin
  Result := False;
  if (AHost = '') or (ASsl = nil) then Exit;
  BindTlsNames();
  if not (Assigned(gGetPeerCert) and Assigned(gX509Free) and Assigned(gCheckHost) and
          Assigned(gCheckIPAsc)) then Exit;
  c := gGetPeerCert(ASsl);
  if c = nil then Exit;
  try
    if IsIPv4Literal(AHost) or IsIPv6Literal(AHost) then
    begin
      h := AnsiString(Unbracket(AHost));
      Result := gCheckIPAsc(c, PAnsiChar(h), 0) = 1;
    end
    else
    begin
      h := AnsiString(TlsName(AHost));
      Result := (h <> '') and (gCheckHost(c, PAnsiChar(h), Length(h), 0, nil) = 1);
    end;
  finally
    gX509Free(c);   // both getters hand back a reference the caller owns
  end;
end;

{ THE NAME THAT IS CHECKED IS THE ONE THAT WAS DIALLED: the socket's own host. It is
  what SNI sent, and after a redirect it is the new host, not the first URL's. An
  https request never pins a resolved IP (FetchCore), so this is the URL's name; if
  that ever changed, an IP here would fail the name check rather than pass it. The
  opt-out is the chain's opt-out: with VerifyPeerCert off nothing is checked. }
function THostCheckedHandler.DoVerifyCert: Boolean;
var host: String;
begin
  Result := inherited DoVerifyCert();
  if (not Result) or (not VerifyPeerCert) then Exit;
  host := '';
  if Socket is TInetSocket then host := TInetSocket(Socket).Host;
  Result := CertNamesHost(SSL.SSL, host);
  if not Result then
  begin
    HostRefused := True;
    if Client is TPinnedClient then TPinnedClient(Client).HostRefused := True;
    SSLLastErrorString := 'the certificate is not for ' + host;
  end;
end;

destructor THostCheckedHandler.Destroy;
begin
  Link.Free;
  inherited Destroy();
end;

procedure THostCheckedHandler.SetSocket(const AStream: TSocketStream);
begin
  inherited SetSocket(AStream);
  if Link <> nil then Reclass6(AStream, Link);
end;

{ TOpenSSLSocketHandler.Connect, for both families: the same context, the
  descriptor (the IPv6 link's, or the stream's own), the SNI, the handshake and
  the same DoVerifyCert. FPC's own version is not called because of the SNI: it
  sends the socket's Host as it stands, so `https://127.0.0.1` sent an ADDRESS,
  which RFC 6066 section 3 forbids ("Literal IPv4 and IPv6 addresses are not
  permitted"), and `localhost.` sent its trailing dot. Its parent's Connect
  (TSocketHandler's) only answers True, so nothing else is skipped. }
function THostCheckedHandler.Connect: Boolean;
var sni: String;
    fd: TSocket;
begin
  Result := InitContext(False);
  if not Result then Exit;
  if Link <> nil then fd := Link.Fd else fd := Socket.Handle;
  Result := CheckSSL(SSL.SetFD(fd));
  if not Result then Exit;
  sni := '';
  if Socket is TInetSocket then sni := TInetSocket(Socket).Host;
  if IsIPv4Literal(sni) or IsIPv6Literal(sni) then sni := '' else sni := TlsName(sni);
  if SendHostAsSNI and (sni <> '') then
    SSL.Ctrl(SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, PAnsiChar(AnsiString(sni)));
  Result := CheckSSL(SSL.Connect);
  if Result then Result := DoVerifyCert();
  if Result then SetSSLActive(True);
end;

function THostCheckedHandler.Recv(const Buffer; Count: Integer): Integer;
begin
  CheckDeadline();
  Result := inherited Recv(Buffer, Count);
end;

function TPinnedClient.GetSocketHandler(const UseSSL: Boolean): TSocketHandler;
begin
  { An https request gets THIS handler and not the registered default, which is a
    plain TOpenSSLSocketHandler: the subclass is that plus the name check. }
  if UseSSL then
  begin
    Result := THostCheckedHandler.Create();
    if ConnectIP6 <> '' then
      THostCheckedHandler(Result).Link := T6Link.Create(ConnectIP6, Result);
  end
  else if ConnectIP6 <> '' then
    Result := TPlain6Handler.Create6(ConnectIP6)
  else
    Result := TPlain4Handler.Create();   // what FPC would make, plus the deadline
  if UseSSL and (Result is TSSLSocketHandler) then
  begin
    { VerifyPeerCert => SSL_VERIFY_PEER, and CertCA.FileName is LoadVerifyLocations'd
      into the context (see opensslsockets InitContext/InitSslKeys). Together that
      makes SSL_connect FAIL on an expired, self-signed, or untrusted-CA certificate,
      instead of FPC's default of accepting anything. }
    TSSLSocketHandler(Result).VerifyPeerCert := VerifyPeer;
    if VerifyPeer and (gCAFile <> '') then
      TSSLSocketHandler(Result).CertificateData.CertCA.FileName := gCAFile;
    { A CLIENT CERTIFICATE (ledger m7). FPC's OpenSSL handler already loads a
      Certificate and a PrivateKey into the context when they are set -- the code
      a server uses -- and a client presents them when the server asks. The
      paths are absolute: http_clientcert expanded them when the sandbox judged
      them, so OpenSSL opens exactly the path the gate passed. }
    if ClientCert <> '' then
    begin
      TSSLSocketHandler(Result).CertificateData.Certificate.FileName := ClientCert;
      TSSLSocketHandler(Result).CertificateData.PrivateKey.FileName := ClientKey;
    end;
    THostCheckedHandler(Result).Client := Self;
  end;
end;

{ A dotted quad is an address; anything else is a name. NOT the socket layer's own
  test, "first byte zero => needs lookup": StrToHostAddr answers in HOST order, so
  on a little-endian machine s_bytes[1] is the LAST octet, and every address
  ending in .0 -- 10.1.2.0 -- was taken for a name, its certificate checked
  against DNS names, and refused (2026-10-07). The socket layer survives the same
  mistake only because looking up "10.1.2.0" answers 10.1.2.0. }
function IsIPv4Literal(const AHost: String): Boolean;
var a: sockets.in_addr;
begin
  Result := TryStrToHostAddr(AHost, a);
end;

{ The UNSPECIFIED address, 0.0.0.0 or `::`, names no host. Linux connects either one
  to this machine itself, so dialling it would reach a local service under a URL
  that named none; it is refused before anything is dialled. }
function IsUnspecifiedAddr(const AHost: String): Boolean;
var a4: sockets.in_addr;
    a6: TIn6_Addr;
begin
  if TryStrToHostAddr(AHost, a4) then Exit(a4.s_addr = 0);
  Result := ParseIPv6(AHost, a6) and (a6.u6_addr32[0] = 0) and (a6.u6_addr32[1] = 0) and
            (a6.u6_addr32[2] = 0) and (a6.u6_addr32[3] = 0);
end;

{ All of a host's A records, dotted, in resolver order. THostResolver resolves the
  whole set even though the socket layer would use only the first. }
function ResolveAllA(const AHost: String): TStringDynArray;
var
  r: THostResolver;
  i: Integer;
begin
  if Assigned(HttpResolveHook) then Exit(HttpResolveHook(AHost));
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

{$IFDEF WINDOWS}
type
  PAddrInfoA = ^TAddrInfoA;
  TAddrInfoA = record         // ws2def.h ADDRINFOA
    ai_flags, ai_family, ai_socktype, ai_protocol: LongInt;
    ai_addrlen: PtrUInt;
    ai_canonname: PAnsiChar;
    ai_addr: Pointer;
    ai_next: PAddrInfoA;
  end;
  TGetAddrInfo = function(node, service: PAnsiChar; hints: PAddrInfoA;
                          out res: PAddrInfoA): LongInt; stdcall;
  TFreeAddrInfo = procedure(ai: PAddrInfoA); stdcall;

var
  gWs2: TLibHandle = NilHandle;
  gGetAddrInfo: TGetAddrInfo = nil;
  gFreeAddrInfo: TFreeAddrInfo = nil;
{$ENDIF}

function HttpResolveAAAA(const AHost: String): TStringDynArray;
var
  {$IFDEF UNIX}
  addrs: array[0..15] of THostAddr6;
  n, i: Integer;
  {$ENDIF}
  {$IFDEF WINDOWS}
  hints: TAddrInfoA;
  res, p: PAddrInfoA;
  h: AnsiString;
  {$ENDIF}
begin
  if Assigned(HttpResolve6Hook) then Exit(HttpResolve6Hook(AHost));
  Result := nil;
  if AHost = '' then Exit;
  {$IFDEF UNIX}
  n := ResolveName6(AHost, addrs);
  for i := 0 to n - 1 do
    if i <= High(addrs) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := HostAddrToStr6(addrs[i]);
    end;
  {$ENDIF}
  {$IFDEF WINDOWS}
  if gWs2 = NilHandle then
  begin
    gWs2 := LoadLibrary('ws2_32.dll');
    if gWs2 <> NilHandle then
    begin
      gGetAddrInfo := TGetAddrInfo(GetProcedureAddress(gWs2, 'getaddrinfo'));
      gFreeAddrInfo := TFreeAddrInfo(GetProcedureAddress(gWs2, 'freeaddrinfo'));
    end;
  end;
  if not (Assigned(gGetAddrInfo) and Assigned(gFreeAddrInfo)) then Exit;
  FillChar(hints, SizeOf(hints), 0);
  hints.ai_family := AF_INET6;
  hints.ai_socktype := SOCK_STREAM;
  h := AnsiString(AHost);
  res := nil;
  if gGetAddrInfo(PAnsiChar(h), nil, @hints, res) <> 0 then Exit;
  try
    p := res;
    while p <> nil do
    begin
      if (p^.ai_family = AF_INET6) and (p^.ai_addr <> nil) then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := HostAddrToStr6(PInetSockAddr6(p^.ai_addr)^.sin6_addr);
      end;
      p := p^.ai_next;
    end;
  finally
    gFreeAddrInfo(res);
  end;
  {$ENDIF}
end;

const
  HTTP_OK      = 0;
  HTTP_EHANDLE = 1;   // an invalid / fabricated client or form handle
  HTTP_EPROXY  = 2;   // a proxy this client cannot honour; nothing was sent
  HTTP_EHOST   = 3;   // https: the server's certificate is not for this host

var
  { What http_error() answers: the last configuration op's result, and since m5
    the last REQUEST's too -- 0 when it was not refused, HTTP_EHOST when its peer's
    certificate named another host. Declared above FetchCore because it writes it. }
  gHttpErr: Integer = 0;

{ Applies a client handle's configuration to one request. With ACreds False it
  leaves out everything that identifies the caller -- the Authorization header,
  the cookies and the client certificate; see SameOrigin. Declared here and
  written beside the client type it reads, further down. }
procedure ApplyClient(c: TPinnedClient; ACfg: TObject; ACreds: Boolean); forward;
function ClientProxyActive(ACfg: TObject): Boolean; forward;
function ClientProxyHost(ACfg: TObject): String; forward;
function ClientFollow(ACfg: TObject; out AMax: Integer): Boolean; forward;
function ProxyRefusedFor(ACfg: TObject; const AUrl: String): Boolean; forward;

{ The cookie each Set-Cookie header of a response sets, as `name=value`: the text
  before its first ';'. FPC's own list splits the header at EVERY ';', so its
  attributes -- `Path=/`, `HttpOnly` -- came back as cookies of their own. }
procedure ResponseCookies(c: TPinnedClient; AJar: TStrings);
var
  i, k, p: Integer;
  h, nv: String;
begin
  for i := 0 to c.ResponseHeaders.Count - 1 do
  begin
    h := c.ResponseHeaders[i];
    if CompareText(Copy(h, 1, 11), 'set-cookie:') <> 0 then Continue;
    nv := Copy(h, 12, MaxInt);
    p := Pos(';', nv);
    if p > 0 then nv := Copy(nv, 1, p - 1);
    nv := Trim(nv);
    p := Pos('=', nv);
    if p <= 1 then Continue;
    k := AJar.IndexOfName(Copy(nv, 1, p - 1));
    if k >= 0 then AJar[k] := nv else AJar.Add(nv);
  end;
end;

{ ONE REQUEST TO ONE URL: which addresses to try, in what order, and the first
  answer. A redirect is NOT followed here -- FetchCore follows it, a hop at a time,
  so every rule below applies to every URL a request reaches and not only to the
  first. ACreds says whether this URL may be sent what identifies the caller; AJar
  (nil when it may not) holds the cookies earlier hops of the same origin set, and
  receives this response's. ALocation is the response's Location header. }
{ AUrl with one trailing dot taken off its host: `https://localhost.:8443/x` asks for
  `localhost`. The dot only spells the name in full, and only some resolvers know
  it -- Windows' does; the netdb hosts-file lookup FPC uses on Linux does not, so
  there `localhost.` never connected (2026-10-07). Taking it off before dialling
  makes resolution, SNI and the name check see the same name on every OS. An
  IPv6 literal is left alone. }
function DotlessUrl(const AUrl: String): String;
var p, i, j, hostStart, hostEnd: Integer;
begin
  Result := AUrl;
  p := Pos('://', Result);
  if p = 0 then Exit;
  i := p + 3;
  j := i;
  while (j <= Length(Result)) and not (Result[j] in ['/', '?', '#']) do Inc(j);
  hostStart := i;
  for p := i to j - 1 do
    if Result[p] = '@' then hostStart := p + 1;
  if (hostStart >= j) or (Result[hostStart] = '[') then Exit;
  hostEnd := hostStart;
  while (hostEnd < j) and (Result[hostEnd] <> ':') do Inc(hostEnd);
  if (hostEnd - 1 > hostStart) and (Result[hostEnd - 1] = '.') then
    Delete(Result, hostEnd - 1, 1);
end;

function FetchHop(const AMethod, ARawUrl, ABody: String;
  const AForceAddrs: array of String; out AStatus: Integer;
  AConnectMs: Integer; ACfg: TObject; ACreds: Boolean;
  AJar: TStrings; out ALocation: String): String;
var
  addrs, addrs6: TStringDynArray;
  uri: TURI;
  AUrl: String;        // ARawUrl as it is requested: see DotlessUrl
  dial, body: String;
  i: Integer;
  connected, hostRefused, viaProxy: Boolean;

  { One attempt against a single connect target ('' = dial the host as written).
    AConnected separates a failure to CONNECT (try the next address -- nothing was
    sent) from an exchange that began, whatever came of it (stop and report it). }
  function Attempt(const AConnectIP: String; out AConnected: Boolean): String;
  var
    c: TPinnedClient;
    resp: TStringStream;
    remaining: Int64;
    k, p: Integer;
  begin
    Result := '';
    AConnected := False;
    AStatus := 0;
    resp := TStringStream.Create('');
    c := TPinnedClient.Create(nil);
    try
      { A bracketed candidate is an IPv6 address (m6). The pin is for the host
        DIALLED -- the URL's, or the proxy's -- and only for it; see
        TPinnedClient.ConnectToServer. }
      if (AConnectIP <> '') and (AConnectIP[1] = '[') then
        c.ConnectIP6 := Unbracket(AConnectIP)
      else
        c.ConnectIP := AConnectIP;
      c.PinHost := dial;
      c.ConnectTimeout := AConnectMs;         // ms; don't hang forever on a dead IP
      c.VerifyPeer := gVerifyPeer;
      if ACfg <> nil then ApplyClient(c, ACfg, ACreds);
      if AJar <> nil then
        for k := 0 to AJar.Count - 1 do
        begin
          p := c.Cookies.IndexOfName(AJar.Names[k]);
          if p >= 0 then c.Cookies[p] := AJar[k] else c.Cookies.Add(AJar[k]);
        end;
      c.AllowRedirect := False;               // FetchCore follows, hop by hop
      { A NETWORK WAIT IS A LIBRARY CALL TOO, and it is the one shape the budget
        can neither size, charge nor judge: how long a server takes is the
        server's business. What CAN be done is to hand the run's remaining time
        down: to the connect, to the socket's per-read timeout -- which bounds a
        peer that goes silent -- and, as a DEADLINE every read checks, to the
        whole response, which is what bounds a peer that trickles (CheckDeadline).
        With no budget installed BudgetRemainingMs answers 0 and nothing below
        runs, so an unbudgeted host keeps exactly the timeouts it had. }
      remaining := BudgetRemainingMs();
      if (HttpDeadlineMs > 0) and ((remaining <= 0) or (remaining > HttpDeadlineMs)) then
        remaining := HttpDeadlineMs;
      if remaining > 0 then
      begin
        if remaining > High(Integer) then remaining := High(Integer);
        if c.ConnectTimeout > Integer(remaining) then
          c.ConnectTimeout := Integer(remaining);
        // The run's remaining time can only SHORTEN a client's own response
        // timeout, never lengthen it.
        if (c.IOTimeout <= 0) or (c.IOTimeout > Integer(remaining)) then
          c.IOTimeout := Integer(remaining);
        gDeadline := GetTickCount64() + QWord(remaining);
      end;
      { THE CONNECT WAIT IS WHOLE SECONDS. The RTL's connect timeout is a select()
        with tv_sec = ms div 1000 and tv_usec = 0, so 500 ms became a zero-second
        wait that fails every connect slower than an instant -- and a budget with
        under a second left did the same. Rounded UP, so it is never shorter than
        asked; a budget can be overrun by under a second, and is still bounded. }
      if (c.ConnectTimeout > 0) and (c.ConnectTimeout mod 1000 <> 0) and
         (c.ConnectTimeout < High(Integer) - 1000) then
        c.ConnectTimeout := (c.ConnectTimeout div 1000 + 1) * 1000;
      if CompareText(AMethod, 'POST') = 0 then
        c.RequestBody := TStringStream.Create(ABody);
      try
        try
          { [] as allowed-codes => every status is accepted (no raise), so the body of
            an error response is read into the stream too. }
          c.HTTPMethod(UpperCase(AMethod), AUrl, resp, []);
          AConnected := True;
        except
          { Only a failure to CONNECT means nothing was sent. Until 2026-10-07 any
            ESocketError counted, and FPC's redirect loop raised one from the
            redirect TARGET's connect -- so a POST that had been answered, by a
            307 to a dead host, was sent again to the first host's next address. }
          on E: ESocketError do
            AConnected := not (E.Code in [seHostNotFound, seCreationFailed,
                                          seConnectFailed, seConnectTimeOut]);
          on E: Exception do AConnected := True;        // reached; keep its answer
        end;
        AStatus := c.ResponseStatusCode;
        if AConnected then
        begin
          Result := resp.DataString;
          ALocation := TFPHTTPClient.GetHeader(c.ResponseHeaders, 'Location');
          if AJar <> nil then ResponseCookies(c, AJar);
        end;
        if c.HostRefused then hostRefused := True;
      finally
        gDeadline := 0;
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
  ALocation := '';
  AUrl := DotlessUrl(ARawUrl);
  hostRefused := False;
  viaProxy := ClientProxyActive(ACfg);
  dial := '';

  if Length(AForceAddrs) > 0 then
  begin
    SetLength(addrs, Length(AForceAddrs));
    for i := 0 to High(AForceAddrs) do addrs[i] := AForceAddrs[i];
    dial := ParseURI(AUrl).Host;
  end
  else
  begin
    uri := ParseURI(AUrl);
    { THE HOST DIALLED IS THE PROXY'S when there is one -- only the proxy is
      dialled, and it resolves the destination, which is never looked up here --
      and the URL's otherwise. The same rules choose its addresses either way. }
    if viaProxy then dial := ClientProxyHost(ACfg) else dial := uri.Host;
    { AN ADDRESS MUST PARSE, AND NAME A HOST. A bracketed host that is not an IPv6
      address, or the unspecified address of either family, is refused before
      anything is dialled; see ParseIPv6 and IsUnspecifiedAddr. }
    if (dial <> '') and
       ((((dial[1] = '[') or (Pos(':', dial) > 0)) and
         (((dial[1] = '[') <> (dial[Length(dial)] = ']')) or not IsIPv6Literal(dial))) or
        IsUnspecifiedAddr(dial)) then
      Exit;
    SetLength(addrs, 1);
    addrs[0] := '';
    if IsIPv6Literal(dial) then
      { AN IPv6 LITERAL is its own only address (m6) -- and an IPv4-MAPPED one,
        ::ffff:a.b.c.d, IS that IPv4 address (RFC 4291 section 2.5.5.2), dialled as
        one: Windows' IPv6 sockets refuse a mapped address outright. }
      addrs[0] := MappedIPv4(dial)
    else if (dial <> '') and (not IsIPv4Literal(dial)) and (not viaProxy) and
            (LowerCase(uri.Protocol) <> 'https') then
    begin
      { A NAME over plain http: every A record, in turn. Over https the name is
        dialled as written: a pinned IP would be what SNI and the name check saw
        (docs/roadmap-net.md). A proxy's name is dialled as written too, and its
        AAAA below, like any host's. }
      addrs := ResolveAllA(dial);
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
  { NOTHING CONNECTED OVER IPv4: a name's AAAA records, in resolver order (m6).
    IPv4 first keeps every host that already worked exactly as it was; a host with
    only IPv6, or whose IPv4 is down, is reached here. Not for a forced list (the
    test names its own) or an address literal. Through a proxy it is the PROXY's
    name that is looked up, never the destination's. }
  if (Length(AForceAddrs) = 0) and (dial <> '') and (not IsIPv6Literal(dial)) and
     (not IsIPv4Literal(dial)) then
  begin
    addrs6 := HttpResolveAAAA(dial);
    for i := 0 to High(addrs6) do
    begin
      body := Attempt('[' + addrs6[i] + ']', connected);
      if connected then
      begin
        Result := body;
        Exit;
      end;
    end;
  end;
  { nothing connected: Result '' and AStatus 0 (from the last Attempt) -- and if
    a peer was refused for its NAME, say so; it is not a dead address. }
  if hostRefused then gHttpErr := HTTP_EHOST;
end;

{ WHERE A REDIRECT MAY TAKE WHAT IDENTIFIES THE CALLER. The Authorization header,
  the cookies and the client certificate go only to the ORIGIN they were set up
  for -- the first URL's scheme, host and port, all three: curl's rule since
  CVE-2022-27776, which RFC 9110 section 15.4 leaves to the client. FPC's loop did
  the reverse of safe: it re-sent the cookies when the host CHANGED, dropped them
  when it did not, and never touched Authorization, so a redirect from https to
  another host's plain http carried a bearer token in cleartext (2026-10-07). }
function SameOrigin(const A, B: String): Boolean;
var ua, ub: TURI;

  function PortOf(const U: TURI): Integer;
  begin
    Result := U.Port;
    if Result = 0 then
      if LowerCase(U.Protocol) = 'https' then Result := 443 else Result := 80;
  end;

begin
  ua := ParseURI(A);
  ub := ParseURI(B);
  Result := SameText(ua.Protocol, ub.Protocol) and
            SameText(TlsName(ua.Host), TlsName(ub.Host)) and (PortOf(ua) = PortOf(ub));
end;

function IsRedirectStatus(ACode: Integer): Boolean;
begin
  Result := (ACode = 301) or (ACode = 302) or (ACode = 303) or (ACode = 307) or (ACode = 308);
end;

{ THE ONE FETCH. HttpFetch (the bare-url verbs and the fallback proof) and the
  client verbs both come here; ACfg is the client handle's object, or nil for a
  bare url, which keeps exactly the behaviour the bare verbs always had -- no
  redirect is followed.

  REDIRECTS ARE FOLLOWED HERE, not by TFPHTTPClient (2026-10-07). Its loop
  re-entered the request with none of this library's rules: no proxy refusal, no
  pin for the new host, no IPv6, no rule about credentials -- an https URL reached
  by a redirect through a proxy was opened WITH THE PROXY, and passed the name
  check on the proxy's name. Here each hop is a request of its own, through
  FetchHop, under every rule a first request is under. What a hop that is not
  followed answers is what FPC answered: the redirect's status and no body -- for
  a missing Location, a scheme other than http and https, or the cap. A 303 turns
  the request into a GET without a body; every other code keeps the method, as
  FPC did. }
function FetchCore(const AMethod, AUrl, ABody: String;
  const AForceAddrs: array of String; out AStatus: Integer;
  AConnectMs: Integer; ACfg: TObject): String;
var
  url, method, body, loc, next, scheme: String;
  hops, maxHops: Integer;
  follow, creds: Boolean;
  jar: TStringList;
begin
  AStatus := 0;
  gHttpErr := HTTP_OK;
  follow := ClientFollow(ACfg, maxHops);
  url := AUrl;
  method := AMethod;
  body := ABody;
  hops := 0;
  jar := TStringList.Create();
  try
    Result := FetchHop(method, url, body, AForceAddrs, AStatus, AConnectMs, ACfg,
                       True, jar, loc);
    while follow and IsRedirectStatus(AStatus) and (gHttpErr = HTTP_OK) do
    begin
      Result := '';
      if loc = '' then Exit;
      if not IsAbsoluteURI(loc) then
      begin
        if not ResolveRelativeURI(url, loc, next) then Exit;
        loc := next;
      end;
      scheme := LowerCase(ParseURI(loc).Protocol);
      if (scheme <> 'http') and (scheme <> 'https') then Exit;
      Inc(hops);
      if hops > maxHops then Exit;
      if ProxyRefusedFor(ACfg, loc) then
      begin
        AStatus := 0;
        gHttpErr := HTTP_EPROXY;      // nothing was sent to it
        Exit;
      end;
      if AStatus = 303 then
      begin
        method := 'GET';
        body := '';
      end;
      url := loc;
      creds := SameOrigin(url, AUrl);
      if creds then
        Result := FetchHop(method, url, body, [], AStatus, AConnectMs, ACfg, True, jar, loc)
      else
        Result := FetchHop(method, url, body, [], AStatus, AConnectMs, ACfg, False, nil, loc);
    end;
  finally
    jar.Free;
  end;
end;

function HttpFetch(const AMethod, AUrl, ABody: String;
  const AForceAddrs: array of String; out AStatus: Integer;
  AConnectMs: Integer = 5000): String;
begin
  Result := FetchCore(AMethod, AUrl, ABody, AForceAddrs, AStatus, AConnectMs, nil);
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
    ClientCert: String;   // absolute, or '' -- see http_clientcert
    ClientKey: String;
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
  ClientCert := '';
  ClientKey := '';
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
{ INDEXED, LIKE ITS THREE SIBLINGS, AND FOR THE SECOND REASON AS WELL AS THE
  FIRST. DoUrlDecode, DoHtmlDecode and DoHtmlEncode all build their answer by
  indexed assignment into a pre-sized RawByteString -- the comments there explain
  the codepage reason. This one still appended, and appending a SLICE (rather
  than a literal) to the function Result is a full copy each time:

      http_urlencode$(string$(60000000, 32))   ' 115484 ms, rc=0 SUCCESS

  Nearly two minutes inside one opCall under a two-second limit. The answer is at
  most three bytes per input byte, so it is sized once and filled -- linear, and
  byte-for-byte the same answer. The Copy(S, i, 1) slice stays, in spirit: bytes
  are moved as bytes, never through a Char under the UTF8 codepage. }
function DoUrlEncode(const S: String): String;
var i, k: Integer; ch: Char; hex: String; r: RawByteString;
begin
  SetLength(r, Length(S) * 3);           // '%XX' is the longest an input byte gets
  k := 0;
  for i := 1 to Length(S) do
  begin
    ch := S[i];
    if ((ch >= 'A') and (ch <= 'Z')) or ((ch >= 'a') and (ch <= 'z')) or
       ((ch >= '0') and (ch <= '9')) or (ch = '-') or (ch = '_') or
       (ch = '.') or (ch = '~') then
    begin
      Inc(k); r[k] := ch;
    end
    else
    begin
      hex := IntToHex(Ord(ch), 2);
      Inc(k); r[k] := '%';
      Inc(k); r[k] := hex[1];
      Inc(k); r[k] := hex[2];
    end;
  end;
  SetLength(r, k);
  Result := r;
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
{ Case-insensitive compare of the ALen bytes at AStart against a literal, with
  no string built. See the note on the loop below for why that matters. }
function EntIs(const S: String; AStart, ALen: Integer; const E: String): Boolean;
var j: Integer; a, b: Char;
begin
  Result := False;
  if ALen <> Length(E) then Exit;
  for j := 0 to ALen - 1 do
  begin
    a := S[AStart + j];
    if (a >= 'A') and (a <= 'Z') then a := Chr(Ord(a) + 32);
    b := E[j + 1];
    if (b >= 'A') and (b <= 'Z') then b := Chr(Ord(b) + 32);
    if a <> b then Exit;
  end;
  Result := True;
end;

{ LINEAR IS NOT THE SAME AS CHEAP. This loop was already indexed -- it does not
  copy the answer over and over the way DoUrlEncode did -- and it is linear in the
  input, which is why the budget gate reads it as bounded. It still spent

      http_htmldecode$(http_htmlencode$(string$(20000000, 60)))   ' 6781 ms, rc=0

  three times its own two-second ceiling inside one opCall, because every single
  entity built TWO temporary strings (a Copy for the entity, a LowerCase of it)
  before comparing. Twenty million entities is forty million allocations.

  Comparing the bytes where they lie removes both, and the entity is only ever
  copied on the path that keeps it. The answer is byte-for-byte unchanged. }
function DoHtmlDecode(const S: String): String;
var i, semi, k, elen: Integer; r: RawByteString;
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
        elen := semi - i + 1;              // includes the '&' and the ';'
        if EntIs(S, i, elen, '&amp;') then begin Inc(k); r[k] := '&'; end
        else if EntIs(S, i, elen, '&lt;') then begin Inc(k); r[k] := '<'; end
        else if EntIs(S, i, elen, '&gt;') then begin Inc(k); r[k] := '>'; end
        else if EntIs(S, i, elen, '&quot;') then begin Inc(k); r[k] := '"'; end
        else if EntIs(S, i, elen, '&apos;') or EntIs(S, i, elen, '&#39;')
             or EntIs(S, i, elen, '&#039;') then begin Inc(k); r[k] := ''''; end
        else RawAppend(r, k, Copy(S, i, elen));   // unknown entity: leave it as it was
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
  begin c.ConnectTimeout := ArgI32(Args[1]); Result := ValInt(1); gHttpErr := HTTP_OK; end
  else begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; end;
end;

function f_http_responsetimeout_set(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TPhosphorHttpClient;
begin
  Err := NoError();
  if GetClient(Args[0].Hnd, c) then
  begin c.ResponseTimeout := ArgI32(Args[1]); Result := ValInt(1); gHttpErr := HTTP_OK; end
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
    c.ProxyHost := Args[1].Str; c.ProxyPort := ArgI32(Args[2]);
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
  begin c.MaxRedirects := ArgI32(Args[1]); Result := ValInt(1); gHttpErr := HTTP_OK; end
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

{ http_clientcert(c@, certfile$, keyfile$) -- the certificate this client presents
  when an https server asks for one (ledger m7). PEM files; keyfile$ "" means the
  key is in certfile$ too, and certfile$ "" removes the certificate. Answers 1
  when it was recorded and 0 when it was not: a bad handle (http_error() 1), or a
  path the sandbox refuses (ioerror() 5) -- OpenSSL, not this engine, will open
  the file, so the gate is asked here, on the path made ABSOLUTE, and that same
  string is what OpenSSL is handed. Nothing is read now: a missing or mismatched
  file shows up as a failed request, as http_ca_file$'s does. }
function f_http_clientcert(const Args: array of TValue; out Err: TPhosphorError): TValue;
var
  c: TPhosphorHttpClient;
  cert, key: String;
begin
  Err := NoError();
  if not GetClient(Args[0].Hnd, c) then
  begin Result := ValInt(0); gHttpErr := HTTP_EHANDLE; Exit; end;
  gHttpErr := HTTP_OK;
  cert := Args[1].Str;
  key := Args[2].Str;
  { The answer is IoAnswer's, so ioerror() is THIS call's: 0 when it was recorded.
    A plain 1 left a refusal's 5 from an earlier call standing beside a success. }
  if cert = '' then
  begin
    c.ClientCert := '';
    c.ClientKey := '';
    Exit(IoAnswer(True));
  end;
  if key = '' then key := cert;
  cert := ExpandFileName(cert);
  key := ExpandFileName(key);
  if (not IoGate(cert, puRead)) or (not IoGate(key, puRead)) then Exit(ValInt(0));
  c.ClientCert := cert;
  c.ClientKey := key;
  Result := IoAnswer(True);
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
  // QUADRATIC APPEND, charged as it goes (RULE 2): one append per field, copying
  // the whole encoded body each time. 60000 fields -- 60000 cheap VM steps to
  // add -- took over four minutes here, unbudgeted, at 15 MB.
  s := '';
  for i := 0 to f.Fields.Count - 1 do
  begin
    if not BudgetAppend(Length(s)) then
    begin Err := BudgetRefusal('http_formurlencoded$'); Exit(ValStr('')); end;
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
  code := ArgI32(Args[0]);
  case code of
    HTTP_OK:      Result := ValStr('no error');
    HTTP_EHANDLE: Result := ValStr('invalid handle');
    HTTP_EPROXY:  Result := ValStr('the request cannot go through this proxy');
    HTTP_EHOST:   Result := ValStr('the server''s certificate is not for this host');
  else
    Result := ValStr('unknown error');
  end;
end;

{ ===========================================================================
  THE CLIENT VERBS (ledger n26)

  A client handle used to be a bag of settings no verb ever read: http_get$,
  http_status and http_post$ took a bare url, so the base url, the headers, params,
  cookies, auth, proxy, timeouts and redirect policy configured on a handle never
  reached a request. The proxy was the dangerous one -- a program that set a proxy
  had its traffic go out DIRECTLY, and nothing said so. These overloads take the
  handle and a path and apply all of it.
  =========================================================================== }

function ClientProxyActive(ACfg: TObject): Boolean;
begin
  Result := (ACfg is TPhosphorHttpClient) and (TPhosphorHttpClient(ACfg).ProxyHost <> '');
end;

function ClientProxyHost(ACfg: TObject): String;
begin
  Result := '';
  if ACfg is TPhosphorHttpClient then Result := TPhosphorHttpClient(ACfg).ProxyHost;
end;

{ Whether this request follows redirects, and how many: a client's own setting; a
  bare url follows none, as it never did. }
function ClientFollow(ACfg: TObject; out AMax: Integer): Boolean;
var cfg: TPhosphorHttpClient;
begin
  AMax := 0;
  Result := ACfg is TPhosphorHttpClient;
  if not Result then Exit;
  cfg := TPhosphorHttpClient(ACfg);
  Result := cfg.FollowRedirects;
  if cfg.MaxRedirects < 0 then AMax := 0
  else if cfg.MaxRedirects > 255 then AMax := 255
  else AMax := cfg.MaxRedirects;
end;

{ A header that identifies the caller to the SERVER. Proxy-Authorization is not
  one: it is for the proxy, which is the same at every hop. }
function IsCredentialHeader(const AName: String): Boolean;
begin
  Result := SameText(AName, 'Authorization') or SameText(AName, 'Cookie');
end;

procedure ApplyClient(c: TPinnedClient; ACfg: TObject; ACreds: Boolean);
var
  cfg: TPhosphorHttpClient;
  i: Integer;
begin
  cfg := TPhosphorHttpClient(ACfg);
  if cfg.ConnectTimeout > 0 then c.ConnectTimeout := cfg.ConnectTimeout;
  if cfg.ResponseTimeout > 0 then c.IOTimeout := cfg.ResponseTimeout;
  // Verification is ON only when the global switch AND this client both ask for
  // it, so either can opt out and neither can quietly turn the other back on.
  c.VerifyPeer := gVerifyPeer and cfg.ValidateSSL;
  if ACreds then
  begin
    c.ClientCert := cfg.ClientCert;
    c.ClientKey := cfg.ClientKey;
  end;
  if cfg.UserAgent <> '' then c.AddHeader('User-Agent', cfg.UserAgent);
  if cfg.Accept <> '' then c.AddHeader('Accept', cfg.Accept);
  if cfg.ContentType <> '' then c.AddHeader('Content-Type', cfg.ContentType);
  if ACreds and (cfg.AuthHeader <> '') then c.AddHeader('Authorization', cfg.AuthHeader);
  // The client's own header bag last, so a header it names explicitly wins.
  for i := 0 to cfg.Headers.Count - 1 do
    if ACreds or not IsCredentialHeader(cfg.Headers.NameAt(i)) then
      c.AddHeader(cfg.Headers.NameAt(i), cfg.Headers.ValueAt(i));
  if ACreds then
    for i := 0 to cfg.Cookies.Count - 1 do
      c.Cookies.Add(cfg.Cookies.NameAt(i) + '=' + cfg.Cookies.ValueAt(i));
  if cfg.ProxyHost <> '' then
  begin
    c.Proxy.Host := cfg.ProxyHost;
    c.Proxy.Port := cfg.ProxyPort;
    c.Proxy.UserName := cfg.ProxyUser;
    c.Proxy.Password := cfg.ProxyPass;
  end;
end;

{ The request url: the base url and the path joined by exactly one '/', or the
  path alone when it is absolute; then the params, url-encoded, as the query.

  THE QUERY IS A QUADRATIC APPEND over a count the SCRIPT chose -- one append per
  param, copying the query each time -- so it is charged as it goes (RULE 2), the
  way JoinList in PhosphorConfigLib is. Answers False, with the url unbuilt, when
  the budget refuses; the caller reports it. (check-budget.py could not see this
  loop on the day it was written: its comment stripper read the '//' inside the
  literal below as a comment, and paired every quote after it wrongly.) }
{ IS THIS AN ABSOLUTE URL? Only when it BEGINS with a scheme and '://' -- RFC 3986
  section 3.1: a letter, then letters, digits, '+', '-' or '.'. The test used to
  be '://' ANYWHERE, so a path whose query carried a url -- /go?to=http://x/ --
  was sent as an absolute url with no host and failed (2026-10-07). }
function HasScheme(const AUrl: String): Boolean;
var i: Integer;
begin
  Result := False;
  if (AUrl = '') or not (AUrl[1] in ['A'..'Z', 'a'..'z']) then Exit;
  i := 2;
  while (i <= Length(AUrl)) and (AUrl[i] in ['A'..'Z', 'a'..'z', '0'..'9', '+', '-', '.']) do
    Inc(i);
  Result := Copy(AUrl, i, 3) = '://';
end;

function ClientUrl(cfg: TPhosphorHttpClient; const APath: String; out AUrl: String): Boolean;
var
  base, p, q: String;
  i, k: Integer;
begin
  Result := False;
  AUrl := '';
  if HasScheme(APath) then AUrl := APath
  else
  begin
    base := cfg.BaseUrl;
    while (base <> '') and (base[Length(base)] = '/') do Delete(base, Length(base), 1);
    k := 1;
    while (k <= Length(APath)) and (APath[k] = '/') do Inc(k);
    p := Copy(APath, k, MaxInt);
    if base = '' then AUrl := APath
    else if p = '' then AUrl := base
    else AUrl := base + '/' + p;
  end;
  q := '';
  for i := 0 to cfg.Params.Count - 1 do
  begin
    if not BudgetAppend(Length(q)) then Exit;
    if q <> '' then q := q + '&';
    q := q + DoUrlEncode(cfg.Params.NameAt(i)) + '=' + DoUrlEncode(cfg.Params.ValueAt(i));
  end;
  if q <> '' then
    if Pos('?', AUrl) > 0 then AUrl := AUrl + '&' + q
    else AUrl := AUrl + '?' + q;
  Result := True;
end;

{ A PROXY THIS CLIENT CANNOT HONOUR IS A REFUSAL, NOT A DETOUR. Two shapes:
    * an https request -- TFPHTTPClient has no CONNECT, so through a proxy it would
      open TLS with the PROXY instead of tunnelling to the destination (read in
      fphttpclient.pp: ExtractHostPort dials Proxy.Host for every scheme), which is
      the missing CONNECT the plan records as a deferral (m7). Sending it direct
      instead would be the leak this entry exists to close;
    * a port outside 1..65535 -- the RTL's ProxyActive needs a port above zero and
      otherwise ignores the proxy, so the request would go DIRECT, silently.
  Either way nothing is sent and http_error() says why. }
function ProxyRefused(cfg: TPhosphorHttpClient; const AUrl: String): Boolean;
begin
  Result := False;
  if cfg.ProxyHost = '' then Exit;
  if (cfg.ProxyPort < 1) or (cfg.ProxyPort > 65535) then Exit(True);
  if LowerCase(ParseURI(AUrl).Protocol) = 'https' then Exit(True);
end;

function HttpIsIPv4Literal(const AHost: String): Boolean;
begin
  Result := IsIPv4Literal(AHost);
end;

function HttpIsIPv6Literal(const AHost: String): Boolean;
begin
  Result := IsIPv6Literal(AHost);
end;

function HttpSameOrigin(const A, B: String): Boolean;
begin
  Result := SameOrigin(A, B);
end;

function ProxyRefusedFor(ACfg: TObject; const AUrl: String): Boolean;
begin
  Result := (ACfg is TPhosphorHttpClient) and ProxyRefused(TPhosphorHttpClient(ACfg), AUrl);
end;

function ClientFetch(const AWho: String; const AHandle: TValue;
                     const AMethod, APath, ABody: String; out AStatus: Integer;
                     out Err: TPhosphorError): String;
var
  cfg: TPhosphorHttpClient;
  url: String;
  ms: Integer;
begin
  Result := '';
  AStatus := 0;
  Err := NoError();
  if not GetClient(AHandle.Hnd, cfg) then begin gHttpErr := HTTP_EHANDLE; Exit; end;
  // A query too long for the run's budget is the run's refusal, like any other.
  if not ClientUrl(cfg, APath, url) then begin Err := BudgetRefusal(AWho); Exit; end;
  if ProxyRefused(cfg, url) then begin gHttpErr := HTTP_EPROXY; Exit; end;
  gHttpErr := HTTP_OK;
  if cfg.ConnectTimeout > 0 then ms := cfg.ConnectTimeout else ms := 5000;
  Result := FetchCore(AMethod, url, ABody, [], AStatus, ms, cfg);
end;

function f_http_cget(const Args: array of TValue; out Err: TPhosphorError): TValue;
var status: Integer;
begin
  Result := ValStr(ClientFetch('http_get$', Args[0], 'GET', Args[1].Str, '', status, Err));
end;

function f_http_cstatus(const Args: array of TValue; out Err: TPhosphorError): TValue;
var status: Integer;
begin
  ClientFetch('http_status', Args[0], 'GET', Args[1].Str, '', status, Err);
  Result := ValInt(status);
end;

function f_http_cpost(const Args: array of TValue; out Err: TPhosphorError): TValue;
var status: Integer;
begin
  Result := ValStr(ClientFetch('http_post$', Args[0], 'POST', Args[1].Str, Args[2].Str, status, Err));
end;

procedure RegisterHttpFuncs(Reg: TPhosphorRegistry);
begin
  // The client verbs: the same three names, taking a client handle and a path.
  Reg.Add('http_get$:@$',      @f_http_cget);
  Reg.Add('http_status:@$',    @f_http_cstatus);
  Reg.Add('http_post$:@$$',    @f_http_cpost);
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
  Reg.Add('http_clientcert:@$$',  @f_http_clientcert);
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

{$IFDEF WIN64}
procedure PreferOpenSSL3Pair;
var hs, hc: TLibHandle;
begin
  hc := LoadLibrary('libcrypto-3-x64.dll');
  hs := LoadLibrary('libssl-3-x64.dll');
  if (hc <> NilHandle) and (hs <> NilHandle) then
  begin
    openssl.DLLUtilName := 'libcrypto-3-x64.dll';
    openssl.DLLSSLName := 'libssl-3-x64.dll';
  end;
  // The probe's own references; the loader takes its own when https first runs.
  if hs <> NilHandle then FreeLibrary(hs);
  if hc <> NilHandle then FreeLibrary(hc);
end;
{$ENDIF}

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
  {$IFDEF WIN64}
  { THE WINDOWS TWIN OF THE LINE ABOVE (ledger m5). FPC 3.2.2's Windows names stop at
    OpenSSL 1.1 (libssl-1_1-x64.dll); a box with only OpenSSL 3 had no https at all,
    and the dev machine had it only because Git's 1.1 happened to be on PATH. The
    loader takes libcrypto and libssl from SEPARATE name lists, so a 3.x libcrypto
    beside a 1.1 libssl is a reachable pairing -- and a crash. The 3.x names go into
    the FIRST slot only when BOTH halves load, so the pair is whole or untouched. The
    slot they take is OpenSSL 1.0's, end-of-life since 2019. }
  PreferOpenSSL3Pair();
  {$ENDIF}
  gCAFile := LocateCABundle();

end.
