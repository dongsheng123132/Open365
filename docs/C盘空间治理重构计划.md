# Open365 C 盘空间治理重构计划

> 状态：开发交接稿，尚未实施  
> 面向：Claude Code / Codex / 后续维护者  
> 核心命题：**不是删除更多，而是让每一块空间重新有主人、有生命周期、有恢复路径。**

## 0. 接手前先看

目标仓库：`D:\uking编程\Open365电脑AI开源助手`

先读：

- `AGENTS.md`、`CLAUDE.md`
- `engine/cleaner.ps1`
- `core/registry.ps1`、`core/action-core.ps1`
- `gui/Open365Pages.cs` 中 `BuildCleanPage` 到 `RunCleanSelected`
- `tests/test-cleaner.ps1`、`tests/test-action-parity.ps1`
- `docs/影核协议改造.md`

协议参考：

- `D:\uking编程\2origin-computer\rfcs\RFC-0000-2origin-computer.md`
- `D:\uking编程\ShadowOS = Harness OS\TERMINOLOGY.md`
- `D:\uking编程\ShadowOS = Harness OS\rfcs\RFC-0004-shadowcore-v0.2.md`
- `D:\uking编程\ShadowOS = Harness OS\rfcs\RFC-0005-benjing-v0.2.md`
- `D:\uking编程\ShadowOS = Harness OS\rfcs\RFC-0006-benxiang-v0.1.md`

开工必须先跑：

```powershell
git status --short --branch
git log -5 --oneline
powershell -File core\action-core.ps1 list -Json
powershell -File core\action-core.ps1 describe cleaner.scan -Json
```

交接前最后一次检查（2026-08-09）：分支 `feat/self-update`。仓库在本计划编写期间发生了新的并行改动，当前不只是普通脏工作区，还存在未合并冲突：

```text
UU action-parity.json
UU core/registry.ps1
UU gui/Open365Tray.cs
```

另有 ActionParity、README、GUI、测试和构建脚本等多处已暂存或未提交改动，完整清单必须以接手时的 `git status --short --branch` 为准。本计划只新增了当前这份 Markdown，没有修改业务代码。

接手顺序：先判断上述冲突来自哪几条并行工作、完成或协调冲突解决，再开始空间治理实现。不要 reset、checkout、clean 或覆盖任何现有改动；修改 `core/registry.ps1`、`action-parity.json`、`gui/Open365Tray.cs` 时尤其要定点合并。

## 1. 产品定位

当前 `cleaner.ps1` 的产品模型是“垃圾类别 + 大小 + 删除”。重构后应成为“空间对象 + 治理策略 + 语义事务 + 复观收据”。

治理对象分三类：

1. **派生空间**：缓存、缩略图、着色器缓存。可删除，因为系统或应用能重建。
2. **过期空间**：超过保留期的临时文件。可删除，因为生命周期已经结束。
3. **原始或诊断空间**：用户文件、回收站、日志、转储、更新中间态。不能因“体积大”自动删除，只能提示、迁移、卸载或经明确批准处理。

重要结论：**恢复路径不等于一律备份。** C 盘内再留一份备份不会释放空间。每条规则必须诚实声明：

- `restore`：能精确还原；
- `regenerate`：不能还原原字节，但系统/应用能重建功能；
- `none`：不可恢复，必须说明原因和风险。

不得把 `regenerate` 写成 `reversible=true`。

## 2. 四套理念怎样落地

### 2.1 本象：只观察，不替动作自证

`cleaner.scan` 是观察器。它只回答路径是否存在、文件数、字节数、观察时间等事实，不接收“应该释放多少”的预期，也不输出 `ok/pass/verdict`。

治理规则不是观察事实，必须与观察结果分层。例如：

```json
{
  "key": "chrome-cache",
  "observation": {
    "path": "...",
    "exists": true,
    "bytes": 123,
    "files": 4,
    "observed_at": "..."
  },
  "policy": {
    "owner": "Google Chrome",
    "lifecycle": "rebuildable-cache",
    "risk": "low",
    "recovery_mode": "regenerate"
  }
}
```

`apply` 完成后必须重新扫描目标规则，结果由“执行前观察”和“执行后观察”的差值决定，不能仅凭 `Remove-Item` 没抛异常就声称成功。

### 2.2 本境：保存治理状态，不保存聊天记录

本境在本功能中的最小实现是治理收据目录：

```text
%LOCALAPPDATA%\Open365\space-governance\
├── intents\       # 动作前审计意图
└── receipts\      # 动作后收据，JSON，一次治理一份
```

收据记录 `request_id`、`plan_id`、规则版本、请求来源声明、前后观察、实际释放量、失败项、恢复语义和证据路径。它是状态与证据，不是用户和 AI 的对话全文。

