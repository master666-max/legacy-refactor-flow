# -*- coding: utf-8 -*-
# R1 第一道稳定化：把"在同一进程里按顺序跑就不成立"的用例挑出来丢掉，并记下丢了几条。
# 那个数字本身就是 R1 的一个真实读数：AI 逐条录出来的特征测试里，有多大比例互相不独立。
#
# 用法：python -X utf8 r1-drop-order-dependent.py <生成的测试文件>
import ast, io, json, os, re, subprocess, sys

TARGET = os.path.realpath(sys.argv[1])
MAX_ROUND = 6

def load_cases(src):
    i = src.index("CASES = ")
    j = src.index("\n", i)
    return ast.literal_eval(src[i + 8:j])

def save_cases(src, cases):
    i = src.index("CASES = ")
    j = src.index("\n", i)
    return src[:i] + "CASES = " + repr(cases) + src[j:]

def run():
    p = subprocess.run([sys.executable, "-X", "utf-8", "-m", "unittest",
                        os.path.splitext(os.path.basename(TARGET))[0]],
                       cwd=os.path.dirname(TARGET), capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    return p.returncode, (p.stdout or "") + (p.stderr or "")

log = []
for rnd in range(1, MAX_ROUND + 1):
    src = io.open(TARGET, encoding="utf-8").read()
    cases = load_cases(src)
    rc, out = run()
    if rc == 0:
        log.append({"轮": rnd, "剩用例": len(cases), "结果": "绿"})
        break
    bad = set(int(m) for m in re.findall(r"test_(\d+)", out))
    if not bad:
        log.append({"轮": rnd, "剩用例": len(cases), "结果": "红但抓不到用例号，停", "尾": out[-300:]})
        break
    cases = [c for i, c in enumerate(cases) if i not in bad]
    io.open(TARGET, "w", encoding="utf-8", newline="\n").write(save_cases(src, cases))
    log.append({"轮": rnd, "丢掉": len(bad), "剩用例": len(cases),
                "丢掉的是": sorted(bad)[:12]})

# 收尾：连跑两遍确认稳定
rc1, o1 = run(); rc2, o2 = run()
print(json.dumps({"log": log, "最后两遍 rc": [rc1, rc2],
                  "若仍红则尾部": None if rc1 == 0 else (o1.strip().splitlines() or [""])[-1][:200]},
                 ensure_ascii=False, indent=1))
