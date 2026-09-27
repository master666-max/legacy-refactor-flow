# legacy-refactor-flow

> 遗留系统重构的通用流程 skill —— **自带强制拆除，用完不留钩子。**

用于把「没人懂 + 没测试 + 可能是 AI 写的屎山」安全改造的 agent skill。基于 2026 年的实证研究与社区十年积累的方法整理而成。

## 它解决什么

LLM 编码 agent 掉进遗留系统的根本原因不是智力不足，而是**上下文碎片化与 token 预算耗尽**。所以本 skill 的重点不是「让 AI 更聪明」，而是三件事：

1. **先造裁判，再动代码** —— 没有可验证的变更探测器，任何改动都是赌博。
2. **先减量，再重构** —— 真屎山里常有相当比例是死代码（坊间流传 40%~70%，**本仓未复核到可引来源，当经验区间用**）；删掉不需要理解的代码，是零风险、最高回报的一步。
3. **AI 提出假设，运行负责裁决** —— 永远不让模型凭「理解」手写测试期望值。

## 附加硬约束：用完必须拆干净

本 skill **不允许留下任何持续性钩子**。流程中创建的任何跨会话 / 跨进程 / 跨仓库生效的东西（MCP 注册、git hook、CI 门、常驻索引、daemon、环境变量、后台任务）都必须：

- 在**创建的同一刻**登记进台账（含原文件 SHA256 备份），并给一条**租约**（`-TTLHours`）
- 收尾时 `-Teardown` 预演 → `-Teardown -Apply` 执行 → `-Verify` 逐条核对
- `-Verify` 任一未清干净即返回非零退出码，无法在绿色下蒙混过关
- 发起方半路死了也有人来收：`-Collect` 列出租约过期的孤儿（默认干跑），`-Collect -Apply` 才真拆；
  **没设租约的条目永远不算孤儿**，误删比漏删严重

## 流程

```
A 立界 → B 测绘 → C 定活 → D 造裁判 → E 小步改
```

A~D 是纯投入期，**一行业务代码都不改**。跳过 D 直接进 E，等于在没有探测器的情况下改代码——
下面提到的 39.4% 是**模型在基准上的成绩**，不是"跳过裁判会砸多少"的测量，只能当类比用。

## 快速开始

```powershell
# 1) 侦察：语言分布、体量热点、变更热力、测试现状、入口点候选
./scripts/phase0-recon.ps1 -RepoPath D:\path\to\repo -OutFile recon-report.md

#    默认噪声表把 build/ 整个排除；若那个仓库的 build/ 是真代码，自己给一份列表（含 `/` 的按路径段匹配）
./scripts/phase0-recon.ps1 -RepoPath D:\path\to\repo -OutFile recon-report.md -ExcludeDirs "node_modules,.git,dist,target,vendor,bin,obj,build/out"

# 2) 登记一个持续性钩子（创建前先备份原文件）
./scripts/hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Register -Kind config -Path <钩子路径> -Action modified -Backup <备份路径>

# 3) 收尾：预演 → 执行 → 验证 → 通用扫描
./scripts/hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Teardown
./scripts/hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Teardown -Apply
./scripts/hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Verify
./scripts/hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Sweep -Repo <目标仓库>

# 4b) 可选：连 [?]（可能本来就是用户有的）也判失败，逼自己逐项确认完
./scripts/hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Sweep -Strict -Repo <目标仓库>
```

## 安装

把仓库克隆到你的 skill 根目录下，**目录名保持 `legacy-refactor-flow`**：

| 平台 | 路径 |
|---|---|
| DeepSeek Harness（用户级） | `~/.dsh/skills/legacy-refactor-flow/` |
| DSH（项目级） | `<项目>/.dsh/skills/legacy-refactor-flow/` |
| Claude Code（用户级） | `~/.claude/skills/legacy-refactor-flow/` |

```powershell
git clone https://github.com/master666-max/legacy-refactor-flow.git "$HOME/.dsh/skills/legacy-refactor-flow"
```

## 目录