审计应 fail-closed：写不下 intent 时，不得开始删除。最终收据写失败时必须在返回值中显式暴露，不能静默报成功。

### 2.3 影核：一个动作，所有 AI 和界面共用

GUI、CLI、Claude Code、Codex、Hermes、OpenClaw 都只能通过 `core/action-core.ps1` 使用同一组 Action ID。GUI 不再直接拼 `cleaner.ps1 clean -Force`。

影核负责：

- 动作发现与 Schema；
- 风险等级；
- 非只读动作默认拒绝；
- 输入输出契约；
- `request_id` 幂等；
- 审计要求；
- GUI / CLI / AI 的行为同源。

### 2.4 本源计算机：形成完整闭环

本功能的闭环固定为：

```text
Observe(scan) -> Think(plan) -> Approve -> Act(apply)
-> Verify(post-observe) -> Learn(receipt/history)
```

v1 不做常驻守护进程、不接完整本象编译器、不复制 ShadowOS 的 Node 实现。只移植可验证的语义，不强行植入整套运行时。

## 3. v1 Action 设计

保留旧 `scan` / `clean` CLI 兼容入口，但 GUI 与 AI 新入口统一为以下四个动作。

### 3.1 `cleaner.scan`（read）

用途：观察所有白名单空间对象。

输入：空对象。后续如需筛选再增加可选 `keys`，v1 可不做。

输出至少包含：

- `spec = open365.space-governance/0.1`
- `kind = space.observation`
- `observation_id`
- `observed_at`
- `policy_revision`
- `items[]`，每项分开保存 `observation` 与 `policy`
- `total_bytes`、`total_human`

兼容要求：暂时保留顶层 `bytes/files/human/path` 字段，避免首页体检与旧 GUI 同时断裂；等所有消费者迁完再移除。

### 3.2 `cleaner.plan`（read）

用途：把选中的观察对象编译成治理计划，不改系统。

输入：

```json
{ "keys": "user-temp,chrome-cache", "requested_by": "claude-code" }
```

`requested_by` 只是来源声明，不是授权凭证。输出至少包含：

- `kind = space.governance.plan`
- `plan_id`（规则版本 + 规范化 key 集合的 SHA-256）
- `policy_revision`
- `created_at`
- `items[]`
- `estimated_bytes`
- `risk_summary`
- `contains_irreversible`
- `requires_human_confirmation = true`

若未传 `keys`，只选择 `default_selected=true` 且当前字节数大于 0 的项目。

### 3.3 `cleaner.apply`（write）

用途：执行已经形成的计划。

输入至少包含：

```json
{
  "keys": "user-temp,chrome-cache",
  "plan_id": "plan:...",
  "request_id": "uuid-or-stable-id",
  "requested_by": "open365-gui"
}
```

规则：

- Action Core 中 `class=write`、`risk=high`（静态登记取最大风险）、`confirmation=always`、`audit_required=true`、`reversible=false`。
- 未显式 `-Confirm` 必须由 Action Core 拒绝。
- `plan_id` 与规范化 key 集合或 `policy_revision` 不一致，拒绝执行。
- 未知 key、重复 key、空 key 集合，拒绝执行。
- `request_id` 已完成且请求哈希相同，返回原收据并标记 `replayed`，不得二次删除。
- 同一 `request_id` 对应不同请求哈希，返回 `idempotency_conflict`。
- 删除前写 intent；写失败则不动世界。
- 每项删除前后都独立观察；整体允许 `done / partial / failed / replayed`。
- “释放量”必须是前后观察差值；执行函数的估算值只能作辅助证据。

### 3.4 `cleaner.history`（read）

用途：让人和 AI 查看最近治理记录。

输入：可选 `limit`，默认 20，最大 100。

输出：收据摘要数组，不读取或上传用户文件正文。损坏的收据不能静默跳过，应返回 `orphans[]` 或 `warnings[]`。

## 4. 规则策略矩阵

建议字段：`owner`、`lifecycle`、`retention_days`、`risk`、`default_selected`、`recovery_mode`、`why_safe`、`recovery_note`。

