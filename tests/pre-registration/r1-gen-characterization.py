# -*- coding: utf-8 -*-
# R1 夹具第一步：给一个模块**从真实运行**造特征测试（期望值一个都不许我手写）。
# 三条自订规矩：
#   ① 副作用全桩并记账（桩清单同时写进生成的测试文件，保证采集与复现同环境）；
#   ② 同一调用连跑两遍，结果不一致（时间/pid/随机名）直接丢弃 —— 否则测试集天生就红，分数毫无意义；
#   ③ 生成的测试用 os.getcwd() 找模块，**不写死路径**：变异探针是在临时副本里跑的，
#      写死原仓路径就会一直在测"没被改过的那份"，那是假实验。
#
# 用法：python -X utf8 r1-gen-characterization.py <目标仓> <模块名> <输出测试文件>
import inspect, io, json, os, socket, subprocess, sys, time

REPO = os.path.realpath(sys.argv[1])
MOD = sys.argv[2]
OUT = os.path.realpath(sys.argv[3])
os.chdir(REPO); sys.path.insert(0, REPO)

STUB_SRC = '''
import os, socket, subprocess, sys, time
class SideEffect(Exception): pass
def _blocked(*a, **k): raise SideEffect("桩：真实副作用被阻断")
def _apply_stubs():
    subprocess.run = _blocked; subprocess.Popen = _blocked
    subprocess.check_output = _blocked; subprocess.check_call = _blocked
    socket.socket.connect = _blocked; socket.socket.bind = _blocked
    os.kill = _blocked; time.sleep = lambda s: None
    os._exit = lambda c=0: None
    for m in ("winreg", "webbrowser"):
        try:
            mod = __import__(m)
            if m == "winreg":
                for f in ("SetValueEx", "CreateKey", "DeleteKey", "OpenKey"):
                    if hasattr(mod, f): setattr(mod, f, _blocked)
            else:
                mod.open = lambda *a, **k: False
        except Exception:
            pass
_apply_stubs()
'''
import subprocess as _sp_mod
_real_run = _sp_mod.run          # 留着做对照；实际用 _real_Popen（见 stable 里的注释）
_real_Popen = _sp_mod.Popen      # ★ 打桩前抓住真的 Popen 类本体：属性查找每次现查，桩拦不住它
_PIPE = _sp_mod.PIPE
_DEVNULL = _sp_mod.DEVNULL
ns = {}
exec(compile(STUB_SRC, "<stubs>", "exec"), ns)
Blocked = ns["SideEffect"]

def stable(fn, args):
    # ★ 每次调用都在**独立子进程**里跑两遍并比逐字输出。
    #   在同一个进程里"按导入顺序挨个调一遍"会把前面调用的副作用带进后面的期望值里
    #   ——实测：那样录出来的 151 条里，跑第二遍时有 6 条对不上（状态污染 + 时间/pid 混入）。
    import subprocess as sp
    code = ("import os,sys;sys.path.insert(0,os.getcwd());"
            "exec(%r);"
            "import importlib,io;M=importlib.import_module(%r);"
            "fn=getattr(M,%r)\nargs=eval(%r)\nline=None\n"
            "buf=io.StringIO();old=sys.stdout;sys.stdout=buf\n"
            "try:\n    r=fn(*args);line='V'+repr(r)\n"
            "except BaseException as e:\n    line='R'+type(e).__name__\n"
            "finally:\n    sys.stdout=old\n"
            "sys.__stdout__.write(line+chr(10))" % (STUB_SRC, MOD, fn.__name__, repr(list(args))))
    outs = []
    for _ in range(2):
        # ★ 用 subprocess.Popen（模块属性每次现查，桩装不进真正的类）——
        #   sp.run 走的是 subprocess 模块**全局作用域**里的 Popen，而那个位置正是我打桩的靶子，
        #   所以"抓住真 run"也没用：它内部照样撞上桩。（这是本轮第三次被自己的桩拦下，两次都记进结论）
        with _real_Popen([sys.executable, "-X", "utf8", "-c", code], cwd=REPO,
                         stdout=_PIPE, stderr=_PIPE, text=True, encoding="utf-8", errors="replace") as ph:
            sout, serr = ph.communicate()
        p = type("R", (), {"stdout": sout or "", "stderr": serr or "", "returncode": ph.returncode})()
        line = (p.stdout or "").strip().splitlines()
        pick = [l for l in line if l[:1] in ("V", "R")]
        es = (p.stderr or "").strip().splitlines()
        outs.append(pick[-1] if pick else "E" + str(p.returncode) + "|" + (es[-1][:90] if es else "无 stderr"))
    if outs[0] != outs[1] or outs[0][0] == "E":
        return None
    return ("value", outs[0][1:], "") if outs[0][0] == "V" else ("raises", outs[0][1:], "")