| 路径 | 作用 |
|---|---|
| `SKILL.md` | skill 入口：两条铁律、五步流程、钩子台账、强制拆除、残留物清单 |
| `scripts/hooks-ledger.ps1` | 台账登记 / 列表 / 预演 / 拆除 / 验证 / 通用扫描 |
| `scripts/phase0-recon.ps1` | 侦察调度器：优先调 scc/tokei/cloc/code-maat/jscpd，内置实现仅兜底并标注来源 |
| `scripts/mutation-probe.ps1` | 裁判强度探针：注变异看测试会不会红，报 `MUT score=` 下限证据；只动临时副本，基线红则拒跑 |
| `references/REFACTOR-RUNBOOK.md` | 完整作战手册：阶段细节、出口条件、按语言工具矩阵、提示词模板 |
| `references/COMMUNITY-MAP.md` | 社区已有方法与流程图、现成工具地图、与 aim42 的对应关系 |
| `references/EXAMPLE-recon-report.md` | 侦察报告的真实输出样例两份：外部工具在位 / 全缺走兜底 |
| `tests/run-all.ps1` | 一次跑完四个自检，任一非零即整体非零 |
| `tests/check-mutation.ps1` | 探针自己得能分出强弱：9 变异点夹具，强/弱两套测试集比**序** |
| `tests/check-encoding.ps1` | 编码不变量：每个 `.ps1` 恰好一个 BOM、自带码页守卫；含**哨兵** |
| `tests/check-ledger-lifecycle.ps1` | 台账工具 14 步全生命周期，含"没拆必须拦"的反向用例 |
| `tests/check-recon.ps1` | 侦察报告 12 条断言，期望值写死在自检里、不取自被测输出 |

## 自检

```powershell
powershell -NoProfile -File tests/run-all.ps1     # 中文 Windows + PS 5.1，最有意义的一档
pwsh -NoProfile -File tests/run-all.ps1           # 也可以；但在 Windows 上它仍用 powershell 5.1 起子进程
```

`run-all` 在 Windows 上一律用 `powershell`（5.1）起子进程——编码故障只在该环境成立，宿主是 pwsh 也不例外。非 Windows 才退到 `pwsh`，此时编码哨兵无从复现，会记 SKIP 而不是假装通过。

四个自检都在 `%TEMP%` 里造一次性沙箱跑，**不碰你的仓库**，跑完即删（加 `-KeepSandbox` 保留现场）。当前规模：编码不变量（8 个 `.ps1`）+ 台账 40 项 + 侦察 14 项 + 探针 8 项。

自检本身也要能被证伪，否则就是恒真的绿灯。五条反向对照（本机实测）：

| 破坏什么 | 应红 | 实测 |
|---|---|---|
| 拿 v1.0 的 `phase0-recon` 喂 `check-recon` | 语言名/体量表/热力污染/目录噪声/子项目配置/中文提交信息 逐条翻红 | 8 红，rc=1 |
| 把 `hooks-ledger` 的 `-Verify` 改成永远报绿 | "未拆除应拦"两条反向用例红 | 恰好 2 红，其余仍绿，rc=1 |
| 喂 v1.1 的 `hooks-ledger`（既无 `HARD=/CHECK=/UNCOVERED=` 也无租约） | Sweep 覆盖面 + 租约收集器两组用例全红，v1.1 本来就对的那 18 项仍绿 | 15 红 / 18 绿，rc=1 |
| 剥掉仓内任一 `.ps1` 的 BOM | 编码自检红 | 1 红，rc=1 |
| 给探针一套**只测远离边界取值**的弱测试集 | 得分必须明显低于强测试集（M1 断言的是**序**，不是绝对值） | 强 0.889 vs 弱 0.111（同为 9 个变异点） |

三个坑值得写下来，因为它们都会把判据悄悄做成恒真、或把仪器当成被测物：

- **码页污染**：`[Console]::OutputEncoding = UTF8` 作用在**整个控制台**而非单进程，后起的子进程会继承它。所以"中文对不对"不能拿当前码页现值当基线——`check-recon` 改从注册表 `…\Nls\CodePage\OEMCP` 取机器出厂码页，用一层壳把它钉回去再测；`check-ledger-lifecycle` 则只断言退出码与条数，中文交由 `check-encoding` 按字节查。
- **夹具自证**：登记-验证类用例必须确证"改写后的文件与备份哈希真的不同"，否则 `-Verify` 报"已还原"是真话，测了个空。`check-ledger-lifecycle` 在开头就量这个，不同才继续。同理，探针的**基线是红就拒跑**：测试本来就红时，"变异被抓住"全是假信号。
- **命名撞自己**：`check-mutation` 里有一条查"探针有没有留下工作副本"，用 `-Filter "lrf-mut-*"`；而它**自己的沙箱就叫 `lrf-mut-chk-*`** ⇒ 第一个命中的是自己。现已改前缀并按 `^lrf-mut-\d{8}-\d{6}-` 精确匹配。写"检查有没有残留"这类断言之前，先问：被检的集合里有没有仪器自己的产物？

## 依赖

