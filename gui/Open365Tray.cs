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
        internal const string Uninstall = "\uECC9"; // 软件卸载（移除）
        internal const string Move = "\uE8B7";   // 软件搬家（文件夹）
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

        // ---------- 程序目录（engine / core / VERSION / stats.json 都相对它找） ----------
        // 用程序集自身的位置，不用 AppDomain.CurrentDomain.BaseDirectory：后者在本程序集
        // 被别的宿主加载时（无头 UI 测试、别的 exe）指向宿主目录，一整套路径会全错。
        internal static readonly string AppDir = ResolveAppDir();

        static string ResolveAppDir()
        {
            try
            {
                string p = System.Reflection.Assembly.GetExecutingAssembly().Location;
                if (!string.IsNullOrEmpty(p))
                {
                    string d = Path.GetDirectoryName(p);
                    if (!string.IsNullOrEmpty(d)) return d;
                }
            }
            catch { }
            return AppDomain.CurrentDomain.BaseDirectory;
        }

        [STAThread]
        static void Main()
        {
            EngineDir = Path.Combine(AppDir, "engine");
            Application.EnableVisualStyles();
            Dpi.Init();                       // 必须在建任何窗体 / 画任何图标之前

            var menu = new ContextMenuStrip();
            menu.Font = new Font("Microsoft YaHei UI", Dpi.Pt(9.5F));
            // 菜单图标默认会被压回 16×16，高 DPI 下配大字显得针眼一样小
            menu.ImageScalingSize = new Size(Dpi.Px(16), Dpi.Px(16));
            Add(menu, "管理中心 — 一键体检 / 全部功能", "", delegate { ManagerForm.Open("home"); });
            menu.Items.Add(new ToolStripSeparator());
            Add(menu, "电脑体检 — 综合评分 + 逐项修复", "", delegate { ManagerForm.Open("home"); });
            Add(menu, "开机加速 — 启动项管理", "", delegate { ManagerForm.Open("startup"); });
            Add(menu, "进程管理 — 结束占用进程", "", delegate { ManagerForm.Open("process"); });
            Add(menu, "垃圾清理 — 扫描 / 勾选清理", "", delegate { ManagerForm.Open("clean"); });
            Add(menu, "网络修复 — 体检 / 一键修复", "", delegate { ManagerForm.Open("net"); });
            Add(menu, "安全护盾 — 三道防线体检", "", delegate { ManagerForm.Open("security"); });
            Add(menu, "软件卸载 — 搜索 / 强力卸载", "", delegate { ManagerForm.Open("uninstall"); });
            Add(menu, "软件搬家 — 微信/QQ/钉钉数据迁盘", "\uE8B7", delegate { ManagerForm.Open("relocate"); });
            menu.Items.Add(new ToolStripSeparator());
            var nightItem = Add(menu, "守夜模式 — 通宵不熄屏/不睡眠", "", delegate
            {
                if (NightWatch.Active) NightWatch.Off();
                else ManagerForm.Open("focus");
            });
            menu.Items.Add(new ToolStripSeparator());
            Add(menu, "关于 Open365", "", delegate
            {
                ShowAbout(null);
            });
            Add(menu, "退出 Open365", "", delegate { Application.Exit(); });

            Tray = new NotifyIcon();
            Tray.Icon = SystemIcons.Shield;
            Tray.Text = "Open365 开源电脑助手" + VersionSuffix;
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
                    Tray.Text = "Open365 开源电脑助手" + VersionSuffix;
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

        // ---------- 版本号（唯一真相源 = 程序目录下的 VERSION 文件） ----------
        // 不在代码里再抄一份常数：VERSION 同时被 core/registry.ps1 读去生成
        // action-parity.json，两份必然漂移。GUI 运行时读文件，永远跟着走。
        static string version;
        internal static string Version
        {
            get
            {
                if (version != null) return version;
                version = "";
                try
                {
                    string p = Path.Combine(AppDir, "VERSION");
                    if (File.Exists(p))
                    {
                        string s = (File.ReadAllText(p) ?? "").Trim();
                        int nl = s.IndexOfAny(new char[] { '\r', '\n' });   // 只认第一行
                        if (nl >= 0) s = s.Substring(0, nl).Trim();
                        version = s;
                    }
                }
                catch { }
                return version;
            }
        }

        /// 拼在标题 / 托盘提示后面的「 v1.3.0」；读不到 VERSION 就什么都不加。
        internal static string VersionSuffix
        {
            get { return (Version.Length > 0) ? (" v" + Version) : ""; }
        }

        /// 关于对话框：托盘菜单和左下角版本号共用这一份，别抄第二份。
        /// 「检查更新」也在这里 —— 全程序只有这一个入口会主动出网。
        internal static void ShowAbout(IWin32Window owner)
        {
            using (var f = new AboutForm())
            {
                if (owner != null) f.ShowDialog(owner); else f.ShowDialog();
            }
        }

        internal const string HomePage = "https://github.com/dongsheng123132/Open365";

        /// 用系统默认浏览器打开一个 http(s) 链接。失败就把地址复制到剪贴板兜底。
        internal static void OpenUrl(string url)
        {
            if (string.IsNullOrEmpty(url)) return;
            if (!url.StartsWith("http://") && !url.StartsWith("https://")) return;   // 只放行网页，别被清单里的怪地址当成启动器
            try { Process.Start(url); }
            catch
            {
                try
                {
                    Clipboard.SetText(url);
                    MessageBox.Show("打不开浏览器，地址已复制到剪贴板：\n" + url, "Open365",
                        MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
                catch { }
            }
        }

        // ---------- 图标渲染：Segoe MDL2 Assets（Win10/11 系统自带图标字体） ----------
        // WinForms 按钮/菜单画不了彩色 emoji（会变"口"），统一用系统图标字体渲染成位图。
        // px 传的是设计稿（96 DPI）尺寸，这里统一放大 —— 否则高 DPI 下大字配小图标。
        internal static Image MdlIcon(string glyph, Color color, int px)
        {
            px = Dpi.Px(px);
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
            string core = Path.Combine(AppDir, "core\\action-core.ps1");
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
    //  关于 / 检查更新
    //  全程序唯一会主动出网的地方，而且只在用户点了「检查更新」之后才走：
    //  一个空请求体的 GET，不带机器码/本机信息，查到新版也只给下载地址，
    //  绝不后台下载、绝不静默替换文件。业务逻辑在 engine/update.ps1，
    //  这里只是按钮面板 —— 走 update.check 动作，与 CLI / AI 同源。
    // =====================================================================
    internal sealed class AboutForm : Form
    {
        static readonly Color Accent = Color.FromArgb(34, 124, 79);    // 品牌绿
        static readonly Color Sub = Color.FromArgb(118, 126, 136);

        readonly Button btnCheck, btnDownload;
        readonly Label lblStatus;
        string downloadUrl = HomePageFallback;
        bool busy;

        const string HomePageFallback = "https://github.com/dongsheng123132/Open365/releases/latest";

        internal AboutForm()
        {
            Text = "关于 Open365";
            Font = new Font("Microsoft YaHei UI", Dpi.Pt(9.5F));
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false; MinimizeBox = false;
            StartPosition = FormStartPosition.CenterParent;
            BackColor = Color.White;
            ClientSize = new Size(452, 306);
            try { Icon = SystemIcons.Shield; } catch { }

            var icon = new PictureBox();
            icon.Image = Program.MdlIcon(Glyph.ShieldSolid, Accent, 34);
            icon.Size = new Size(38, 38);
            icon.Location = new Point(24, 22);
            icon.SizeMode = PictureBoxSizeMode.CenterImage;

            var title = new Label();
            title.Text = "Open365 · 开源电脑助手";
            title.Font = new Font("Microsoft YaHei UI", Dpi.Pt(13F), FontStyle.Bold);
            title.ForeColor = Color.FromArgb(30, 36, 44);
            title.AutoSize = true;
            title.Location = new Point(70, 22);

            var ver = new Label();
            ver.Text = (Program.Version.Length > 0) ? ("v" + Program.Version) : "版本未知";
            ver.Font = new Font("Microsoft YaHei UI", Dpi.Pt(9F));
            ver.ForeColor = Sub;
            ver.AutoSize = true;
            ver.Location = new Point(72, 50);

            var blurb = new Label();
            blurb.Text = "无广告 · 无弹窗 · 无捆绑 · 不联网上传\r\n\r\n"
                       + "所有动作都由 engine\\*.ps1 明文脚本执行，记事本就能审计。\r\n"
                       + "检查更新只发一个空的 GET，不带机器码、不传任何本机信息；\r\n"
                       + "有新版也只告诉你去哪下，不后台下载、不静默替换文件。";
            blurb.ForeColor = Color.FromArgb(70, 78, 88);
            blurb.AutoSize = false;
            blurb.Location = new Point(26, 80);
            blurb.Size = new Size(400, 92);

            var line = new Panel();
            line.BackColor = Color.FromArgb(232, 234, 238);
            line.Location = new Point(26, 178);
            line.Size = new Size(400, 1);

            btnCheck = MakeBtn("检查更新", true);
            btnCheck.Location = new Point(26, 194);
            // 稳定的非视觉标识：让「这个按钮绑的是哪个动作」可被机器检查（ActionParity 绑定清单）
            btnCheck.Name = "Open365.Gui.UpdateCheck";
            btnCheck.AccessibleName = "Open365.Gui.UpdateCheck";
            btnCheck.Click += delegate { DoCheck(); };

            btnDownload = MakeBtn("打开下载页", false);
            btnDownload.Location = new Point(134, 194);
            btnDownload.Visible = false;
            btnDownload.Click += delegate { Program.OpenUrl(downloadUrl); };

            lblStatus = new Label();
            lblStatus.Text = "";
            lblStatus.AutoSize = false;
            lblStatus.Location = new Point(26, 228);
            lblStatus.Size = new Size(400, 34);
            lblStatus.ForeColor = Sub;

            var home = new LinkLabel();
            home.Text = "项目主页 github.com/dongsheng123132/Open365";
            home.AutoSize = true;
            home.Location = new Point(26, 270);
            home.LinkColor = Accent;
            home.ActiveLinkColor = Accent;
            home.Font = new Font("Microsoft YaHei UI", Dpi.Pt(9F));
            home.LinkClicked += delegate { Program.OpenUrl(Program.HomePage); };

            var btnClose = MakeBtn("关闭", false);
            btnClose.Location = new Point(346, 264);
            btnClose.Click += delegate { Close(); };
            CancelButton = btnClose;

            Controls.Add(icon); Controls.Add(title); Controls.Add(ver);
            Controls.Add(blurb); Controls.Add(line);
            Controls.Add(btnCheck); Controls.Add(btnDownload); Controls.Add(lblStatus);
            Controls.Add(home); Controls.Add(btnClose);

            Dpi.Apply(this);   // 控件全建完再统一缩放
        }

        static Button MakeBtn(string text, bool solid)
        {
            var b = new Button();
            b.Text = text;
            b.Size = new Size(100, 30);
            b.FlatStyle = FlatStyle.Flat;
            b.Cursor = Cursors.Hand;
            b.Font = new Font("Microsoft YaHei UI", Dpi.Pt(9.5F));
            if (solid)
            {
                b.FlatAppearance.BorderSize = 0;
                b.BackColor = Accent; b.ForeColor = Color.White;
            }
            else
            {
                b.FlatAppearance.BorderColor = Color.FromArgb(210, 214, 220);
                b.BackColor = Color.White; b.ForeColor = Color.FromArgb(60, 68, 78);
            }
            return b;
        }

        void DoCheck()
        {
            if (busy) return;
            busy = true;
            btnCheck.Enabled = false;
            btnDownload.Visible = false;
            lblStatus.ForeColor = Sub;
            lblStatus.Text = "正在检查…（只发一个 GET，不上传任何信息）";

            var th = new System.Threading.Thread(delegate ()
            {
                string j = Program.RunAction("update.check", null, false);
                try { BeginInvoke((Action)delegate { OnChecked(j); }); } catch { }
            });
            th.IsBackground = true;
            th.Start();
        }

        void OnChecked(string json)
        {
            busy = false;
            btnCheck.Enabled = true;

            var d = Program.ParseJson(json);
            if (d == null)
            {
                lblStatus.ForeColor = Color.FromArgb(190, 70, 60);
                lblStatus.Text = "检查失败：没能运行更新检查（engine\\update.ps1 缺失或被拦）。";
                return;
            }

            string status = Program.Str(d, "status");
            string latest = Program.Str(d, "latest");
            string url = Program.Str(d, "download_url");
            if (url.Length > 0) downloadUrl = url;

            switch (status)
            {
                case "update-available":
                    lblStatus.ForeColor = Color.FromArgb(190, 130, 20);
                    lblStatus.Text = "发现新版本 v" + latest + "。要不要更新由你决定。";
                    btnDownload.Visible = true;
                    break;
                case "up-to-date":
                    lblStatus.ForeColor = Accent;
                    lblStatus.Text = "已经是最新版本 v" + latest + "。";
                    break;
                case "ahead":
                    // 本机比线上还新（开发版）。说"已经是最新版 v<线上版本>"会让人误以为自己装的是那个版本。
                    lblStatus.ForeColor = Accent;
                    lblStatus.Text = "你这台装的 v" + Program.Version + " 比已发布的 v" + latest + " 还新（开发版），不用更新。";
                    break;
                case "unknown":
                    lblStatus.ForeColor = Color.FromArgb(190, 130, 20);
                    lblStatus.Text = Program.Str(d, "error");
                    btnDownload.Visible = true;
                    break;
                default:
                    lblStatus.ForeColor = Color.FromArgb(190, 70, 60);
                    lblStatus.Text = "查不到更新（网络不通或被墙）。可以点右边手动去看。";
                    downloadUrl = HomePageFallback;
                    btnDownload.Visible = true;
                    break;
            }
        }
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
            get { return Path.Combine(Program.AppDir, "stats.json"); }
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
