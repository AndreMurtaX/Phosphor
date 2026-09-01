{******************************************************************************
  Phosphor BASIC -- HTTP client (an OPT-IN host package)

  MIT License. Copyright (c) 2026 Andre Murta.

  An opt-in package (host/packages/, RegisterHttpFuncs) over FPC's TFPHTTPClient.
  Plain HTTP needs no external runtime library (only HTTPS would pull OpenSSL), so
  it is verified against reality with a local server the test spins up -- no network
  and no external dependency.

    http_get$(url$)          GET url$, return the response body (see contract below)
    http_status(url$)        GET url$, return the HTTP status code (0 on failure)
    http_post$(url$, body$)  POST body$ to url$, return the response body

  Contract: http_get$/http_post$ return the response body on a 2xx status and an
  empty string otherwise (an error status, or a transport failure) -- so pair them
  with http_status when the code matters. http_status returns the code for ANY
  response (2xx or not) and 0 only when the request could not complete. Nothing here
  raises: a 404 is an answer the BASIC program can inspect, not an exception.
******************************************************************************}
unit PhosphorHttpLib;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, fphttpclient,
  PhosphorValue, PhosphorErrors, PhosphorRegistry;

procedure RegisterHttpFuncs(Reg: TPhosphorRegistry);

implementation

{ TFPHTTPClient.Get / .Post RAISE on a non-2xx status. We do not want that -- a 404
  is an answer, not a Pascal exception the BASIC program can't see. So we pass a
  response stream and read the body (and the status code) AFTER swallowing any such
  raise: the client has already filled the stream and set ResponseStatusCode by the
  time it checks the code and throws. A genuine transport failure leaves the stream
  empty and the code 0, which is exactly the "" / 0 we answer with. }

function f_http_get(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TFPHTTPClient; resp: TStringStream;
begin
  Err := NoError;
  resp := TStringStream.Create('');
  c := TFPHTTPClient.Create(nil);
  try
    try c.Get(Args[0].Str, resp); except end;
    Result := ValStr(resp.DataString);
  finally
    c.Free;
    resp.Free;
  end;
end;

function f_http_status(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TFPHTTPClient; resp: TStringStream;
begin
  Err := NoError;
  resp := TStringStream.Create('');
  c := TFPHTTPClient.Create(nil);
  try
    try c.Get(Args[0].Str, resp); except end;
    Result := ValInt(c.ResponseStatusCode);
  finally
    c.Free;
    resp.Free;
  end;
end;

function f_http_post(const Args: array of TValue; out Err: TPhosphorError): TValue;
var c: TFPHTTPClient; resp: TStringStream;
begin
  Err := NoError;
  resp := TStringStream.Create('');
  c := TFPHTTPClient.Create(nil);
  try
    c.RequestBody := TStringStream.Create(Args[1].Str);
    try
      try c.Post(Args[0].Str, resp); except end;
      Result := ValStr(resp.DataString);
    finally
      c.RequestBody.Free;
      c.RequestBody := nil;
    end;
  finally
    c.Free;
    resp.Free;
  end;
end;

procedure RegisterHttpFuncs(Reg: TPhosphorRegistry);
begin
  Reg.Add('http_get$:$',     @f_http_get);
  Reg.Add('http_status:$',   @f_http_status);
  Reg.Add('http_post$:$$',   @f_http_post);
end;

end.
