#!/usr/bin/env pwsh
# 无数据库契约测试：按当前 Java DTO 字段形状加载矩阵脚本中的响应判据。
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$dto = Get-Content -LiteralPath (Join-Path $root 'src/main/java/com/cangshu/api/dto/UploadResponse.java') -Raw
$hashDto = Get-Content -LiteralPath (Join-Path $root 'src/main/java/com/cangshu/api/dto/HashView.java') -Raw
foreach($shape in @('UUID id','HashView hash','Long sizeBytes','Boolean deduplicated','UUID contentId')){
    if(-not $dto.Contains($shape)){throw "UploadResponse DTO 缺字段：$shape"}
}
foreach($shape in @('String algorithm','String digest')){
    if(-not $hashDto.Contains($shape)){throw "HashView DTO 缺字段：$shape"}
}
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'verify-task31-matrix.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw "矩阵脚本语法错误：$($errors[0].Message)"}
$functions=@($ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Test-Task31UploadResponse'},$true))
if($functions.Count -ne 1){throw '上传契约判据必须恰有一个定义'}
. ([scriptblock]::Create($functions[0].Extent.Text))
$digest='a'*64
$payload=[pscustomobject]@{Digest=$digest;SizeBytes=65536}
$valid=@"
{"id":"11111111-1111-1111-1111-111111111111","name":"fixture.bin","sizeBytes":65536,"hash":{"algorithm":"sha256","digest":"$digest"},"status":"READY","deduplicated":false,"contentId":"22222222-2222-2222-2222-222222222222"}
"@ | ConvertFrom-Json
if(-not (Test-Task31UploadResponse -Response $valid -Payload $payload -Deduplicated $false)){throw '真实 DTO 形状被拒绝'}
$reused=($valid | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
$reused.deduplicated=$true
if(-not (Test-Task31UploadResponse -Response $reused -Payload $payload -Deduplicated $true)){throw '复用响应被拒绝'}
if(Test-Task31UploadResponse -Response $reused -Payload $payload -Deduplicated $false){throw '错误 deduplicated 期望被接受'}
$legacy=('{' + '"resourceId":"11111111-1111-1111-1111-111111111111","digest":"' + $digest + '","sizeBytes":65536,"deduplicated":false}') | ConvertFrom-Json
if(Test-Task31UploadResponse -Response $legacy -Payload $payload -Deduplicated $false){throw '旧 resourceId/顶层digest 形状被错误接受'}
$bad=($valid | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
$bad.hash.digest='b'*64
if(Test-Task31UploadResponse -Response $bad -Payload $payload -Deduplicated $false){throw '错误摘要被接受'}
$bad=($valid | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
$bad.hash.algorithm='SHA-256'
if(Test-Task31UploadResponse -Response $bad -Payload $payload -Deduplicated $false){throw '错误显示算法被接受'}
$identityFunction=@($ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Test-Task31ReadyIdentity'},$true))
if($identityFunction.Count -ne 1){throw '库内关联判据必须恰有一个定义'}
. ([scriptblock]::Create($identityFunction[0].Extent.Text))
function Invoke-PsqlQuery { param([string] $DatabaseName,[string] $Command) return $script:mockRows }
$schema='cangshu_m1'
$contentId='22222222-2222-2222-2222-222222222222'
$resourceId='11111111-1111-1111-1111-111111111111'
$key='sha256/aa/aa/' + $digest
$script:mockRows=@("$resourceId|$contentId|$contentId|SHA-256|$digest|65536|65536|READY|READY|$contentId|filesystem|$key")
$identity=Test-Task31ReadyIdentity -DatabaseName sample -Payload $payload -ResourceIds @($resourceId) -ContentId $contentId
if(-not $identity.Pass){throw '真实 schema 的资源→内容→位置关联被拒绝'}
$script:mockRows=@("$resourceId|$contentId|$contentId|SHA-256|$digest|65536|65536|READY|READY|$contentId|filesystem|sha256/xx/xx/$digest")
if((Test-Task31ReadyIdentity -DatabaseName sample -Payload $payload -ResourceIds @($resourceId) -ContentId $contentId).Pass){throw '错误物理键被接受'}
$script:mockRows=@("$resourceId|$contentId|$contentId|SHA-256|$digest|65536|65536|READY|READY|$contentId|filesystem|$key",
    "$resourceId|$contentId|$contentId|SHA-256|$digest|65536|65536|READY|READY|$contentId|filesystem|$key")
if((Test-Task31ReadyIdentity -DatabaseName sample -Payload $payload -ResourceIds @($resourceId) -ContentId $contentId).Pass){throw '重复位置/资源关联被接受'}
Write-Output 'PASS task31 UploadResponse real DTO shape, legacy rejection, DB identity join'
