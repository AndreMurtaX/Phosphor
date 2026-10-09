{******************************************************************************
  phosphorhttptest -- the headless runner for the HTTP opt-in package

  MIT License. Copyright (c) 2026 Andre Murta.

  Like phosphorpkgtest, but it also stands up a REAL local HTTP server (FPC's
  TFPHTTPServer, on a loopback port) before running the .bas, so PhosphorHttpLib is
  exercised against a live server -- no mocks, no network, no external dependency.
  The server answers a few fixed routes:

    GET  /        -> 200  "phosphor http ok"
    GET  /json    -> 200  a small JSON body
    GET  /teapot  -> 418  "teapot"
    POST /echo    -> 200  (the request body, verbatim)
    any  /inspect -> 200  what the request carried: its target, query, method,
                          and the headers a client handle sets (one per line)
    (anything else)  404  "not found"

  Beside it, a RAW server (TV6Server in its Raw mode, server_url_raw$) answers the request head
  it was sent, byte for byte, which a parsing server cannot show (2026-10-09).

  The BASIC program learns the server's address from server_url$() -- a host
  function this runner registers -- so the port never has to be hard-coded in the
  test. The server runs in a background thread; the process Halt()s when the test is
  done, which tears the thread down with it.
******************************************************************************}
program phosphorhttptest;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

uses
  {$IFDEF UNIX}cthreads, BaseUnix,{$ENDIF}
  SysUtils, Classes, Types, StrUtils, fphttpserver, httpdefs, openssl,
  dynlibs, ctypes, ssockets, sslsockets, opensslsockets, fpopenssl, sockets, URIParser,
  PhosphorEngine, PhosphorValue, PhosphorErrors, PhosphorTestLib,
  PhosphorHttpLib, PhosphorBudget;

const
  SRV_PORT     = 18099;
  SRV_PORT_TLS = 18443;
  SRV_PORT_TLS_IP = 18444;   // the same CA, a certificate for IP:127.0.0.1 only (m5)
  SRV_PORT_MTLS = 18445;     // requires a client certificate the CA signed (m7)
  SRV_PORT_V6 = 18446;       // [::1], plain http (m6)
  SRV_PORT_V6_TLS = 18447;   // [::1], https, the localhost certificate (m6)
  SRV_PORT_V6_TLS_IP = 18448;// [::1], https, the certificate naming ::1 (m6)
  { [::1], a peer that TRICKLES THE TLS HANDSHAKE: it reads the ClientHello, sends
    a record header announcing 16384 bytes, then one byte every 200 ms for four
    seconds. Every read is answered in time, so only a deadline on the whole
    handshake bounds it (2026-10-08, second adversarial round). }
  SRV_PORT_V6_TLS_TRICKLE = 18449;
  { [::1], a peer that reads the ClientHello and sends the TLS record header only
    after 900 ms, then nothing for two seconds. Its single late write is what a
    shutdown() from another thread could not interrupt on Windows (2026-10-08,
    third adversarial pass). }
  SRV_PORT_V6_TLS_LATE = 18450;
  { [::1], a server that drains an upload in 128 KiB bursts, 600 ms apart, with a
    small receive buffer -- each burst lets one blocking send through, so only a
    send bounded by the deadline ends the request on time (fourth pass). }
  SRV_PORT_V6_DRAIN = 18452;
  { [::1], a RELAY in front of the IP-certificate TLS server: what the client
    sends goes straight through, and what the server sends goes straight back
    for the first 700 ms of the connection -- then one byte every 300 ms. A TLS
    record arriving late is so trickled INSIDE itself, which is what OpenSSL's
    own reads restarted the timeout on (fourth pass). }
  SRV_PORT_V6_RELAY = 18453;
  { 127.0.0.1, a RAW server (2026-10-09): it answers the request head it was sent,
    byte for byte, as the body -- so a test sees exactly what reached the wire,
    which TFPHTTPServer, parsing the head into fields, cannot show: an injected
    CR LF arrives there as one more well-formed header. Routes below. }
  SRV_PORT_RAW = 18455;

var
  BaseURL: String;
  BaseURLHttps: String;
  CAFile: String;   // the throwaway CA the TLS fixture chains to (ledger m5)
  BaseURLHttpsIP: String;
  BaseURLMtls: String;
  GResolve6Map: TStringList = nil;   // http_resolve6_as$'s answers
  GResolve6Calls: Integer = 0;       // how often the package asked it
  CertDirG: String;   // where the fixtures live, for the client-certificate paths
  Withheld: String = '';   // http_tls_withhold's name, consulted by the library's seam
  GHits: LongInt = 0;      // how many requests /hit has seen
  GSniLock: TRTLCriticalSection;
  GSni: TStringList = nil; // the SNI per TLS connection; Objects[] is its stream
  GRawHits: LongInt = 0;   // how many connections the raw server has accepted
  GRawLocation: String = '';   // what the raw server's /b/c/d;p?q redirects to

{ ---- the local test server -------------------------------------------------}

