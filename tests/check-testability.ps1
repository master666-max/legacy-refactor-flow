# check-testability.ps1 —— testability-scan.ps1 自己得能分得出"守得住 / 守不住"
# 三条设计约束（都是本仓实发过的坑）：
#   ① 反向对照必留：门只能"通过"不算证据，必须有一个夹具专门让它**判失败**（TT2/TT3）。
#   ② 阈值不许是摆设：TT-S 把阈值放大到不可能触发，判定必须翻 ⇒ 证明 verdict 真由那条规则驱动。
#   ③ 断言用增量与"当场读回"，不猜绝对计数（沙箱里本来就挂着别的件）。
param([string]$Script = "", [switch]$KeepSandbox)
$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$root = Split-Path -Parent $PSScriptRoot
if (-not $Script) { $Script = Join-Path $root "scripts\testability-scan.ps1" }
if (-not (Test-Path -LiteralPath $Script)) { Write-Host "找不到被测脚本: $Script"; exit 2 }
$Script = (Resolve-Path -LiteralPath $Script).Path

$sb = Join-Path ([System.IO.Path]::GetTempPath()) ("lrf-ttchk-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$repo = Join-Path $sb "repo"; $kit = Join-Path $repo "_refactor-kit"
$pass = 0; $bad = 0; $skip = 0
function Chk($n, $hit, $d) { if ($hit) { Write-Host ("  [OK] {0,-34} {1}" -f $n, $d); $script:pass++ } else { Write-Host ("  [X ] {0,-34} {1}" -f $n, $d); $script:bad++ } }

$sh = if ($env:OS -eq 'Windows_NT') { 'powershell' } else { 'pwsh' }
$shArgs = if ($env:OS -eq 'Windows_NT') { @('-NoProfile','-ExecutionPolicy','Bypass','-File') } else { @('-NoProfile','-File') }
function Scan($scopeRel, $extra) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $a = @($Script, '-Scope', (Join-Path $kit $scopeRel)) + $extra
        $o = & $sh ($shArgs + [string[]]$a) 2>&1 | Out-String; $rc = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    [pscustomobject]@{ rc = $rc; out = $o }
}
function Wfile($rel, $txt) {
    $p = Join-Path $repo $rel; $d = Split-Path -Parent $p
    if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    [System.IO.File]::WriteAllText($p, ($txt -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
}
function Wscope($name, $line) {
    # 用显式拼接：上一版在双引号串里写了两个反引号，反引号被转义成字面字符，
    # [scope] 那行就不再位于行首 —— 扫描器的行首正则找不到，表现成 文件不存在，很误导。
    $t = "# 界" + "`n" + $line + "`n" + "`n" + "## DoD" + "`n" + "- 用例数不减且逐条一致" + "`n"
    [System.IO.File]::WriteAllText((Join-Path $kit $name), $t, (New-Object System.Text.UTF8Encoding($false)))
}

try {
    New-Item -ItemType Directory -Force -Path $repo, $kit | Out-Null

    # 可守：3 个顶层函数 + __main__ 守卫 + 顶层可执行少
    Wfile "guardable.py" @'
import os


def one(x):
    return x + 1


def two(x):
    return x > 2


def three(a, b):
    return a == b

if __name__ == "__main__":
    print(one(1))
'@
    # 零函数（真仓 dsh-env.py 的形状：只是转调 + 守卫）
    Wfile "nofunc.py" @'
import os, sys
try:
    sys.stdout.reconfigure(errors="replace")
except Exception:
    pass
if __name__ == "__main__":
    print("shell only")
'@
    # 导入即执行自身（真仓 dsh-accept.py 的形状：1 函数、无守卫、一串顶层调用）
    Wfile "importexec.py" @'
import os, sys
def run_py(n):
    return 0
print("[1/3] step one")
rc = run_py("a.py")
print("rc", rc)
rc2 = run_py("b.py")
print("rc2", rc2)
rc3 = run_py("c.py")
print("done")
'@
    Wfile "hasfuncs.js" @'
export function alpha(x) { return x + 1 }
const beta = (y) => y > 2
async function gamma(z) { return await z }
'@
    Wfile "weird.xyz" @'
def nothing_here(): pass
'@

    Wscope "s-ok.md"     '[scope] IN_SCOPE=guardable.py'
    Wscope "s-zero.md"   '[scope] IN_SCOPE=nofunc.py'
    Wscope "s-risk.md"   '[scope] IN_SCOPE=importexec.py'
    Wscope "s-decl.md"   '[scope] IN_SCOPE=nofunc.py#process'
    Wscope "s-js.md"     '[scope] IN_SCOPE=hasfuncs.js'
    Wscope "s-odd.md"    '[scope] IN_SCOPE=weird.xyz'
    Wscope "s-missing.md" '[scope] IN_SCOPE=no-such-file.py'
    Wscope "s-empty.md"  '[scope] IN_SCOPE='
    Wscope "s-none.md"   '本文件故意没有机器可读行'

    $r = Scan "s-ok.md" @()
    Chk 'TT1 可守件判 pass' ($r.rc -eq 0 -and $r.out -match 'verdict=pass' -and $r.out -match 'ok=1') "rc=$($r.rc) ｜ $(($r.out -split "`n" | Where-Object { $_ -match '\[testability\] files=' }) -join '')"

    $r = Scan "s-zero.md" @()
    Chk 'TT2 零函数件必须判不过' ($r.rc -eq 1 -and $r.out -match 'zero-func=1' -and $r.out -match 'verdict=fail') "rc=$($r.rc)（反向对照：门能开）"

    $r = Scan "s-risk.md" @()
    Chk 'TT3 导入即执行必须判不过' ($r.rc -eq 1 -and $r.out -match 'import-exec-risk=1') "rc=$($r.rc)（1 个函数不够，无守卫+顶层一串调用＝不可守）"

    $r = Scan "s-decl.md" @()
    Chk 'TT4 标了 #process 则放过并如实标注' ($r.rc -eq 0 -and $r.out -match 'declared-process=1' -and $r.out -match '别声称造了裁判') "rc=$($r.rc)"

    $r = Scan "s-risk.md" @('-TopExecMax', '999')
    Chk 'TT-S 哨兵：阈值真在驱动判定' ($r.rc -eq 0 -and $r.out -match 'import-exec-risk=0') "放大阈值后 verdict=$($r.out -match 'verdict=pass') rc=$($r.rc)（不翻说明那条规则是摆设）"

    $r = Scan "s-js.md" @()
    Chk 'TT9 js 件按函数数判' ($r.rc -eq 0 -and $r.out -match 'ok=1' -and $r.out -match '顶层可执行=na') "rc=$($r.rc)（非 py 不参与顶层可执行判定）"

    $r = Scan "s-odd.md" @()
    Chk 'TT8 未识别语言记 unmeasured 并点名' ($r.out -match 'unmeasured=1' -and $r.out -match '无判断力') "rc=$($r.rc)（没测≠通过：交付必须写明未核）"

    $r = Scan "s-missing.md" @()
    Chk 'TT7 清单指了不存在的件' ($r.rc -eq 1 -and $r.out -match 'missing=1') "rc=$($r.rc)（不许把不存在的件当可守）"

    $r = Scan "s-empty.md" @()
    Chk 'TT6 空清单不许当过关' ($r.rc -eq 1) "rc=$($r.rc)"

    $r = Scan "s-none.md" @()
    Chk 'TT5 没有机器行要拒绝代猜（rc=2）' ($r.rc -eq 2 -and $r.out -match '拦不住东西') "rc=$($r.rc)"

    # 探针自己不许留残留文件
    $stray = @(Get-ChildItem -LiteralPath $repo -File -Force | Where-Object { $_.Name -match '^SCOPE\.md$' -and $_.LastWriteTime -gt (Get-Date).AddMinutes(-30) })
    Chk 'TT10 本自检不在靶仓留件' ($stray.Count -eq 0) "本次在 repo 根新写的意外件=$($stray.Count)"
} catch {
    Write-Host ("  [X ] 测试自身异常: " + $_.Exception.Message); $bad++
} finally {
    if ($KeepSandbox) { Write-Host "[testability] 沙箱留着：$sb" }
    elseif (Test-Path -LiteralPath $sb) { Remove-Item -LiteralPath $sb -Recurse -Force }
}
Write-Host ""
if ($bad -gt 0) { Write-Host "[testability] 失败 $bad 项 / 通过 $pass 项"; exit 1 }
if ($pass -eq 0) { Write-Host "[testability] 一项都没测成 —— 不算通过"; exit 1 }
Write-Host "[testability] 全部通过（$pass 项）。"
exit 0
