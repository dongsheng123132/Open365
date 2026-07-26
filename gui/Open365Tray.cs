// Open365 托盘外壳 (C# / .NET Framework, 用系统自带 csc 编译)
// 平时只有右下角托盘图标常驻, 内存极低。
// 所有功能入口统一指向图形「管理中心」(ManagerForm) 的对应页面。
// 守夜模式 (NightWatch) 在本进程内实现：SetThreadExecutionState 防熄屏/防睡眠 +
// 临时挡 Windows 更新自动重启；开关即时生效，退出程序自动还原。
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Open365
{
    // Segoe MDL2 Assets 图标码位（Win10/11 系统自带图标字体，已在本机渲染验证均有墨迹）。
    // 用 \uXXXX 转义而非直接嵌 PUA 字符，避免源码编码坑。
    internal static class Glyph
    {
        internal const string Health = "";   // 体检（心跳脉搏）
        internal const string Power = "";    // 开机启动
        internal const string Tasks = "";    // 运行进程（任务视图）
        internal const string Broom = "";    // 垃圾清理（垃圾桶）
        internal const string Wifi = "";     // 网络修复
        internal const string Shield = "";   // 安全护盾（盾牌）
        internal const string ShieldSolid = ""; // 品牌实心盾
        internal const string Uninstall = ""; // 软件卸载（移除）
        internal const string Moon = "";     // 守夜模式（月亮）
        internal const string Sun = "";      // 守夜未开启（亮度/太阳）
        internal const string Refresh = "";  // 刷新
        internal const string Search = "";   // 搜索
        internal const string Repair = "";   // 修复（扳手）
        internal const string Check = "";    // 对勾
        internal const string Warning = "";  // 警告
        internal const string Error = "";    // 错误
        internal const string Info = "";     // 关于/信息
        internal const string Cancel = "";   // 退出（叉）
    }

    static class Program
    {
        internal static string EngineDir;
        internal static NotifyIcon Tray;

        [STAThread]
        static void Main()
        {
            EngineDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "engine");
            Application.EnableVisualStyles();

            var menu = new ContextMenuStrip();
            menu.Font = new Font("Microsoft YaHei UI", 9.5F);
            Add(menu, "管理中心 — 一键体检 / 全部功能", "", delegate { ManagerForm.Open("home"); });
            menu.Items.Add(new ToolStripSeparator());
            Add(menu, "电脑体检 — 综合评分 + 逐项修复", "", delegate { ManagerForm.Open("home"); });
            Add(menu, "开机加速 — 启动项管理", "", delegate { ManagerForm.Open("startup"); });
            Add(menu, "进程管理 — 结束占用进程", "", delegate { ManagerForm.Open("process"); });
            Add(menu, "垃圾清理 — 扫描 / 勾选清理", "", delegate { ManagerForm.Open("clean"); });
            Add(menu, "网络修复 — 体检 / 一键修复", "", delegate { ManagerForm.Open("net"); });
            Add(menu, "安全护盾 — 三道防线体检", "", delegate { ManagerForm.Open("security"); });
            Add(menu, "软件卸载 — 搜索 / 强力卸载", "", delegate { ManagerForm.Open("uninstall"); });
            menu.Items.Add(new ToolStripSeparator());
            var nightItem = Add(menu, "守夜模式 — 通宵不熄屏/不睡眠", "", delegate
            {
                if (NightWatch.Active) NightWatch.Off();
                else ManagerForm.Open("focus");
            });
            menu.Items.Add(new ToolStripSeparator());
            Add(menu, "关于 Open365", "", delegate
            {
                MessageBox.Show("Open365 · 开源电脑助手\n无广告 · 无弹窗 · 无捆绑 · 不联网上传\n\n" +
                    "点击托盘盾牌图标打开管理中心；\n所有动作都由 engine\\*.ps1 明文脚本执行，记事本就能审计。",
                    "Open365", MessageBoxButtons.OK, MessageBoxIcon.Information);
            });
            Add(menu, "退出 Open365", "", delegate { Application.Exit(); });

            Tray = new NotifyIcon();
            Tray.Icon = SystemIcons.Shield;
            Tray.Text = "Open365 开源电脑助手";
            Tray.Visible = true;
            Tray.ContextMenuStrip = menu;
            Tray.MouseClick += delegate (object s, MouseEventArgs e)
            {
                if (e.Button == MouseButtons.Left) menu.Show(Cursor.Position);
            };
            Tray.DoubleClick += delegate { ManagerForm.Open("home"); };
            Tray.ShowBalloonTip(2500, "Open365 已常驻右下角", "点击托盘盾牌图标打开管理中心。", ToolTipIcon.Info);

            NightWatch.Changed += delegate
            {
                if (NightWatch.Active)
                {
                    nightItem.Text = "守夜中 — 点击退出（自动还原）";
                    Tray.Text = "Open365 · 守夜模式进行中";
                }
                else
                {
                    nightItem.Text = "守夜模式 — 通宵不熄屏/不睡眠";
                    Tray.Text = "Open365 开源电脑助手";
                }
            };

            Application.Run();
            NightWatch.Off();          // 退出兜底：还原守夜的所有系统改动
            Tray.Visible = false;
            Tray.Dispose();
        }

        static ToolStripMenuItem Add(ContextMenuStrip menu, string text, string glyph, EventHandler onClick)
        {
            var it = new ToolStripMenuItem(text);
            it.Image = MdlIcon(glyph, Color.FromArgb(70, 90, 110), 16);
            it.Click += onClick;
            menu.Items.Add(it);
            return it;
        }

        // ---------- 图标渲染：Segoe MDL2 Assets（Win10/11 系统自带图标字体） ----------
        // WinForms 按钮/菜单画不了彩色 emoji（会变"口"），统一用系统图标字体渲染成位图。
        internal static Image MdlIcon(string glyph, Color color, int px)
        {
            var bmp = new System.Drawing.Bitmap(px + 2, px + 2);
            using (var g = Graphics.FromImage(bmp))
            using (var f = new Font("Segoe MDL2 Assets", px, GraphicsUnit.Pixel))
            using (var br = new SolidBrush(color))
            {
                g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                var sz = g.MeasureString(glyph, f);
                g.DrawString(glyph, f, br, (bmp.Width - sz.Width) / 2f, (bmp.Height - sz.Height) / 2f);
            }
            return bmp;
        }

        // ---------- 运行引擎并捕获 JSON（静默） ----------
        internal static string RunJson(string file, string args)
        {
            string path = Path.Combine(EngineDir, file);
            if (!File.Exists(path)) return null;
            return RunPs("[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; & '" + path + "' " + args + " -Json");
        }

        // 带一个 -Id 参数的引擎调用（startup/process 用）
        internal static string RunJsonId(string file, string action, string idValue)
        {
            return RunJson(file, action + " -Id " + Quote(idValue));
        }

        // ---------- 动作核心（ActionParity 0.1 / 影核协议） ----------
        // 已同源的功能一律走这里：GUI 按钮、CLI、AI 调用的是同一个 Action ID、
        // 同一份输入输出契约、同一道权限闸门。GUI 不再自己拼引擎命令行。
        // 返回值是动作 output 的 JSON（失败返回 null），因此页面解析代码保持不变。
        internal static string RunAction(string actionId, string inputJson, bool confirm)
        {
            string core = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "core\\action-core.ps1");
            if (!File.Exists(core)) return null;

            string tmp = null;
            try
            {
                string cmd = "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; & " + Quote(core)
                           + " run " + actionId + " -Json";
                if (!string.IsNullOrEmpty(inputJson))
                {
                    // 输入走临时文件：JSON 里的双引号塞进 -Command 会把命令行拆坏
                    tmp = Path.Combine(Path.GetTempPath(), "open365-action-" + Guid.NewGuid().ToString("N") + ".json");
                    File.WriteAllText(tmp, inputJson, new UTF8Encoding(false));
                    cmd += " -InputFile " + Quote(tmp);
                }
                if (confirm) cmd += " -Confirm";

                var env = ParseJson(RunPs(cmd));
                if (env == null || !Bool(env, "ok")) return null;
                object output;
                if (!env.TryGetValue("output", out output) || output == null) return null;
                return new JavaScriptSerializer().Serialize(output);
            }
            catch { return null; }
            finally
            {
                if (tmp != null) { try { File.Delete(tmp); } catch { } }
            }
        }

        // 拼一个简单的动作输入 JSON：JsonInput("query", kw)
        internal static string JsonInput(params string[] keyValues)
        {
            var d = new Dictionary<string, object>();
            for (int i = 0; i + 1 < keyValues.Length; i += 2) d[keyValues[i]] = keyValues[i + 1];
            return new JavaScriptSerializer().Serialize(d);
        }

        // PowerShell 单引号安全包裹：' 转义成 ''，双引号直接去掉（防拆外层 -Command）
        internal static string Quote(string v)
        {
            return "'" + (v ?? "").Replace("'", "''").Replace("\"", "") + "'";
        }

        static string RunPs(string inner)
        {
            try
            {
                var psi = new ProcessStartInfo();
                psi.FileName = "powershell.exe";
                psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command \"" + inner + "\"";
                psi.UseShellExecute = false;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                psi.CreateNoWindow = true;
                psi.StandardOutputEncoding = Encoding.UTF8;
                var p = Process.Start(psi);
                // 后台把 stderr 抽干：否则引擎往 stderr 写多了会把管道缓冲写满，
                // 子进程阻塞在写 stderr、父进程阻塞在读 stdout -> 死锁挂起整个 GUI。
                var errThread = new System.Threading.Thread(delegate ()
                {
                    try { p.StandardError.ReadToEnd(); } catch { }
                });
                errThread.IsBackground = true;
                errThread.Start();
                string outp = p.StandardOutput.ReadToEnd();
                p.WaitForExit();
                return (outp == null) ? null : outp.Trim();
            }
            catch { return null; }
        }

        // ---------- JSON 小工具（GUI 程序集内共用） ----------
        internal static Dictionary<string, object> ParseJson(string json)
        {
            if (string.IsNullOrEmpty(json)) return null;
            try { return new JavaScriptSerializer().DeserializeObject(json) as Dictionary<string, object>; }
            catch { return null; }
        }
        internal static bool Bool(Dictionary<string, object> d, string k)
        { object v; return d != null && d.TryGetValue(k, out v) && v is bool && (bool)v; }
        internal static string Str(Dictionary<string, object> d, string k)
        { object v; return (d != null && d.TryGetValue(k, out v) && v != null) ? v.ToString() : ""; }
        internal static int Int(Dictionary<string, object> d, string k)
        { object v; int r; return (d != null && d.TryGetValue(k, out v) && v != null && int.TryParse(v.ToString(), out r)) ? r : 0; }
        internal static long Long(Dictionary<string, object> d, string k)
        { object v; long r; return (d != null && d.TryGetValue(k, out v) && v != null && long.TryParse(v.ToString(), out r)) ? r : 0L; }
        internal static Dictionary<string, object> Obj(Dictionary<string, object> d, string k)
        { object v; return (d != null && d.TryGetValue(k, out v)) ? v as Dictionary<string, object> : null; }
        internal static object[] Arr(Dictionary<string, object> d, string k)
        { object v; return (d != null && d.TryGetValue(k, out v)) ? v as object[] : null; }
    }

    // =====================================================================
    //  本地防护统计（stats.json 存在程序目录，纯本地、不联网）
    //  给首页"安全感数值"用：已守护天数 / 累计清理垃圾 / 累计修复次数。
    // =====================================================================
    internal static class LocalStats
    {
        static Dictionary<string, object> d;
        static string FilePath
        {
            get { return Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "stats.json"); }
        }

        static void Load()
        {
            if (d != null) return;
            try { d = Program.ParseJson(File.ReadAllText(FilePath)); } catch { }
            if (d == null) d = new Dictionary<string, object>();
            if (!d.ContainsKey("first_run"))
            {
                d["first_run"] = DateTime.Now.ToString("yyyy-MM-dd");
                Save();
            }
        }

        static void Save()
        {
            try { File.WriteAllText(FilePath, new JavaScriptSerializer().Serialize(d)); } catch { }
        }

        internal static int GuardDays
        {
            get
            {
                Load();
                DateTime f;
                if (!DateTime.TryParse(Program.Str(d, "first_run"), out f)) return 1;
                return Math.Max(1, (int)(DateTime.Now.Date - f.Date).TotalDays + 1);
            }
        }

        internal static long CleanedBytes
        {
            get { Load(); return Program.Long(d, "cleaned_bytes"); }
        }

        internal static void AddCleaned(long bytes)
        {
            Load();
            d["cleaned_bytes"] = CleanedBytes + bytes;
            Save();
        }

        internal static int Fixes
        {
            get { Load(); return Program.Int(d, "fixes"); }
        }

        internal static void IncFixes()
        {
            Load();
            d["fixes"] = Fixes + 1;
            Save();
        }
    }

    // =====================================================================
    //  守夜模式（进程内实现，与 engine/focus.ps1 同语义）
    //  1) SetThreadExecutionState 声明"正在忙" -> 不熄屏/不睡眠（关掉即还原）
    //  2) 临时设 NoAutoRebootWithLoggedOnUsers=1 挡更新自动重启，
    //     退出时精确还原（键是我们建的就删键；原本有值就写回原值）。
    // =====================================================================
    internal static class NightWatch
    {
        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        static extern uint SetThreadExecutionState(uint esFlags);
        const uint ES_CONTINUOUS = 0x80000000;
        const uint ES_SYSTEM_REQUIRED = 0x00000001;
        const uint ES_DISPLAY_REQUIRED = 0x00000002;

        internal static bool Active;
        internal static DateTime StartedAt;
        internal static DateTime Deadline = DateTime.MinValue;   // MinValue = 一直守夜
        internal static event Action Changed;

        static bool keepDisplay;
        static Timer keepTimer;                                  // UI 线程定时器

        const string WU_KEY = @"SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU";
        const string WU_VAL = "NoAutoRebootWithLoggedOnUsers";
        static bool wuApplied, wuKeyCreated, wuHadValue;
        static object wuOldValue;

        internal static void On(bool keepScreenOn, bool blockUpdateReboot, int hours)
        {
            keepDisplay = keepScreenOn;
            StartedAt = DateTime.Now;
            Deadline = (hours > 0) ? StartedAt.AddHours(hours) : DateTime.MinValue;
            AssertAwake();
            if (blockUpdateReboot) TryBlockReboot();
            if (keepTimer == null)
            {
                keepTimer = new Timer();
                keepTimer.Interval = 50000;                      // 每 50 秒重新声明一次
                keepTimer.Tick += delegate { Tick(); };
            }
            keepTimer.Start();
            Active = true;
            RaiseChanged();
        }

        internal static void Off()
        {
            if (!Active) return;
            Active = false;
            if (keepTimer != null) keepTimer.Stop();
            SetThreadExecutionState(ES_CONTINUOUS);              // 清除"别睡"声明
            RestoreReboot();
            RaiseChanged();
        }

        static void Tick()
        {
            if (!Active) return;
            if (Deadline != DateTime.MinValue && DateTime.Now >= Deadline)
            {
                Off();
                if (Program.Tray != null)
                    Program.Tray.ShowBalloonTip(3000, "守夜模式已结束",
                        "到达设定时长，已自动退出并还原所有设置。", ToolTipIcon.Info);
                return;
            }
            AssertAwake();
        }

        static void AssertAwake()
        {
            uint f = ES_CONTINUOUS | ES_SYSTEM_REQUIRED;
            if (keepDisplay) f |= ES_DISPLAY_REQUIRED;
            SetThreadExecutionState(f);
        }

        static void TryBlockReboot()
        {
            try
            {
                var k = Registry.LocalMachine.OpenSubKey(WU_KEY, true);
                if (k == null) { k = Registry.LocalMachine.CreateSubKey(WU_KEY); wuKeyCreated = true; }
                else
                {
                    var v = k.GetValue(WU_VAL);
                    if (v != null) { wuHadValue = true; wuOldValue = v; }
                }
                k.SetValue(WU_VAL, 1, RegistryValueKind.DWord);
                k.Close();
                wuApplied = true;
            }
            catch { wuApplied = false; }                          // 没权限就跳过，防熄屏照常生效
        }

        static void RestoreReboot()
        {
            if (!wuApplied) return;
            try
            {
                if (wuKeyCreated)
                {
                    Registry.LocalMachine.DeleteSubKeyTree(WU_KEY, false);
                }
                else
                {
                    var k = Registry.LocalMachine.OpenSubKey(WU_KEY, true);
                    if (k != null)
                    {
                        if (wuHadValue) k.SetValue(WU_VAL, wuOldValue, RegistryValueKind.DWord);
                        else k.DeleteValue(WU_VAL, false);
                        k.Close();
                    }
                }
            }
            catch { }
            wuApplied = false; wuKeyCreated = false; wuHadValue = false; wuOldValue = null;
        }

        static void RaiseChanged()
        {
            var h = Changed;
            if (h != null) h();
        }
    }
}
