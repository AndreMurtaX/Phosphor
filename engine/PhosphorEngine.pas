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
  PhosphorArrayLib, PhosphorDictLib, PhosphorStrListLib, PhosphorStrLib, PhosphorNumLib,
  PhosphorJsonLib, PhosphorDateTimeLib, PhosphorRegexLib, PhosphorIoLib, PhosphorConfigLib,
  PhosphorSysLib, PhosphorPlatformLib, PhosphorCallLib, PhosphorErrLib;

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
    FMaxSteps: Int64;
    FMaxOutputBytes: Int64;
    FTimeoutMs: Int64;
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
    { Execution ceilings for running untrusted scripts; 0 (the default) = no limit.
      A ceiling is fatal -- ON ERROR cannot catch it -- so a script cannot escape
      it. LastError.Code is peLimit when one is hit. }
    property MaxSteps: Int64 read FMaxSteps write FMaxSteps;
    property MaxOutputBytes: Int64 read FMaxOutputBytes write FMaxOutputBytes;
    property TimeoutMs: Int64 read FTimeoutMs write FTimeoutMs;
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
  RegisterJsonFuncs(FRegistry);
  RegisterDateTimeFuncs(FRegistry);
  RegisterRegexFuncs(FRegistry);
  RegisterIoFuncs(FRegistry);
  RegisterConfigFuncs(FRegistry);
  RegisterSysFuncs(FRegistry);
  RegisterPlatformFuncs(FRegistry);
  RegisterCallFuncs(FRegistry);
  RegisterErrFuncs(FRegistry);
  FOnOutput := nil;
  FErrorLine := 0;
  FErrorMessage := '';
  FLastError := NoError;
  FMaxSteps := 0;
  FMaxOutputBytes := 0;
  FTimeoutMs := 0;
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
    vm.MaxSteps := FMaxSteps;
    vm.MaxOutputBytes := FMaxOutputBytes;
    vm.TimeoutMs := FTimeoutMs;
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
