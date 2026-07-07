# AGENTS.md — 给 AI 代理的安装与使用说明

> 这份文件是写给**自动化 AI 代理**看的（Claude Code / Cursor / 各类装机 Agent）。
> 目标：让 AI 在用户的 Windows 电脑上，**无人值守**地把 Open365 装好、验证、并能调用其功能。
> 人类用户请看 [README.md](README.md)。

## 0. 一句话

Open365 = 无广告 / 无捆绑 / 不联网上传的开源 Windows 电脑维护工具。纯 PowerShell 引擎 + C# 托盘 GUI，**零第三方依赖**（只用 Windows 自带的 `csc` 编译、`netsh`/`Get-*`/注册表 执行）。

## 1. 环境要求（几乎所有 Win10/11 都满足）

- Windows 10 / 11
- .NET Framework 4.x —— 系统自带，无需安装。检测：
  ```powershell
  Test-Path "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
  ```
  返回 `True` 即可编译 GUI。返回 `False` 时仍可用命令行引擎（见第 5 节）。
- 建议以**管理员**身份运行（修复类操作需要）。

## 2. 获取代码（私有仓库）

优先用 `gh`（已登录时最省事）：
```bash
gh repo clone dongsheng123132/Open365 -- --depth 1
```
或用 git（需要有权限的凭据）：
```bash
git clone --depth 1 https://github.com/dongsheng123132/Open365.git
```
成功标志：出现 `Open365/` 目录且内含 `install.ps1`、`engine/`、`gui/`。

## 3. 安装（一条命令）

```powershell
cd Open365
powershell -ExecutionPolicy Bypass -File install.ps1
```
带开机自启：
```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Autostart
```
只编译不启动（无头环境/CI）：
```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -NoLaunch
```

**判断成败（AI 必读）**：`install.ps1` 的**退出码 0 = 成功，1 = 失败**；每步打印 `[OK]` / `[FAIL]`。脚本幂等，可重复运行。

## 4. 验证安装

```powershell
# a) 产物存在
Test-Path .\Open365.exe                       # -> True

# b) 引擎可跑（只读、不改系统），返回 JSON 即正常
powershell -ExecutionPolicy Bypass -File engine\security.ps1 check -Json

# c) 全套自测（模拟故障→验证→自动还原，不碰真实数据）
powershell -ExecutionPolicy Bypass -File tests\run-all.ps1   # 退出码 0 = 全过
```

## 5. 直接调用功能（不开 GUI，适合 AI 自动化）

每个引擎都是自洽 CLI，**默认动作只读**，都支持 `-Json` 输出结构化结果：

```powershell
engine\security.ps1  check       -Json   # 杀毒/防火墙/更新 三道防线体检
engine\security.ps1  enable-all          # 一键复位三道防线（需管理员）
engine\network.ps1   diagnose    -Json   # 网络体检（自动判断病因）
engine\network.ps1   repair-all          # 一键修网（需管理员，之后需重启）
engine\cleaner.ps1   scan        -Json   # 扫垃圾（只报告）
engine\cleaner.ps1   clean -Force        # 清垃圾（-Only key1,key2 可精确到类）
engine\startup.ps1   list        -Json   # 列开机启动项
engine\process.ps1   list        -Json   # 列进程（关键系统进程受保护，禁止结束）
engine\uninstall.ps1 search 关键词 -Json # 搜软件
engine\uninstall.ps1 residue-clean 关键词 -Yes  # 清残留（留底可还原）
engine\focus.ps1     on -Hours 8         # 守夜模式（防熄屏/睡眠，退出自动还原）
```

安全边界（AI 请遵守）：只读动作（`check`/`diagnose`/`scan`/`list`/`status`）随便跑；改系统的动作需要管理员，且多为可还原。不可逆动作（卸载软件、清垃圾）需 `-Force`/`-Yes` 且**建议先把只读结果讲给用户确认**。

## 6. 卸载

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
```
只停进程、删快捷方式与自启任务；**不删源码、不碰用户数据**。

## 7. 给 AI 的注意事项

- **不联网**：本工具全程离线，不要为它配置任何联网/上报。
- **编码**：`.ps1`/`.cs` 源码是 UTF-8 **BOM**（PS 5.1 读中文需要），改文件请保持 BOM。
- **改 GUI 后重编**：`powershell -ExecutionPolicy Bypass -File tools\build-gui.ps1`。若 `Open365.exe` 被占用，先 `Stop-Process -Name Open365`，或用改名法让路。
- **架构纪律**：加功能就新建一个 `engine\<名字>.ps1`（自洽 CLI，默认只读，带 `-Json`），引擎之间零引用。详见 [docs/架构约定.md](docs/架构约定.md)。
