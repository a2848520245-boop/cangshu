<#
.SYNOPSIS
    任务 29 单写者启动门取证：真实双进程互斥（退出码 2）＋ 数据根零字节 ＋ 反向证据。

.DESCRIPTION
    全部在隔离库上操作（默认库名前缀 cangshu_task29_verify_a / cangshu_task29_verify_b，
    每次追加 runId，只新建并保留），
    绝不触碰 cangshu / cangshu_test / cangshu_m1demo，也不改它们的 schema。

    步骤：
      1) 建两个隔离库并按序人工执行 db/migration 下全部脚本（带 -v script_sha256 记账）；
      2) 用例 0 正常启动（库 A ＋ 数据根 shared ＋ 端口 18090）：断言日志顺序
         门获取 → CANGSHU|migration|verified → Started CangshuApplication，健康检查 UP；
      3) 用例 1 同库 ＋ 同数据根（端口 18091）：第二个进程退出码 2、日志含门失败标记、
         全程无 Tomcat 监听，且数据根目录树／文件 SHA256／时间戳快照前后一致（不写任何业务字节）；
      4) 用例 2 同库 ＋ 不同数据根：仍退出码 2，拒绝原因＝DB 会话锁（该锁独立生效）；
      5) 用例 3 同数据根 ＋ 不同库：仍退出码 2，拒绝原因＝数据根文件锁（该锁独立生效）；
      6) 用例 4 反向证据：第一个进程优雅停机（退出码 0）后，后续进程必须能正常启动成功 ——
         证明门是「互斥」而不是「永久拒绝」。

    口径：数据根下的 .cangshu-writer.lock 是协议标记，不算业务字节。
    每次生成唯一 runId，证据写入 target/task29-gate/<runId>；已有同名目录即拒绝运行。
    证据和本轮新建的库均保留；
    在可销毁 VM 中核对证据后，按脚本输出的主机、端口、库名手工清理。

    凭据来自 src/main/resources/application.yml 的既有默认值，可被 CANGSHU_DB_USER / CANGSHU_DB_PASSWORD
    覆盖；密码只经环境变量传给子进程，不打印、不进命令行。

    前置：已构建打包 jar（mvn -B -DskipTests package）；本机有 PostgreSQL 17 客户端
    （默认 E:\PostgreSQL\17\bin，可用 -PostgresBin 覆盖）；JAVA_HOME 指向 JDK 21+。

.EXAMPLE
    pwsh -File scripts/verify-task29-single-writer.ps1 -DatabasePort <isolated-port>

#>
[CmdletBinding()]
param(
    [string] $PrimaryDatabaseName = 'cangshu_task29_verify_a',
    [string] $SecondaryDatabaseName = 'cangshu_task29_verify_b',
    [ValidateSet('127.0.0.1')]
    [string] $DatabaseHost = '127.0.0.1',
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 65535)]
    [int] $DatabasePort,
    [int] $PrimaryServerPort = 18090,
    [int] $SecondaryServerPort = 18091,
    [string] $PostgresBin = 'E:\PostgreSQL\17\bin',
    [int] $TimeoutSeconds = 120
)

if ($DatabaseHost -cne '127.0.0.1') {
    throw '拒绝执行：数据库主机必须是本机 127.0.0.1'
}
if ($DatabasePort -eq 5432) {
    throw '拒绝执行：5432 可能指向旧 PostgreSQL 实例；必须显式提供隔离实例的其他端口'
}

$ErrorActionPreference = 'Stop'
# PowerShell 7.3+ 会把原生命令的 stderr 当成错误；本脚本按退出码判定，显式关掉该行为。
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
function Resolve-From([string] $Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

$migrationDir = Join-Path $repoRoot 'db/migration'
$jarPath = Join-Path $repoRoot 'target/cangshu-0.1.0-SNAPSHOT.jar'
$runId = 'r' + (Get-Date -Format 'yyyyMMddHHmmssfff') + '_' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
$managementPath = '/m-' + $runId
$runRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'target/task29-gate'))
$outputRoot = [System.IO.Path]::GetFullPath((Join-Path $runRoot $runId))
$postgresBinPath = Resolve-From $PostgresBin
$psql = Join-Path $postgresBinPath 'psql.exe'
$createdb = Join-Path $postgresBinPath 'createdb.exe'
$curlPath = 'curl.exe'
$endpoint = $DatabaseHost + ':' + $DatabasePort
$sharedDataRoot = Join-Path $outputRoot 'data-root-shared'
$otherDataRoot = Join-Path $outputRoot 'data-root-other'

