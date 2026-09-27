<#
.SYNOPSIS
  check-encoding.ps1 —— 编码不变量自检（对应 README「编码契约」三条）
.DESCRIPTION
  1) 仓内每个 .ps1 必须以 UTF-8 BOM 开头（Windows PowerShell 5.1 对无 BOM 文件按
     ANSI 代码页解码，中文会把语法树撞坏 —— 这是 v1.0 的开箱故障）。
  2) 每个 .ps1 必须自带 [Console]::OutputEncoding = UTF8（否则脚本输出经管道给上层
     时中文整片乱码，收尾判定读到的回执不可信）。
  3) 哨兵：把 BOM 剥掉再喂给 5.1 的解析器，必须**真的报错**。
     哨兵不成立 ⇒ 说明本文件里的检查是恒真的，不能算通过。
  只在 PS 5.1 下能跑哨兵；pwsh 7 永远按 UTF-8 读，构造不出该故障，会记 SKIP。
.EXAMPLE
  powershell -NoProfile -File tests/check-encoding.ps1
#>
param(
    [string]$Repo = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$fail = 0
$skip = 0
function Say($tag, $msg) { Write-Host ("  [{0}] {1}" -f $tag, $msg) }

if (-not (Test-Path -LiteralPath $Repo)) { Write-Host "路径不存在: $Repo"; exit 2 }
$root = (Resolve-Path -LiteralPath $Repo).Path
$ps1s = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.ps1 -Force |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } | Sort-Object FullName)

Write-Host ("[encoding] 仓 = {0}，.ps1 共 {1} 个" -f $root, $ps1s.Count)
if ($ps1s.Count -eq 0) { Write-Host "[encoding] 一个 .ps1 都没找到，无从检查。"; exit 2 }

$isWin = ($env:OS -eq 'Windows_NT')
$canSentinel = ($PSVersionTable.PSVersion.Major -eq 5)

foreach ($f in $ps1s) {
    Write-Host ("")
    Say "---" $f.Name
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $rel = $f.FullName.Replace($root, "").TrimStart('\', '/')

    # 1) BOM（且只许一个 —— 双 BOM 会让"带 BOM"这条通过，却把第二个 BOM 留成内容）
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        if ($bytes.Length -ge 6 -and $bytes[3] -eq 0xEF -and $bytes[4] -eq 0xBB -and $bytes[5] -eq 0xBF) {
            Say "X" "双 BOM：第 4~6 字节又是 EF BB BF，第二个会当成正文内容"; $fail++
        } else { Say "OK" "带且只带一个 UTF-8 BOM" }
    } else { Say "X" "缺 BOM（前三字节 = $(if($bytes.Length -ge 3){('{0:X2} {1:X2} {2:X2}' -f $bytes[0],$bytes[1],$bytes[2])}else{'不足 3 字节'})），PS 5.1 下会 ParserError"; $fail++ }

    # 2) 输出编码守卫
    $txt = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($txt -match '\[Console\]::OutputEncoding\s*=\s*\[System\.Text\.Encoding\]::UTF8') {
        Say "OK" "自带 OutputEncoding=UTF8 守卫"
    } else { Say "X" "缺 OutputEncoding 守卫（管道里中文会变 GBK 字节）"; $fail++ }

    # 3) 工作树换行符（eol=crlf 只在 Windows 检出时生效）
    if ($isWin) {
        $crlf = 0; $lone = 0
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -eq 10) { if ($i -gt 0 -and $bytes[$i-1] -eq 13) { $crlf++ } else { $lone++ } }
        }
        if ($lone -eq 0 -and $crlf -gt 0) { Say "OK" "工作树全 CRLF（$crlf 行）" }
        else { Say "X" "工作树混用换行：CRLF=$crlf 裸LF=$lone"; $fail++ }
    } else { Say "SKIP " "非 Windows 检出，eol=crlf 不适用"; $skip++ }

    # 4) 哨兵：剥 BOM 后 5.1 解析器必须报错，否则这条检查是恒真的
    if (-not $canSentinel) {
        Say "SKIP " "哨兵需 Windows PowerShell 5.1（当前 $($PSVersionTable.PSVersion)），pwsh 7 构造不出该故障"
        $skip++
        continue
    }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("lrf-nobom-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".ps1")
    try {
        $body = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF) { $bytes[3..($bytes.Length-1)] } else { $bytes }
        [System.IO.File]::WriteAllBytes($tmp, [byte[]]$body)
        $tok = $null; $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$tok, [ref]$errs)
        $ne = @($errs).Count
        $hasNonAscii = $false
        foreach ($ch in [char[]]$txt) { if ([int]$ch -gt 127) { $hasNonAscii = $true; break } }
        if ($ne -gt 0) {
            Say "OK" "哨兵成立：剥 BOM 后解析器报 $ne 处错 ⇒ 本项检查不是恒真"
        } elseif ($hasNonAscii) {
            Say "X" "哨兵不成立：含非 ASCII 却没有 BOM，解析器竟然没报错 —— 检查失去效力"
            $fail++
        } else {
            Say "SKIP " "全 ASCII 文件，剥 BOM 不影响解析，本文件无从证伪"
            $skip++
        }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
}

Write-Host ("")
if ($fail -gt 0) { Write-Host "[encoding] 失败：$fail 项，另有 SKIP $skip"; exit 1 }
Write-Host "[encoding] 全部通过（SKIP $skip 项，均因当前环境构造不出该故障）。"
exit 0
