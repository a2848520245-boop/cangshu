# Synthetic, database-free tests for the exact summary function used by verify-task31-matrix.ps1.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'task31-summary.ps1')
$required = @('1-1','1-2','2-1','3-1','4-1','4-2','4-3','4-4','5-1','5-2','5-3','5-4','6-4','7-4')
$na = @('1-3','1-4','2-2','2-3','2-4','3-2','3-3','3-4','6-2','6-3','7-2','7-3')
function New-CompleteSummary {
    $runs = foreach ($cell in $required) {
        foreach ($run in 1..3) {
            [pscustomobject]@{
                cellId = $cell; run = $run; verdict = '全有'; failedChecks = @()
                checks = @([pscustomobject]@{ pass = $true })
                database = "db_$($cell)_$run"; dataRoot = "root_$($cell)_$run"
                snapshots = @('index','before','after','restart')
                evidenceFilesPresent = $true
                blockEvidence = if ($cell -match '^[2347]-') { "block_$($cell)_$run" } else { '' }
                blockEvidencePresent = ($cell -match '^[2347]-')
            }
        }
    }
    return [pscustomobject]@{
        requestedCells = @($required) + @($na) + @('6-1','7-1')
        results = @($runs)
        notApplicable = @($na | ForEach-Object { [pscustomobject]@{ CellId = $_; Reason = '规范逐格理由' } })
        unimplementedCells = @()
        gcReferences = @(
            [pscustomobject]@{ cellId = '6-1'; sourceCellId = '6-4'; runEvidence = @('6-4/r1','6-4/r2','6-4/r3') },
            [pscustomobject]@{ cellId = '7-1'; sourceCellId = '7-4'; runEvidence = @('7-4/r1','7-4/r2','7-4/r3') }
        )
        negativeControls = @('missing_bytes','corrupt_bytes','orphan' | ForEach-Object {
            [pscustomobject]@{ type = $_; turnedRed = $true; evidence = "negative/$_"; evidencePresent = $true }
        })
        databaseInventoryUnchanged = $true
        leftoverDatabases = @()
    }
}
function Assert-Exit([string] $Case, $Summary, [int] $Expected) {
    $actual = Get-Task31Decision -Summary ($Summary | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
    if ($actual.exitCode -ne $Expected) { throw "$Case expected $Expected, got $($actual.exitCode): $($actual | ConvertTo-Json -Compress)" }
    Write-Host "PASS $Case exit=$Expected"
}
Assert-Exit 'complete' (New-CompleteSummary) 0
$s = New-CompleteSummary; $s.results[0].checks[0].pass = $false; Assert-Exit 'assertion failure' $s 1
$s = New-CompleteSummary; $s.results[0].verdict = '执行异常'; Assert-Exit 'execution exception' $s 1
$s = New-CompleteSummary; $s.unimplementedCells = @('5-2'); Assert-Exit 'unimplemented' $s 2
$s = New-CompleteSummary; $s.results = @($s.results | Where-Object { $_.cellId -ne '5-2' -or $_.run -ne 3 }); Assert-Exit 'too few runs' $s 2
$s = New-CompleteSummary; $s.notApplicable[0].Reason = ''; Assert-Exit 'missing N/A reason' $s 2
$s = New-CompleteSummary; $s.gcReferences[0].runEvidence = @('6-4/r1','6-4/r2'); Assert-Exit 'missing GC reference' $s 2
$s = New-CompleteSummary; $s.negativeControls = @($s.negativeControls | Where-Object { $_.type -ne 'orphan' }); Assert-Exit 'missing negative control' $s 2
$s = New-CompleteSummary; $s.negativeControls[0].turnedRed = $false; Assert-Exit 'negative did not turn red' $s 1
$s = New-CompleteSummary; $s.leftoverDatabases = @('cangshu_task31_leftover'); Assert-Exit 'leftover database' $s 1
$s = New-CompleteSummary; $s.databaseInventoryUnchanged = $false; Assert-Exit 'inventory anomaly' $s 1
$s = New-CompleteSummary; $s | Add-Member -NotePropertyName artifactStable -NotePropertyValue $false; Assert-Exit 'jar changed during execution' $s 1
$s = New-CompleteSummary; $s.results[0].checks = @(); Assert-Exit 'missing checks' $s 2
$s = New-CompleteSummary; $s.results[0].PSObject.Properties.Remove('checks'); Assert-Exit 'absent checks field' $s 2
$s = New-CompleteSummary; $s.results[0].checks[0].pass = 'true'; Assert-Exit 'nonboolean check' $s 2
$s = New-CompleteSummary; $s.results[0].snapshots = @('same','same','after','restart'); Assert-Exit 'duplicate snapshot' $s 2
$s = New-CompleteSummary; $s.results[0].evidenceFilesPresent = $false; Assert-Exit 'missing snapshot file' $s 2
$s = New-CompleteSummary; $s.results[0].run = 2; Assert-Exit 'duplicate run' $s 2
$s = New-CompleteSummary; $s.requestedCells = @($s.requestedCells | Where-Object { $_ -ne '7-4' }) + @('8-1'); Assert-Exit 'wrong requested cell' $s 2
$s = New-CompleteSummary; $s.gcReferences[0].runEvidence = @('6-4/r1','6-4/r2','fake/r3'); Assert-Exit 'fake GC reference' $s 2
$s = New-CompleteSummary; $s.results[1].database = $s.results[0].database; Assert-Exit 'cross-cell duplicate database' $s 2
$s = New-CompleteSummary; $s.results[1].dataRoot = $s.results[0].dataRoot; Assert-Exit 'cross-cell duplicate root' $s 2
$s = New-CompleteSummary; $s.results += $s.results[0]; Assert-Exit 'extra duplicate record' $s 2
$s = New-CompleteSummary; $s.results += [pscustomobject]@{ cellId='8-1'; run=1; verdict='全有'; checks=@([pscustomobject]@{pass=$true}) }; Assert-Exit 'unknown record' $s 2
$s = New-CompleteSummary; $s.results[0].evidenceFilesPresent = 'true'; Assert-Exit 'string snapshot evidence' $s 2
$s = New-CompleteSummary; $s.results[6].blockEvidencePresent = 'true'; Assert-Exit 'string block evidence' $s 2
$s = New-CompleteSummary; $s.databaseInventoryUnchanged = 'true'; Assert-Exit 'string inventory evidence' $s 1
$s = New-CompleteSummary; $s.negativeControls[0].turnedRed = 'true'; Assert-Exit 'string negative verdict' $s 2
$s = New-CompleteSummary; $s.negativeControls[0].evidencePresent = $false; Assert-Exit 'missing negative file' $s 2
$s = New-CompleteSummary; $s.negativeControls[0].evidencePresent = 'true'; Assert-Exit 'string negative file flag' $s 2
$s = New-CompleteSummary; $s.negativeControls += $s.negativeControls[0]; Assert-Exit 'repeat valid negative record' $s 0
$s = New-CompleteSummary; $s.notApplicable += [pscustomobject]@{ cellId='8-1'; Reason='fake' }; Assert-Exit 'extra N/A record' $s 2
$s = New-CompleteSummary; $s.gcReferences += [pscustomobject]@{ cellId='8-1'; sourceCellId='6-4'; runEvidence=@() }; Assert-Exit 'extra GC record' $s 2
Assert-Exit 'empty summary' ([pscustomobject]@{}) 1
$s = New-CompleteSummary; $s.results[0].checks = @([pscustomobject]@{}); Assert-Exit 'empty check object' $s 2
$s = New-CompleteSummary; $s.results[0].PSObject.Properties.Remove('run'); Assert-Exit 'absent run field' $s 2
$s = New-CompleteSummary; $s.results[0].PSObject.Properties.Remove('database'); Assert-Exit 'absent database field' $s 2
$s = New-CompleteSummary; $s.results[0].PSObject.Properties.Remove('dataRoot'); Assert-Exit 'absent root field' $s 2
$s = New-CompleteSummary; $s.results[1].dataRoot = ($s.results[0].dataRoot.ToUpperInvariant() + '/'); Assert-Exit 'normalized root duplicate' $s 2
$s = New-CompleteSummary; $s.results[0].dataRoot = 'C:\task31\same'; $s.results[1].dataRoot = 'c:/task31/same/'; Assert-Exit 'slash-equivalent root duplicate' $s 2
$s = New-CompleteSummary; $s.negativeControls += [pscustomobject]@{ type='unknown'; turnedRed=$true; evidence='x'; evidencePresent=$true }; Assert-Exit 'unknown negative type' $s 2
$s = New-CompleteSummary; $s.negativeControls += [pscustomobject]@{ type='orphan'; turnedRed=$false; evidence='x'; evidencePresent=$true }; Assert-Exit 'repeat negative failure' $s 1
$s = New-CompleteSummary; $s.results += [pscustomobject]@{}; Assert-Exit 'empty record object' $s 2
$s = New-CompleteSummary; $s.negativeControls[0].PSObject.Properties.Remove('evidence'); Assert-Exit 'absent negative evidence field' $s 2
$evidenceDir = Join-Path ([System.IO.Path]::GetTempPath()) ('task31-gate-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $evidenceDir | Out-Null
try {
    $present = Join-Path $evidenceDir 'present.txt'
    $empty = Join-Path $evidenceDir 'empty.txt'
    Set-Content -LiteralPath $present -Value 'red evidence' -Encoding UTF8
    [System.IO.File]::WriteAllBytes($empty, [byte[]]@())
    if (-not (Test-Task31EvidenceFile -Path $present) -or
            (Test-Task31EvidenceFile -Path $empty) -or
            (Test-Task31EvidenceFile -Path (Join-Path $evidenceDir 'absent.txt')) -or
            (Test-Task31EvidenceFile -Path $evidenceDir)) {
        throw 'snapshot/block evidence leaf and nonempty inspection mismatch'
    }
    Write-Host 'PASS snapshot/block leaf/nonempty/missing/directory inspection'
    $controls = @('present.txt','empty.txt','absent.txt' | ForEach-Object {
        [pscustomobject]@{ type = 'orphan'; turnedRed = $true; evidence = $_; evidencePresent = $true }
    })
    $inspected = @(Get-Task31NegativeControls -Controls $controls -BaseDirectory $evidenceDir)
    if ($inspected.Count -ne 3 -or $inspected[0].evidencePresent -ne $true -or
            $inspected[1].evidencePresent -ne $false -or $inspected[2].evidencePresent -ne $false) {
        throw 'negative evidence file inspection mismatch'
    }
    Write-Host 'PASS supplemental leaf/nonempty/missing file inspection'
} finally {
    Remove-Item -LiteralPath $present, $empty -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $evidenceDir -Force -ErrorAction SilentlyContinue
}
$matrixPath = Join-Path $PSScriptRoot 'verify-task31-matrix.ps1'
$tokens = $null; $parseErrors = $null
$matrixAst = [System.Management.Automation.Language.Parser]::ParseFile($matrixPath, [ref]$tokens, [ref]$parseErrors)
$referenceBranches = @($matrixAst.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text.Contains("`$cellId -in @('6-1','7-1')")
}, $true))
$runnerBranches = @($matrixAst.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text.Contains('if (-not $cellRunners.ContainsKey($cellId))')
}, $true))
if (@($parseErrors).Count -gt 0 -or $referenceBranches.Count -ne 1 -or $runnerBranches.Count -ne 1 -or
        $referenceBranches[0].Extent.StartOffset -ge $runnerBranches[0].Extent.StartOffset -or
        -not $referenceBranches[0].Extent.Text.Contains('continue')) {
    throw 'matrix GC reference branch must skip runner registration before missing-runner branch'
}
Write-Host 'PASS matrix GC reference control flow AST'
Write-Host 'task31-summary synthetic cases: 47 passed'
