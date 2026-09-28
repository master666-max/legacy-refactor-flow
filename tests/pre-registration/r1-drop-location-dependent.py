# -*- coding: utf-8 -*-
# R1 第二道稳定化：把**位置依赖**的用例挑出来丢掉并计数。
# 判据（跑前定死）：期望值里出现"本次沙箱仓的绝对路径"或任意盘符绝对路径 ⇒ 这条测试换目录就失效 ⇒ 丢。
# ★ 光"原地绿"不算数：丢掉之后要把整个仓复制到一个新目录再跑一遍，两边都绿才算过基线。
#   （这条准入门是 2026-09-28 实测补的：141 条里有 4 条期望值录进了绝对路径，
#     其中 1 条含本沙箱仓路径、3 条含别的盘符路径 —— 原地全绿，换个目录就全红。）
#
# 用法：python -X utf8 r1-drop-location-dependent.py <生成的测试文件> [复验用的新目录]
import ast, io, json, os, re, shutil, subprocess, sys

TARGET = os.path.realpath(sys.argv[1])
REPO = os.path.dirname(TARGET)
MODULE = os.path.splitext(os.path.basename(TARGET))[0]   # ★ 从文件名推，别写死上一轮那个 char_dsh_env
ALT = os.path.realpath(sys.argv[2]) if len(sys.argv) > 2 else os.path.join(
    os.environ.get("TEMP", "/tmp"), "lrf-r1-alt-%d" % os.getpid())   # ★ 每次换个名字，别复用可能有锁的旧目录

src = io.open(TARGET, encoding="utf-8").read()
i = src.index("CASES = "); j = src.index("\n", i)
cases = ast.literal_eval(src[i + 8:j])

pathish = re.compile(re.escape(REPO).replace("\\\\", "[\\\\/]"), re.I)
driveabs = re.compile(r"[A-Za-z]:[\\\\/]", re.I)

kept, dropped = [], []
for idx, c in enumerate(cases):
    expect = repr(c)
    hit = None
    if pathish.search(expect):
        hit = "含本沙箱仓路径"
    elif driveabs.search(expect):
        hit = "含任意盘符绝对路径"
    if hit is None:
        kept.append(c)                 # ★ 存**原始用例元组**，别把 (idx, c, hit) 塞进 CASES
    else:
        dropped.append((idx, c, hit))

def save(s2, cases2):
    a = s2.index("CASES = "); b = s2.index("\n", a)
    return s2[:a] + "CASES = " + repr(cases2) + s2[b:]

io.open(TARGET, "w", encoding="utf-8", newline="\n").write(save(src, kept))

def run_in(d):
    p = subprocess.run([sys.executable, "-X", "utf-8", "-m", "unittest", MODULE],
                       cwd=d, capture_output=True, text=True, encoding="utf-8", errors="replace")
    tail = [l for l in ((p.stdout or "") + (p.stderr or "")).splitlines() if l.strip()]
    return p.returncode, (tail[-2:] if tail else ["无输出"])

rc_here, out_here = run_in(REPO)

if os.path.exists(ALT):
    shutil.rmtree(ALT)      # ★ 存在才删（新名字本来就不存在，删它反而抛 FileNotFound）；不写 ignore_errors，删不掉要出声
shutil.copytree(REPO, ALT)
rc_alt, out_alt = run_in(ALT)

print(json.dumps({
    "录了多少": len(cases), "丢掉(位置依赖)": len(dropped), "留下": len(kept),
    "丢掉的是哪些函数": sorted({c[1][0] for c in dropped})[:10],
    "原因分布": {"含本沙箱仓路径": sum(1 for c in dropped if c[2] == "含本沙箱仓路径"),
             "含任意盘符绝对路径": sum(1 for c in dropped if c[2] == "含任意盘符绝对路径")},
    "原地跑": [rc_here, out_here],
    "换目录跑": [rc_alt, out_alt],
    "两边都绿": rc_here == 0 and rc_alt == 0,
    "ALT 目录": ALT,
}, ensure_ascii=False, indent=1))