| key | 主人 | 生命周期 | 保留期 | 风险 | 默认选 | 恢复语义 |
|---|---|---|---:|---|---|---|
| `win-temp` | Windows | expired-temp | 1 天 | low | 是 | none：仅处理过期临时项 |
| `user-temp` | 当前用户/应用 | expired-temp | 1 天 | low | 是 | none：仅处理过期临时项 |
| `prefetch` | Windows 性能子系统 | performance-state | 30 天或不自动清 | medium | 否 | regenerate，但可能短期变慢 |
| `thumbs` | Windows Explorer | rebuildable-cache | 0 天 | low | 是 | regenerate |
| `win-update` | Windows Update | update-staging | 不自动 | high | 否 | re-download，不等于回滚 |
| `cbs-logs` | Windows Servicing | diagnostic-evidence | 建议 30 天 | medium | 否 | none：会损失诊断证据 |
| `inetcache` | Windows/当前用户 | rebuildable-cache | 0 天 | low | 是 | regenerate |
| `crashdumps` | 崩溃应用/用户 | diagnostic-evidence | 建议 14 天 | medium | 否 | none：会损失调试证据 |
| `wer` | Windows Error Reporting | diagnostic-evidence | 建议 14 天 | medium | 否 | none：会损失诊断证据 |
| `d3dcache` | GPU/应用 | rebuildable-cache | 0 天 | low | 是 | regenerate，首次运行可能变慢 |
| `edge-cache` | Microsoft Edge | rebuildable-cache | 0 天 | low | 是 | regenerate |
| `chrome-cache` | Google Chrome | rebuildable-cache | 0 天 | low | 是 | regenerate |
| `firefox-cache` | Mozilla Firefox | rebuildable-cache | 0 天 | low | 是 | regenerate；继续只碰缓存子目录 |
| `recyclebin` | 当前用户 | user-recovery-buffer | 用户决定 | high | 否 | none：清空后不可恢复 |

注意：`win-update` 不能继续当普通目录直接删。v1 若没有正确处理 Windows Update 服务状态与系统 API，就只观察和提示，不执行该规则。`prefetch` 也不应作为“越清越快”的默认项。

`Get-DirSize` 与 `Clear-Dir` 需要支持 `retention_days`，扫描和执行必须使用同一个过期判断函数，避免“计划只算旧文件，执行却删全部”。

## 5. GUI 改造

目标名称建议：左侧导航与页面标题改为“C 盘空间治理”，不要再以“垃圾”定义所有空间。

清理页表格建议列：

```text
选择 | 归属 | 空间类型 | 生命周期 | 风险 | 恢复方式 | 可释放
```

GUI 行为：

1. `LoadClean()` 调 `cleaner.scan`，默认勾选完全由 `policy.default_selected` 决定，删除当前 `key != recyclebin` 的硬编码。
2. 用户点击执行后，先调 `cleaner.plan`。
3. 确认框展示计划 ID、风险分组、不可恢复项和预计释放量。
4. 用户确认后通过 `ActC("cleaner.apply", ...)` 执行，不再走 `Engine("cleaner.ps1", "clean -Force ...")`。
5. 执行按钮设置稳定绑定 `Open365.Gui.CleanerApply`；扫描仍为 `Open365.Gui.CleanerScan`。
6. 完成提示展示真实前后差值、部分失败数量、收据路径；失败不能只显示“请重试”。
7. 首页体检文案从“垃圾文件”改为“可治理空间”，但不要仅按空间大就扣健康分。缓存多不等于电脑不健康，建议把扣分改成提示，不影响安全评分。

当前 GUI 正在做主题和高 DPI 改造。必须使用 `Theme.*` 与 `Dpi.Px`，不要写新的原始颜色和字体。

## 6. AI 参与边界

Claude Code、Codex、Hermes、OpenClaw 都可安全执行：

```text
list / describe / cleaner.scan / cleaner.plan / cleaner.history
```

它们可以解释空间主人、生命周期、风险和建议，也可以生成计划，但不能拥有一套私有清理逻辑，不能绕过 Action Core 直接 `Remove-Item`。

`cleaner.apply` v1 依赖 Action Core 的 `-Confirm`，这只是“显式确认位”，**不是可验证的人类授权**；AI 理论上也能自行传入。因此文档与工具描述必须诚实：v1 是策略约束，不是密码学的人在环证明。

真正强制“AI 不能冒充人确认”属于 v2 Trust Lane：由 GUI 在用户确认后签发一次性、短时、绑定 `plan_id + request_hash` 的 capability，Action Core 消费后立即作废。没有 capability 时，AI 只能规划，不能执行。不要在 v1 用 `requested_by="human"` 这种自报字段冒充授权。

## 7. 必须有的反向判据

至少覆盖以下失败注入；只测正常路径不算完成。

