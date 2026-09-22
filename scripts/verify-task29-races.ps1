<#
.SYNOPSIS
    P0-3③ 对账共锁与任务 29 重启竞态专项取证（真实进程／隔离库／可复跑）。

.DESCRIPTION
    全部在隔离库上操作（默认 cangshu_task29race_c / _a / _b，自建自删），绝不触碰
    cangshu、cangshu_test、cangshu_m1demo、cangshu_u1demo/u2demo/u3demo、cangshu_task3/4/4_bench/5。

    用例 C（对账不隔离门锁文件）：数据根预置协议锁文件（带哨兵内容）＋ 一个真孤儿，起 serve →
      启动对账在**持有门**的状态下运行 → 断言：真孤儿被隔离（说明扫描确实跑过）、锁文件仍在原处且
      字节／长度／修改时间未变、orphan/ 下没有它、orphanFound 只计真孤儿。

    用例 A（门专用会话断开后是否停写）：起 serve → 记录门专用会话 backend PID 与 pg_locks 原文 →
      pg_terminate_backend 只断该会话 → A2 再发真实 HTTP 上传与删除（**如实记录**写入行为）→ A1
      同数据根的第二写者仍被拒（退出码 2、reason=data-root-file-lock：文件锁独立兜住单写者互斥）→
      杀旧进程 → 重启 serve：新门可取得、正常上传（恢复路径不是永久锁死）。

    用例 B（旧业务 COMMIT 未结束时重启对账）：resource 插入后的延时触发器把一次真实上传卡在
      「已 moveInto、位置行未提交」窗口（附阻塞点 pg_stat_activity／pg_locks 原文）：
      B1 上传进行中（curl --limit-rate 节流拉长窗口）尝试对账 CLI → 退出码 2（写者门拒绝）；
      B2 未提交窗口内断开门的 DB 会话后再跑对账 CLI → 退出码 2（数据根文件锁），正式字节未被隔离、
         orphan/ 无该键；
      B3 上传提交后：内容 READY、位置行 1、字节摘要与内容身份一致；
      B4 停服后对账 CLI → 退出码 0、orphanFound=0、bytesMissing=0（最终一致性）。

    口径：多进程下「对账 CLI 与上传同时写」是单写者门明确禁止的（07-运行手册 §7），因此用例 B 的
    对抗证据是「对账被门拒绝、一根字节未动」；真正**同时在跑**的一侧由仓内集成测试
    GcAndReconcileIntegrationTests#concurrentUploadWindowIsNeverQuarantined 覆盖（同进程、真实
    PostgreSQL ＋ 真实数据根，分段锁内重读后判定）。

    凭据来自 src/main/resources/application.yml 的既有默认值，可被 CANGSHU_DB_USER /
    CANGSHU_DB_PASSWORD 覆盖；密码只经环境变量传给子进程，不打印、不进命令行。

    前置：本机 PostgreSQL 17（默认 E:\PostgreSQL\17\bin，可用 -PostgresBin 覆盖）；JAVA_HOME 指向
    JDK 21+；缺 jar 时本脚本会先用 mvn -B -DskipTests package 构建。

.EXAMPLE
    pwsh -File scripts/verify-task29-races.ps1

.EXAMPLE
    pwsh -File scripts/verify-task29-races.ps1 -KeepDatabase -OutputDirectory D:\p0-3-reconcile
#>
[CmdletBinding()]
param(
    [string] $DatabaseNameC = 'cangshu_task29race_c',
    [string] $DatabaseNameA = 'cangshu_task29race_a',
    [string] $DatabaseNameB = 'cangshu_task29race_b',
    [string] $DatabaseHost = '127.0.0.1',
    [int] $DatabasePort = 5432,
    [int] $ServerPort = 18092,
    [int] $ProbeServerPort = 18093,
    [string] $OutputDirectory = 'target/p0-3-reconcile',
    [string] $MirrorDirectory = 'target/p0-3-reconcile-mirror',
    [string] $PostgresBin = 'E:\PostgreSQL\17\bin',
    [int] $TimeoutSeconds = 180,
    [int] $CommitWindowSeconds = 40,
    [int] $ThrottleBytes = 4194304,
    [string] $ThrottleRate = '250K',
    [switch] $SkipBuild,
    [switch] $KeepDatabase
)

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
$outputRoot = Resolve-From $OutputDirectory
$mirrorRoot = Resolve-From $MirrorDirectory
$postgresBinPath = Resolve-From $PostgresBin
$psql = Join-Path $postgresBinPath 'psql.exe'
$createdb = Join-Path $postgresBinPath 'createdb.exe'
$dropdb = Join-Path $postgresBinPath 'dropdb.exe'
$curlPath = 'curl.exe'
$schema = 'cangshu_m1'
$endpoint = $DatabaseHost + ':' + $DatabasePort
$serverEndpoint = $DatabaseHost + ':' + $ServerPort
$probeServerEndpoint = $DatabaseHost + ':' + $ProbeServerPort
$writerLockKey = 20260919   # 07 §1 登记值：单写者门的 PostgreSQL 会话级咨询锁键
$dataRootC = Join-Path $outputRoot 'data-root-c-lockfile'
$dataRootA = Join-Path $outputRoot 'data-root-a-gate-session'
$dataRootB = Join-Path $outputRoot 'data-root-b-commit-window'
$checks = [System.Collections.Generic.List[object]]::new()
$serveProcesses = [System.Collections.Generic.List[object]]::new()

# ── 通用工具 ────────────────────────────────────────────────────────────────────────────────
function Quote-Arguments([string[]] $Arguments) {
    $quoted = foreach ($argument in $Arguments) {
        if ($argument -match '\s') { '"' + $argument + '"' } else { $argument }
    }
    return ($quoted -join ' ')
}

function Save-Text {
    param([string[]] $Lines, [string] $Path)
    $text = ($Lines -join [Environment]::NewLine) + [Environment]::NewLine
    # 无 BOM 的 UTF-8：SQL 夹具文件不能带 BOM，否则 psql 会把它当成语句开头
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
    return $Path
}

function Invoke-PsqlTuples {
    param([string] $DatabaseName, [string] $Command)
    # -w：绝不进密码提示——无凭据时立刻失败，不允许挂在交互输入上
    $output = (& $psql -h $DatabaseHost -p $DatabasePort -U $dbUser -d $DatabaseName -q -t -A -w -v 'ON_ERROR_STOP=1' -c $Command 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "psql 执行失败（退出码 $LASTEXITCODE）：$Command ； $($output -join ' | ')" }
    return @($output | ForEach-Object { ([string] $_).Trim() } | Where-Object { $_ -ne '' })
}

function Invoke-PsqlQuery {
    param([string] $DatabaseName, [string] $Command)
    $output = (& $psql -h $DatabaseHost -p $DatabasePort -U $dbUser -d $DatabaseName -q -w -v 'ON_ERROR_STOP=1' -c $Command 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "psql 执行失败（退出码 $LASTEXITCODE）：$Command ； $($output -join ' | ')" }
    return @($output | ForEach-Object { ([string] $_).TrimEnd() })
}

function Invoke-PsqlFile {
    param([string] $DatabaseName, [string] $Path)
    $output = (& $psql -h $DatabaseHost -p $DatabasePort -U $dbUser -d $DatabaseName -q -w -v 'ON_ERROR_STOP=1' -f $Path 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "psql -f 失败（退出码 $LASTEXITCODE）：$Path ； $($output -join ' | ')" }
    return @($output)
}