# ── 前置检查 ────────────────────────────────────────────────────────────────────────────────
foreach ($databaseName in @($PrimaryDatabaseName, $SecondaryDatabaseName)) {
    if ($databaseName -notmatch '^cangshu_task29_[A-Za-z0-9_]+$') {
        throw "拒绝执行：库名 '$databaseName' 不符合隔离库规则 ^cangshu_task29_[A-Za-z0-9_]+$（不得指向 cangshu / cangshu_test / cangshu_m1demo）"
    }
}
if ($PrimaryDatabaseName -eq $SecondaryDatabaseName) {
    throw '两个隔离库名必须不同：用例 3 要用「同数据根 ＋ 不同库」证明文件锁独立生效'
}
$PrimaryDatabaseName += '_' + $runId
$SecondaryDatabaseName += '_' + $runId
foreach ($databaseName in @($PrimaryDatabaseName, $SecondaryDatabaseName)) {
    if ($databaseName.Length -gt 63) {
        throw "拒绝执行：加 runId 后数据库名超过 PostgreSQL 63 字节限制：$databaseName"
    }
}
if (-not (Test-Path -LiteralPath $migrationDir)) { throw "找不到迁移脚本目录：$migrationDir" }
if (-not (Test-Path -LiteralPath $jarPath)) {
    throw "找不到打包 jar：$jarPath ； 先执行 mvn -B -DskipTests package"
}
foreach ($tool in @($psql, $createdb)) {
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
if (-not (Get-Command $curlPath -ErrorAction SilentlyContinue)) {
    throw "找不到 $curlPath（健康检查与优雅停调用它；Windows 10 1803+ 自带 curl.exe）"
}
if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
    throw '找不到 Get-NetTCPConnection：无法确认管理请求的监听 PID，拒绝运行'
}

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

function Assert-SafeOutputPaths {
    foreach ($directory in @($repoRoot, (Join-Path $repoRoot 'target'), $runRoot, $outputRoot)) {
        $item = Get-Item -LiteralPath $directory -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw "拒绝使用重解析目录作为取证输出路径：$directory"
        }
    }
    $runRootItem = Get-Item -LiteralPath $runRoot -Force -ErrorAction SilentlyContinue
    if ($null -ne $runRootItem -and -not $runRootItem.PSIsContainer) {
        throw "取证根路径不是目录：$runRoot"
    }
    if ($null -ne (Get-Item -LiteralPath $outputRoot -Force -ErrorAction SilentlyContinue)) {
        throw "拒绝覆盖已有取证目录：$outputRoot"
    }
}
Assert-SafeOutputPaths

# ── 通用工具 ────────────────────────────────────────────────────────────────────────────────
function Quote-Arguments([string[]] $Arguments) {
    $quoted = foreach ($argument in $Arguments) {
        if ($argument -match '\s') { '"' + $argument + '"' } else { $argument }
    }
    return ($quoted -join ' ')
}

function Invoke-PsqlQuery {
    param([string] $DatabaseName, [string] $Command)
    $output = (& $psql -h $DatabaseHost -p $DatabasePort -U $dbUser -d $DatabaseName -q -v 'ON_ERROR_STOP=1' -c $Command 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "psql 执行失败（退出码 $LASTEXITCODE）：$Command ； $($output -join ' | ')"
    }
    return $output
}

