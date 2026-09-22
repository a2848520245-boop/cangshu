<#
.SYNOPSIS
    任务 30 迁移启动门取证：在隔离库上用真实 PostgreSQL + 打包 jar 复现「正常启动通过」与「三类漂移退出码 3」。

.DESCRIPTION
    步骤（全部对隔离库 cangshu_task30_verify 操作，绝不触碰 cangshu / cangshu_test / cangshu_m1demo）：
      1. 创建隔离库，用 psql 按序执行 db/migration 下全部脚本（带 -v script_sha256=<脚本 SHA-256> 记账）；
      2. 以显式参数启动打包 jar（java -jar target/cangshu-0.1.0-SNAPSHOT.jar）：
           -Dcangshu.migration.dir=<仓库 db/migration>
           -Dspring.datasource.url=jdbc:postgresql://<host>:<port>/cangshu_task30_verify?currentSchema=cangshu_m1
         正常用例断言：日志出现 CANGSHU|migration|verified，健康检查 UP，进程退出码 0
         （正常用例经 actuator shutdown 端点优雅停机，退出码 0 即 JVM 正常终止）；
      3. 逐类制造真实漂移并重启，断言退出码 3 且日志含对应失败信息：
           A 台账缺行      —— 删除 schema_version 中 V2 行
           B 删除 CHECK    —— DROP CONSTRAINT content_size_bytes_check
           C 删除索引      —— DROP INDEX cangshu_m1.idx_content_digest
           D 未登记脚本    —— 复制 db/migration 并额外塞入 V9__unregistered.sql
         每类的原始日志（stdout/err）按用例名留在输出目录；
      4. 结尾删除隔离库（-KeepDatabase 可保留）。

    凭据来自 src/main/resources/application.yml 的既有默认值，可被 CANGSHU_DB_USER / CANGSHU_DB_PASSWORD
    覆盖；密码只经环境变量传递给子进程，不打印、不进命令行。

    前置：已构建打包 jar（mvn -B -DskipTests package）；本机有 PostgreSQL 17 客户端（默认 E:\\PostgreSQL\\17\\bin）；
    JAVA_HOME 指向 JDK 21+。

.EXAMPLE
    pwsh -File scripts/verify-task30-migration-gate.ps1

.EXAMPLE
    pwsh -File scripts/verify-task30-migration-gate.ps1 -KeepDatabase -OutputDirectory D:\\task30-evidence
#>
[CmdletBinding()]
param(
    [string] $DatabaseName = 'cangshu_task30_verify',
    [string] $DatabaseHost = '127.0.0.1',
    [int] $DatabasePort = 5432,
    [int] $ServerPort = 18080,
    [string] $OutputDirectory = 'target/task30-migration-gate',
    [string] $PostgresBin = 'E:\\PostgreSQL\\17\\bin',
    [int] $TimeoutSeconds = 120,
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
$postgresBinPath = Resolve-From $PostgresBin
$psql = Join-Path $postgresBinPath 'psql.exe'
$createdb = Join-Path $postgresBinPath 'createdb.exe'
$dropdb = Join-Path $postgresBinPath 'dropdb.exe'
$dataRoot = Join-Path $outputRoot 'data-root'

# ── 前置检查 ────────────────────────────────────────────────────────────────────────────────
if ($DatabaseName -notmatch '^cangshu_task30_[A-Za-z0-9_]+$') {
    throw "拒绝执行：库名 '$DatabaseName' 不符合隔离库规则 ^cangshu_task30_[A-Za-z0-9_]+$（不得指向 cangshu / cangshu_test / cangshu_m1demo）"
}
if (-not (Test-Path -LiteralPath $migrationDir)) { throw "找不到迁移脚本目录：$migrationDir" }
if (-not (Test-Path -LiteralPath $jarPath)) {
    throw "找不到打包 jar：$jarPath`n先执行：mvn -B -DskipTests package"
}
foreach ($tool in @($psql, $createdb, $dropdb)) {
    if (-not (Test-Path -LiteralPath $tool)) {
        throw "找不到 $tool`n用 -PostgresBin 指定 PostgreSQL 17 bin 目录（当前：$postgresBinPath）"
    }
}
$javaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME')
if (-not $javaHome) { throw '未设置 JAVA_HOME（打包 jar 需要 JDK 21+ 运行）' }
$javaPath = Join-Path $javaHome 'bin/java.exe'
if (-not (Test-Path -LiteralPath $javaPath)) { throw "找不到 java：$javaPath" }
$javaVersionLine = (& $javaPath -version 2>&1 | Select-Object -First 1) -join ''
$javaMajor = if ($javaVersionLine -match 'version "?(\\d+)') { [int] $Matches[1] } else { 0 }
if ($javaMajor -lt 21) { throw "运行打包 jar 需要 JDK 21+，当前：$javaVersionLine" }
if (-not (Get-Command $curlPath -ErrorAction SilentlyContinue)) {
    throw "找不到 $curlPath（健康检查与优雅停调用它；Windows 10 1803+ 自带 curl.exe）"
}

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
New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null

$env:PGPASSWORD = $dbPassword
$env:CANGSHU_DB_USER = $dbUser
$env:CANGSHU_DB_PASSWORD = $dbPassword

function Quote-Arguments([string[]] $Arguments) {
    $quoted = foreach ($argument in $Arguments) {
        if ($argument -match '\\s') { '"' + $argument + '"' } else { $argument }
    }
    return ($quoted -join ' ')
}

function Invoke-PsqlQuery {
    param([string] $Command)
    $output = (& $psql -h $DatabaseHost -p $DatabasePort -U $dbUser -d $DatabaseName -q -v 'ON_ERROR_STOP=1' -c $Command 2>&1)
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
        $output = (& $psql -h $DatabaseHost -p $DatabasePort -U $dbUser -d $DatabaseName -q `
            -v 'ON_ERROR_STOP=1' -v "script_sha256=$sha" -f $script.FullName 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "迁移脚本执行失败：$($script.Name)`n$($output -join [Environment]::NewLine)"
        }
        Write-Host ("    迁移 {0}（sha256={1}…）" -f $script.Name, $sha.Substring(0, 12))
    }
}

