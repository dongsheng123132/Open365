// Open365 最小托盘外壳 (C# / .NET Framework, 用系统自带 csc 编译)
// 平时只有右下角托盘图标常驻, 内存极低.
// 安全护盾 / 网络修复 / 垃圾清理 = 读引擎 -Json -> 友好图形弹窗 + 一键按钮 (不弹黑窗).
// 开机加速 / 软件卸载 / 守夜模式 = 暂时仍在控制台窗口显示.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace Open365
{
    static class Program
    {
        internal static string EngineDir;

        [STAThread]
        static void Main()
        {
            EngineDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "engine");

            var menu = new ContextMenuStrip();
            Add(menu, "🧰  管理中心 — 开机启动 / 进程 / 修复", delegate { ManagerForm.Open("startup"); });
            menu.Items.Add(new ToolStripSeparator());
            Add(menu, "🚀  开机加速 — 启动项管理(图形)", delegate { ManagerForm.Open("startup"); });
            Add(menu, "🧠  进程管理 — 结束占用进程(图形)", delegate { ManagerForm.Open("process"); });
            menu.Items.Add(new ToolStripSeparator());
            Add(menu, "🛡️  安全护盾 — 一键体检/修复", delegate { DoSecurity(); });
            Add(menu, "🔧  网络修复 — 一键体检/修复", delegate { DoNetwork(); });
            Add(menu, "🧹  垃圾清理 — 一键扫描/清理", delegate { DoClean(); });
            Add(menu, "🗑️  软件卸载 — 搜索(顽固软件也能卸)", delegate { DoUninstall(); });
            Add(menu, "🌙  守夜模式 — 开启", delegate { RunConsole("focus.ps1", "on"); });
            menu.Items.Add(new ToolStripSeparator());
            Add(menu, "关于 Open365", delegate {
                MessageBox.Show("Open365 · 开源电脑助手\n无广告 · 无弹窗 · 无捆绑 · 不联网上传\n\n左键或右键点击托盘盾牌图标，选择功能。",
                    "Open365", MessageBoxButtons.OK, MessageBoxIcon.Information);
            });
            Add(menu, "退出 Open365", delegate { Application.Exit(); });

            var icon = new NotifyIcon();
            icon.Icon = SystemIcons.Shield;
            icon.Text = "Open365 开源电脑助手";
            icon.Visible = true;
            icon.ContextMenuStrip = menu;
            icon.MouseClick += delegate(object s, MouseEventArgs e) {
                if (e.Button == MouseButtons.Left) menu.Show(Cursor.Position);
            };
            icon.ShowBalloonTip(2500, "Open365 已常驻右下角", "左键或右键点击托盘盾牌图标，选择功能。", ToolTipIcon.Info);

            Application.Run();
            icon.Visible = false;
            icon.Dispose();
        }

        static void Add(ContextMenuStrip menu, string text, EventHandler onClick)
        {
            var it = new ToolStripMenuItem(text);
            it.Click += onClick;
            menu.Items.Add(it);
        }

        // ---------- 功能：安全护盾 ----------
        internal static void DoSecurity()
        {
            var d = ParseJson(RunJsonWait("正在检测安全状态…", "security.ps1", "check"));
            if (d == null) { RunConsole("security.ps1", "check"); return; }
            var def = Obj(d, "defender"); var fw = Obj(d, "firewall"); var up = Obj(d, "update");

            string rt = Bool(def, "available") ? (Bool(def, "realtime_enabled") ? "✅ 已开启" : "❌ 已关闭") : "❓ 读不到";
            string av = Bool(def, "available") ? (Bool(def, "antivirus_enabled") ? "✅ 已开启" : "❌ 已关闭") : "❓ 读不到";
            string fwS = Bool(fw, "all_on") ? "✅ 已开启" : "❌ 有未开启";
            string upS = (Str(up, "status") == "Running") ? "✅ 运行中" : "❌ 已停止";

            string body = "🛡  实时杀毒(Defender)：" + rt + "\n"
                        + "🛡  杀毒引擎　　　　：" + av + "\n"
                        + "🔥  防火墙　　　　　：" + fwS + "\n"
                        + "🔄  系统更新　　　　：" + upS + "\n";
            if (Bool(def, "available")) body += "📅  病毒库　　　　　：" + Int(def, "signature_age_days") + " 天前更新\n";
            body += "\n" + Str(d, "verdict");

            var problems = Arr(d, "problems");
            int pc = (problems == null) ? 0 : problems.Length;
            if (pc > 0)
            {
                body += "\n\n发现 " + pc + " 个隐患：";
                foreach (var p in problems) body += "\n  • " + p;
                if (ShowResult("安全护盾自检", body, "🛡 一键修复"))
                {
                    RunJsonWait("正在修复（开启 Defender + 防火墙 + 更新）…", "security.ps1", "enable-all");
                    DoSecurity(); // 修复后重新体检并展示最新状态
                }
            }
            else
            {
                ShowResult("安全护盾自检", body, null);
            }
        }

        // ---------- 功能：网络修复 ----------
        internal static void DoNetwork()
        {
            var d = ParseJson(RunJsonWait("正在检测网络（约需几秒）…", "network.ps1", "diagnose"));
            if (d == null) { RunConsole("network.ps1", "diagnose"); return; }
            var t = Obj(d, "tests"); var px = Obj(d, "proxy");

            string body = "🌐  网页能否打开："  + (Bool(t, "web_works") ? "✅ 正常" : "❌ 打不开") + "\n"
                        + "🔎  DNS 域名解析："  + (Bool(t, "dns_works") ? "✅ 正常" : "❌ 失败") + "\n"
                        + "📡  外网连通　　："  + (Bool(t, "internet_reachable") ? "✅ 正常" : "❌ 不通") + "\n"
                        + "📶  连到路由器　："  + (Bool(t, "gateway_reachable") ? "✅ 正常" : "❌ 不通") + "\n"
                        + "🧩  系统代理　　："  + (Bool(px, "enabled") ? ("⚠️ 已开启 → " + Str(px, "server")) : "✅ 未开启") + "\n"
                        + "\n" + Str(d, "verdict");

            string sug = Str(d, "suggestion");
            string act = null;
            if (sug == "clear-proxy") act = "清除异常代理";
            else if (sug == "set-dns") act = "切换公共 DNS";
            else if (sug == "repair-all") act = "🔧 一键全修复";

            if (act != null)
            {
                if (ShowResult("网络体检", body, act))
                {
                    var rd = ParseJson(RunJsonWait("正在修复…", "network.ps1", sug));
                    bool reboot = rd != null && Bool(rd, "reboot_required");
                    ShowResult("修复完成",
                        reboot ? "✅ 已执行修复。\n\n其中 Winsock / TCP-IP 重置需要【重启电脑】后才生效，\n请重启后再试浏览器。"
                               : "✅ 已执行修复，请再试试浏览器。", null);
                }
            }
            else
            {
                ShowResult("网络体检", body, null);
            }
        }

        // ---------- 功能：垃圾清理 ----------
        internal static void DoClean()
        {
            var d = ParseJson(RunJsonWait("正在扫描垃圾…", "cleaner.ps1", "scan"));
            if (d == null) { RunConsole("cleaner.ps1", "scan"); return; }

            string total = Str(d, "total_human");
            double tb = 0; object tv;
            if (d.TryGetValue("total_bytes", out tv) && tv != null) double.TryParse(tv.ToString(), out tb);

            string body = "🧹  扫描完成，可清理：\n";
            var items = Arr(d, "items");
            if (items != null)
                foreach (var it in items)
                {
                    var io = it as Dictionary<string, object>;
                    long b = 0; object bv;
                    if (io != null && io.TryGetValue("bytes", out bv) && bv != null) long.TryParse(bv.ToString(), out b);
                    if (b > 0) body += "\n  • " + Str(io, "name") + "：" + Str(io, "human");
                }
            body += "\n\n合计可释放：" + total;

            if (tb > 0)
            {
                if (ShowResult("垃圾清理", body, "🧹 立即清理 " + total))
                {
                    var rd = ParseJson(RunJsonWait("正在清理…", "cleaner.ps1", "clean -Force"));
                    string freed = (rd != null) ? Str(rd, "total_freed_human") : "";
                    ShowResult("清理完成", "✅ 清理完成，已释放空间：" + freed, null);
                }
            }
            else
            {
                ShowResult("垃圾清理", "✨ 已经很干净了，没有可清理的垃圾。", null);
            }
        }

        // ---------- 功能：软件卸载（仍用控制台） ----------
        static void DoUninstall()
        {
            string kw = Microsoft.VisualBasic.Interaction.InputBox(
                "输入软件名关键词搜索，留空=列出全部已安装软件", "Open365 软件卸载", "");
            if (!string.IsNullOrEmpty(kw)) RunConsole("uninstall.ps1", "search " + kw);
            else RunConsole("uninstall.ps1", "list");
        }

        // ---------- 运行引擎并捕获 JSON（静默，带"请稍候"进度框） ----------
        static string RunJsonWait(string waitText, string file, string args)
        {
            string result = null;
            var f = new Form();
            f.Text = "Open365";
            f.FormBorderStyle = FormBorderStyle.FixedDialog;
            f.StartPosition = FormStartPosition.CenterScreen;
            f.ControlBox = false; f.ShowInTaskbar = false; f.TopMost = true;
            f.Font = new Font("Microsoft YaHei UI", 10F);
            f.ClientSize = new Size(320, 92);
            var lbl = new Label(); lbl.AutoSize = true; lbl.Location = new Point(20, 18); lbl.Text = waitText;
            f.Controls.Add(lbl);
            var pb = new ProgressBar(); pb.Style = ProgressBarStyle.Marquee; pb.Location = new Point(20, 50); pb.Size = new Size(280, 18);
            f.Controls.Add(pb);
            var th = new Thread(delegate () {
                result = RunJson(file, args);
                try { f.BeginInvoke((Action)(f.Close)); } catch { }
            });
            th.IsBackground = true;
            f.Shown += delegate { th.Start(); };
            f.ShowDialog();
            return result;
        }

        internal static string RunJson(string file, string args)
        {
            string path = Path.Combine(EngineDir, file);
            if (!File.Exists(path)) return null;
            return RunPs("[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; & '" + path + "' " + args + " -Json");
        }

        // 带一个 -Id 参数的引擎调用：用单引号安全包裹值（含空格/冒号/反斜杠也安全），
        // PowerShell 单引号字符串里的 ' 需转义成 ''。
        internal static string RunJsonId(string file, string action, string idValue)
        {
            string path = Path.Combine(EngineDir, file);
            if (!File.Exists(path)) return null;
            string safe = (idValue ?? "").Replace("'", "''");
            return RunPs("[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; & '" + path + "' " + action + " -Id '" + safe + "' -Json");
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

        // ---------- 在控制台窗口运行引擎（其余功能 / 兜底） ----------
        static void RunConsole(string file, string action)
        {
            string path = Path.Combine(EngineDir, file);
            if (!File.Exists(path)) { MessageBox.Show("找不到引擎: " + path); return; }
            try
            {
                var psi = new ProcessStartInfo();
                psi.FileName = "powershell.exe";
                psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -NoExit -Command "
                    + "\"[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; & '" + path + "' " + action + "\"";
                psi.UseShellExecute = true;
                Process.Start(psi);
            }
            catch (Exception ex) { MessageBox.Show("启动失败: " + ex.Message); }
        }

        // ---------- 通用结果弹窗：返回 true 表示用户点了"动作"按钮 ----------
        static bool ShowResult(string title, string body, string actionText)
        {
            var f = new Form();
            f.Text = title;
            f.FormBorderStyle = FormBorderStyle.FixedDialog;
            f.StartPosition = FormStartPosition.CenterScreen;
            f.MaximizeBox = false; f.MinimizeBox = false; f.ShowInTaskbar = false; f.TopMost = true;
            f.Font = new Font("Microsoft YaHei UI", 10.5F);
            f.ClientSize = new Size(440, 120);

            var lbl = new Label();
            lbl.AutoSize = true;
            lbl.MaximumSize = new Size(404, 0);
            lbl.Location = new Point(18, 16);
            lbl.Text = body;
            f.Controls.Add(lbl);

            int by = lbl.Bottom + 18;
            var btnClose = new Button();
            btnClose.Text = (actionText == null) ? "关闭" : "暂不";
            btnClose.Size = new Size(90, 32);
            btnClose.DialogResult = DialogResult.Cancel;
            f.Controls.Add(btnClose);

            Button btnAct = null;
            if (actionText != null)
            {
                btnAct = new Button();
                btnAct.Text = actionText;
                btnAct.Size = new Size(160, 32);
                btnAct.DialogResult = DialogResult.OK;
                f.Controls.Add(btnAct);
            }

            int w = Math.Max(440, lbl.Right + 18);
            f.ClientSize = new Size(w, by + 32 + 16);
            if (btnAct != null)
            {
                btnAct.Location = new Point(f.ClientSize.Width - 18 - btnClose.Width - 8 - btnAct.Width, by);
                btnClose.Location = new Point(f.ClientSize.Width - 18 - btnClose.Width, by);
                f.AcceptButton = btnAct;
            }
            else
            {
                btnClose.Location = new Point(f.ClientSize.Width - 18 - btnClose.Width, by);
                f.AcceptButton = btnClose;
            }
            f.CancelButton = btnClose;

            return f.ShowDialog() == DialogResult.OK;
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
        internal static Dictionary<string, object> Obj(Dictionary<string, object> d, string k)
        { object v; return (d != null && d.TryGetValue(k, out v)) ? v as Dictionary<string, object> : null; }
        internal static object[] Arr(Dictionary<string, object> d, string k)
        { object v; return (d != null && d.TryGetValue(k, out v)) ? v as object[] : null; }
    }
}