function Invoke-MigrationScripts {
    param([string] $DatabaseName)
    $scripts = @(Get-ChildItem -LiteralPath $migrationDir -Filter 'V*.sql' | Sort-Object -Property Name)
    if ($scripts.Count -eq 0) { throw "迁移目录里没有 V*.sql：$migrationDir" }
    foreach ($script in $scripts) {
        $sha = (Get-FileHash -LiteralPath $script.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $output = (& $psql -h $DatabaseHost -p $DatabasePort -U $dbUser -d $DatabaseName -q -v 'ON_ERROR_STOP=1' -v "script_sha256=$sha" -f $script.FullName 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "迁移脚本执行失败：$($script.Name) ； $($output -join ' | ')"
        }
    }
}

function Assert-IsolatedDatabaseAbsent {
    param([string] $DatabaseName)
    $query = "SELECT count(*) FROM pg_database WHERE datname = '$DatabaseName'"
    $result = @(& $psql -h $DatabaseHost -p $DatabasePort -U $dbUser -d postgres -t -A -v 'ON_ERROR_STOP=1' -c $query 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "无法确认隔离库是否已存在：$DatabaseName（退出码 $LASTEXITCODE）" }
    if (($result -join '').Trim() -ne '0') { throw "拒绝覆盖已有隔离库：$DatabaseName" }
}

function New-IsolatedDatabase {
    param([string] $DatabaseName)
    & $createdb -h $DatabaseHost -p $DatabasePort -U $dbUser $DatabaseName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "创建隔离库失败：$DatabaseName（退出码 $LASTEXITCODE）" }
    $script:createdDatabases += $DatabaseName
    Invoke-MigrationScripts -DatabaseName $DatabaseName
}

function Start-GateProcess {
    param(
        [string] $DatabaseName,
        [string] $DataRoot,
        [int] $ServerPort,
        [string] $LogName,
        [switch] $AllowShutdownEndpoint
    )
    # 用拼接而不是 "$DatabaseName?currentSchema=..."：PowerShell 会把 ? 并进变量名，URL 会被写坏。
    $jdbcUrl = 'jdbc:postgresql://' + $endpoint + '/' + $DatabaseName + '?currentSchema=cangshu_m1'
    $jvmArguments = @(
        '-Dstdout.encoding=UTF-8',
        '-Dstderr.encoding=UTF-8',
        "-Dcangshu.migration.dir=$migrationDir",
        "-Dcangshu.data-root=$DataRoot",
        "-Dspring.datasource.url=$jdbcUrl"
    )
    $applicationArguments = @('--spring.main.banner-mode=off', '--server.address=127.0.0.1', "--server.port=$ServerPort")
    if ($AllowShutdownEndpoint) {
        $applicationArguments += '--management.endpoints.web.exposure.include=health,shutdown'
        $applicationArguments += '--management.endpoint.shutdown.access=unrestricted'
        $applicationArguments += "--management.endpoints.web.base-path=$managementPath"
    }
    $stdout = Join-Path $outputRoot "$LogName.log"
    $stderr = Join-Path $outputRoot "$LogName.err.log"
    $arguments = Quote-Arguments ($jvmArguments + @('-jar', $jarPath) + $applicationArguments)
    $process = Start-Process -FilePath $javaPath -ArgumentList $arguments -NoNewWindow -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $script:startedProcesses += $process
    return [pscustomobject]@{ Process = $process; Stdout = $stdout; Stderr = $stderr; Database = $DatabaseName; DataRoot = $DataRoot; Port = $ServerPort }
}