1. 造一个 Firefox profile，放 `places.sqlite`、`logins.json`、`prefs.js`，治理后必须原样存在。
2. 在临时目录造“新文件 + 超过保留期旧文件”，扫描只统计旧文件，执行只删除旧文件。
3. `default_selected=false` 的 Prefetch、Windows Update、CBS、CrashDumps、WER、回收站不得被默认计划选中。
4. 故意传错 `plan_id`，世界零改动，且无完成收据。
5. 同一 `request_id` 重放两次，第二次返回 `replayed`，不得再次执行。
6. 同一 `request_id` 换 key 集合，必须报幂等冲突。
7. 让 intent 目录不可写，`apply` 必须 fail-closed，测试文件一字节不动。
8. 模拟一个文件被占用：整体结果为 `partial`，失败项可见，不能静默报全成功。
9. 执行后重新造一个缓存文件：历史收据仍表示“当时”的证据，当前扫描表示“现在”的事实，不能混为一谈。
10. 放一份损坏 JSON 到 receipts，`history` 必须报告孤儿/警告，不能当它不存在。
11. `OPEN365_SANDBOX=1` 加 `-Confirm` 调 `cleaner.apply`，仍必须被动作核心拒绝。
12. GUI 静态绑定检查必须证明扫描和执行都走 Action Core，不再出现清理页直接调用 `cleaner.ps1 clean -Force`。

所有破坏性测试只允许在自建 sandbox，禁止碰真实回收站、浏览器、系统临时目录。

## 8. 具体文件改动顺序

建议小步提交，每一步可独立回滚：

1. `engine/cleaner.ps1`
   - 扩展规则元数据；
   - 统一 key 规范化；
   - 加保留期过滤；
   - 实现 observation / plan / apply / history；
   - 保留 `clean` 兼容入口；
   - PS1 保持 UTF-8 BOM。
2. `tests/test-cleaner.ps1`
   - 先补 sandbox 反向判据，再改实现直至通过。
3. `core/registry.ps1`
   - 注册 `cleaner.plan`、`cleaner.apply`、`cleaner.history`；
   - 更新 `cleaner.scan` Schema；
   - `Get-Open365StateContract().queries` 加只读动作。
4. 生成 `action-parity.json`
   - 只能运行 `core\action-core.ps1 manifest -WriteManifest`，禁止手改。
5. `tests/test-action-parity.ps1`
   - 增加清理写动作默认拒绝、沙箱拒绝、GUI 同源绑定检查。
6. `gui/Open365Pages.cs`
   - 合并空间治理表格与 plan/apply 流程。
7. `gui/Open365Manager.cs`、`gui/Open365Tray.cs`
   - 定点更新导航和标题文案，保留现有主题改动。
8. `open365.ps1`、`AGENTS.md`、`CLAUDE.md`、`README.md`、`docs/影核协议改造.md`
   - 更新 CLI 示例、AI 使用边界和理念说明。

每完成一个小步先看 `git diff --check` 和 `git status`，确认没有覆盖并行工作，再提交。

## 9. 验证门槛

最低验证：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-cleaner.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-action-parity.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File core\action-core.ps1 verify -Json
powershell -ExecutionPolicy Bypass -File tests\run-all.ps1
powershell -ExecutionPolicy Bypass -File tools\build-gui.ps1
```

GUI 还要跑预览截图：

```powershell
powershell -ExecutionPolicy Bypass -File tools\build-gui-preview.ps1
powershell -ExecutionPolicy Bypass -File tools\ui-shot.ps1 -Page clean -Out "$env:TEMP\open365-space.png"
$env:OPEN365_UI_SCALE='1.5'
powershell -ExecutionPolicy Bypass -File tools\ui-shot.ps1 -Page clean -Out "$env:TEMP\open365-space-150.png"
```

验收不是“脚本退出码 0”，而是：

- sandbox 中实际只删了计划内、已过期的对象；
- 前后观察差值与收据一致；
- 非默认高风险项没有被静默带入；
- Action Core、GUI、CLI、AI 使用同一动作；
- 部分失败、审计失败、收据损坏都可见；
- 旧 GUI 主题和高 DPI 改动没有被覆盖。

## 10. v1 不做 / v2 再做

v1 不做：

- 全盘重复文件自动删除；
- 自动处理用户下载、桌面、文档；
- WinSxS 手工删除；
- 驱动目录和未知 `ProgramData` 清理；
- 常驻后台监控；
- 将本象/本境 Node Runtime 整套嵌入 Open365；
- 用 AI 自由生成 PowerShell 删除命令。

v2 候选：

- Trust Lane 一次性人类批准 capability；
- 多用户、多浏览器 profile 发现；
- 大文件归属图与迁移建议；
- 重复文件只建议、不自动删；
- 收据趋势与空间生命周期预测；
- 本象带外复观任务；
- 本境经验沉淀：某应用反复长大后建议搬家、改缓存位置或卸载，而不是反复清同一目录。

## 11. 最终产品表达

建议对用户只讲一句：

> **Open365 不替你决定什么该消失。它先认清空间属于谁、为什么存在、何时到期、出了问题怎样恢复，再让你和 AI 一起决定。**

这句话必须由动作契约、默认策略、收据和反向测试共同证明，不能只做成页面文案。