type
  { TFPHttpServer keeps Address (bind interface), UseSSL, and CertificateData
    protected; republish them so we can pin the server to loopback only (the fallback
    test needs a genuinely dead 127.0.0.x) and stand a second server up over TLS with
    an auto-generated self-signed certificate (the https test). }
  TBoundHttpServer = class(TFPHTTPServer)
  protected
    function GetSocketHandler(const AUseSSL: Boolean): TSocketHandler; override;
  published
    property Address;
    property UseSSL;
    property CertificateData;
  end;

  { A TLS HANDLER THAT REMEMBERS THE SNI its connection sent (2026-10-07), so
    /inspect can answer it: a request cannot reach its handler (TSocketStream keeps
    it private), so the name is filed under the connection's stream, which the
    request can reach. }
  TSniHandler = class(TOpenSSLSocketHandler)
  public
    function Accept: Boolean; override;
  end;

  { A TLS SERVER THAT REQUIRES A CLIENT CERTIFICATE (ledger m7). FPC's handler can
    only ASK for one -- VerifyPeerCert sets SSL_VERIFY_PEER, which on a server
    requests a certificate and accepts a client that sends none. Requiring it
    takes SSL_VERIFY_FAIL_IF_NO_PEER_CERT, which FPC never sets, so it is set on
    each connection right after the context is built, through SSL_set_verify
    bound by name -- the m5 approach, for the same reason. The client's chain is
    verified against the throwaway CA. }
  TRequireClientCertHandler = class(TOpenSSLSocketHandler)
  protected
    function InitContext(NeedCertificate: Boolean): Boolean; override;
  end;

  TMutualTlsServer = class(TBoundHttpServer)
  protected
    function GetSocketHandler(const AUseSSL: Boolean): TSocketHandler; override;
  end;

  { The server runs in its own thread, and that same object carries the request
    handler -- so the object is plainly used (th.Start), no stray instance. }
  TServerThread = class(TThread)
  public
    Srv: TFPHTTPServer;
    procedure HandleRequest(Sender: TObject;
      var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
    procedure Execute; override;
  end;

{ Send EXACTLY these bytes as the body. We deliberately avoid AResponse.Content:
  that round-trips the string through a TStringList, which appends a trailing line
  ending -- and one that differs by platform (CRLF on Windows, LF on Unix), which
  would make a byte-exact test OS-dependent. A content stream sends the raw bytes
  and sets Content-Length from its size. }
procedure SetBody(var AResponse: TFPHTTPConnectionResponse; ACode: Integer; const ABody: String);
begin
  AResponse.Code := ACode;
  AResponse.ContentType := 'text/plain';
  AResponse.ContentStream := TStringStream.Create(ABody);
  AResponse.FreeContentStream := True;
  AResponse.ContentLength := AResponse.ContentStream.Size;
end;

{ A query argument read off the raw request target, which for a request through a
  proxy is the absolute url. Values are taken as written: the tests send none that
  needs decoding, and none holding '&' or '?'. }
function QueryArg(const AUri, AName: String): String;
var p: Integer;
    part: String;
begin
  Result := '';
  p := Pos('?', AUri);
  if p = 0 then Exit;
  for part in Copy(AUri, p + 1, MaxInt).Split(['&']) do
    if Copy(part, 1, Length(AName) + 1) = AName + '=' then
      Exit(Copy(part, Length(AName) + 2, MaxInt));
end;

{ The SNI a TLS request sent, '' for none, and '-' for a connection no TSniHandler
  accepted (plain http). Taken out of the list as it is read: one request per
  connection, and a later stream at the same address must not inherit it. }
function RequestSni(ARequest: TFPHTTPConnectionRequest): String;
var i: Integer;
begin
  Result := '-';
  EnterCriticalSection(GSniLock);
  try
    i := GSni.IndexOfObject(ARequest.Connection.Socket);
    if i >= 0 then
    begin
      Result := GSni[i];
      GSni.Delete(i);
    end;
  finally
    LeaveCriticalSection(GSniLock);
  end;
end;

procedure TServerThread.HandleRequest(Sender: TObject;
  var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var path, m: String;
begin
  path := ARequest.PathInfo;
  m := ARequest.Method;
  { THE REDIRECT ROUTES (2026-10-07). /redirect?to=URL&code=N answers N -- 302
    when absent -- with Location URL; /setcookie does the same and sets a cookie
    that carries attributes; /hit counts the request and then redirects like
    /redirect, and /hits answers the count. Matched anywhere in the target, as
    /inspect is, so a request through a proxy reaches them -- and ahead of
    /inspect, because a `to` that names /inspect is in the target too. }
  if Pos('/hits', ARequest.URI) > 0 then
    SetBody(AResponse, 200, IntToStr(GHits))
  else if (Pos('/redirect', ARequest.URI) > 0) or (Pos('/setcookie', ARequest.URI) > 0) or
          (Pos('/hit', ARequest.URI) > 0) then
  begin
    if Pos('/hit', ARequest.URI) > 0 then InterLockedIncrement(GHits);
    if Pos('/setcookie', ARequest.URI) > 0 then
      AResponse.SetCustomHeader('Set-Cookie', 'srv=7; Path=/; HttpOnly');
    AResponse.SetCustomHeader('Location', QueryArg(ARequest.URI, 'to'));
    SetBody(AResponse, StrToIntDef(QueryArg(ARequest.URI, 'code'), 302), '');
  end
  else
  { /inspect ANSWERS WHAT IT WAS SENT, so a test can see what a client handle put
    on the wire (ledger n26). Matched anywhere in the request target, because a
    request that came through a PROXY carries the absolute url on its request line
    -- "GET http://host:port/inspect" -- and that target is the proof the proxy
    was used: this same server is what the proxy test points the proxy at. }
  if Pos('/inspect', ARequest.URI) > 0 then
    SetBody(AResponse, 200,
      'target=' + ARequest.URI + #10 +
      'query=' + ARequest.QueryString + #10 +
      'method=' + m + #10 +
      'ua=' + ARequest.UserAgent + #10 +
      'accept=' + ARequest.Accept + #10 +
      'ctype=' + ARequest.GetFieldByName('Content-Type') + #10 +
      'auth=' + ARequest.Authorization + #10 +
      'pauth=' + ARequest.GetFieldByName('Proxy-Authorization') + #10 +
      'cookie=' + ARequest.GetFieldByName('Cookie') + #10 +
      'xdemo=' + ARequest.GetFieldByName('X-Demo') + #10 +
      'sni=' + RequestSni(ARequest) + #10 +
      'body=' + ARequest.Content)
  else if ((path = '/') or (path = '')) and (m = 'GET') then
    SetBody(AResponse, 200, 'phosphor http ok')
  else if (path = '/json') and (m = 'GET') then
    SetBody(AResponse, 200, '{"n":42}')
  else if (path = '/teapot') and (m = 'GET') then
    SetBody(AResponse, 418, 'teapot')
  else if (path = '/echo') and (m = 'POST') then
    SetBody(AResponse, 200, ARequest.Content)
  else
    SetBody(AResponse, 404, 'not found');
end;

procedure TServerThread.Execute;
begin
  try
    Srv.Active := True;   // blocks in the accept loop until the process ends
  except
  end;
end;

{ ---- host function: server_url$() -> the base URL of the local server -------}

function f_server_url(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValStr(BaseURL);
end;

{ server_url_https$() -> the base URL of the local TLS server (self-signed cert). }
function f_server_url_https(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValStr(BaseURLHttps);
end;

{ server_ca_file$() -> the path of the throwaway CA that signed the TLS fixture. The
  fixture names `localhost` and nothing else, so with this CA trusted a request to
  https://localhost verifies end to end and one to https://127.0.0.1 -- the same
  server, the same chain -- must be refused for its NAME. Handed over by the runner
  because it knows where the fixture lives and the script's working directory does
  not. }
function f_server_ca_file(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValStr(CAFile);
end;

const
  { OpenSSL ssl.h. FPC's openssl unit defines SSL_VERIFY_PEER and not this one. }
  SSL_VERIFY_FAIL_IF_NO_PEER_CERT = $02;

type
  TSslSetVerify = procedure(ssl: PSSL; mode: cint; cb: Pointer); cdecl;

function TRequireClientCertHandler.InitContext(NeedCertificate: Boolean): Boolean;
var setverify: TSslSetVerify;
begin
  Result := inherited InitContext(NeedCertificate);
  if not Result then Exit;
  setverify := TSslSetVerify(GetProcedureAddress(SSLLibHandle, 'SSL_set_verify'));
  // No way to require it means this server must not pretend to: refuse to start.
  if not Assigned(setverify) then Exit(False);
  setverify(SSL.SSL, SSL_VERIFY_PEER or SSL_VERIFY_FAIL_IF_NO_PEER_CERT, nil);
end;

function TSniHandler.Accept: Boolean;
var i: Integer;
    sni: String;
begin
  Result := inherited Accept();
  if not Result then Exit;
  sni := SSLGetServername(SSL.SSL);   // '' when the client sent none
  EnterCriticalSection(GSniLock);
  try
    i := GSni.IndexOfObject(Socket);
    if i >= 0 then GSni[i] := sni else GSni.AddObject(sni, Socket);
  finally
    LeaveCriticalSection(GSniLock);
  end;
end;

function TBoundHttpServer.GetSocketHandler(const AUseSSL: Boolean): TSocketHandler;
var h: TSniHandler;
begin
  if not AUseSSL then Exit(inherited GetSocketHandler(AUseSSL));
  h := TSniHandler.Create();
  h.CertificateData := Self.CertificateData;   // what CreateSSLSocketHandler does
  Result := h;
end;

function TMutualTlsServer.GetSocketHandler(const AUseSSL: Boolean): TSocketHandler;
var h: TRequireClientCertHandler;
begin
  if not AUseSSL then Exit(inherited GetSocketHandler(AUseSSL));
  h := TRequireClientCertHandler.Create();
  h.CertificateData := Self.CertificateData;   // what CreateSSLSocketHandler does
  h.VerifyPeerCert := True;                    // SSL_VERIFY_PEER, and the CA loaded
  Result := h;
end;

{ AN IPv6 SERVER (ledger m6). TFPHTTPServer is IPv4 only -- it is built on
  TInetServer, which opens AF_INET -- so the IPv6 side is a small accept loop of its
  own on [::1]. Each accepted descriptor becomes a TSocketStream, which works for any
  descriptor, wrapped in FPC's OpenSSL handler when it is a TLS server; Accept does
  the handshake. Routes: / answers "phosphor http ok", /family answers "ipv6" --
  the IPv4 servers have no such route, so a request that answers it went over IPv6
  -- /echo answers the request body, and /redir sends a 302 to the IPv4 server, the
  case that shows a pin is for its own host only. One connection at a time, which
  is what the tests make. }
type
  TV6Server = class(TThread)
  public
    Port: Word;
    Tls: Boolean;
    CertFile, KeyFile: String;
    Ready: Boolean;
    Trickle: Boolean;   // trickle a TLS handshake instead of serving
    LateHeader: Boolean;   // with Trickle: one late record header, then silence
    Drain: Boolean;        // read a request body in slow bursts
    { THE RAW SERVER (SRV_PORT_RAW, 2026-10-09): on 127.0.0.1, not [::1], and it
      answers the request head it was sent, byte for byte -- see ServeRaw. The
      same accept loop and the same head reader as the IPv6 servers. }
    Raw: Boolean;
    procedure Execute; override;
  private
    procedure Serve(AFd: TSocket);
  end;

{ THE TRICKLING RELAY (see SRV_PORT_V6_RELAY). One connection at a time, which is
  what the test makes: the upward copy runs on a thread of its own so the
  downward one can take its time. }
type
  TPipeUp = class(TThread)
  public
    FromFd, ToFd: TSocket;
    procedure Execute; override;
  end;

  TRelay = class(TThread)
  public
    Port, Upstream: Word;
    Ready: Boolean;
    procedure Execute; override;
  end;

procedure TPipeUp.Execute;
var
  buf: array[0..4095] of Byte;
  n: LongInt;
begin
  repeat
    n := fpRecv(FromFd, @buf[0], SizeOf(buf), 0);
    if n > 0 then
      if fpSend(ToFd, @buf[0], n, 0) <= 0 then Break;
  until n <= 0;
  fpShutdown(ToFd, 1);
end;

procedure TRelay.Execute;
var
  ls, cs, us: TSocket;
  a, u: TInetSockAddr6;
  len: TSockLen;
  up: TPipeUp;
  buf: array[0..4095] of Byte;
  n, i: LongInt;
  t0: QWord;
  {$IFDEF UNIX}one: LongInt;{$ENDIF}
begin
  ls := fpSocket(AF_INET6, SOCK_STREAM, 0);
  {$IFDEF UNIX}
  one := 1;
  fpsetsockopt(ls, SOL_SOCKET, SO_REUSEADDR, @one, SizeOf(one));
  {$ENDIF}
  FillChar(a, SizeOf(a), 0);
  a.sin6_family := AF_INET6;
  a.sin6_port := htons(Port);
  a.sin6_addr := StrToHostAddr6('::1');
  if fpBind(ls, @a, SizeOf(a)) <> 0 then Exit;
  if fpListen(ls, 8) <> 0 then Exit;
  Ready := True;
  while not Terminated do
  begin
    len := SizeOf(a);
    cs := fpAccept(ls, @a, @len);
    {$IFDEF WINDOWS}if cs = TSocket(-1) then Continue;{$ELSE}if cs < 0 then Continue;{$ENDIF}
    t0 := GetTickCount64();
    us := fpSocket(AF_INET6, SOCK_STREAM, 0);
    FillChar(u, SizeOf(u), 0);
    u.sin6_family := AF_INET6;
    u.sin6_port := htons(Upstream);
    u.sin6_addr := StrToHostAddr6('::1');
    if fpConnect(us, @u, SizeOf(u)) <> 0 then
    begin
      CloseSocket(us);
      CloseSocket(cs);
      Continue;
    end;
    up := TPipeUp.Create(True);
    up.FromFd := cs;
    up.ToFd := us;
    up.FreeOnTerminate := False;
    up.Start;
    try
      repeat
        n := fpRecv(us, @buf[0], SizeOf(buf), 0);
        if n <= 0 then Break;
        if GetTickCount64() - t0 < 700 then
        begin
          if fpSend(cs, @buf[0], n, 0) <= 0 then Break;
        end
        else
          for i := 0 to n - 1 do
          begin
            { SEND, THEN WAIT: the record must BEGIN before the client's deadline
              for the defect to show -- a first byte held back 300 ms arrived
              after it, and the old reader simply timed out on time. }
            if fpSend(cs, @buf[i], 1, 0) <= 0 then Break;
            Sleep(300);
          end;
      until False;
    except
      // either side gone: the case is over
    end;
    fpShutdown(cs, 2);
    fpShutdown(us, 2);
    up.WaitFor;
    up.Free;
    CloseSocket(us);
    CloseSocket(cs);
  end;
end;

{ raw_hits() -> how many connections the raw server has accepted so far. }
function f_raw_hits(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(GRawHits);
end;

{ raw_location$(loc$) -> loc$. The raw server's /b/c/d;p?q answers 302 with
  exactly these bytes as its Location from now on. }
function f_raw_location(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  GRawLocation := Args[0].Str;
  UniqueString(GRawLocation);
  Result := ValStr(GRawLocation);
end;

{ server_url_raw$() -> the raw server's base url, http://127.0.0.1:PORT }
function f_server_url_raw(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValStr('http://127.0.0.1:' + IntToStr(SRV_PORT_RAW));
end;

{ http_resolve_ref$(base$, ref$) -> the url a redirect from base$ to the
  Location ref$ is sent to: PhosphorHttpLib's own resolution, the one FetchCore
  follows. '' when it cannot resolve one. }
function f_http_resolve_ref(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValStr(HttpResolveReference(Args[0].Str, Args[1].Str));
end;

procedure TV6Server.Execute;
var
  ls, cs: TSocket;
  a: TInetSockAddr6;
  a4: TInetSockAddr;
  len: TSockLen;
  rcv: LongInt;
  {$IFDEF UNIX}one: LongInt;{$ENDIF}
begin
  if Raw then ls := fpSocket(AF_INET, SOCK_STREAM, 0)
  else ls := fpSocket(AF_INET6, SOCK_STREAM, 0);
  {$IFDEF UNIX}
  one := 1;
  fpsetsockopt(ls, SOL_SOCKET, SO_REUSEADDR, @one, SizeOf(one));
  {$ENDIF}
  FillChar(a, SizeOf(a), 0);
  a.sin6_family := AF_INET6;
  a.sin6_port := htons(Port);
  a.sin6_addr := StrToHostAddr6('::1');
  FillChar(a4, SizeOf(a4), 0);
  a4.sin_family := AF_INET;
  a4.sin_port := htons(Port);
  a4.sin_addr := StrToNetAddr('127.0.0.1');
  if Raw then
  begin
    if fpBind(ls, @a4, SizeOf(a4)) <> 0 then Exit;
  end
  else if fpBind(ls, @a, SizeOf(a)) <> 0 then Exit;
  if Drain then
  begin
    rcv := 4096;
    fpsetsockopt(ls, SOL_SOCKET, SO_RCVBUF, @rcv, SizeOf(rcv));
  end;
  if fpListen(ls, 8) <> 0 then Exit;
  Ready := True;
  while not Terminated do
  begin
    len := SizeOf(a);
    cs := fpAccept(ls, @a, @len);
    {$IFDEF WINDOWS}if cs = TSocket(-1) then Continue;{$ELSE}if cs < 0 then Continue;{$ENDIF}
    { Counted before anything is read, so a test can prove a request that should
      have sent nothing did not even connect. }
    if Raw then InterLockedIncrement(GRawHits);
    try
      Serve(cs);
    except
      // a broken client must not take the server down for the next one
    end;
  end;
end;

{ http_wire_url$(url$) -> the url the library hands FPC for url$, or '' when it
  refuses url$ before any dial: PhosphorHttpLib's HttpWireUrl. }
function f_http_wire_url(const Args: array of TValue; out Err: TPhosphorError): TValue;
var w: String;
begin
  Err := NoError();
  if not HttpWireUrl(Args[0].Str, w) then w := '';
  Result := ValStr(w);
end;

{ ---- the generated authority sweep (2026-10-09, round 2) --------------------
  THE ORACLE, written apart from the library's HttpWireUrl and sharing none of
  its code: RFC 3986's reading of an http url, by its own scan, against what
  FPC's ParseURI -- the parser the client really dials with -- reads out of
  the same text. A url is usable iff RFC 3986 reads a well-formed authority (at
  most one '@'; a '[' host closed by ']' and followed by nothing or ':'; a port
  of digits, 1..65535, or empty) and ParseURI, handed the url with its fragment
  removed and an empty port's ':' dropped, reads the same scheme, user,
  password, host and port. AWire is that url. }
{ The first (or, with ALast, the last) index of C in S; 0 when it is absent. }
function ChIdx(C: Char; const S: String; ALast: Boolean): Integer;
var i: Integer;
begin
  Result := 0;
  for i := 1 to Length(S) do
    if S[i] = C then
    begin
      Result := i;
      if not ALast then Exit;
    end;
end;

function OracleWire(const U: String; out AWire: String): Boolean;
var
  w, rest, auth, tail, ui, hp, h, d, usr, pw: String;
  i, n, ats, port: Integer;
  colon: Boolean;
  f: TURI;
begin
  Result := False;
  AWire := '';
  i := ChIdx('#', U, False);
  if i > 0 then w := Copy(U, 1, i - 1) else w := U;
  if Copy(w, 1, 7) <> 'http://' then Exit;
  rest := Copy(w, 8, MaxInt);
  n := 1;
  while (n <= Length(rest)) and (rest[n] <> '/') and (rest[n] <> '?') do Inc(n);
  auth := Copy(rest, 1, n - 1);
  tail := Copy(rest, n, MaxInt);
  ats := 0;
  for i := 1 to Length(auth) do
    if auth[i] = '@' then Inc(ats);
  if ats > 1 then Exit;
  ui := '';
  hp := auth;
  if ats = 1 then
  begin
    i := ChIdx('@', auth, False);
    ui := Copy(auth, 1, i - 1);
    hp := Copy(auth, i + 1, MaxInt);
  end;
  usr := ui;
  pw := '';
  i := ChIdx(':', ui, False);
  if i > 0 then
  begin
    usr := Copy(ui, 1, i - 1);
    pw := Copy(ui, i + 1, MaxInt);
  end;
  colon := False;
  d := '';
  if Copy(hp, 1, 1) = '[' then
  begin
    i := ChIdx(']', hp, False);
    if i = 0 then Exit;
    h := Copy(hp, 1, i);
    if i < Length(hp) then
    begin
      if hp[i + 1] <> ':' then Exit;
      colon := True;
      d := Copy(hp, i + 2, MaxInt);
    end;
  end
  else
  begin
    i := ChIdx(':', hp, True);
    if i > 0 then
    begin
      colon := True;
      h := Copy(hp, 1, i - 1);
      d := Copy(hp, i + 1, MaxInt);
    end
    else h := hp;
  end;
  port := 0;
  if d <> '' then
  begin
    for i := 1 to Length(d) do
      if not (d[i] in ['0'..'9']) then Exit;
    while (Length(d) > 1) and (d[1] = '0') do Delete(d, 1, 1);
    if Length(d) > 5 then Exit;
    port := StrToInt(d);
    if (port < 1) or (port > 65535) then Exit;
  end
  else if colon then
    auth := Copy(auth, 1, Length(auth) - 1);
  w := 'http://' + auth + tail;
  try
    f := ParseURI(w, False);
  except
    Exit;
  end;
  if (f.Protocol <> 'http') or (not f.HasAuthority) or (f.Username <> usr) or
     (f.Password <> pw) or (f.Host <> h) or (f.Port <> port) then
    Exit;
  AWire := w;
  Result := True;
end;

{ http_url_sweep$() -> "checked=N usable=U refused=R mismatches=M" and, after a
  space, the first mismatching urls. Every url is "http://" + an authority + a
  tail, and the library's HttpWireUrl must give the oracle's answer -- the same
  verdict and, when usable, the same url -- on each. The authorities:
    * every string of 0..4 characters over ? # @ : [ ] / % h 1 -- 11111 of them;
    * five realistic authorities with two of ? # @ : [ ] / % inserted, at every
      pair of positions i <= j -- (L+1)(L+2)/2 * 64 for an authority of length L.
  Each with all seven tails below. }
const
  SweepChars: array[0..9] of Char = ('?', '#', '@', ':', '[', ']', '/', '%', 'h', '1');
  SweepTails: array[0..6] of String = ('', '/', '?', '#', '/p?a?b', '?a#b#c', '#a?b#c');
  SweepReal: array[0..4] of String = ('u:p@127.0.0.1:8080', '[::1]:443', 'h.test', 'h:65616', 'h:');

function f_http_url_sweep(const Args: array of TValue; out Err: TPhosphorError): TValue;
var
  checked, usable, refused, bad: Int64;
  firsts: array[1..3] of String;

  procedure Check(const AAuth: String);
  var t: Integer;
      u, wl, wo: String;
      vl, vo: Boolean;
  begin
    for t := 0 to High(SweepTails) do
    begin
      u := 'http://' + AAuth + SweepTails[t];
      vl := HttpWireUrl(u, wl);
      vo := OracleWire(u, wo);
      Inc(checked);
      if vo then Inc(usable) else Inc(refused);
      if (vl <> vo) or (vl and (wl <> wo)) then
      begin
        Inc(bad);
        if bad <= 3 then firsts[bad] := ' ' + u;
      end;
    end;
  end;

var
  a, b, c, d, r, i, j: Integer;
  s, ins: String;
begin
  Err := NoError();
  checked := 0; usable := 0; refused := 0; bad := 0;
  firsts[1] := ''; firsts[2] := ''; firsts[3] := '';
  Check('');
  for a := 0 to 9 do
  begin
    Check(SweepChars[a]);
    for b := 0 to 9 do
    begin
      Check(SweepChars[a] + SweepChars[b]);
      for c := 0 to 9 do
      begin
        Check(SweepChars[a] + SweepChars[b] + SweepChars[c]);
        for d := 0 to 9 do
          Check(SweepChars[a] + SweepChars[b] + SweepChars[c] + SweepChars[d]);
      end;
    end;
  end;
  for r := 0 to High(SweepReal) do
  begin
    for i := 0 to Length(SweepReal[r]) do
      for j := i to Length(SweepReal[r]) do
        for a := 0 to 7 do
          for b := 0 to 7 do
          begin
            { the first character goes in after i characters of the authority,
              the second after j of them -- so for i = j, both side by side. }
            s := SweepReal[r];
            ins := Copy(s, 1, i) + SweepChars[a] + Copy(s, i + 1, j - i) + SweepChars[b] +
                   Copy(s, j + 1, MaxInt);
            Check(ins);
          end;
  end;
  Result := ValStr(Format('checked=%d usable=%d refused=%d mismatches=%d',
                          [checked, usable, refused, bad]) + firsts[1] + firsts[2] + firsts[3]);
end;

procedure TV6Server.Serve(AFd: TSocket);
var
  h: TOpenSSLSocketHandler;
  st: TSocketStream;
  buf: array[0..8191] of Byte;
  n, hdrEnd, want, p, k: Integer;
  req, head, path, body, resp, chunk, status, extra, line: AnsiString;
  ch: AnsiChar;
  {$IFDEF WINDOWS}lw: array[0..1] of Word;{$ELSE}ll: array[0..1] of LongInt;{$ENDIF}
begin
  if Trickle then
  begin
    st := TSocketStream.Create(LongInt(AFd), nil);
    try
      n := st.Read(buf[0], SizeOf(buf));          // the ClientHello
      if n <= 0 then Exit;
      resp := Chr($16) + Chr($03) + Chr($03) + Chr($40) + Chr($00);
      if LateHeader then
      begin
        try
          Sleep(900);
          st.WriteBuffer(resp[1], Length(resp));
          Sleep(2000);
        except
          // the client gave up, which is the point
        end;
        Exit;
      end;
      st.WriteBuffer(resp[1], Length(resp));
      ch := Chr($02);
      try
        for k := 1 to 20 do
        begin
          Sleep(200);
          st.WriteBuffer(ch, 1);
        end;
      except
        // the client gave up, which is the point
      end;
    finally
      st.Free;
    end;
    Exit;
  end;
  if Tls then
  begin
    h := TOpenSSLSocketHandler.Create();
    h.CertificateData.Certificate.FileName := CertFile;
    h.CertificateData.PrivateKey.FileName := KeyFile;
    st := TSocketStream.Create(LongInt(AFd), h);
  end
  else
  begin
    h := nil;
    st := TSocketStream.Create(LongInt(AFd), nil);
  end;
  try
    if (h <> nil) and (not h.Accept()) then Exit;
    req := '';
    hdrEnd := 0;
    repeat
      n := st.Read(buf[0], SizeOf(buf));
      if n > 0 then
      begin
        SetString(chunk, PAnsiChar(@buf[0]), n);
        req := req + chunk;
      end;
      hdrEnd := Pos(#13#10#13#10, req);
    until (n <= 0) or (hdrEnd > 0);
    if hdrEnd = 0 then Exit;
    if Raw then
    begin
      { THE RAW ROUTES, matched anywhere in the request target, as the
        TFPHTTPServer routes are, so a request through a proxy -- whose target
        is the absolute url -- reaches them too:
          /b/c/d;p?q    302, Location: what raw_location$ last set
          /threecookies 302 setting SID=upper, sid=lower, THEME=x; Location /head
          /ctlcookie    302 setting bad=a<0x01>b and good=1; Location /head
          anything else 200, the body is the request head as it arrived: the
                        request line and every header line, each with its CR LF,
                        and not the blank line that ends the head. }
      head := Copy(req, 1, hdrEnd + 1);
      line := Copy(head, 1, Pos(#13, head) - 1);    // the request line
      path := ExtractWord(2, line, [' ']);
      extra := '';
      if Pos('/b/c/d;p?q', path) > 0 then
        extra := 'Location: ' + GRawLocation + #13#10
      else if Pos('/threecookies', path) > 0 then
        extra := 'Set-Cookie: SID=upper' + #13#10 + 'Set-Cookie: sid=lower' + #13#10 +
                 'Set-Cookie: THEME=x' + #13#10 + 'Location: /head' + #13#10
      else if Pos('/ctlcookie', path) > 0 then
        extra := 'Set-Cookie: bad=a' + Chr(1) + 'b' + #13#10 + 'Set-Cookie: good=1' +
                 #13#10 + 'Location: /head' + #13#10;
      if extra <> '' then
      begin
        status := '302 Found';
        resp := '';
      end
      else
      begin
        status := '200 OK';
        resp := head;
      end;
      resp := 'HTTP/1.1 ' + status + #13#10 + extra + 'Content-Length: ' +
              IntToStr(Length(resp)) + #13#10 + 'Connection: close' + #13#10#13#10 + resp;
      st.WriteBuffer(resp[1], Length(resp));
      Exit;
    end;
    head := Copy(req, 1, hdrEnd - 1);
    body := Copy(req, hdrEnd + 4, MaxInt);
    want := 0;
    p := Pos('content-length:', LowerCase(head));
    if p > 0 then
    begin
      line := Copy(head, p + 15, MaxInt);
      if Pos(#13, line) > 0 then line := Copy(line, 1, Pos(#13, line) - 1);
      want := StrToIntDef(Trim(line), 0);
    end;
    if Drain then
    begin
      { 128 KiB, then 600 ms, until the body is in or the client has gone. }
      k := Length(body);
      try
        while k < want do
        begin
          p := 0;
          while (p < 131072) and (k < want) do
          begin
            n := st.Read(buf[0], SizeOf(buf));
            if n <= 0 then Break;
            Inc(p, n);
            Inc(k, n);
          end;
          if n <= 0 then Break;
          Sleep(600);
        end;
        resp := 'HTTP/1.1 200 OK' + #13#10 + 'Content-Length: 2' + #13#10 +
                'Connection: close' + #13#10#13#10 + 'OK';
        st.WriteBuffer(resp[1], Length(resp));
      except
        // the client gave up, which is the point
      end;
      Exit;
    end;
    while Length(body) < want do
    begin
      n := st.Read(buf[0], SizeOf(buf));
      if n <= 0 then Break;
      SetString(chunk, PAnsiChar(@buf[0]), n);
      body := body + chunk;
    end;
    line := Copy(head, 1, Pos(#13, head + #13) - 1);   // the request line
    path := ExtractWord(2, line, [' ']);
    { /trickle: twenty bytes, one every 200 ms -- four seconds in all, and every
      read answered well inside any per-read timeout. Only a deadline on the
      WHOLE response bounds it. The client leaving early ends the writes. }
    { /silent: ten of a promised hundred bytes, then nothing for two seconds.
      /late: the same ten, one more byte at 900 ms, then nothing. A read timeout
      ends the first; only a read bounded by the deadline itself ends the second
      on time (2026-10-08, third adversarial pass). }
    { ANSWERS THAT BREAK OFF (fourth pass): each ends by closing -- a FIN, or a
      reset for /rst -- with no error the client's own reader raises. /chunkok and
      /closeok are the complete twins: a chunked body with its last chunk, and a
      body with no length that ends at the close, which is complete by RFC 9112. }
    if (path = '/shortclose') or (path = '/chunkcut') or (path = '/hdrcut') or
       (path = '/chunkok') or (path = '/closeok') or (path = '/rst') then
    begin
      if path = '/shortclose' then
        resp := 'HTTP/1.1 200 OK' + #13#10 + 'Content-Length: 100' + #13#10 +
                'Connection: close' + #13#10#13#10 + 'AAAAAAAAAA'
      else if path = '/chunkcut' then
        resp := 'HTTP/1.1 200 OK' + #13#10 + 'Transfer-Encoding: chunked' + #13#10 +
                'Connection: close' + #13#10#13#10 + 'a' + #13#10 + 'AAAAAAAAAA' +
                #13#10 + '64' + #13#10 + 'BBBBB'
      else if path = '/hdrcut' then
        resp := 'HTTP/1.1 200 OK' + #13#10 + 'Content-Length: 5' + #13#10
      else if path = '/chunkok' then
        resp := 'HTTP/1.1 200 OK' + #13#10 + 'Transfer-Encoding: chunked' + #13#10 +
                'Connection: close' + #13#10#13#10 + 'a' + #13#10 + 'AAAAAAAAAA' +
                #13#10 + '0' + #13#10#13#10
      else if path = '/closeok' then
        resp := 'HTTP/1.1 200 OK' + #13#10 + 'Connection: close' + #13#10#13#10 +
                'AAAAAAAAAA'
      else
        resp := 'HTTP/1.1 200 OK' + #13#10 + 'Content-Length: 100' + #13#10 +
                'Connection: close' + #13#10#13#10 + 'AAAAAAAAAA';
      try
        st.WriteBuffer(resp[1], Length(resp));
        if path = '/rst' then
        begin
          { A RESET 50 ms before a one-second deadline: the peer broke it off,
            however close the clock was. SO_LINGER on, zero seconds, then close. }
          Sleep(950);
          {$IFDEF WINDOWS}
          lw[0] := 1; lw[1] := 0;
          fpsetsockopt(AFd, SOL_SOCKET, SO_LINGER, @lw, SizeOf(lw));
          {$ELSE}
          ll[0] := 1; ll[1] := 0;
          fpsetsockopt(AFd, SOL_SOCKET, SO_LINGER, @ll, SizeOf(ll));
          {$ENDIF}
        end;
      except
        // the client gave up, which is the point
      end;
      Exit;
    end;
    if (path = '/silent') or (path = '/late') then
    begin
      resp := 'HTTP/1.1 200 OK' + #13#10 + 'Content-Length: 100' + #13#10 +
              'Connection: close' + #13#10#13#10 + 'AAAAAAAAAA';
      try
        st.WriteBuffer(resp[1], Length(resp));
        if path = '/late' then
        begin
          Sleep(900);
          ch := 'B';
          st.WriteBuffer(ch, 1);
        end;
        Sleep(2000);
      except
        // the client gave up, which is the point
      end;
      Exit;
    end;
    if path = '/trickle' then
    begin
      resp := 'HTTP/1.1 200 OK' + #13#10 + 'Content-Length: 20' + #13#10 +
              'Connection: close' + #13#10#13#10;
      st.WriteBuffer(resp[1], Length(resp));
      ch := 'x';
      try
        for k := 1 to 20 do
        begin
          Sleep(200);
          st.WriteBuffer(ch, 1);
        end;
      except
        // the client is gone, which is the point
      end;
      Exit;
    end;
    status := '200 OK';
    extra := '';
    if path = '/' then resp := 'phosphor http ok'
    else if path = '/family' then resp := 'ipv6'
    else if path = '/echo' then resp := body
    else if path = '/redir' then
    begin
      status := '302 Found';
      extra := 'Location: http://127.0.0.1:' + IntToStr(SRV_PORT) + '/' + #13#10;
      resp := '';
    end
    else
    begin
      status := '404 Not Found';
      resp := 'not found';
    end;
    resp := 'HTTP/1.1 ' + status + #13#10 + 'Content-Length: ' + IntToStr(Length(resp)) +
            #13#10 + extra + 'Connection: close' + #13#10#13#10 + resp;
    st.WriteBuffer(resp[1], Length(resp));
  finally
    st.Free;   // closes the descriptor and frees the handler
  end;
end;

function TestResolve6(const AHost: String): TStringDynArray;
var v: String;
    parts: TStringArray;
    i: Integer;
begin
  Inc(GResolve6Calls);
  Result := nil;
  if GResolve6Map = nil then Exit;
  v := GResolve6Map.Values[LowerCase(AHost)];
  if v = '' then Exit;
  parts := v.Split([',']);
  SetLength(Result, Length(parts));
  for i := 0 to High(parts) do Result[i] := Trim(parts[i]);
end;

{ http_resolve6_as$(host$, addrs$) -> addrs$. From now on host$ has exactly these
  IPv6 addresses (comma-separated, no brackets): PhosphorHttpLib's HttpResolve6Hook,
  the AAAA twin of http_resolve_as$. A host given none answers none. }
function f_http_resolve6_as(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if GResolve6Map = nil then GResolve6Map := TStringList.Create();
  GResolve6Map.Values[LowerCase(Args[0].Str)] := Args[1].Str;
  HttpResolve6Hook := @TestResolve6;
  Result := ValStr(Args[1].Str);
end;

{ http_resolve6_calls() -> how many AAAA lookups the package has made through the
  hook. A request carried by a proxy must make none: the proxy resolves, and a
  client that looked the name up itself would leak it to the local resolver. }
function f_http_resolve6_calls(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(GResolve6Calls);
end;

{ server_ipv6_name$() -> a name this OS's REAL resolver answers ::1 for: Linux's
  /etc/hosts names ::1 ip6-localhost, and Windows answers localhost's AAAA with
  ::1 itself. }
function f_server_ipv6_name(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  {$IFDEF WINDOWS}Result := ValStr('localhost');{$ELSE}Result := ValStr('ip6-localhost');{$ENDIF}
end;

{ http_resolve6_has_loopback(name$) -> 1 when the package's REAL AAAA resolver --
  the hook set aside for the call -- answers an address equal to ::1 for name$,
  else 0. Compared as addresses, because the text form the RTL writes ("::0001")
  is not the canonical one. }
function f_http_resolve6_has_loopback(const Args: array of TValue; out Err: TPhosphorError): TValue;
var
  saved: THttpResolveHook;
  got: TStringDynArray;
  i, j: Integer;
  a, lo: TIn6_Addr;
  same: Boolean;
begin
  Err := NoError();
  saved := HttpResolve6Hook;
  HttpResolve6Hook := nil;
  try
    got := HttpResolveAAAA(Args[0].Str);
  finally
    HttpResolve6Hook := saved;
  end;
  lo := StrToHostAddr6('::1');
  Result := ValInt(0);
  for i := 0 to High(got) do
  begin
    a := StrToHostAddr6(got[i]);
    same := True;
    for j := 0 to 7 do
      if a.u6_addr16[j] <> lo.u6_addr16[j] then same := False;
    if same then Exit(ValInt(1));
  end;
end;

{ server_url_ipv6$(which$) -> the base URL of an IPv6 server: "http" for plain,
  "https" for TLS with the localhost certificate, "https_ip" for TLS with the
  certificate that names ::1 -- all three at the literal [::1]. }
function f_server_url_ipv6(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if Args[0].Str = 'https' then Result := ValStr('https://[::1]:' + IntToStr(SRV_PORT_V6_TLS))
  else if Args[0].Str = 'https_ip' then Result := ValStr('https://[::1]:' + IntToStr(SRV_PORT_V6_TLS_IP))
  else if Args[0].Str = 'tlstrickle' then Result := ValStr('https://[::1]:' + IntToStr(SRV_PORT_V6_TLS_TRICKLE))
  else if Args[0].Str = 'tlslate' then Result := ValStr('https://[::1]:' + IntToStr(SRV_PORT_V6_TLS_LATE))
  else if Args[0].Str = 'drain' then Result := ValStr('http://[::1]:' + IntToStr(SRV_PORT_V6_DRAIN))
  else if Args[0].Str = 'relay' then Result := ValStr('https://[::1]:' + IntToStr(SRV_PORT_V6_RELAY))
  else Result := ValStr('http://[::1]:' + IntToStr(SRV_PORT_V6));
end;

{ server_url_mtls$() -> https://localhost on the server that REQUIRES a client
  certificate signed by the throwaway CA. Its own certificate is the localhost
  one, so with server_ca_file$ trusted the client verifies it end to end. }
function f_server_url_mtls(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValStr(BaseURLMtls);
end;

{ server_client_cert$(which$) -> the path of a client-certificate fixture: "cert",
  "key", or "combined" (certificate and key in one PEM). }
function f_server_client_cert(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if Args[0].Str = 'key' then Result := ValStr(CertDirG + 'tls_test_client_key.pem')
  else if Args[0].Str = 'combined' then Result := ValStr(CertDirG + 'tls_test_client_combined.pem')
  else Result := ValStr(CertDirG + 'tls_test_client_cert.pem');
end;

{ server_url_https_ip$() -> the base URL of a third server, same routes, whose
  certificate (same throwaway CA) carries IP:127.0.0.1 and no DNS name. With the CA
  trusted, https://127.0.0.1 there must verify and https://localhost must not -- the
  mirror of the first TLS server, and the case that tells an IP checked as an IP
  from an IP checked as a DNS name. }
function f_server_url_https_ip(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValStr(BaseURLHttpsIP);
end;

function WithholdHook(const AName: String): Boolean;
begin
  Result := (Withheld <> '') and (AName = Withheld);
end;

{ http_tls_withhold(name$) -> 1. From now on the package's hostname check finds
  that OpenSSL name missing (PhosphorHttpLib's HttpTlsWithhold seam). The check binds
  once per process, so a script must call this BEFORE its first https request. }
function f_http_tls_withhold(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Withheld := Args[0].Str;
  HttpTlsWithhold := @WithholdHook;
  Result := ValInt(1);
end;

type
  TOpenSSLVersionFn = function(t: cint): PAnsiChar; cdecl;

{ server_openssl_version$() -> the version string of the OpenSSL this process
  loaded for https ("OpenSSL 3.0.13 30 Jan 2024"), asked of the library itself.
  "" when none loaded. }
function f_server_openssl_version(const Args: array of TValue; out Err: TPhosphorError): TValue;
var fn: TOpenSSLVersionFn;
begin
  Err := NoError();
  Result := ValStr('');
  if not InitSSLInterface then Exit;
  fn := TOpenSSLVersionFn(GetProcedureAddress(SSLUtilHandle, 'OpenSSL_version'));
  if not Assigned(fn) then
    fn := TOpenSSLVersionFn(GetProcedureAddress(SSLUtilHandle, 'SSLeay_version'));
  if Assigned(fn) then Result := ValStr(String(fn(0)));
end;

{ server_openssl3_pair() -> 1 when this is 64-bit Windows and BOTH OpenSSL 3 DLLs
  load, 0 when it is Windows and they do not, -1 anywhere else. Asked here with
  LoadLibrary, independently of the package, so a test can derive which OpenSSL the
  package OUGHT to have loaded on Windows and compare it with the one it did. }
function f_server_openssl3_pair(const Args: array of TValue; out Err: TPhosphorError): TValue;
{$IFDEF WIN64}
var hs, hc: TLibHandle;
{$ENDIF}
begin
  Err := NoError();
  {$IFDEF WIN64}
  hc := LoadLibrary('libcrypto-3-x64.dll');
  hs := LoadLibrary('libssl-3-x64.dll');
  Result := ValInt(Ord((hc <> NilHandle) and (hs <> NilHandle)));
  if hs <> NilHandle then FreeLibrary(hs);
  if hc <> NilHandle then FreeLibrary(hc);
  {$ELSE}
  Result := ValInt(-1);
  {$ENDIF}
end;

{ Test-only: GET url$ but FORCE the candidate connect addresses (comma-separated),
  so the package's multi-address fallback can be proven deterministically -- no DNS,
  no real network. e.g. http_get_via$(url$, "127.0.0.9,127.0.0.1") must skip the dead
  loopback address and connect to the live server. Lives in the runner, not the
  package, so the package's BASIC API stays http_get$/http_status/http_post$. }
function f_http_get_via(const Args: array of TValue; out Err: TPhosphorError): TValue;
var addrs: TStringDynArray; status: Integer;
begin
  Err := NoError();
  addrs := SplitString(Args[1].Str, ',');
  { Short connect timeout: a dead loopback alias times out (rather than refusing) on
    Windows, and we don't want the fallback proof to wait seconds for that. }
  Result := ValStr(HttpFetch('GET', Args[0].Str, '', addrs, status, 800));
end;

{ Test-only: http_resolve_as$(host$, ip$) makes host$ resolve to ip$ for the rest
  of the run, through PhosphorHttpLib's resolver seam. The proxy test maps a
  destination name to a DEAD loopback address, so a request that went around the
  proxy -- dialling the destination itself -- fails, where one that used the
  proxy succeeds (ledger n26). Answers ip$. }
var
  GResolveMap: TStringList = nil;

function TestResolve(const AHost: String): TStringDynArray;
var ip: String;
    parts: TStringArray;
    i: Integer;
begin
  Result := nil;
  ip := GResolveMap.Values[LowerCase(AHost)];
  if ip = '' then Exit;
  parts := ip.Split([',']);     // several A records, in order
  SetLength(Result, Length(parts));
  for i := 0 to High(parts) do Result[i] := Trim(parts[i]);
end;

function f_http_resolve_as(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if GResolveMap = nil then GResolveMap := TStringList.Create();
  GResolveMap.Values[LowerCase(Args[0].Str)] := Args[1].Str;
  HttpResolveHook := @TestResolve;
  Result := ValStr(Args[1].Str);
end;

{ http_test_deadline(ms) -- run each request as if the budget had ms left (0:
  off), through the library's HttpDeadlineMs seam. Answers ms. }
function f_http_test_deadline(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  HttpDeadlineMs := Trunc(AsDouble(Args[0]));
  Result := ValInt(HttpDeadlineMs);
end;

{ http_test_spend(ms) -- charge the run's budget for ms of waiting, at the price
  pause() and a network wait pay, WITHOUT waiting: so a test can stand a request
  at the edge of the budget in no time. Answers 1 while the budget holds, 0 once
  this charge spent it. Test only (2026-10-08, second adversarial round). }
function f_http_test_spend(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(Ord(BudgetCharge(Trunc(AsDouble(Args[0])) * BudgetUnitsPerMs)));
end;

{ http_is_ipv4(host$) / http_is_ipv6(host$) -- 1 when the library takes host$ for
  an address of that family, which decides the certificate check and SNI. }
function f_http_is_ipv4(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(Ord(HttpIsIPv4Literal(Args[0].Str)));
end;

function f_http_is_ipv6(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(Ord(HttpIsIPv6Literal(Args[0].Str)));
end;

{ http_same_origin(a$, b$) -- 1 when a redirect from a$ to b$ keeps the caller's
  credentials, the library's own rule. }
function f_http_same_origin(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  Result := ValInt(Ord(HttpSameOrigin(Args[0].Str, Args[1].Str)));
end;

{ ---- the usual byte-exact package-test scaffolding -------------------------}

function ReadSource(const APath: String): String;
var fs: TFileStream; len: Int64;
begin
  Result := '';
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    len := fs.Size;
    SetLength(Result, len);
    if len > 0 then fs.ReadBuffer(Result[1], len);
  finally
    fs.Free;
  end;
  if (Length(Result) >= 3) and (Result[1] = #$EF) and
     (Result[2] = #$BB) and (Result[3] = #$BF) then
    Delete(Result, 1, 3);
end;

procedure WriteSummary;
var s: String;
begin
  s := 'passed: ' + IntToStr(AssertsPassed) + #10 +
       'failed: ' + IntToStr(AssertsFailed) + #10;
  FileWrite(StdOutputHandle, s[1], Length(s));
end;

var
  eng: TPhosphorEngine;
  srv, srvTls, srvTlsIP: TBoundHttpServer;
  srvMtls: TMutualTlsServer;
  v6Plain, v6Tls, v6TlsIP, v6Trickle, v6Late, v6Drain: TV6Server;
  relay: TRelay;
  raw: TV6Server;
  th, thTls, thTlsIP, thMtls: TServerThread;
  path, certDir: String;
  rc, i, waited: Integer;
begin
  {$IFDEF UNIX}
  { When a client aborts the TLS handshake (e.g. our verification refuses the
    self-signed cert), the server thread writes to a closed socket -> SIGPIPE, whose
    default action KILLS the process (exit 141). Ignore it so the write just fails;
    Windows has no SIGPIPE, hence this is Unix-only and 04_https passed there already. }
  fpSignal(SIGPIPE, SignalHandler(SIG_IGN));
  {$ENDIF}

  { --openssl-check : report (via exit code) whether the OpenSSL runtime can be loaded
    here, so the suite can library-gate the https test exactly on what this runner can
    do (exit 0 = available). }
  if ParamStr(1) = '--openssl-check' then
    Halt(Ord(not InitSSLInterface));

  if ParamCount < 1 then
  begin
    Writeln(StdErr, 'usage: phosphorhttptest <file.bas>');
    Halt(2);
  end;
  path := ParamStr(1);
  if (path <> '--serve') and (not FileExists(path)) then
  begin
    Writeln(StdErr, 'phosphorhttptest: file not found: ', path);
    Halt(2);
  end;

  BaseURL      := 'http://127.0.0.1:' + IntToStr(SRV_PORT);
  BaseURLHttps := 'https://127.0.0.1:' + IntToStr(SRV_PORT_TLS);
  BaseURLHttpsIP := 'https://127.0.0.1:' + IntToStr(SRV_PORT_TLS_IP);
  BaseURLMtls := 'https://localhost:' + IntToStr(SRV_PORT_MTLS);

  { Stand up the local server in a background thread. Bind loopback ONLY, so that a
    127.0.0.x address other than .1 is genuinely dead -- the fallback test relies on
    that to prove it skips a dead address. }
  InitCriticalSection(GSniLock);
  GSni := TStringList.Create();
  srv := TBoundHttpServer.Create(nil);
  srv.Address := '127.0.0.1';
  srv.Port := SRV_PORT;
  srv.Threaded := True;
  th := TServerThread.Create(True);
  th.Srv := srv;
  srv.OnRequest := @th.HandleRequest;
  th.FreeOnTerminate := False;
  th.Start;

  { A second server over TLS, same routes, using a checked-in test certificate
    (tls_test_cert.pem / _key.pem, alongside the .bas). Since m5 it is not
    self-signed: a throwaway CA (tls_test_ca.pem, whose key was discarded the day
    it was made) signed it for DNS:localhost only. Untrusted by default all the
    same, which is what 04_https needs; trusted through server_ca_file$, it lets
    15_https_hostname tell a right name from a wrong one on one chain. We load a fixture
    rather than auto-generating one at runtime: FPC 3.2.2's in-process X.509 generation
    uses OpenSSL APIs that OpenSSL 3 changed, so the auto-signed path silently produced
    no working cert on the OpenSSL-3 VM (the handshake then failed even with
    verification off). The fixture is a throwaway test credential, never a real one.
    The https test proves both that verification refuses this untrusted cert by default
    and that TLS works once verification is explicitly relaxed. }
  srvTls := TBoundHttpServer.Create(nil);
  srvTls.Address := '127.0.0.1';
  srvTls.Port := SRV_PORT_TLS;
  srvTls.Threaded := True;
  srvTls.UseSSL := True;
  certDir := ExtractFilePath(ExpandFileName(path));
  CAFile := certDir + 'tls_test_ca.pem';
  CertDirG := certDir;
  if FileExists(certDir + 'tls_test_cert.pem') then
  begin
    srvTls.CertificateData.Certificate.FileName := certDir + 'tls_test_cert.pem';
    srvTls.CertificateData.PrivateKey.FileName  := certDir + 'tls_test_key.pem';
  end;
  thTls := TServerThread.Create(True);
  thTls.Srv := srvTls;
  srvTls.OnRequest := @thTls.HandleRequest;
  thTls.FreeOnTerminate := False;
  thTls.Start;

  { The third: the same CA, a certificate for IP:127.0.0.1 and no DNS name. }
  srvTlsIP := TBoundHttpServer.Create(nil);
  srvTlsIP.Address := '127.0.0.1';
  srvTlsIP.Port := SRV_PORT_TLS_IP;
  srvTlsIP.Threaded := True;
  srvTlsIP.UseSSL := True;
  if FileExists(certDir + 'tls_test_ip_cert.pem') then
  begin
    srvTlsIP.CertificateData.Certificate.FileName := certDir + 'tls_test_ip_cert.pem';
    srvTlsIP.CertificateData.PrivateKey.FileName  := certDir + 'tls_test_ip_key.pem';
  end;
  thTlsIP := TServerThread.Create(True);
  thTlsIP.Srv := srvTlsIP;
  srvTlsIP.OnRequest := @thTlsIP.HandleRequest;
  thTlsIP.FreeOnTerminate := False;
  thTlsIP.Start;

  { The fourth: the localhost certificate, and a client certificate REQUIRED. }
  srvMtls := TMutualTlsServer.Create(nil);
  srvMtls.Address := '127.0.0.1';
  srvMtls.Port := SRV_PORT_MTLS;
  srvMtls.Threaded := True;
  srvMtls.UseSSL := True;
  if FileExists(certDir + 'tls_test_cert.pem') then
  begin
    srvMtls.CertificateData.Certificate.FileName := certDir + 'tls_test_cert.pem';
    srvMtls.CertificateData.PrivateKey.FileName  := certDir + 'tls_test_key.pem';
    srvMtls.CertificateData.CertCA.FileName      := certDir + 'tls_test_ca.pem';
  end;
  thMtls := TServerThread.Create(True);
  thMtls.Srv := srvMtls;
  srvMtls.OnRequest := @thMtls.HandleRequest;
  thMtls.FreeOnTerminate := False;
  thMtls.Start;

  { The three IPv6 servers (m6). }
  v6Plain := TV6Server.Create(True);
  v6Plain.Port := SRV_PORT_V6;
  v6Plain.FreeOnTerminate := False;
  v6Plain.Start;
  v6Tls := TV6Server.Create(True);
  v6Tls.Port := SRV_PORT_V6_TLS;
  v6Tls.Tls := True;
  v6Tls.CertFile := certDir + 'tls_test_cert.pem';
  v6Tls.KeyFile := certDir + 'tls_test_key.pem';
  v6Tls.FreeOnTerminate := False;
  v6Tls.Start;
  v6TlsIP := TV6Server.Create(True);
  v6TlsIP.Port := SRV_PORT_V6_TLS_IP;
  v6TlsIP.Tls := True;
  v6TlsIP.CertFile := certDir + 'tls_test_ip_cert.pem';
  v6TlsIP.KeyFile := certDir + 'tls_test_ip_key.pem';
  v6TlsIP.FreeOnTerminate := False;
  v6TlsIP.Start;
  v6Trickle := TV6Server.Create(True);
  v6Trickle.Port := SRV_PORT_V6_TLS_TRICKLE;
  v6Trickle.Trickle := True;
  v6Trickle.FreeOnTerminate := False;
  v6Trickle.Start;
  v6Late := TV6Server.Create(True);
  v6Late.Port := SRV_PORT_V6_TLS_LATE;
  v6Late.Trickle := True;
  v6Late.LateHeader := True;
  v6Late.FreeOnTerminate := False;
  v6Late.Start;
  v6Drain := TV6Server.Create(True);
  v6Drain.Port := SRV_PORT_V6_DRAIN;
  v6Drain.Drain := True;
  v6Drain.FreeOnTerminate := False;
  v6Drain.Start;
  relay := TRelay.Create(True);
  relay.Port := SRV_PORT_V6_RELAY;
  relay.Upstream := SRV_PORT_V6_TLS_IP;
  relay.FreeOnTerminate := False;
  relay.Start;
  raw := TV6Server.Create(True);
  raw.Raw := True;
  raw.Port := SRV_PORT_RAW;
  raw.FreeOnTerminate := False;
  raw.Start;

  { Wait for both sockets to be listening before the test fires requests. }
  waited := 0;
  while ((not srv.Active) or (not srvTls.Active) or (not srvTlsIP.Active) or
         (not srvMtls.Active) or (not v6Plain.Ready) or (not v6Tls.Ready) or
         (not v6TlsIP.Ready) or (not v6Trickle.Ready) or (not v6Late.Ready) or
         (not v6Drain.Ready) or (not relay.Ready) or (not raw.Ready)) and (waited < 3000) do
    begin Sleep(20); Inc(waited, 20); end;
  Sleep(150);

  { --serve: keep the server up so it can be inspected (curl) by hand. }
  if path = '--serve' then
  begin
    Writeln(StdErr, 'serving on ', BaseURL, ' for 20s'); Flush(StdErr);
    Sleep(20000);
    Halt(0);
  end;

  eng := TPhosphorEngine.Create();
  // A TEST RUNNER IS ALWAYS SANDBOXED, with no flag to turn it off. The suite
  // exists to run code that is being changed, which is exactly the code most
  // likely to name a path it did not mean to; on 2026-09-05 an unbounded run of a
  // defective dir_delete erased thirteen projects outside this checkout. The
  // working directory is the root -- every test writes under bin/ , which is
  // inside it -- so nothing a test names can resolve outside the checkout.
  eng.SandboxRoot := GetCurrentDir;
  // AND ALWAYS BUDGETED (ledger n17) -- the same ceiling, for the same reason,
  // as phosphorpkgtest.lpr, which says why. tests/packages/13_http_budget_live.bas
  // asserts it is armed in THIS runner, which a fix to the other would not reach.
  eng.MaxSteps := 1000000;

  try
    RegisterTestFuncs(eng.Registry);
    RegisterHttpFuncs(eng.Registry);
    eng.Registry.Add('server_url$:', @f_server_url);
    eng.Registry.Add('server_url_https$:', @f_server_url_https);
    eng.Registry.Add('server_ca_file$:', @f_server_ca_file);
    eng.Registry.Add('server_url_https_ip$:', @f_server_url_https_ip);
    eng.Registry.Add('server_url_mtls$:', @f_server_url_mtls);
    eng.Registry.Add('server_url_ipv6$:$', @f_server_url_ipv6);
    eng.Registry.Add('http_resolve6_as$:$$', @f_http_resolve6_as);
    eng.Registry.Add('server_ipv6_name$:', @f_server_ipv6_name);
    eng.Registry.Add('http_resolve6_calls:', @f_http_resolve6_calls);
    eng.Registry.Add('http_resolve6_has_loopback:$', @f_http_resolve6_has_loopback);
    eng.Registry.Add('server_client_cert$:$', @f_server_client_cert);
    eng.Registry.Add('http_tls_withhold:$', @f_http_tls_withhold);
    eng.Registry.Add('server_openssl_version$:', @f_server_openssl_version);
    eng.Registry.Add('server_openssl3_pair:', @f_server_openssl3_pair);
    eng.Registry.Add('http_get_via$:$$', @f_http_get_via);
    eng.Registry.Add('http_resolve_as$:$$', @f_http_resolve_as);
    eng.Registry.Add('http_test_deadline:n', @f_http_test_deadline);
    eng.Registry.Add('http_test_spend:n', @f_http_test_spend);
    eng.Registry.Add('http_is_ipv4:$', @f_http_is_ipv4);
    eng.Registry.Add('http_is_ipv6:$', @f_http_is_ipv6);
    eng.Registry.Add('http_same_origin:$$', @f_http_same_origin);
    eng.Registry.Add('raw_hits:', @f_raw_hits);
    eng.Registry.Add('raw_location$:$', @f_raw_location);
    eng.Registry.Add('server_url_raw$:', @f_server_url_raw);
    eng.Registry.Add('http_resolve_ref$:$$', @f_http_resolve_ref);
    eng.Registry.Add('http_wire_url$:$', @f_http_wire_url);
    eng.Registry.Add('http_url_sweep$:', @f_http_url_sweep);
    ResetTestState();
    rc := eng.Run(ReadSource(path));
    if rc <> 0 then
    begin
      Writeln(StdErr, Format('phosphorhttptest: %s:%d: %s', [path, eng.ErrorLine, eng.ErrorMessage]));
      WriteSummary();
      Halt(2);
    end;
    for i := 0 to Failures.Count - 1 do
      Writeln(StdErr, '  FAIL ', Failures[i]);
    WriteSummary();
    if AssertsFailed = 0 then Halt(0) else Halt(1);
  finally
    eng.Free;
    { The server thread is torn down by the process exit; no clean stop needed. }
  end;
end.
