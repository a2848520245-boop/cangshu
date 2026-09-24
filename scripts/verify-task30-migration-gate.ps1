<#
.SYNOPSIS
    任务 30 迁移启动门取证：在隔离库上用真实 PostgreSQL + 打包 jar 复现「正常启动通过」与「四类漂移退出码 3」。

.DESCRIPTION
    仅供已核验的可销毁 VM 合成夹具使用。每轮生成唯一 runId、五个全新隔离库和独立日志目录；
    库与日志均保留供人工核对，不自动删除或覆盖。不得指向宿主机旧实例。
      1. 创建五个隔离库，各自用 psql 按序执行 db/migration 下全部脚本（带 SHA-256 记账）；
      2. 以显式参数启动打包 jar（java -jar target/cangshu-0.1.0-SNAPSHOT.jar）：
           -Dcangshu.migration.dir=<仓库 db/migration>
         -Dspring.datasource.url=jdbc:postgresql://127.0.0.1:<port>/<runId-隔离库>?currentSchema=cangshu_m1
         正常用例断言：日志出现 CANGSHU|migration|verified，健康检查 UP，进程退出码 0
         （正常用例经 actuator shutdown 端点优雅停机，退出码 0 即 JVM 正常终止）；
      3. 逐类制造真实漂移并重启，断言退出码 3 且日志含对应失败信息：
           A 台账缺行      —— 删除 schema_version 中 V2 行
           B 删除 CHECK    —— DROP CONSTRAINT content_size_bytes_check
           C 删除索引      —— DROP INDEX cangshu_m1.idx_content_digest
           D 未登记脚本    —— 复制 db/migration 并额外塞入 V9__unregistered.sql
         每类的原始日志（stdout/err）按用例名留在输出目录；
      4. 输出本轮库清单；核对证据后在 VM 内按清单人工清理。

    凭据来自 src/main/resources/application.yml 的既有默认值，可被 CANGSHU_DB_USER / CANGSHU_DB_PASSWORD
    覆盖；密码只经环境变量传递给子进程，不打印、不进命令行。

    前置：已构建打包 jar（mvn -B -DskipTests package）；本机有 PostgreSQL 17 客户端（默认 E:\\PostgreSQL\\17\\bin）；
    JAVA_HOME 指向 JDK 21+。

.EXAMPLE
    pwsh -File scripts/verify-task30-migration-gate.ps1 -DatabasePort <isolated-port> -VmFixtureId <vm-fixture-id> -DisposableVmConfirmed
#>
[CmdletBinding()]
param(
    [ValidateSet('127.0.0.1')]
    [string] $DatabaseHost = '127.0.0.1',
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 65535)]
    [int] $DatabasePort,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$')]
    [string] $VmFixtureId,
    [Parameter(Mandatory = $true)]
    [switch] $DisposableVmConfirmed,
    [ValidateRange(1, 65535)]
    [int] $ServerPort = 18080,
    [string] $PostgresBin = 'E:\PostgreSQL\17\bin',
    [ValidateRange(1, 3600)]
    [int] $TimeoutSeconds = 120
)

if ($DatabaseHost -cne '127.0.0.1' -or $DatabasePort -eq 5432) {
    throw '拒绝执行：必须连接 127.0.0.1 上显式指定的非 5432 隔离实例端口'
}
if (-not $DisposableVmConfirmed) { throw '拒绝执行：必须确认已核验可销毁 VM 合成夹具' }

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
$runId = [guid]::NewGuid().ToString('N')
$actuatorBasePath = '/actuator-task30-' + $runId
$outputParent = Join-Path $repoRoot 'target/task30-migration-gate'
$outputRoot = Join-Path $outputParent $runId
$postgresBinPath = Resolve-From $PostgresBin
$psql = Join-Path $postgresBinPath 'psql.exe'
$createdb = Join-Path $postgresBinPath 'createdb.exe'
$dataRoot = Join-Path $outputRoot 'data-root'
$databaseNames = [ordered]@{
    clean = "cangshu_task30_${runId}_c"
    ledger = "cangshu_task30_${runId}_a"
    check = "cangshu_task30_${runId}_b"
    index = "cangshu_task30_${runId}_i"
    script = "cangshu_task30_${runId}_s"
}
$script:currentDatabase = $null