- PowerShell 5.1+ 或 pwsh 7+（Windows / Linux / macOS 均可）
- 可选外部工具——**有则用，无则自动降级**：`scc` / `tokei` / `cloc`（语言统计）、`code-maat`（变更热力，需 Java）、`jscpd`（重复率）

### 编码契约（改这两个脚本时必须守住）

两个 `.ps1` 一律存成 **带 BOM 的 UTF-8 + CRLF**，脚本开头都有 `[Console]::OutputEncoding = UTF8`。少任何一条都会在"中文 Windows + Windows PowerShell 5.1"这个默认组合上出事：

| 约定 | 破了会怎样 |
|---|---|
| 带 BOM | PS 5.1 对无 BOM 的 `.ps1` 按 ANSI 代码页（中文机 = GBK）解码 → 中文注释与字符串变乱码 → 乱码字节撞坏语法树 → **ParserError，脚本完全不可用** |
| 脚本内设 `OutputEncoding = UTF8` | PS 5.1 默认按控制台 OEM 代码页输出 → 输出经管道/重定向给上层（agent、CI 日志）读时中文整片乱码，**等于没有证据** |
| `code-maat` 用 `-c git` 且日志写成无 BOM UTF-8 | 本版 standalone jar 的 `git2` 解析器对规范格式也报 `Parse error`；带 BOM 时连 `git` 解析器也在第 1 行第 1 列报错 |

`.gitattributes` 里的 `*.ps1 text eol=crlf` **只管换行符，不管编码**，管不住第一行那条。

## 变更记录

### v1.3（2026-09-28）—— 把"造了裁判"变成"裁判有多强"，把"记得拆"变成"有人收"

| 变更 | 为什么 |
|---|---|
| 新增 `scripts/mutation-probe.ps1` | 铁律一只要求"造裁判"，从没量过裁判多强。特征测试是对"等价"做**抽样**，抽样强度的度量是变异得分；工具表里早就列着 Stryker/mutmut，却没进任何一条出口条件。D 步出口现在要求报数 |
| 台账加租约与孤儿收集器 | 铁律二的执行**依赖发起方活着**，而会话会被切断（本机 AGENTS.md R-4 记过孤儿子代理）。数据库对付这问题的老办法是 WAL + 外部恢复，分布式系统的对应物是**租约 + TTL + 清扫者**：`-Register -Owner x -TTLHours n` / `-Renew` / `-Collect [-Apply]`；三条死规矩——默认干跑、无租约永不算孤儿、缺备份一律不动 |
| C 步出口改三元组 | "每个入口点都有判定"是簿记判据。DEAD 在底层只能是 `(判定, 观测窗口, 触达画像)`：静态可达性在反射/DI/序列化上必崩，日志反推又是"缺证据当反证据"（季度任务与灾备路径在 90 天窗口里都像死的）。并要求删除**可撤回** |
| 图谱分工加弃权规则 | "结构问题查图、实现读文件"的分类器是 agent 自己；错分时那 9 个百分点的损失正好落在你以为它是结构题的那批上，且没有信号。拿不准就退回读文件 |
| D 步加"行为差异一律登记" | 特征测试的意义是**值中性**（Feathers 原话：要知道变了，**不管你觉得那对不对**）。不登记，测试集就成了反对变化的那一方 |
| 引用更正三处 | ① 39.4% 是 compound 实例（177/1,099 题）而非"复合重构失败率"，"跳过 D ≈ 60% 失败"是**因果滑位**，降格为类比；② RefAgent 的 64.7% 是**相对**提升不是百分点；③ "40%~70% 是死代码"四轮检索无可引来源，改标"未复核，当经验区间用" |
| 新增第四条实证约束 | arXiv 2605.02096（226 个真实历史缺陷案例）原话直指要害：**开发者自己的测试套件不足以当重构正确性的 oracle**。同时写清为什么不照搬——它的 97.3% 是分类准确率，非确定性的东西进闸门会带来另一类恒真风险 |

自检同步扩到 **40 + 14 + 8 项**（新增 21~27 租约与收集器、M0~M6 探针）。

### v1.2（2026-09-28）—— 工具追上自家铁律

