{******************************************************************************
  Phosphor BASIC -- engine facade (the public seam of the library)

  MIT License
  Copyright (c) 2026 Andre Murta

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
*******************************************************************************

  The engine is a LIBRARY from day one. It knows nothing about consoles, files,
  windows or the LCL: every byte it wants to show the outside world leaves
  through the OnOutput callback, and the host decides where it lands. This is
  the boundary the whole project is built to keep, and scripts/build.ps1 fails
  the build if any engine unit reaches for a host or GUI unit.

  WALKING SKELETON -- READ THIS

  This build is NOT the interpreter. It recognizes exactly one thing: PRINT and
  PRINTLN of a string literal, plus REM / ' comments and blank lines. It exists
  only to prove three things end to end before the real work starts:

    1. the host<->engine seam (all I/O through OnOutput, no I/O in the engine);
    2. UTF-8 preserved byte-for-byte from source literal to output;
    3. the compile -> link -> run -> golden-compare path.

  The lexer, parser, exec core and the five-type value model all land in phase 1
  proper and replace everything below. Nothing here is meant to survive.
******************************************************************************}
unit PhosphorEngine;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils;

const
  PhosphorVersion = '0.0.1';

type
  { Output sink. The engine hands finished text to the host and forgets it.
    PRINTLN puts the trailing LF into the text it emits; PRINT does not. The
    host writes the bytes verbatim -- it never has to know about line endings. }
  TPhosphorOutputProc = procedure(const AText: String) of object;

  { TPhosphorEngine -- the public API. See the skeleton note at the top of the
    unit: today this only understands PRINT / PRINTLN. }
  TPhosphorEngine = class
  private
    FOnOutput: TPhosphorOutputProc;
    FErrorLine: Integer;
    FErrorMessage: String;
    procedure Emit(const AText: String);
    function RunLine(const ALine: String): Boolean;
  public
    constructor Create;
    { Runs ASource (UTF-8 bytes). Returns 0 on success, or the 1-based number of
      the line that first failed; ErrorMessage then explains it. }
    function Run(const ASource: String): Integer;
    property OnOutput: TPhosphorOutputProc read FOnOutput write FOnOutput;
    property ErrorLine: Integer read FErrorLine;
    property ErrorMessage: String read FErrorMessage;
  end;

implementation

constructor TPhosphorEngine.Create;
begin
  inherited Create;
  FOnOutput := nil;
  FErrorLine := 0;
  FErrorMessage := '';
end;

procedure TPhosphorEngine.Emit(const AText: String);
begin
  if Assigned(FOnOutput) then
    FOnOutput(AText);
end;

{ Case-insensitive keyword test with an ASCII word boundary. LowerCase on a
  UTF-8 AnsiString only touches A-Z (bytes < $80), so it can never corrupt a
  multibyte sequence, and we only ever compare the ASCII keyword prefix here. }
function KeywordAt(const S, AKeyword: String): Boolean;
var
  n: Integer;
  after: Char;
begin
  n := Length(AKeyword);
  if Length(S) < n then
    Exit(False);
  if LowerCase(Copy(S, 1, n)) <> AKeyword then
    Exit(False);
  if Length(S) = n then
    Exit(True);
  after := S[n + 1];
  Result := (after = ' ') or (after = #9) or (after = '"');
end;

{ Extracts the bytes between the first and last double quote on the line. The
  bytes are a slice of the original UTF-8 string, so nothing is transcoded. }
function LiteralOf(const S: String; out ALiteral: String): Boolean;
var
  first, last, i: Integer;
begin
  first := 0;
  last := 0;
  for i := 1 to Length(S) do
    if S[i] = '"' then
    begin
      if first = 0 then
        first := i;
      last := i;
    end;
  if (first = 0) or (last <= first) then
    Exit(False);
  ALiteral := Copy(S, first + 1, last - first - 1);
  Result := True;
end;

function TPhosphorEngine.RunLine(const ALine: String): Boolean;
var
  line, trimmed, literal: String;
begin
  line := ALine;
  { Tolerate CRLF sources: drop a trailing CR before matching. }
  if (Length(line) > 0) and (line[Length(line)] = #13) then
    SetLength(line, Length(line) - 1);

  trimmed := Trim(line);
  if trimmed = '' then
    Exit(True);
  if trimmed[1] = '''' then
    Exit(True);
  if KeywordAt(trimmed, 'rem') then
    Exit(True);

  if KeywordAt(trimmed, 'println') then
  begin
    if not LiteralOf(trimmed, literal) then
    begin
      FErrorMessage := 'PRINTLN expects a "string literal" (skeleton stub)';
      Exit(False);
    end;
    Emit(literal + #10);
    Exit(True);
  end;

  if KeywordAt(trimmed, 'print') then
  begin
    if not LiteralOf(trimmed, literal) then
    begin
      FErrorMessage := 'PRINT expects a "string literal" (skeleton stub)';
      Exit(False);
    end;
    Emit(literal);
    Exit(True);
  end;

  FErrorMessage := 'Syntax error: the skeleton stub understands only ' +
                   'PRINT / PRINTLN "literal", REM and '' comments';
  Result := False;
end;

function TPhosphorEngine.Run(const ASource: String): Integer;
var
  i, start, lineNo: Integer;
begin
  FErrorLine := 0;
  FErrorMessage := '';
  lineNo := 0;
  start := 1;
  { Split on LF by hand rather than through TStringList, so the byte content of
    each line is a plain slice and never runs through a codepage conversion. }
  for i := 1 to Length(ASource) + 1 do
    if (i > Length(ASource)) or (ASource[i] = #10) then
    begin
      Inc(lineNo);
      if not RunLine(Copy(ASource, start, i - start)) then
      begin
        FErrorLine := lineNo;
        Exit(lineNo);
      end;
      start := i + 1;
    end;
  Result := 0;
end;

end.
