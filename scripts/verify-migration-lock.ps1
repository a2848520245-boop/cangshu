<#
.SYNOPSIS
    人工迁移锁协议取证：隔离库上复现「正常迁移／并发第二次迁移被拒／写者持锁被拒／失败回滚」＋交付态包装脚本冒烟。

.DESCRIPTION
    全部在自建自删的隔离库上操作（默认 cangshu_miglock_verify_a / cangshu_miglock_verify_b），
    绝不触碰 cangshu / cangshu_test / cangshu_m1demo；**不依赖 Docker**（用本机 PostgreSQL 17 客户端跑 scripts/migrate.sh）。

    锁协议（07-运行手册 §1 登记值／§4／§7；ADR-0001 §四 ^dec-t2、§七 ^dec-t3）：
      迁移锁键 20260918、写者锁键 20260919；两把都是非阻塞取锁，取不到即拒绝且**不写任何字节**、退出码 2。

    用例：
      ① 正常迁移（库 A）：scripts/migrate.sh → 退出码 0；日志体现取锁（lock-acquired）先于第一个脚本、释放齐全
         （lock-released ＋ migration_lock_released=true）；结构与台账正确（V1／V2 摘要与宿主文件一致）；运行后无残留咨询锁。
      ② 并发第二次迁移（库 B）：#1 用副本目录（V1／V2 ＋ V9 慢脚本）真实迁移并持锁，期间 #2 迁移被拒 → 退出码 2、
         原文 reason=migration-lock、台账未被改动、被拒时 #1 仍在跑；#1 正常结束（退出码 0）且锁已释放。
      ③ 写者持锁（库 B，先重建为空库）：一个持有写者锁 20260919 的会话（等价于 serve 的 WriterGate）在跑时迁移
         → 退出码 2、原文 reason=writer-lock 并给出「停掉 serve 实例」指引；拒绝路径连 cangshu_m1 schema 都没建；
         会话结束后写者锁释放。
      ④ 失败回滚（库 A，重建为空库）：副本目录 V1／V2 ＋ V9 失败脚本（建表＋记账后故意 RAISE）→ 退出码 1；
         台账无 V9 行、探针表不存在（失败脚本整体回滚，V1／V2 保持已提交）；两把锁都已释放且能再次取得。
      ⑤ 交付态包装脚本冒烟（库 A，重建为空库）：scripts/compose-migrate.sh 用 CANGSHU_MIGRATE_PSQL 替换传输（本机 psql）
         → 退出码 0、协议标记与台账一致。**容器内 psql（docker compose exec）本身未执行**：本机 Docker 引擎未运行。

    凭据取自 src/main/resources/application.yml 的既有默认值，可被 CANGSHU_DB_USER / CANGSHU_DB_PASSWORD 覆盖；
    密码只经环境变量传给子进程，不打印、不进命令行。

    前置：本机 PostgreSQL 17（127.0.0.1:5432）＋ PostgreSQL 17 客户端（默认 E:\PostgreSQL\17\bin）；
    Git Bash（默认 C:\Program Files\Git\bin\bash.exe —— scripts/*.sh 需要 bash ＋ sha256sum）。

.EXAMPLE
    pwsh -File scripts/verify-migration-lock.ps1

.EXAMPLE
    pwsh -File scripts/verify-migration-lock.ps1 -KeepDatabase -OutputDirectory D:\miglock-evidence
#>
[CmdletBinding()]
param(
    [string] $PrimaryDatabaseName = 'cangshu_miglock_verify_a',
    [string] $SecondaryDatabaseName = 'cangshu_miglock_verify_b',
    [string] $DatabaseHost = '127.0.0.1',
    [int] $DatabasePort = 5432,
    [string] $OutputDirectory = 'target/migration-lock-evidence',
    [string] $PostgresBin = 'E:\PostgreSQL\17\bin',
    [string] $BashPath = 'C:\Program Files\Git\bin\bash.exe',
    [int] $SlowScriptSeconds = 15,
    [int] $HolderSeconds = 40,
    [int] $TimeoutSeconds = 180,
    [switch] $KeepDatabase
)

$ErrorActionPreference = 'Stop'
# PowerShell 7.3+ 会把原生命令的 stderr 当成错误；本脚本按退出码与文本判定，显式关掉该行为。
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}
# 原生输出（bash／psql）里有中文，按 UTF-8 解码，中文断言才成立。
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
function Resolve-From([string] $Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}
# bash（Git Bash）要 POSIX 路径：E:\a\b → /e/a/b
function ConvertTo-PosixPath([string] $Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    $drive = $full.Substring(0, 1).ToLowerInvariant()
    return '/' + $drive + ($full.Substring(2).Replace('\', '/'))
}

$migrationDir = Join-Path $repoRoot 'db/migration'
$migrateScript = Join-Path $repoRoot 'scripts/migrate.sh'
$composeMigrateScript = Join-Path $repoRoot 'scripts/compose-migrate.sh'
$outputRoot = Resolve-From $OutputDirectory
$postgresBinPath = Resolve-From $PostgresBin
$psql = Join-Path $postgresBinPath 'psql.exe'
$createdb = Join-Path $postgresBinPath 'createdb.exe'
$dropdb = Join-Path $postgresBinPath 'dropdb.exe'
$bashExe = (Resolve-Path -LiteralPath $BashPath).Path
$migrateScriptPosix = ConvertTo-PosixPath $migrateScript
$composeMigrateScriptPosix = ConvertTo-PosixPath $composeMigrateScript
$psqlPosix = ConvertTo-PosixPath $psql
$endpoint = $DatabaseHost + ':' + $DatabasePort

# ── 前置检查 ────────────────────────────────────────────────────────────────────────────────
foreach ($databaseName in @($PrimaryDatabaseName, $SecondaryDatabaseName)) {
    if ($databaseName -notmatch '^cangshu_miglock_verify_[A-Za-z0-9_]+$') {
        throw "拒绝执行：库名 '$databaseName' 不符合隔离库规则 ^cangshu_miglock_verify_[A-Za-z0-9_]+$（不得指向 cangshu / cangshu_test / cangshu_m1demo）"
    }
}
if ($PrimaryDatabaseName -eq $SecondaryDatabaseName) { throw '两个隔离库名必须不同' }
if (-not (Test-Path -LiteralPath $migrationDir)) { throw "找不到迁移脚本目录：$migrationDir" }
foreach ($tool in @($psql, $createdb, $dropdb)) {
    if (-not (Test-Path -LiteralPath $tool)) {
        throw "找不到 $tool ； 用 -PostgresBin 指定 PostgreSQL 17 bin 目录（当前：$postgresBinPath）"
    }
}
foreach ($script in @($migrateScript, $composeMigrateScript)) {
    if (-not (Test-Path -LiteralPath $script)) { throw "找不到迁移脚本：$script" }
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
$env:PGPASSWORD = $dbPassword
$env:CANGSHU_DB_PASSWORD = $dbPassword

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

# ── 断言与通用工具 ──────────────────────────────────────────────────────────────────────────
function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "断言失败：$Message" }
}
function Assert-Contains {
    param([string] $Text, [string] $Needle, [string] $Message)
    if (-not $Text.Contains($Needle)) { throw "断言失败：$Message（输出里没有「$Needle」）" }
}
function Invoke-Psql {
    param([string] $Database, [string] $Command)
    $output = (& $psql -w -h $DatabaseHost -p $DatabasePort -U $dbUser -d $Database -q -v 'ON_ERROR_STOP=1' -tAc $Command 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "psql 执行失败（退出码 $LASTEXITCODE）：$Command ； $($output -join ' | ')"
    }
    return @($output | ForEach-Object { $_.ToString() })
}
function Get-SqlScalar {
    param([string] $Database, [string] $Command)
    return ((Invoke-Psql -Database $Database -Command $Command) -join '').Trim()
}
function Get-AdvisoryLockKeys {
    param([string] $Database)
    $value = Get-SqlScalar -Database $Database -Command "SELECT COALESCE(string_agg(DISTINCT ((classid::bigint << 32) | objid::bigint)::text, ','), '') FROM pg_locks WHERE locktype = 'advisory' AND objsubid = 1"
    if ([string]::IsNullOrWhiteSpace($value)) { return @() }
    return @($value -split ',')
}
function Get-Ledger {
    param([string] $Database)
    return ((Invoke-Psql -Database $Database -Command "SELECT version || '|' || script_name || '|' || script_sha256 FROM cangshu_m1.schema_version ORDER BY version") -join [Environment]::NewLine).Trim()
}
function Get-HostScriptLedger {
    # 台账口径：script_sha256 ＝ 宿主上该文件的 SHA-256（与 scripts/migrate.sh 传给 psql 变量的值同源）
    $rows = @()
    foreach ($script in @(Get-ChildItem -LiteralPath $migrationDir -Filter 'V*.sql' | Sort-Object Name)) {
        $sha = (Get-FileHash -LiteralPath $script.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $rows += ($script.BaseName.Split('__')[0]) + '|' + $script.Name + '|' + $sha
    }
    return ($rows -join [Environment]::NewLine)
}
function Reset-IsolatedDatabase {
    param([string] $Database)
    & $dropdb -w -h $DatabaseHost -p $DatabasePort -U $dbUser --if-exists $Database 2>&1 | Out-Null
    & $createdb -w -h $DatabaseHost -p $DatabasePort -U $dbUser $Database 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "创建隔离库失败：$Database（退出码 $LASTEXITCODE）" }
}
function Set-MigrationEnvironment {
    param([string] $Database, [string] $MigrationDirectory)
    $env:CANGSHU_DB_NAME = $Database
    $env:CANGSHU_DB_HOST = $DatabaseHost
    $env:CANGSHU_DB_PORT = "$DatabasePort"
    $env:CANGSHU_DB_USER = $dbUser
    $env:CANGSHU_DB_PASSWORD = $dbPassword
    $env:CANGSHU_MIGRATION_LOG_DIR = $outputRoot
    $env:CANGSHU_MIGRATE_PSQL = "$psqlPosix -h $DatabaseHost -p $DatabasePort -U $dbUser -d $Database"
    if ($MigrationDirectory) {
        $env:CANGSHU_MIGRATION_DIR = ConvertTo-PosixPath $MigrationDirectory
    } else {
        Remove-Item Env:CANGSHU_MIGRATION_DIR -ErrorAction SilentlyContinue
    }
}
function Invoke-MigrationRun {
    param([string] $Database, [string] $LogName, [string] $MigrationDirectory, [string] $ScriptPath)
    Set-MigrationEnvironment -Database $Database -MigrationDirectory $MigrationDirectory
    if (-not $ScriptPath) { $ScriptPath = $migrateScriptPosix }
    $log = Join-Path $outputRoot "$LogName.log"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lines = & $bashExe -l $ScriptPath 2>&1 | ForEach-Object { $_.ToString() }
    $exitCode = $LASTEXITCODE
    $stopwatch.Stop()
    $text = ($lines -join [Environment]::NewLine)
    Set-Content -LiteralPath $log -Value $text -Encoding UTF8
    return [pscustomobject]@{
        ExitCode = $exitCode
        Text     = $text
        Log      = $log
        Seconds  = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
    }
}
function Start-MigrationRun {
    param([string] $Database, [string] $LogName, [string] $MigrationDirectory)
    Set-MigrationEnvironment -Database $Database -MigrationDirectory $MigrationDirectory
    $stdout = Join-Path $outputRoot "$LogName.log"
    $stderr = Join-Path $outputRoot "$LogName.err.log"
    $arguments = @('-l', $migrateScriptPosix)
    $process = Start-Process -FilePath $bashExe -ArgumentList $arguments -NoNewWindow -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    return [pscustomobject]@{ Process = $process; Stdout = $stdout; Stderr = $stderr }
}
function Wait-ForLogPattern {
    param([string] $Path, [string] $Pattern, [int] $WaitSeconds, [System.Diagnostics.Process] $Process)
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($Process -and $Process.HasExited) { return $false }
        if (Test-Path -LiteralPath $Path) {
            try {
                if (Select-String -LiteralPath $Path -Pattern $Pattern -SimpleMatch -Quiet -Encoding UTF8 -ErrorAction Stop) { return $true }
            } catch {
                # 子进程仍持有写句柄时重试即可
            }
        }
        Start-Sleep -Milliseconds 300
    }
    return $false
}
function Wait-ForAdvisoryLock {
    param([string] $Database, [string] $Key, [int] $WaitSeconds)
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-AdvisoryLockKeys -Database $Database) -contains $Key) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}
function Get-LogText([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
}
function New-MigrationVariant {
    param([string] $Name, [int] $SlowSeconds, [switch] $FailureProbe)
    $directory = Join-Path $outputRoot "variants/$Name"
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    foreach ($script in @(Get-ChildItem -LiteralPath $migrationDir -Filter 'V*.sql' | Sort-Object Name)) {
        Copy-Item -LiteralPath $script.FullName -Destination (Join-Path $directory $script.Name)
    }
    if ($SlowSeconds -gt 0) {
        Set-Content -LiteralPath (Join-Path $directory 'V9__slow_probe.sql') -Encoding UTF8 -Value @"
-- 并发取证用慢脚本：占住迁移锁＋睡眠，不建表不记账（只存在于 target/ 副本目录，不进 db/migration）。
BEGIN;
SELECT pg_sleep($SlowSeconds);
COMMIT;
"@
    }
    if ($FailureProbe) {
        Set-Content -LiteralPath (Join-Path $directory 'V9__failure_probe.sql') -Encoding UTF8 -Value @'
-- 失败回滚取证：建表＋记账后故意 RAISE（只存在于 target/ 副本目录，不进 db/migration）。
BEGIN;
CREATE TABLE IF NOT EXISTS cangshu_m1.miglock_rollback_probe (id integer PRIMARY KEY);
INSERT INTO cangshu_m1.schema_version (version, script_name, executed_at, script_sha256)
VALUES ('V9', 'V9__failure_probe.sql', now(), :'script_sha256');
DO $probe$ BEGIN RAISE EXCEPTION 'CANGSHU|verify|failure-probe|deliberate'; END $probe$;
COMMIT;
'@
    }
    return $directory
}

# ── 用例 ① 正常迁移 ─────────────────────────────────────────────────────────────────────────
function Invoke-NormalMigrationCase {
    Reset-IsolatedDatabase $PrimaryDatabaseName
    $run = Invoke-MigrationRun -Database $PrimaryDatabaseName -LogName 'case1-normal-migration' -MigrationDirectory $null
    Assert-True ($run.ExitCode -eq 0) "正常迁移期望退出码 0，实际 $($run.ExitCode)（见 $($run.Log)）"
    $acquired = 'CANGSHU|migration|lock-acquired|migrationKey=20260918|writerKey=20260919'
    Assert-Contains $run.Text $acquired '日志缺少取锁标记'
    Assert-Contains $run.Text 'CANGSHU|migration|lock-released|migrationKey=20260918|writerKey=20260919' '日志缺少释放标记'
    Assert-Contains $run.Text 'migration_lock_released=true|writer_lock_released=true' '日志缺少显式释放结果'
    $scriptMarker = 'CANGSHU|migration|script|name=V1__init.sql|sha256='
    Assert-Contains $run.Text $scriptMarker '日志缺少脚本执行标记'
    Assert-True ($run.Text.IndexOf($acquired) -lt $run.Text.IndexOf($scriptMarker)) '取锁必须发生在第一个迁移脚本之前'
    $expectedLedger = Get-HostScriptLedger
    $actualLedger = Get-Ledger $PrimaryDatabaseName
    Assert-True ($actualLedger -eq $expectedLedger) "台账与宿主脚本摘要不一致：期望 [$expectedLedger]，实际 [$actualLedger]"
    Assert-Contains $run.Text ($expectedLedger -split [Environment]::NewLine)[0] '运行日志里的台账行与宿主摘要不一致'
    $tables = Get-SqlScalar -Database $PrimaryDatabaseName -Command "SELECT string_agg(tablename, ',' ORDER BY tablename) FROM pg_tables WHERE schemaname = 'cangshu_m1'"
    Assert-True ($tables -eq 'content,content_conflict,location,resource,schema_version') "表集合不符：$tables"
    $indexes = Get-SqlScalar -Database $PrimaryDatabaseName -Command "SELECT string_agg(indexname, ',' ORDER BY indexname) FROM pg_indexes WHERE schemaname = 'cangshu_m1' AND indexname IN ('idx_resource_name_trgm','idx_resource_tags_jsonb')"
    Assert-True ($indexes -eq 'idx_resource_name_trgm,idx_resource_tags_jsonb') "V2 索引缺失：$indexes"
    Assert-True ((Get-SqlScalar -Database $PrimaryDatabaseName -Command "SELECT count(*) FROM pg_extension WHERE extname = 'pg_trgm'") -eq '1') 'pg_trgm 扩展未安装'
    $locks = Get-AdvisoryLockKeys -Database $PrimaryDatabaseName
    Assert-True ($locks.Count -eq 0) "迁移结束后仍有残留咨询锁：$($locks -join ',')"
    return [pscustomobject]@{
        Evidence = "退出码 0；取锁标记先于首个脚本；台账 [$actualLedger] 与宿主摘要一致；表 5 张＋V2 两索引＋pg_trgm；残留锁 0"
        Log      = $run.Log
    }
}

# ── 用例 ② 并发第二次迁移被拒 ───────────────────────────────────────────────────────────────
function Invoke-ConcurrentMigrationCase {
    Reset-IsolatedDatabase $SecondaryDatabaseName
    $variant = New-MigrationVariant -Name 'concurrent' -SlowSeconds $SlowScriptSeconds
    $first = Start-MigrationRun -Database $SecondaryDatabaseName -LogName 'case2-first-migration' -MigrationDirectory $variant
    try {
        Assert-True (Wait-ForAdvisoryLock -Database $SecondaryDatabaseName -Key '20260918' -WaitSeconds $TimeoutSeconds) "没等到第一个迁移持住迁移锁 20260918（见 $($first.Stdout)）"
        Assert-True (-not $first.Process.HasExited) '第一个迁移在第二个迁移发起前就结束了，无法构成并发'
        $ledgerBefore = Get-Ledger $SecondaryDatabaseName
        $second = Invoke-MigrationRun -Database $SecondaryDatabaseName -LogName 'case2-second-migration-denied' -MigrationDirectory $null
        Assert-True ($second.ExitCode -eq 2) "并发第二次迁移期望退出码 2（07 §7 未拿锁），实际 $($second.ExitCode)（见 $($second.Log)）"
        Assert-Contains $second.Text 'CANGSHU|migration|denied|reason=migration-lock|lockKey=20260918' '被拒原因不是迁移锁'
        Assert-Contains $second.Text '已有迁移在执行' '被拒信息没有说明「已有迁移在执行」'
        Assert-Contains $second.Text '未执行任何 DDL，未写任何字节' '被拒路径没有说明未写任何字节'
        Assert-True ($second.Seconds -lt 10) "被拒应当立刻返回（实测 $($second.Seconds) 秒），不阻塞等锁"
        Assert-True (-not $first.Process.HasExited) '被拒时第一个迁移应当仍在运行（否则不是并发场景）'
        $ledgerAfter = Get-Ledger $SecondaryDatabaseName
        Assert-True ($ledgerAfter -eq $ledgerBefore) "被拒的第二次迁移改动了台账：before [$ledgerBefore]，after [$ledgerAfter]"
        Assert-True ($first.Process.WaitForExit($TimeoutSeconds * 1000)) "第一个迁移未在 $TimeoutSeconds 秒内结束"
        $firstText = Get-LogText $first.Stdout
        Assert-True ($first.Process.ExitCode -eq 0) "第一个迁移期望退出码 0，实际 $($first.Process.ExitCode)（见 $($first.Stdout)）"
        Assert-Contains $firstText 'migration_lock_released=true|writer_lock_released=true' '第一个迁移没有正常释放两把锁'
        $locks = Get-AdvisoryLockKeys -Database $SecondaryDatabaseName
        Assert-True ($locks.Count -eq 0) "第一个迁移结束后仍有残留咨询锁：$($locks -join ',')"
        return [pscustomobject]@{
            Evidence = "第二次迁移退出码 2（$($second.Seconds) 秒内返回，未阻塞）原文 reason=migration-lock；台账 before=after；被拒时 #1 仍在跑；#1 退出码 0 且锁已释放"
            Log      = $second.Log
        }
    } finally {
        if (-not $first.Process.HasExited) { $first.Process.Kill() }
    }
}

# ── 用例 ③ 写者持锁时迁移被拒 ───────────────────────────────────────────────────────────────
function Invoke-WriterLockHeldCase {
    Reset-IsolatedDatabase $SecondaryDatabaseName
    $holderScript = Join-Path $outputRoot 'writer-lock-holder.sql'
    Set-Content -LiteralPath $holderScript -Encoding UTF8 -Value @'
-- 模拟一个持有写者锁（键 20260919，07 §1 登记值）的活跃写者：等价于 serve 实例的 WriterGate 会话锁。
SELECT pg_advisory_lock(20260919);
SELECT pg_sleep(300);
'@
    $holderLog = Join-Path $outputRoot 'case3-writer-lock-holder.log'
    $holderArguments = @('-w', '-h', $DatabaseHost, '-p', "$DatabasePort", '-U', $dbUser, '-d', $SecondaryDatabaseName, '-q', '-f', $holderScript)
    $holder = Start-Process -FilePath $psql -ArgumentList $holderArguments -NoNewWindow -PassThru -RedirectStandardOutput $holderLog
    try {
        Assert-True (Wait-ForAdvisoryLock -Database $SecondaryDatabaseName -Key '20260919' -WaitSeconds $TimeoutSeconds) "没等到模拟写者持住写者锁 20260919（见 $holderLog）"
        $run = Invoke-MigrationRun -Database $SecondaryDatabaseName -LogName 'case3-writer-lock-denied' -MigrationDirectory $null
        Assert-True ($run.ExitCode -eq 2) "写者持锁时期望退出码 2（07 §7 未拿锁），实际 $($run.ExitCode)（见 $($run.Log)）"
        Assert-Contains $run.Text 'CANGSHU|migration|denied|reason=writer-lock|lockKey=20260919' '被拒原因不是写者锁'
        Assert-Contains $run.Text '迁移操作需确保业务写者已退出' '拒绝信息缺少规范依据原文'
        Assert-Contains $run.Text '停掉 serve' '拒绝信息没有给出「停掉 serve 实例」指引'
        Assert-True ($run.Seconds -lt 10) "拒绝应当立刻返回（实测 $($run.Seconds) 秒），不阻塞等写者退出"
        $schema = Get-SqlScalar -Database $SecondaryDatabaseName -Command "SELECT COALESCE(to_regnamespace('cangshu_m1')::text, '<null>')"
        Assert-True ($schema -eq '<null>') "被拒的迁移不应写任何字节，但库里出现了 cangshu_m1：$schema"
    } finally {
        if (-not $holder.HasExited) { $holder.Kill() }
        $holder.WaitForExit()
    }
    Start-Sleep -Milliseconds 500
    $locks = Get-AdvisoryLockKeys -Database $SecondaryDatabaseName
    Assert-True ($locks.Count -eq 0) "模拟写者退出后仍有残留咨询锁：$($locks -join ',')"
    return [pscustomobject]@{
        Evidence = "迁移退出码 2、原文 reason=writer-lock|lockKey=20260919；指引含「停掉 serve」；拒绝后 cangshu_m1 未创建；写者退出后残留锁 0"
        Log      = $run.Log
    }
}

# ── 用例 ④ 失败回滚 ─────────────────────────────────────────────────────────────────────────
function Invoke-FailureRollbackCase {
    Reset-IsolatedDatabase $PrimaryDatabaseName
    $variant = New-MigrationVariant -Name 'failure' -SlowSeconds 0 -FailureProbe
    $run = Invoke-MigrationRun -Database $PrimaryDatabaseName -LogName 'case4-failure-rollback' -MigrationDirectory $variant
    Assert-True ($run.ExitCode -eq 1) "失败迁移期望退出码 1（脚本报错、整体回滚），实际 $($run.ExitCode)（见 $($run.Log)）"
    Assert-Contains $run.Text 'CANGSHU|verify|failure-probe|deliberate' '日志里没有失败脚本的故意错误'
    Assert-Contains $run.Text '迁移失败' '日志没有说明迁移失败'
    $ledger = Get-Ledger $PrimaryDatabaseName
    Assert-True ($ledger -eq (Get-HostScriptLedger)) "失败脚本应整体回滚：台账期望 V1／V2，实际 [$ledger]"
    Assert-True (-not $ledger.Contains('V9')) "失败脚本的台账行没有被回滚：$ledger"
    $probeTable = Get-SqlScalar -Database $PrimaryDatabaseName -Command "SELECT COALESCE(to_regclass('cangshu_m1.miglock_rollback_probe')::text, '<null>')"
    Assert-True ($probeTable -eq '<null>') "失败脚本建的探针表没有被回滚：$probeTable"
    $locks = Get-AdvisoryLockKeys -Database $PrimaryDatabaseName
    Assert-True ($locks.Count -eq 0) "失败结束后仍有残留咨询锁：$($locks -join ',')"
    $reacquire = Get-SqlScalar -Database $PrimaryDatabaseName -Command "SELECT pg_try_advisory_lock(20260918) AND pg_try_advisory_lock(20260919)"
    Assert-True ($reacquire -eq 't') "失败结束后两把锁应当可以再次取得，实际：$reacquire"
    return [pscustomobject]@{
        Evidence = "退出码 1；台账 [$ledger]（无 V9）；探针表不存在；残留锁 0；两把锁可再次取得（pg_try_advisory_lock=true）"
        Log      = $run.Log
    }
}

# ── 用例 ⑤ 交付态包装脚本冒烟（容器传输未执行） ──────────────────────────────────────────────
function Invoke-ComposeWrapperCase {
    Reset-IsolatedDatabase $PrimaryDatabaseName
    $run = Invoke-MigrationRun -Database $PrimaryDatabaseName -LogName 'case5-compose-wrapper' -MigrationDirectory $null -ScriptPath $composeMigrateScriptPosix
    Assert-True ($run.ExitCode -eq 0) "包装脚本期望退出码 0，实际 $($run.ExitCode)（见 $($run.Log)）"
    Assert-Contains $run.Text '== 人工迁移（交付态：容器内 psql）==' '包装脚本没有打印交付态标题'
    Assert-Contains $run.Text 'CANGSHU|migration|lock-acquired|migrationKey=20260918|writerKey=20260919' '包装脚本没有取锁标记'
    Assert-Contains $run.Text 'migration_lock_released=true|writer_lock_released=true' '包装脚本没有释放标记'
    $ledger = Get-Ledger $PrimaryDatabaseName
    Assert-True ($ledger -eq (Get-HostScriptLedger)) "包装脚本迁移后的台账不符：[$ledger]"
    return [pscustomobject]@{
        Evidence = "退出码 0；协议标记与台账与用例 ① 一致；容器内 psql（docker compose exec）未执行：本机 Docker 引擎未运行"
        Log      = $run.Log
    }
}

# ── 取证主体 ────────────────────────────────────────────────────────────────────────────────
Write-Host '== 人工迁移锁协议取证 =='
Write-Host "  隔离库：$PrimaryDatabaseName / $SecondaryDatabaseName @ $endpoint    用户：$dbUser"
Write-Host "  证据目录：$outputRoot"
Write-Host '  协议锁键：迁移锁 20260918、写者锁 20260919（07 §1 登记值；不支持环境变量覆盖）'

$cases = @(
    [pscustomobject]@{ Name = '① 正常迁移（取锁→执行→释放；结构与台账）'; Body = { Invoke-NormalMigrationCase } },
    [pscustomobject]@{ Name = '② 并发第二次迁移被拒（reason=migration-lock，非阻塞）'; Body = { Invoke-ConcurrentMigrationCase } },
    [pscustomobject]@{ Name = '③ 写者持锁时迁移被拒（reason=writer-lock，给停 serve 指引）'; Body = { Invoke-WriterLockHeldCase } },
    [pscustomobject]@{ Name = '④ 失败回滚（台账与结构无残留、锁已释放）'; Body = { Invoke-FailureRollbackCase } },
    [pscustomobject]@{ Name = '⑤ 交付态包装脚本冒烟（容器传输未执行）'; Body = { Invoke-ComposeWrapperCase } }
)

$results = @()
try {
    foreach ($case in $cases) {
        Write-Host ''
        Write-Host ("[用例] " + $case.Name)
        try {
            $outcome = & $case.Body
            $results += [pscustomobject]@{ Case = $case.Name; Ok = $true; Evidence = $outcome.Evidence; Log = $outcome.Log }
            Write-Host ("  PASS：" + $outcome.Evidence)
            Write-Host ("  原始输出：" + $outcome.Log)
        } catch {
            $results += [pscustomobject]@{ Case = $case.Name; Ok = $false; Evidence = $_.Exception.Message; Log = '(见上方与证据目录)' }
            Write-Host ("  FAIL：" + $_.Exception.Message)
        }
    }
} finally {
    if ($KeepDatabase) {
        Write-Host ''
        Write-Host "  保留隔离库（-KeepDatabase）：$PrimaryDatabaseName / $SecondaryDatabaseName"
    } else {
        foreach ($database in @($PrimaryDatabaseName, $SecondaryDatabaseName)) {
            & $dropdb -w -h $DatabaseHost -p $DatabasePort -U $dbUser --if-exists $database 2>&1 | Out-Null
        }
        Write-Host ''
        Write-Host "  已删除隔离库：$PrimaryDatabaseName / $SecondaryDatabaseName"
    }
    Remove-Item Env:CANGSHU_MIGRATION_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:CANGSHU_MIGRATE_PSQL -ErrorAction SilentlyContinue
    Remove-Item Env:CANGSHU_MIGRATION_LOG_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:CANGSHU_DB_PASSWORD -ErrorAction SilentlyContinue

    $summary = @()
    $summary += '== 人工迁移锁协议取证结果 =='
    foreach ($result in $results) {
        $mark = if ($result.Ok) { 'PASS' } else { 'FAIL' }
        $summary += "[$mark] $($result.Case)"
        $summary += "        证据：$($result.Evidence)"
        $summary += "        原始输出：$($result.Log)"
    }
    Set-Content -LiteralPath (Join-Path $outputRoot 'summary.txt') -Value ($summary -join [Environment]::NewLine) -Encoding UTF8
}

Write-Host ''
Write-Host '== 结果 =='
foreach ($result in $results) {
    $mark = if ($result.Ok) { 'PASS' } else { 'FAIL' }
    Write-Host ("  [{0}] {1}" -f $mark, $result.Case)
    Write-Host ("         证据：{0}" -f $result.Evidence)
    Write-Host ("         原始输出：{0}" -f $result.Log)
}
$failedCount = @($results | Where-Object { -not $_.Ok }).Count
Write-Host ''
if ($failedCount -gt 0) {
    Write-Host "取证未通过：$failedCount 个用例失败（见上方与 $outputRoot）"
    exit 1
}
Write-Host '取证通过：正常迁移退出码 0 且取锁先于脚本、锁释放齐全；并发第二次迁移退出码 2（reason=migration-lock）；写者持锁时退出码 2（reason=writer-lock，给停 serve 指引、不写任何字节）；失败回滚无残留且锁已释放。'
exit 0