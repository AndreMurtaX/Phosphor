<#
  Shared argument handling for every test runner. DOT-SOURCED, never executed:

      . (Join-Path $PSScriptRoot 'lib\runner.ps1')
      Assert-RunnerArgs 'test-suite.ps1' prove   $args
      Assert-RunnerArgs 'test-gui.ps1'   noprove $args

  The PowerShell twin of scripts/lib/runner.sh -- see that file for the defect
  this pair exists to stop, measured on 2026-09-15.

  WHY NOT JUST [CmdletBinding()]. It does refuse an unknown named parameter, but
  it refuses with PowerShell's own wording and EXIT 1 -- the same code a genuinely
  failed run uses. A caller cannot tell "you typed the flag wrong" from "the suite
  failed", and a CI step that treats non-zero as failure hides the difference for
  good. So the runners drop CmdletBinding, extra tokens land in $args, and this
  says exit 2 with the same sentence its bash twin says.

  A note on the shape of the call: $args must be passed EXPLICITLY. It is an
  automatic variable scoped to the caller, so a function that read $args would
  read its own (empty) one and pass everything silently -- a guard that cannot
  fail, which is the class this whole exercise is about.
#>

# ---------------------------------------------------------------------------
# Assert-CleanBuild -- a -vewn build must be CLEAN, and the log is the only
# witness. See the long note in scripts/lib/runner.sh: fpc EXITS 0 ON A WARNING
# and still writes the binary, so a runner that judges by Test-Path or by the
# exit code cannot see one, and eight invocations across four runners did exactly
# that. Measured 2026-09-15: probe_budget.lpr(588,5) Warning: Comment level 2
# found, fpc exit 0, binary produced, suite green.
#
# The exclusion stays narrow on purpose -- Compiling and Linking are fpc's own
# progress lines. Widening it is how a real note hides in a noisy build.
function Assert-CleanBuild {
    param(
        [object[]] $Log,
        [Parameter(Mandatory = $true)] [string] $Label
    )
    $issues = $Log | Where-Object {
        "$_" -match '(?i)warning|note:|error|fatal' -and "$_" -notmatch 'Compiling|Linking'
    }
    if ($issues) {
        $issues | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "$Label build NOT clean"
    }
}

function Assert-RunnerArgs {
    param(
        [Parameter(Mandatory = $true)] [string] $Who,
        [Parameter(Mandatory = $true)] [ValidateSet('prove', 'noprove')] [string] $Mode,
        [object[]] $Extra
    )

    $script:RunnerProve = $false
    if (-not $Extra) { return }

    foreach ($a in $Extra) {
        $t = [string] $a
        switch -Regex ($t) {
            '^(--prove|--prove-failure|-ProveFailure)$' {
                if ($Mode -ne 'prove') {
                    [Console]::Error.WriteLine("${Who}: unknown argument '$t' -- this runner has no prove mode.")
                    [Console]::Error.WriteLine("${Who}: refusing rather than running the ordinary suite and")
                    [Console]::Error.WriteLine("${Who}: printing OK, which would read as a proof that happened.")
                    exit 2
                }
                $script:RunnerProve = $true
            }
            '^(--help|-h)$' {
                if ($Mode -eq 'prove') {
                    Write-Host "usage: $Who [-ProveFailure]"
                } else {
                    Write-Host "usage: $Who   (no arguments; this runner has no prove mode)"
                }
                exit 0
            }
            default {
                [Console]::Error.WriteLine("${Who}: unknown argument '$t'")
                if ($Mode -eq 'prove') {
                    [Console]::Error.WriteLine("${Who}: use -ProveFailure, or nothing.")
                } else {
                    [Console]::Error.WriteLine("${Who}: this runner takes no arguments.")
                }
                exit 2
            }
        }
    }
}
