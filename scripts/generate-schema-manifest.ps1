<#
.SYNOPSIS
    用隔离 PG17 实例重新生成 M1 schema 基线清单（src/main/resources/db/schema-manifest-v1.json）。

.DESCRIPTION
    可复现入口对应 com.cangshu.migration.SchemaManifestGenerator（应用启动绝不会调用它）：
      1. 在 -DatabaseHost/-DatabasePort 指向的实例上创建随机命名的临时库（cangshu_task30_manifest_<uuid>）；
      2. 按序执行 db/migration 下全部 V*.sql（文件整体 SHA-256 作为 :'script_sha256' 记账值）；
      3. 从真实 catalog 反编译（pg_get_constraintdef / pg_get_indexdef）写出清单；
      4. 删除临时库。

    **需要隔离的 PG17 实例**：清单记录的是「该实例反编译出来的结构」，所以生成源必须是隔离 PG17 实例
    （本项目开发轨为 127.0.0.1:5432）；不要把 cangshu / cangshu_test / cangshu_m1demo 这类既有库
    当生成源。脚本先核对实例大版本，不是 17 直接失败。

    默认只生成到 target/schema-manifest-generated.json 并与制品清单比较 SHA-256：
      一致   → 打印「逐字节一致」，退出码 0；
      不一致 → 打印两份摘要，退出码 1（加 -Apply 才覆盖制品清单）。

    凭据来自 src/main/resources/application.yml 的既有默认值，可被 CANGSHU_DB_USER / CANGSHU_DB_PASSWORD
    覆盖；密码只经环境变量传给子进程，不打印、不进命令行。

.EXAMPLE
    pwsh -File scripts/generate-schema-manifest.ps1

.EXAMPLE
    pwsh -File scripts/generate-schema-manifest.ps1 -Build -Apply
#>
[CmdletBinding()]
param(
    [string] $DatabaseHost = '127.0.0.1',
    [int] $DatabasePort = 5432,
    [string] $AdminDatabase = 'postgres',
    [string] $Output = 'target/schema-manifest-generated.json',
    [string] $PostgresBin = 'E:\\PostgreSQL\\17\\bin',
    [switch] $Build,
    [switch] $Apply
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
$committedManifest = Join-Path $repoRoot 'src/main/resources/db/schema-manifest-v1.json'
$jarPath = Join-Path $repoRoot 'target/cangshu-0.1.0-SNAPSHOT.jar'
$outputPath = Resolve-From $Output
$psql = Join-Path (Resolve-From $PostgresBin) 'psql.exe'
$endpoint = $DatabaseHost + ':' + $DatabasePort

if (-not (Test-Path -LiteralPath $psql)) {
    throw "找不到 $psql ； 用 -PostgresBin 指定 PostgreSQL 17 bin 目录"
}
$javaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME')
if (-not $javaHome) { throw '未设置 JAVA_HOME（生成器需要 JDK 21+ 运行）' }
$javaPath = Join-Path $javaHome 'bin/java.exe'
if (-not (Test-Path -LiteralPath $javaPath)) { throw "找不到 java：$javaPath" }
if ($Build) {
    Write-Host '  先构建打包 jar：mvn -B -q -DskipTests package'
    & mvn -B -q -DskipTests package
    if ($LASTEXITCODE -ne 0) { throw "mvn package 失败（退出码 $LASTEXITCODE）" }
}
if (-not (Test-Path -LiteralPath $jarPath)) {
    throw "找不到打包 jar：$jarPath ； 先执行 mvn -B -DskipTests package，或加 -Build"
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

$env:PGPASSWORD = $dbPassword
$env:CANGSHU_DB_PASSWORD = $dbPassword

Write-Host '== 生成 schema manifest =='
Write-Host "  生成源（隔离 PG17 实例）：$endpoint    管理库：$AdminDatabase    用户：$dbUser"
$serverVersion = (& $psql -h $DatabaseHost -p $DatabasePort -U $dbUser -d $AdminDatabase -tAc 'SHOW server_version' 2>&1) -join ''
if ($LASTEXITCODE -ne 0) { throw "无法连接 PG 实例 $endpoint（退出码 $LASTEXITCODE）：$serverVersion" }
if ($serverVersion -notmatch '^17\\.') {
    throw "清单生成需要隔离的 PG17 实例，当前实例版本为 $serverVersion ； 用 -DatabaseHost/-DatabasePort 指定另一实例"
}
Write-Host "  实例版本：$serverVersion"

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputPath) | Out-Null
$jvmArguments = @(
    '-Dstdout.encoding=UTF-8',
    '-Dstderr.encoding=UTF-8',
    '-cp', $jarPath,
    '-Dloader.main=com.cangshu.migration.SchemaManifestGenerator',
    'org.springframework.boot.loader.launch.PropertiesLauncher'
)
$generatorArguments = @(
    "--admin-url=jdbc:postgresql://$endpoint/$AdminDatabase",
    "--username=$dbUser",
    '--password-env=CANGSHU_DB_PASSWORD',
    "--migration-dir=$migrationDir",
    "--output=$outputPath"
)
& $javaPath ($jvmArguments + $generatorArguments)
if ($LASTEXITCODE -ne 0) { throw "清单生成器失败（退出码 $LASTEXITCODE）" }
if (-not (Test-Path -LiteralPath $outputPath)) { throw "生成器没有写出清单：$outputPath" }

$generated = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
$generatedHash = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant()
$committedHash = (Get-FileHash -LiteralPath $committedManifest -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host ("  生成清单：sha256={0}  migrations={1} tables={2} indexes={3} pg={4}" -f $generatedHash, $generated.migrations.Count, $generated.tables.Count, $generated.indexes.Count, $generated.postgresqlMajor)
Write-Host ("  制品清单：sha256={0}" -f $committedHash)

Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
Remove-Item Env:CANGSHU_DB_PASSWORD -ErrorAction SilentlyContinue

if ($generatedHash -eq $committedHash) {
    Write-Host '  结论：与制品清单逐字节一致（当前隔离实例可复现该基线）'
    exit 0
}
Write-Host '  结论：与制品清单不一致（两份摘要不同，临时库已删除，制品未被改动）'
if (-not $Apply) {
    Write-Host '  未覆盖制品清单（未加 -Apply）：请先核对差异，再用 -Apply 落地'
    exit 1
}
Copy-Item -LiteralPath $outputPath -Destination $committedManifest -Force
Write-Host "  已覆盖制品清单：$committedManifest"
Write-Host '  注意：清单变化后，启动门基线与 SchemaVerifierTests 正例都要重新取证（mvn -B test 与 scripts/verify-task30-migration-gate.ps1）'
exit 0