function Get-FirstMatch {
    param([string] $Path, [string] $Pattern)
    $matches = @(Select-String -LiteralPath $Path -Pattern $Pattern -SimpleMatch -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function New-IsolatedDataRoot {
    param([string] $Path)
    $resolved = [System.IO.Path]::GetFullPath($Path)
    $relative = [System.IO.Path]::GetRelativePath($outputRoot, $resolved)
    if ($relative -notin @('data-root-shared', 'data-root-other') -or
        [System.IO.Path]::GetDirectoryName($resolved) -ne $outputRoot) {
        throw "拒绝创建非输出目录直属隔离数据根：$resolved"
    }
    $item = Get-Item -LiteralPath $resolved -Force -ErrorAction SilentlyContinue
    if ($null -ne $item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw "拒绝使用重解析数据根：$resolved"
    }
    if ($null -ne $item) { throw "拒绝覆盖已有数据根：$resolved" }
    New-Item -ItemType Directory -Path $resolved | Out-Null
    return $resolved
}

function Wait-ForLogPattern {
    param([string] $Path, [string] $Pattern, [int] $WaitSeconds, [System.Diagnostics.Process] $Process)
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($Process -and $Process.HasExited) { return $false }
        if (Test-Path -LiteralPath $Path) {
            try {
                if (Select-String -LiteralPath $Path -Pattern $Pattern -SimpleMatch -Quiet -Encoding UTF8 -ErrorAction Stop) {
                    return $true
                }
            } catch {
                # 子进程仍持有写句柄时重试即可
            }
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Get-LogText([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
}

function Get-LogTail([string] $Path, [int] $Lines = 15) {
    if (-not (Test-Path -LiteralPath $Path)) { return '(日志不存在)' }
    return ((Get-Content -LiteralPath $Path -Encoding UTF8 -Tail $Lines) -join [Environment]::NewLine)
}

function Assert-OwnedListener {
    param([System.Diagnostics.Process] $Process, [int] $ServerPort)
    if ($Process.HasExited) { throw "拒绝管理请求：本次 Java 进程 $($Process.Id) 已退出" }
    $listeners = @(Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $ServerPort -State Listen -ErrorAction Stop)
    if ($listeners.Count -eq 0 -or @($listeners | Where-Object { $_.OwningProcess -ne $Process.Id }).Count -gt 0) {
        throw "拒绝管理请求：127.0.0.1:$ServerPort 的监听 PID 不是本次 Java 进程 $($Process.Id)"
    }
}

function Invoke-Curl {
    param([string] $Method, [string] $Uri, [System.Diagnostics.Process] $Process, [int] $ServerPort, [int] $TimeoutSeconds = 15)
    Assert-OwnedListener -Process $Process -ServerPort $ServerPort
    $arguments = @('--silent', '--show-error', '--noproxy', '*', '--max-time', $TimeoutSeconds, '--request', $Method, $Uri)
    $output = (& $curlPath @arguments 2>&1) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0) {
        throw "curl 调用失败（退出码 $LASTEXITCODE）：$Method $Uri ； $output"
    }
    return $output
}

function Wait-ForHealth {
    param([System.Diagnostics.Process] $Process, [int] $ServerPort, [int] $WaitSeconds)
    $uri = 'http://127.0.0.1:' + $ServerPort + $managementPath + '/health'
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $lastError = '（尚未发起请求）'
    while ((Get-Date) -lt $deadline) {
        try {
            $health = (Invoke-Curl -Method 'GET' -Uri $uri -Process $Process -ServerPort $ServerPort -TimeoutSeconds 5) | ConvertFrom-Json
            if ($health.status -eq 'UP') { return $health }
            $lastError = '健康状态非 UP：' + ($health | ConvertTo-Json -Compress)
        } catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Milliseconds 800
    }
    throw "健康检查在 $WaitSeconds 秒内未通过：$lastError"
}

function Stop-GateProcessGracefully {
    param([System.Diagnostics.Process] $Process, [int] $ServerPort)
    Invoke-Curl -Method 'POST' -Uri ('http://127.0.0.1:' + $ServerPort + $managementPath + '/shutdown') -Process $Process -ServerPort $ServerPort | Out-Null
    if (-not $Process.WaitForExit(60000)) { throw '优雅停机超时（60 秒内进程未退出）' }
    return $Process.ExitCode
}

function Test-TcpListener {
    param([string] $TargetHost, [int] $Port, [int] $TimeoutMs = 400)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $client.ConnectAsync($TargetHost, $Port)
        if (-not $connect.Wait($TimeoutMs)) { return $false }
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Get-DataRootSnapshot {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $entries = @(Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object -Property FullName)
    return @($entries | ForEach-Object {
        $relative = $_.FullName.Substring($Path.Length).TrimStart([char] 92)
        if ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            'L|{0}' -f $relative
        } elseif ($_.PSIsContainer) {
            'D|{0}' -f $relative
        } else {
            $sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            'F|{0}|{1}|{2}|{3}' -f $relative, $_.Length, $_.LastWriteTimeUtc.ToString('o'), $sha256
        }
    })
}

function Save-DataRootSnapshot {
    param([string[]] $Snapshot, [string] $Path)
    $lines = if ($Snapshot.Count -eq 0) { @('(数据根不存在或为空目录)') } else { $Snapshot }
    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
    return $Path
}

function Assert-DataRootUnchanged {
    param([string] $CaseName, [string[]] $Before, [string] $DataRoot)
    $after = Get-DataRootSnapshot -Path $DataRoot
    Save-DataRootSnapshot -Snapshot $after -Path (Join-Path $outputRoot "case-$CaseName-data-root-after.txt") | Out-Null
    $difference = @(Compare-Object -ReferenceObject $Before -DifferenceObject $after)
    if ($difference.Count -ne 0) {
        $detail = ($difference | ForEach-Object { $_.SideIndicator + ' ' + $_.InputObject }) -join [Environment]::NewLine
        throw "用例 $CaseName 之后数据根发生了变化（门失败的进程写了东西）：" + [Environment]::NewLine + $detail
    }
    return "前后快照一致（$($Before.Count) 项，含目录和文件 SHA256）"
}

# ── 用例实现 ────────────────────────────────────────────────────────────────────────────────
function Invoke-PrimaryStartupCase {
    $run = Start-GateProcess -DatabaseName $PrimaryDatabaseName -DataRoot $sharedDataRoot -ServerPort $PrimaryServerPort -LogName 'case-0-primary-start' -AllowShutdownEndpoint
    if (-not (Wait-ForLogPattern -Path $run.Stdout -Pattern 'CANGSHU|writer-gate|acquired' -WaitSeconds $TimeoutSeconds -Process $run.Process)) {
        throw "用例 0 未出现门获取日志（见 $($run.Stdout)）" + [Environment]::NewLine + (Get-LogTail $run.Stdout)
    }
    if (-not (Wait-ForLogPattern -Path $run.Stdout -Pattern 'CANGSHU|migration|verified' -WaitSeconds $TimeoutSeconds -Process $run.Process)) {
        throw "用例 0 未出现迁移核对日志（见 $($run.Stdout)）" + [Environment]::NewLine + (Get-LogTail $run.Stdout)
    }
    if (-not (Wait-ForLogPattern -Path $run.Stdout -Pattern 'Started CangshuApplication' -WaitSeconds $TimeoutSeconds -Process $run.Process)) {
        throw "用例 0 未出现 Started CangshuApplication（见 $($run.Stdout)）" + [Environment]::NewLine + (Get-LogTail $run.Stdout)
    }
    Wait-ForHealth -Process $run.Process -ServerPort $PrimaryServerPort -WaitSeconds 60 | Out-Null

    # 协议标记不被对账当成孤儿字节：启动对账跑完之后，锁文件必须仍在原路径、且没有被隔离到 orphan/。
    # 一旦被挪走，原路径上会出现一个全新的无人加锁文件，第二个写者就能拿到文件锁。
    $lockFile = Join-Path $sharedDataRoot '.cangshu-writer.lock'
    if (-not (Test-Path -LiteralPath $lockFile)) {
        throw "启动对账之后协议锁文件不在原路径：$lockFile（孤儿隔离不得移动被门持有的锁文件）"
    }
    if (Test-Path -LiteralPath (Join-Path $sharedDataRoot 'orphan\.cangshu-writer.lock')) {
        throw '协议锁文件被对账隔离到了 orphan/：对账把锁文件当成了孤儿字节，文件锁互斥随之失效'
    }
    $configLine = Get-FirstMatch -Path $run.Stdout -Pattern 'CANGSHU|config|dataRoot='
    if ($null -eq $configLine -or -not $configLine.Line.Contains('writerLockFile=' + $lockFile)) {
        throw "启动配置行未登记数据根文件锁路径 $lockFile（见 $($run.Stdout)）"
    }


    $gateLine = Get-FirstMatch -Path $run.Stdout -Pattern 'CANGSHU|writer-gate|acquired'
    $verifiedLine = Get-FirstMatch -Path $run.Stdout -Pattern 'CANGSHU|migration|verified'
    $startedLine = Get-FirstMatch -Path $run.Stdout -Pattern 'Started CangshuApplication'
    if ($gateLine.LineNumber -ge $verifiedLine.LineNumber) {
        throw "启动顺序错误：门（第 $($gateLine.LineNumber) 行）必须早于迁移核对（第 $($verifiedLine.LineNumber) 行）"
    }
    if ($verifiedLine.LineNumber -ge $startedLine.LineNumber) {
        throw "启动顺序错误：迁移核对（第 $($verifiedLine.LineNumber) 行）必须早于开始服务（第 $($startedLine.LineNumber) 行）"
    }
    return [pscustomobject]@{
        Run      = $run
        Gate     = $gateLine.Line.Trim()
        Verified = $verifiedLine.Line.Trim()
        Started  = $startedLine.Line.Trim()
        Order    = "门第 $($gateLine.LineNumber) 行 → 迁移核对第 $($verifiedLine.LineNumber) 行 → 开始服务第 $($startedLine.LineNumber) 行"
    }
}

function Invoke-DeniedCase {
    param([string] $CaseName, [string] $DatabaseName, [string] $DataRoot, [int] $ServerPort, [string] $ExpectedReason)
    $run = Start-GateProcess -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -LogName "case-$CaseName"
    $listenerHits = 0
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    try {
        while ($true) {
            # 先探测端口再判退出：门失败的进程绝不能出现 Tomcat 监听。
            if (Test-TcpListener -TargetHost $DatabaseHost -Port $ServerPort) { $listenerHits++ }
            if ($run.Process.HasExited) { break }
            if ((Get-Date) -gt $deadline) { break }
            Start-Sleep -Milliseconds 150
        }
        if (-not $run.Process.HasExited) {
            throw "用例 $CaseName 未在 $TimeoutSeconds 秒内退出（见 $($run.Stdout)）" + [Environment]::NewLine + (Get-LogTail $run.Stdout)
        }
        $logText = Get-LogText $run.Stdout
        $deniedLine = Get-FirstMatch -Path $run.Stdout -Pattern ('CANGSHU|writer-gate|denied|reason=' + $ExpectedReason)
        if ($null -eq $deniedLine) {
            throw "用例 $CaseName 的日志缺少门失败标记 reason=$ExpectedReason（见 $($run.Stdout)）" + [Environment]::NewLine + (Get-LogTail $run.Stdout)
        }
        if ($logText.Contains('Started CangshuApplication') -or $logText.Contains('Tomcat started on port')) {
            throw "用例 $CaseName 出现了 Tomcat 监听／开始服务日志，违反「门失败即停写」"
        }
        if ($logText.Contains('CANGSHU|migration|verified')) {
            throw "用例 $CaseName 出现了迁移核对日志：门必须先于核对"
        }
        if ($logText.Contains('MigrationVerificationException')) {
            throw "用例 $CaseName 混入了迁移核对失败（退出码 3 的路径）：门失败必须与之区分"
        }
        if ($listenerHits -ne 0) {
            throw "用例 $CaseName 期间端口 $ServerPort 出现监听 $listenerHits 次（门失败不得对外服务）"
        }
        if ($run.Process.ExitCode -ne 2) {
            throw "用例 $CaseName 期望退出码 2，实际 $($run.Process.ExitCode)（见 $($run.Stdout)）" + [Environment]::NewLine + (Get-LogTail $run.Stdout)
        }
        return [pscustomobject]@{
            Case     = $CaseName
            Expected = 2
            Actual   = $run.Process.ExitCode
            Log      = $run.Stdout
            Evidence = $deniedLine.Line.Trim()
        }
    } finally {
        if (-not $run.Process.HasExited) { $run.Process.Kill() }
    }
}

# ── 取证 ────────────────────────────────────────────────────────────────────────────────────
Write-Host '== 任务 29 单写者启动门取证 =='
Write-Host "  runId：$runId"
Write-Host "  主库：$PrimaryDatabaseName    次库：$SecondaryDatabaseName    @ $endpoint    用户：$dbUser"
Write-Host "  日志目录：$outputRoot"
Write-Host "  jar：$jarPath"
foreach ($serverPort in @($PrimaryServerPort, $SecondaryServerPort)) {
    if (Test-TcpListener -TargetHost $DatabaseHost -Port $serverPort) {
        throw "端口 $serverPort 已被占用：取证要求两个端口都空着，否则监听探测不再可信"
    }
}

$results = @()
$createdDatabases = @()
$startedProcesses = @()
$cleanupErrors = @()
$priorEnv = @{}
foreach ($name in @('PGPASSWORD', 'CANGSHU_DB_USER', 'CANGSHU_DB_PASSWORD')) {
    $priorEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$primary = $null
$snapshotBefore = @()
$snapshotEvidence = '(用例 1 未执行)'
$reverseEvidence = '(用例 4 未执行)'
try {
    $env:PGPASSWORD = $dbPassword
    $env:CANGSHU_DB_USER = $dbUser
    $env:CANGSHU_DB_PASSWORD = $dbPassword
    Assert-IsolatedDatabaseAbsent -DatabaseName $PrimaryDatabaseName
    Assert-IsolatedDatabaseAbsent -DatabaseName $SecondaryDatabaseName
    Assert-SafeOutputPaths
    if (-not (Test-Path -LiteralPath $runRoot)) { New-Item -ItemType Directory -Path $runRoot | Out-Null }
    Assert-SafeOutputPaths
    New-Item -ItemType Directory -Path $outputRoot | Out-Null
    @(
        "runId=$runId"
        "databaseHost=$DatabaseHost"
        "databasePort=$DatabasePort"
        "primaryDatabase=$PrimaryDatabaseName"
        "secondaryDatabase=$SecondaryDatabaseName"
        "evidenceDirectory=$outputRoot"
    ) | Set-Content -LiteralPath (Join-Path $outputRoot 'run-info.txt') -Encoding UTF8
    Write-Host '[1/6] 建两个隔离库并按序人工执行迁移脚本'
    New-IsolatedDataRoot -Path $sharedDataRoot | Out-Null
    New-IsolatedDataRoot -Path $otherDataRoot | Out-Null
    New-IsolatedDatabase -DatabaseName $PrimaryDatabaseName
    New-IsolatedDatabase -DatabaseName $SecondaryDatabaseName

    Write-Host '[2/6] 用例 0：第一个写者正常启动（库 A ＋ 数据根 shared ＋ 端口 18090）'
    $primary = Invoke-PrimaryStartupCase
    $results += [pscustomobject]@{ Case = '用例 0 正常启动（第一个写者）'; Expected = 0; Actual = 0; Log = $primary.Run.Stdout; Evidence = $primary.Order }
    Write-Host "    顺序：$($primary.Order)"
    Write-Host "    $($primary.Gate)"
    Write-Host "    $($primary.Verified)"

    $snapshotBefore = Get-DataRootSnapshot -Path $sharedDataRoot
    Save-DataRootSnapshot -Snapshot $snapshotBefore -Path (Join-Path $outputRoot 'case-1-data-root-before.txt') | Out-Null

    Write-Host '[3/6] 用例 1：同库 ＋ 同数据根（端口 18091）'
    $caseOne = Invoke-DeniedCase -CaseName '1-same-database-same-root' -DatabaseName $PrimaryDatabaseName -DataRoot $sharedDataRoot -ServerPort $SecondaryServerPort -ExpectedReason 'db-session-lock'
    $results += $caseOne
    $snapshotEvidence = Assert-DataRootUnchanged -CaseName '1-same-database-same-root' -Before $snapshotBefore -DataRoot $sharedDataRoot

    Write-Host '[4/6] 用例 2：同库 ＋ 不同数据根（端口 18091）'
    $otherRootBefore = Get-DataRootSnapshot -Path $otherDataRoot
    Save-DataRootSnapshot -Snapshot $otherRootBefore -Path (Join-Path $outputRoot 'case-2-same-database-other-root-data-root-before.txt') | Out-Null
    $results += Invoke-DeniedCase -CaseName '2-same-database-other-root' -DatabaseName $PrimaryDatabaseName -DataRoot $otherDataRoot -ServerPort $SecondaryServerPort -ExpectedReason 'db-session-lock'
    Assert-DataRootUnchanged -CaseName '2-same-database-other-root' -Before $otherRootBefore -DataRoot $otherDataRoot | Out-Null

    Write-Host '[5/6] 用例 3：同数据根 ＋ 不同库（端口 18091）'
    $results += Invoke-DeniedCase -CaseName '3-same-root-other-database' -DatabaseName $SecondaryDatabaseName -DataRoot $sharedDataRoot -ServerPort $SecondaryServerPort -ExpectedReason 'data-root-file-lock'
    $snapshotEvidence = $snapshotEvidence + ' ／ 用例 3 后同样一致：' + (Assert-DataRootUnchanged -CaseName '3-same-root-other-database' -Before $snapshotBefore -DataRoot $sharedDataRoot)

    Write-Host '[6/6] 用例 4（反向证据）：第一个写者优雅停机后，后续进程必须能正常启动'
    $primaryExit = Stop-GateProcessGracefully -Process $primary.Run.Process -ServerPort $PrimaryServerPort
    $results[0].Actual = $primaryExit
    $releaseLine = Get-FirstMatch -Path $primary.Run.Stdout -Pattern 'CANGSHU|writer-gate|released'
    if ($null -eq $releaseLine) {
        throw "第一个写者停机后没有释放日志（见 $($primary.Run.Stdout)）"
    }
    $reverse = Start-GateProcess -DatabaseName $PrimaryDatabaseName -DataRoot $sharedDataRoot -ServerPort $SecondaryServerPort -LogName 'case-4-reverse-start' -AllowShutdownEndpoint
    if (-not (Wait-ForLogPattern -Path $reverse.Stdout -Pattern 'Started CangshuApplication' -WaitSeconds $TimeoutSeconds -Process $reverse.Process)) {
        throw "用例 4 反转失败：前一个写者停机后，后续进程仍无法启动（见 $($reverse.Stdout)）" + [Environment]::NewLine + (Get-LogTail $reverse.Stdout)
    }
    Wait-ForHealth -Process $reverse.Process -ServerPort $SecondaryServerPort -WaitSeconds 60 | Out-Null
    $reverseExit = Stop-GateProcessGracefully -Process $reverse.Process -ServerPort $SecondaryServerPort
    $reverseGateLine = Get-FirstMatch -Path $reverse.Stdout -Pattern 'CANGSHU|writer-gate|acquired'
    $reverseEvidence = '释放日志：' + $releaseLine.Line.Trim()
    $results += [pscustomobject]@{
        Case     = '用例 4 反向证据（前写者停机后重启）'
        Expected = 0
        Actual   = $reverseExit
        Log      = $reverse.Stdout
        Evidence = $reverseGateLine.Line.Trim()
    }
} finally {
    foreach ($process in $startedProcesses) {
        try {
            if (-not $process.HasExited) { $process.Kill() }
            if (-not $process.WaitForExit(10000)) { throw "进程 $($process.Id) 未在 10 秒内退出" }
        } catch {
            $cleanupErrors += "进程 $($process.Id) 清理失败：$($_.Exception.Message)"
        }
    }
    if ($createdDatabases.Count -gt 0) {
        Write-Host ('  本次 runId={0} 新建库已保留：{1}:{2} / {3}' -f $runId, $DatabaseHost, $DatabasePort, ($createdDatabases -join ' / '))
        Write-Host "  证据目录：$outputRoot"
        Write-Host '  请在可销毁 VM 中核对证据后，按上述主机、端口、库名手工清理。'
    }
    foreach ($name in $priorEnv.Keys) {
        try {
            [Environment]::SetEnvironmentVariable($name, $priorEnv[$name], 'Process')
        } catch {
            $cleanupErrors += "环境变量 $name 恢复失败：$($_.Exception.Message)"
        }
    }
    if ($cleanupErrors.Count -gt 0) {
        foreach ($message in $cleanupErrors) { Write-Warning $message }
    }
}

if ($cleanupErrors.Count -gt 0) { throw "取证清理失败：$($cleanupErrors -join '；')" }
Write-Host ''
Write-Host '== 结果 =='
$failed = @()
foreach ($result in $results) {
    $ok = ($result.Actual -eq $result.Expected)
    if (-not $ok) { $failed += $result }
    $mark = if ($ok) { 'PASS' } else { 'FAIL' }
    Write-Host ("  [{0}] {1}：期望退出码 {2} / 实际 {3}" -f $mark, $result.Case, $result.Expected, $result.Actual)
    Write-Host ("         证据：{0}" -f $result.Evidence)
    Write-Host ("         原始日志：{0}" -f $result.Log)
}
Write-Host ''
Write-Host "  用例 1 数据根快照：$snapshotEvidence"
Write-Host "  $reverseEvidence"
if ($failed.Count -gt 0) {
    Write-Host ''
    Write-Host "取证未通过：$($failed.Count) 个用例不符合期望（见上方日志）"
    exit 1
}
Write-Host ''
Write-Host '取证通过：同库同根／同库异根／同根异库三例都退出码 2 且无监听、无业务字节写入；前写者停机后重启成功。'
exit 0
