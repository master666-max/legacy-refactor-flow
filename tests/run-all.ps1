<#
.SYNOPSIS
  run-all.ps1 —— 一次跑完六个自检，任一项非零即整体非零
.DESCRIPTION
  五项：编码不变量（含哨兵）、台账 14 步生命周期 + 租约收集器、侦察报告断言、裁判强度探针、
  工作流执行器（门会不会停、密封会不会破、产物会不会漏进被检仓/技能仓）。
  在 Windows PowerShell 5.1 下跑最有意义（编码那条故障只在该环境成立）；
  非 Windows 上退到 pwsh，编码哨兵记 SKIP。
  check-mutation 与 check-workflow 需要本机有 node（夹具是 JS）；没有则整项记 SKIP 并判不通过，不许静默变绿。
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
# 计数取自清单长度，不写死数字：往数组里加一项而文案仍写"4 / 4"，是一种自我打脸的假绿
$checks = @('check-encoding.ps1', 'check-ledger-lifecycle.ps1', 'check-recon.ps1', 'check-mutation.ps1', 'check-testability.ps1', 'check-workflow.ps1')
$total = 0
foreach ($t in $checks) {
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
$n = $checks.Count
Write-Host ""
if ($total -gt 0) { Write-Host "[run-all] $total / $n 项失败"; exit 1 }
Write-Host "[run-all] $n / $n 项通过。"
exit 0