# ── 前置检查 ────────────────────────────────────────────────────────────────────────────────
if (-not (Test-Path -LiteralPath $migrationDir)) { throw "找不到迁移脚本目录：$migrationDir" }
if (-not (Test-Path -LiteralPath $jarPath)) {
    throw "找不到打包 jar：$jarPath`n先执行：mvn -B -DskipTests package"
}
foreach ($tool in @($psql, $createdb)) {
    if (-not (Test-Path -LiteralPath $tool)) {
        throw "找不到 $tool`n用 -PostgresBin 指定 PostgreSQL 17 bin 目录（当前：$postgresBinPath）"
    }
}
$javaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME')
if (-not $javaHome) { throw '未设置 JAVA_HOME（打包 jar 需要 JDK 21+ 运行）' }
$javaPath = Join-Path $javaHome 'bin/java.exe'
if (-not (Test-Path -LiteralPath $javaPath)) { throw "找不到 java：$javaPath" }
$javaVersionLine = (& $javaPath -version 2>&1 | Select-Object -First 1) -join ''
$javaMajor = if ($javaVersionLine -match 'version "?(\d+)') { [int] $Matches[1] } else { 0 }
if ($javaMajor -lt 21) { throw "运行打包 jar 需要 JDK 21+，当前：$javaVersionLine" }
if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
    throw '找不到 Get-NetTCPConnection：无法核对本轮监听进程，拒绝发送健康或停机请求'
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

foreach ($directory in @($repoRoot, (Join-Path $repoRoot 'target'), $outputParent, $outputRoot)) {
    $item = Get-Item -LiteralPath $directory -Force -ErrorAction SilentlyContinue
    if ($null -ne $item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw "拒绝使用重解析目录作为取证输出路径：$directory"
    }
}
if (Test-Path -LiteralPath $outputRoot) { throw "拒绝覆盖已有取证目录：$outputRoot" }

function Quote-Arguments([string[]] $Arguments) {
    $quoted = foreach ($argument in $Arguments) {
        if ($argument -match '\s') { '"' + $argument + '"' } else { $argument }
    }
    return ($quoted -join ' ')
}

function Invoke-PsqlQuery {
    param([string] $Command)
    $output = (& $psql -h $DatabaseHost -p $DatabasePort -U $dbUser -d $script:currentDatabase -q -t -A -v 'ON_ERROR_STOP=1' -c $Command 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "psql 执行失败（退出码 $LASTEXITCODE）：$Command`n$($output -join [Environment]::NewLine)"
    }
    return $output
}

