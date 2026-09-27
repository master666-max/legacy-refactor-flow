<#
.SYNOPSIS
  run-all.ps1 —— 一次跑完三个自检，任一项非零即整体非零
.DESCRIPTION
  三项：编码不变量（含哨兵）、台账 14 步生命周期、侦察报告七条断言。
  在 Windows PowerShell 5.1 下跑最有意义（编码那条故障只在该环境成立）；
  pwsh 7 下也能跑，编码哨兵会记 SKIP。
.EXAMPLE
  powershell -NoProfile -File tests/run-all.ps1
#>
param([switch]$KeepSandbox)
$ErrorActionPreference = "Continue"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$here = $PSScriptRoot
$sh = if ($env:OS -eq 'Windows_NT') { 'powershell' } else { 'pwsh' }
$shArgs = if ($env:OS -eq 'Windows_NT') { @('-NoProfile','-ExecutionPolicy','Bypass','-File') } else { @('-NoProfile','-File') }

Write-Host "[run-all] 宿主 = $sh，当前 PSVersion = $($PSVersionTable.PSVersion)"
$total = 0
foreach ($t in @('check-encoding.ps1', 'check-ledger-lifecycle.ps1', 'check-recon.ps1')) {
    $p = Join-Path $here $t
    Write-Host ""
    Write-Host "════════════════ $t"
    $a = $shArgs + @($p)
    if ($KeepSandbox) { $a += '-KeepSandbox' }
    & $sh $a
    $rc = $LASTEXITCODE
    if ($rc -ne 0) { $total++ }
    Write-Host "──────────────── $t → rc=$rc"
}
Write-Host ""
if ($total -gt 0) { Write-Host "[run-all] $total / 3 项失败"; exit 1 }
Write-Host "[run-all] 3 / 3 项通过。"
exit 0
