# 密封式重构工作流契约（legacy-refactor-workflow/v1）

这份文档规定**什么算跑完、什么不许说**。执行器 `workflow-run.ps1` 按
`legacy-refactor-flow.workflow.json` 里的门逐条判定；不在本文件里的口头承诺不算契约。

## 1. 规范产物（canonical artifacts）

一次 run 落在 `~/.legacy-refactor-flow/runs/<projectId>/<runId>/`，**在被检仓之外**：

| 文件 | 入密封？ | 作用 |
|---|---|---|
| `run-manifest.json` | 是 | 身份：目标仓、profile、输入、三个脚本的 sha256、`confirmed` 列表、结论、停在哪个门 |
| `gates.json` | 是 | 每条门/步骤：判据、解析后的实际目标、verdict、证据尾部、实测 rc、时刻 |
| `coverage.json` | 是 | 每阶段状态 + `unknown` + `notChecked`，并钉死一条规则文本 |
| `seal.json` | — | 上面三件的 SHA-256 |
| `report.md` | **否** | 人读投影，允许事后加批注 |
| `recon-report.md`、`mutation-report.md` | 否 | 机器生成的过程报告（落 runDir，不落被检仓） |

**放置规则**：机器生成的过程报告一律落 runDir。被检仓的 `_refactor-kit/` 里只放**人写的、本来就该进仓的**东西
（`SCOPE.md`、`TRIAGE.csv`）。混放的后果不是难看，是门变噪声：实测过一次 —— recon 报告落进 kitDir
⇒ `git status` 出现未跟踪项 ⇒ 拆除阶段永远过不了，正常在改代码的仓反而被判失败。

## 2. 门与判定强度

DSL 七种判据：`exists` / `nonempty` / `matches` / `notMatches` / `cmd` / `tool` / `human`。
共 23 条门，六个阶段：A 立界(5) · B 测绘(6) · C 定活(3) · D 造裁判(4) · E 小步改(2) · T 拆除(3)。

- **机器门**只管机器能判真假的事。`cmd`/`tool` 的退出码是唯一裁判，不接受"看起来对了"。
- **人工门**（`op=human`，六条）必须 `-Confirm <阶段号>` 显式放行；没放行 ⇒ 该门 `wait` ⇒ 阶段 `partial/INCONCLUSIVE` ⇒ 退出码 3。
  `-Confirm` 是数组参数，`-File` 调用时 `A,B,C` 会作为**一个字符串**传入，执行器按逗号再切一刀。
- 子进程工作目录固定为**被检仓**（相对 `-OutFile` 与 `{testCmd}` 都在那里解析）。

**门不承诺它没做的判断。** 例：B-g4 查的是"同一份报告自相矛盾"（识别到测试却宣称从零开始），
它查不了"测试判据用错了" —— 后者写在 B-g6 人工门里。凡是把结论寄托在语义判断上的地方，都必须有人工门兜着。

## 3. 退出码

| rc | 含义 | 典型 |
|---|---|---|
| 0 | `complete`：本 profile 全部门通过（人工门已确认） | 可以按 DoD 交付 |
| 1 | `failed`：某条机器门不过 | 停在 `failAt`，不许说"改好了" |
| 2 | 用法/安装故障 | 清单缺失、profile 未知、非 dry-run 却没给 `-TestCmd`、`-VerifySeal` 没给 `-RunDir` |
| 3 | `partial/INCONCLUSIVE`：只有人工门未放行 | 补齐确认，或按未完成交付 |

**rc≠0 时交付措辞受限**：只能写"跑到 X 停住"，不能写"基本完成"。这是 coverage.json 里那条 `rule` 的落地。

## 4. 覆盖状态与 unknown

`complete` / `partial` / `unknown` / `failed` 四态，加五条不变量（见清单 `invariants`）。

**unknown ≠ 已解决。** 变异探针的名额截断、`-Targets` 没扫到的文件、`-Sweep` 明说判不了的
daemon / crontab / 用户级环境变量 / 常驻端口 / 跨仓写入 —— 全部进 `notChecked` 或 `unknown`，
绝不因为"没报问题"就当通过。D 阶段的 score 在采不满时**是抽样分**，coverage 里写明白。

