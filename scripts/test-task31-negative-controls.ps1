# 纯 mock/临时文件验证负对照编排；不会连接数据库、启动应用或执行 VM。
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'task31-negative-controls.ps1')
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('task31-negative-mock-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

try {
    $script:invocationId = 'mockrun'
    $script:ownedProcesses = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
    $script:ownedDatabases = [System.Collections.Generic.HashSet[string]]::new()
    $payloadPath = Join-Path $testRoot 'payload.bin'
    [System.IO.File]::WriteAllBytes($payloadPath, [byte[]](1,2,3,4,5,6,7,8))
    $digest = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $payload = [pscustomobject]@{ Path=$payloadPath; Digest=$digest; SizeBytes=8 }
    $resourceId = '00000000-0000-0000-0000-000000000001'

    function Assert-IsolatedDatabaseName { param([string] $DatabaseName)
        if ($DatabaseName -notmatch '^mockprefix_mockrun_neg_(missing_bytes|corrupt_bytes|orphan)$') {
            throw "非隔离库名：$DatabaseName"
        }
    }
    function New-SeededResource { param([string] $DatabaseName, [string] $DataRoot,
            [int] $ServerPort, [string] $RunDirectory, $Payload)
        if ($script:failSeed) { throw 'mock seed failed' }
        $script:ownedDatabases.Add($DatabaseName) | Out-Null
        $blob = Get-Task31NegativeBlobPath -DataRoot $DataRoot -Digest $Payload.Digest
        New-Item -ItemType Directory -Path (Split-Path -Parent $blob) -Force | Out-Null
        Copy-Item -LiteralPath $Payload.Path -Destination $blob
        $resource = if ($script:legacyShape) {
            [pscustomobject]@{ resourceId=$script:resourceId; digest=$Payload.Digest }
        } else {
            [pscustomobject]@{
                id=$script:resourceId; hash=[pscustomobject]@{algorithm='sha256';digest=$Payload.Digest}
                sizeBytes=$Payload.SizeBytes; contentId='00000000-0000-0000-0000-000000000002'
            }
        }
        return [pscustomobject]@{
            Serve=[pscustomobject]@{ Stdout=(Join-Path $RunDirectory 'serve.log') }
            Uri='http://127.0.0.1:' + $ServerPort + '/api/resources'
            Resource=$resource
        }
    }
    function Save-Snapshot { param([string] $Label, [string] $RunDirectory,
            [string] $DatabaseName, [string] $DataRoot, [int] $ServerPort, [string[]] $Extra)
        $path = Join-Path $RunDirectory ('snapshot-' + $Label + '.txt')
        Set-Content -LiteralPath $path -Value ("snapshot=$Label") -Encoding UTF8
        return [pscustomobject]@{ Path=$path }
    }
    function Get-DatabaseState { param([string] $DatabaseName)
        if ($script:caseType -eq 'corrupt_bytes' -and $script:gcDone) {
            return @('content|RECLAIMING','location|-','resource|-','counts|content=1,location=0,resource=0')
        }
        if ($script:caseType -eq 'corrupt_bytes') {
            return @('content|RECLAIM_PENDING','location|seed','resource|-','counts|content=1,location=1,resource=0')
        }
        return @('content|READY','location|seed','resource|READY','counts|content=1,location=1,resource=1')
    }
    function Get-DataRootTree { param([string] $DataRoot) return @('mock-tree') }
    function Get-HttpStatus { param([string] $Method, [string] $Uri, [int] $TimeoutSeconds,
            [string] $OutFile)
        $script:requests += [pscustomobject]@{ Method=$Method; Uri=$Uri }
        if ($Uri -like '*/content') {
            Assert-True ($Uri -eq ('http://127.0.0.1:19001/api/resources/' + $script:resourceId + '/content')) `
                '缺字节下载 URI 未使用真实响应 id'
            Set-Content -LiteralPath $OutFile -Value '{"code":"INTERNAL_ERROR"}' -Encoding UTF8
            return [pscustomobject]@{ Status='500'; ExitCode=0 }
        }
        if ($Uri -like '*/trash?confirm=true') { return [pscustomobject]@{ Status='200'; ExitCode=0 } }
        Assert-True ($Uri -eq ('http://127.0.0.1:19001/api/resources/' + $script:resourceId)) `
            '软删 URI 未使用真实响应 id'
        return [pscustomobject]@{ Status='204'; ExitCode=0 }
    }
    function Get-LogText { param([string] $Path) return 'CANGSHU|alert|contentId=mock 字节缺失' }
    function Stop-ServeGracefully { param($Run) return 0 }
    function Invoke-CliMode { param([string] $DatabaseName, [string] $DataRoot,
            [int] $ServerPort, [string] $Mode, [string] $RunDirectory)
        if ($Mode -eq 'gc') {
            $script:gcDone = $true
            return [pscustomobject]@{ ExitCode=4;
                Stdout='CANGSHU|alert|BYTE_MISMATCH 停止本轮删除 gc|byteMismatch=1'; LogPath='mock-gc.log' }
        }
        $candidate = Get-ChildItem -LiteralPath (Join-Path $DataRoot 'sha256') -Recurse -File |
            Where-Object { $_.Name -ne $script:payload.Digest } | Select-Object -First 1
        if (-not $candidate) { throw 'mock orphan candidate absent' }
        $key = [System.IO.Path]::GetRelativePath($DataRoot, $candidate.FullName)
        $target = Join-Path (Join-Path $DataRoot 'orphan') $key
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Move-Item -LiteralPath $candidate.FullName -Destination $target
        return [pscustomobject]@{ ExitCode=0; Stdout='reconcile|orphanQuarantined=1'; LogPath='mock-reconcile.log' }
    }
    function Remove-IsolatedDatabase { param([string] $DatabaseName)
        if (-not $script:ownedDatabases.Remove($DatabaseName)) { throw "清理未确权库：$DatabaseName" }
    }

    $script:payload = $payload
    $script:resourceId = $resourceId
    $script:requests = @()
    $results = @()
    foreach ($type in @('missing_bytes','corrupt_bytes','orphan')) {
        $script:caseType = $type
        $script:gcDone = $false
        $caseDirectory = Join-Path $testRoot $type
        New-Item -ItemType Directory -Path $caseDirectory | Out-Null
        $result = Invoke-Task31NegativeCase -Type $type -RunDirectory $caseDirectory `
            -DatabaseName ('mockprefix_mockrun_neg_' + $type) -ServerPort 19001 -Payload $payload
        Assert-True ($result.turnedRed -is [bool] -and $result.turnedRed) "$type 未变红"
        Assert-True ((Test-Path -LiteralPath $result.evidence -PathType Leaf) -and
            [System.IO.Path]::IsPathRooted($result.evidence)) "$type 证据路径无效"
        $results += $result
    }
    Assert-True ($results.Count -eq 3 -and $script:ownedDatabases.Count -eq 0) '三类结果或隔离库清理错误'
    Assert-True (@($script:requests | Where-Object { $_.Uri -match '/api/resources/.+/content$' }).Count -eq 1) `
        '缺字节下载路径未执行'
    Assert-True (@($script:requests | Where-Object { $_.Method -eq 'DELETE' -and
        $_.Uri -eq ('http://127.0.0.1:19001/api/resources/' + $resourceId) }).Count -eq 1) `
        '坏字节软删路径未执行'

    $script:failSeed = $true
    $failedDirectory = Join-Path $testRoot 'failed-seed'
    New-Item -ItemType Directory -Path $failedDirectory | Out-Null
    $failure = Invoke-Task31NegativeCase -Type 'missing_bytes' -RunDirectory $failedDirectory `
        -DatabaseName 'mockprefix_mockrun_neg_missing_bytes' -ServerPort 19002 -Payload $payload
    Assert-True ($failure.turnedRed -is [bool] -and -not $failure.turnedRed) '异常被误判 PASS'
    Assert-True ((Get-Content -LiteralPath $failure.evidence -Raw) -match 'mock seed failed') '异常原文未入证据'

    $script:failSeed = $false
    $script:legacyShape = $true
    $legacyDirectory = Join-Path $testRoot 'legacy-response'
    New-Item -ItemType Directory -Path $legacyDirectory | Out-Null
    $legacy = Invoke-Task31NegativeCase -Type 'missing_bytes' -RunDirectory $legacyDirectory `
        -DatabaseName 'mockprefix_mockrun_neg_missing_bytes' -ServerPort 19003 -Payload $payload
    Assert-True ($legacy.turnedRed -is [bool] -and -not $legacy.turnedRed) '旧响应形状被误判 PASS'
    Assert-True ((Get-Content -LiteralPath $legacy.evidence -Raw) -match '前置上传响应不符合') `
        '旧响应形状错误未入证据'

    # 公开入口只验证编排、独立目录/库名；每类真实分支已在上方用 mock helper + 文件夹具运行。
    function Invoke-Task31NegativeCase { param([string] $Type, [string] $RunDirectory,
            [string] $DatabaseName, [int] $ServerPort, $Payload)
        $script:publicCalls += [pscustomobject]@{ Type=$Type; Directory=$RunDirectory; Database=$DatabaseName; Port=$ServerPort }
        $path = Join-Path $RunDirectory 'evidence.txt'
        Set-Content -LiteralPath $path -Value 'mock public call' -Encoding UTF8
        return [pscustomobject]@{ type=$Type; turnedRed=$true; evidence=$path }
    }
    $script:publicCalls = @()
    $publicRoot = Join-Path $testRoot 'public'
    New-Item -ItemType Directory -Path $publicRoot | Out-Null
    $public = @(Invoke-Task31NegativeControls -OutputRoot $publicRoot -DatabasePrefix 'mockprefix' `
        -BaseServerPort 19000 -Payload $payload)
    Assert-True ($public.Count -eq 3 -and @($script:publicCalls.Database | Select-Object -Unique).Count -eq 3) `
        '公开入口未形成三类独立库'
    Assert-True (@($script:publicCalls.Directory | Select-Object -Unique).Count -eq 3) '公开入口共用目录'
    Assert-True (@($script:publicCalls | Where-Object { $_.Database -notmatch '^mockprefix_mockrun_neg_' }).Count -eq 0) `
        '公开入口库名不合规则'
    Write-Host 'PASS task31 negative controls: three mock cases, failure evidence, isolated orchestration'
} finally {
    $temp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $actual = [System.IO.Path]::GetFullPath($testRoot)
    if (-not $actual.StartsWith($temp, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not ((Split-Path -Leaf $actual) -like 'task31-negative-mock-*')) {
        throw "拒绝清理非本测试目录：$actual"
    }
    Remove-Item -LiteralPath $actual -Recurse -Force
}