function Invoke-MigrationScripts {
    $scripts = @(Get-ChildItem -LiteralPath $migrationDir -Filter 'V*.sql' | Sort-Object -Property Name)
    if ($scripts.Count -eq 0) { throw "迁移目录里没有 V*.sql：$migrationDir" }
    foreach ($script in $scripts) {
        $sha = (Get-FileHash -LiteralPath $script.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $output = (& $psql -h $DatabaseHost -p $DatabasePort -U $dbUser -d $script:currentDatabase -q `
            -v 'ON_ERROR_STOP=1' -v "script_sha256=$sha" -f $script.FullName 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "迁移脚本执行失败：$($script.Name)`n$($output -join [Environment]::NewLine)"
        }
        Write-Host ("    迁移 {0}（sha256={1}…）" -f $script.Name, $sha.Substring(0, 12))
    }
}

function Assert-IsolatedDatabaseAbsent {
    param([string] $Name)
    $query = "SELECT count(*) FROM pg_database WHERE datname = '$Name'"
    $result = @(& $psql -h $DatabaseHost -p $DatabasePort -U $dbUser -d postgres -t -A -v 'ON_ERROR_STOP=1' -c $query 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "无法确认隔离库是否已存在：$Name（退出码 $LASTEXITCODE）" }
    if (($result -join '').Trim() -ne '0') { throw "拒绝覆盖已有隔离库：$Name" }
}

function New-IsolatedDatabase {
    param([string] $Name)
    $output = @(& $createdb -h $DatabaseHost -p $DatabasePort -U $dbUser $Name 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "创建隔离库失败：$Name（退出码 $LASTEXITCODE）：$($output -join ' | ')" }
    $script:createdDatabases += $Name
    Add-Content -LiteralPath (Join-Path $outputRoot 'created-databases.txt') -Value $Name -Encoding UTF8 -ErrorAction Stop
    $script:currentDatabase = $Name
    Invoke-MigrationScripts
}

function Get-ListeningSockets {
    # 查询失败必须中止；空列表仅表示当前没有监听，不能吞掉权限或 CIM 错误。
    return @(Get-NetTCPConnection -State Listen -ErrorAction Stop)
}

function Assert-ServerPortFree {
    $listeners = @(Get-ListeningSockets | Where-Object { [int]$_.LocalPort -eq $ServerPort })
    if ($listeners.Count -gt 0) { throw "服务端口 $ServerPort 已被占用，拒绝启动本轮 JVM" }
}

function Assert-OwnHttpListener {
    param([System.Diagnostics.Process] $Process)
    if ($Process.HasExited) { throw "本轮 JVM $($Process.Id) 已退出，拒绝发送 HTTP 请求" }
    $listeners = @(Get-ListeningSockets | Where-Object { [int]$_.LocalPort -eq $ServerPort })
    if ($listeners.Count -eq 0) { throw "服务端口 $ServerPort 无监听，拒绝发送 HTTP 请求" }
    foreach ($listener in $listeners) {
        if ([int]$listener.OwningProcess -ne $Process.Id -or $listener.LocalAddress -cne '127.0.0.1') {
            throw "服务端口 $ServerPort 的监听不属于本轮 JVM $($Process.Id) 的 127.0.0.1，拒绝发送 HTTP 请求"
        }
    }
    if ($Process.HasExited) { throw "本轮 JVM $($Process.Id) 在监听核对后退出，拒绝发送 HTTP 请求" }
    return "127.0.0.1:${ServerPort}|pid=$($Process.Id)"
}

function Start-GateProcess {
    param([string] $MigrationDirectory, [string] $LogName, [switch] $AllowShutdownEndpoint)
    Assert-ServerPortFree
    $jdbcUrl = 'jdbc:postgresql://' + $DatabaseHost + ':' + $DatabasePort + '/' + $script:currentDatabase + '?currentSchema=cangshu_m1'
    $jvmArguments = @(
        '-Dstdout.encoding=UTF-8',
        '-Dstderr.encoding=UTF-8',
        "-Dcangshu.migration.dir=$MigrationDirectory",
        "-Dcangshu.data-root=$dataRoot",
        "-Dspring.datasource.url=$jdbcUrl"
    )
    $applicationArguments = @('--spring.main.banner-mode=off', '--server.address=127.0.0.1', "--server.port=$ServerPort", "--management.server.port=$ServerPort", "--management.endpoints.web.base-path=$actuatorBasePath")
    if ($AllowShutdownEndpoint) {
        $applicationArguments += '--management.endpoints.web.exposure.include=health,shutdown'
        $applicationArguments += '--management.endpoint.shutdown.access=unrestricted'
    }
    $stdout = Join-Path $outputRoot "$LogName.log"
    $stderr = Join-Path $outputRoot "$LogName.err.log"
    $arguments = Quote-Arguments ($jvmArguments + @('-jar', $jarPath) + $applicationArguments)
    $process = Start-Process -FilePath $javaPath -ArgumentList $arguments -NoNewWindow -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $script:startedProcesses += $process
    return [pscustomobject]@{ Process = $process; Stdout = $stdout; Stderr = $stderr }
}

function Wait-ForLogPattern {
    param([string] $Path, [string] $Pattern, [int] $WaitSeconds)
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
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

function Invoke-CleanStartupCase {
    $run = Start-GateProcess -MigrationDirectory $migrationDir -LogName 'case-clean' -AllowShutdownEndpoint
    try {
        if (-not (Wait-ForLogPattern -Path $run.Stdout -Pattern 'CANGSHU|migration|verified' -WaitSeconds $TimeoutSeconds)) {
            throw "正常启动未出现 CANGSHU|migration|verified（见 $($run.Stdout)）"
        }
        if (-not (Wait-ForLogPattern -Path $run.Stdout -Pattern 'Started CangshuApplication' -WaitSeconds $TimeoutSeconds) -or $run.Process.HasExited) {
            throw "正常启动未确认自有服务已监听（见 $($run.Stdout)）"
        }
        $verifiedLines = @(Select-String -LiteralPath $run.Stdout -Pattern 'CANGSHU|migration|verified' -SimpleMatch -Encoding UTF8)
        $listenerEvidence = Assert-OwnHttpListener -Process $run.Process
        $health = Invoke-RestMethod -Method Get -Uri "http://127.0.0.1:${ServerPort}${actuatorBasePath}/health" -TimeoutSec 30
        if ($health.status -ne 'UP') { throw "健康检查未通过：$($health | ConvertTo-Json -Compress)" }
        Assert-OwnHttpListener -Process $run.Process | Out-Null
        Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:${ServerPort}${actuatorBasePath}/shutdown" -TimeoutSec 30 | Out-Null
        if (-not $run.Process.WaitForExit(60000)) { throw '优雅停机超时（60 秒内进程未退出）' }
        return [pscustomobject]@{
            Case       = '正常启动（clean）'
            Expected   = 0
            Actual     = $run.Process.ExitCode
            Log        = $run.Stdout
            Evidence   = "$($verifiedLines[0].Line.Trim())；$listenerEvidence；basePath=$actuatorBasePath"
            Message    = ''
        }
    } finally { Stop-OwnProcess $run.Process }
}

function Invoke-DriftCase {
    param([string] $Name, [string] $ExpectedMessage, [string] $MigrationDirectory = $migrationDir)
    $run = Start-GateProcess -MigrationDirectory $MigrationDirectory -LogName "case-$Name"
    try {
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $samples = 0
        $observedListener = $null
        while ((Get-Date) -lt $deadline) {
            $samples++
            $ownedListeners = @(Get-ListeningSockets | Where-Object { [int]$_.OwningProcess -eq $run.Process.Id })
            if ($ownedListeners.Count -gt 0) {
                $observedListener = ($ownedListeners | ForEach-Object { "$($_.LocalAddress):$($_.LocalPort)" }) -join ', '
                break
            }
            if ($run.Process.WaitForExit(100)) { break }
        }
        $logText = Get-LogText $run.Stdout
        $startedInLog = $logText -match '(?i)(Started CangshuApplication|Tomcat started)'
        $auditPath = Join-Path $outputRoot "case-$Name-listener-audit.txt"
        @(
            "runId=$runId", "case=$Name", "pid=$($run.Process.Id)", "samples=$samples",
            "observedListener=$observedListener", "startedInLog=$startedInLog", "stdout=$($run.Stdout)"
        ) | Set-Content -LiteralPath $auditPath -Encoding UTF8 -ErrorAction Stop
        if ($null -ne $observedListener -or $startedInLog) {
            throw "用例 $Name 曾出现本轮监听或启动成功日志，拒绝判定拒启（见 $auditPath）"
        }
        if (-not $run.Process.HasExited) {
            throw "用例 $Name 未在 $TimeoutSeconds 秒内退出（见 $($run.Stdout)）"
        }
        if (-not $logText.Contains($ExpectedMessage)) {
            throw "用例 $Name 的日志缺少期望信息「$ExpectedMessage」（见 $($run.Stdout)）"
        }
        return [pscustomobject]@{
            Case     = $Name
            Expected = 3
            Actual   = $run.Process.ExitCode
            Log      = $run.Stdout
            Evidence = "$ExpectedMessage；未观测到本轮监听（$samples 次轮询）；无 Started/Tomcat started 日志；$auditPath"
            Message  = $ExpectedMessage
        }
    } finally { Stop-OwnProcess $run.Process }
}

function Stop-OwnProcess {
    param([System.Diagnostics.Process] $Process)
    if (-not $Process.HasExited) { $Process.Kill() }
    if (-not $Process.WaitForExit(10000)) { throw "自有进程 $($Process.Id) 未在 10 秒内退出" }
}

function New-UnregisteredScriptDirectory {
    $directory = Join-Path $outputRoot 'migration-drift'
    if (Test-Path -LiteralPath $directory) { throw "拒绝覆盖已有漂移目录：$directory" }
    New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
    foreach ($script in @(Get-ChildItem -LiteralPath $migrationDir -Filter 'V*.sql')) {
        Copy-Item -LiteralPath $script.FullName -Destination (Join-Path $directory $script.Name)
    }
    Set-Content -LiteralPath (Join-Path $directory 'V9__unregistered.sql') -Encoding UTF8 -Value @(
        '-- 未登记脚本：只用于任务 30 迁移门负例取证，不进 db/migration。'
        'SELECT 1;'
    )
    return $directory
}

# ── 取证 ────────────────────────────────────────────────────────────────────────────────────
function Assert-CaseResult {
    param($Result)
    if ($Result.Actual -ne $Result.Expected) {
        throw "用例 $($Result.Case) 退出码错误：期望 $($Result.Expected)，实际 $($Result.Actual)；日志 $($Result.Log)"
    }
    Write-Host ("  [PASS] {0}：退出码 {1}；证据：{2}；日志：{3}" -f $Result.Case, $Result.Actual, $Result.Evidence, $Result.Log)
}

$createdDatabases = @()
$startedProcesses = @()
$cleanupErrors = @()
$priorEnv = @{}
foreach ($name in @('PGPASSWORD', 'CANGSHU_DB_USER', 'CANGSHU_DB_PASSWORD')) {
    $priorEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    if (-not (Test-Path -LiteralPath $outputParent)) {
        New-Item -ItemType Directory -Path $outputParent -ErrorAction Stop | Out-Null
    }
    New-Item -ItemType Directory -Path $outputRoot -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Path $dataRoot -ErrorAction Stop | Out-Null
    $manifest = @(
        "runId=$runId", "vmFixtureId=$VmFixtureId", "databaseHost=$DatabaseHost", "databasePort=$DatabasePort",
        "databaseUser=$dbUser", "serverAddress=127.0.0.1", "serverPort=$ServerPort", "jar=$jarPath",
        "migrationDirectory=$migrationDir", "outputDirectory=$outputRoot", "cleanup=manual-only"
    )
    foreach ($case in $databaseNames.Keys) { $manifest += "database.$case=$($databaseNames[$case])" }
    $manifest | Set-Content -LiteralPath (Join-Path $outputRoot 'run-manifest.txt') -Encoding UTF8 -ErrorAction Stop
    Write-Host "== 任务 30 迁移启动门取证：runId=$runId =="
    Write-Host "  VM 合成夹具：$VmFixtureId；隔离实例：${DatabaseHost}:${DatabasePort}；证据：$outputRoot"
    $env:PGPASSWORD = $dbPassword
    $env:CANGSHU_DB_USER = $dbUser
    $env:CANGSHU_DB_PASSWORD = $dbPassword
    foreach ($name in $databaseNames.Values) { Assert-IsolatedDatabaseAbsent -Name $name }

    Write-Host '[1/5] 正常启动（隔离库 + 人工迁移 + 打包 jar）'
    New-IsolatedDatabase -Name $databaseNames.clean
    $result = Invoke-CleanStartupCase
    Assert-CaseResult $result

    Write-Host '[2/5] 漂移 A：台账缺行（DELETE schema_version V2）'
    New-IsolatedDatabase -Name $databaseNames.ledger
    $deletedRows = @(Invoke-PsqlQuery "WITH deleted AS (DELETE FROM cangshu_m1.schema_version WHERE version = 'V2' RETURNING version) SELECT count(*) FROM deleted")
    if (($deletedRows -join '').Trim() -ne '1') { throw "台账负例未恰好删除一行 V2：$($deletedRows -join ' | ')" }
    $result = Invoke-DriftCase -Name 'drift-a-ledger-missing' -ExpectedMessage 'schema_version 台账与迁移脚本不一致'
    Assert-CaseResult $result

    Write-Host '[3/5] 漂移 B：删除 CHECK 约束（content_size_bytes_check）'
    New-IsolatedDatabase -Name $databaseNames.check
    Invoke-PsqlQuery 'ALTER TABLE cangshu_m1.content DROP CONSTRAINT content_size_bytes_check' | Out-Null
    $result = Invoke-DriftCase -Name 'drift-b-check-dropped' -ExpectedMessage 'schema 关键结构与 manifest 不一致'
    Assert-CaseResult $result

    Write-Host '[4/5] 漂移 C：删除索引（idx_content_digest）'
    New-IsolatedDatabase -Name $databaseNames.index
    Invoke-PsqlQuery 'DROP INDEX cangshu_m1.idx_content_digest' | Out-Null
    $result = Invoke-DriftCase -Name 'drift-c-index-dropped' -ExpectedMessage 'schema 关键结构与 manifest 不一致'
    Assert-CaseResult $result

    Write-Host '[5/5] 漂移 D：db/migration 多出未登记脚本（V9__unregistered.sql）'
    New-IsolatedDatabase -Name $databaseNames.script
    $driftDirectory = New-UnregisteredScriptDirectory
    $result = Invoke-DriftCase -Name 'drift-d-unregistered-script' -ExpectedMessage '迁移脚本集合或摘要与 manifest 不一致' `
        -MigrationDirectory $driftDirectory
    Assert-CaseResult $result
} finally {
    foreach ($process in $startedProcesses) {
        try { Stop-OwnProcess $process }
        catch { $cleanupErrors += "进程 $($process.Id) 收束失败：$($_.Exception.Message)" }
    }
    foreach ($name in $priorEnv.Keys) {
        [Environment]::SetEnvironmentVariable($name, $priorEnv[$name], 'Process')
    }
    Write-Host "  本轮库保留在 ${DatabaseHost}:${DatabasePort}：$($createdDatabases -join ', ')"
    Write-Host "  本轮库清单与参数：$(Join-Path $outputRoot 'run-manifest.txt')"
    if ($cleanupErrors.Count -gt 0) { throw "PROCESS_TREE_UNVERIFIED：$($cleanupErrors -join '；')" }
}

Write-Host '取证通过：正常启动退出码 0，四类真实漂移分别退出码 3。'
