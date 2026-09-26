# ACC-G4 decision and read-only supplemental evidence inspection.
function Test-Task31EvidenceFile {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $file = Get-Item -LiteralPath $Path -ErrorAction Stop
        return [bool](-not $file.PSIsContainer -and $file.Length -gt 0)
    } catch {
        return $false
    }
}
function Get-Task31NegativeControls {
    param($Controls, [string] $BaseDirectory)
    return @($Controls | Where-Object { $null -ne $_ } | ForEach-Object {
        $evidencePath = [string]$_.evidence
        $evidencePresent = $false
        if (-not [string]::IsNullOrWhiteSpace($evidencePath)) {
            try {
                $resolvedEvidence = if ([System.IO.Path]::IsPathRooted($evidencePath)) {
                    [System.IO.Path]::GetFullPath($evidencePath)
                } else {
                    [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $evidencePath))
                }
                $evidencePresent = Test-Task31EvidenceFile -Path $resolvedEvidence
                $evidencePath = $resolvedEvidence
            } catch {
                $evidencePresent = $false
            }
        }
        [pscustomobject]@{ type = $_.type; turnedRed = $_.turnedRed; evidence = $evidencePath;
            evidencePresent = [bool]$evidencePresent }
    })
}
function Get-Task31Decision {
    param([Parameter(Mandatory)] $Summary)

    $required = @('1-1','1-2','2-1','3-1','4-1','4-2','4-3','4-4','5-1','5-2','5-3','5-4','6-4','7-4')
    $notApplicable = @('1-3','1-4','2-2','2-3','2-4','3-2','3-3','3-4','6-2','6-3','7-2','7-3')
    $gcReferences = @{ '6-1' = '6-4'; '7-1' = '7-4' }
    $negativeTypes = @('missing_bytes','corrupt_bytes','orphan')
    $failures = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    $records = @($Summary.results | Where-Object { $null -ne $_ })
    $expectedCells = @($required) + @($notApplicable) + @($gcReferences.Keys)

    if ($Summary.databaseInventoryUnchanged -isnot [bool] -or $Summary.databaseInventoryUnchanged -ne $true) { $failures.Add('数据库实例清单前后不一致或未核对') }
    if ($Summary.PSObject.Properties.Name -contains 'artifactStable' -and $Summary.artifactStable -ne $true) {
        $failures.Add('执行期 jar SHA-256 与已核构建制品不一致')
    }
    if (@($Summary.leftoverDatabases).Count -gt 0) { $failures.Add('存在残留隔离库') }
    $requested = @($Summary.requestedCells | Where-Object { $null -ne $_ })
    if ($requested.Count -ne 28 -or @($requested | Select-Object -Unique).Count -ne 28 -or
            @($requested | Where-Object { $_ -notin $expectedCells }).Count -gt 0) {
        $missing.Add('请求格子必须是规范中的完整28格且不得重复')
    }
    foreach ($record in $records) {
        $cell = [string]$record.cellId
        $run = [string]$record.run
        $checks = @($record.checks | Where-Object { $null -ne $_ })
        if ($record.verdict -match '异常|不符|失败' -or @($record.failedChecks | Where-Object { $null -ne $_ }).Count -gt 0 -or
                @($checks | Where-Object { $_.pass -is [bool] -and $_.pass -eq $false }).Count -gt 0) {
            $failures.Add("$cell r$run 明确失败、断言失败或执行异常")
        } elseif ($record.verdict -notin @('全有', '全无')) {
            $missing.Add("$cell r$run 未形成有效判定")
        }
        if ($checks.Count -eq 0 -or @($checks | Where-Object { $_.pass -isnot [bool] }).Count -gt 0) {
            $missing.Add("$cell r$run 缺有效判据记录")
        }
    }
    if ($records.Count -ne 42 -or @($records | Where-Object { $_.cellId -notin $required }).Count -gt 0) {
        $missing.Add('必须恰好有42次可达格运行，不能含额外或未知格')
    }
    foreach ($cell in $required) {
        $found = @($records | Where-Object { $_.cellId -eq $cell })
        if ($found.Count -ne 3 -or @($found | ForEach-Object { $_.run } | Select-Object -Unique).Count -ne 3 -or
                @($found | Where-Object { [string]$_.run -in @('1','2','3') -and $_.verdict -in @('全有','全无') }).Count -ne 3) {
            $missing.Add("$cell 少于3次有效独立运行")
        }
        if (@($found | ForEach-Object { $_.database } | Select-Object -Unique).Count -ne 3 -or
                @($found | ForEach-Object { $_.dataRoot } | Select-Object -Unique).Count -ne 3 -or
                @($found | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.database) -or [string]::IsNullOrWhiteSpace([string]$_.dataRoot) }).Count -gt 0) {
            $missing.Add("$cell 缺独立库或数据根")
        }
        foreach ($record in $found) {
            $snapshots = @($record.snapshots)
            if ($snapshots.Count -ne 4 -or @($snapshots | Select-Object -Unique).Count -ne 4 -or
                    @($snapshots | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0 -or
                    $record.evidenceFilesPresent -isnot [bool] -or $record.evidenceFilesPresent -ne $true) {
                $missing.Add("$cell r$($record.run) 三快照文件不全或路径不独立")
            }
            if ($cell -match '^[2347]-' -and ([string]::IsNullOrWhiteSpace([string]$record.blockEvidence) -or $record.blockEvidencePresent -isnot [bool] -or $record.blockEvidencePresent -ne $true)) {
                $missing.Add("$cell r$($record.run) 缺阻塞点证据")
            }
        }
    }
    if ($records.Count -eq 42) {
        foreach ($property in @('database','dataRoot')) {
            $values = @($records | ForEach-Object { $_.$property })
            $normalized = if ($property -eq 'dataRoot') {
                @($values | ForEach-Object { ([string]$_).Replace('/', '\').TrimEnd('\').ToUpperInvariant() })
            } else {
                @($values | ForEach-Object { ([string]$_).ToLowerInvariant() })
            }
            if (@($values | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0 -or
                    @($normalized | Select-Object -Unique).Count -ne 42) {
                $missing.Add("42次运行的 $property 必须全局唯一")
            }
        }
    }
    if (@($Summary.notApplicable | Where-Object { $null -ne $_ }).Count -ne 12 -or
            @($Summary.notApplicable | Where-Object { $null -ne $_ -and $_.cellId -notin $notApplicable }).Count -gt 0) {
        $missing.Add('不适用记录必须恰好为规范中的12格')
    }
    foreach ($cell in $notApplicable) {
        $entries = @($Summary.notApplicable | Where-Object { $_.CellId -eq $cell })
        if ($entries.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$entries[0].Reason)) {
            $missing.Add("$cell 缺不适用理由")
        }
    }
    if (@($Summary.gcReferences | Where-Object { $null -ne $_ }).Count -ne 2 -or
            @($Summary.gcReferences | Where-Object { $null -ne $_ -and $_.cellId -notin $gcReferences.Keys }).Count -gt 0) {
        $missing.Add('GC引用必须恰好为规范中的2格')
    }
    foreach ($cell in $gcReferences.Keys) {
        $source = $gcReferences[$cell]
        $entries = @($Summary.gcReferences | Where-Object { $_.cellId -eq $cell -and $_.sourceCellId -eq $source })
        $expectedReferences = @(1..3 | ForEach-Object { "$source/r$_" })
        $references = if ($entries.Count -eq 1) { @($entries[0].runEvidence) } else { @() }
        $sourceRuns = @($records | Where-Object { $_.cellId -eq $source -and $_.verdict -in @('全有','全无') })
        if ($entries.Count -ne 1 -or $references.Count -ne 3 -or
                @($references | Select-Object -Unique).Count -ne 3 -or
                @($references | Where-Object { $_ -notin $expectedReferences }).Count -gt 0 -or
                $sourceRuns.Count -ne 3 -or $entries[0].sourceCellId -ne $source) {
            $missing.Add("$cell 缺 $source 三次GC证据引用")
        }
    }
    if (@($Summary.negativeControls | Where-Object { $null -ne $_ -and $_.type -notin $negativeTypes }).Count -gt 0) {
        $missing.Add('负对照包含未知类型')
    }
    foreach ($type in $negativeTypes) {
        $entries = @($Summary.negativeControls | Where-Object { $_.type -eq $type })
        if (@($entries | Where-Object { $_.turnedRed -is [bool] -and $_.turnedRed -eq $false }).Count -gt 0) {
            $failures.Add("$type 负对照未变红")
        }
        if ($entries.Count -eq 0 -or @($entries | Where-Object {
                    $_.turnedRed -isnot [bool] -or $_.turnedRed -ne $true -or
                    [string]::IsNullOrWhiteSpace([string]$_.evidence) -or
                    $_.evidencePresent -isnot [bool] -or $_.evidencePresent -ne $true
                }).Count -gt 0) {
            $missing.Add("$type 缺变红证据")
        }
    }
    if (@($Summary.unimplementedCells).Count -gt 0) { $missing.Add('存在未实现执行器') }
    $exitCode = if ($failures.Count -gt 0) { 1 } elseif ($missing.Count -gt 0) { 2 } else { 0 }
    return [pscustomobject]@{
        exitCode = $exitCode
        status = @('PASS','FAIL','INCOMPLETE')[$exitCode]
        requiredIndependentCells = 14
        requiredRunsPerCell = 3
        failures = @($failures.ToArray())
        missing = @($missing.ToArray())
    }
}