function Invoke-MigrationScripts {
    param([string] $DatabaseName)
    $scripts = @(Get-ChildItem -LiteralPath $migrationDir -Filter 'V*.sql' | Sort-Object -Property Name)
    if ($scripts.Count -eq 0) { throw "迁移目录里没有 V*.sql：$migrationDir" }
    foreach ($script in $scripts) {
        $sha = (Get-FileHash -LiteralPath $script.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $output = (& $psql -h $DatabaseHost -p $DatabasePort -U $dbUser -d $DatabaseName -q -w -v 'ON_ERROR_STOP=1' -v "script_sha256=$sha" -f $script.FullName 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "迁移脚本执行失败：$($script.Name) ； $($output -join ' | ')" }
    }
    return $scripts.Count
}

function Reset-IsolatedDatabase {
    param([string] $DatabaseName)
    if ($DatabaseName -notin @($DatabaseNameC, $DatabaseNameA, $DatabaseNameB)) {
        throw "拒绝删库：$DatabaseName 不在本次三个隔离库的白名单内"
    }
    & $dropdb -h $DatabaseHost -p $DatabasePort -U $dbUser --if-exists $DatabaseName 2>&1 | Out-Null
    & $createdb -h $DatabaseHost -p $DatabasePort -U $dbUser $DatabaseName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "创建隔离库失败：$DatabaseName（退出码 $LASTEXITCODE）" }
    return Invoke-MigrationScripts -DatabaseName $DatabaseName
}

function Reset-DataRoot {
    param([string] $Path)
    $resolved = [System.IO.Path]::GetFullPath($Path)
    $allowed = @($dataRootC, $dataRootA, $dataRootB) |
        ForEach-Object { [System.IO.Path]::GetFullPath($_) }
    if ($allowed -notcontains $resolved) {
        throw "拒绝清理不在本次三个数据根白名单内的目录：$resolved"
    }
    if ((Test-Path -LiteralPath $resolved) -and
        ((Get-Item -LiteralPath $resolved -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw "拒绝递归清理目录联接或符号链接：$resolved"
    }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $resolved | Out-Null
    return $resolved
}

function Get-DataRootTree {
    param([string] $DataRoot)
    if (-not (Test-Path -LiteralPath $DataRoot)) { return @('(数据根不存在)') }
    $entries = @(Get-ChildItem -LiteralPath $DataRoot -Recurse -Force -File | Sort-Object -Property FullName)
    return @($entries | ForEach-Object {
        $relative = $_.FullName.Substring($DataRoot.Length).TrimStart([char] 92, [char] 47)
        '{0}|size={1}|mtimeUtc={2}' -f $relative, $_.Length, $_.LastWriteTimeUtc.ToString('o')
    })
}

function Get-LogText([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($null -eq $text) { return '' }   # 空文件：Get-Content -Raw 返回 $null，调用方按空串处理
    return $text
}

function Get-LogTail([string] $Path, [int] $Lines = 15) {
    if (-not (Test-Path -LiteralPath $Path)) { return '(日志不存在)' }
    return ((Get-Content -LiteralPath $Path -Encoding UTF8 -Tail $Lines) -join [Environment]::NewLine)
}

function Get-LogLine {
    param([string] $Path, [string] $Pattern)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $hits = @(Select-String -LiteralPath $Path -Pattern $Pattern -SimpleMatch -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($hits.Count -eq 0) { return $null }
    return $hits[0]
}

function Get-LogLines {
    param([string] $Path, [string] $Pattern)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Select-String -LiteralPath $Path -Pattern $Pattern -SimpleMatch -Encoding UTF8 -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Line.Trim() })
}

function Get-SummaryField {
    param([string] $Line, [string] $Key)
    if ($Line -match ($Key + '=([^|]+)')) { return $Matches[1].Trim() }
    return ''
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
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Wait-ForCondition {
    param([scriptblock] $Condition, [int] $WaitSeconds, [string] $Description)
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            if (& $Condition) { return $true }
        } catch {
            # 条件里的查询在目标进程重启期间可能瞬时失败：重试即可
        }
        Start-Sleep -Milliseconds 250
    }
    throw "等待超时（$WaitSeconds 秒）：$Description"
}

function Invoke-Curl {
    param([string] $Method, [string] $Uri, [int] $TimeoutSeconds = 15)
    $arguments = @('--silent', '--show-error', '--noproxy', '*', '--max-time', $TimeoutSeconds, '--request', $Method, $Uri)
    $output = (& $curlPath @arguments 2>&1) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0) { throw "curl 调用失败（退出码 $LASTEXITCODE）：$Method $Uri ； $output" }
    return $output
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
        } catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Milliseconds 700
    }
    throw "健康检查在 $WaitSeconds 秒内未通过：$lastError"
}

function Get-JdbcUrl([string] $DatabaseName) {
    # 用拼接而不是 "$DatabaseName?currentSchema=..."：PowerShell 会把 ? 并进变量名，URL 会被写坏。
    return 'jdbc:postgresql://' + $endpoint + '/' + $DatabaseName + '?currentSchema=' + $schema
}

function Get-CommonJvmArguments([string] $DatabaseName, [string] $DataRoot) {
    # 注意：数组字面量里的逗号比 + 结合得更紧——'-Dkey=' + $value 会被拆成两个参数（Java 会把值当成主类）。
    # 因此这里一律用双引号插值，绝不写成 @('a', 'b' + $c)。
    return @(
        '-Dstdout.encoding=UTF-8',
        '-Dstderr.encoding=UTF-8',
        "-Dcangshu.migration.dir=$migrationDir",
        "-Dcangshu.data-root=$DataRoot",
        "-Dspring.datasource.url=$(Get-JdbcUrl $DatabaseName)"
    )
}

function Start-ServeProcess {
    param([string] $DatabaseName, [string] $DataRoot, [int] $ServerPort, [string] $LogName, [switch] $AllowShutdown)
    $applicationArguments = @('--spring.main.banner-mode=off', "--server.port=$ServerPort")
    if ($AllowShutdown) {
        $applicationArguments += '--management.endpoints.web.exposure.include=health,shutdown'
        $applicationArguments += '--management.endpoint.shutdown.enabled=true'
    }
    $stdout = Join-Path $outputRoot ($LogName + '.log')
    $stderr = Join-Path $outputRoot ($LogName + '.err.log')
    $arguments = Quote-Arguments ((Get-CommonJvmArguments $DatabaseName $DataRoot) + @('-jar', $jarPath) + $applicationArguments)
    $process = Start-Process -FilePath $javaPath -ArgumentList $arguments -NoNewWindow -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    return [pscustomobject]@{ Process = $process; Stdout = $stdout; Stderr = $stderr; Database = $DatabaseName; DataRoot = $DataRoot; Port = $ServerPort }
}

function Start-ServeAndWait {
    param([string] $DatabaseName, [string] $DataRoot, [int] $ServerPort, [string] $LogName)
    $run = Start-ServeProcess -DatabaseName $DatabaseName -DataRoot $DataRoot -ServerPort $ServerPort -LogName $LogName -AllowShutdown
    $serveProcesses.Add($run)
    if (-not (Wait-ForLogPattern -Path $run.Stdout -Pattern 'CANGSHU|writer-gate|acquired' -WaitSeconds $TimeoutSeconds -Process $run.Process)) {
        throw ($LogName + ' 未出现写者门获取日志：' + $run.Stdout + [Environment]::NewLine +
            (Get-LogTail $run.Stdout) + [Environment]::NewLine + 'stderr：' + (Get-LogTail $run.Stderr 10))
    }
    if (-not (Wait-ForLogPattern -Path $run.Stdout -Pattern 'CANGSHU|job|maintenance|' -WaitSeconds $TimeoutSeconds -Process $run.Process)) {
        throw ($LogName + ' 未出现启动维护摘要（对账＋GC）：' + $run.Stdout + [Environment]::NewLine + (Get-LogTail $run.Stdout))
    }
    Wait-ForHealth -ServerEndpoint ($DatabaseHost + ':' + $ServerPort) -WaitSeconds 90 | Out-Null
    return $run
}

