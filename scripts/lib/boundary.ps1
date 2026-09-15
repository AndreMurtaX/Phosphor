<#
  The engine boundary check. DOT-SOURCED, never executed:

      . (Join-Path $PSScriptRoot 'lib/boundary.ps1')
      Assert-EngineBoundary (Join-Path $root 'engine')

  The PowerShell twin of scripts/lib/boundary.sh -- read that file for the two
  defects this pair exists to close and for why a single alternation is the fix
  rather than a different ordering of passes.

  The short form: there were four copies of this check and they scored 8/11 (bash)
  and 10/11 (PowerShell) against eleven cases in tests/boundary whose expected
  answers come from Pascal, not from any implementation. The bash halves never
  stripped (* *); all four stripped // before the block forms, which lets a brace
  comment lose its terminator to a // on the same line and then swallow a real
  uses clause. scripts/check-boundary.py runs this and its bash twin over those
  fixtures and fails if either slips or if the two stop agreeing.
#>

$script:BoundaryForbidden = @(
    'crt', 'video', 'keyboard', 'lcl', 'lclintf', 'lcltype', 'forms', 'controls',
    'dialogs', 'graphics', 'interfaces', 'windows', 'unix', 'baseunix'
)

# One pass, three comment forms, earliest-opening wins -- byte-for-byte the same
# alternation scripts/lib/boundary.sh hands to perl. The two tails let an
# unterminated comment run to end of file rather than falling through as code.
$script:BoundaryStrip = '//[^\n]*|\{[^}]*\}?|\(\*.*?(\*\)|\z)'

function Get-BoundaryFlat {
    param([Parameter(Mandatory = $true)] [string] $Path)
    $text = [System.IO.File]::ReadAllText($Path)
    $flat = [regex]::Replace($text, $script:BoundaryStrip, ' ',
                             [Text.RegularExpressions.RegexOptions]::Singleline)
    return ($flat -replace "`r?`n", ' ').ToLowerInvariant()
}

function Assert-EngineBoundary {
    param([Parameter(Mandatory = $true)] [string] $EngineDir)
    $violations = @()
    foreach ($src in Get-ChildItem -Path $EngineDir -Filter *.pas -Recurse) {
        $flat = Get-BoundaryFlat $src.FullName
        foreach ($u in $script:BoundaryForbidden) {
            if ($flat -match "uses[^;]*[ ,]$([regex]::Escape($u))[ ,;]") {
                $violations += "$($src.Name): uses '$u'"
            }
        }
    }
    if ($violations.Count -gt 0) {
        Write-Host 'BOUNDARY VIOLATION -- the engine reached a host/GUI unit:' -ForegroundColor Red
        $violations | ForEach-Object { Write-Host "  $_" }
        throw 'engine must stay host-agnostic (see docs/architecture.md)'
    }
    Write-Host 'boundary check: engine stays host-agnostic' -ForegroundColor DarkGray
}
