# 预注册实验的仪器（R1）

这三份 `.py` 是 **R1 的仪器**，不是本 skill 的自测。区别很重要：

- `tests/*.ps1`（`run-all.ps1` 那 5 项）**不需要外部靶子**，从 GitHub 新克隆就能全绿。
- 本目录要**你给它一个真实仓**才有意义 —— R1 问的就是"AI 对着真仓自造的特征测试，当裁判够不够格"，
  没有真仓就没有这个问题。所以它们**没接进 `run-all.ps1`**，别指望克隆后跑自测能复现下面的读数。

## 要回答的问题与判据（跑前钉死，不许跑后改）

预注册假设：**AI 逐条从真实运行录出来的特征测试，抓不住多数语义改动**。
判据按方案 A 钉：20 个破坏点里**抓到 ≤ 11 即假设成立**（与假设同向）。全文见仓外文档
《第一性原理审视-legacy-refactor-flow-与预注册-20260928》。

## 四步复现（每步的产物都是下一步的输入）

```powershell
# 0) 靶仓只读复制一份到沙箱，别在原仓上动
$sb = "$env:TEMP\lrf-r1-repro"

# 1) 从真实运行录期望值（期望值一个都不许手写）→ 生成 char_<模块>.py
python -X utf8 tests/pre-registration/r1-gen-characterization.py $sb <模块名> $sb\char_<模块>.py

# 2) 丢掉"在同一进程里按顺序跑就不成立"的用例，并计数
python -X utf8 tests/pre-registration/r1-drop-order-dependent.py $sb\char_<模块>.py

# 3) 丢掉期望值里录进绝对路径的用例，并把整仓复制到新目录复验：两边都绿才叫过基线
python -X utf8 tests/pre-registration/r1-drop-location-dependent.py $sb\char_<模块>.py

# 4) 主测臂：拿这份测试当裁判，往沙箱副本里注破坏点
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/mutation-probe.ps1 `
  -Repo $sb -TestCmd "python -X utf8 -m unittest char_<模块>" -Targets <文件名>.py -MaxMutants 20 `
  -OutFile $sb\r1.md
```

两个反照臂（用来证明"这个分不是仪器坏了"）：

- **空测试集**：把第 4 步的 `-TestCmd` 换成一个不含任何用例的命令 ⇒ 得分必须 **0.00**。
  跑到 0.00 说明这 20 个破坏点**真的改变了行为**，只是裁判没看见。
- **该仓自带测试**：`-TestCmd` 换成仓里原有的测试命令 ⇒ 与自造那份同档比较。

## 已取到的读数（靶：`master666-max/dsh-launcher` @ `cc29041`，文件 `dsh_env.py`）

| | 录制 | 去顺序依赖 | 去位置依赖 | 主测得分 |
|---|---|---|---|---|
| 2026-09-28 首次 | 151 | 145（丢 6） | 141（丢 4） | `score=0.15 killed=3 total=20 avail=108 uncov=88` |
| 2026-09-28 复算（本目录这套脚本原样重跑） | 150 | 143（丢 7） | 141（丢 2） | 机器行**逐字相同** `score=0.15 killed=3 total=20 avail=108 uncov=88` |

两件事必须分开说：

1. **分数可复现**，机器行 `score/killed/total/avail/uncov` 五项一致。
2. **漏斗不可复现** —— 三步计数每次都不完全一样（录制 151/150、丢 6/7、丢 4/2）。
   原因在第 1 步：录值靠"连调两遍比逐字"，某个调用恰好那一轮两遍不一致就被丢掉。
   ⇒ 报"丢了 N 条顺序依赖"这类**过程数**时要带上当轮口径，别写成常量。
   本轮两次漏斗都收在 141，是巧合，不是设计。

抽样口径照旧：候选点 108，本轮采 20，`uncov=88` ⇒ 这是**抽样分**，不许外推成"全仓裁判只有四成威力"。

**破坏点的类别口径**（引用 `0.15` 时必须带上）：R1 设计要五类破坏点（边界值／取反／常数±1／交换参数序／改异常类型），
而 `scripts/mutation-probe.ps1` 的内置规则只认 `>= > <= < == != === !== True False true false` 这些记号 ⇒ **只造得出前两类**。
所以 `0.15` 是"两类破坏点上的裁判强度"，不是五类。两臂（自造测试 vs 自带测试）用的是同一套破坏点，**方向性结论不受影响**，
但绝对数不许说成"五类都只抓一成"。补另三类要上 Stryker/mutmut 级别的工具，本仓未驱动它（见主 README「下限证据」）。

## 这三份仪器自己绊倒过的地方（都是实发，不是设想）

- 抓真 `subprocess.run` 照样撞上自己的桩：`run` 内部查的是模块全局作用域里的 `Popen`，那正是桩的位置。
  ⇒ 改用打桩前抓到的 `Popen` **类本体**。
- 为了吞函数噪音重定向 `sys.stdout`，把自己那行结果标记一起吞了（表现：子进程 rc=0、stdout 空 ⇒ 全部用例被丢）。
  ⇒ 结果走 `sys.__stdout__`。
- `stderr` 丢进 `DEVNULL` = 烧掉案发现场，剩下的只有 rc。⇒ 一律 `PIPE` 并保留末行。
- `shutil.rmtree(ignore_errors=True)` 把"删不干净"咽掉，下一步假报目录已存在；反过来无脑 `rmtree` 新名字又抛 `FileNotFound`。
  ⇒ 存在才删，且不吞错。
- 过滤后往 `CASES` 里塞了 `(idx, case, 原因)` 三元组 ⇒ 生成的测试 `TypeError`。⇒ 只存原始用例元组。
- 本目录第三份脚本从**文件名**推 unittest 模块名；上一轮的一次性版本写死了 `char_dsh_env`，
  换靶模块就会静默跑错对象 —— 这条改动是复算时才发现需要的，也是复算能跑通的前提。
