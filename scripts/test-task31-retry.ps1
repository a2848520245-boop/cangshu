#!/usr/bin/env pwsh
# 无数据库测试：明确未命中才重试，重试库名/端口独立，异常与断言失败不重试。
$ErrorActionPreference='Stop'
$path=Join-Path $PSScriptRoot 'verify-task31-matrix.ps1'
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count){throw "矩阵脚本语法错误：$($errors[0].Message)"}
foreach($name in @('Throw-Task31Miss','Get-Task31AttemptAction','Get-CellDatabaseName','Get-CellPort')){
    $function=@($ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
    if($function.Count -ne 1){throw "函数定义数量异常：$name"}
    . ([scriptblock]::Create($function[0].Extent.Text))
}
try{Throw-Task31Miss 'window absent';throw '未抛出未命中例外'}
catch{
    if($_.Exception.Data['Task31Miss'] -ne $true -or $_.Exception.Message -ne 'window absent'){
        throw '未命中例外未保留专用分类与原文'
    }
}
if((Get-Task31AttemptAction -Miss $true -Result $null -Attempt 1 -Maximum 3) -ne 'retry'){throw '第1次未命中应重试'}
if((Get-Task31AttemptAction -Miss $true -Result $null -Attempt 3 -Maximum 3) -ne 'exhausted'){throw '达到上限应 INCOMPLETE'}
if((Get-Task31AttemptAction -Miss $false -Result ([pscustomobject]@{Verdict='不符'}) -Attempt 1 -Maximum 3) -ne 'record'){throw '断言失败不得重试'}
if((Get-Task31AttemptAction -Miss $false -Result ([pscustomobject]@{Verdict='执行异常'}) -Attempt 1 -Maximum 3) -ne 'record'){throw '环境异常不得重试'}
$DatabasePrefix='cangshu_task31'
$invocationId='20260926010101_12345678'
$BaseServerPort=18130
$names=@(1..3 | ForEach-Object {Get-CellDatabaseName -CellId '6-4' -Run 2 -Attempt $_})
$ports=@(1..3 | ForEach-Object {Get-CellPort -CellIndex 9 -Run 2 -Attempt $_})
if(@($names | Select-Object -Unique).Count -ne 3 -or @($ports | Select-Object -Unique).Count -ne 3){throw '重试未使用独立库名和端口'}
if(@($names | Where-Object {$_.Length -gt 63}).Count -gt 0){throw '重试库名超过63字节'}
Write-Output 'PASS task31 bounded miss retry, fail-fast, isolated attempt names/ports'
