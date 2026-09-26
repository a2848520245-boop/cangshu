# 任务 31 三类真实负对照。由 verify-task31-matrix.ps1 dot-source；复用其隔离库和确权进程 helper。
function Get-Task31NegativeBlobPath {
    param([string] $DataRoot, [string] $Digest)
    if ($Digest -notmatch '^[0-9a-f]{64}$') { throw '负对照载荷摘要不是小写 SHA-256' }
    return Join-Path $DataRoot ('sha256/' + $Digest.Substring(0, 2) + '/' +
        $Digest.Substring(2, 2) + '/' + $Digest)
}

function Invoke-Task31NegativeCase {
    param([ValidateSet('missing_bytes','corrupt_bytes','orphan')] [string] $Type,
        [string] $RunDirectory, [string] $DatabaseName, [int] $ServerPort, $Payload)

    $dataRoot = Join-Path $RunDirectory 'data-root'
    $evidence = [System.IO.Path]::GetFullPath((Join-Path $RunDirectory 'evidence.txt'))
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("type=$Type")
    $lines.Add("database=$DatabaseName")
    $lines.Add("dataRoot=$dataRoot")
    $lines.Add("serverPort=$ServerPort")
    $turnedRed = $false
    $ownedProcessStart = $ownedProcesses.Count
    try {
        Assert-IsolatedDatabaseName -DatabaseName $DatabaseName
        $seed = New-SeededResource -DatabaseName $DatabaseName -DataRoot $dataRoot `
            -ServerPort $ServerPort -RunDirectory $RunDirectory -Payload $Payload
        $resourceId = [string]$seed.Resource.id
        $parsedId = [guid]::Empty
        if (-not [guid]::TryParse($resourceId, [ref]$parsedId) -or
            $seed.Resource.hash.algorithm -ne 'sha256' -or
            $seed.Resource.hash.digest -ne $Payload.Digest -or
            $seed.Resource.sizeBytes -ne $Payload.SizeBytes -or
            -not $seed.Resource.contentId) {
            throw '前置上传响应不符合 05 §3.1：需要 id、hash.algorithm、hash.digest、sizeBytes、contentId'
        }
        $blob = Get-Task31NegativeBlobPath -DataRoot $dataRoot -Digest $Payload.Digest
        if (-not (Test-Path -LiteralPath $blob -PathType Leaf)) { throw "前置上传字节缺失：$blob" }
        $before = Save-Snapshot -Label 'before-injection' -RunDirectory $RunDirectory `
            -DatabaseName $DatabaseName -DataRoot $dataRoot -ServerPort $ServerPort
        $lines.Add("beforeSnapshot=$($before.Path)")
        switch ($Type) {
            'missing_bytes' {
                # 只删本例刚上传、位于确权数据根中的内容键。
                Remove-Item -LiteralPath $blob -Force
                $body = Join-Path $RunDirectory 'download-error.json'
                $download = Get-HttpStatus -Method 'GET' `
                    -Uri ($seed.Uri + '/' + $resourceId + '/content') -OutFile $body
                $bodyText = if (Test-Path -LiteralPath $body) { Get-Content -LiteralPath $body -Raw -Encoding UTF8 } else { '' }
                $serveLog = Get-LogText -Path $seed.Serve.Stdout
                $state = @(Get-DatabaseState -DatabaseName $DatabaseName)
                $tree = @(Get-DataRootTree -DataRoot $dataRoot)
                $lines.Add("downloadHttp=$($download.Status)|curlExit=$($download.ExitCode)")
                $lines.Add("downloadBody=$bodyText")
                $lines.Add('databaseState=' + ($state -join ';'))
                $lines.Add('dataTree=' + ($tree -join ';'))
                $lines.Add("serveLog=$($seed.Serve.Stdout)")
                $after = Save-Snapshot -Label 'after-injection' -RunDirectory $RunDirectory `
                    -DatabaseName $DatabaseName -DataRoot $dataRoot -ServerPort $ServerPort `
                    -Extra @("downloadHttp=$($download.Status)", "downloadBody=$bodyText")
                $lines.Add("afterSnapshot=$($after.Path)")
                $turnedRed = [bool](
                    $download.ExitCode -eq 0 -and $download.Status -eq '500' -and
                    $bodyText -match 'INTERNAL_ERROR' -and $serveLog -match 'CANGSHU\|alert\|.*字节缺失' -and
                    -not (Test-Path -LiteralPath $blob) -and
                    ($state -join ';') -match 'counts\|content=1,location=1,resource=1')
            }
            'corrupt_bytes' {
                $soft = Get-HttpStatus -Method 'DELETE' -Uri ($seed.Uri + '/' + $resourceId) `
                    -OutFile (Join-Path $RunDirectory 'soft-delete.json')
                $empty = Get-HttpStatus -Method 'DELETE' -Uri ($seed.Uri + '/trash?confirm=true') `
                    -OutFile (Join-Path $RunDirectory 'empty-trash.json')
                $pending = @(Get-DatabaseState -DatabaseName $DatabaseName)
                if ($soft.Status -ne '204' -or $empty.Status -ne '200' -or
                    ($pending -join ';') -notmatch 'content\|RECLAIM_PENDING' -or
                    ($pending -join ';') -notmatch 'counts\|content=1,location=1,resource=0') {
                    throw "GC 前置未成立：soft=$($soft.Status),empty=$($empty.Status),state=$($pending -join ';')"
                }
                Stop-ServeGracefully -Run $seed.Serve | Out-Null
                $stream = [System.IO.File]::Open($blob, [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                try {
                    $first = $stream.ReadByte()
                    if ($first -lt 0) { throw '拒绝修改空载荷' }
                    $stream.Position = 0
                    $stream.WriteByte([byte]($first -bxor 255))
                } finally { $stream.Dispose() }
                $corruptDigest = (Get-FileHash -LiteralPath $blob -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($corruptDigest -eq $Payload.Digest) { throw '坏字节注入未改变摘要' }
                $gc = Invoke-CliMode -DatabaseName $DatabaseName -DataRoot $dataRoot `
                    -ServerPort $ServerPort -Mode 'gc' -RunDirectory $RunDirectory
                $state = @(Get-DatabaseState -DatabaseName $DatabaseName)
                $tree = @(Get-DataRootTree -DataRoot $dataRoot)
                $lines.Add("gcExit=$($gc.ExitCode)|gcLog=$($gc.LogPath)")
                $lines.Add("gcStdout=$($gc.Stdout)")
                $lines.Add('databaseState=' + ($state -join ';'))
                $lines.Add('dataTree=' + ($tree -join ';'))
                $after = Save-Snapshot -Label 'after-injection' -RunDirectory $RunDirectory `
                    -DatabaseName $DatabaseName -DataRoot $dataRoot -ServerPort $ServerPort `
                    -Extra @("gcExit=$($gc.ExitCode)", "corruptDigest=$corruptDigest")
                $lines.Add("afterSnapshot=$($after.Path)")
                $turnedRed = [bool](
                    $gc.ExitCode -ne 0 -and $gc.Stdout -match 'CANGSHU\|alert\|.*BYTE_MISMATCH' -and
                    $gc.Stdout -match '停止本轮删除' -and
                    $gc.Stdout -match 'byteMismatch=1' -and
                    (Test-Path -LiteralPath $blob -PathType Leaf) -and
                    (Get-FileHash -LiteralPath $blob -Algorithm SHA256).Hash.ToLowerInvariant() -eq $corruptDigest -and
                    ($state -join ';') -match 'content\|RECLAIMING' -and
                    ($state -join ';') -notmatch 'content\|RECLAIMED')
            }
            'orphan' {
                Stop-ServeGracefully -Run $seed.Serve | Out-Null
                $orphanBytes = [System.IO.File]::ReadAllBytes($Payload.Path)
                if ($orphanBytes.Length -eq 0) { throw '孤儿负对照载荷为空' }
                $orphanBytes[0] = [byte]($orphanBytes[0] -bxor 255)
                $hash = [System.Security.Cryptography.SHA256]::HashData($orphanBytes)
                $orphanDigest = [Convert]::ToHexString($hash).ToLowerInvariant()
                $orphanKey = 'sha256/' + $orphanDigest.Substring(0, 2) + '/' +
                    $orphanDigest.Substring(2, 2) + '/' + $orphanDigest
                $orphanBlob = Join-Path $dataRoot $orphanKey
                if (Test-Path -LiteralPath $orphanBlob) { throw "拒绝覆盖孤儿候选：$orphanBlob" }
                New-Item -ItemType Directory -Path (Split-Path -Parent $orphanBlob) -Force | Out-Null
                [System.IO.File]::WriteAllBytes($orphanBlob, $orphanBytes)
                $beforeState = @(Get-DatabaseState -DatabaseName $DatabaseName)
                $reconcile = Invoke-CliMode -DatabaseName $DatabaseName -DataRoot $dataRoot `
                    -ServerPort $ServerPort -Mode 'reconcile' -RunDirectory $RunDirectory
                $isolated = Join-Path (Join-Path $dataRoot 'orphan') $orphanKey
                $afterState = @(Get-DatabaseState -DatabaseName $DatabaseName)
                $tree = @(Get-DataRootTree -DataRoot $dataRoot)
                $lines.Add("reconcileExit=$($reconcile.ExitCode)|reconcileLog=$($reconcile.LogPath)")
                $lines.Add("reconcileStdout=$($reconcile.Stdout)")
                $lines.Add('databaseBefore=' + ($beforeState -join ';'))
                $lines.Add('databaseAfter=' + ($afterState -join ';'))
                $lines.Add('dataTree=' + ($tree -join ';'))
                $after = Save-Snapshot -Label 'after-injection' -RunDirectory $RunDirectory `
                    -DatabaseName $DatabaseName -DataRoot $dataRoot -ServerPort $ServerPort `
                    -Extra @("reconcileExit=$($reconcile.ExitCode)", "orphanDigest=$orphanDigest")
                $lines.Add("afterSnapshot=$($after.Path)")
                $turnedRed = [bool](
                    $reconcile.ExitCode -eq 0 -and $reconcile.Stdout -match 'orphanQuarantined=1' -and
                    -not (Test-Path -LiteralPath $orphanBlob) -and
                    (Test-Path -LiteralPath $isolated -PathType Leaf) -and
                    (Get-FileHash -LiteralPath $isolated -Algorithm SHA256).Hash.ToLowerInvariant() -eq $orphanDigest -and
                    ($afterState -join ';') -eq ($beforeState -join ';'))
            }
        }
    } catch {
        $turnedRed = $false
        $lines.Add('exception=' + $_.Exception.ToString())
    } finally {
        for ($index = $ownedProcessStart; $index -lt $ownedProcesses.Count; $index++) {
            $process = $ownedProcesses[$index]
            try {
                if (-not $process.HasExited) {
                    Stop-Process -Id $process.Id -Force -ErrorAction Stop
                    if (-not $process.WaitForExit(30000)) { throw "进程 $($process.Id) 未在30秒内退出" }
                }
            } catch {
                $turnedRed = $false
                $lines.Add('processCleanupFailure=' + $_.Exception.ToString())
            }
        }
        if ($ownedDatabases.Contains($DatabaseName)) {
            try { Remove-IsolatedDatabase -DatabaseName $DatabaseName }
            catch {
                $turnedRed = $false
                $lines.Add('databaseCleanupFailure=' + $_.Exception.ToString())
            }
        }
    }
    $lines.Add("turnedRed=$turnedRed")
    Set-Content -LiteralPath $evidence -Value $lines -Encoding UTF8
    return [pscustomobject]@{ type = $Type; turnedRed = [bool]$turnedRed; evidence = $evidence }
}

function Invoke-Task31NegativeControls {
    param([string] $OutputRoot, [string] $DatabasePrefix, [int] $BaseServerPort, $Payload)
    $root = [System.IO.Path]::GetFullPath($OutputRoot)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "输出根不存在：$root" }
    $controlRoot = Join-Path $root ('negative-controls-' + [guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $controlRoot) { throw "拒绝覆盖负对照目录：$controlRoot" }
    New-Item -ItemType Directory -Path $controlRoot | Out-Null
    $results = foreach ($type in @('missing_bytes', 'corrupt_bytes', 'orphan')) {
        $runDirectory = Join-Path $controlRoot $type
        if (Test-Path -LiteralPath $runDirectory) { throw "拒绝覆盖负对照目录：$runDirectory" }
        New-Item -ItemType Directory -Path $runDirectory | Out-Null
        $databaseName = $DatabasePrefix + '_' + $invocationId + '_neg_' + $type
        $serverPort = $BaseServerPort + 1000 + @{'missing_bytes'=1;'corrupt_bytes'=2;'orphan'=3}[$type]
        Invoke-Task31NegativeCase -Type $type -RunDirectory $runDirectory `
            -DatabaseName $databaseName -ServerPort $serverPort -Payload $Payload
    }
    return @($results)
}