def argsets(na):
    if na == 0:
        return [()]
    pool = [[0], [1], [-1], ["x"], [""], [True], [None], [[], [1]]]
    return [tuple(v * na) for v in pool[:6]]

mod = __import__(MOD)
keep, skip = [], []
for name, fn in sorted(vars(mod).items()):
    if name.startswith("_") or not inspect.isfunction(fn) or fn.__module__ != MOD:
        continue
    try:
        sig = inspect.signature(fn)
    except Exception:
        continue
    na = len([p for p in sig.parameters.values() if p.kind in (p.POSITIONAL_OR_KEYWORD, p.POSITIONAL_ONLY)])
    if na > 2:
        skip.append((name, "参数多于 2 个，本轮不构造对象")); continue
    for a in argsets(na):
        r = stable(fn, list(a))
        if r is None:
            skip.append((name + repr(a), "两遍不一致 ⇒ 非确定，丢弃")); continue
        kind, val, printed = r
        if kind == "raises" and val in ("SideEffect", "SystemExit", "KeyboardInterrupt"):
            skip.append((name + repr(a), "被桩挡住 / 会退出进程")); continue
        keep.append((name, repr(a), kind, val))

with io.open(OUT, "w", encoding="utf-8", newline="\n") as fp:
    fp.write("# -*- coding: utf-8 -*-\n")
    fp.write("# 特征测试（R1 夹具）。期望值全部来自真实运行：录值 = 连调两遍取一致结果，\n")
    fp.write("# 不一致 / 被桩挡住 / 会退出进程的一律不收。断言的是\"现在就是这样\"，不含\"应该这样\"。\n")
    fp.write("import importlib, io, os, sys, unittest\n")
    fp.write(STUB_SRC)
    fp.write("sys.path.insert(0, os.getcwd())   # ★ 跟着当前目录走：变异探针在临时副本里跑\n")
    fp.write("M = importlib.import_module(%r)\n" % MOD)
    fp.write("CASES = %s\n" % repr(keep))
    fp.write('''
class Characterization(unittest.TestCase):
    pass

def make(name, args_repr, kind, expect):
    def t(self):
        fn = getattr(M, name)
        args = eval(args_repr)
        buf = io.StringIO(); old = sys.stdout; sys.stdout = buf
        try:
            r = fn(*args)
            if kind == "raises":
                self.fail("本应抛 " + expect + " 却没抛")
            self.assertEqual(repr(r), expect)
        except BaseException as e:
            if kind == "raises":
                self.assertEqual(type(e).__name__, expect)
            else:
                raise
        finally:
            sys.stdout = old
    return t

for i, c in enumerate(CASES):
    setattr(Characterization, "test_%03d" % i, make(*c))

if __name__ == "__main__":
    unittest.main(verbosity=1)
''')
print(json.dumps({"module": MOD, "收了": len(keep), "丢弃": len(skip),
                  "丢弃样例": [s[0] + " — " + s[1] for s in skip[:6]], "测试文件": OUT}, ensure_ascii=False, indent=1))
