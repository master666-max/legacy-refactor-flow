<#
.SYNOPSIS
  testability-scan.ps1 —— 立界时问一句："你挑的这件，守得住吗"
.DESCRIPTION
  为什么需要它：2026-09-28 真仓实测，A 阶段按行数挑的两个 in-scope 件**根本没法造裁判** ——
    · dsh-env.py       顶层函数 0 个（只是转调壳 + main 守卫）⇒ 录不出任何期望值
    · dsh-accept.py    1 个函数但 29 条顶层可执行语句、无 __main__ 守卫 ⇒ 连"导入被测件"都会执行自身
  而这两件事，SCOPE.md 里的人读表格**拦不住**：agent 写完界照样往下走。本件把这条判断变成机器门。

  判据（对 python）：
    有可测面 = 顶层函数数 > 0 且 (有 __main__ 守卫 或 顶层可执行语句 < 5)
  非 python 只数函数（顶层可执行/守卫记 na，不参与判定）；识别不了的语言记 unmeasured，
  并在结尾**显式声明"本件对这些文件无判断力"** —— unmeasured 不算通过，也不算失败，算没测。

  ★ 这是**启发式，不是词法器/AST**：正则数行首的 def、赋值与调用。写在一行里的多个语句、
    exec 出来的代码、装饰器换行等情况会数错。所以它只配当"挑错件时喊一声"的门，
    不配当"这件被守住了"的证明 —— 守住没有证据，只有强度读数（见 mutation-probe）。

  退出码：0 = 全部有可测面；1 = 有文件没可测面；2 = SCOPE.md 里没有机器可读的 [scope] IN_SCOPE= 行
        （没这行就是**界不可核**，本件拒绝代替人猜）。

  声明"我知道它只能进程级对照"的写法：在该项后面加 #process，本件就放过它并如实标注。
    [scope] IN_SCOPE=dsh-env.py#process, dsh-fallback-heal.py
.EXAMPLE
  ./testability-scan.ps1 -Scope _refactor-kit/SCOPE.md
#>
param(
    [Parameter(Mandatory = $true)][string]$Scope,
    [string]$Repo = "",
    [int]$TopExecMax = 4          # 顶层可执行语句的上限；真仓两个实测值是 4（可守）与 29（不可守）
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

if (-not (Test-Path -LiteralPath $Scope)) { Write-Host "[testability] SCOPE 文件不存在：$Scope"; exit 2 }
$scopeFull = (Resolve-Path -LiteralPath $Scope).Path
if (-not $Repo) { $Repo = Split-Path -Parent (Split-Path -Parent $scopeFull) }   # <repo>/<kit>/SCOPE.md
$txt = [System.IO.File]::ReadAllText($scopeFull, [System.Text.Encoding]::UTF8)

$m = [regex]::Match($txt, '(?mi)^\s*\[scope\]\s+IN_SCOPE=(.*)$')
if (-not $m.Success) {
    Write-Host "[testability] SCOPE.md 里没有机器可读的 `[scope] IN_SCOPE=<逗号清单>` 行"
    Write-Host "[testability] 人读的表格拦不住东西 —— 要么补这行，要么这道门本就该停在 A"
    exit 2
}
if (-not $m.Groups[1].Value.Trim()) {
    # 与"没有这行"分开：这行在、清单空，是**故意的空**，得按空清单判，不许冒充"界不可核"
    Write-Host "[testability] IN_SCOPE 是空的 ⇒ 没东西可守，判不过"
    exit 1
}
$items = @($m.Groups[1].Value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($items.Count -eq 0) { Write-Host "[testability] IN_SCOPE 是空的 ⇒ 没东西可守，判不过"; exit 1 }

$ok = 0; $zeroFunc = 0; $importRisk = 0; $missing = 0; $unmeasured = 0; $declared = 0
$bad = New-Object System.Collections.Generic.List[string]

foreach ($raw in $items) {
    $name = ($raw -split '#')[0].Trim()
    $asProcess = ($raw -match '(?i)#process')
    $p = if ([System.IO.Path]::IsPathRooted($name)) { $name } else { Join-Path $Repo $name }
    if (-not (Test-Path -LiteralPath $p)) { $missing++; $bad.Add("$name ：文件不存在（界指了个不存在的件）"); continue }
    $body = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
    $ext = [System.IO.Path]::GetExtension($p).ToLower()
    $funcs = 0; $topExec = -1; $guard = $false; $lang = 'other'
    if ($ext -eq '.py') {
        $lang = 'py'
        $funcs  = [regex]::Matches($body, '(?m)^def\s+\w').Count
        $topExec = [regex]::Matches($body, '(?m)^(?!if\s+__name__)(for\s|while\s|print\(|with\s|try:|if\s|os\.|sys\.|subprocess|[A-Za-z_][\w]*\s*=)').Count
        $guard = ($body -match '(?m)^if\s+__name__')
    } elseif ('.js','.ts','.mjs','.cjs' -contains $ext) {
        $lang = 'js'
        $funcs = [regex]::Matches($body, '(?m)^\s{0,2}(export\s+)?(async\s+)?function\s+\w').Count +
                 [regex]::Matches($body, '(?m)^\s{0,2}(const|let)\s+\w+\s*=\s*(async\s*\(|\(|function)').Count
    }

    if ($lang -eq 'other') {
        $unmeasured++
        Write-Host ("  [无判断力] {0}（语言未识别 ⇒ 本件对它不置可否，交付里必须写明'未核'）" -f $name)
        continue
    }
    $reason = ''
    if ($funcs -eq 0) { $reason = "顶层函数 0 个 ⇒ 录不出期望值"; $zeroFunc++ }
    elseif ($lang -eq 'py' -and $topExec -gt $TopExecMax -and -not $guard) { $reason = "顶层可执行 $topExec 条且无 __main__ 守卫 ⇒ 导入即执行自身"; $importRisk++ }
    if ($reason -and $asProcess) {
        $declared++
        Write-Host ("  [进程级] {0}：{1} ⇒ 已声明只走进程级对照，本门放过，但**别声称造了裁判**" -f $name, $reason)
        if ($reason -match '函数 0') { $zeroFunc-- } else { $importRisk-- }
        continue
    }
    if ($reason) { $bad.Add("$name ：$reason") ; Write-Host ("  [不可守] {0}（{1}）" -f $name, $reason) }
    else { $ok++; Write-Host ("  [可守] {0}（lang={1} 函数={2} 顶层可执行={3} 守卫={4}）" -f $name, $lang, $funcs, $(if ($topExec -lt 0) {'na'} else {$topExec}), $guard) }
}

$verdict = if ($bad.Count -gt 0) { 'fail' } else { 'pass' }
Write-Host ("[testability] files={0} ok={1} zero-func={2} import-exec-risk={3} missing={4} unmeasured={5} declared-process={6} verdict={7}" -f `
    $items.Count, $ok, $zeroFunc, $importRisk, $missing, $unmeasured, $declared, $verdict)
if ($bad.Count -gt 0) {
    Write-Host "[testability] 挑中的件里有守不住的：换件，或在 SCOPE 里给它标 #process 并改走进程级对照。"
    foreach ($b in $bad) { Write-Host ("        - " + $b) }
    exit 1
}
Write-Host "[testability] 声明过的判定是启发式（正则数行首），不是 AST ⇒ 它能喊出'挑错件'，不能证明'这件被守住了'。"
exit 0
