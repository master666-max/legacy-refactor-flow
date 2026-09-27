<#
.SYNOPSIS
  check-ledger-lifecycle.ps1 —— hooks-ledger.ps1 的 14 步全生命周期断言
.DESCRIPTION
  在 %TEMP% 里造一个一次性沙箱（绝不碰真仓库），把台账工具从登记跑到拆除再跑到验证。
  含**反向用例**：文件被改写却没拆除时 -Verify 必须返回非零；.git/hooks 里有门时
  -Sweep 必须返回非零。只有正向用例的检查是恒真的，抓不到"拆除根本没生效"。
  沙箱跑完即删，不留残留。
.EXAMPLE
  powershell -NoProfile -File tests/check-ledger-lifecycle.ps1
  pwsh -NoProfile -File tests/check-ledger-lifecycle.ps1
#>
param(
    [string]$Script = "",
    [switch]$KeepSandbox
)
$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$root = Split-Path -Parent $PSScriptRoot
if (-not $Script) { $Script = Join-Path $root "scripts\hooks-ledger.ps1" }
if (-not (Test-Path -LiteralPath $Script)) { Write-Host "找不到被测脚本: $Script"; exit 2 }
$Script = (Resolve-Path -LiteralPath $Script).Path

$sb = Join-Path ([System.IO.Path]::GetTempPath()) ("lrf-sandbox-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$repo = Join-Path $sb "repo"; $kit = Join-Path $sb "kit"
$ledger = Join-Path $kit "hooks.json"; $backup = Join-Path $kit "backup\.mcp.json"
New-Item -ItemType Directory -Force -Path (Join-Path $repo "src"), $kit, (Split-Path -Parent $backup) | Out-Null

$pass = 0; $bad = 0
# 子进程用哪个 shell：Windows 上按 5.1 测（那才是出事的环境），其它平台退回 pwsh
$sh = if ($env:OS -eq 'Windows_NT') { 'powershell' } else { 'pwsh' }
$shArgs = @('-NoProfile','-File')
if ($env:OS -eq 'Windows_NT') { $shArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File') }
function HashOf($p) { if (-not (Test-Path -LiteralPath $p)) { return "" }; (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }
$gate = Join-Path (Join-Path (Join-Path $repo '.git') 'hooks') 'pre-commit'
function Step($want, $name, [string[]]$args_) {
    # 子进程往 stderr 写东西不该把整个 harness 掐死：这里临时放宽，退出码才是判据
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $sh ($shArgs + [string[]]@($Script)) @args_ 2>&1 | Out-String }
    finally { $ErrorActionPreference = $prev }
    $rc = $LASTEXITCODE
    $hit = ($rc -eq $want)
    if ($hit) { $script:pass++ } else { $script:bad++ }
    Write-Host ("  [{0}] {1,-30} rc={2} (期望 {3})" -f ($(if($hit){"OK"}else{"X"})), $name, $rc, $want)
    if (-not $hit) { ($out -split "`r?`n" | Where-Object { $_ } | Select-Object -First 5 | ForEach-Object { Write-Host ("        | " + $_) }) }
    return $out
}
try {
    # ---- 沙箱：一个 git 仓 + 一个"会被改写的配置文件" + 一个已装的 git 门 ----
    Set-Content -LiteralPath (Join-Path $repo "src\app.py") -Value "x = 1" -Encoding UTF8
    $baseline = '{"mcpServers":{}}' + [Environment]::NewLine
    Set-Content -LiteralPath (Join-Path $repo ".mcp.json") -Value $baseline.TrimEnd() -Encoding ASCII
    $gitExe = Get-Command git -ErrorAction SilentlyContinue
    if ($gitExe) {
        & git init -q $repo 2>&1 | Out-Null
        & git -C $repo add -A 2>&1 | Out-Null
        & git -C $repo -c user.email=t@t -c user.name=t commit -q -m "seed" 2>&1 | Out-Null
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $gate) | Out-Null
    Set-Content -LiteralPath $gate -Value "#!/bin/sh`necho gate" -Encoding ASCII

    # 关键：备份存基线，随后把真文件改成**确实不同**的内容。
    # 若改写与基线一字不差，-Verify 报"已还原"就是真话，整条反向用例白测。
    Copy-Item -LiteralPath (Join-Path $repo ".mcp.json") -Destination $backup -Force
    $hBase = HashOf $backup
    Set-Content -LiteralPath (Join-Path $repo ".mcp.json") -Value '{"mcpServers":{"evil":{"command":"node"}}}' -Encoding ASCII
    $hDirty = HashOf (Join-Path $repo ".mcp.json")
    if ($hBase -eq $hDirty) { Write-Host "  [X] 夹具失效：改写后与基线同哈希，反向用例无从成立"; exit 1 }
    Write-Host ("[lifecycle] 脚本 = {0}" -f $Script)
    Write-Host ("[lifecycle] 夹具真值：基线 {0} / 改写 {1}" -f $hBase.Substring(0,16), $hDirty.Substring(0,16))

    Step 0  "1 干净态 Verify"        @('-Ledger', $ledger, '-Verify') | Out-Null
    Step 0  "2 Register modified"    @('-Ledger', $ledger, '-Register','-Kind','config','-Path',(Join-Path $repo ".mcp.json"),'-Action','modified','-Backup',$backup) | Out-Null
    Step 1  "3 未拆除 Verify 应拦"    @('-Ledger', $ledger, '-Verify') | Out-Null
    Step 0  "4 Teardown 预演"        @('-Ledger', $ledger, '-Teardown') | Out-Null
    if ((HashOf (Join-Path $repo ".mcp.json")) -ne $hDirty) { Write-Host "  [X] 预演改了东西（不该改）"; $bad++ } else { Write-Host "  [OK] 预演未动文件"; $pass++ }
    Step 0  "5 Teardown -Apply"      @('-Ledger', $ledger, '-Teardown','-Apply') | Out-Null
    if ((HashOf (Join-Path $repo ".mcp.json")) -eq $hBase) { Write-Host "  [OK] 文件真还原成基线"; $pass++ } else { Write-Host "  [X] 声称拆了，哈希却对不上"; $bad++ }
    Step 0  "6 拆后 Verify 应绿"      @('-Ledger', $ledger, '-Verify') | Out-Null

    # created 类：拆除 = 真删
    $dir = Join-Path $kit "scratch-dir"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Step 0  "7 Register created dir" @('-Ledger', $ledger, '-Register','-Kind','dir','-Path',$dir,'-Action','created') | Out-Null
    Step 1  "8 未拆 created 应拦"     @('-Ledger', $ledger, '-Verify') | Out-Null
    Step 0  "9 Teardown -Apply"      @('-Ledger', $ledger, '-Teardown','-Apply') | Out-Null
    if (Test-Path -LiteralPath $dir) { Write-Host "  [X] 台账说拆了，目录还在"; $bad++ } else { Write-Host "  [OK] 目录真被删"; $pass++ }
    Step 0  "10 拆后 Verify"          @('-Ledger', $ledger, '-Verify') | Out-Null
    $lst = Step 0 "11 List"           @('-Ledger', $ledger, '-List')
    # 这里只断言**条数与路径**，不断言中文：自检进程自己设过 UTF-8 码页，而
    # SetConsoleOutputCP 作用于整个控制台，子进程继承之后"没守卫也能出对的中文"，
    # 拿 '已拆' 这种字样当判据就是恒真。守卫本身由 check-encoding.ps1 按字节查。
    $listed = @($lst -split "`r?`n" | Where-Object { $_ -match '\.mcp\.json|scratch-dir' })
    if ($listed.Count -eq 2) { Write-Host "  [OK] List 列出 2 条"; $pass++ } else { Write-Host "  [X] List 只列出 $($listed.Count) 条（期望 2）"; $bad++ }
    Step 1  "12 Sweep 见 git 门应拦"  @('-Ledger', $ledger, '-Sweep','-Repo',$repo) | Out-Null
    Remove-Item -LiteralPath $gate -Force
    Step 0  "13 Sweep 清门后应绿"     @('-Ledger', $ledger, '-Sweep','-Repo',$repo) | Out-Null
    Step 2  "14 无子命令给用法"        @('-Ledger', $ledger) | Out-Null
} finally {
    if ($KeepSandbox) { Write-Host "[lifecycle] 沙箱留着：$sb" }
    elseif (Test-Path -LiteralPath $sb) { Remove-Item -LiteralPath $sb -Recurse -Force }
}
Write-Host ("")
if ($bad -gt 0) { Write-Host "[lifecycle] 失败 $bad 项 / 通过 $pass 项"; exit 1 }
Write-Host "[lifecycle] 全部通过（$pass 项）。"
exit 0
