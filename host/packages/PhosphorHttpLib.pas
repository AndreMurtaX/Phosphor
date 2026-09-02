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
  SysUtils, Classes, Types, fphttpclient, opensslsockets, openssl, ssockets,
  sslsockets, sslbase, resolve, sockets, URIParser,
  PhosphorValue, PhosphorErrors, PhosphorRegistry;

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
  Err := NoError;
  Result := ValStr(HttpFetch('GET', Args[0].Str, '', [], status));
end;

function f_http_status(const Args: array of TValue; out Err: TPhosphorError): TValue;
var status: Integer;
begin
  Err := NoError;
  HttpFetch('GET', Args[0].Str, '', [], status);
  Result := ValInt(status);
end;

function f_http_post(const Args: array of TValue; out Err: TPhosphorError): TValue;
var status: Integer;
begin
  Err := NoError;
  Result := ValStr(HttpFetch('POST', Args[0].Str, Args[1].Str, [], status));
end;

{ http_verify_peer(on%) -- turn https certificate verification on (default) or off.
  Off is a deliberate, explicit choice for a self-signed dev server; it is never the
  default. Returns the value it set. }
function f_http_verify_peer(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  gVerifyPeer := AsDouble(Args[0]) <> 0;
  Result := ValInt(Ord(gVerifyPeer));
end;

{ http_ca_file$(path$) -- point verification at a specific CA bundle (PEM). Mainly for
  platforms without a system bundle in a standard place (e.g. Windows). Returns path$. }
function f_http_ca_file(const Args: array of TValue; out Err: TPhosphorError): TValue;
begin
  Err := NoError;
  gCAFile := Args[0].Str;
  Result := ValStr(gCAFile);
end;

procedure RegisterHttpFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('http_get$:$',       @f_http_get);
  Reg.Add('http_status:$',     @f_http_status);
  Reg.Add('http_post$:$$',     @f_http_post);
  Reg.Add('http_verify_peer:n', @f_http_verify_peer);
  Reg.Add('http_ca_file$:$',   @f_http_ca_file);
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
  gCAFile := LocateCABundle;

end.
