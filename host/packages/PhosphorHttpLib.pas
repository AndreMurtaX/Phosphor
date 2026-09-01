{******************************************************************************
  Phosphor BASIC -- HTTP client (an OPT-IN host package)

  MIT License. Copyright (c) 2026 Andre Murta.

  An opt-in package (host/packages/, RegisterHttpFuncs) over FPC's TFPHTTPClient.
  Plain HTTP needs no external runtime library (only HTTPS would pull OpenSSL), so
  it is verified against reality with a local server the test spins up -- no network
  and no external dependency.

    http_get$(url$)          GET url$, return the response body
    http_status(url$)        GET url$, return the HTTP status code (0 on failure)
    http_post$(url$, body$)  POST body$ to url$, return the response body

  Contract: http_get$/http_post$ return the response body for ANY status (the body of
  an error response too -- pair with http_status when the code matters). http_status
  returns the code for any response, and 0 only when the request could not complete.
  Nothing here raises: a 404 is an answer the BASIC program inspects, not an exception.

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
  SysUtils, Classes, Types, fphttpclient, ssockets, resolve, sockets, URIParser,
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

type
  { TFPHTTPClient derives BOTH the connect target and the Host: header from the request
    URI. Overriding ConnectToServer lets us dial one chosen IP while SendRequest keeps
    building Host: from the original URI -- the seam the fallback needs. }
  TPinnedClient = class(TFPHTTPClient)
  public
    ConnectIP: String;
  protected
    procedure ConnectToServer(const AHost: String; APort: Integer;
      UseSSL: Boolean = False); override;
  end;

procedure TPinnedClient.ConnectToServer(const AHost: String; APort: Integer;
  UseSSL: Boolean);
begin
  if ConnectIP <> '' then
    inherited ConnectToServer(ConnectIP, APort, UseSSL)
  else
    inherited ConnectToServer(AHost, APort, UseSSL);
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
    host := ParseURI(AUrl).Host;
    if (host = '') or IsIPv4Literal(host) then
    begin
      SetLength(addrs, 1);
      addrs[0] := '';                 // dial the URL's host as written
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

procedure RegisterHttpFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('http_get$:$',     @f_http_get);
  Reg.Add('http_status:$',   @f_http_status);
  Reg.Add('http_post$:$$',   @f_http_post);
end;

end.
