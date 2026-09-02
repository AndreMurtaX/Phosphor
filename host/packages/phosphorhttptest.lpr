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
  PhosphorEngine, PhosphorValue, PhosphorErrors, PhosphorTestLib,
  PhosphorHttpLib;

const
  SRV_PORT     = 18099;
  SRV_PORT_TLS = 18443;

var
  BaseURL: String;
  BaseURLHttps: String;

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
  if ((path = '/') or (path = '')) and (m = 'GET') then
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
  Err := NoError;
  Result := ValStr(BaseURL);
end;

{ server_url_https$() -> the base URL of the local TLS server (self-signed cert). }
function f_server_url_https(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  Result := ValStr(BaseURLHttps);
end;

{ Test-only: GET url$ but FORCE the candidate connect addresses (comma-separated),
  so the package's multi-address fallback can be proven deterministically -- no DNS,
  no real network. e.g. http_get_via$(url$, "127.0.0.9,127.0.0.1") must skip the dead
  loopback address and connect to the live server. Lives in the runner, not the
  package, so the package's BASIC API stays http_get$/http_status/http_post$. }
function f_http_get_via(const Args: array of TValue; out Err: TPhosphorError): TValue;
var addrs: TStringDynArray; status: Integer;
begin
  Err := NoError;
  addrs := SplitString(Args[1].Str, ',');
  { Short connect timeout: a dead loopback alias times out (rather than refusing) on
    Windows, and we don't want the fallback proof to wait seconds for that. }
  Result := ValStr(HttpFetch('GET', Args[0].Str, '', addrs, status, 800));
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
  srv, srvTls: TBoundHttpServer;
  th, thTls: TServerThread;
  path: String;
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

  { A second server over TLS, same routes, with an auto-generated self-signed
    certificate (UseSSL + empty CertificateData). The https test proves both that
    verification refuses this untrusted cert by default and that TLS works once
    verification is explicitly relaxed. }
  srvTls := TBoundHttpServer.Create(nil);
  srvTls.Address := '127.0.0.1';
  srvTls.Port := SRV_PORT_TLS;
  srvTls.Threaded := True;
  srvTls.UseSSL := True;
  thTls := TServerThread.Create(True);
  thTls.Srv := srvTls;
  srvTls.OnRequest := @thTls.HandleRequest;
  thTls.FreeOnTerminate := False;
  thTls.Start;

  { Wait for both sockets to be listening before the test fires requests. }
  waited := 0;
  while ((not srv.Active) or (not srvTls.Active)) and (waited < 3000) do
    begin Sleep(20); Inc(waited, 20); end;
  Sleep(150);

  { --serve: keep the server up so it can be inspected (curl) by hand. }
  if path = '--serve' then
  begin
    Writeln(StdErr, 'serving on ', BaseURL, ' for 20s'); Flush(StdErr);
    Sleep(20000);
    Halt(0);
  end;

  eng := TPhosphorEngine.Create;
  try
    RegisterTestFuncs(eng.Registry);
    RegisterHttpFuncs(eng.Registry);
    eng.Registry.Add('server_url$:', @f_server_url);
    eng.Registry.Add('server_url_https$:', @f_server_url_https);
    eng.Registry.Add('http_get_via$:$$', @f_http_get_via);
    ResetTestState;
    rc := eng.Run(ReadSource(path));
    if rc <> 0 then
    begin
      Writeln(StdErr, Format('phosphorhttptest: %s:%d: %s', [path, eng.ErrorLine, eng.ErrorMessage]));
      WriteSummary;
      Halt(2);
    end;
    for i := 0 to Failures.Count - 1 do
      Writeln(StdErr, '  FAIL ', Failures[i]);
    WriteSummary;
    if AssertsFailed = 0 then Halt(0) else Halt(1);
  finally
    eng.Free;
    { The server thread is torn down by the process exit; no clean stop needed. }
  end;
end.
