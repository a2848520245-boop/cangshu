<#
.SYNOPSIS
    任务 31 门槛四注入矩阵取证（08-验收规范 §3／§3.1 四类 × 七点 × 每格 3 次 ＋ 负对照）。

.DESCRIPTION
    全部在隔离库上操作（库名形如 cangshu_task31_<点>_<类>_r<序>，自建自删），绝不触碰
    cangshu / cangshu_test / cangshu_m1demo / cangshu_m1 / 各 *_u?demo / cangshu_task4_bench。

    逐格口径以 08 §3.1（块 #^clt6-cells，2026-09-22 裁决）为唯一权威依据：
      · 每格 3 次有效运行（未命中该格即重跑、不计次）；
      · 每格独立库 ＋ 独立数据根；
      · 三快照＝快照1 杀前 / 快照2 杀后不重启（只读核对）/ 快照3 重启后对账收敛；
      · 点 2／3／4／7 需注入的格子必须附阻塞点证据（pg_locks / pg_stat_activity 原文），
        无证据该格不计次；
      · 不可达格一律「不适用 ＋ 理由」，禁止删格、缩类、缩点；
      · ④ 类各格必须先停 serve 再跑 --mode=gc（WriterGate 为 @PostConstruct，serve 与 GC CLI
        不可并发持锁，08 §3.1 硬约束）。

    被杀进程无有意义退出码，不作判据；判据＝三快照 × 文件树 × 只读 SQL × 日志标记
    （CANGSHU|alert、job|gc、writer-gate）× HTTP 码。

    本脚本不改生产代码、不改 db/migration/*.sql：库侧注入只用触发器／会话锁／表锁，
    均在本格流程内自建自删，且不写 schema_version 台账。

.PARAMETER Cells
    要执行的格子，形如 '5-1'（点 5 类 ①）；可多值或用 -Cells all（默认 '5-1'）。
    已定义但本阶段未实现执行器的格子会显式报错（未实现 ≠ 通过）。

.EXAMPLE
    pwsh -File scripts/verify-task31-matrix.ps1 -Cells 5-1

.EXAMPLE
    pwsh -File scripts/verify-task31-matrix.ps1 -Cells 4-1 -Runs 1 -RateLimit 4k

.NOTES
    凭据来自 src/main/resources/application.yml 的既有默认值，可被 CANGSHU_DB_USER /
    CANGSHU_DB_PASSWORD 覆盖；密码只经 PGPASSWORD 传给子进程，不打印、不进命令行。
    前置：已构建打包 jar；PostgreSQL 17 客户端；JAVA_HOME 指向 JDK 21+。
#>
[CmdletBinding()]
param(
    [string[]] $Cells = @('5-1'),
    [int] $Runs = 3,
    [ValidateRange(1,8)] [int] $MaxAttemptsPerRun = 3,
    [string] $DatabasePrefix = 'cangshu_task31',
    [string] $DatabaseHost = '127.0.0.1',
    [int] $DatabasePort = 5432,
    [int] $BaseServerPort = 18130,
    [string] $OutputDirectory = 'target/task31-matrix',
    [string] $PostgresBin = 'E:\PostgreSQL\17\bin',
    [int] $TimeoutSeconds = 120,
    [int] $BlockWaitSeconds = 60,
    [string] $RateLimit = '8k',
    [int] $PayloadBytes = 65536,
    [int] $StagePayloadBytes = 268435456,
    [int] $GcPayloadBytes = 134217728,
    [string] $SupplementalEvidenceFile = '',
    [string] $BuildManifest = 'target/task31-build-manifest.json',
    [switch] $KeepDatabase,
    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'
if ($DatabasePrefix -cnotmatch '^[a-z][a-z0-9_]*$' -or $DatabasePrefix.Length -gt 20) {
    throw 'DatabasePrefix 只允许小写字母开头的小写字母、数字、下划线，且最多20字符（含负对照库名需不超过63字节）'
}
if ($BaseServerPort -lt 1024 -or $BaseServerPort + (($MaxAttemptsPerRun - 1) * 2000) + 150 -gt 65535 -or
    $BaseServerPort + 1003 -gt 65535) { throw 'BaseServerPort 与尝试次数组合超出安全 TCP 端口范围' }
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'task31-summary.ps1')
. (Join-Path $PSScriptRoot 'task31-negative-controls.ps1')
function Resolve-From([string] $Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

$migrationDir = Join-Path $repoRoot 'db/migration'
$jarPath = Join-Path $repoRoot 'target/cangshu-0.1.0-SNAPSHOT.jar'
$buildManifestPath = Resolve-From $BuildManifest
$outputBase = Resolve-From $OutputDirectory
$invocationId = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss') + '_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$outputRoot = Join-Path $outputBase $invocationId
$postgresBinPath = Resolve-From $PostgresBin
$psql = Join-Path $postgresBinPath 'psql.exe'
$createdb = Join-Path $postgresBinPath 'createdb.exe'
$dropdb = Join-Path $postgresBinPath 'dropdb.exe'
$curlPath = 'curl.exe'
$endpoint = $DatabaseHost + ':' + $DatabasePort
$schema = 'cangshu_m1'

function Assert-RunDataRoot {
    param([string] $DataRoot, [string] $RunDirectory)
    $actual = [System.IO.Path]::GetFullPath($DataRoot)
    $run = [System.IO.Path]::GetFullPath($RunDirectory)
    $expected = [System.IO.Path]::GetFullPath((Join-Path $run 'data-root'))
    $relativeRun = [System.IO.Path]::GetRelativePath($outputRoot, $run)
    $outside = $relativeRun -eq '..' -or
        $relativeRun.StartsWith('..' + [System.IO.Path]::DirectorySeparatorChar) -or
        [System.IO.Path]::IsPathRooted($relativeRun)
    if ($outside -or -not [string]::Equals($actual, $expected,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝递归清理非本格数据根：$actual（期望 $expected）"
    }
    if ((Test-Path -LiteralPath $actual) -and
        ((Get-Item -LiteralPath $actual -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw "拒绝递归清理目录联接或符号链接：$actual"
    }
}

# ════════════════════════════════════════════════════════════════════════════════════════════
#  库名白名单（任何建库／删库之前必须先过此校验）
# ════════════════════════════════════════════════════════════════════════════════════════════
$deniedDatabases = @(
    'cangshu', 'cangshu_test', 'cangshu_m1demo', 'cangshu_m1', 'cangshu_task4_bench',
    'cangshu_u1demo', 'cangshu_u2demo', 'cangshu_u3demo',
    'postgres', 'template0', 'template1'
)

function Assert-IsolatedDatabaseName {
    param([string] $DatabaseName)
    if ([string]::IsNullOrWhiteSpace($DatabaseName)) {
        throw '拒绝执行：库名为空'
    }
    if ($DatabaseName -match '[*?\[\]]') {
        throw "拒绝执行：库名含通配符 '$DatabaseName'"
    }
    $expected = '^' + [regex]::Escape($DatabasePrefix) + '_[A-Za-z0-9_]+$'
    if ($DatabaseName -notmatch $expected) {
        throw "拒绝执行：库名 '$DatabaseName' 不符合隔离库规则 $expected"
    }
    if ($deniedDatabases -contains $DatabaseName.ToLowerInvariant()) {
        throw "拒绝执行：库名 '$DatabaseName' 在既有库／系统库黑名单内"
    }
}

# ════════════════════════════════════════════════════════════════════════════════════════════
#  前置检查
# ════════════════════════════════════════════════════════════════════════════════════════════
if (-not (Test-Path -LiteralPath $migrationDir)) { throw "找不到迁移脚本目录：$migrationDir" }
foreach ($tool in @($psql, $createdb, $dropdb)) {
    if (-not (Test-Path -LiteralPath $tool)) {
        throw "找不到 $tool ； 用 -PostgresBin 指定 PostgreSQL 17 bin 目录（当前：$postgresBinPath）"
    }
}
$javaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME')
if (-not $javaHome) { throw '未设置 JAVA_HOME（打包 jar 需要 JDK 21+ 运行）' }
$javaPath = Join-Path $javaHome 'bin/java.exe'
if (-not (Test-Path -LiteralPath $javaPath)) { throw "找不到 java：$javaPath" }
$javaVersionLine = (& $javaPath -version 2>&1 | Select-Object -First 1) -join ''
$javaMajor = if ($javaVersionLine -match 'version "?(\d+)') { [int] $Matches[1] } else { 0 }
if ($javaMajor -lt 21) { throw "运行打包 jar 需要 JDK 21+，当前：$javaVersionLine" }
if (-not (Get-Command $curlPath -ErrorAction SilentlyContinue)) { throw "找不到 $curlPath" }

$applicationYaml = Get-Content -LiteralPath (Join-Path $repoRoot 'src/main/resources/application.yml') -Raw
function Get-ConfiguredDefault([string] $Key, [string] $Fallback) {
    $pattern = '(?m)^\s*' + [regex]::Escape($Key) + ':\s*\$\{CANGSHU_[A-Z_]+:([^}]+)\}'
    if ($applicationYaml -match $pattern) { return $Matches[1].Trim() }
    return $Fallback
}
$dbUser = [Environment]::GetEnvironmentVariable('CANGSHU_DB_USER')
if (-not $dbUser) { $dbUser = Get-ConfiguredDefault 'username' 'postgres' }
$dbPassword = [Environment]::GetEnvironmentVariable('CANGSHU_DB_PASSWORD')
if (-not $dbPassword) { $dbPassword = Get-ConfiguredDefault 'password' 'postgres' }

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$ownedDatabases = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$ownedProcesses = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$env:PGPASSWORD = $dbPassword
$env:CANGSHU_DB_USER = $dbUser
$env:CANGSHU_DB_PASSWORD = $dbPassword

# 取证绑定：提交 ＋ 工作树状态（08 §6 要求证据同时绑定提交与工作树）。
$headCommit = (& git -C $repoRoot rev-parse HEAD 2>&1) -join ''
$worktreeDirty = @(& git -C $repoRoot status --porcelain | Where-Object { $_ -ne '' })
$headCommit = $headCommit.Trim()
if ($LASTEXITCODE -ne 0 -or $headCommit -notmatch '^[0-9a-f]{40}$') { throw '无法确认当前 Git HEAD，拒绝执行矩阵' }
if ($worktreeDirty.Count -gt 0) {
    Set-Content -LiteralPath (Join-Path $outputRoot 'dirty-worktree.txt') -Encoding UTF8 -Value $worktreeDirty
    throw "正式矩阵须从干净 HEAD 构建并执行；当前工作树脏 $($worktreeDirty.Count) 项，清单已存输出目录"
}
$buildLogPath = Join-Path $outputRoot 'build.log'
if ($SkipBuild) {
    if (-not (Test-Path -LiteralPath $buildManifestPath -PathType Leaf)) {
        throw "SkipBuild 需已有可核对的构建清单：$buildManifestPath"
    }
    if (-not (Test-Path -LiteralPath $jarPath -PathType Leaf)) { throw "SkipBuild 找不到制品：$jarPath" }
    $manifest = Get-Content -LiteralPath $buildManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $actualJarSha = (Get-FileHash -LiteralPath $jarPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($manifest.head -cne $headCommit -or $manifest.sourceClean -isnot [bool] -or $manifest.sourceClean -ne $true -or
        $manifest.jarSha256 -cne $actualJarSha -or $manifest.jarPath -cne $jarPath) {
        throw 'SkipBuild 清单的干净 HEAD、jar 路径或 SHA-256 与当前制品不符'
    }
    $buildProvenance = [pscustomobject]@{mode='verified-skip-build';head=$headCommit;sourceClean=$true;
        jarPath=$jarPath;jarSha256=$actualJarSha;manifestPath=$buildManifestPath;buildLog=$manifest.buildLog}
} else {
    if (-not (Get-Command mvn -ErrorAction SilentlyContinue)) { throw '找不到 mvn；无法从当前干净 HEAD 构建 jar' }
    $buildCommand = 'mvn -B -ntp -DskipTests package'
    $buildOutput = @(& mvn -B -ntp -DskipTests package 2>&1)
    $buildExit = $LASTEXITCODE
    Set-Content -LiteralPath $buildLogPath -Value $buildOutput -Encoding UTF8
    if ($buildExit -ne 0 -or -not (Test-Path -LiteralPath $jarPath -PathType Leaf)) {
        throw "当前 HEAD 构建失败：exit=$buildExit；日志：$buildLogPath"
    }
    $headAfterBuild = ((& git -C $repoRoot rev-parse HEAD) -join '').Trim()
    $dirtyAfterBuild = @(& git -C $repoRoot status --porcelain | Where-Object { $_ -ne '' })
    if ($headAfterBuild -cne $headCommit -or $dirtyAfterBuild.Count -gt 0) {
        throw '构建期间 HEAD 或源码工作树发生变化，拒绝把制品绑定为干净当前 HEAD'
    }
    $actualJarSha = (Get-FileHash -LiteralPath $jarPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $buildProvenance = [pscustomobject]@{mode='built-current-head';head=$headCommit;sourceClean=$true;
        jarPath=$jarPath;jarSha256=$actualJarSha;manifestPath=$buildManifestPath;buildLog=$buildLogPath;
        command=$buildCommand;builtAt=(Get-Date).ToUniversalTime().ToString('o')}
    $manifestDirectory = Split-Path -Parent $buildManifestPath
    if (-not (Test-Path -LiteralPath $manifestDirectory)) { New-Item -ItemType Directory -Path $manifestDirectory -Force | Out-Null }
    Set-Content -LiteralPath $buildManifestPath -Value ($buildProvenance | ConvertTo-Json -Depth 4) -Encoding UTF8
}
Set-Content -LiteralPath (Join-Path $outputRoot 'build-provenance.json') -Value ($buildProvenance | ConvertTo-Json -Depth 4) -Encoding UTF8

# ════════════════════════════════════════════════════════════════════════════════════════════
#  通用工具
# ════════════════════════════════════════════════════════════════════════════════════════════
function Quote-Arguments([string[]] $Arguments) {
    $quoted = foreach ($argument in $Arguments) {
        if ($argument -match '\s') { '"' + $argument + '"' } else { $argument }
    }
    return ($quoted -join ' ')
}

function Invoke-PsqlQuery {
    param([string] $DatabaseName, [string] $Command)
    $output = @(& $psql -h $DatabaseHost -p $DatabasePort -U $dbUser -d $DatabaseName -X -t -A -q -v 'ON_ERROR_STOP=1' -c $Command 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "psql 执行失败（退出码 $LASTEXITCODE）：$Command ； $($output -join ' | ')" }
    return @($output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
}

function Invoke-PsqlFile {
    param([string] $DatabaseName, [string] $Path)
    $output = (& $psql -h $DatabaseHost -p $DatabasePort -U $dbUser -d $DatabaseName -q -v 'ON_ERROR_STOP=1' -f $Path 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "psql 执行脚本失败（退出码 $LASTEXITCODE）：$Path ； $($output -join ' | ')" }
    return ($output -join [Environment]::NewLine)
}

function Invoke-MigrationScripts {
    param([string] $DatabaseName)
    $scripts = @(Get-ChildItem -LiteralPath $migrationDir -Filter 'V*.sql' | Sort-Object -Property Name)
    if ($scripts.Count -eq 0) { throw "迁移目录里没有 V*.sql：$migrationDir" }
    foreach ($script in $scripts) {
        $sha = (Get-FileHash -LiteralPath $script.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $output = (& $psql -h $DatabaseHost -p $DatabasePort -U $dbUser -d $DatabaseName -q -v 'ON_ERROR_STOP=1' -v "script_sha256=$sha" -f $script.FullName 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "迁移脚本执行失败：$($script.Name) ； $($output -join ' | ')" }
    }
}

function Reset-IsolatedDatabase {
    param([string] $DatabaseName)
    Assert-IsolatedDatabaseName -DatabaseName $DatabaseName
    if ($ownedDatabases.Contains($DatabaseName)) { throw "本次调用已创建隔离库：$DatabaseName" }
    if (@(Get-DatabaseInventory | Where-Object { $_ -eq $DatabaseName }).Count -ne 0) {
        throw "拒绝覆盖已存在数据库：$DatabaseName"
    }
    $createOutput = @(& $createdb -h $DatabaseHost -p $DatabasePort -U $dbUser $DatabaseName 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "创建隔离库失败：$DatabaseName（退出码 $LASTEXITCODE）" }
    $ownedDatabases.Add($DatabaseName) | Out-Null
    Invoke-MigrationScripts -DatabaseName $DatabaseName
}

function Remove-IsolatedDatabase {
    param([string] $DatabaseName)
    Assert-IsolatedDatabaseName -DatabaseName $DatabaseName
    if (-not $ownedDatabases.Contains($DatabaseName)) { throw "拒绝清理未经本次调用确权创建的库：$DatabaseName" }
    $dropOutput = @(& $dropdb -h $DatabaseHost -p $DatabasePort -U $dbUser $DatabaseName 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "删除隔离库失败：$DatabaseName（退出码 $LASTEXITCODE）：$($dropOutput -join ' | ')" }
    $ownedDatabases.Remove($DatabaseName) | Out-Null
}

function Get-DatabaseInventory {
    $sql = 'SELECT datname FROM pg_database ORDER BY datname'
    return @(Invoke-PsqlQuery -DatabaseName 'postgres' -Command $sql)
}

function Start-CangshuProcess {
    param(
        [string] $DatabaseName,
        [string] $DataRoot,
        [int] $ServerPort,
        [string] $LogName,
        [string] $RunDirectory,
        [ValidateSet('serve', 'gc', 'reconcile')] [string] $Mode = 'serve',
        [switch] $AllowShutdownEndpoint
    )
    # 拼接而非内插：PowerShell 会把 ? 并进变量名，URL 会被写坏。
    $jdbcUrl = 'jdbc:postgresql://' + $endpoint + '/' + $DatabaseName + '?currentSchema=' + $schema
    $jvmArguments = @(
        '-Dstdout.encoding=UTF-8',
        '-Dstderr.encoding=UTF-8',
        "-Dcangshu.migration.dir=$migrationDir",
        "-Dcangshu.data-root=$DataRoot",
        "-Dspring.datasource.url=$jdbcUrl"
    )
    $applicationArguments = @('--spring.main.banner-mode=off')
    if ($Mode -eq 'serve') {
        $applicationArguments += "--server.port=$ServerPort"
        if ($AllowShutdownEndpoint) {
            $applicationArguments += '--management.endpoints.web.exposure.include=health,shutdown'
            $applicationArguments += '--management.endpoint.shutdown.enabled=true'
        }
    } else {
        $applicationArguments += '--spring.main.web-application-type=none'
        $applicationArguments += "--mode=$Mode"
    }
    $stdout = Join-Path $RunDirectory "$LogName.log"
    $stderr = Join-Path $RunDirectory "$LogName.err.log"
    $arguments = Quote-Arguments ($jvmArguments + @('-jar', $jarPath) + $applicationArguments)
    $process = Start-Process -FilePath $javaPath -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $ownedProcesses.Add($process)
    return [pscustomobject]@{
        Process = $process; Stdout = $stdout; Stderr = $stderr
        Database = $DatabaseName; DataRoot = $DataRoot; Port = $ServerPort; Mode = $Mode
    }
}

function Wait-ForLogPattern {
    param([string] $Path, [string] $Pattern, [int] $WaitSeconds, [System.Diagnostics.Process] $Process)
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($Process -and $Process.HasExited) { return $false }
        if (Test-Path -LiteralPath $Path) {
            try {
                if (Select-String -LiteralPath $Path -Pattern $Pattern -SimpleMatch -Quiet -Encoding UTF8 -ErrorAction Stop) { return $true }
            } catch { }
        }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Get-LogText([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
}

function Get-LogTail([string] $Path, [int] $Lines = 20) {
    if (-not (Test-Path -LiteralPath $Path)) { return '(日志不存在)' }
    return ((Get-Content -LiteralPath $Path -Encoding UTF8 -Tail $Lines) -join [Environment]::NewLine)
}

function Invoke-Curl {
    param([string] $Method, [string] $Uri, [int] $TimeoutSeconds = 15, [string] $OutFile)
    $arguments = @('--silent', '--show-error', '--noproxy', '*', '--max-time', $TimeoutSeconds, '--request', $Method)
    if ($OutFile) { $arguments += @('--output', $OutFile) }
    $arguments += $Uri
    $output = (& $curlPath @arguments 2>&1) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0) { throw "curl 调用失败（退出码 $LASTEXITCODE）：$Method $Uri ； $output" }
    return $output
}

function Get-HttpStatus {
    param([string] $Method, [string] $Uri, [int] $TimeoutSeconds = 15, [string] $OutFile)
    $arguments = @('--silent', '--show-error', '--noproxy', '*', '--max-time', $TimeoutSeconds,
        '--request', $Method, '--write-out', '%{http_code}', '--output', $OutFile, $Uri)
    $output = (& $curlPath @arguments 2>&1) -join ''
    return [pscustomobject]@{ Status = $output.Trim(); ExitCode = $LASTEXITCODE }
}

function Wait-ForHealth {
    param([string] $ServerEndpoint, [int] $WaitSeconds)
    $uri = 'http://' + $ServerEndpoint + '/actuator/health'
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $lastError = '（尚未发起请求）'
    while ((Get-Date) -lt $deadline) {
        try {
            $health = (Invoke-Curl -Method 'GET' -Uri $uri -TimeoutSeconds 5) | ConvertFrom-Json
            if ($health.status -eq 'UP') { return $health }
            $lastError = '健康状态非 UP：' + ($health | ConvertTo-Json -Compress)
        } catch { $lastError = $_.Exception.Message }
        Start-Sleep -Milliseconds 700
    }
    throw "健康检查在 $WaitSeconds 秒内未通过：$lastError"
}

function Test-TcpListener {
    param([string] $TargetHost, [int] $Port, [int] $TimeoutMs = 400)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $client.ConnectAsync($TargetHost, $Port)
        if (-not $connect.Wait($TimeoutMs)) { return $false }
        return $client.Connected
    } catch { return $false } finally { $client.Close() }
}

function Stop-CangshuHard {
    param([System.Diagnostics.Process] $Process)
    if (-not $Process) { return '（无进程句柄）' }
    if ($Process.HasExited) { return "进程已自行退出（退出码 $($Process.ExitCode)）" }
    Stop-Process -Id $Process.Id -Force -ErrorAction Stop
    $Process.WaitForExit(30000) | Out-Null
    return 'Stop-Process -Force 已执行（被杀进程无有意义退出码，不作判据）'
}

# ════════════════════════════════════════════════════════════════════════════════════════════
#  快照（三快照口径；全部只读，不起进程、不做任何恢复动作）
# ════════════════════════════════════════════════════════════════════════════════════════════
function Get-DataRootTree {
    param([string] $DataRoot)
    if (-not (Test-Path -LiteralPath $DataRoot)) { return @('(数据根不存在)') }
    $entries = @(Get-ChildItem -LiteralPath $DataRoot -Recurse -Force -File | Sort-Object -Property FullName)
    if ($entries.Count -eq 0) { return @('(空数据根)') }
    return @($entries | ForEach-Object {
        $relative = $_.FullName.Substring($DataRoot.Length).TrimStart([char] 92).Replace('\', '/')
        '{0}|size={1}' -f $relative, $_.Length
    })
}

function Get-DatabaseState {
    param([string] $DatabaseName)
    $sql = "SELECT 'content|' || coalesce(string_agg(status, ',' ORDER BY id), '-') FROM $schema.content " +
           "UNION ALL SELECT 'location|' || coalesce(string_agg(storage_key, ',' ORDER BY id), '-') FROM $schema.location " +
           "UNION ALL SELECT 'resource|' || coalesce(string_agg(status, ',' ORDER BY id), '-') FROM $schema.resource " +
           "UNION ALL SELECT 'counts|content=' || (SELECT count(*) FROM $schema.content) || ',location=' || " +
           "(SELECT count(*) FROM $schema.location) || ',resource=' || (SELECT count(*) FROM $schema.resource)"
    $identitySql = "SELECT 'identity|contentId=' || c.id || '|algorithm=' || c.hash_algorithm || " +
        "'|digest=' || c.digest || '|size=' || c.size_bytes || '|status=' || c.status || " +
        "'|locationId=' || coalesce(l.id::text,'-') || '|locationContentId=' || coalesce(l.content_id::text,'-') || " +
        "'|backend=' || coalesce(l.storage_backend,'-') || '|key=' || coalesce(l.storage_key,'-') || " +
        "'|resourceId=' || coalesce(r.id::text,'-') || '|resourceContentId=' || coalesce(r.content_id::text,'-') || " +
        "'|resourceSize=' || coalesce(r.size_bytes::text,'-') || '|resourceStatus=' || coalesce(r.status,'-') " +
        "FROM $schema.content c LEFT JOIN $schema.location l ON l.content_id=c.id " +
        "LEFT JOIN $schema.resource r ON r.content_id=c.id ORDER BY c.id,r.id,l.id"
    return @((Invoke-PsqlQuery -DatabaseName $DatabaseName -Command $sql) +
        (Invoke-PsqlQuery -DatabaseName $DatabaseName -Command $identitySql))
}

function Test-Task31ReadyIdentity {
    param([string] $DatabaseName, $Payload, [string[]] $ResourceIds, [string] $ContentId)
    $sql = "SELECT r.id::text || '|' || r.content_id::text || '|' || c.id::text || '|' || " +
        "c.hash_algorithm || '|' || c.digest || '|' || c.size_bytes || '|' || r.size_bytes || '|' || " +
        "c.status || '|' || r.status || '|' || l.content_id::text || '|' || l.storage_backend || '|' || l.storage_key " +
        "FROM $schema.resource r JOIN $schema.content c ON c.id=r.content_id " +
        "JOIN $schema.location l ON l.content_id=c.id ORDER BY r.id,l.id"
    $rows = @(Invoke-PsqlQuery -DatabaseName $DatabaseName -Command $sql)
    $key = 'sha256/' + $Payload.Digest.Substring(0,2) + '/' + $Payload.Digest.Substring(2,2) + '/' + $Payload.Digest
    $expected = @($ResourceIds | ForEach-Object { ([guid]$_).ToString().ToLowerInvariant() } | Sort-Object)
    $actual = @()
    $valid = $rows.Count -eq $ResourceIds.Count
    foreach($row in $rows){
        $parts = [string]$row -split '\|'
        if($parts.Count -ne 12){$valid=$false;continue}
        $actual += $parts[0].ToLowerInvariant()
        if($parts[1] -ne $ContentId -or $parts[2] -ne $ContentId -or
            $parts[3] -cne 'SHA-256' -or $parts[4] -cne $Payload.Digest -or
            $parts[5] -ne [string]$Payload.SizeBytes -or $parts[6] -ne [string]$Payload.SizeBytes -or
            $parts[7] -ne 'READY' -or $parts[8] -ne 'READY' -or
            $parts[9] -ne $ContentId -or $parts[10] -ne 'filesystem' -or $parts[11] -cne $key){$valid=$false}
    }
    if(@(Compare-Object -ReferenceObject $expected -DifferenceObject @($actual | Sort-Object)).Count -gt 0){$valid=$false}
    return [pscustomobject]@{Pass=[bool]$valid;Detail=($rows -join ';');Rows=$rows}
}

function Save-Snapshot {
    param(
        [string] $Label, [string] $RunDirectory, [string] $DatabaseName,
        [string] $DataRoot, [int] $ServerPort, [string[]] $Extra = @()
    )
    $lines = @()
    $lines += '# 快照 ' + $Label + '  ' + (Get-Date).ToUniversalTime().ToString('o')
    $lines += '## 进程／端口（serve 端口 ' + $ServerPort + '）'
    $lines += 'listening=' + (Test-TcpListener -TargetHost '127.0.0.1' -Port $ServerPort)
    $lines += '## 只读 SQL（' + $DatabaseName + '.' + $schema + '）'
    $lines += @(Get-DatabaseState -DatabaseName $DatabaseName)
    $lines += '## 数据根文件树（' + $DataRoot + '）'
    $lines += @(Get-DataRootTree -DataRoot $DataRoot)
    if ($Extra.Count -gt 0) { $lines += '## 附加只读核对'; $lines += $Extra }
    $path = Join-Path $RunDirectory ('snapshot-' + $Label + '.txt')
    Set-Content -LiteralPath $path -Value $lines -Encoding UTF8
    return [pscustomobject]@{ Path = $path; Lines = $lines }
}

# ════════════════════════════════════════════════════════════════════════════════════════════
#  夹具原语（库侧注入；不改生产代码、不改 db/migration、不写 schema_version）
# ════════════════════════════════════════════════════════════════════════════════════════════
$fixtureFunction = 'public.task31_fixture_gate'
$fixtureTrigger = 'task31_fixture_gate'

# 原语 A：延时触发器（普通触发器 ＋ pg_sleep）。不进入 pg_constraint，对启动结构门无影响。
function New-DelayTrigger {
    param(
        [string] $DatabaseName, [string] $RunDirectory,
        [ValidateSet('INSERT', 'UPDATE', 'DELETE')] [string] $Event = 'INSERT',
        [ValidateSet('content', 'location', 'resource')] [string] $Table = 'resource',
        [string] $WhenClause = '',
        [int] $SleepSeconds = 45,
        [ValidateSet('BEFORE', 'AFTER')] [string] $Timing = 'AFTER'
    )
    $whenSql = if ($WhenClause) { "WHEN ($WhenClause)" } else { '' }
    $ddl = @'
CREATE OR REPLACE FUNCTION public.task31_fixture_gate() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN
  PERFORM pg_sleep(%SLEEP%);
  RETURN COALESCE(NEW, OLD);
END
$body$;
'@
    $ddl = $ddl.Replace('%SLEEP%', [string] $SleepSeconds)
    $ddl += "DROP TRIGGER IF EXISTS $fixtureTrigger ON $schema.$Table;" + [Environment]::NewLine
    $ddl += "CREATE TRIGGER $fixtureTrigger $Timing $Event ON $schema.$Table FOR EACH ROW $whenSql EXECUTE FUNCTION $fixtureFunction();"
    $path = Join-Path $RunDirectory ('fixture-delay-' + $Table + '-' + $Event + '.sql')
    Set-Content -LiteralPath $path -Value $ddl -Encoding UTF8
    Invoke-PsqlFile -DatabaseName $DatabaseName -Path $path | Out-Null
    return $path
}

# 原语 B：提交门约束触发器（DEFERRABLE INITIALLY DEFERRED）。
# 精确卡在「行已插、COMMIT 未落」；代价＝进入 pg_constraint（contype='t'），
# 重启前必须拆除，否则 DEC-T3 结构门会以退出码 3 拒启（见 fixture-gate-interaction）。
function New-CommitGateTrigger {
    param(
        [string] $DatabaseName, [string] $RunDirectory,
        [ValidateSet('content', 'location', 'resource')] [string] $Table = 'resource',
        [ValidateSet('INSERT', 'UPDATE')] [string] $Event = 'INSERT',
        [string] $WhenClause = '',
        [int] $SleepSeconds = 45
    )
    $whenSql = if ($WhenClause) { "WHEN ($WhenClause)" } else { '' }
    $ddl = @'
CREATE OR REPLACE FUNCTION public.task31_fixture_gate() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN
  PERFORM pg_sleep(%SLEEP%);
  RETURN COALESCE(NEW, OLD);
END
$body$;
'@
    $ddl = $ddl.Replace('%SLEEP%', [string] $SleepSeconds)
    $ddl += "DROP TRIGGER IF EXISTS $fixtureTrigger ON $schema.$Table;" + [Environment]::NewLine
    $ddl += "CREATE CONSTRAINT TRIGGER $fixtureTrigger AFTER $Event ON $schema.$Table DEFERRABLE INITIALLY DEFERRED FOR EACH ROW $whenSql EXECUTE FUNCTION $fixtureFunction();"
    $path = Join-Path $RunDirectory ('fixture-commit-gate-' + $Table + '-' + $Event + '.sql')
    Set-Content -LiteralPath $path -Value $ddl -Encoding UTF8
    Invoke-PsqlFile -DatabaseName $DatabaseName -Path $path | Out-Null
    return $path
}

# 原语 C：表级排它锁（另一会话持有，卡在目标语句之前；用于「移动前」这类语句边界）。
function Start-TableBlockSession {
    param([string] $DatabaseName, [string] $RunDirectory, [string] $Table = 'content')
    # EXCLUSIVE 阻塞 SELECT ... FOR UPDATE 所需的 ROW SHARE，但允许普通 ACCESS SHARE 只读快照。
    $sql = 'BEGIN; LOCK TABLE ' + $schema + '.' + $Table + ' IN EXCLUSIVE MODE; SELECT pg_sleep(300); COMMIT;'
    $out = Join-Path $RunDirectory ('fixture-table-block-' + $Table + '.out')
    $err = Join-Path $RunDirectory ('fixture-table-block-' + $Table + '.err')
    $arguments = @('-h', $DatabaseHost, '-p', $DatabasePort, '-U', $dbUser, '-d', $DatabaseName, '-q', '-c', $sql)
    $process = Start-Process -FilePath $psql -ArgumentList (Quote-Arguments $arguments) -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    $ownedProcesses.Add($process)
    return [pscustomobject]@{ Process = $process; Out = $out; Err = $err; Table = $Table }
}

function Remove-FixtureObjects {
    param([string] $DatabaseName, [string] $RunDirectory)
    $sql = "DROP TRIGGER IF EXISTS $fixtureTrigger ON $schema.content;" +
           "DROP TRIGGER IF EXISTS $fixtureTrigger ON $schema.location;" +
           "DROP TRIGGER IF EXISTS $fixtureTrigger ON $schema.resource;" +
           "DROP FUNCTION IF EXISTS $fixtureFunction();"
    $path = Join-Path $RunDirectory 'fixture-teardown.sql'
    Set-Content -LiteralPath $path -Value $sql -Encoding UTF8
    Invoke-PsqlFile -DatabaseName $DatabaseName -Path $path | Out-Null
    return "夹具已拆除（$fixtureFunction / $fixtureTrigger）"
}

function Get-FixtureInventory {
    param([string] $DatabaseName)
    $sql = "SELECT 'trigger|' || tgname || '|' || tgconstraint FROM pg_trigger t " +
           "JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace " +
           "WHERE NOT t.tgisinternal AND n.nspname = '$schema'"
    return @(Invoke-PsqlQuery -DatabaseName $DatabaseName -Command $sql)
}

# 阻塞点证据（08 §3.1 裁决记录第 3 条：无证据该格不计次）
function Save-BlockEvidence {
    param([string] $Label, [string] $DatabaseName, [string] $RunDirectory)
    $activity = "SELECT pid, state, coalesce(wait_event_type,'-') AS wait_event_type, " +
                "coalesce(wait_event,'-') AS wait_event, backend_type, left(replace(query, chr(10), ' '), 160) AS query " +
                "FROM pg_stat_activity WHERE datname = '$DatabaseName' AND pid <> pg_backend_pid() ORDER BY pid"
    $locks = "SELECT l.pid, l.locktype, l.mode, l.granted, coalesce(c.relname, '-') AS relation, " +
             "coalesce(l.transactionid::text, '-') AS xid FROM pg_locks l LEFT JOIN pg_class c ON c.oid = l.relation " +
             "WHERE l.pid IN (SELECT pid FROM pg_stat_activity WHERE datname = '$DatabaseName') " +
             "ORDER BY l.pid, l.granted DESC, l.locktype"
    $lines = @()
    $lines += '# 阻塞点证据 [' + $Label + ']  ' + (Get-Date).ToUniversalTime().ToString('o')
    $lines += '库：' + $DatabaseName
    $lines += ''
    $lines += '## A. pg_stat_activity 原文'
    $lines += @(Invoke-PsqlQuery -DatabaseName $DatabaseName -Command $activity)
    $lines += ''
    $lines += '## B. pg_locks 原文'
    $lines += @(Invoke-PsqlQuery -DatabaseName $DatabaseName -Command $locks)
    $path = Join-Path $RunDirectory ('block-evidence-' + $Label + '.txt')
    Set-Content -LiteralPath $path -Value $lines -Encoding UTF8
    return [pscustomobject]@{ Path = $path; Lines = $lines }
}

function Wait-ForBlockedBackend {
    param([string] $DatabaseName, [int] $WaitSeconds, [string] $WaitEventPattern = 'PgSleep')
    $sql = "SELECT pid FROM pg_stat_activity WHERE datname = '$DatabaseName' AND pid <> pg_backend_pid() " +
           "AND state = 'active' AND coalesce(wait_event,'') LIKE '%$WaitEventPattern%'"
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        $rows = @(Invoke-PsqlQuery -DatabaseName $DatabaseName -Command $sql | Where-Object { $_ -match '^\s*\d+\s*$' })
        if ($rows.Count -gt 0) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

# 节流上传客户端：curl --limit-rate 拉长窗口（异步，便于在其飞行中杀进程）。
function Start-ThrottledUpload {
    param(
        [string] $Uri, [string] $UploadPath, [string] $RunDirectory,
        [string] $Name = 'upload', [string] $RateLimitSeconds = ''
    )
    $responseFile = Join-Path $RunDirectory "$Name-response.json"
    $codeFile = Join-Path $RunDirectory "$Name-http-code.txt"
    $errFile = Join-Path $RunDirectory "$Name-client.err.log"
    $arguments = @('--silent', '--show-error', '--noproxy', '*', '--max-time', '900')
    if ($RateLimitSeconds) { $arguments += @('--limit-rate', $RateLimitSeconds) }
    $arguments += @('--request', 'POST', '--form', ('file=@' + $UploadPath),
        '--output', $responseFile, '--write-out', '%{http_code}', $Uri)
    $process = Start-Process -FilePath $curlPath -ArgumentList (Quote-Arguments $arguments) -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $codeFile -RedirectStandardError $errFile
    $ownedProcesses.Add($process)
    return [pscustomobject]@{
        Process = $process; Response = $responseFile; Code = $codeFile; Error = $errFile; Uri = $Uri
    }
}

function New-PayloadFile {
    param([string] $Path, [int] $SizeBytes)
    if ($SizeBytes -lt 1) { throw '载荷大小必须大于零' }
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    if (Test-Path -LiteralPath $Path) { throw "拒绝覆盖已有载荷：$Path" }
    $buffer = New-Object byte[] 1048576
    for ($index = 0; $index -lt $buffer.Length; $index++) { $buffer[$index] = [byte] (($index * 31 + 7) % 256) }
    $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
    try {
        $remaining = $SizeBytes
        while ($remaining -gt 0) {
            $count = [Math]::Min($remaining, $buffer.Length)
            $stream.Write($buffer, 0, $count)
            $remaining -= $count
        }
    } finally { $stream.Dispose() }
    return [pscustomobject]@{
        Path = $Path; SizeBytes = $SizeBytes
        Digest = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Get-CellDirectory {
    param([string] $CellId)
    $path = Join-Path $outputRoot $CellId
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    return $path
}

function Get-RunDirectory {
    param([string] $CellId, [int] $Run, [int] $Attempt = 1)
    $path = Join-Path (Get-CellDirectory -CellId $CellId) ('r' + $Run + '-a' + $Attempt)
    if (Test-Path -LiteralPath $path) { throw "拒绝覆盖已有尝试目录：$path" }
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

function Get-CellPort {
    param([int] $CellIndex, [int] $Run, [int] $Attempt = 1)
    return $BaseServerPort + ($CellIndex * 10) + $Run + (($Attempt - 1) * 2000)
}

function Get-CellDatabaseName {
    param([string] $CellId, [int] $Run, [int] $Attempt = 1)
    $name = $DatabasePrefix + '_' + $invocationId + '_' + ($CellId -replace '-', '_') + '_r' + $Run + '_a' + $Attempt
    if ($name.Length -gt 63) { throw "隔离库名超过 PostgreSQL 63 字节：$name" }
    return $name
}

# ════════════════════════════════════════════════════════════════════════════════════════════
#  格子注册表（08 §3.1 全 28 格逐格登记；不可达格登记「不适用 ＋ 理由」）
# ════════════════════════════════════════════════════════════════════════════════════════════
$cellRegistry = @(
    @{ Id='1-1'; P=1; C='①'; Pos='FileStore.stage 流式写 tmp'; Exp='无最终键、无元数据；tmp 残留待对账'; Reach='可达'; Inj='摘要器替身（stage 内 sleep）或大文件轮询抓点'; Runner='' }
    @{ Id='1-2'; P=1; C='②'; Pos='复用同样先落 tmp（字节已在最终键）'; Exp='无新增引用；既有内容与字节不动'; Reach='可达'; Inj='轮询抓点'; Runner='' }
    @{ Id='1-3'; P=1; C='③'; Pos='—'; Exp='—'; Reach='不适用'; Inj=''; Reason='软删／清空不写 tmp'; Runner='' }
    @{ Id='1-4'; P=1; C='④'; Pos='—'; Exp='—'; Reach='不适用'; Inj=''; Reason='GC 不写 tmp'; Runner='' }
    @{ Id='2-1'; P=2; C='①'; Pos='CatalogService 调 FileStore.moveInto 之前'; Exp='tmp 在、最终键未建；无元数据'; Reach='需注入'; Inj='锁闩（SegmentLockManager 测试侧装饰）或表级排它锁卡 selectContentForUpdate'; Runner='' }
    @{ Id='2-2'; P=2; C='②'; Pos='—'; Exp='—'; Reach='不适用'; Inj=''; Reason='复用命中无移动动作'; Runner='' }
    @{ Id='2-3'; P=2; C='③'; Pos='—'; Exp='—'; Reach='不适用'; Inj=''; Reason='软删／清空无字节移动'; Runner='' }
    @{ Id='2-4'; P=2; C='④'; Pos='—'; Exp='—'; Reach='不适用'; Inj=''; Reason='GC 删字节走 deleteBlob，不是移动'; Runner='' }
    @{ Id='3-1'; P=3; C='①'; Pos='moveInto 成功、首条 INSERT 前'; Exp='无元数据 ＋ 孤儿字节；对账识别'; Reach='需注入'; Inj='触发器延时（content INSERT）'; Runner='' }
    @{ Id='3-2'; P=3; C='②'; Pos='—'; Exp='—'; Reach='不适用'; Inj=''; Reason='复用命中无「移动后、首条 INSERT 前」窗口'; Runner='' }
    @{ Id='3-3'; P=3; C='③'; Pos='—'; Exp='—'; Reach='不适用'; Inj=''; Reason='软删／清空不动字节，无孤立字节窗口'; Runner='' }
    @{ Id='3-4'; P=3; C='④'; Pos='—'; Exp='—'; Reach='不适用'; Inj=''; Reason='GC 无移动动作'; Runner='' }
    @{ Id='4-1'; P=4; C='①'; Pos='三行已插、COMMIT 未落'; Exp='事务回滚、三表无行；孤儿字节对账收敛'; Reach='需注入'; Inj='提交门约束触发器（resource INSERT，DEFERRABLE INITIALLY DEFERRED）'; Runner='4-1' }
    @{ Id='4-2'; P=4; C='②'; Pos='资源行 INSERT 未提交'; Exp='无新增引用；既有内容与字节不动'; Reach='需注入'; Inj='提交门约束触发器（resource INSERT）'; Runner='' }
    @{ Id='4-3'; P=4; C='③'; Pos='软删／硬删事务未提交'; Exp='资源状态未落库（仍为就绪）'; Reach='需注入'; Inj='触发器延时（resource UPDATE）'; Runner='' }
    @{ Id='4-4'; P=4; C='④'; Pos='段一提交前被杀'; Exp='保持待回收；位置行仍在、字节在'; Reach='需注入'; Inj='触发器延时（content UPDATE SET status）'; Runner='' }
    @{ Id='5-1'; P=5; C='①'; Pos='201 返回后即杀'; Exp='三表齐全 ＋ 位置与字节 ＋ 大小与摘要相符；重启可读'; Reach='可达'; Inj='无（HTTP 响应后直接强杀）'; Runner='5-1' }
    @{ Id='5-2'; P=5; C='②'; Pos='响应含 deduplicated 后即杀'; Exp='新增 1 条引用；字节零重写；原引用完好'; Reach='可达'; Inj='无'; Runner='' }
    @{ Id='5-3'; P=5; C='③'; Pos='软删／清空提交后即杀'; Exp='DELETED ＋ 待回收，或行已删；字节仍在'; Reach='可达'; Inj='无'; Runner='' }
    @{ Id='5-4'; P=5; C='④'; Pos='段一提交后杀'; Exp='回收中残留、位置行已删、字节在 → 启动对账报告、下次 GC 续接'; Reach='可达'; Inj='无（先停 serve 再跑 --mode=gc）'; Runner='' }
    @{ Id='6-1'; P=6; C='①'; Pos='由 ④ 同点覆盖（引用降为 0 后进入 GC 链路）'; Exp='同点 ④ 行'; Reach='可达（经 ④）'; Inj='同 6-4'; Runner='' }
    @{ Id='6-2'; P=6; C='②'; Pos='—'; Exp='—'; Reach='不适用'; Inj=''; Reason='复用不删字节'; Runner='' }
    @{ Id='6-3'; P=6; C='③'; Pos='—'; Exp='—'; Reach='不适用'; Inj=''; Reason='软删／清空不删字节（字节留待 GC）'; Runner='' }
    @{ Id='6-4'; P=6; C='④'; Pos='段二 sha256Hex 校验中（GcService）'; Exp='回收中 ＋ 字节在 → 重扫删字节并置已回收'; Reach='可达'; Inj='轮询抓点（大字节拉长段二窗口）；未命中即重跑、不计次'; Runner='' }
    @{ Id='7-1'; P=7; C='①'; Pos='由 ④ 同点覆盖'; Exp='同点 ④ 行'; Reach='可达（经 ④）'; Inj='同 7-4'; Runner='' }
    @{ Id='7-2'; P=7; C='②'; Pos='—'; Exp='—'; Reach='不适用'; Inj=''; Reason='复用不删字节'; Runner='' }
    @{ Id='7-3'; P=7; C='③'; Pos='—'; Exp='—'; Reach='不适用'; Inj=''; Reason='软删／清空不删字节，未到 GC 段三'; Runner='' }
    @{ Id='7-4'; P=7; C='④'; Pos='deleteBlob 完成、段三 COMMIT 未落'; Exp='回收中 ＋ 字节缺 → 重扫幂等通过并置已回收'; Reach='需注入'; Inj='触发器延时（content UPDATE WHEN NEW.status = RECLAIMED）'; Runner='' }
)

function Get-CellDefinition {
    param([string] $CellId)
    $match = @($cellRegistry | Where-Object { $_.Id -eq $CellId })
    if ($match.Count -eq 0) {
        $known = ($cellRegistry | ForEach-Object { $_.Id }) -join '、'
        throw "未知格子 '$CellId'；已登记格子：$known"
    }
    return $match[0]
}

function Resolve-RequestedCells {
    param([string[]] $Requested)
    if ($Requested.Count -eq 1 -and $Requested[0] -eq 'all') {
        return @($cellRegistry | ForEach-Object { $_.Id })
    }
    foreach ($cellId in $Requested) { Get-CellDefinition -CellId $cellId | Out-Null }
    return $Requested
}

# ════════════════════════════════════════════════════════════════════════════════════════════
#  共用流程：起 serve → 等启动标记 → 健康检查
# ════════════════════════════════════════════════════════════════════════════════════════════
function Start-ServeAndWait {
    param([string] $DatabaseName, [string] $DataRoot, [int] $ServerPort, [string] $LogName, [string] $RunDirectory)
    $run = Start-CangshuProcess -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort `
        -LogName $LogName -RunDirectory $RunDirectory -Mode 'serve' -AllowShutdownEndpoint
    $serverEndpoint = '127.0.0.1:' + $ServerPort
    foreach ($marker in @('CANGSHU|writer-gate|acquired', 'CANGSHU|migration|verified', 'Started CangshuApplication')) {
        if (-not (Wait-ForLogPattern -Path $run.Stdout -Pattern $marker -WaitSeconds $TimeoutSeconds -Process $run.Process)) {
            $tail = Get-LogTail $run.Stdout
            throw "未出现启动标记 '$marker'（见 $($run.Stdout)）" + [Environment]::NewLine + $tail
        }
    }
    Wait-ForHealth -ServerEndpoint $serverEndpoint -WaitSeconds 60 | Out-Null
    $run | Add-Member -NotePropertyName ServerEndpoint -NotePropertyValue $serverEndpoint -Force
    return $run
}

function Stop-ServeGracefully {
    param($Run)
    Invoke-Curl -Method 'POST' -Uri ('http://' + $Run.ServerEndpoint + '/actuator/shutdown') | Out-Null
    if (-not $Run.Process.WaitForExit(60000)) { throw '优雅停机超时（60 秒内进程未退出）' }
    return $Run.Process.ExitCode
}

function Invoke-CliMode {
    param([string] $DatabaseName, [string] $DataRoot, [int] $ServerPort, [string] $Mode, [string] $RunDirectory)
    $script:task31CliSequence++
    $run = Start-CangshuProcess -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort `
        -LogName ('cli-' + $Mode + '-' + $script:task31CliSequence) -RunDirectory $RunDirectory -Mode $Mode
    if (-not $run.Process.WaitForExit(180000)) {
        Stop-Process -Id $run.Process.Id -Force -ErrorAction SilentlyContinue
        throw "CLI --mode=$Mode 超时未退出"
    }
    return [pscustomobject]@{
        ExitCode = $run.Process.ExitCode
        Stdout = Get-LogText $run.Stdout
        Stderr = Get-LogText $run.Stderr
        LogPath = $run.Stdout
        Mode = $Mode
    }
}

function Get-CliSummaryLine {
    param([string] $Stdout, [string] $Prefix)
    $lines = @(($Stdout -split "`r?`n") | Where-Object { $_.StartsWith($Prefix) })
    if ($lines.Count -eq 0) { return '' }
    return $lines[-1]
}

function Throw-Task31Miss {
    param([string] $Message)
    $exception = [System.InvalidOperationException]::new($Message)
    $exception.Data['Task31Miss'] = $true
    throw $exception
}

function Get-Task31AttemptAction {
    param([bool] $Miss, $Result, [int] $Attempt, [int] $Maximum)
    if ($null -ne $Result) { return 'record' }
    if ($Miss -and $Attempt -lt $Maximum) { return 'retry' }
    if ($Miss) { return 'exhausted' }
    throw '尝试既无结果也非明确未命中，拒绝继续'
}

function Get-LogMarkerLine {
    param([string] $Text, [string] $Marker)
    $lines = @(($Text -split "`r?`n") | Where-Object { $_.Contains($Marker) })
    if ($lines.Count -eq 0) { return '' }
    return $lines[-1]
}

function Get-SummaryField {
    param([string] $Line, [string] $Key)
    if ($Line -match ($Key + '=([^|]+)')) { return $Matches[1].Trim() }
    return ''
}

# ════════════════════════════════════════════════════════════════════════════════════════════
#  单元 5-1（① 提交后强杀）——本阶段冒烟格
# ════════════════════════════════════════════════════════════════════════════════════════════
function Invoke-Cell1_5_Run {
    param([string] $CellId, [int] $Run, [string] $DatabaseName, [string] $DataRoot, [int] $ServerPort,
        [string] $RunDirectory, $Payload)
    $checks = @()
    $serverEndpoint = '127.0.0.1:' + $ServerPort
    # 控制器基路径＝/api（ResourceController 的 @RequestMapping），健康检查在 /actuator 下不带 /api。
    $uploadUri = 'http://' + $serverEndpoint + '/api/resources'

    Reset-IsolatedDatabase -DatabaseName $DatabaseName
    Assert-RunDataRoot -DataRoot $DataRoot -RunDirectory $RunDirectory
    if (Test-Path -LiteralPath $DataRoot) { throw "拒绝覆盖已有数据根：$DataRoot" }
    New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null

    $serve = Start-ServeAndWait -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort `
        -LogName 'serve-1' -RunDirectory $RunDirectory
    $snapshot0 = Save-Snapshot -Label '0-before-upload' -RunDirectory $RunDirectory -DatabaseName $DatabaseName `
        -DataRoot $DataRoot -ServerPort $ServerPort

    # 上传（节流客户端拉长窗口；本格判据只看 201 之后的提交后状态）
    $upload = Start-ThrottledUpload -Uri $uploadUri -UploadPath $Payload.Path -RunDirectory $RunDirectory `
        -Name 'upload' -RateLimitSeconds $RateLimit
    if (-not $upload.Process.WaitForExit(180000)) {
        Stop-Process -Id $upload.Process.Id -Force -ErrorAction SilentlyContinue
        throw "上传客户端未在 180 秒内结束（见 $($upload.Error)）"
    }
    $httpCode = (Get-Content -LiteralPath $upload.Code -Raw -Encoding UTF8).Trim()
    $responseJson = Get-Content -LiteralPath $upload.Response -Raw -Encoding UTF8
    $checks += [pscustomobject]@{ Name = 'HTTP 上传返回 201'; Pass = ($httpCode -eq '201'); Detail = "http_code=$httpCode" }
    $uploaded = if ($responseJson) { $responseJson | ConvertFrom-Json } else { $null }
    $checks += [pscustomobject]@{ Name = '上传响应符合 id/hash/contentId/size/deduplicated 契约';
        Pass = (Test-Task31UploadResponse -Response $uploaded -Payload $Payload -Deduplicated $false);
        Detail = if ($uploaded) { 'id=' + $uploaded.id + '|hash=' + $uploaded.hash.digest + '|sizeBytes=' + $uploaded.sizeBytes } else { '（空响应）' } }

    # 快照 1＝杀前（点 5 口径：真实 HTTP 响应之后、强杀之前）
    $snapshot1 = Save-Snapshot -Label '1-before-kill' -RunDirectory $RunDirectory -DatabaseName $DatabaseName `
        -DataRoot $DataRoot -ServerPort $ServerPort -Extra @('http_code=' + $httpCode, 'response=' + $responseJson)

    # 强杀（点 5：响应后即杀）
    $killNote = Stop-CangshuHard -Process $serve.Process

    # 快照 2＝杀后不重启（只读核对）
    $snapshot2 = Save-Snapshot -Label '2-after-kill-no-restart' -RunDirectory $RunDirectory -DatabaseName $DatabaseName `
        -DataRoot $DataRoot -ServerPort $ServerPort -Extra @('kill=' + $killNote)

    $state2 = Get-DatabaseState -DatabaseName $DatabaseName
    $checks += [pscustomobject]@{ Name = '快照2 三表齐全（提交后强杀不丢行）'; Pass = ($state2 -join '') -match 'counts\|content=1,location=1,resource=1';
        Detail = ($state2 -join ' / ') }
    $identity2 = Test-Task31ReadyIdentity -DatabaseName $DatabaseName -Payload $Payload -ResourceIds @($uploaded.id) -ContentId $uploaded.contentId
    $checks += [pscustomobject]@{ Name = '库内资源→内容→位置与响应摘要、大小及存储键一致'; Pass = $identity2.Pass; Detail = $identity2.Detail }
    $checks += [pscustomobject]@{ Name = '快照2 serve 端口已关闭'; Pass = (-not (Test-TcpListener -TargetHost '127.0.0.1' -Port $ServerPort));
        Detail = 'port=' + $ServerPort }

    # 重启 → 启动对账（04 §8 步骤 3：对账先于服务开始）
    $serve2 = Start-ServeAndWait -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort `
        -LogName 'serve-2-restart' -RunDirectory $RunDirectory
    $startupReconcile = Wait-ForLogPattern -Path $serve2.Stdout -Pattern 'CANGSHU|job|reconcile|reconcile|' -WaitSeconds $TimeoutSeconds -Process $serve2.Process
    $reconcileLine = Get-LogMarkerLine -Text (Get-LogText $serve2.Stdout) -Marker 'CANGSHU|job|reconcile|reconcile|'
    $checks += [pscustomobject]@{ Name = '重启后启动对账已运行且无异常'; Pass = ($startupReconcile -and $reconcileLine -match 'needsAttention=false');
        Detail = $reconcileLine }

    # 重启后资源可读（HTTP）
    $detailOut = Join-Path $RunDirectory 'restart-detail.json'
    $detailStatus = Get-HttpStatus -Method 'GET' -Uri ($uploadUri + '/' + $uploaded.id) -OutFile $detailOut
    $contentOut = Join-Path $RunDirectory 'restart-content.bin'
    $contentStatus = Get-HttpStatus -Method 'GET' -Uri ($uploadUri + '/' + $uploaded.id + '/content') -OutFile $contentOut
    $contentDigest = if (Test-Path -LiteralPath $contentOut) { (Get-FileHash -LiteralPath $contentOut -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' }
    $checks += [pscustomobject]@{ Name = '重启后资源详情可读 200'; Pass = ($detailStatus.Status -eq '200'); Detail = 'http_code=' + $detailStatus.Status }
    $checks += [pscustomobject]@{ Name = '重启后字节可下载 200'; Pass = ($contentStatus.Status -eq '200'); Detail = 'http_code=' + $contentStatus.Status }
    $checks += [pscustomobject]@{ Name = '下载字节摘要与内容身份相符'; Pass = ($contentDigest -eq $Payload.Digest);
        Detail = 'downloaded=' + $contentDigest + '|expected=' + $Payload.Digest }

    # 快照 3＝重启后对账收敛（含 CLI 对账／GC 摘要）
    $gracefulExit = Stop-ServeGracefully -Run $serve2
    $cliReconcile = Invoke-CliMode -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Mode 'reconcile' -RunDirectory $RunDirectory
    $cliGc = Invoke-CliMode -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Mode 'gc' -RunDirectory $RunDirectory
    $reconcileSummary = Get-CliSummaryLine -Stdout $cliReconcile.Stdout -Prefix 'reconcile|'
    $gcSummary = Get-CliSummaryLine -Stdout $cliGc.Stdout -Prefix 'gc|'
    $checks += [pscustomobject]@{ Name = 'CLI 对账收敛（needsAttention=false 且 bytesMissing=0）';
        Pass = ($cliReconcile.ExitCode -eq 0 -and (Get-SummaryField $reconcileSummary 'needsAttention') -eq 'false' -and (Get-SummaryField $reconcileSummary 'bytesMissing') -eq '0');
        Detail = $reconcileSummary }
    $checks += [pscustomobject]@{ Name = 'CLI GC 无异常（needsAttention=false）';
        Pass = ((Get-SummaryField $gcSummary 'needsAttention') -eq 'false'); Detail = $gcSummary }
    $snapshot3 = Save-Snapshot -Label '3-restart-reconciled' -RunDirectory $RunDirectory -DatabaseName $DatabaseName `
        -DataRoot $DataRoot -ServerPort $ServerPort -Extra @(
            'graceful_exit_code=' + $gracefulExit,
            'cli_reconcile=' + $reconcileSummary,
            'cli_gc=' + $gcSummary,
            'detail_http=' + $detailStatus.Status,
            'content_http=' + $contentStatus.Status,
            'content_sha256=' + $contentDigest)

    $state3 = Get-DatabaseState -DatabaseName $DatabaseName
    $checks += [pscustomobject]@{ Name = '快照3 内容就绪 ＋ 位置在'; Pass = ($state3 -join '') -match 'resource\|READY' -and ($state3 -join '') -match 'location\|sha256/';
        Detail = ($state3 -join ' / ') }
    $tree3 = @(Get-DataRootTree -DataRoot $DataRoot)
    $checks += [pscustomobject]@{ Name = '快照3 最终键字节在且大小相符';
        Pass = (@($tree3 | Where-Object { $_ -like ('*' + $Payload.Digest + '|size=' + $Payload.SizeBytes) }).Count -eq 1);
        Detail = ($tree3 -join ' ; ') }
    $checks += [pscustomobject]@{ Name = '日志无 CANGSHU|alert'; Pass = ((Get-LogText $serve2.Stdout) -notmatch 'CANGSHU\|alert');
        Detail = 'serve-2-restart.log' }

    $failed = @($checks | Where-Object { -not $_.Pass })
    return [pscustomobject]@{
        CellId = $CellId; Point = 5; Class = '①'; Run = $Run
        Database = $DatabaseName; DataRoot = $DataRoot; ServerPort = $ServerPort
        Verdict = if ($failed.Count -eq 0) { '全有' } else { '不符' }
        Checks = $checks
        SnapshotFiles = @($snapshot0.Path, $snapshot1.Path, $snapshot2.Path, $snapshot3.Path)
        BlockEvidence = ''
        HttpCode = $httpCode
        Digest = $Payload.Digest
        FailedChecks = @($failed | ForEach-Object { $_.Name + '：' + $_.Detail })
    }
}

# ════════════════════════════════════════════════════════════════════════════════════════════
#  单元 4-1（① 三行已插、COMMIT 未落）——注入格演示（提交门约束触发器 ＋ 阻塞点证据）
# ════════════════════════════════════════════════════════════════════════════════════════════
function Invoke-Cell4_1_Run {
    param([string] $CellId, [int] $Run, [string] $DatabaseName, [string] $DataRoot, [int] $ServerPort,
        [string] $RunDirectory, $Payload)
    $checks = @()
    $serverEndpoint = '127.0.0.1:' + $ServerPort
    $uploadUri = 'http://' + $serverEndpoint + '/api/resources'

    Reset-IsolatedDatabase -DatabaseName $DatabaseName
    Assert-RunDataRoot -DataRoot $DataRoot -RunDirectory $RunDirectory
    if (Test-Path -LiteralPath $DataRoot) { throw "拒绝覆盖已有数据根：$DataRoot" }
    New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null

    $serve = Start-ServeAndWait -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort `
        -LogName 'serve-1' -RunDirectory $RunDirectory
    $snapshot0 = Save-Snapshot -Label '0-before-upload' -RunDirectory $RunDirectory -DatabaseName $DatabaseName `
        -DataRoot $DataRoot -ServerPort $ServerPort

    # 装夹具：提交门约束触发器（精确卡在 COMMIT 未落）
    $fixtureSql = New-CommitGateTrigger -DatabaseName $DatabaseName -RunDirectory $RunDirectory `
        -Table 'resource' -Event 'INSERT' -SleepSeconds 45
    $fixtureInventory = Get-FixtureInventory -DatabaseName $DatabaseName

    # 节流上传，等后端被卡在接缝上
    $upload = Start-ThrottledUpload -Uri $uploadUri -UploadPath $Payload.Path -RunDirectory $RunDirectory `
        -Name 'upload' -RateLimitSeconds $RateLimit
    $pinned = Wait-ForBlockedBackend -DatabaseName $DatabaseName -WaitSeconds $BlockWaitSeconds -WaitEventPattern 'PgSleep'
    if (-not $pinned) {
        Stop-Process -Id $upload.Process.Id -Force -ErrorAction SilentlyContinue
        Stop-CangshuHard -Process $serve.Process | Out-Null
        Remove-FixtureObjects -DatabaseName $DatabaseName -RunDirectory $RunDirectory | Out-Null
        if ($serve.Process.HasExited) { throw "点4 serve在提交门前退出；日志：$($serve.Stdout)" }
        Throw-Task31Miss "未在 $BlockWaitSeconds 秒内命中点 4 接缝（见 $RunDirectory）"
    }
    $blockEvidence = Save-BlockEvidence -Label '4-1-before-kill' -DatabaseName $DatabaseName -RunDirectory $RunDirectory
    $snapshot1 = Save-Snapshot -Label '1-before-kill' -RunDirectory $RunDirectory -DatabaseName $DatabaseName `
        -DataRoot $DataRoot -ServerPort $ServerPort -Extra @('blocked_at=COMMIT', 'fixture=' + $fixtureSql)

    Stop-CangshuHard -Process $serve.Process | Out-Null
    Stop-Process -Id $upload.Process.Id -Force -ErrorAction SilentlyContinue

    # 快照 2＝杀后不重启
    $snapshot2 = Save-Snapshot -Label '2-after-kill-no-restart' -RunDirectory $RunDirectory -DatabaseName $DatabaseName `
        -DataRoot $DataRoot -ServerPort $ServerPort
    $state2 = Get-DatabaseState -DatabaseName $DatabaseName
    $checks += [pscustomobject]@{ Name = '快照2 三表无行（事务回滚）'; Pass = ($state2 -join '') -match 'counts\|content=0,location=0,resource=0';
        Detail = ($state2 -join ' / ') }
    $tree2 = @(Get-DataRootTree -DataRoot $DataRoot)
    $orphanInPlace = @($tree2 | Where-Object { $_ -like ('sha256/*' + $Payload.Digest + '|size=' + $Payload.SizeBytes) }).Count
    $checks += [pscustomobject]@{ Name = '快照2 孤儿字节在最终键上（移动已发生）'; Pass = ($orphanInPlace -eq 1); Detail = ($tree2 -join ' ; ') }

    # 夹具进入 pg_constraint；所有夹具必须先拆除，才允许重启。
    Remove-FixtureObjects -DatabaseName $DatabaseName -RunDirectory $RunDirectory | Out-Null
    $checks += [pscustomobject]@{ Name = '重启前夹具已拆除'; Pass = (@(Get-FixtureInventory -DatabaseName $DatabaseName | Where-Object { $_ -like '*task31_fixture_gate*' }).Count -eq 0);
        Detail = 'install=' + ($fixtureInventory -join ';') }
    # 重启 → 启动对账应把孤儿隔离
    $serve2 = Start-ServeAndWait -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort `
        -LogName 'serve-2-restart' -RunDirectory $RunDirectory
    $orphanLine = Wait-ForLogPattern -Path $serve2.Stdout -Pattern 'CANGSHU|job|reconcile|orphan|storageKey=' -WaitSeconds $TimeoutSeconds -Process $serve2.Process
    $checks += [pscustomobject]@{ Name = '重启对账识别孤儿字节'; Pass = $orphanLine;
        Detail = ('found=' + $orphanLine + '; log=' + $serve2.Stdout) }
    Stop-ServeGracefully -Run $serve2 | Out-Null
    $cliReconcile = Invoke-CliMode -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Mode 'reconcile' -RunDirectory $RunDirectory
    $reconcileSummary = Get-CliSummaryLine -Stdout $cliReconcile.Stdout -Prefix 'reconcile|'
    $checks += [pscustomobject]@{ Name = '一次对账收敛（孤儿已隔离，三表仍无行）';
        Pass = ((Get-SummaryField $reconcileSummary 'needsAttention') -eq 'false');
        Detail = $reconcileSummary }

    $snapshot3 = Save-Snapshot -Label '3-restart-reconciled' -RunDirectory $RunDirectory -DatabaseName $DatabaseName `
        -DataRoot $DataRoot -ServerPort $ServerPort -Extra @('cli_reconcile=' + $reconcileSummary)
    $state3 = Get-DatabaseState -DatabaseName $DatabaseName
    $checks += [pscustomobject]@{ Name = '快照3 仍无可见新增'; Pass = ($state3 -join '') -match 'counts\|content=0,location=0,resource=0';
        Detail = ($state3 -join ' / ') }
    $tree3 = @(Get-DataRootTree -DataRoot $DataRoot)
    $checks += [pscustomobject]@{ Name = '快照3 孤儿已移入隔离区'; Pass = (@($tree3 | Where-Object { $_ -like ('orphan/sha256/*' + $Payload.Digest + '*') }).Count -ge 1);
        Detail = ($tree3 -join ' ; ') }
    $checks += [pscustomobject]@{ Name = '阻塞点证据已留存（pg_stat_activity ＋ pg_locks 原文）';
        Pass = ((Get-LogText $blockEvidence.Path) -match 'PgSleep'); Detail = $blockEvidence.Path }

    $failed = @($checks | Where-Object { -not $_.Pass })
    return [pscustomobject]@{
        CellId = $CellId; Point = 4; Class = '①'; Run = $Run
        Database = $DatabaseName; DataRoot = $DataRoot; ServerPort = $ServerPort
        Verdict = if ($failed.Count -eq 0) { '全无' } else { '不符' }
        Checks = $checks
        SnapshotFiles = @($snapshot0.Path, $snapshot1.Path, $snapshot2.Path, $snapshot3.Path)
        BlockEvidence = $blockEvidence.Path
        HttpCode = '(上传被强杀中断，无响应)'
        Digest = $Payload.Digest
        FailedChecks = @($failed | ForEach-Object { $_.Name + '：' + $_.Detail })
    }
}

function Invoke-UploadAndWait {
    param([string] $Uri, $Payload, [string] $RunDirectory, [string] $Name, [string] $Limit = '')
    $client = Start-ThrottledUpload -Uri $Uri -UploadPath $Payload.Path -RunDirectory $RunDirectory -Name $Name -RateLimitSeconds $Limit
    if (-not $client.Process.WaitForExit(900000)) { throw "上传客户端超时：$Name" }
    $code = (Get-Content -LiteralPath $client.Code -Raw -Encoding UTF8).Trim()
    $body = Get-Content -LiteralPath $client.Response -Raw -Encoding UTF8
    $json = if ($body) { $body | ConvertFrom-Json } else { $null }
    return [pscustomobject]@{ Code=$code; Body=$body; Json=$json; Client=$client }
}

function Test-Task31UploadResponse {
    param($Response, $Payload, [bool] $Deduplicated)
    if ($null -eq $Response -or $null -eq $Response.hash) { return $false }
    $resourceId = [guid]::Empty
    $contentId = [guid]::Empty
    return ([guid]::TryParse([string]$Response.id, [ref]$resourceId) -and
        [guid]::TryParse([string]$Response.contentId, [ref]$contentId) -and
        $resourceId -ne [guid]::Empty -and $contentId -ne [guid]::Empty -and
        $Response.hash.algorithm -ceq 'sha256' -and
        $Response.hash.digest -ceq $Payload.Digest -and
        [long]$Response.sizeBytes -eq [long]$Payload.SizeBytes -and
        $Response.deduplicated -is [bool] -and $Response.deduplicated -eq $Deduplicated)
}

function Start-Task31HttpRequest {
    param([string] $Method, [string] $Uri, [string] $RunDirectory, [string] $Name)
    $response = Join-Path $RunDirectory "$Name-response.txt"
    $code = Join-Path $RunDirectory "$Name-http-code.txt"
    $errorLog = Join-Path $RunDirectory "$Name-client.err.log"
    $arguments = @('--silent','--show-error','--noproxy','*','--max-time','180',
        '--request',$Method,'--output',$response,'--write-out','%{http_code}',$Uri)
    $process = Start-Process -FilePath $curlPath -ArgumentList (Quote-Arguments $arguments) -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $code -RedirectStandardError $errorLog
    $ownedProcesses.Add($process)
    return [pscustomobject]@{Process=$process;Response=$response;Code=$code;Error=$errorLog}
}

function New-SeededResource {
    param([string] $DatabaseName, [string] $DataRoot, [int] $ServerPort,
        [string] $RunDirectory, $Payload)
    Reset-IsolatedDatabase -DatabaseName $DatabaseName
    Assert-RunDataRoot -DataRoot $DataRoot -RunDirectory $RunDirectory
    if (Test-Path -LiteralPath $DataRoot) { throw "拒绝覆盖已有数据根：$DataRoot" }
    New-Item -ItemType Directory -Path $DataRoot | Out-Null
    $serve = Start-ServeAndWait -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -LogName 'serve-seed' -RunDirectory $RunDirectory
    $uri = 'http://127.0.0.1:' + $ServerPort + '/api/resources'
    $upload = Invoke-UploadAndWait -Uri $uri -Payload $Payload -RunDirectory $RunDirectory -Name 'seed'
    if ($upload.Code -ne '201' -or -not (Test-Task31UploadResponse -Response $upload.Json -Payload $Payload -Deduplicated $false)) {
        throw "前置上传未获有效 201：code=$($upload.Code); body=$($upload.Body)"
    }
    return [pscustomobject]@{ Serve=$serve; Uri=$uri; Resource=$upload.Json; Upload=$upload }
}

function New-GcPendingSeed {
    param([string] $DatabaseName, [string] $DataRoot, [int] $ServerPort,
        [string] $RunDirectory, $Payload)
    $seed = New-SeededResource -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -RunDirectory $RunDirectory -Payload $Payload
    $soft = Get-HttpStatus -Method DELETE -Uri ($seed.Uri + '/' + $seed.Resource.id) -OutFile (Join-Path $RunDirectory 'seed-soft-delete.txt')
    $empty = Get-HttpStatus -Method DELETE -Uri ($seed.Uri + '/trash?confirm=true') -OutFile (Join-Path $RunDirectory 'seed-empty-trash.json')
    $state = @(Get-DatabaseState -DatabaseName $DatabaseName)
    if ($soft.Status -ne '204' -or $empty.Status -ne '200' -or
        ($state -join ';') -notmatch 'content\|RECLAIM_PENDING' -or
        ($state -join ';') -notmatch 'counts\|content=1,location=1,resource=0') {
        throw "GC 前置状态不成立：soft=$($soft.Status),empty=$($empty.Status),state=$($state -join ';')"
    }
    Stop-ServeGracefully -Run $seed.Serve | Out-Null
    $blob = Join-Path $DataRoot ('sha256/' + $Payload.Digest.Substring(0,2) + '/' + $Payload.Digest.Substring(2,2) + '/' + $Payload.Digest)
    if (-not (Test-Path -LiteralPath $blob)) { throw "GC 前置字节不存在：$blob" }
    return [pscustomobject]@{Seed=$seed;Blob=$blob;State=$state}
}

function New-Task31Result {
    param([string] $CellId, [int] $Run, [string] $DatabaseName, [string] $DataRoot,
        [int] $ServerPort, $Checks, $Snapshots, [string] $BlockEvidence = '',
        [string] $HttpCode = '', [string] $Digest = '')
    $failed = @($Checks | Where-Object { -not $_.Pass })
    return [pscustomobject]@{
        CellId=$CellId; Point=[int]$CellId.Split('-')[0]; Class=@{'1'='①';'2'='②';'3'='③';'4'='④'}[$CellId.Split('-')[1]]
        Run=$Run; Database=$DatabaseName; DataRoot=$DataRoot; ServerPort=$ServerPort
        Verdict=$(if($failed.Count -eq 0){if($CellId -in @('5-1','5-2')){'全有'}else{'全无'}}else{'不符'})
        Checks=@($Checks); SnapshotFiles=@($Snapshots); BlockEvidence=$BlockEvidence
        HttpCode=$HttpCode; Digest=$Digest; FailedChecks=@($failed | ForEach-Object { $_.Name + '：' + $_.Detail })
    }
}

# 点 3：BEFORE INSERT 触发器只延迟首条 content INSERT 的执行，移动已经完成，
# 但该 INSERT 尚未写入；普通 AFTER INSERT 触发器不符合这一接缝。
function Invoke-Cell3_1_Run {
    param([string] $CellId, [int] $Run, [string] $DatabaseName, [string] $DataRoot, [int] $ServerPort,
        [string] $RunDirectory, $Payload)
    $checks = @()
    Reset-IsolatedDatabase -DatabaseName $DatabaseName
    Assert-RunDataRoot -DataRoot $DataRoot -RunDirectory $RunDirectory
    if (Test-Path -LiteralPath $DataRoot) { throw "拒绝覆盖已有数据根：$DataRoot" }
    New-Item -ItemType Directory -Path $DataRoot | Out-Null
    $serve = Start-ServeAndWait -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -LogName 'serve-1' -RunDirectory $RunDirectory
    $snapshot0 = Save-Snapshot -Label '0-before-upload' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort
    $fixture = New-DelayTrigger -DatabaseName $DatabaseName -RunDirectory $RunDirectory -Table content -Event INSERT -Timing BEFORE -SleepSeconds 45
    $upload = Start-ThrottledUpload -Uri ('http://127.0.0.1:' + $ServerPort + '/api/resources') -UploadPath $Payload.Path `
        -RunDirectory $RunDirectory -Name upload -RateLimitSeconds $RateLimit
    if (-not (Wait-ForBlockedBackend -DatabaseName $DatabaseName -WaitSeconds $BlockWaitSeconds -WaitEventPattern 'PgSleep')) {
        if ($serve.Process.HasExited) { throw "点3 serve在触发器前退出；日志：$($serve.Stdout)" }
        Throw-Task31Miss '点 3 未命中 BEFORE content INSERT'
    }
    $block = Save-BlockEvidence -Label '3-1-before-kill' -DatabaseName $DatabaseName -RunDirectory $RunDirectory
    $tree1 = @(Get-DataRootTree -DataRoot $DataRoot)
    $state1 = @(Get-DatabaseState -DatabaseName $DatabaseName)
    $checks += [pscustomobject]@{Name='点3证据显示首条 INSERT 被阻塞';Pass=((Get-LogText $block.Path) -match 'PgSleep' -and (Get-LogText $block.Path) -match '(?i)insert.*content');Detail=$block.Path}
    $checks += [pscustomobject]@{Name='杀前最终键字节已在';Pass=(@($tree1 | Where-Object {$_ -like ('sha256/*' + $Payload.Digest + '|size=' + $Payload.SizeBytes)}).Count -eq 1);Detail=($tree1 -join ';')}
    $checks += [pscustomobject]@{Name='杀前尚无已提交元数据';Pass=(($state1 -join ';') -match 'counts\|content=0,location=0,resource=0');Detail=($state1 -join ';')}
    $snapshot1 = Save-Snapshot -Label '1-before-kill' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Extra @('fixture=' + $fixture,'point=BEFORE content INSERT')
    Stop-CangshuHard -Process $serve.Process | Out-Null
    if (-not $upload.Process.HasExited) { Stop-Process -Id $upload.Process.Id -Force -ErrorAction Stop }
    $snapshot2 = Save-Snapshot -Label '2-after-kill-no-restart' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort
    $state2 = @(Get-DatabaseState -DatabaseName $DatabaseName)
    $checks += [pscustomobject]@{Name='杀后事务回滚三表无行';Pass=(($state2 -join ';') -match 'counts\|content=0,location=0,resource=0');Detail=($state2 -join ';')}
    Remove-FixtureObjects -DatabaseName $DatabaseName -RunDirectory $RunDirectory | Out-Null
    $checks += [pscustomobject]@{Name='重启前夹具已拆除';Pass=(@(Get-FixtureInventory -DatabaseName $DatabaseName | Where-Object {$_ -like '*task31_fixture_gate*'}).Count -eq 0);Detail=$fixture}
    $serve2 = Start-ServeAndWait -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -LogName 'serve-2-restart' -RunDirectory $RunDirectory
    $orphan = Wait-ForLogPattern -Path $serve2.Stdout -Pattern 'CANGSHU|job|reconcile|orphan|storageKey=' -WaitSeconds $TimeoutSeconds -Process $serve2.Process
    $checks += [pscustomobject]@{Name='重启对账报告孤儿';Pass=$orphan;Detail=$serve2.Stdout}
    Stop-ServeGracefully -Run $serve2 | Out-Null
    $reconcile = Invoke-CliMode -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Mode reconcile -RunDirectory $RunDirectory
    $line = Get-CliSummaryLine -Stdout $reconcile.Stdout -Prefix 'reconcile|'
    $checks += [pscustomobject]@{Name='对账再次运行后收敛';Pass=($reconcile.ExitCode -eq 0 -and (Get-SummaryField $line needsAttention) -eq 'false');Detail=$line}
    $snapshot3 = Save-Snapshot -Label '3-restart-reconciled' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Extra @('cli_reconcile=' + $line)
    $state3 = @(Get-DatabaseState -DatabaseName $DatabaseName)
    $tree3 = @(Get-DataRootTree -DataRoot $DataRoot)
    $checks += [pscustomobject]@{Name='最终无新增资源且孤儿已隔离';Pass=(($state3 -join ';') -match 'counts\|content=0,location=0,resource=0' -and @($tree3 | Where-Object {$_ -like ('orphan/sha256/*' + $Payload.Digest + '*')}).Count -eq 1);Detail=(($state3 + $tree3) -join ';')}
    $failed = @($checks | Where-Object {-not $_.Pass})
    return [pscustomobject]@{CellId=$CellId;Point=3;Class='①';Run=$Run;Database=$DatabaseName;DataRoot=$DataRoot;ServerPort=$ServerPort;
        Verdict=$(if($failed.Count -eq 0){'全无'}else{'不符'});Checks=$checks;SnapshotFiles=@($snapshot0.Path,$snapshot1.Path,$snapshot2.Path,$snapshot3.Path);
        BlockEvidence=$block.Path;HttpCode='(上传被强杀中断)';Digest=$Payload.Digest;FailedChecks=@($failed | ForEach-Object {$_.Name + '：' + $_.Detail})}
}

function Invoke-Cell4_2_Run {
    param([string] $CellId, [int] $Run, [string] $DatabaseName, [string] $DataRoot, [int] $ServerPort,
        [string] $RunDirectory, $Payload)
    $seed = New-SeededResource -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -RunDirectory $RunDirectory -Payload $Payload
    $checks = @()
    $snapshot0 = Save-Snapshot -Label '0-seed-ready' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort
    $blob = Join-Path $DataRoot ('sha256/' + $Payload.Digest.Substring(0,2) + '/' + $Payload.Digest.Substring(2,2) + '/' + $Payload.Digest)
    $originalWrite = (Get-Item -LiteralPath $blob).LastWriteTimeUtc.Ticks
    $fixture = New-CommitGateTrigger -DatabaseName $DatabaseName -RunDirectory $RunDirectory -Table resource -Event INSERT -SleepSeconds 45
    $upload = Start-ThrottledUpload -Uri $seed.Uri -UploadPath $Payload.Path -RunDirectory $RunDirectory -Name 'reuse' -RateLimitSeconds $RateLimit
    if (-not (Wait-ForBlockedBackend -DatabaseName $DatabaseName -WaitSeconds $BlockWaitSeconds -WaitEventPattern PgSleep)) {
        if ($seed.Serve.Process.HasExited) { throw "点4-2 serve在提交门前退出；日志：$($seed.Serve.Stdout)" }
        Throw-Task31Miss '点 4-2 未命中资源 INSERT 的提交门'
    }
    $block = Save-BlockEvidence -Label '4-2-before-kill' -DatabaseName $DatabaseName -RunDirectory $RunDirectory
    $state1 = @(Get-DatabaseState -DatabaseName $DatabaseName)
    $checks += [pscustomobject]@{Name='资源 INSERT 提交门确已命中';Pass=((Get-LogText $block.Path) -match 'PgSleep' -and
        (Get-LogText $fixture) -match '(?i)CREATE CONSTRAINT TRIGGER.*AFTER INSERT ON cangshu_m1\.resource' -and
        (Get-LogText $block.Path) -match '(?i)(COMMIT|insert.*resource)');Detail=($fixture + ';' + $block.Path)}
    $checks += [pscustomobject]@{Name='杀前仅原资源可见';Pass=(($state1 -join ';') -match 'counts\|content=1,location=1,resource=1');Detail=($state1 -join ';')}
    $snapshot1 = Save-Snapshot -Label '1-before-kill' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Extra @('fixture=' + $fixture)
    Stop-CangshuHard -Process $seed.Serve.Process | Out-Null
    if (-not $upload.Process.HasExited) { Stop-Process -Id $upload.Process.Id -Force -ErrorAction Stop }
    $snapshot2 = Save-Snapshot -Label '2-after-kill-no-restart' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort
    $state2 = @(Get-DatabaseState -DatabaseName $DatabaseName)
    $tree2 = @(Get-DataRootTree -DataRoot $DataRoot)
    $checks += [pscustomobject]@{Name='复用资源 INSERT 回滚且原资源完好';Pass=(($state2 -join ';') -match 'counts\|content=1,location=1,resource=1' -and @($tree2 | Where-Object {$_ -eq ('sha256/' + $Payload.Digest.Substring(0,2) + '/' + $Payload.Digest.Substring(2,2) + '/' + $Payload.Digest + '|size=' + $Payload.SizeBytes)}).Count -eq 1);Detail=(($state2 + $tree2) -join ';')}
    $checks += [pscustomobject]@{Name='原位物理字节未重写';Pass=((Get-Item -LiteralPath $blob).LastWriteTimeUtc.Ticks -eq $originalWrite -and
        (Get-FileHash -LiteralPath $blob -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Payload.Digest);Detail="originalWriteTicks=$originalWrite;tree=$($tree2 -join ';')"}
    $tmpFiles = @(Get-ChildItem -LiteralPath (Join-Path $DataRoot 'tmp') -File -Filter 'upload-*.tmp' -ErrorAction SilentlyContinue)
    $checks += [pscustomobject]@{Name='杀后复用请求临时字节残留可归属';Pass=($tmpFiles.Count -eq 1 -and $tmpFiles[0].Length -eq $Payload.SizeBytes);Detail=($tmpFiles.FullName -join ';')}
    Remove-FixtureObjects -DatabaseName $DatabaseName -RunDirectory $RunDirectory | Out-Null
    $checks += [pscustomobject]@{Name='重启前夹具已拆除';Pass=(@(Get-FixtureInventory -DatabaseName $DatabaseName | Where-Object {$_ -like '*task31_fixture_gate*'}).Count -eq 0);Detail=$fixture}
    if($tmpFiles.Count -ne 1){throw '复用提交门杀后业务 tmp 数量不为1，无法安全施加加龄夹具'}
    $tmpRoot = [System.IO.Path]::GetFullPath((Join-Path $DataRoot 'tmp'))
    $fullTmp = [System.IO.Path]::GetFullPath($tmpFiles[0].FullName)
    if(-not $fullTmp.StartsWith($tmpRoot + [System.IO.Path]::DirectorySeparatorChar,[System.StringComparison]::OrdinalIgnoreCase) -or
        ((Get-Item -LiteralPath $fullTmp -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)){
        throw "拒绝对非本格普通业务 tmp 加龄：$fullTmp"
    }
    $oldTime = (Get-Item -LiteralPath $fullTmp).LastWriteTimeUtc
    (Get-Item -LiteralPath $fullTmp).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-25)
    $ageEvidence = Join-Path $RunDirectory 'tmp-aging-fixture.txt'
    Set-Content -LiteralPath $ageEvidence -Encoding UTF8 -Value @('快照2原样保留；只加龄本格复用tmp',
        'path=' + $fullTmp,'beforeLastWriteUtc=' + $oldTime.ToString('o'),
        'afterLastWriteUtc=' + (Get-Item -LiteralPath $fullTmp).LastWriteTimeUtc.ToString('o'))
    $serve2 = Start-ServeAndWait -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -LogName 'serve-restart' -RunDirectory $RunDirectory
    $startupLine = Get-LogMarkerLine -Text (Get-LogText $serve2.Stdout) -Marker 'CANGSHU|job|reconcile|reconcile|'
    $deleted = Get-SummaryField -Line $startupLine -Key tempDeleted
    $checks += [pscustomobject]@{Name='重启对账清理加龄复用tmp';Pass=(-not (Test-Path -LiteralPath $fullTmp) -and $deleted -match '^\d+$' -and [int]$deleted -ge 1);Detail=$startupLine}
    $detail = Get-HttpStatus -Method GET -Uri ($seed.Uri + '/' + $seed.Resource.id) -OutFile (Join-Path $RunDirectory 'restart-original.json')
    $downloadPath = Join-Path $RunDirectory 'restart-original.bin'
    $content = Get-HttpStatus -Method GET -Uri ($seed.Uri + '/' + $seed.Resource.id + '/content') -OutFile $downloadPath
    $downloadDigest = if(Test-Path $downloadPath){(Get-FileHash $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant()}else{''}
    $checks += [pscustomobject]@{Name='重启后原资源与字节可读';Pass=($detail.Status -eq '200' -and $content.Status -eq '200' -and $downloadDigest -eq $Payload.Digest);Detail="detail=$($detail.Status),download=$($content.Status),digest=$downloadDigest"}
    Stop-ServeGracefully -Run $serve2 | Out-Null
    $reconcile = Invoke-CliMode -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Mode reconcile -RunDirectory $RunDirectory
    $line = Get-CliSummaryLine -Stdout $reconcile.Stdout -Prefix 'reconcile|'
    $checks += [pscustomobject]@{Name='对账干净';Pass=($reconcile.ExitCode -eq 0 -and (Get-SummaryField $line needsAttention) -eq 'false');Detail=$line}
    $snapshot3 = Save-Snapshot -Label '3-restart-reconciled' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Extra @('startup_reconcile=' + $startupLine,'cli_reconcile=' + $line,'original_detail=' + $detail.Status,'original_download=' + $content.Status,'tmp_aging_evidence=' + $ageEvidence)
    $state3 = @(Get-DatabaseState -DatabaseName $DatabaseName)
    $checks += [pscustomobject]@{Name='最终仍仅一条引用';Pass=(($state3 -join ';') -match 'counts\|content=1,location=1,resource=1');Detail=($state3 -join ';')}
    return New-Task31Result -CellId $CellId -Run $Run -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort `
        -Checks $checks -Snapshots @($snapshot0.Path,$snapshot1.Path,$snapshot2.Path,$snapshot3.Path) -BlockEvidence $block.Path -Digest $Payload.Digest
}

function Invoke-Cell5_2_Run {
    param([string] $CellId, [int] $Run, [string] $DatabaseName, [string] $DataRoot, [int] $ServerPort,
        [string] $RunDirectory, $Payload)
    $seed = New-SeededResource -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -RunDirectory $RunDirectory -Payload $Payload
    $checks = @()
    $snapshot0 = Save-Snapshot -Label '0-seed-ready' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort
    $blob = Join-Path $DataRoot ('sha256/' + $Payload.Digest.Substring(0,2) + '/' + $Payload.Digest.Substring(2,2) + '/' + $Payload.Digest)
    $before = Get-Item -LiteralPath $blob
    $beforeWrite = $before.LastWriteTimeUtc.Ticks
    $second = Invoke-UploadAndWait -Uri $seed.Uri -Payload $Payload -RunDirectory $RunDirectory -Name 'reuse'
    $checks += [pscustomobject]@{Name='复用响应 201 且 deduplicated=true';Pass=($second.Code -eq '201' -and
        (Test-Task31UploadResponse -Response $second.Json -Payload $Payload -Deduplicated $true) -and
        $second.Json.id -ne $seed.Resource.id -and $second.Json.contentId -eq $seed.Resource.contentId);Detail="code=$($second.Code);body=$($second.Body)"}
    $snapshot1 = Save-Snapshot -Label '1-before-kill' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Extra @('http_code=' + $second.Code,'response=' + $second.Body)
    Stop-CangshuHard -Process $seed.Serve.Process | Out-Null
    $snapshot2 = Save-Snapshot -Label '2-after-kill-no-restart' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort
    $state2 = @(Get-DatabaseState -DatabaseName $DatabaseName)
    $afterWrite = (Get-Item -LiteralPath $blob).LastWriteTimeUtc.Ticks
    $checks += [pscustomobject]@{Name='新增一条引用但内容位置各一条';Pass=(($state2 -join ';') -match 'counts\|content=1,location=1,resource=2');Detail=($state2 -join ';')}
    $identity2 = Test-Task31ReadyIdentity -DatabaseName $DatabaseName -Payload $Payload `
        -ResourceIds @($seed.Resource.id,$second.Json.id) -ContentId $seed.Resource.contentId
    $checks += [pscustomobject]@{Name='两资源均关联同一正确内容身份与位置';Pass=$identity2.Pass;Detail=$identity2.Detail}
    $checks += [pscustomobject]@{Name='原位字节未重写';Pass=($beforeWrite -eq $afterWrite -and (Get-FileHash -LiteralPath $blob -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Payload.Digest);Detail="beforeTicks=$beforeWrite,afterTicks=$afterWrite"}
    $serve2 = Start-ServeAndWait -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -LogName 'serve-restart' -RunDirectory $RunDirectory
    foreach($entry in @(@{Name='original';Id=$seed.Resource.id},@{Name='reused';Id=$second.Json.id})) {
        $out = Join-Path $RunDirectory ('restart-' + $entry.Name + '.bin')
        $status = Get-HttpStatus -Method GET -Uri ($seed.Uri + '/' + $entry.Id + '/content') -OutFile $out
        $digest = if(Test-Path $out){(Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash.ToLowerInvariant()}else{''}
        $checks += [pscustomobject]@{Name=('重启后' + $entry.Name + '可读');Pass=($status.Status -eq '200' -and $digest -eq $Payload.Digest);Detail="code=$($status.Status),digest=$digest"}
    }
    Stop-ServeGracefully -Run $serve2 | Out-Null
    $reconcile = Invoke-CliMode -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Mode reconcile -RunDirectory $RunDirectory
    $line = Get-CliSummaryLine -Stdout $reconcile.Stdout -Prefix 'reconcile|'
    $checks += [pscustomobject]@{Name='对账干净';Pass=($reconcile.ExitCode -eq 0 -and (Get-SummaryField $line needsAttention) -eq 'false');Detail=$line}
    $snapshot3 = Save-Snapshot -Label '3-restart-reconciled' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Extra @('cli_reconcile=' + $line)
    return New-Task31Result -CellId $CellId -Run $Run -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort `
        -Checks $checks -Snapshots @($snapshot0.Path,$snapshot1.Path,$snapshot2.Path,$snapshot3.Path) -HttpCode $second.Code -Digest $Payload.Digest
}

function Invoke-Cell4_3_Run {
    param([string] $CellId, [int] $Run, [string] $DatabaseName, [string] $DataRoot, [int] $ServerPort,
        [string] $RunDirectory, $Payload)
    $seed = New-SeededResource -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -RunDirectory $RunDirectory -Payload $Payload
    $checks = @()
    $snapshot0 = Save-Snapshot -Label '0-seed-ready' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort
    $fixture = New-CommitGateTrigger -DatabaseName $DatabaseName -RunDirectory $RunDirectory -Table resource -Event UPDATE `
        -WhenClause "NEW.status = 'DELETED'" -SleepSeconds 45
    $delete = Start-Task31HttpRequest -Method DELETE -Uri ($seed.Uri + '/' + $seed.Resource.id) -RunDirectory $RunDirectory -Name 'soft-delete'
    if (-not (Wait-ForBlockedBackend -DatabaseName $DatabaseName -WaitSeconds $BlockWaitSeconds -WaitEventPattern PgSleep)) {
        if ($seed.Serve.Process.HasExited) { throw "点4-3 serve在提交门前退出；日志：$($seed.Serve.Stdout)" }
        Throw-Task31Miss '点 4-3 未命中资源状态 UPDATE 的提交门'
    }
    $block = Save-BlockEvidence -Label '4-3-before-kill' -DatabaseName $DatabaseName -RunDirectory $RunDirectory
    $state1 = @(Get-DatabaseState -DatabaseName $DatabaseName)
    $checks += [pscustomobject]@{Name='资源 UPDATE 提交门确已命中';Pass=((Get-LogText $block.Path) -match 'PgSleep' -and
        (Get-LogText $fixture) -match '(?i)CREATE CONSTRAINT TRIGGER.*AFTER UPDATE ON cangshu_m1\.resource' -and
        (Get-LogText $block.Path) -match '(?i)(COMMIT|update.*resource)');Detail=($fixture + ';' + $block.Path)}
    $checks += [pscustomobject]@{Name='杀前资源仍就绪';Pass=(($state1 -join ';') -match 'resource\|READY' -and ($state1 -join ';') -match 'counts\|content=1,location=1,resource=1');Detail=($state1 -join ';')}
    $snapshot1 = Save-Snapshot -Label '1-before-kill' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Extra @('fixture=' + $fixture)
    Stop-CangshuHard -Process $seed.Serve.Process | Out-Null
    if(-not $delete.Process.HasExited){Stop-Process -Id $delete.Process.Id -Force -ErrorAction Stop}
    $snapshot2 = Save-Snapshot -Label '2-after-kill-no-restart' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort
    $state2 = @(Get-DatabaseState -DatabaseName $DatabaseName)
    $blob = Join-Path $DataRoot ('sha256/' + $Payload.Digest.Substring(0,2) + '/' + $Payload.Digest.Substring(2,2) + '/' + $Payload.Digest)
    $checks += [pscustomobject]@{Name='软删回滚，资源仍就绪且字节在';Pass=(($state2 -join ';') -match 'resource\|READY' -and (Test-Path -LiteralPath $blob) -and (Get-FileHash -LiteralPath $blob -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Payload.Digest);Detail=($state2 -join ';')}
    Remove-FixtureObjects -DatabaseName $DatabaseName -RunDirectory $RunDirectory | Out-Null
    $checks += [pscustomobject]@{Name='重启前夹具已拆除';Pass=(@(Get-FixtureInventory -DatabaseName $DatabaseName | Where-Object {$_ -like '*task31_fixture_gate*'}).Count -eq 0);Detail=$fixture}
    $serve2 = Start-ServeAndWait -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -LogName 'serve-restart' -RunDirectory $RunDirectory
    $status = Get-HttpStatus -Method GET -Uri ($seed.Uri + '/' + $seed.Resource.id) -OutFile (Join-Path $RunDirectory 'restart-detail.json')
    $checks += [pscustomobject]@{Name='重启后原资源详情可读';Pass=($status.Status -eq '200');Detail='http=' + $status.Status}
    Stop-ServeGracefully -Run $serve2 | Out-Null
    $reconcile = Invoke-CliMode -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Mode reconcile -RunDirectory $RunDirectory
    $line = Get-CliSummaryLine -Stdout $reconcile.Stdout -Prefix 'reconcile|'
    $checks += [pscustomobject]@{Name='对账干净';Pass=($reconcile.ExitCode -eq 0 -and (Get-SummaryField $line needsAttention) -eq 'false');Detail=$line}
    $snapshot3 = Save-Snapshot -Label '3-restart-reconciled' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Extra @('cli_reconcile=' + $line,'detail_http=' + $status.Status)
    return New-Task31Result -CellId $CellId -Run $Run -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort `
        -Checks $checks -Snapshots @($snapshot0.Path,$snapshot1.Path,$snapshot2.Path,$snapshot3.Path) -BlockEvidence $block.Path -Digest $Payload.Digest
}

function Invoke-Cell5_3_Run {
    param([string] $CellId, [int] $Run, [string] $DatabaseName, [string] $DataRoot, [int] $ServerPort,
        [string] $RunDirectory, $Payload)
    $seed = New-SeededResource -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -RunDirectory $RunDirectory -Payload $Payload
    $checks = @()
    $snapshot0 = Save-Snapshot -Label '0-seed-ready' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort
    $delete = Get-HttpStatus -Method DELETE -Uri ($seed.Uri + '/' + $seed.Resource.id) -OutFile (Join-Path $RunDirectory 'soft-delete-response.txt')
    $checks += [pscustomobject]@{Name='软删 HTTP 204';Pass=($delete.Status -eq '204' -and $delete.ExitCode -eq 0);Detail="status=$($delete.Status),exit=$($delete.ExitCode)"}
    $snapshot1 = Save-Snapshot -Label '1-before-kill' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Extra @('delete_http=' + $delete.Status)
    Stop-CangshuHard -Process $seed.Serve.Process | Out-Null
    $snapshot2 = Save-Snapshot -Label '2-after-kill-no-restart' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort
    $state2 = @(Get-DatabaseState -DatabaseName $DatabaseName)
    $blob = Join-Path $DataRoot ('sha256/' + $Payload.Digest.Substring(0,2) + '/' + $Payload.Digest.Substring(2,2) + '/' + $Payload.Digest)
    $checks += [pscustomobject]@{Name='软删提交后资源 DELETED 且内容位置仍在';Pass=(($state2 -join ';') -match 'resource\|DELETED' -and ($state2 -join ';') -match 'content\|READY' -and ($state2 -join ';') -match 'counts\|content=1,location=1,resource=1');Detail=($state2 -join ';')}
    $checks += [pscustomobject]@{Name='软删不删字节';Pass=((Test-Path -LiteralPath $blob) -and (Get-FileHash -LiteralPath $blob -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Payload.Digest);Detail=$blob}
    $serve2 = Start-ServeAndWait -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -LogName 'serve-restart' -RunDirectory $RunDirectory
    $detail = Get-HttpStatus -Method GET -Uri ($seed.Uri + '/' + $seed.Resource.id) -OutFile (Join-Path $RunDirectory 'restart-detail.json')
    $trash = Get-HttpStatus -Method GET -Uri ($seed.Uri + '/trash') -OutFile (Join-Path $RunDirectory 'restart-trash.json')
    $trashBody = Get-Content -LiteralPath (Join-Path $RunDirectory 'restart-trash.json') -Raw -Encoding UTF8
    $checks += [pscustomobject]@{Name='重启后活跃详情不可见而回收站可见';Pass=($detail.Status -eq '404' -and $trash.Status -eq '200' -and $trashBody.Contains([string]$seed.Resource.id));Detail="detail=$($detail.Status),trash=$($trash.Status)"}
    Stop-ServeGracefully -Run $serve2 | Out-Null
    $reconcile = Invoke-CliMode -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Mode reconcile -RunDirectory $RunDirectory
    $line = Get-CliSummaryLine -Stdout $reconcile.Stdout -Prefix 'reconcile|'
    $checks += [pscustomobject]@{Name='对账干净';Pass=($reconcile.ExitCode -eq 0 -and (Get-SummaryField $line needsAttention) -eq 'false');Detail=$line}
    $snapshot3 = Save-Snapshot -Label '3-restart-reconciled' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Extra @('cli_reconcile=' + $line)
    return New-Task31Result -CellId $CellId -Run $Run -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort `
        -Checks $checks -Snapshots @($snapshot0.Path,$snapshot1.Path,$snapshot2.Path,$snapshot3.Path) -HttpCode $delete.Status -Digest $Payload.Digest
}

function Invoke-CellGc_Run {
    param([string] $CellId, [int] $Run, [string] $DatabaseName, [string] $DataRoot, [int] $ServerPort,
        [string] $RunDirectory, $Payload)
    $point = [int]$CellId.Split('-')[0]
    $gcSeed = New-GcPendingSeed -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -RunDirectory $RunDirectory -Payload $Payload
    $checks = @()
    $snapshot0 = Save-Snapshot -Label '0-reclaim-pending' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort
    $fixture = ''
    if ($point -eq 4) {
        # GC CLI 在夹具安装后才启动：普通 AFTER 触发器不进入 pg_constraint，仍卡在段一事务提交前。
        $fixture = New-DelayTrigger -DatabaseName $DatabaseName -RunDirectory $RunDirectory -Table content -Event UPDATE -Timing AFTER `
            -WhenClause "NEW.status = 'RECLAIMING'" -SleepSeconds 45
    } elseif ($point -eq 7) {
        # 段二 deleteBlob 已完成；AFTER UPDATE 仍在段三事务内，COMMIT 尚未发生。
        $fixture = New-DelayTrigger -DatabaseName $DatabaseName -RunDirectory $RunDirectory -Table content -Event UPDATE -Timing AFTER `
            -WhenClause "NEW.status = 'RECLAIMED'" -SleepSeconds 45
    }
    # GC CLI 必须在 serve 退出后启动（WriterGate 单写者）。
    $gc = Start-CangshuProcess -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort `
        -LogName 'gc-interrupted' -RunDirectory $RunDirectory -Mode gc
    $block = ''
    if ($point -in @(4,7)) {
        if (-not (Wait-ForBlockedBackend -DatabaseName $DatabaseName -WaitSeconds $BlockWaitSeconds -WaitEventPattern PgSleep)) {
            if ($gc.Process.HasExited) { throw "GC CLI 在点 $point 注入前退出；日志：$($gc.Stdout)" }
            Throw-Task31Miss "GC 点 $point 的提交门未命中"
        }
        $evidence = Save-BlockEvidence -Label ($CellId + '-before-kill') -DatabaseName $DatabaseName -RunDirectory $RunDirectory
        $block = $evidence.Path
        $checks += [pscustomobject]@{Name='GC 提交门有 pg_stat_activity/pg_locks 原文';Pass=((Get-LogText $block) -match 'PgSleep' -and (Get-LogText $block) -match '(?i)update.*content');Detail=$block}
    } elseif ($point -eq 5) {
        $deadline = (Get-Date).AddSeconds($BlockWaitSeconds)
        $hit = $false
        while ((Get-Date) -lt $deadline -and -not $gc.Process.HasExited) {
            $state = @(Get-DatabaseState -DatabaseName $DatabaseName)
            if (($state -join ';') -match 'content\|RECLAIMING' -and ($state -join ';') -match 'location\|-' -and
                (Test-Path -LiteralPath $gcSeed.Blob)) { $hit = $true; break }
            Start-Sleep -Milliseconds 50
        }
        if (-not $hit) { if ($gc.Process.HasExited) { throw "GC CLI 在点5窗口前退出；日志：$($gc.Stdout)" }; Throw-Task31Miss 'GC 点 5 未观测到段一已提交、位置行已删、字节尚在' }
    } elseif ($point -eq 6) {
        $jcmd = Join-Path $javaHome 'bin/jcmd.exe'
        if (-not (Test-Path -LiteralPath $jcmd)) { throw "点 6 缺 JDK jcmd：$jcmd" }
        $deadline = (Get-Date).AddSeconds($BlockWaitSeconds)
        $hit = $false
        $threadEvidence = Join-Path $RunDirectory 'gc-sha256-thread-print.txt'
        while ((Get-Date) -lt $deadline -and -not $gc.Process.HasExited) {
            $threadText = @(& $jcmd $gc.Process.Id Thread.print -l 2>&1)
            if ($LASTEXITCODE -eq 0) {
                $raw = $threadText -join [Environment]::NewLine
                if ($raw -match 'com\.cangshu\.storage\.FileStore\.sha256Hex' -and
                    $raw -match 'com\.cangshu\.job\.GcService\.deleteBytes') {
                    Set-Content -LiteralPath $threadEvidence -Value $raw -Encoding UTF8
                    $hit = $true
                    break
                }
            }
            Start-Sleep -Milliseconds 100
        }
        if (-not $hit) { if ($gc.Process.HasExited -and (Get-LogText $gc.Stdout) -match 'CANGSHU\|alert') { throw "GC CLI 告警退出；日志：$($gc.Stdout)" }; Throw-Task31Miss 'GC 点 6 未在自启 JVM 线程栈观测到 GcService.deleteBytes → FileStore.sha256Hex' }
        $state = @(Get-DatabaseState -DatabaseName $DatabaseName)
        $checks += [pscustomobject]@{Name='自启 JVM 线程栈证明段二 sha256Hex 中';Pass=((Get-LogText $threadEvidence) -match 'FileStore\.sha256Hex' -and (Get-LogText $threadEvidence) -match 'GcService\.deleteBytes' -and ($state -join ';') -match 'content\|RECLAIMING' -and (Test-Path -LiteralPath $gcSeed.Blob));Detail=$threadEvidence}
    }
    $state1 = @(Get-DatabaseState -DatabaseName $DatabaseName)
    $blob1 = Test-Path -LiteralPath $gcSeed.Blob
    if ($point -eq 4) {
        $checks += [pscustomobject]@{Name='段一 COMMIT 前待回收且位置、字节在';Pass=(($state1 -join ';') -match 'content\|RECLAIM_PENDING' -and ($state1 -join ';') -match 'counts\|content=1,location=1,resource=0' -and $blob1);Detail=($state1 -join ';')}
    } else {
        $checks += [pscustomobject]@{Name='段一已提交、回收中且位置行已删';Pass=(($state1 -join ';') -match 'content\|RECLAIMING' -and ($state1 -join ';') -match 'counts\|content=1,location=0,resource=0');Detail=($state1 -join ';')}
        $checks += [pscustomobject]@{Name='目标阶段字节存在性';Pass=($blob1 -eq ($point -ne 7));Detail="point=$point,blob=$blob1"}
    }
    $snapshot1 = Save-Snapshot -Label '1-before-kill' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Extra @('gc_pid=' + $gc.Process.Id,'fixture=' + $fixture,'blob_exists=' + $blob1)
    Stop-CangshuHard -Process $gc.Process | Out-Null
    $snapshot2 = Save-Snapshot -Label '2-after-kill-no-restart' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort
    $state2 = @(Get-DatabaseState -DatabaseName $DatabaseName)
    $blob2 = Test-Path -LiteralPath $gcSeed.Blob
    $expectedStatus = if($point -eq 4){'RECLAIM_PENDING'}else{'RECLAIMING'}
    $expectedLocations = if($point -eq 4){1}else{0}
    $checks += [pscustomobject]@{Name='杀后事务边界状态正确';Pass=(($state2 -join ';') -match ('content\|' + $expectedStatus) -and ($state2 -join ';') -match ('counts\|content=1,location=' + $expectedLocations + ',resource=0') -and $blob2 -eq ($point -ne 7));Detail=(($state2 -join ';') + ";blob=$blob2")}
    if ($fixture) {
        Remove-FixtureObjects -DatabaseName $DatabaseName -RunDirectory $RunDirectory | Out-Null
        $checks += [pscustomobject]@{Name='重启前夹具已拆除';Pass=(@(Get-FixtureInventory -DatabaseName $DatabaseName | Where-Object {$_ -like '*task31_fixture_gate*'}).Count -eq 0);Detail=$fixture}
    }
    # serve 启动会先对账再立即跑 GC；用只运行对账的 CLI 观察残留，避免 GC 抢先删掉点5/6字节。
    $initialReconcile = Invoke-CliMode -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Mode reconcile -RunDirectory $RunDirectory
    $startupLog = $initialReconcile.Stdout
    $startupLine = Get-CliSummaryLine -Stdout $startupLog -Prefix 'reconcile|'
    if ($point -eq 4) {
        $checks += [pscustomobject]@{Name='段一回滚后对账干净';Pass=($initialReconcile.ExitCode -eq 0 -and $startupLine -match 'needsAttention=false');Detail=$startupLine}
    } else {
        $checks += [pscustomobject]@{Name='独立重启对账显式报告 RECLAIMING 残留';Pass=($initialReconcile.ExitCode -ne 0 -and $startupLine -match 'needsAttention=true' -and $startupLog -match 'RECLAIMING');Detail=$startupLine}
        $checks += [pscustomobject]@{Name='对账保持目标字节状态';Pass=((Test-Path -LiteralPath $gcSeed.Blob) -eq ($point -ne 7));Detail=$gcSeed.Blob}
    }
    $resume = Invoke-CliMode -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Mode gc -RunDirectory $RunDirectory
    $gcLine = Get-CliSummaryLine -Stdout $resume.Stdout -Prefix 'gc|'
    $checks += [pscustomobject]@{Name='下一轮 GC 续接且无待处理';Pass=($resume.ExitCode -eq 0 -and (Get-SummaryField $gcLine needsAttention) -eq 'false');Detail=$gcLine}
    $reconcile = Invoke-CliMode -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Mode reconcile -RunDirectory $RunDirectory
    $recLine = Get-CliSummaryLine -Stdout $reconcile.Stdout -Prefix 'reconcile|'
    $checks += [pscustomobject]@{Name='GC 后对账干净';Pass=($reconcile.ExitCode -eq 0 -and (Get-SummaryField $recLine needsAttention) -eq 'false');Detail=$recLine}
    $serve2 = Start-ServeAndWait -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -LogName 'serve-final' -RunDirectory $RunDirectory
    $checks += [pscustomobject]@{Name='最终 serve 启动且健康';Pass=($serve2.Process.HasExited -eq $false);Detail=$serve2.Stdout}
    Stop-ServeGracefully -Run $serve2 | Out-Null
    $snapshot3 = Save-Snapshot -Label '3-restart-reconciled' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Extra @('initial_reconcile=' + $startupLine,'gc_resume=' + $gcLine,'final_reconcile=' + $recLine)
    $state3 = @(Get-DatabaseState -DatabaseName $DatabaseName)
    $checks += [pscustomobject]@{Name='最终置 RECLAIMED 且字节已删';Pass=(($state3 -join ';') -match 'content\|RECLAIMED' -and ($state3 -join ';') -match 'counts\|content=1,location=0,resource=0' -and -not (Test-Path -LiteralPath $gcSeed.Blob));Detail=($state3 -join ';')}
    return New-Task31Result -CellId $CellId -Run $Run -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort `
        -Checks $checks -Snapshots @($snapshot0.Path,$snapshot1.Path,$snapshot2.Path,$snapshot3.Path) -BlockEvidence $block -Digest $Payload.Digest
}

function Invoke-CellStage_Run {
    param([string] $CellId, [int] $Run, [string] $DatabaseName, [string] $DataRoot, [int] $ServerPort,
        [string] $RunDirectory, $Payload)
    $reuse = $CellId -eq '1-2'
    $checks = @()
    if ($reuse) {
        $seed = New-SeededResource -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -RunDirectory $RunDirectory -Payload $Payload
        $serve = $seed.Serve
        $uri = $seed.Uri
    } else {
        Reset-IsolatedDatabase -DatabaseName $DatabaseName
        Assert-RunDataRoot -DataRoot $DataRoot -RunDirectory $RunDirectory
        if (Test-Path -LiteralPath $DataRoot) { throw "拒绝覆盖已有数据根：$DataRoot" }
        New-Item -ItemType Directory -Path $DataRoot | Out-Null
        $serve = Start-ServeAndWait -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -LogName 'serve-1' -RunDirectory $RunDirectory
        $uri = 'http://127.0.0.1:' + $ServerPort + '/api/resources'
    }
    $snapshot0 = Save-Snapshot -Label '0-before-stage' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort
    $blob = Join-Path $DataRoot ('sha256/' + $Payload.Digest.Substring(0,2) + '/' + $Payload.Digest.Substring(2,2) + '/' + $Payload.Digest)
    $baselineBlobHash = if($reuse){(Get-FileHash -LiteralPath $blob -Algorithm SHA256).Hash.ToLowerInvariant()}else{''}
    $upload = Start-ThrottledUpload -Uri $uri -UploadPath $Payload.Path -RunDirectory $RunDirectory -Name 'interrupted-stage'
    $jcmd = Join-Path $javaHome 'bin/jcmd.exe'
    if(-not (Test-Path -LiteralPath $jcmd)){throw "点 1 缺 JDK jcmd：$jcmd"}
    $deadline = (Get-Date).AddSeconds($BlockWaitSeconds)
    $tmpFile = $null
    $stackPath = Join-Path $RunDirectory 'stage-thread-print.txt'
    $hit = $false
    while((Get-Date) -lt $deadline -and -not $serve.Process.HasExited -and -not $upload.Process.HasExited){
        $candidate = @(Get-ChildItem -LiteralPath (Join-Path $DataRoot 'tmp') -File -Filter 'upload-*.tmp' -ErrorAction SilentlyContinue |
            Where-Object {$_.Length -gt 0 -and $_.Length -lt $Payload.SizeBytes} | Select-Object -First 1)
        if($candidate.Count -eq 0){Start-Sleep -Milliseconds 10;continue}
        $threadText = @(& $jcmd $serve.Process.Id Thread.print -l 2>&1)
        $raw = $threadText -join [Environment]::NewLine
        if($LASTEXITCODE -eq 0 -and $raw -match 'com\.cangshu\.storage\.FileStore\.stage' -and
            $raw -match 'com\.cangshu\.ingest\.UploadIngestService\.stage'){
            $current = Get-Item -LiteralPath $candidate[0].FullName -ErrorAction SilentlyContinue
            if($current -and $current.Length -gt 0 -and $current.Length -lt $Payload.SizeBytes){
                $tmpFile = $current.FullName
                Set-Content -LiteralPath $stackPath -Value $raw -Encoding UTF8
                $hit = $true
                break
            }
        }
    }
    if(-not $hit){if($serve.Process.HasExited){throw "点1 serve提前退出；日志：$($serve.Stdout)"};Throw-Task31Miss '点 1 未同时观测到业务 data-root/tmp 未完成文件及自启 JVM FileStore.stage 线程栈'}
    $tempSize1 = (Get-Item -LiteralPath $tmpFile).Length
    $state1 = @(Get-DatabaseState -DatabaseName $DatabaseName)
    $checks += [pscustomobject]@{Name='杀前业务 tmp 正写入且栈在 FileStore.stage';Pass=($tempSize1 -gt 0 -and $tempSize1 -lt $Payload.SizeBytes -and (Get-LogText $stackPath) -match 'FileStore\.stage');Detail="$tmpFile|size=$tempSize1|stack=$stackPath"}
    $expectedCount = if($reuse){'content=1,location=1,resource=1'}else{'content=0,location=0,resource=0'}
    $checks += [pscustomobject]@{Name='杀前未新增元数据且既有行完整';Pass=(($state1 -join ';') -match ('counts\|' + $expectedCount));Detail=($state1 -join ';')}
    $checks += [pscustomobject]@{Name='最终键存在性符合新建/复用';Pass=((Test-Path -LiteralPath $blob) -eq $reuse);Detail=$blob}
    $snapshot1 = Save-Snapshot -Label '1-before-kill' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Extra @('stage_stack=' + $stackPath,'business_tmp=' + $tmpFile,'tmp_size=' + $tempSize1)
    Stop-CangshuHard -Process $serve.Process | Out-Null
    if(-not $upload.Process.HasExited){Stop-Process -Id $upload.Process.Id -Force -ErrorAction Stop}
    $snapshot2 = Save-Snapshot -Label '2-after-kill-no-restart' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort
    $state2 = @(Get-DatabaseState -DatabaseName $DatabaseName)
    $tempSize2 = if(Test-Path -LiteralPath $tmpFile){(Get-Item -LiteralPath $tmpFile).Length}else{-1}
    $checks += [pscustomobject]@{Name='杀后业务 tmp 留有未完成字节';Pass=($tempSize2 -gt 0 -and $tempSize2 -lt $Payload.SizeBytes);Detail="$tmpFile|size=$tempSize2"}
    $checks += [pscustomobject]@{Name='杀后无新增元数据';Pass=(($state2 -join ';') -match ('counts\|' + $expectedCount));Detail=($state2 -join ';')}
    if($reuse){
        $checks += [pscustomobject]@{Name='原引用及字节完好';Pass=((Test-Path -LiteralPath $blob) -and (Get-FileHash -LiteralPath $blob -Algorithm SHA256).Hash.ToLowerInvariant() -eq $baselineBlobHash);Detail=$blob}
    }else{
        $checks += [pscustomobject]@{Name='最终键未建立';Pass=(-not (Test-Path -LiteralPath $blob));Detail=$blob}
    }
    # 快照2先保留杀后原状；只给本格确权的业务 tmp 加龄，触发生产24h清理分支。
    $tmpRoot = [System.IO.Path]::GetFullPath((Join-Path $DataRoot 'tmp'))
    $fullTmp = [System.IO.Path]::GetFullPath($tmpFile)
    if(-not $fullTmp.StartsWith($tmpRoot + [System.IO.Path]::DirectorySeparatorChar,[System.StringComparison]::OrdinalIgnoreCase) -or
        ((Get-Item -LiteralPath $fullTmp -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)){
        throw "拒绝对非本格普通业务 tmp 加龄：$fullTmp"
    }
    $oldTime = (Get-Item -LiteralPath $fullTmp).LastWriteTimeUtc
    (Get-Item -LiteralPath $fullTmp).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-25)
    $agedTime = (Get-Item -LiteralPath $fullTmp).LastWriteTimeUtc
    $ageEvidence = Join-Path $RunDirectory 'tmp-aging-fixture.txt'
    Set-Content -LiteralPath $ageEvidence -Encoding UTF8 -Value @(
        '仅本格业务 tmp 时间加龄夹具；原始杀后快照2未改写',
        'path=' + $fullTmp, 'size=' + $tempSize2,
        'beforeLastWriteUtc=' + $oldTime.ToString('o'),
        'afterLastWriteUtc=' + $agedTime.ToString('o'))
    $checks += [pscustomobject]@{Name='业务 tmp 已加龄超过24h';Pass=($agedTime -lt (Get-Date).ToUniversalTime().AddHours(-24));Detail=$ageEvidence}
    $serve2 = Start-ServeAndWait -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -LogName 'serve-restart' -RunDirectory $RunDirectory
    $startupLine = Get-LogMarkerLine -Text (Get-LogText $serve2.Stdout) -Marker 'CANGSHU|job|reconcile|reconcile|'
    $deleted = Get-SummaryField -Line $startupLine -Key tempDeleted
    $checks += [pscustomobject]@{Name='重启一次对账删除加龄业务 tmp';Pass=(-not (Test-Path -LiteralPath $fullTmp) -and $deleted -match '^\d+$' -and [int]$deleted -ge 1);Detail=($startupLine + ';' + $ageEvidence)}
    if($reuse){
        $status = Get-HttpStatus -Method GET -Uri ($uri + '/' + $seed.Resource.id + '/content') -OutFile (Join-Path $RunDirectory 'restart-original.bin')
        $digest = if($status.Status -eq '200'){(Get-FileHash -LiteralPath (Join-Path $RunDirectory 'restart-original.bin') -Algorithm SHA256).Hash.ToLowerInvariant()}else{''}
        $checks += [pscustomobject]@{Name='重启后原资源可读';Pass=($status.Status -eq '200' -and $digest -eq $Payload.Digest);Detail="http=$($status.Status),digest=$digest"}
    }
    Stop-ServeGracefully -Run $serve2 | Out-Null
    $reconcile = Invoke-CliMode -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Mode reconcile -RunDirectory $RunDirectory
    $line = Get-CliSummaryLine -Stdout $reconcile.Stdout -Prefix 'reconcile|'
    $checks += [pscustomobject]@{Name='重启后对账无异常';Pass=($reconcile.ExitCode -eq 0 -and (Get-SummaryField $line needsAttention) -eq 'false');Detail=$line}
    $snapshot3 = Save-Snapshot -Label '3-restart-reconciled' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Extra @('startup_reconcile=' + $startupLine,'cli_reconcile=' + $line,'tmp_aging_evidence=' + $ageEvidence)
    $state3 = @(Get-DatabaseState -DatabaseName $DatabaseName)
    $checks += [pscustomobject]@{Name='最终无新增元数据';Pass=(($state3 -join ';') -match ('counts\|' + $expectedCount));Detail=($state3 -join ';')}
    return New-Task31Result -CellId $CellId -Run $Run -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort `
        -Checks $checks -Snapshots @($snapshot0.Path,$snapshot1.Path,$snapshot2.Path,$snapshot3.Path) -Digest $Payload.Digest
}

function Invoke-Cell2_1_Run {
    param([string] $CellId, [int] $Run, [string] $DatabaseName, [string] $DataRoot, [int] $ServerPort,
        [string] $RunDirectory, $Payload)
    $checks = @()
    Reset-IsolatedDatabase -DatabaseName $DatabaseName
    Assert-RunDataRoot -DataRoot $DataRoot -RunDirectory $RunDirectory
    if(Test-Path -LiteralPath $DataRoot){throw "拒绝覆盖已有数据根：$DataRoot"}
    New-Item -ItemType Directory -Path $DataRoot | Out-Null
    $serve = Start-ServeAndWait -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -LogName 'serve-1' -RunDirectory $RunDirectory
    $snapshot0 = Save-Snapshot -Label '0-before-upload' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort
    $blocker = Start-TableBlockSession -DatabaseName $DatabaseName -RunDirectory $RunDirectory -Table content
    if(-not (Wait-ForBlockedBackend -DatabaseName $DatabaseName -WaitSeconds $BlockWaitSeconds -WaitEventPattern PgSleep)){
        throw '点 2 表级阻塞会话未持锁；不计次'
    }
    $upload = Start-ThrottledUpload -Uri ('http://127.0.0.1:' + $ServerPort + '/api/resources') -UploadPath $Payload.Path `
        -RunDirectory $RunDirectory -Name 'before-move' -RateLimitSeconds $RateLimit
    if(-not (Wait-ForBlockedBackend -DatabaseName $DatabaseName -WaitSeconds $BlockWaitSeconds -WaitEventPattern relation)){
        if($serve.Process.HasExited){throw "点2 serve提前退出；日志：$($serve.Stdout)"}
        Throw-Task31Miss '点 2 应用 selectContentForUpdate 未等待 content 表锁'
    }
    $block = Save-BlockEvidence -Label '2-1-before-kill' -DatabaseName $DatabaseName -RunDirectory $RunDirectory
    $tree1 = @(Get-DataRootTree -DataRoot $DataRoot)
    $state1 = @(Get-DatabaseState -DatabaseName $DatabaseName)
    $tmpFiles = @(Get-ChildItem -LiteralPath (Join-Path $DataRoot 'tmp') -File -Filter 'upload-*.tmp' -ErrorAction SilentlyContinue | Where-Object {$_.Length -eq $Payload.SizeBytes})
    $blob = Join-Path $DataRoot ('sha256/' + $Payload.Digest.Substring(0,2) + '/' + $Payload.Digest.Substring(2,2) + '/' + $Payload.Digest)
    $checks += [pscustomobject]@{Name='应用后端在 content 行锁查询前受阻';Pass=((Get-LogText $block.Path) -match 'relation' -and (Get-LogText $block.Path) -match '\|f\|content' -and (Get-LogText $block.Path) -match '(?i)select.*content');Detail=$block.Path}
    $checks += [pscustomobject]@{Name='移动前完整业务 tmp 在、最终键未建';Pass=($tmpFiles.Count -eq 1 -and -not (Test-Path -LiteralPath $blob));Detail=($tree1 -join ';')}
    $checks += [pscustomobject]@{Name='杀前元数据未落库';Pass=(($state1 -join ';') -match 'counts\|content=0,location=0,resource=0');Detail=($state1 -join ';')}
    $snapshot1 = Save-Snapshot -Label '1-before-kill' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Extra @('blocker_pid=' + $blocker.Process.Id,'tmp=' + $tmpFiles[0].FullName)
    Stop-CangshuHard -Process $serve.Process | Out-Null
    if(-not $upload.Process.HasExited){Stop-Process -Id $upload.Process.Id -Force -ErrorAction Stop}
    if(-not $blocker.Process.HasExited){Stop-Process -Id $blocker.Process.Id -Force -ErrorAction Stop; $blocker.Process.WaitForExit(30000) | Out-Null}
    $snapshot2 = Save-Snapshot -Label '2-after-kill-no-restart' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort
    $state2 = @(Get-DatabaseState -DatabaseName $DatabaseName)
    $checks += [pscustomobject]@{Name='杀后无元数据且未移动';Pass=(($state2 -join ';') -match 'counts\|content=0,location=0,resource=0' -and -not (Test-Path -LiteralPath $blob) -and (Test-Path -LiteralPath $tmpFiles[0].FullName));Detail=($state2 -join ';')}
    $tmpRoot = [System.IO.Path]::GetFullPath((Join-Path $DataRoot 'tmp'))
    $fullTmp = [System.IO.Path]::GetFullPath($tmpFiles[0].FullName)
    if(-not $fullTmp.StartsWith($tmpRoot + [System.IO.Path]::DirectorySeparatorChar,[System.StringComparison]::OrdinalIgnoreCase) -or
        ((Get-Item -LiteralPath $fullTmp -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)){
        throw "拒绝对非本格普通业务 tmp 加龄：$fullTmp"
    }
    $oldTime = (Get-Item -LiteralPath $fullTmp).LastWriteTimeUtc
    (Get-Item -LiteralPath $fullTmp).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-25)
    $agedTime = (Get-Item -LiteralPath $fullTmp).LastWriteTimeUtc
    $ageEvidence = Join-Path $RunDirectory 'tmp-aging-fixture.txt'
    Set-Content -LiteralPath $ageEvidence -Encoding UTF8 -Value @(
        '仅本格业务 tmp 时间加龄夹具；原始杀后快照2未改写',
        'path=' + $fullTmp, 'size=' + (Get-Item -LiteralPath $fullTmp).Length,
        'beforeLastWriteUtc=' + $oldTime.ToString('o'),
        'afterLastWriteUtc=' + $agedTime.ToString('o'))
    $checks += [pscustomobject]@{Name='移动前业务 tmp 已加龄超过24h';Pass=($agedTime -lt (Get-Date).ToUniversalTime().AddHours(-24));Detail=$ageEvidence}
    $serve2 = Start-ServeAndWait -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -LogName 'serve-restart' -RunDirectory $RunDirectory
    $startupLine = Get-LogMarkerLine -Text (Get-LogText $serve2.Stdout) -Marker 'CANGSHU|job|reconcile|reconcile|'
    $deleted = Get-SummaryField -Line $startupLine -Key tempDeleted
    $checks += [pscustomobject]@{Name='重启一次对账删除加龄业务 tmp';Pass=(-not (Test-Path -LiteralPath $fullTmp) -and $deleted -match '^\d+$' -and [int]$deleted -ge 1);Detail=($startupLine + ';' + $ageEvidence)}
    Stop-ServeGracefully -Run $serve2 | Out-Null
    $reconcile = Invoke-CliMode -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Mode reconcile -RunDirectory $RunDirectory
    $line = Get-CliSummaryLine -Stdout $reconcile.Stdout -Prefix 'reconcile|'
    $checks += [pscustomobject]@{Name='重启对账无异常';Pass=($reconcile.ExitCode -eq 0 -and (Get-SummaryField $line needsAttention) -eq 'false');Detail=$line}
    $snapshot3 = Save-Snapshot -Label '3-restart-reconciled' -RunDirectory $RunDirectory -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -Extra @('startup_reconcile=' + $startupLine,'cli_reconcile=' + $line,'tmp_aging_evidence=' + $ageEvidence)
    $state3 = @(Get-DatabaseState -DatabaseName $DatabaseName)
    $checks += [pscustomobject]@{Name='最终仍无新增元数据和最终键';Pass=(($state3 -join ';') -match 'counts\|content=0,location=0,resource=0' -and -not (Test-Path -LiteralPath $blob));Detail=($state3 -join ';')}
    return New-Task31Result -CellId $CellId -Run $Run -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort `
        -Checks $checks -Snapshots @($snapshot0.Path,$snapshot1.Path,$snapshot2.Path,$snapshot3.Path) -BlockEvidence $block.Path -Digest $Payload.Digest
}

$cellRunners = @{
    '5-1' = 'Invoke-Cell1_5_Run'
    '4-1' = 'Invoke-Cell4_1_Run'
    '3-1' = 'Invoke-Cell3_1_Run'
    '4-2' = 'Invoke-Cell4_2_Run'
    '5-2' = 'Invoke-Cell5_2_Run'
    '4-3' = 'Invoke-Cell4_3_Run'
    '5-3' = 'Invoke-Cell5_3_Run'
    '4-4' = 'Invoke-CellGc_Run'
    '5-4' = 'Invoke-CellGc_Run'
    '6-4' = 'Invoke-CellGc_Run'
    '7-4' = 'Invoke-CellGc_Run'
    '1-1' = 'Invoke-CellStage_Run'
    '1-2' = 'Invoke-CellStage_Run'
    '2-1' = 'Invoke-Cell2_1_Run'
}

# ════════════════════════════════════════════════════════════════════════════════════════════
#  主流程
# ════════════════════════════════════════════════════════════════════════════════════════════
$requestedCells = Resolve-RequestedCells -Requested $Cells
$payload = New-PayloadFile -Path (Join-Path $outputRoot ('payloads/upload-' + $PayloadBytes + 'b.bin')) -SizeBytes $PayloadBytes
$stagePayload = if (@($requestedCells | Where-Object { $_ -in @('1-1','1-2') }).Count -gt 0) {
    New-PayloadFile -Path (Join-Path $outputRoot ('payloads/stage-' + $StagePayloadBytes + 'b.bin')) -SizeBytes $StagePayloadBytes
} else { $null }
$gcPayload = if (@($requestedCells | Where-Object { $_ -like '*-4' -and $_ -notin @('1-4','2-4','3-4') }).Count -gt 0) {
    New-PayloadFile -Path (Join-Path $outputRoot ('payloads/gc-' + $GcPayloadBytes + 'b.bin')) -SizeBytes $GcPayloadBytes
} else { $null }

$databaseInventoryBefore = Get-DatabaseInventory
Set-Content -LiteralPath (Join-Path $outputRoot 'db-inventory-before.txt') -Value $databaseInventoryBefore -Encoding UTF8

Write-Host ('[task31-matrix] HEAD=' + $headCommit + ' 工作树脏=' + ($worktreeDirty.Count -gt 0) + '（脏文件 ' + $worktreeDirty.Count + ' 项）')
Write-Host ('[task31-matrix] 要求格子：' + ($requestedCells -join '、') + '；每格 ' + $Runs + ' 次；载荷 ' + $payload.SizeBytes + ' 字节，sha256=' + $payload.Digest)

$results = @()
$missedAttempts = @()
$unimplemented = @()
$notApplicable = @()
$cellIndex = 0
foreach ($cellId in $requestedCells) {
    $definition = Get-CellDefinition -CellId $cellId
    if ($definition.Reach -eq '不适用') {
        $notApplicable += [pscustomobject]@{ CellId = $cellId; Point = $definition.P; Class = $definition.C; Reason = $definition.Reason }
        Write-Host ('[task31-matrix] ' + $cellId + ' → 不适用：' + $definition.Reason)
        continue
    }
    if ($cellId -in @('6-1','7-1')) {
        Write-Host ('[task31-matrix] ' + $cellId + ' → 引用④类同点三次GC证据（由汇总门核对）')
        continue
    }
    if (-not $cellRunners.ContainsKey($cellId)) {
        $unimplemented += [pscustomobject]@{ CellId = $cellId; Reach = $definition.Reach; Injection = $definition.Inj }
        Write-Host ('[task31-matrix] ' + $cellId + ' → 已定义但本阶段未实现执行器（未实现 ≠ 通过）')
        continue
    }
    $runner = Get-Command -Name $cellRunners[$cellId]
    for ($run = 1; $run -le $Runs; $run++) {
      for ($attempt = 1; $attempt -le $MaxAttemptsPerRun; $attempt++) {
        $databaseName = Get-CellDatabaseName -CellId $cellId -Run $run -Attempt $attempt
        $runDirectory = Get-RunDirectory -CellId $cellId -Run $run -Attempt $attempt
        $dataRoot = Join-Path $runDirectory 'data-root'
        $serverPort = Get-CellPort -CellIndex $cellIndex -Run $run -Attempt $attempt
        Write-Host ('[task31-matrix] 执行 ' + $cellId + ' r' + $run + ' attempt=' + $attempt + ' 库=' + $databaseName + ' 端口=' + $serverPort)
        $result = $null
        $miss = $false
        $missReason = ''
        $cleanupFailures = [System.Collections.Generic.List[string]]::new()
        $runPayload = if ($definition.C -eq '④') { $gcPayload } elseif ($cellId -in @('1-1','1-2')) { $stagePayload } else { $payload }
        $ownedProcessStart = $ownedProcesses.Count
        try {
            $result = & $runner -CellId $cellId -Run $run -DatabaseName $databaseName -DataRoot $dataRoot `
                -ServerPort $serverPort -RunDirectory $runDirectory -Payload $runPayload
        } catch {
            if ($_.Exception.Data['Task31Miss'] -eq $true) {
                $miss = $true
                $missReason = $_.Exception.Message
                Write-Host ('[task31-matrix] ' + $cellId + ' r' + $run + ' a' + $attempt + ' 未命中：' + $missReason)
            } else {
                $result = [pscustomobject]@{
                    CellId = $cellId; Point = $definition.P; Class = $definition.C; Run = $run
                    Database = $databaseName; DataRoot = $dataRoot; ServerPort = $serverPort
                    Verdict = '执行异常'; Checks = @(); SnapshotFiles = @(); BlockEvidence = ''
                    HttpCode = ''; Digest = $runPayload.Digest; FailedChecks = @($_.Exception.Message)
                }
                Write-Host ('[task31-matrix] ' + $cellId + ' r' + $run + ' 环境/执行异常：' + $_.Exception.Message)
            }
        } finally {
            # 仅收束本格通过 Start-Process 返回的确权句柄，不按进程名扫杀。
            for ($processIndex = $ownedProcessStart; $processIndex -lt $ownedProcesses.Count; $processIndex++) {
                $ownedProcess = $ownedProcesses[$processIndex]
                try {
                    if (-not $ownedProcess.HasExited) {
                        Stop-Process -Id $ownedProcess.Id -Force -ErrorAction Stop
                        if (-not $ownedProcess.WaitForExit(30000)) { throw "进程 $($ownedProcess.Id) 未在30秒内退出" }
                    }
                } catch {
                    $cleanupFailures.Add('确权进程收束失败：' + $_.Exception.Message)
                }
            }
            if (-not $KeepDatabase) {
                try {
                    if ($ownedDatabases.Contains($databaseName)) { Remove-IsolatedDatabase -DatabaseName $databaseName }
                }
                catch {
                    $cleanupFailures.Add('隔离库清理失败：' + $_.Exception.Message)
                }
            }
        }
        if ($cleanupFailures.Count -gt 0) {
            $miss = $false
            if ($null -eq $result) {
                $result = [pscustomobject]@{
                    CellId = $cellId; Point = $definition.P; Class = $definition.C; Run = $run
                    Database = $databaseName; DataRoot = $dataRoot; ServerPort = $serverPort
                    Verdict = '执行异常'; Checks = @(); SnapshotFiles = @(); BlockEvidence = ''
                    HttpCode = ''; Digest = $runPayload.Digest; FailedChecks = @()
                }
            }
            $result.Verdict = '执行异常'
            $result.FailedChecks = @($result.FailedChecks) + @($cleanupFailures.ToArray())
        }
        $attemptAction = Get-Task31AttemptAction -Miss $miss -Result $result -Attempt $attempt -Maximum $MaxAttemptsPerRun
        if ($attemptAction -ne 'record') {
            $missRecord = [pscustomobject]@{cellId=$cellId;run=$run;attempt=$attempt;database=$databaseName;
                dataRoot=$dataRoot;serverPort=$serverPort;reason=$missReason;runDirectory=$runDirectory;
                executedAt=(Get-Date).ToUniversalTime().ToString('o')}
            Set-Content -LiteralPath (Join-Path $runDirectory 'attempt-missed.json') -Encoding UTF8 -Value ($missRecord | ConvertTo-Json -Depth 4)
            $missedAttempts += $missRecord
            if ($attemptAction -eq 'retry') { continue }
            Write-Host ('[task31-matrix] ' + $cellId + ' r' + $run + ' 已用尽 ' + $MaxAttemptsPerRun + ' 次窗口尝试，保持 INCOMPLETE')
            break
        }
        $record = [pscustomobject]@{
            cellId = $result.CellId; point = $result.Point; class = $result.Class; run = $result.Run
            database = $result.Database; dataRoot = $result.DataRoot; serverPort = $result.ServerPort
            head = $headCommit; worktreeDirty = ($worktreeDirty.Count -gt 0); worktreeDirtyFiles = $worktreeDirty
            reachability = $definition.Reach; injection = $definition.Inj; triggerPosition = $definition.Pos
            expected = $definition.Exp
            verdict = $result.Verdict
            httpCode = $result.HttpCode; payloadDigest = $result.Digest
            blockEvidence = $result.BlockEvidence
            snapshots = $result.SnapshotFiles
            evidenceFilesPresent = (@($result.SnapshotFiles).Count -eq 4 -and
                @($result.SnapshotFiles | Where-Object { -not (Test-Task31EvidenceFile -Path $_) }).Count -eq 0)
            blockEvidencePresent = (-not [string]::IsNullOrWhiteSpace([string]$result.BlockEvidence) -and
                (Test-Task31EvidenceFile -Path $result.BlockEvidence))
            checks = @($result.Checks | ForEach-Object { [pscustomobject]@{ name = $_.Name; pass = $_.Pass; detail = $_.Detail } })
            failedChecks = $result.FailedChecks
            executedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        Set-Content -LiteralPath (Join-Path $runDirectory 'result.json') -Value ($record | ConvertTo-Json -Depth 8) -Encoding UTF8
        $results += $record
        Write-Host ('[task31-matrix] ' + $cellId + ' r' + $run + ' → ' + $record.verdict +
            '（失败判据 ' + @($record.failedChecks).Count + ' 项）')
        break
      }
    }
    $cellIndex++
}

$supplemental = if ($SupplementalEvidenceFile) {
    $supplementalPath = Resolve-From $SupplementalEvidenceFile
    Get-Content -LiteralPath $supplementalPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else { [pscustomobject]@{ gcReferences = @(); negativeControls = @() } }
$fullMatrix = $requestedCells.Count -eq 28 -and $Runs -eq 3
$executedNegativeControls = if ($fullMatrix) {
    @(Invoke-Task31NegativeControls -OutputRoot $outputRoot -DatabasePrefix $DatabasePrefix -BaseServerPort $BaseServerPort -Payload $payload)
} else { @() }
$rawNegativeControls = @($executedNegativeControls) + @($supplemental.negativeControls | Where-Object { $null -ne $_ })
$negativeControls = Get-Task31NegativeControls -Controls $rawNegativeControls -BaseDirectory $outputRoot
$gcReferences = if ($fullMatrix) {
    @(
        [pscustomobject]@{cellId='6-1';sourceCellId='6-4';runEvidence=@('6-4/r1','6-4/r2','6-4/r3')},
        [pscustomobject]@{cellId='7-1';sourceCellId='7-4';runEvidence=@('7-4/r1','7-4/r2','7-4/r3')}
    )
} else { @($supplemental.gcReferences | Where-Object { $null -ne $_ }) }

$databaseInventoryAfter = Get-DatabaseInventory
Set-Content -LiteralPath (Join-Path $outputRoot 'db-inventory-after.txt') -Value $databaseInventoryAfter -Encoding UTF8
$inventoryDifference = @(Compare-Object -ReferenceObject $databaseInventoryBefore -DifferenceObject $databaseInventoryAfter)
$jarShaAfter = if (Test-Path -LiteralPath $jarPath -PathType Leaf) {
    (Get-FileHash -LiteralPath $jarPath -Algorithm SHA256).Hash.ToLowerInvariant()
} else { '' }
$artifactStable = $jarShaAfter -ceq $buildProvenance.jarSha256
$summary = [pscustomobject]@{
    task = '31'; phase = 'matrix execution (08 §3.1)'
    executedAt = (Get-Date).ToUniversalTime().ToString('o')
    head = $headCommit; worktreeDirty = ($worktreeDirty.Count -gt 0); worktreeDirtyFiles = $worktreeDirty
    build = $buildProvenance
    artifactStable = [bool]$artifactStable
    jarSha256After = $jarShaAfter
    payload = [pscustomobject]@{ path = $payload.Path; sizeBytes = $payload.SizeBytes; sha256 = $payload.Digest }
    requestedCells = $requestedCells; runs = $Runs
    results = $results
    missedAttempts = $missedAttempts
    notApplicable = $notApplicable
    unimplementedCells = $unimplemented
    gcReferences = $gcReferences
    negativeControls = $negativeControls
    databaseInventoryUnchanged = ($inventoryDifference.Count -eq 0)
    leftoverDatabases = @(($databaseInventoryAfter | Where-Object { $_ -like ($DatabasePrefix + '_' + $invocationId + '_*') }))
}
$decision = Get-Task31Decision -Summary $summary
$summary | Add-Member -NotePropertyName decision -NotePropertyValue $decision
Set-Content -LiteralPath (Join-Path $outputRoot 'matrix-summary.json') -Value ($summary | ConvertTo-Json -Depth 12) -Encoding UTF8

# 单元格报告（三快照对比 ＋ 阻塞点证据 ＋ 判定）
foreach ($cellGroup in ($results | Group-Object -Property cellId)) {
    $cellDirectory = Get-CellDirectory -CellId $cellGroup.Name
    $definition = Get-CellDefinition -CellId $cellGroup.Name
    $lines = @()
    $lines += '# 任务 31 矩阵格 ' + $cellGroup.Name + '（点 ' + $definition.P + '／类 ' + $definition.C + '）'
    $lines += '触发位置：' + $definition.Pos
    $lines += '期望结果：' + $definition.Exp
    $lines += '可达性：' + $definition.Reach + '；注入方式：' + $definition.Inj
    $lines += 'HEAD=' + $headCommit + '；工作树脏=' + ($worktreeDirty.Count -gt 0) + '；执行时刻=' + (Get-Date).ToUniversalTime().ToString('o')
    $lines += ''
    $lines += '| 轨道｜类｜注入点｜序号 | 杀前快照 | 杀后不重启快照 | 重启后对账快照 | 判定 | 阻塞点证据 | 执行时刻 |'
    $lines += '|---|---|---|---|---|---|---|'
    foreach ($record in $cellGroup.Group) {
        $lines += '| ①｜' + $record.class + '｜点 ' + $record.point + '｜r' + $record.run + ' | ' +
            ($record.snapshots[1] ?? '-') + ' | ' + ($record.snapshots[2] ?? '-') + ' | ' + ($record.snapshots[3] ?? '-') +
            ' | ' + $record.verdict + ' | ' + (if ($record.blockEvidence) { $record.blockEvidence } else { '（可达格，无需注入）' }) +
            ' | ' + $record.executedAt + ' |'
    }
    foreach ($record in $cellGroup.Group) {
        $lines += ''
        $lines += '## r' + $record.run + ' 判据明细（判定＝' + $record.verdict + '）'
        foreach ($check in $record.checks) {
            $lines += ('- [' + (if ($check.pass) { 'PASS' } else { 'FAIL' }) + '] ' + $check.name + '：' + $check.detail)
        }
        if (@($record.failedChecks).Count -gt 0) {
            $lines += '- 失败项：' + (@($record.failedChecks) -join '；')
        }
        $snapshotFiles = @($record.snapshots)
        if ($snapshotFiles.Count -ge 4) {
            $lines += ''
            $lines += '### 三快照对比（只读 SQL＋文件树）'
            $before = Get-Content -LiteralPath $snapshotFiles[1] -Encoding UTF8 -ErrorAction SilentlyContinue
            $after = Get-Content -LiteralPath $snapshotFiles[2] -Encoding UTF8 -ErrorAction SilentlyContinue
            $restart = Get-Content -LiteralPath $snapshotFiles[3] -Encoding UTF8 -ErrorAction SilentlyContinue
            $lines += '- 快照1（杀前）：' + (($before | Where-Object { $_ -match '^(counts|content|location|resource)\|' }) -join ' ； ')
            $lines += '- 快照2（杀后不重启）：' + (($after | Where-Object { $_ -match '^(counts|content|location|resource)\|' }) -join ' ； ')
            $lines += '- 快照3（重启后对账）：' + (($restart | Where-Object { $_ -match '^(counts|content|location|resource)\|' }) -join ' ； ')
        }
    }
    Set-Content -LiteralPath (Join-Path $cellDirectory 'cell-report.txt') -Value $lines -Encoding UTF8
}

Write-Host ''
Write-Host ('[task31-matrix] 完成：执行 ' + $results.Count + ' 次运行；未实现格 ' + $unimplemented.Count + '；不适用格 ' + $notApplicable.Count)
Write-Host ('[task31-matrix] 库清单前后一致=' + ($inventoryDifference.Count -eq 0) + '；残留隔离库=' + @($summary.leftoverDatabases).Count + ' 个')
Write-Host ('[task31-matrix] 结果：' + (Join-Path $outputRoot 'matrix-summary.json'))
foreach ($record in $results) {
    Write-Host ('  ' + $record.cellId + ' r' + $record.run + ' → ' + $record.verdict + '（库 ' + $record.database + '）')
}
if ($unimplemented.Count -gt 0) {
    Write-Host ('[task31-matrix] 未实现执行器的格子（未实现 ≠ 通过）：' + (($unimplemented | ForEach-Object { $_.CellId }) -join '、'))
}
Write-Host ('[task31-matrix] ACC-G4=' + $decision.status + ' exit=' + $decision.exitCode +
    '；失败=' + @($decision.failures).Count + '；缺项=' + @($decision.missing).Count)
exit $decision.exitCode