function Invoke-CliRun {
    param([string] $DatabaseName, [string] $DataRoot, [string] $LogName, [string] $Mode = 'reconcile')
    $applicationArguments = @('--spring.main.web-application-type=none', '--spring.main.banner-mode=off', "--mode=$Mode")
    $stdout = Join-Path $outputRoot ($LogName + '.log')
    $stderr = Join-Path $outputRoot ($LogName + '.err.log')
    $arguments = Quote-Arguments ((Get-CommonJvmArguments $DatabaseName $DataRoot) + @('-jar', $jarPath) + $applicationArguments)
    $process = Start-Process -FilePath $javaPath -ArgumentList $arguments -NoNewWindow -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $exited = $process.WaitForExit(($TimeoutSeconds + 60) * 1000)
    if (-not $exited) {
        $process.Kill()
        throw ('CLI 作业 ' + $LogName + ' 超时未退出：' + $stdout + [Environment]::NewLine + (Get-LogTail $stdout))
    }
    return [pscustomobject]@{ Process = $process; ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

function Get-CliSummaryLine {
    param([string] $Stdout, [string] $Prefix = 'reconcile|')
    if (-not (Test-Path -LiteralPath $Stdout)) { return '' }
    $lines = @(Get-Content -LiteralPath $Stdout -Encoding UTF8 | Where-Object { $_.TrimStart().StartsWith($Prefix) })
    if ($lines.Count -eq 0) { return '' }
    return $lines[-1].Trim()
}

function Stop-ServeGracefully {
    param([System.Diagnostics.Process] $Process, [string] $ServerEndpoint)
    Invoke-Curl -Method 'POST' -Uri ('http://' + $ServerEndpoint + '/actuator/shutdown') | Out-Null
    if (-not $Process.WaitForExit(90000)) { throw '优雅停机超时（90 秒内进程未退出）' }
    return $Process.ExitCode
}

function Stop-ProcessHard {
    param([System.Diagnostics.Process] $Process)
    if ($Process -and -not $Process.HasExited) {
        $Process.Kill()
        $Process.WaitForExit(30000) | Out-Null
    }
}

function Save-BlockEvidence {
    param([string] $Label, [string] $DatabaseName, [string] $ExtraNote = '')
    $activity = "SELECT pid, state, coalesce(wait_event_type, '-') AS wait_event_type, " +
                "coalesce(wait_event, '-') AS wait_event, backend_type, " +
                "left(replace(query, chr(10), ' '), 130) AS query " +
                "FROM pg_stat_activity WHERE datname = '" + $DatabaseName + "' AND pid <> pg_backend_pid() ORDER BY pid"
    $locks = "SELECT l.pid, l.locktype, l.mode, l.granted, " +
             "coalesce(l.classid::text, '-') AS classid, coalesce(l.objid::text, '-') AS objid, " +
             "coalesce(c.relname, '-') AS relation FROM pg_locks l LEFT JOIN pg_class c ON c.oid = l.relation " +
             "WHERE l.pid IN (SELECT pid FROM pg_stat_activity WHERE datname = '" + $DatabaseName + "') " +
             "ORDER BY l.pid, l.granted DESC, l.locktype"
    $lines = @()
    $lines += '# 阻塞点证据 [' + $Label + ']  ' + (Get-Date).ToUniversalTime().ToString('o')
    $lines += '库：' + $DatabaseName + '    写者会话锁键：' + $writerLockKey
    if ($ExtraNote) { $lines += '说明：' + $ExtraNote }
    $lines += ''
    $lines += '## A. pg_stat_activity 原文'
    $lines += @(Invoke-PsqlQuery -DatabaseName $DatabaseName -Command $activity)
    $lines += ''
    $lines += '## B. pg_locks 原文'
    $lines += @(Invoke-PsqlQuery -DatabaseName $DatabaseName -Command $locks)
    $path = Join-Path $outputRoot ('block-evidence-' + $Label + '.txt')
    $saved = Save-Text -Lines $lines -Path $path
    return [pscustomobject]@{ Path = $saved; Lines = $lines }
}

function Get-GateSessionPid {
    param([string] $DatabaseName)
    $sql = "SELECT l.pid FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid " +
           "WHERE l.locktype = 'advisory' AND l.granted AND a.datname = '" + $DatabaseName + "' ORDER BY l.pid LIMIT 1"
    $rows = @(Invoke-PsqlTuples -DatabaseName $DatabaseName -Command $sql)
    if ($rows.Count -eq 0) { return 0 }
    return [int] $rows[0]
}

function Get-DatabaseCounts {
    param([string] $DatabaseName)
    $sql = "SELECT 'content=' || (SELECT count(*) FROM ${schema}.content) " +
           "|| '|location=' || (SELECT count(*) FROM ${schema}.location) " +
           "|| '|resource=' || (SELECT count(*) FROM ${schema}.resource)"
    return (Invoke-PsqlTuples -DatabaseName $DatabaseName -Command $sql)
}

function Get-AdvisoryLockProbe {
    param([string] $DatabaseName)
    # 两次 -c 共用一个 psql 会话；t/t 表示写者锁空闲。
    $output = (& $psql -h $DatabaseHost -p $DatabasePort -U $dbUser -d $DatabaseName -q -t -A -w -v 'ON_ERROR_STOP=1' `
        -c ('SELECT pg_try_advisory_lock(' + $writerLockKey + ')') `
        -c ('SELECT pg_advisory_unlock(' + $writerLockKey + ')') 2>&1)
    if ($LASTEXITCODE -ne 0) { throw ('advisory 锁探针失败：' + ($output -join ' | ')) }
    return (@($output | ForEach-Object { ([string] $_).Trim() } | Where-Object { $_ -ne '' }) -join '/')
}

function Add-Check {
    param([string] $Name, [bool] $Pass, [string] $Detail)
    $checks.Add([pscustomobject]@{ Name = $Name; Pass = $Pass; Detail = $Detail })
    $mark = if ($Pass) { 'PASS' } else { 'FAIL' }
    Write-Host ('  [{0}] {1}' -f $mark, $Name)
    Write-Host ('         {0}' -f $Detail)
}

function New-Payload {
    param([string] $Path, [int] $Size, [string] $Seed)
    $block = [System.Text.Encoding]::UTF8.GetBytes($Seed)
    $bytes = New-Object byte[] $Size
    $filled = 0
    while ($filled -lt $Size) {
        $take = [Math]::Min($block.Length, $Size - $filled)
        [Array]::Copy($block, 0, $bytes, $filled, $take)
        $filled += $take
    }
    [System.IO.File]::WriteAllBytes($Path, $bytes)
    return $Path
}

function Get-Sha256([string] $Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-BlobPath([string] $DataRoot, [string] $StorageKey) {
    return Join-Path $DataRoot $StorageKey.Replace('/', [char] 92)
}

function Start-ThrottledUpload {
    param([string] $Uri, [string] $FilePath, [string] $LogName, [string] $Rate)
    $status = Join-Path $outputRoot ($LogName + '.status.txt')
    $response = Join-Path $outputRoot ($LogName + '.response.json')
    $stderr = Join-Path $outputRoot ($LogName + '.err.log')
    $form = 'file=@' + $FilePath + ';type=application/octet-stream;filename=race-payload.bin'
    $arguments = @('--silent', '--show-error', '--noproxy', '*', '--max-time', '300', '--limit-rate', $Rate,
        '--output', $response, '--write-out', '%{http_code} %{time_total}', '--form', $form, $Uri)
    $process = Start-Process -FilePath $curlPath -ArgumentList (Quote-Arguments $arguments) -NoNewWindow -PassThru -RedirectStandardOutput $status -RedirectStandardError $stderr
    return [pscustomobject]@{ Process = $process; Status = $status; Response = $response; Stderr = $stderr }
}

function Install-CommitWindowTrigger {
    param([string] $DatabaseName, [int] $SleepSeconds)
    $ddl = 'CREATE OR REPLACE FUNCTION ' + $schema + '.cangshu_race_window_gate() RETURNS trigger LANGUAGE plpgsql AS $body$ BEGIN PERFORM pg_sleep(' + $SleepSeconds + '); RETURN COALESCE(NEW, OLD); END $body$;'
    $drop = 'DROP TRIGGER IF EXISTS cangshu_race_window ON ' + $schema + '.resource;'
    $create = 'CREATE TRIGGER cangshu_race_window AFTER INSERT ON ' + $schema + '.resource FOR EACH ROW EXECUTE FUNCTION ' + $schema + '.cangshu_race_window_gate();'
    $path = Join-Path $outputRoot 'fixture-commit-window.sql'
    Save-Text -Lines @($ddl, $drop, $create) -Path $path | Out-Null
    Invoke-PsqlFile -DatabaseName $DatabaseName -Path $path | Out-Null
    return $path
}

function Remove-FixtureObjects {
    param([string] $DatabaseName)
    $dropTrigger = 'DROP TRIGGER IF EXISTS cangshu_race_window ON ' + $schema + '.resource;'
    $dropFunction = 'DROP FUNCTION IF EXISTS ' + $schema + '.cangshu_race_window_gate();'
    $path = Join-Path $outputRoot 'fixture-teardown.sql'
    Save-Text -Lines @($dropTrigger, $dropFunction) -Path $path | Out-Null
    Invoke-PsqlFile -DatabaseName $DatabaseName -Path $path | Out-Null
}

function Wait-ForBlockedBackend {
    param([string] $DatabaseName, [int] $WaitSeconds)
    $sql = "SELECT count(*) FROM pg_stat_activity WHERE datname = '" + $DatabaseName + "' " +
           "AND pid <> pg_backend_pid() AND state = 'active' AND coalesce(wait_event, '') = 'PgSleep'"
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        $rows = @(Invoke-PsqlTuples -DatabaseName $DatabaseName -Command $sql)
        if ($rows.Count -gt 0 -and [int] $rows[0] -gt 0) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

function Stop-AllServeProcesses {
    foreach ($run in @($serveProcesses)) {
        if ($run.Process -and -not $run.Process.HasExited) { Stop-ProcessHard -Process $run.Process }
    }
}

function Invoke-Upload {
    param([string] $Uri, [string] $FilePath, [string] $LogName)
    $response = Join-Path $outputRoot ($LogName + '.response.json')
    $form = 'file=@' + $FilePath + ';type=application/octet-stream;filename=race.bin'
    $arguments = @('--silent', '--show-error', '--noproxy', '*', '--max-time', '90',
        '--output', $response, '--write-out', '%{http_code}', '--form', $form, $Uri)
    $status = (((& $curlPath @arguments 2>&1) | Out-String).Trim())
    return [pscustomobject]@{ Status = $status; Response = $response }
}

function Invoke-HttpStatus {
    param([string] $Method, [string] $Uri, [int] $TimeoutSeconds = 60)
    $body = Join-Path $outputRoot ('http-' + $Method + '.body')
    $arguments = @('--silent', '--show-error', '--noproxy', '*', '--max-time', $TimeoutSeconds,
        '--output', $body, '--write-out', '%{http_code}', '--request', $Method, $Uri)
    $status = (((& $curlPath @arguments 2>&1) | Out-String).Trim())
    return $status
}

function Get-JsonField {
    param([string] $Path, [string] $Name)
    $text = Get-LogText $Path
    if ($text -match ('"' + $Name + '"\s*:\s*"([^"]*)"')) { return $Matches[1] }
    return ''
}

function Get-ConfiguredDefault([string] $Key, [string] $Fallback) {
    $pattern = '(?m)^\s*' + [regex]::Escape($Key) + ':\s*\$\{CANGSHU_[A-Z_]+:([^}]+)\}'
    if ($script:applicationYaml -match $pattern) { return $Matches[1].Trim() }
    return $Fallback
}

# ── 前置检查 ────────────────────────────────────────────────────────────────────────────────
$protectedNames = @('postgres', 'template0', 'template1', 'cangshu', 'cangshu_test', 'cangshu_m1demo',
    'cangshu_u1demo', 'cangshu_u2demo', 'cangshu_u3demo', 'cangshu_task3', 'cangshu_task4',
    'cangshu_task4_bench', 'cangshu_task5')
$databaseNames = @($DatabaseNameC, $DatabaseNameA, $DatabaseNameB)
foreach ($databaseName in $databaseNames) {
    if ($databaseName -notmatch '^cangshu_task29race_[a-z0-9_]+$') {
        throw "拒绝执行：库名 '$databaseName' 不符合隔离库规则 ^cangshu_task29race_[a-z0-9_]+$（自建自删前缀）"
    }
    if ($protectedNames -contains $databaseName) { throw "拒绝执行：'$databaseName' 是受保护库（白名单外）" }
}
if (@(@($DatabaseNameC, $DatabaseNameA, $DatabaseNameB) | Select-Object -Unique).Count -ne 3) {
    throw '三个用例库名必须互不相同'
}
if (-not (Test-Path -LiteralPath $migrationDir)) { throw "找不到迁移脚本目录：$migrationDir" }
foreach ($tool in @($psql, $createdb, $dropdb)) {
    if (-not (Test-Path -LiteralPath $tool)) {
        throw "找不到 $tool ； 用 -PostgresBin 指定 PostgreSQL 17 bin 目录（当前：$postgresBinPath）"
    }
}
$javaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME')
if (-not $javaHome) { throw '未设置 JAVA_HOME（serve／CLI 需要 JDK 21+ 运行）' }
$javaPath = Join-Path $javaHome 'bin/java.exe'
if (-not (Test-Path -LiteralPath $javaPath)) { throw "找不到 java：$javaPath" }
$javaVersionLine = (& $javaPath -version 2>&1 | Select-Object -First 1) -join ''
$javaMajor = if ($javaVersionLine -match 'version "?(\d+)') { [int] $Matches[1] } else { 0 }
if ($javaMajor -lt 21) { throw "运行打包 jar 需要 JDK 21+，当前：$javaVersionLine" }
if (-not (Get-Command $curlPath -ErrorAction SilentlyContinue)) { throw "找不到 $curlPath" }
foreach ($port in @($ServerPort, $ProbeServerPort)) {
    if (Test-TcpListener -TargetHost $DatabaseHost -Port $port) {
        throw "端口 $port 已被占用：取证要求两个端口都空着，否则「门失败不监听」的探测不再可信"
    }
}

$script:applicationYaml = Get-Content -LiteralPath (Join-Path $repoRoot 'src/main/resources/application.yml') -Raw
$dbUser = [Environment]::GetEnvironmentVariable('CANGSHU_DB_USER')
if (-not $dbUser) { $dbUser = Get-ConfiguredDefault 'username' 'postgres' }
$dbPassword = [Environment]::GetEnvironmentVariable('CANGSHU_DB_PASSWORD')
if (-not $dbPassword) { $dbPassword = Get-ConfiguredDefault 'password' 'postgres' }

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
New-Item -ItemType Directory -Force -Path $mirrorRoot | Out-Null
$env:PGPASSWORD = $dbPassword
$env:CANGSHU_DB_USER = $dbUser
$env:CANGSHU_DB_PASSWORD = $dbPassword
$baseUrl = 'http://' + $serverEndpoint

if (-not (Test-Path -LiteralPath $jarPath)) {
    if ($SkipBuild) { throw "找不到打包 jar：$jarPath （-SkipBuild 下不会自行构建）" }
    Write-Host ('  产物缺失，先构建：mvn -B -DskipTests package（日志：' + (Join-Path $outputRoot 'package.log') + '）')
    & mvn -B -DskipTests package *> (Join-Path $outputRoot 'package.log')
    if ($LASTEXITCODE -ne 0) { throw ('构建失败，见 ' + (Join-Path $outputRoot 'package.log')) }
}

Write-Host '== P0-3③ 对账共锁与任务 29 重启竞态专项取证 =='
Write-Host "  隔离库：$DatabaseNameC / $DatabaseNameA / $DatabaseNameB  @ $endpoint    用户：$dbUser"
Write-Host "  输出目录：$outputRoot"
Write-Host "  镜像目录：$mirrorRoot"
Write-Host "  jar：$jarPath"
Write-Host ''

try {
    # ==========================================================================================
    # 用例 C：对账不隔离、不移动、不计数单写者门协议文件（持锁对账）
    # ==========================================================================================
    Write-Host '[1/3] 用例 C：持锁对账后门协议文件仍在原处（预置锁文件＋真孤儿）'
    try {
        $migrationCountC = Reset-IsolatedDatabase -DatabaseName $DatabaseNameC
        $dataRootC = Reset-DataRoot -Path $dataRootC
        Write-Host ('    隔离库 {0} 已重建（{1} 个迁移脚本）；数据根 {2}' -f $DatabaseNameC, $migrationCountC, $dataRootC)

        $lockFileC = Join-Path $dataRootC '.cangshu-writer.lock'
        $sentinelC = '任务29 单写者门协议标记：不是字节对象 ' + [Guid]::NewGuid().ToString()
        [System.IO.File]::WriteAllText($lockFileC, $sentinelC, (New-Object System.Text.UTF8Encoding($false)))
        $lockDigestBefore = Get-Sha256 $lockFileC
        $lockLengthBefore = (Get-Item -LiteralPath $lockFileC).Length
        $lockMtimeBefore = (Get-Item -LiteralPath $lockFileC).LastWriteTimeUtc.ToString('o')

        $orphanPayloadC = Join-Path $outputRoot 'case-c-orphan.payload'
        [System.IO.File]::WriteAllText($orphanPayloadC,
            ('任务29：与门锁文件同轮的真孤儿字节 ' + [Guid]::NewGuid().ToString()),
            (New-Object System.Text.UTF8Encoding($false)))
        $orphanDigestC = Get-Sha256 $orphanPayloadC
        $orphanKeyC = 'sha256/' + $orphanDigestC.Substring(0, 2) + '/' + $orphanDigestC.Substring(2, 2) + '/' + $orphanDigestC
        $orphanPathC = Get-BlobPath -DataRoot $dataRootC -StorageKey $orphanKeyC
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $orphanPathC) | Out-Null
        Copy-Item -LiteralPath $orphanPayloadC -Destination $orphanPathC
        Save-Text -Lines (Get-DataRootTree -DataRoot $dataRootC) -Path (Join-Path $outputRoot 'case-c-data-root-before.txt') | Out-Null

        $serveC = Start-ServeAndWait -DatabaseName $DatabaseNameC -DataRoot $dataRootC -ServerPort $ServerPort -LogName 'case-c-serve'
        $maintenanceLineC = (Get-LogLines -Path $serveC.Stdout -Pattern 'CANGSHU|job|maintenance|' | Select-Object -Last 1)
        $orphanFoundC = Get-SummaryField $maintenanceLineC 'orphanFound'
        $orphanQuarantinedC = Get-SummaryField $maintenanceLineC 'orphanQuarantined'
        # 门持有该文件的字节区锁：持锁期间外部进程读不了它的内容（这本身是「门在生效」的正向证据），
        # 因此持锁时只核对目录项元数据，字节摘要与长度留到停机放锁之后再核对一遍。
        $lockReadDetailC = ''
        try {
            $null = Get-Sha256 $lockFileC
            $lockReadDetailC = '持锁期间外部读取成功（本平台未拒绝）：digest 已当场核对'
        } catch {
            $lockReadDetailC = '持锁期间外部读取被拒（ERROR_SHARING_VIOLATION＝门确实持有字节区锁）'
        }
        $lockHeldMetaOkC = $false
        $lockHeldMetaDetailC = ''
        try {
            $lockItemC = Get-Item -LiteralPath $lockFileC -Force
            $lockLengthHeldC = $lockItemC.Length
            $lockMtimeHeldC = $lockItemC.LastWriteTimeUtc.ToString('o')
            $lockHeldMetaOkC = ($lockLengthHeldC -eq $lockLengthBefore) -and ($lockMtimeHeldC -eq $lockMtimeBefore)
            $lockHeldMetaDetailC = '持锁期目录项 len=' + $lockLengthHeldC + ' mtime=' + $lockMtimeHeldC
        } catch {
            $lockHeldMetaDetailC = '持锁期读取目录项失败：' + $_.Exception.Message
        }
        $quarantinedLockC = Join-Path $dataRootC 'orphan\.cangshu-writer.lock'
        $quarantinedOrphanC = Get-BlobPath -DataRoot $dataRootC -StorageKey ('orphan/' + $orphanKeyC)
        Save-Text -Lines (Get-DataRootTree -DataRoot $dataRootC) -Path (Join-Path $outputRoot 'case-c-data-root-after.txt') | Out-Null

        $exitC = -99
        try { $exitC = Stop-ServeGracefully -Process $serveC.Process -ServerEndpoint $serverEndpoint } catch {
            $exitC = -1
            Stop-ProcessHard -Process $serveC.Process
        }
        # 停机（放锁）后核对字节摘要：与启动前逐字节一致＝对账一根字节也没动过
        $lockDigestAfter = Get-Sha256 $lockFileC
        $lockLengthAfter = (Get-Item -LiteralPath $lockFileC -Force).Length

        Add-Check -Name '用例 C：启动对账在持有门的状态下跑完并隔离了真孤儿' -Pass `
            (($orphanFoundC -eq '1') -and ($orphanQuarantinedC -eq '1') -and (Test-Path -LiteralPath $quarantinedOrphanC)) `
            -Detail ($maintenanceLineC + ' ／ 隔离目标 orphan/' + $orphanKeyC.Substring(7, 8) + '… 已存在')
        Add-Check -Name '用例 C：门协议文件仍在原路径' -Pass (Test-Path -LiteralPath $lockFileC) -Detail $lockFileC
        Add-Check -Name '用例 C：门协议文件字节／长度／修改时间未变（未被移动、改写、重建）' -Pass `
            ($lockHeldMetaOkC -and ($lockDigestBefore -eq $lockDigestAfter) -and ($lockLengthBefore -eq $lockLengthAfter)) `
            -Detail ($lockHeldMetaDetailC + ' ／ 停机后 sha256 ' + $lockDigestBefore.Substring(0, 16) + '… → ' + $lockDigestAfter.Substring(0, 16) + '… ／ len ' + $lockLengthBefore + ' → ' + $lockLengthAfter + ' ／ ' + $lockReadDetailC)
        Add-Check -Name '用例 C：门协议文件未被隔离到 orphan/（也没被当作孤儿计数）' -Pass `
            (-not (Test-Path -LiteralPath $quarantinedLockC)) `
            -Detail ('orphan/.cangshu-writer.lock 不存在；orphanFound=' + $orphanFoundC + '（只计真孤儿）')
        Add-Check -Name '用例 C：serve 优雅停机退出码 0' -Pass ($exitC -eq 0) -Detail ('exit=' + $exitC)
    } catch {
        Add-Check -Name '用例 C：执行异常' -Pass $false -Detail $_.Exception.Message
        Stop-AllServeProcesses
    }

    # ==========================================================================================
    # 用例 A：门专用会话断开后是否停写（A2 如实记录 ＋ A1 第二写者仍被拒 ＋ 重启恢复）
    # ==========================================================================================
    Write-Host '[2/3] 用例 A：门专用会话断开后是否停写'
    Stop-AllServeProcesses
    try {
        $migrationCountA = Reset-IsolatedDatabase -DatabaseName $DatabaseNameA
        $dataRootA = Reset-DataRoot -Path $dataRootA
        Write-Host ('    隔离库 {0} 已重建（{1} 个迁移脚本）；数据根 {2}' -f $DatabaseNameA, $migrationCountA, $dataRootA)

        $serveA = Start-ServeAndWait -DatabaseName $DatabaseNameA -DataRoot $dataRootA -ServerPort $ServerPort -LogName 'case-a-serve'
        $gateAcquiredA = (Get-LogLines -Path $serveA.Stdout -Pattern 'CANGSHU|writer-gate|acquired' | Select-Object -Last 1)

        $payloadA0 = New-Payload -Path (Join-Path $outputRoot 'case-a-baseline.bin') -Size 4096 -Seed 'task29-race-baseline-upload-payload '
        $baselineA = Invoke-Upload -Uri ($baseUrl + '/api/resources') -FilePath $payloadA0 -LogName 'case-a-baseline-upload'
        $baselineIdA = Get-JsonField -Path $baselineA.Response -Name 'id'
        Add-Check -Name '用例 A：断门之前正常上传 201（基线）' -Pass ($baselineA.Status -eq '201') -Detail ('HTTP ' + $baselineA.Status + ' ；resourceId=' + $baselineIdA)

        $evidenceBeforeA = Save-BlockEvidence -Label 'a-before-terminate-gate-session' -DatabaseName $DatabaseNameA `
            -ExtraNote ('断开门专用会话之前：业务连接池与门专用会话并存，门会话持有 advisory 锁 ' + $writerLockKey)
        $gatePidA = Get-GateSessionPid -DatabaseName $DatabaseNameA
        if ($gatePidA -le 0) { throw '在 pg_locks 里找不到持有写者 advisory 锁的门专用会话（用例 A 前提不成立）' }
        $sessionRowA = (Invoke-PsqlQuery -DatabaseName $DatabaseNameA -Command (
            'SELECT pid, backend_type, state, coalesce(wait_event, ''-'') AS wait_event, left(replace(query, chr(10), '' ''), 70) AS query FROM pg_stat_activity WHERE pid = ' + $gatePidA))
        $terminateA = (Invoke-PsqlTuples -DatabaseName $DatabaseNameA -Command ('SELECT pg_terminate_backend(' + $gatePidA + ')')) -join ''
        Wait-ForCondition -Condition { (Get-GateSessionPid -DatabaseName $DatabaseNameA) -eq 0 } -WaitSeconds 30 `
            -Description '门专用会话已断开（该库 advisory 写者锁从 pg_locks 消失）'
        $probeAfterA = Get-AdvisoryLockProbe -DatabaseName $DatabaseNameA
        $evidenceAfterA = Save-BlockEvidence -Label 'a-after-terminate-gate-session' -DatabaseName $DatabaseNameA `
            -ExtraNote '门专用会话已断开：写者 advisory 锁消失，数据根文件锁仍被旧进程持有'

        # A2：门会话断开后，本进程还能不能写（如实记录，不作为通过/失败判据）
        $countsBeforeA2 = Get-DatabaseCounts -DatabaseName $DatabaseNameA
        $payloadA2 = New-Payload -Path (Join-Path $outputRoot 'case-a-after-terminate.bin') -Size 4096 -Seed 'task29-race-after-gate-session-terminated '
        $afterTerminateA = Invoke-Upload -Uri ($baseUrl + '/api/resources') -FilePath $payloadA2 -LogName 'case-a-upload-after-terminate'
        $countsAfterA2 = Get-DatabaseCounts -DatabaseName $DatabaseNameA
        $deleteA2 = Invoke-HttpStatus -Method 'DELETE' -Uri ($baseUrl + '/api/resources/' + $baselineIdA)
        $gateDeniedLinesA = @(Get-LogLines -Path $serveA.Stdout -Pattern 'CANGSHU|writer-gate|denied')
        $blobCountAfterA2 = @(Get-ChildItem -LiteralPath $dataRootA -Recurse -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '.cangshu-writer.lock' }).Count

        # A1：同数据根的第二写者必须仍被拒（数据根文件锁独立生效）
        $secondA = Start-ServeProcess -DatabaseName $DatabaseNameA -DataRoot $dataRootA -ServerPort $ProbeServerPort -LogName 'case-a-second-writer'
        $serveProcesses.Add($secondA)
        $listenerHitsA = 0
        $deadlineA = (Get-Date).AddSeconds($TimeoutSeconds)
        while (-not $secondA.Process.HasExited -and (Get-Date) -lt $deadlineA) {
            if (Test-TcpListener -TargetHost $DatabaseHost -Port $ProbeServerPort) { $listenerHitsA++ }
            Start-Sleep -Milliseconds 150
        }
        if (-not $secondA.Process.HasExited) {
            Stop-ProcessHard -Process $secondA.Process
            throw '同数据根的第二写者没有在超时内退出（门失败必须停写并退出）'
        }
        $secondExitA = $secondA.Process.ExitCode
        $deniedA = Get-LogLine -Path $secondA.Stdout -Pattern 'CANGSHU|writer-gate|denied|reason=data-root-file-lock'
        $deniedAText = if ($deniedA) { $deniedA.Line.Trim() } else { '未出现 reason=data-root-file-lock' }

        # 重启恢复：杀旧进程 → 新门可取得 → 正常上传
        Stop-ProcessHard -Process $serveA.Process
        Wait-ForCondition -Condition { ((Invoke-PsqlTuples -DatabaseName $DatabaseNameA -Command (
            'SELECT count(*) FROM pg_stat_activity WHERE datname = ''' + $DatabaseNameA + ''' AND pid <> pg_backend_pid()')) -join '') -eq '0' } `
            -WaitSeconds 60 -Description '旧进程的数据库会话全部结束（旧 session 已清）'
        $serveA2 = Start-ServeAndWait -DatabaseName $DatabaseNameA -DataRoot $dataRootA -ServerPort $ServerPort -LogName 'case-a-serve-restart'
        $payloadA3 = New-Payload -Path (Join-Path $outputRoot 'case-a-after-restart.bin') -Size 4096 -Seed 'task29-race-after-restart-upload '
        $afterRestartA = Invoke-Upload -Uri ($baseUrl + '/api/resources') -FilePath $payloadA3 -LogName 'case-a-upload-after-restart'
        $exitA2 = -99
        try { $exitA2 = Stop-ServeGracefully -Process $serveA2.Process -ServerEndpoint $serverEndpoint } catch {
            $exitA2 = -1
            Stop-ProcessHard -Process $serveA2.Process
        }

        Add-Check -Name '用例 A1：同数据根的第二写者仍被拒（退出码 2、数据根文件锁）' -Pass `
            (($secondExitA -eq 2) -and ($null -ne $deniedA) -and ($listenerHitsA -eq 0)) `
            -Detail ('exit=' + $secondExitA + ' ／ ' + $deniedAText + ' ／ 端口监听次数=' + $listenerHitsA)
        Add-Check -Name '用例 A：断门后写者 advisory 锁确实消失（DB 侧门已断）' -Pass ($probeAfterA -eq 't/t') `
            -Detail ('terminate_backend(' + $gatePidA + ')=' + $terminateA + ' ／ pg_try_advisory_lock(' + $writerLockKey + ')=' + $probeAfterA + ' ／ 门会话行：' + ($sessionRowA -join ' | '))
        Add-Check -Name '用例 A：重启后新门可取得且上传成功（恢复路径不是永久锁死）' -Pass (($afterRestartA.Status -eq '201') -and ($exitA2 -eq 0)) `
            -Detail ('重启后上传 HTTP ' + $afterRestartA.Status + ' ／ 优雅停机 exit=' + $exitA2 + ' ／ ' + $gateAcquiredA)

        $gapLines = @()
        $gapLines += '# 用例 A 结论：门专用会话断开后的写入行为（如实记录，不作为脚本通过/失败判据）'
        $gapLines += '时间（UTC）：' + (Get-Date).ToUniversalTime().ToString('o')
        $gapLines += '门专用会话 backend PID：' + $gatePidA + '（pg_terminate_backend ⇒ ' + $terminateA + '）'
        $gapLines += '断开后写者 advisory 锁探针：' + $probeAfterA + '（t/t ＝ 该库写者锁已空闲）'
        $gapLines += '断开后 HTTP 上传：' + $afterTerminateA.Status + '（+1 资源行＝下面计数；观察值以本行与计数为准）'
        $gapLines += '断开后 HTTP 删除：' + $deleteA2
        $gapLines += '库计数 断门前后：' + $countsBeforeA2 + '  →  ' + $countsAfterA2
        $gapLines += '数据根里字节文件数（除协议锁文件；断门后）：' + $blobCountAfterA2
        $gapLines += 'serve 日志中 writer-gate|denied 行数（断门后）：' + $gateDeniedLinesA.Count
        $gapLines += '同数据根第二写者退出码：' + $secondExitA + '（' + $deniedAText + '）'
        $gapLines += ''
        $gapLines += '判定：WriterGate 只在启动取门、运行期无失锁监测。门专用会话被外部断开后，'
        $gapLines += '      本进程仍在写（上传/删除照常返回成功、库里新增行、盘上新增字节），即「未停写」；'
        $gapLines += '      数据根文件锁仍由旧进程持有，因此同数据根的第二写者依旧被拒（退出码 2）。'
        $gapLines += '      缺口＝「失锁即停写」的运行时检测尚未实现；需 GPT-6/用户裁决检测方式（不在本项范围）。'
        Save-Text -Lines $gapLines -Path (Join-Path $outputRoot 'case-a-conclusion.txt') | Out-Null
        Add-Check -Name '用例 A2（如实记录）：门会话断开后本进程是否停写' -Pass $true `
            -Detail ('未停写：上传 HTTP ' + $afterTerminateA.Status + '、删除 HTTP ' + $deleteA2 + '、库计数 ' + $countsBeforeA2 + ' → ' + $countsAfterA2 + '（缺口见 case-a-conclusion.txt，需裁决）')
    } catch {
        Add-Check -Name '用例 A：执行异常' -Pass $false -Detail $_.Exception.Message
        Stop-AllServeProcesses
    }

    # ==========================================================================================
    # 用例 B：旧业务 COMMIT 未结束时重启对账
    # ==========================================================================================
    Write-Host '[3/3] 用例 B：旧业务 COMMIT 未结束时重启对账'
    Stop-AllServeProcesses
    $uploadB = $null
    try {
        $migrationCountB = Reset-IsolatedDatabase -DatabaseName $DatabaseNameB
        $dataRootB = Reset-DataRoot -Path $dataRootB
        $fixturePathB = Install-CommitWindowTrigger -DatabaseName $DatabaseNameB -SleepSeconds $CommitWindowSeconds
        Write-Host ('    隔离库 {0} 已重建（{1} 个迁移脚本）；夹具 {2}（resource 插入后 pg_sleep({3})）' -f $DatabaseNameB, $migrationCountB, $fixturePathB, $CommitWindowSeconds)

        $serveB = Start-ServeAndWait -DatabaseName $DatabaseNameB -DataRoot $dataRootB -ServerPort $ServerPort -LogName 'case-b-serve'
        $payloadB = New-Payload -Path (Join-Path $outputRoot 'case-b-payload.bin') -Size $ThrottleBytes -Seed 'cangshu-task29-race-throttled-upload '
        $payloadShaB = Get-Sha256 $payloadB
        $keyB = 'sha256/' + $payloadShaB.Substring(0, 2) + '/' + $payloadShaB.Substring(2, 2) + '/' + $payloadShaB
        $blobB = Get-BlobPath -DataRoot $dataRootB -StorageKey $keyB
        $orphanBlobB = Get-BlobPath -DataRoot $dataRootB -StorageKey ('orphan/' + $keyB)
        $uploadB = Start-ThrottledUpload -Uri ($baseUrl + '/api/resources') -FilePath $payloadB -LogName 'case-b-upload' -Rate $ThrottleRate

        # B1：节流上传进行中（curl 仍在跑）——同时跑对账 CLI；用「CLI 结束时 curl 还没退」证明确实重叠。
        # 注：multipart 体在容器侧落盘、应用侧只做一次本地搬移，所以应用侧 tmp/ 窗口极短，不能作为节流窗口的判据。
        Start-Sleep -Milliseconds 800
        Save-Text -Lines (Get-DataRootTree -DataRoot $dataRootB) -Path (Join-Path $outputRoot 'case-b-data-root-upload-in-flight.txt') | Out-Null
        $cliB1Started = Get-Date
        $cliB1 = Invoke-CliRun -DatabaseName $DatabaseNameB -DataRoot $dataRootB -LogName 'case-b-cli-during-streaming'
        $cliB1Seconds = [Math]::Round(((Get-Date) - $cliB1Started).TotalSeconds, 1)
        $uploadInFlightAtCliEndB1 = -not $uploadB.Process.HasExited
        $deniedB1 = Get-LogLine -Path $cliB1.Stdout -Pattern 'CANGSHU|writer-gate|denied'
        $deniedB1Text = if ($deniedB1) { $deniedB1.Line.Trim() } else { '无门拒绝日志' }

        # B2：阻塞点（已 moveInto、位置行未提交）
        Wait-ForCondition -Condition {
            (Test-Path -LiteralPath $blobB) -and
            (((Invoke-PsqlTuples -DatabaseName $DatabaseNameB -Command ('SELECT count(*) FROM ' + $schema + '.content')) -join '') -eq '0')
        } -WaitSeconds 120 -Description '上传已 moveInto（正式键上有字节）而内容行尚未提交'
        $blockedB = Wait-ForBlockedBackend -DatabaseName $DatabaseNameB -WaitSeconds 30
        $countsAtBlockB = Get-DatabaseCounts -DatabaseName $DatabaseNameB
        $evidenceB1 = Save-BlockEvidence -Label 'b-1-upload-blocked-before-commit' -DatabaseName $DatabaseNameB `
            -ExtraNote '真实上传已完成 moveInto（正式键上有字节）；业务事务停在 resource 插入后的 pg_sleep 窗口，未 COMMIT（库计数对其余会话不可见）'
        Save-Text -Lines (Get-DataRootTree -DataRoot $dataRootB) -Path (Join-Path $outputRoot 'case-b-data-root-blocked.txt') | Out-Null

        # 模拟门专用会话释放 → 未提交窗口内跑对账 CLI
        $gatePidB = Get-GateSessionPid -DatabaseName $DatabaseNameB
        $terminateB = (Invoke-PsqlTuples -DatabaseName $DatabaseNameB -Command ('SELECT pg_terminate_backend(' + $gatePidB + ')')) -join ''
        Wait-ForCondition -Condition { (Get-GateSessionPid -DatabaseName $DatabaseNameB) -eq 0 } -WaitSeconds 30 `
            -Description '门专用会话已断开（模拟重启窗口）'
        $probeAfterB = Get-AdvisoryLockProbe -DatabaseName $DatabaseNameB
        $cliB2 = Invoke-CliRun -DatabaseName $DatabaseNameB -DataRoot $dataRootB -LogName 'case-b-cli-during-uncommitted-window'
        $deniedB2 = Get-LogLine -Path $cliB2.Stdout -Pattern 'CANGSHU|writer-gate|denied|reason=data-root-file-lock'
        $deniedB2Text = if ($deniedB2) { $deniedB2.Line.Trim() } else { '无数据根文件锁拒绝日志' }
        $blobStillB = Test-Path -LiteralPath $blobB
        $orphanCopyB = Test-Path -LiteralPath $orphanBlobB
        Save-Text -Lines (Get-DataRootTree -DataRoot $dataRootB) -Path (Join-Path $outputRoot 'case-b-data-root-after-cli-denied.txt') | Out-Null

        # B3：等上传提交（触发器窗口结束即 COMMIT）
        $uploadFinishedB = $uploadB.Process.WaitForExit(($CommitWindowSeconds + 180) * 1000)
        $statusB = (Get-LogText $uploadB.Status).Trim()
        $statusFieldsB = @($statusB -split '\s+')
        $httpStatusB = if ($statusFieldsB.Count -ge 1) { $statusFieldsB[0] } else { '' }
        $uploadSecondsB = if ($statusFieldsB.Count -ge 2) { $statusFieldsB[1] } else { '未知' }
        $uploadErrorsB = Get-LogText $uploadB.Stderr
        $contentStatusB = (Invoke-PsqlTuples -DatabaseName $DatabaseNameB -Command ('SELECT status FROM ' + $schema + '.content')) -join ''
        $locationRowsB = (Invoke-PsqlTuples -DatabaseName $DatabaseNameB -Command ('SELECT count(*) FROM ' + $schema + '.location')) -join ''
        $blobShaB = if (Test-Path -LiteralPath $blobB) { Get-Sha256 $blobB } else { '(缺失)' }

        # B4：停服 ＋ 拆夹具 ＋ 提交后再对账（最终一致性）
        $exitB = -99
        try { $exitB = Stop-ServeGracefully -Process $serveB.Process -ServerEndpoint $serverEndpoint } catch {
            $exitB = -1
            Stop-ProcessHard -Process $serveB.Process
        }
        Remove-FixtureObjects -DatabaseName $DatabaseNameB
        $cliB4 = Invoke-CliRun -DatabaseName $DatabaseNameB -DataRoot $dataRootB -LogName 'case-b-cli-after-commit'
        $summaryB4 = Get-CliSummaryLine -Stdout $cliB4.Stdout
        $blobStillB4 = Test-Path -LiteralPath $blobB

        Add-Check -Name '用例 B1：节流上传进行中跑对账 CLI → 被写者门拒绝（两边确实重叠）' -Pass `
            (($cliB1.ExitCode -eq 2) -and ($null -ne $deniedB1) -and $uploadInFlightAtCliEndB1) `
            -Detail ('对账 CLI exit=' + $cliB1.ExitCode + '（耗时 ' + $cliB1Seconds + 's）／ ' + $deniedB1Text + ' ／ CLI 结束时上传仍在飞行=' + $uploadInFlightAtCliEndB1 + ' ／ 节流参数=payload ' + $ThrottleBytes + 'B @ ' + $ThrottleRate)
        Add-Check -Name '用例 B2：未提交窗口内对账 CLI 被数据根文件锁拒绝、正式字节未被隔离' -Pass `
            (($cliB2.ExitCode -eq 2) -and ($null -ne $deniedB2) -and ($probeAfterB -eq 't/t') -and $blobStillB -and (-not $orphanCopyB)) `
            -Detail ('对账 CLI exit=' + $cliB2.ExitCode + ' ／ ' + $deniedB2Text + ' ／ 写者锁探针=' + $probeAfterB + ' ／ 正式键字节仍在=' + $blobStillB + ' ／ orphan 副本=' + $orphanCopyB)
        Add-Check -Name '用例 B2：阻塞点证据已留存（pg_stat_activity／pg_locks 原文＋库计数＋文件快照）' -Pass `
            ($blockedB -and ($countsAtBlockB -match 'content=0') -and ((Get-LogText $evidenceB1.Path) -match 'PgSleep')) `
            -Detail ('阻塞后端 wait_event=PgSleep 已观测=' + $blockedB + ' ／ 阻塞点库计数（锁外可见）=' + $countsAtBlockB + ' ／ 证据=' + $evidenceB1.Path)
        Add-Check -Name '用例 B3：上传提交后内容 READY、位置行 1、字节摘要与内容身份一致' -Pass `
            (($httpStatusB -eq '201') -and ($contentStatusB -eq 'READY') -and ($locationRowsB -eq '1') -and ($blobShaB -eq $payloadShaB) -and (-not (Test-Path -LiteralPath $orphanBlobB))) `
            -Detail ('HTTP ' + $httpStatusB + ' ／ 上传耗时 ' + $uploadSecondsB + 's（节流拉长窗口）／ content=' + $contentStatusB + ' ／ location=' + $locationRowsB + ' ／ 字节摘要一致=' + ($blobShaB -eq $payloadShaB) + ' ／ orphan 无该键=' + (-not (Test-Path -LiteralPath $orphanBlobB)) + ' ／ serve 停机 exit=' + $exitB + ' ／ curl stderr=' + $uploadErrorsB.Trim())
        Add-Check -Name '用例 B4：提交后再对账收敛（退出码 0、无孤儿、无缺失字节）' -Pass `
            (($cliB4.ExitCode -eq 0) -and ((Get-SummaryField $summaryB4 'orphanFound') -eq '0') -and ((Get-SummaryField $summaryB4 'bytesMissing') -eq '0') -and ((Get-SummaryField $summaryB4 'needsAttention') -eq 'false') -and $blobStillB4) `
            -Detail ('对账 CLI exit=' + $cliB4.ExitCode + ' ／ ' + $summaryB4 + ' ／ 字节仍在=' + $blobStillB4)
    } catch {
        Add-Check -Name '用例 B：执行异常' -Pass $false -Detail $_.Exception.Message
        Stop-AllServeProcesses
        if ($uploadB -and -not $uploadB.Process.HasExited) { Stop-ProcessHard -Process $uploadB.Process }
    }
} finally {
    Stop-AllServeProcesses
    if ($uploadB -and -not $uploadB.Process.HasExited) { Stop-ProcessHard -Process $uploadB.Process }
    if ($KeepDatabase) {
        Write-Host ('  保留隔离库（-KeepDatabase）：' + ($databaseNames -join ' / '))
    } else {
        foreach ($databaseName in $databaseNames) {
            & $dropdb -h $DatabaseHost -p $DatabasePort -U $dbUser --if-exists $databaseName 2>&1 | Out-Null
        }
        Write-Host ('  已删除隔离库：' + ($databaseNames -join ' / '))
    }
}

# ── 残留检查 ＋ 结果汇总 ＋ 镜像 ─────────────────────────────────────────────────────────────
# 注意：环境变量清理必须放在最后——后面的残留检查还要用 PGPASSWORD 跑 psql，
# 提前清掉会让 psql 停在密码提示上（无终端输入＝挂住）。
$residualDatabases = @(Invoke-PsqlTuples -DatabaseName 'postgres' -Command "SELECT datname FROM pg_database WHERE datname LIKE 'cangshu%' ORDER BY 1")
$residualRaceDatabases = @($residualDatabases | Where-Object { $_ -like 'cangshu_task29race_*' })
$portServerListening = Test-TcpListener -TargetHost $DatabaseHost -Port $ServerPort
$portProbeListening = Test-TcpListener -TargetHost $DatabaseHost -Port $ProbeServerPort
$residualRaceText = if ($residualRaceDatabases.Count -eq 0) { '无' } else { $residualRaceDatabases -join ',' }
Add-Check -Name '残留：无 cangshu_task29race_* 库、两个端口无监听' -Pass `
    (((-not $KeepDatabase) -and $residualRaceDatabases.Count -eq 0) -and (-not $portServerListening) -and (-not $portProbeListening)) `
    -Detail ('残留隔离库=' + $residualRaceText + ' ／ 端口 ' + $ServerPort + ' 监听=' + $portServerListening + ' ／ 端口 ' + $ProbeServerPort + ' 监听=' + $portProbeListening + ' ／ psql -lqt(cangshu%)=' + ($residualDatabases -join ','))

$failed = @($checks | Where-Object { -not $_.Pass })
$summaryLines = @()
$summaryLines += '# P0-3③ 对账共锁与任务 29 重启竞态专项取证：scripts/verify-task29-races.ps1'
$summaryLines += '时间（UTC）：' + (Get-Date).ToUniversalTime().ToString('o')
$summaryLines += '仓（提交）：' + ((& git -C $repoRoot rev-parse HEAD) -join '')
$summaryLines += '隔离库：' + $DatabaseNameC + ' / ' + $DatabaseNameA + ' / ' + $DatabaseNameB + ' @ ' + $endpoint
$summaryLines += '输出目录：' + $outputRoot
$summaryLines += '镜像目录：' + $mirrorRoot
$summaryLines += ''
foreach ($check in $checks) {
    $mark = if ($check.Pass) { 'PASS' } else { 'FAIL' }
    $summaryLines += ('[' + $mark + '] ' + $check.Name)
    $summaryLines += ('    ' + $check.Detail)
}
$summaryLines += ''
$summaryLines += ('合计：通过 ' + ($checks.Count - $failed.Count) + ' / 共 ' + $checks.Count)
$summaryPath = Save-Text -Lines $summaryLines -Path (Join-Path $outputRoot 'verify-task29-races-summary.txt')

Write-Host ''
Write-Host '== 结果 =='
foreach ($check in $checks) {
    $mark = if ($check.Pass) { 'PASS' } else { 'FAIL' }
    Write-Host ('  [{0}] {1}' -f $mark, $check.Name)
    Write-Host ('         {0}' -f $check.Detail)
}
Write-Host ''
Write-Host ('  通过 {0} / 共 {1}；证据目录 {2}；镜像 {3}' -f ($checks.Count - $failed.Count), $checks.Count, $outputRoot, $mirrorRoot)

Copy-Item -Path (Join-Path $outputRoot '*') -Destination $mirrorRoot -Recurse -Force
Write-Host ('  已镜像到：' + $mirrorRoot)

Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
Remove-Item Env:CANGSHU_DB_USER -ErrorAction SilentlyContinue
Remove-Item Env:CANGSHU_DB_PASSWORD -ErrorAction SilentlyContinue

if ($failed.Count -gt 0) {
    Write-Host ''
    Write-Host ('取证未通过：' + $failed.Count + ' 项不符合期望（见上方日志）')
    exit 1
}
Write-Host ''
Write-Host '取证通过：门协议文件未被对账触碰／未被计数，用例 A 的第二写者与用例 B 的对账 CLI 均被写者门拒绝且未动字节，用例 B 提交后收敛。'
exit 0