function Reset-IsolatedDatabase {
    & $dropdb -h $DatabaseHost -p $DatabasePort -U $dbUser --if-exists $DatabaseName 2>&1 | Out-Null
    & $createdb -h $DatabaseHost -p $DatabasePort -U $dbUser $DatabaseName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "创建隔离库失败：$DatabaseName（退出码 $LASTEXITCODE）" }
    Invoke-MigrationScripts
}

function Start-GateProcess {
    param([string] $MigrationDirectory, [string] $LogName, [switch] $AllowShutdownEndpoint)
    $jvmArguments = @(
        '-Dstdout.encoding=UTF-8',
        '-Dstderr.encoding=UTF-8',
        "-Dcangshu.migration.dir=$MigrationDirectory",
        "-Dcangshu.data-root=$dataRoot",
        "-Dspring.datasource.url=jdbc:postgresql://${DatabaseHost}:${DatabasePort}/${DatabaseName}?currentSchema=cangshu_m1"
    )
    $applicationArguments = @('--spring.main.banner-mode=off', "--server.port=$ServerPort")
    if ($AllowShutdownEndpoint) {
        $applicationArguments += '--management.endpoints.web.exposure.include=health,shutdown'
        $applicationArguments += '--management.endpoint.shutdown.enabled=true'
    }
    $stdout = Join-Path $outputRoot "$LogName.log"
    $stderr = Join-Path $outputRoot "$LogName.err.log"
    $arguments = Quote-Arguments ($jvmArguments + @('-jar', $jarPath) + $applicationArguments)
    $process = Start-Process -FilePath $javaPath -ArgumentList $arguments -NoNewWindow -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
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
    Reset-IsolatedDatabase
    $run = Start-GateProcess -MigrationDirectory $migrationDir -LogName 'case-clean' -AllowShutdownEndpoint
    try {
        if (-not (Wait-ForLogPattern -Path $run.Stdout -Pattern 'CANGSHU|migration|verified' -WaitSeconds $TimeoutSeconds)) {
            throw "正常启动未出现 CANGSHU|migration|verified（见 $($run.Stdout)）"
        }
        $verifiedLines = @(Select-String -LiteralPath $run.Stdout -Pattern 'CANGSHU|migration|verified' -SimpleMatch -Encoding UTF8)
        $health = Invoke-RestMethod -Method Get -Uri "http://${DatabaseHost}:${ServerPort}/actuator/health" -TimeoutSec 30
        if ($health.status -ne 'UP') { throw "健康检查未通过：$($health | ConvertTo-Json -Compress)" }
        Invoke-RestMethod -Method Post -Uri "http://${DatabaseHost}:${ServerPort}/actuator/shutdown" -TimeoutSec 30 | Out-Null
        if (-not $run.Process.WaitForExit(60000)) { throw '优雅停机超时（60 秒内进程未退出）' }
        return [pscustomobject]@{
            Case       = '正常启动（clean）'
            Expected   = 0
            Actual     = $run.Process.ExitCode
            Log        = $run.Stdout
            Evidence   = $verifiedLines[0].Line.Trim()
            Message    = ''
        }
    } finally {
        if (-not $run.Process.HasExited) { $run.Process.Kill() }
    }
}

