# 把这套工作流装进"支持复杂工作流的平台"

面向的读者：要把本技能接到 zcode / 其他带工作流编排的 agent 平台上的**人**，不是模型。
读序：先看 §1 决定走哪条路，再照 §2 或 §3 接，§4 是接完之后的验收。

## 1. 三条接入路径，按平台的 abilities 选

| 平台能做什么 | 走哪条 | 拿什么去接 |
|---|---|---|
| 能跑 shell 步骤并按退出码分支 | **A. 前台执行器**（推荐，零改造） | `workflow/workflow-run.ps1` + `workflow/legacy-refactor-flow.workflow.json` |
| 只有可视化编排画布（节点/条件边/审批节点） | **B. 映射** | 见 §2 的对应表；每个节点仍调 A 的单阶段跑法 `-FromPhase` |
| 只认"技能 + 斜杠命令" | **C. 技能形态** | `SKILL.md` + `commands/legacy-refactor-*.md`，门靠 agent 自觉（弱于 A） |

**没有 MCP server、没有常驻 job、没有取消接口。** 谁要是按"提交一个异步任务再轮询"的形状接，接不上——
本执行器是一次性前台跑完同步返回 rc 的那种（限度写在 `workflow/contract.md` §6）。

## 2. 可视化编排的对应表

| 画布上的东西 | 本包里的东西 | 注意 |
|---|---|---|
| 阶段节点 | `phases[].id`（A/B/C/D/E/T） | 单阶段跑法：`-FromPhase D`；profile 决定哪些阶段在场 |
| 节点内动作 | `phases[].steps[]`（`kind=cmd` / `kind=tool` / `kind=manual`） | `manual` 没有可执行体，必须落到审批节点或删除 |
| 条件边 | `phases[].gates[]` 的 `verdict` | 只有 `pass` 才往下；`fail`→rc1，`wait`→rc3 |
| 审批节点 | `op=human` 的门（每个阶段各一条，共 6 条） | **必须由真人点**，平台若允许 agent 自批就等于没有这道门 |
| 产物存储 | `runArtifacts.root`（被检仓之外） | 平台的 artifact 通道要指向 runDir，别指向被检仓 |
| 任务状态 | `coverageStates` 四态 | `unknown` 不是"没跑"也不是"通过"，映射时不许折成绿 |
| 超时 | `profiles[].budgetSec` | **执行器自己不计时**，超时只能由平台侧给（见 contract §7） |

## 3. 接之前的前置与坑

- 宿主：PowerShell 5.1 或 7（非 Windows 用 `pwsh`）。仓内 `.ps1` 全部 **UTF-8 BOM + CRLF**，
  缺 BOM 在中文 Windows 的 5.1 上直接 ParserError——**平台若重新生成/转码这些文件就会坏**。
- 目标仓必须是 **git 仓**：A-g3 直接要 `git rev-parse HEAD`，不是 git 仓就停在 A —— 这是设计，
  没有退路的仓不该开始重构。T 的 `-Sweep` 还要读 `git status`。
- `-TestCmd` 由用户提供，且必须是**该仓自己的**跑法。不许拿本仓的 `node --test` 夹具当别人的期望值。
- 相对路径都按**被检仓**解析（`-OutFile`、`{testCmd}`）；执行器会把子进程工作目录切到目标仓。
- 并发：runId 只到秒。同一个仓在同一秒起两次 ⇒ 落进同一个目录、互相覆盖（`New-Item -Force` 不报错）。
  平台并发调度请错开，或每次都显式给 `-RunDir`。
- 人工门的放行值是**阶段字母**：`-Confirm A,B,C,D,E,T`。在 `-File` 调用形态下整串会当成一个字符串传入，
  执行器自己按逗号切 —— 平台侧原样给就行，不必再切。

## 4. 接完的验收（四条，都要实跑）

1. `-DryRun` 不给 `-Confirm` ⇒ **rc=3**。若这里出 0，说明平台把审批节点旁路了。
2. 全确认实跑 ⇒ **rc=0**，且 `~/.legacy-refactor-flow/runs/<projectId>/<runId>/` 有五份文件、
   `-VerifySeal` 对它们 **rc=0**。
3. 手改 `gates.json` 一个字节 ⇒ `-VerifySeal` **rc=1**。验不出篡改，前两条都不作数。
4. 跑完之后目标仓 `git status` 干净（机器生成的过程报告都在 runDir）。
   脏了 ⇒ 平台在中间加了写被检仓的步骤。

一键复跑本机版：`powershell -NoProfile -File tests/check-workflow.ps1`（跑完自己打总数）。

## 5. 卸载 = 删两处

- `~/.legacy-refactor-flow/runs/`（本包全部产物）
- 目标仓里的 `_refactor-kit/`（只有人写的 `SCOPE.md` / `TRIAGE.csv` 本该留在仓内；不要就删）

不留任何持续性钩子、不注册 cron、不改 `git config`、不设 `core.hooksPath` —— T 阶段就是拿来证明这一点的，
`hooks-ledger -Sweep` 若报 HARD>0 就是没拆干净。