还有一条同类：**跑裁判的代价**。测试命令是靶仓自带的，探针会把它重跑 N+1 遍，
它想往哪儿写就往哪儿写（实测往本机 TEMP 写了 167 个不删的空目录）。
探针量出 `temp-new=N`（排除仪器自己的 `lrf-*`），N>0 ⇒ 执行器记一条 unknown：
本机 TEMP 不在写入域登记的视野里，这些件算未清，不许念成"拆干净了"。
★ `N` 数的是"基线前后 TEMP 根里新增的条目"，**分不清是靶仓测试写的还是同时段别的进程写的**
（实测撞见过 Java 的 `hsperfdata_*`、安装器的 `*.tmp`）⇒ 归因要么看名字前缀，要么就当"未清"处理，不许替靶仓定罪。
也正因为这样，配套断言只能用**序**（写件的轮次必须明显多于不写的），不能用绝对 0 —— 活机器上 0 不稳。

## 5. 密封的语义与限度

`seal.json` = 三份语义文档的 SHA-256。核对：`-VerifySeal -RunDir <目录>`，不匹配 ⇒ rc=1。

密封**只**证明"本地这三份文件从密封之后没被改过"。它**不**是签名、**不**证明作者身份、
**不**证明某个运行时真的加载过这一版清单、**不**保证 `report.md` 未被改（那是投影，故意不入密封）。
要跨机器可信需要外部时间戳或第三方签名，本工作流没有，也不假装有。

## 6. 与密封式扫描工具的差别（诚实声明）

参照物是"阶段门 + 密封产物 + 覆盖状态"这套结构。差别：

- 本执行器**单进程前台**跑，没有常驻 job 通道 ⇒ 没有 running / cancel_requested 之类的中间态，**不支持协作取消**；
  中途关掉就是一次没有 seal 的半截 run。
- 只读状态 = `-RunDir` 单独使用（不给 `-RepoPath`），读的是已落盘的密封产物，**不是进度**；没有 `-Status` 这个开关。
- 门是**同步**判的：一条不过立刻停，不排队续跑。

## 7. 清单里声明了、但执行器暂未执行的字段

这些字段现在**只是给人与上层平台读的**，改它们不改变行为。写出来是为了别让清单变成装饰：

| 字段 | 现状 |
|---|---|
| `phases[].onFail`（`stop` / `fail-closed`） | 执行器对所有阶段一律"不过就停 + rc≠0"，两者行为**暂无差别** |
| `profiles[].budgetSec` | 未做超时，跑多久都不中止 |
| `profiles[].mutateCode` / `runTargetProject` | 未据此开关；D 阶段总是跑变异探针，`{testCmd}` 总是由用户负责 |
| `profiles[].incompleteOutcome` | 结论字符串写死在代码里（`partial/INCONCLUSIVE` / `failed`），改这里不影响输出 |
| `inputs.owner.default` | 参数 `-Owner` 存在，但 T 阶段的台账命令没把它传下去 |
| `runArtifacts.*`、`coverageStates`、`invariants` | 文档性字段，执行器不读；实际行为由代码与本文档共同约定 |

要哪个变成真机制，就在改它的同一次提交里补一条反向控制断言，别只改清单。

## 8. 反向控制（这些断言都是实测过的，不是设计意图）

| 编号 | 断言 | 实测 |
|---|---|---|
| W1 | 无人工确认 ⇒ 不得 complete | rc=3 |
| W2 | 全确认 ⇒ complete | rc=0 |
| W4 | 改 `gates.json` 一个字节 ⇒ `-VerifySeal` 必须验破 | rc=1 |
| W6 | 改 `report.md` ⇒ 密封**不该**破（设计如此） | rc=0 |
| W0 / W0b / W0d | 产物不落被检仓、不落技能仓，跑完 `git status` 干净 | 通过 |
| W0c | 工具步骤必须带输出尾部（否则失败无因可查） | detail 非空 |
| W5 | 缺 `SCOPE.md` ⇒ 停在 A-g1 | rc=1 |
| W8 | 轻量档（`-Profile gate`）能从本档第一阶段跑完；dry-run 未确认仍不出 complete | rc=0 / rc=3 |
| W9 | 矛盾门能开也能不开（拿**发布的 pattern** 打两种形状） | 说谎命中 / 诚实不命中 |

跑法：`powershell -NoProfile -File tests/check-workflow.ps1`（跑完自己打总数；需本机有 node 与 git）。
