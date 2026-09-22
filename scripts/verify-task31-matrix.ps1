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
    要执行的格子，形如 '1-5'（点 5 类 ①）；可多值或用 -Cells all（默认 '1-5'）。
    已定义但本阶段未实现执行器的格子会显式报错（未实现 ≠ 通过）。

.EXAMPLE
    pwsh -File scripts/verify-task31-matrix.ps1 -Cells 1-5

.EXAMPLE
    pwsh -File scripts/verify-task31-matrix.ps1 -Cells 1-4 -Runs 1 -RateLimit 4k

.NOTES
    凭据来自 src/main/resources/application.yml 的既有默认值，可被 CANGSHU_DB_USER /
    CANGSHU_DB_PASSWORD 覆盖；密码只经 PGPASSWORD 传给子进程，不打印、不进命令行。
    前置：已构建打包 jar；PostgreSQL 17 客户端；JAVA_HOME 指向 JDK 21+。
#>
[CmdletBinding()]
param(
    [string[]] $Cells = @('1-5'),
    [int] $Runs = 3,
    [string] $DatabasePrefix = 'cangshu_task31',
    [string] $DatabaseHost = '127.0.0.1',
    [int] $DatabasePort = 5432,
    [int] $BaseServerPort = 18130,
    [string] $OutputDirectory = 'target/task31-matrix',
    [string] $PostgresBin = 'E:\\PostgreSQL\\17\\bin',
    [int] $TimeoutSeconds = 120,
    [int] $BlockWaitSeconds = 60,
    [string] $RateLimit = '8k',
    [int] $PayloadBytes = 65536,
    [switch] $KeepDatabase,
    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'
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
$outputRoot = Resolve-From $OutputDirectory
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
    if ($DatabaseName -match '[*?\\[\\]]') {
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
if (-not (Test-Path -LiteralPath $jarPath)) { throw "找不到打包 jar：$jarPath ； 先执行 mvn -B -DskipTests package" }
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
$javaMajor = if ($javaVersionLine -match 'version "?(\\d+)') { [int] $Matches[1] } else { 0 }
if ($javaMajor -lt 21) { throw "运行打包 jar 需要 JDK 21+，当前：$javaVersionLine" }
if (-not (Get-Command $curlPath -ErrorAction SilentlyContinue)) { throw "找不到 $curlPath" }

$applicationYaml = Get-Content -LiteralPath (Join-Path $repoRoot 'src/main/resources/application.yml') -Raw
function Get-ConfiguredDefault([string] $Key, [string] $Fallback) {
    $pattern = '(?m)^\\s*' + [regex]::Escape($Key) + ':\\s*\\$\\{CANGSHU_[A-Z_]+:([^}]+)\\}'
    if ($applicationYaml -match $pattern) { return $Matches[1].Trim() }
    return $Fallback
}
$dbUser = [Environment]::GetEnvironmentVariable('CANGSHU_DB_USER')
if (-not $dbUser) { $dbUser = Get-ConfiguredDefault 'username' 'postgres' }
$dbPassword = [Environment]::GetEnvironmentVariable('CANGSHU_DB_PASSWORD')
if (-not $dbPassword) { $dbPassword = Get-ConfiguredDefault 'password' 'postgres' }

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$env:PGPASSWORD = $dbPassword
$env:CANGSHU_DB_USER = $dbUser
$env:CANGSHU_DB_PASSWORD = $dbPassword

# 取证绑定：提交 ＋ 工作树状态（08 §6 要求证据同时绑定提交与工作树）。
$headCommit = (& git -C $repoRoot rev-parse HEAD 2>&1) -join ''
$worktreeDirty = @(& git -C $repoRoot status --porcelain | Where-Object { $_ -ne '' })
$headCommit = $headCommit.Trim()

# ════════════════════════════════════════════════════════════════════════════════════════════
#  通用工具
# ════════════════════════════════════════════════════════════════════════════════════════════
function Quote-Arguments([string[]] $Arguments) {
    $quoted = foreach ($argument in $Arguments) {
        if ($argument -match '\\s') { '"' + $argument + '"' } else { $argument }
    }
    return ($quoted -join ' ')
}

function Invoke-PsqlQuery {
    param([string] $DatabaseName, [string] $Command)
    $output = (& $psql -h $DatabaseHost -p $DatabasePort -U $dbUser -d $DatabaseName -q -v 'ON_ERROR_STOP=1' -c $Command 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "psql 执行失败（退出码 $LASTEXITCODE）：$Command ； $($output -join ' | ')" }
    return ($output -join [Environment]::NewLine)
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
    & $dropdb -h $DatabaseHost -p $DatabasePort -U $dbUser --if-exists $DatabaseName 2>&1 | Out-Null
    & $createdb -h $DatabaseHost -p $DatabasePort -U $dbUser $DatabaseName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "创建隔离库失败：$DatabaseName（退出码 $LASTEXITCODE）" }
    Invoke-MigrationScripts -DatabaseName $DatabaseName
}

function Remove-IsolatedDatabase {
    param([string] $DatabaseName)
    Assert-IsolatedDatabaseName -DatabaseName $DatabaseName
    & $dropdb -h $DatabaseHost -p $DatabasePort -U $dbUser --if-exists $DatabaseName 2>&1 | Out-Null
}

function Get-DatabaseInventory {
    $sql = 'SELECT datname FROM pg_database ORDER BY datname'
    return @(Invoke-PsqlQuery -DatabaseName 'postgres' -Command $sql | Where-Object { $_ -match '\\S' })
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
    $process = Start-Process -FilePath $javaPath -ArgumentList $arguments -NoNewWindow -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
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
        $relative = $_.FullName.Substring($DataRoot.Length).TrimStart([char] 92).Replace('\\', '/')
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
    return @(Invoke-PsqlQuery -DatabaseName $DatabaseName -Command $sql | Where-Object { $_ -match '\\S' })
}

function Save-Snapshot {
    param(
        [string] $Label, [string] $RunDirectory, [string] $DatabaseName,
        [string] $DataRoot, [int] $ServerPort, [string] $Extra = ''
    )
    $lines = @()
    $lines += '# 快照 ' + $Label + '  ' + (Get-Date).ToUniversalTime().ToString('o')
    $lines += '## 进程／端口（serve 端口 ' + $ServerPort + '）'
    $lines += 'listening=' + (Test-TcpListener -TargetHost '127.0.0.1' -Port $ServerPort)
    $lines += '## 只读 SQL（' + $DatabaseName + '.' + $schema + '）'
    $lines += @(Get-DatabaseState -DatabaseName $DatabaseName)
    $lines += '## 数据根文件树（' + $DataRoot + '）'
    $lines += @(Get-DataRootTree -DataRoot $DataRoot)
    if ($Extra) { $lines += '## 附加只读核对'; $lines += $Extra }
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
    $sql = 'BEGIN; LOCK TABLE ' + $schema + '.' + $Table + ' IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(300); COMMIT;'
    $out = Join-Path $RunDirectory ('fixture-table-block-' + $Table + '.out')
    $err = Join-Path $RunDirectory ('fixture-table-block-' + $Table + '.err')
    $arguments = @('-h', $DatabaseHost, '-p', $DatabasePort, '-U', $dbUser, '-d', $DatabaseName, '-q', '-c', $sql)
    $process = Start-Process -FilePath $psql -ArgumentList (Quote-Arguments $arguments) -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
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
    return @(Invoke-PsqlQuery -DatabaseName $DatabaseName -Command $sql | Where-Object { $_ -match '\\S' })
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
        $rows = @(Invoke-PsqlQuery -DatabaseName $DatabaseName -Command $sql | Where-Object { $_ -match '^\\s*\\d+\\s*$' })
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
    $process = Start-Process -FilePath $curlPath -ArgumentList (Quote-Arguments $arguments) -NoNewWindow -PassThru `
        -RedirectStandardOutput $codeFile -RedirectStandardError $errFile
    return [pscustomobject]@{
        Process = $process; Response = $responseFile; Code = $codeFile; Error = $errFile; Uri = $Uri
    }
}

function New-PayloadFile {
    param([string] $Path, [int] $SizeBytes)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    $buffer = New-Object byte[] $SizeBytes
    for ($index = 0; $index -lt $SizeBytes; $index++) { $buffer[$index] = [byte] (($index * 31 + 7) % 256) }
    [System.IO.File]::WriteAllBytes($Path, $buffer)
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
    param([string] $CellId, [int] $Run)
    $path = Join-Path (Get-CellDirectory -CellId $CellId) ('r' + $Run)
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    return $path
}

function Get-CellPort {
    param([int] $CellIndex, [int] $Run)
    return $BaseServerPort + ($CellIndex * 10) + $Run
}

function Get-CellDatabaseName {
    param([string] $CellId, [int] $Run)
    return $DatabasePrefix + '_' + ($CellId -replace '-', '_') + '_r' + $Run
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
        return @($cellRegistry | Where-Object { $_.Runner } | ForEach-Object { $_.Id })
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
    $run = Start-CangshuProcess -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort `
        -LogName ('cli-' + $Mode) -RunDirectory $RunDirectory -Mode $Mode
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
    if (Test-Path -LiteralPath $DataRoot) { Remove-Item -LiteralPath $DataRoot -Recurse -Force }
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
    $checks += [pscustomobject]@{ Name = '响应含资源与摘要'; Pass = ([bool] $uploaded -and [bool] $uploaded.digest);
        Detail = if ($uploaded) { 'digest=' + $uploaded.digest + '|sizeBytes=' + $uploaded.sizeBytes } else { '（空响应）' } }
    $checks += [pscustomobject]@{ Name = '响应摘要与服务端计算一致'; Pass = ([bool] $uploaded -and $uploaded.digest -eq $Payload.Digest);
        Detail = 'payload=' + $Payload.Digest }

    # 快照 1＝杀前（点 5 口径：真实 HTTP 响应之后、强杀之前）
    $snapshot1 = Save-Snapshot -Label '1-before-kill' -RunDirectory $RunDirectory -DatabaseName $DatabaseName `
        -DataRoot $DataRoot -ServerPort $ServerPort -Extra @('http_code=' + $httpCode, 'response=' + $responseJson)

    # 强杀（点 5：响应后即杀）
    $killNote = Stop-CangshuHard -Process $serve.Process

    # 快照 2＝杀后不重启（只读核对）
    $snapshot2 = Save-Snapshot -Label '2-after-kill-no-restart' -RunDirectory $RunDirectory -DatabaseName $DatabaseName `
        -DataRoot $DataRoot -ServerPort $ServerPort -Extra @('kill=' + $killNote)

    $state2 = Get-DatabaseState -DatabaseName $DatabaseName
    $checks += [pscustomobject]@{ Name = '快照2 三表齐全（提交后强杀不丢行）'; Pass = ($state2 -join '') -match 'counts\\|content=1,location=1,resource=1';
        Detail = ($state2 -join ' / ') }
    $checks += [pscustomobject]@{ Name = '快照2 serve 端口已关闭'; Pass = (-not (Test-TcpListener -TargetHost '127.0.0.1' -Port $ServerPort));
        Detail = 'port=' + $ServerPort }

    # 重启 → 启动对账（04 §8 步骤 3：对账先于服务开始）
    $serve2 = Start-ServeAndWait -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort `
        -LogName 'serve-2-restart' -RunDirectory $RunDirectory
    $startupReconcile = Wait-ForLogPattern -Path $serve2.Stdout -Pattern 'CANGSHU|job|reconcile|reconcile|' -WaitSeconds $TimeoutSeconds -Process $serve2.Process
    $reconcileLine = Get-CliSummaryLine -Stdout (Get-LogText $serve2.Stdout) -Prefix 'CANGSHU|job|reconcile|reconcile|'
    $checks += [pscustomobject]@{ Name = '重启后启动对账已运行且无异常'; Pass = ($startupReconcile -and $reconcileLine -match 'needsAttention=false');
        Detail = $reconcileLine }

    # 重启后资源可读（HTTP）
    $detailOut = Join-Path $RunDirectory 'restart-detail.json'
    $detailStatus = Get-HttpStatus -Method 'GET' -Uri ($uploadUri + '/' + $uploaded.resourceId) -OutFile $detailOut
    $contentOut = Join-Path $RunDirectory 'restart-content.bin'
    $contentStatus = Get-HttpStatus -Method 'GET' -Uri ($uploadUri + '/' + $uploaded.resourceId + '/content') -OutFile $contentOut
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
    $checks += [pscustomobject]@{ Name = '快照3 内容就绪 ＋ 位置在'; Pass = ($state3 -join '') -match 'resource\\|READY' -and ($state3 -join '') -match 'location\\|sha256/';
        Detail = ($state3 -join ' / ') }
    $tree3 = @(Get-DataRootTree -DataRoot $DataRoot)
    $checks += [pscustomobject]@{ Name = '快照3 最终键字节在且大小相符';
        Pass = (@($tree3 | Where-Object { $_ -like ('*' + $Payload.Digest + '|size=' + $Payload.SizeBytes) }).Count -eq 1);
        Detail = ($tree3 -join ' ; ') }
    $checks += [pscustomobject]@{ Name = '日志无 CANGSHU|alert'; Pass = ((Get-LogText $serve2.Stdout) -notmatch 'CANGSHU\\|alert');
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
    if (Test-Path -LiteralPath $DataRoot) { Remove-Item -LiteralPath $DataRoot -Recurse -Force }
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
        throw "未在 $BlockWaitSeconds 秒内命中点 4 接缝（未命中即重跑、不计次；见 $RunDirectory）"
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
    $checks += [pscustomobject]@{ Name = '快照2 三表无行（事务回滚）'; Pass = ($state2 -join '') -match 'counts\\|content=0,location=0,resource=0';
        Detail = ($state2 -join ' / ') }
    $tree2 = @(Get-DataRootTree -DataRoot $DataRoot)
    $orphanInPlace = @($tree2 | Where-Object { $_ -like ('sha256/*' + $Payload.Digest + '|size=' + $Payload.SizeBytes) }).Count
    $checks += [pscustomobject]@{ Name = '快照2 孤儿字节在最终键上（移动已发生）'; Pass = ($orphanInPlace -eq 1); Detail = ($tree2 -join ' ; ') }

    # 夹具卫生实测：带约束触发器重启会被 DEC-T3 结构门以退出码 3 拒启（夹具必须在重启前拆除）
    $gateAttemptLog = Join-Path $RunDirectory 'fixture-gate-attempt.log'
    $gateAttempt = Start-CangshuProcess -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort `
        -LogName 'fixture-gate-attempt' -RunDirectory $RunDirectory -Mode 'serve'
    $gateAttempt.Process.WaitForExit(90000) | Out-Null
    $gateExitCode = if ($gateAttempt.Process.HasExited) { $gateAttempt.Process.ExitCode } else { -1 }
    if (-not $gateAttempt.Process.HasExited) { Stop-Process -Id $gateAttempt.Process.Id -Force -ErrorAction SilentlyContinue }
    $gateInteraction = @(
        '# 夹具与 DEC-T3 结构门的交互实测（夹具卫生依据）',
        '夹具：' + $fixtureSql + '（CREATE CONSTRAINT TRIGGER → 进入 pg_constraint，contype=t）',
        '库内夹具清单：' + ($fixtureInventory -join ' ; '),
        '带夹具重启 serve 的退出码：' + $gateExitCode + '（期望 3＝结构核对不一致）',
        '日志尾部：' + [Environment]::NewLine + (Get-LogTail $gateAttemptLog 12)
    )
    Set-Content -LiteralPath (Join-Path $RunDirectory 'fixture-gate-interaction.txt') -Value $gateInteraction -Encoding UTF8
    $checks += [pscustomobject]@{ Name = '带约束触发器重启被结构门拒启（退出码 3，夹具须先拆除）'; Pass = ($gateExitCode -eq 3);
        Detail = 'exit_code=' + $gateExitCode }

    # 拆除夹具后重启 → 启动对账应把孤儿隔离
    Remove-FixtureObjects -DatabaseName $DatabaseName -RunDirectory $RunDirectory | Out-Null
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
    $checks += [pscustomobject]@{ Name = '快照3 仍无可见新增'; Pass = ($state3 -join '') -match 'counts\\|content=0,location=0,resource=0';
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

$cellRunners = @{
    '5-1' = 'Invoke-Cell1_5_Run'
    '4-1' = 'Invoke-Cell4_1_Run'
}

# ════════════════════════════════════════════════════════════════════════════════════════════
#  主流程
# ════════════════════════════════════════════════════════════════════════════════════════════
$requestedCells = Resolve-RequestedCells -Requested $Cells
$payload = New-PayloadFile -Path (Join-Path $outputRoot ('payloads/upload-' + $PayloadBytes + 'b.bin')) -SizeBytes $PayloadBytes

$databaseInventoryBefore = Get-DatabaseInventory
Set-Content -LiteralPath (Join-Path $outputRoot 'db-inventory-before.txt') -Value $databaseInventoryBefore -Encoding UTF8

Write-Host ('[task31-matrix] HEAD=' + $headCommit + ' 工作树脏=' + ($worktreeDirty.Count -gt 0) + '（脏文件 ' + $worktreeDirty.Count + ' 项）')
Write-Host ('[task31-matrix] 要求格子：' + ($requestedCells -join '、') + '；每格 ' + $Runs + ' 次；载荷 ' + $payload.SizeBytes + ' 字节，sha256=' + $payload.Digest)

$results = @()
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
    if (-not $cellRunners.ContainsKey($cellId)) {
        $unimplemented += [pscustomobject]@{ CellId = $cellId; Reach = $definition.Reach; Injection = $definition.Inj }
        Write-Host ('[task31-matrix] ' + $cellId + ' → 已定义但本阶段未实现执行器（未实现 ≠ 通过）')
        continue
    }
    $runner = Get-Command -Name $cellRunners[$cellId]
    for ($run = 1; $run -le $Runs; $run++) {
        $databaseName = Get-CellDatabaseName -CellId $cellId -Run $run
        $runDirectory = Get-RunDirectory -CellId $cellId -Run $run
        $dataRoot = Join-Path $runDirectory 'data-root'
        $serverPort = Get-CellPort -CellIndex $cellIndex -Run $run
        Write-Host ('[task31-matrix] 执行 ' + $cellId + ' r' + $run + ' 库=' + $databaseName + ' 端口=' + $serverPort)
        $result = $null
        try {
            $result = & $runner -CellId $cellId -Run $run -DatabaseName $databaseName -DataRoot $dataRoot `
                -ServerPort $serverPort -RunDirectory $runDirectory -Payload $payload
        } catch {
            $result = [pscustomobject]@{
                CellId = $cellId; Point = $definition.P; Class = $definition.C; Run = $run
                Database = $databaseName; DataRoot = $dataRoot; ServerPort = $serverPort
                Verdict = '未命中／执行异常'; Checks = @(); SnapshotFiles = @(); BlockEvidence = ''
                HttpCode = ''; Digest = $payload.Digest; FailedChecks = @($_.Exception.Message)
            }
            Write-Host ('[task31-matrix] ' + $cellId + ' r' + $run + ' 异常：' + $_.Exception.Message)
        } finally {
            if (-not $KeepDatabase) { Remove-IsolatedDatabase -DatabaseName $databaseName }
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
            checks = @($result.Checks | ForEach-Object { [pscustomobject]@{ name = $_.Name; pass = $_.Pass; detail = $_.Detail } })
            failedChecks = $result.FailedChecks
            executedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        Set-Content -LiteralPath (Join-Path $runDirectory 'result.json') -Value ($record | ConvertTo-Json -Depth 8) -Encoding UTF8
        $results += $record
        Write-Host ('[task31-matrix] ' + $cellId + ' r' + $run + ' → ' + $record.verdict +
            '（失败判据 ' + @($record.failedChecks).Count + ' 项）')
    }
    $cellIndex++
}

$databaseInventoryAfter = Get-DatabaseInventory
Set-Content -LiteralPath (Join-Path $outputRoot 'db-inventory-after.txt') -Value $databaseInventoryAfter -Encoding UTF8
$inventoryDifference = @(Compare-Object -ReferenceObject $databaseInventoryBefore -DifferenceObject $databaseInventoryAfter)

$summary = [pscustomobject]@{
    task = '31'; phase = 'first-cell smoke (08 §3.1)'
    executedAt = (Get-Date).ToUniversalTime().ToString('o')
    head = $headCommit; worktreeDirty = ($worktreeDirty.Count -gt 0); worktreeDirtyFiles = $worktreeDirty
    payload = [pscustomobject]@{ path = $payload.Path; sizeBytes = $payload.SizeBytes; sha256 = $payload.Digest }
    requestedCells = $requestedCells; runs = $Runs
    results = $results
    notApplicable = $notApplicable
    unimplementedCells = $unimplemented
    databaseInventoryUnchanged = ($inventoryDifference.Count -eq 0)
    leftoverDatabases = @(($databaseInventoryAfter | Where-Object { $_ -like ($DatabasePrefix + '*') }))
}
Set-Content -LiteralPath (Join-Path $outputRoot 'matrix-summary.json') -Value ($summary | ConvertTo-Json -Depth 10) -Encoding UTF8

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
            $lines += '- 快照1（杀前）：' + (($before | Where-Object { $_ -match '^(counts|content|location|resource)\\|' }) -join ' ； ')
            $lines += '- 快照2（杀后不重启）：' + (($after | Where-Object { $_ -match '^(counts|content|location|resource)\\|' }) -join ' ； ')
            $lines += '- 快照3（重启后对账）：' + (($restart | Where-Object { $_ -match '^(counts|content|location|resource)\\|' }) -join ' ； ')
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
