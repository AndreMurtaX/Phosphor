{******************************************************************************
  Phosphor BASIC -- engine facade (the public seam of the library)

  MIT License. Copyright (c) 2026 Andre Murta.

  The engine is a library: it knows nothing about consoles, files, windows or the
  LCL. Everything it shows the outside world leaves through OnOutput; a host
  registers function packages into Registry. This replaces the phase-0 walking
  skeleton (which understood only PRINT/PRINTLN of a literal) with the real
  pipeline: lexer -> compiler -> stack VM over the five-kind value model.

  Run returns 0 on success, or the 1-based source line of the first error;
  ErrorMessage then explains it. Errors are reported, not raised.
******************************************************************************}
unit PhosphorEngine;

{$mode objfpc}{$H+}{$J-}
{$codepage UTF8}

interface

uses
  SysUtils,
  PhosphorValue, PhosphorErrors, PhosphorOpcodes, PhosphorRegistry,
  PhosphorCompiler, PhosphorVM, PhosphorHandles,
  // library packages (engine/libs)
  PhosphorArrayLib, PhosphorDictLib, PhosphorStrListLib, PhosphorStrLib, PhosphorNumLib;

const
  PhosphorVersion = '0.0.1';

type
  EPhosphorInternal = class(Exception);

  TPhosphorEngine = class
  private
    FRegistry: TPhosphorRegistry;
    FOnOutput: TPhosphorOutputProc;
    FErrorLine: Integer;
    FErrorMessage: String;
    FLastError: TPhosphorError;
  public
    constructor Create;
    destructor Destroy; override;
    { Compile and run ASource (UTF-8). 0 on success; otherwise the 1-based line
      of the first error (ErrorMessage explains it). }
    function Run(const ASource: String): Integer;
    property Registry: TPhosphorRegistry read FRegistry;
    property OnOutput: TPhosphorOutputProc read FOnOutput write FOnOutput;
    property ErrorLine: Integer read FErrorLine;
    property ErrorMessage: String read FErrorMessage;
    property LastError: TPhosphorError read FLastError;
  end;

implementation

constructor TPhosphorEngine.Create;
begin
  inherited Create;
  // Fire loudly if an opcode was renumbered -- a silent bytecode-format break.
  if not VerifyOpcodeNumbering then
    raise EPhosphorInternal.Create('opcode numbering is corrupt (see PhosphorOpcodes)');
  FRegistry := TPhosphorRegistry.Create;
  RegisterArrayFuncs(FRegistry);   // built-in library packages (engine/libs)
  RegisterDictFuncs(FRegistry);
  RegisterStrListFuncs(FRegistry);
  RegisterStrFuncs(FRegistry);
  RegisterNumFuncs(FRegistry);
  FOnOutput := nil;
  FErrorLine := 0;
  FErrorMessage := '';
  FLastError := NoError;
end;

destructor TPhosphorEngine.Destroy;
begin
  FRegistry.Free;
  inherited Destroy;
end;

function TPhosphorEngine.Run(const ASource: String): Integer;
var
  comp: TPhosphorCompiler;
  vm: TPhosphorVM;
  prog: TProgram;
begin
  FErrorLine := 0;
  FErrorMessage := '';
  FLastError := NoError;
  ResetHandles;   // no handles leak between programs

  comp := TPhosphorCompiler.Create;
  try
    if not comp.Compile(ASource, prog) then
    begin
      FErrorMessage := comp.ErrorMessage;
      FErrorLine := comp.ErrorLine;
      if FErrorLine = 0 then FErrorLine := 1;
      FLastError := MakeError(peSyntax, FErrorMessage);
      Exit(FErrorLine);
    end;
  finally
    comp.Free;
  end;

  vm := TPhosphorVM.Create;
  try
    vm.Registry := FRegistry;
    vm.OnOutput := FOnOutput;
    if not vm.Run(prog) then
    begin
      FLastError := vm.LastError;
      FErrorMessage := vm.LastError.Message;
      FErrorLine := vm.ErrorLine;
      if FErrorLine = 0 then FErrorLine := 1;
      Exit(FErrorLine);
    end;
    Result := 0;
  finally
    vm.Free;
    prog.Free;
  end;
end;

end.
