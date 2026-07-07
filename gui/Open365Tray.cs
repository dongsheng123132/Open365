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
            Add(menu, "🏠  管理中心 — 一键体检 / 全部功能", delegate { ManagerForm.Open("home"); });
            menu.Items.Add(new ToolStripSeparator());
            Add(menu, "💻  电脑体检 — 综合评分 + 逐项修复", delegate { ManagerForm.Open("home"); });
            Add(menu, "🚀  开机加速 — 启动项管理", delegate { ManagerForm.Open("startup"); });
            Add(menu, "🧠  进程管理 — 结束占用进程", delegate { ManagerForm.Open("process"); });
            Add(menu, "🧹  垃圾清理 — 扫描 / 勾选清理", delegate { ManagerForm.Open("clean"); });
            Add(menu, "🔧  网络修复 — 体检 / 一键修复", delegate { ManagerForm.Open("net"); });
            Add(menu, "🛡️  安全护盾 — 三道防线体检", delegate { ManagerForm.Open("security"); });
            Add(menu, "🗑️  软件卸载 — 搜索 / 强力卸载", delegate { ManagerForm.Open("uninstall"); });
            menu.Items.Add(new ToolStripSeparator());
            var nightItem = Add(menu, "🌙  守夜模式 — 通宵不熄屏/不睡眠", delegate
            {
                if (NightWatch.Active) NightWatch.Off();
                else ManagerForm.Open("focus");
            });
            menu.Items.Add(new ToolStripSeparator());
            Add(menu, "关于 Open365", delegate
            {
                MessageBox.Show("Open365 · 开源电脑助手\n无广告 · 无弹窗 · 无捆绑 · 不联网上传\n\n" +
                    "点击托盘盾牌图标打开管理中心；\n所有动作都由 engine\\*.ps1 明文脚本执行，记事本就能审计。",
                    "Open365", MessageBoxButtons.OK, MessageBoxIcon.Information);
            });
            Add(menu, "退出 Open365", delegate { Application.Exit(); });

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
                    nightItem.Text = "🌙  守夜中 — 点击退出（自动还原）";
                    Tray.Text = "Open365 · 守夜模式进行中";
                }
                else
                {
                    nightItem.Text = "🌙  守夜模式 — 通宵不熄屏/不睡眠";
                    Tray.Text = "Open365 开源电脑助手";
                }
            };

            Application.Run();
            NightWatch.Off();          // 退出兜底：还原守夜的所有系统改动
            Tray.Visible = false;
            Tray.Dispose();
        }

        static ToolStripMenuItem Add(ContextMenuStrip menu, string text, EventHandler onClick)
        {
            var it = new ToolStripMenuItem(text);
            it.Click += onClick;
            menu.Items.Add(it);
            return it;
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