| 变更 | 说明 |
|---|---|
| `-Sweep` 补三类盲区 | SKILL.md §4.1 列了 CI 配置 / 环境变量 / worktree，之前**一条都没查**。现补齐：CI 配置与 `.env*` 计入 `[?]`；`core.hooksPath` 被改指仓外、临时 worktree 多于一个，计入 `[X]` 硬残留并返回非零 |
| 未覆盖项明写 | daemon / crontab / 用户级环境变量 / 常驻端口 / 跨仓写入 —— 本工具判不了，扫描末尾打 `[未覆盖] …`，**不许让它长得像"扫过了"** |
| 机器可读汇总 | `-Sweep` 打 `HARD= CHECK= UNCOVERED=`，`-Verify` 打 `BAD= OK=`；中文给人看，ASCII 给上层读 |
| `-Sweep -Strict` | 连 `[?]`（可能是用户本来就有的）也判失败，用于"必须逐项确认完"的收尾 |
| 报告路径口径统一 | 第 2 节表头写"相对路径"、scc 分支却塞的是绝对 `Location`；现统一由 `Get-Rel` 削根，兜底与入口点候选同口径 |
| 样例报告换靶 | `references/EXAMPLE-recon-report.md` 原先扫的是另一个项目，把它的绝对路径与文件名带进了公开仓；现改为本仓自扫，并附一份"无外部工具时走兜底"的形状 |

自检同步扩到 **25 + 14 项**：新增 15~20（Sweep 覆盖面，用**增量**比对不猜绝对计数）与 R8/R8b（路径口径）。反向对照实测：喂 v1.1 的 `phase0` → R8/R8b 红（7 条路径全绝对）；喂 v1.1 的 `hooks-ledger` → 新 7 格全红、原有 18 项仍绿。

### v1.1（2026-09-28）—— 修 7 处，其中 6 处在 v1.0 上会让报告写错结论

| # | 症状 | 根因 | 影响 |
|---|---|---|---|
| 1 | 两个 `.ps1` 在中文 Windows 的 PS 5.1 下直接 ParserError | 存成了无 BOM 的 UTF-8（见上方编码契约） | 脚本在该环境**完全不可用** |
| 2 | 「语言分布」表语言名全空 | 读 `$e.Language`，而 scc 的 JSON 字段叫 `Name` | 报告里 13 行语言名全空 |
| 3 | 「体量最大的 N 个文件」整表空白 | scc 不加 `--by-file` 时 `Files` 数组恒为空 | 热点候选一条都给不出 |
| 4 | 变更热力表被 java 报错文本污染 | `-c git2` 解析器对本版 jar 不可用；且脚本把报错当 CSV 数据采信 | 报错文本被当"最频繁变更的文件"写进报告 |
| 5 | 「一级目录」表混进 `.git` / `dist` / `build` | 噪声正则要求尾随分隔符，根级目录漏网 | 模块切分候选被噪声占位 |
| 6 | 仓库里有 5 套测试却报「未检测到任何测试/构建配置 —— 从零开始造裁判」 | 只查根目录，不看子项目 | **把错误结论直接写进报告**，monorepo 尤甚 |
| 7 | 中文提交信息与脚本自身输出在管道/重定向下乱码 | 控制台码页（本机 = 936）决定了两件事：PS 5.1 **与 pwsh 7 都**按它解码子进程输出，也按它编码自己的输出（初版把根因窄写成"PS 5.1"，是仓内 `check-recon` 的 R6 反向对照把它纠正的：钉回出厂码页后 v1.0 在两个解释器下都现出乱码） | 报告中文不可读；`-Verify` 的回执给 agent 读是乱码，"证据是脚本输出"这条铁律落空 |

**怎么验的**：`hooks-ledger.ps1` 的 14 步生命周期（干净态 → 登记 → 未拆应拦 → 预演 → `-Apply` → 拆后应绿 → 扫描）在 PS 5.1 与 pwsh 7.6 下各跑一遍全对；`phase0-recon.ps1` 用**同一目标仓、同一解释器**跑 v1.0/v1.1 对照，第 2~7 项逐条翻正（如语言名空行 13→0、体量表 0→20 行、java 报错污染 3→0、噪声目录 build/dist/.git→无、测试设施"从零开始"→检出 5 处）。这些验证已固化成仓内 `tests/`，不必再信我的一面之词——见下面「自检」。

### v1.0（2026-09-24）

首版：两条铁律、A→E 五步流程、钩子台账与强制拆除、侦察调度器。

## 来源与致谢

方法源自社区十年积累：**aim42**（Architecture Improvement Method）、Michael Feathers《Working Effectively with Legacy Code》、**Mikado Method**、Martin Fowler 的 *Patterns of Legacy Displacement*、Adam Tornhill 的软件分析、Markus Harrer 的 *awesome-legacy-systems*。

实证数据来自：SWE-Refactor（arXiv [2602.03712](https://arxiv.org/abs/2602.03712)）、RefAgent（arXiv [2511.03153](https://arxiv.org/abs/2511.03153)）、Codebase-Memory（arXiv [2603.27277](https://arxiv.org/abs/2603.27277)）。

## License

MIT
