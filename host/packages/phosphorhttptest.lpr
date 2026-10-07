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
  dynlibs, ctypes,
  PhosphorEngine, PhosphorValue, PhosphorErrors, PhosphorTestLib,
  PhosphorHttpLib;

const
  SRV_PORT     = 18099;
  SRV_PORT_TLS = 18443;
  SRV_PORT_TLS_IP = 18444;   // the same CA, a certificate for IP:127.0.0.1 only (m5)

var
  BaseURL: String;
  BaseURLHttps: String;
  CAFile: String;   // the throwaway CA the TLS fixture chains to (ledger m5)
  BaseURLHttpsIP: String;
  Withheld: String = '';   // http_tls_withhold's name, consulted by the library's seam

{ ---- the local test server -------------------------------------------------}

type
  { TFPHttpServer keeps Address (bind interface), UseSSL, and CertificateData
    protected; republish them so we can pin the server to loopback only (the fallback
    test needs a genuinely dead 127.0.0.x) and stand a second server up over TLS with
    an auto-generated self-signed certificate (the https test). }
  TBoundHttpServer = class(TFPHTTPServer)
  published
    property Address;
    property UseSSL;
    property CertificateData;
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

procedure TServerThread.HandleRequest(Sender: TObject;
  var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var path, m: String;
begin
  path := ARequest.PathInfo;
  m := ARequest.Method;
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
begin
  Result := nil;
  ip := GResolveMap.Values[LowerCase(AHost)];
  if ip <> '' then
  begin
    SetLength(Result, 1);
    Result[0] := ip;
  end;
end;

function f_http_resolve_as(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError();
  if GResolveMap = nil then GResolveMap := TStringList.Create();
  GResolveMap.Values[LowerCase(Args[0].Str)] := Args[1].Str;
  HttpResolveHook := @TestResolve;
  Result := ValStr(Args[1].Str);
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
  th, thTls, thTlsIP: TServerThread;
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

  { Stand up the local server in a background thread. Bind loopback ONLY, so that a
    127.0.0.x address other than .1 is genuinely dead -- the fallback test relies on
    that to prove it skips a dead address. }
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

  { Wait for both sockets to be listening before the test fires requests. }
  waited := 0;
  while ((not srv.Active) or (not srvTls.Active) or (not srvTlsIP.Active)) and (waited < 3000) do
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
    eng.Registry.Add('http_tls_withhold:$', @f_http_tls_withhold);
    eng.Registry.Add('server_openssl_version$:', @f_server_openssl_version);
    eng.Registry.Add('server_openssl3_pair:', @f_server_openssl3_pair);
    eng.Registry.Add('http_get_via$:$$', @f_http_get_via);
    eng.Registry.Add('http_resolve_as$:$$', @f_http_resolve_as);
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