function Invoke-DriftCase {
    param([string] $Name, [string] $ExpectedMessage, [string] $MigrationDirectory = $migrationDir)
    $run = Start-GateProcess -MigrationDirectory $MigrationDirectory -LogName "case-$Name"
    try {
        if (-not $run.Process.WaitForExit($TimeoutSeconds * 1000)) {
            throw "用例 $Name 未在 $TimeoutSeconds 秒内退出（见 $($run.Stdout)）"
        }
        $logText = Get-LogText $run.Stdout
        if (-not $logText.Contains($ExpectedMessage)) {
            throw "用例 $Name 的日志缺少期望信息「$ExpectedMessage」（见 $($run.Stdout)）"
        }
        return [pscustomobject]@{
            Case     = $Name
            Expected = 3
            Actual   = $run.Process.ExitCode
            Log      = $run.Stdout
            Evidence = $ExpectedMessage
            Message  = $ExpectedMessage
        }
    } finally {
        if (-not $run.Process.HasExited) { $run.Process.Kill() }
    }
}

function New-UnregisteredScriptDirectory {
    $directory = Join-Path $outputRoot 'migration-drift'
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
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
Write-Host "== 任务 30 迁移启动门取证 =="
Write-Host "  隔离库：$DatabaseName @ ${DatabaseHost}:${DatabasePort}    用户：$dbUser    日志目录：$outputRoot"
Write-Host "  jar：$jarPath"
$results = @()
try {
    Write-Host '[1/5] 正常启动（隔离库 + 人工迁移 + 打包 jar）'
    $results += Invoke-CleanStartupCase

    Write-Host '[2/5] 漂移 A：台账缺行（DELETE schema_version V2）'
    Reset-IsolatedDatabase
    Invoke-PsqlQuery "DELETE FROM cangshu_m1.schema_version WHERE version = 'V2'" | Out-Null
    $results += Invoke-DriftCase -Name 'drift-a-ledger-missing' -ExpectedMessage 'schema_version 台账与迁移脚本不一致'

    Write-Host '[3/5] 漂移 B：删除 CHECK 约束（content_size_bytes_check）'
    Reset-IsolatedDatabase
    Invoke-PsqlQuery 'ALTER TABLE cangshu_m1.content DROP CONSTRAINT content_size_bytes_check' | Out-Null
    $results += Invoke-DriftCase -Name 'drift-b-check-dropped' -ExpectedMessage 'schema 关键结构与 manifest 不一致'

    Write-Host '[4/5] 漂移 C：删除索引（idx_content_digest）'
    Reset-IsolatedDatabase
    Invoke-PsqlQuery 'DROP INDEX cangshu_m1.idx_content_digest' | Out-Null
    $results += Invoke-DriftCase -Name 'drift-c-index-dropped' -ExpectedMessage 'schema 关键结构与 manifest 不一致'

    Write-Host '[5/5] 漂移 D：db/migration 多出未登记脚本（V9__unregistered.sql）'
    Reset-IsolatedDatabase
    $driftDirectory = New-UnregisteredScriptDirectory
    $results += Invoke-DriftCase -Name 'drift-d-unregistered-script' -ExpectedMessage '迁移脚本集合或摘要与 manifest 不一致' `
        -MigrationDirectory $driftDirectory
} finally {
    if ($KeepDatabase) {
        Write-Host "  保留隔离库（-KeepDatabase）：$DatabaseName"
    } else {
        & $dropdb -h $DatabaseHost -p $DatabasePort -U $dbUser --if-exists $DatabaseName 2>&1 | Out-Null
        Write-Host "  已删除隔离库：$DatabaseName"
    }
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:CANGSHU_DB_USER -ErrorAction SilentlyContinue
    Remove-Item Env:CANGSHU_DB_PASSWORD -ErrorAction SilentlyContinue
}

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
if ($failed.Count -gt 0) {
    Write-Host ''
    Write-Host "取证未通过：$($failed.Count) 个用例的退出码与期望不符（见上方日志）"
    exit 1
}
Write-Host ''
Write-Host '取证通过：正常启动退出码 0 且出现 CANGSHU|migration|verified；三类漂移各自退出码 3。'
exit 0
