// Open365 管理中心窗口 (WinForms, 仿 WinUtil 左导航 + 右列表)
// 左侧竖排功能，右侧一张大列表 + 行内操作按钮：
//   开机启动 —— 读 startup.ps1 list -Json，每行 [启用]/[禁用] 一键切换（可还原）。
//   运行进程 —— 读 process.ps1 list -Json，每行 [结束]；关键系统进程置灰、禁止结束。
//   网络/清理/安全 —— 复用托盘里已有的体检/修复弹窗。
// 引擎调用、JSON 解析都复用 Program 里的 internal 方法，不重复造轮子（同一个程序集内）。
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Threading;
using System.Windows.Forms;

namespace Open365
{
    public partial class ManagerForm : Form
    {
        // ---- 单实例：托盘点哪个功能就开到哪一页 ----
        internal static ManagerForm Instance;
        internal static void Open(string page)
        {
            if (Instance == null || Instance.IsDisposed)
            {
                Instance = new ManagerForm();
                Instance.Show();
            }
            else
            {
                if (Instance.WindowState == FormWindowState.Minimized) Instance.WindowState = FormWindowState.Normal;
                Instance.Activate();
                Instance.BringToFront();
            }
            Instance.ShowPage(page);
        }

        // ---- 配色（极简高级灰 + 品牌绿强调；去掉旧「管家蓝」，中性灰不带蓝调） ----
        static readonly Color NavBg = Color.FromArgb(23, 26, 31);      // 深炭中性（去蓝）
        static readonly Color NavHover = Color.FromArgb(36, 40, 47);
        static readonly Color NavActive = Color.FromArgb(34, 124, 79); // 选中=品牌绿（原科技蓝）
        static readonly Color Accent = Color.FromArgb(34, 124, 79);    // 强调色=品牌绿盾
        static readonly Color Body = Color.White;
        static readonly Color AltRow = Color.FromArgb(246, 247, 249);  // 中性浅灰卡片底（去蓝调）

        // ---- 控件 ----
        readonly FlowLayoutPanel navFlow;
        readonly Dictionary<string, Button> navButtons = new Dictionary<string, Button>();
        readonly Dictionary<string, string> navGlyphs = new Dictionary<string, string>();
        readonly Label headTitle, headSub;
        readonly Panel content;

        Panel pageStartup, pageProc;
        DataGridView gridStartup, gridProc;
        Label lblStartupCount, lblProcCount;
        string current = "";

        public ManagerForm()
        {
            Text = "Open365 管理中心";
            Font = new Font("Microsoft YaHei UI", Dpi.Pt(9.5F));
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(1000, 640);
            MinimumSize = new Size(880, 560);
            BackColor = Body;
            try { Icon = SystemIcons.Shield; } catch { }

            // ===== 左侧导航 =====
            var nav = new Panel();
            nav.Dock = DockStyle.Left;
            nav.Width = 172;
            nav.BackColor = NavBg;

            var brand = new Panel();
            brand.Dock = DockStyle.Top;
            brand.Height = 76;
            brand.BackColor = NavBg;
            var brandIcon = new PictureBox();
            brandIcon.Image = Program.MdlIcon(Glyph.ShieldSolid, Color.FromArgb(90, 190, 120), 26);
            brandIcon.Size = new Size(30, 30);
            brandIcon.Location = new Point(16, 16);
            var brandTitle = new Label();
            brandTitle.Text = "Open365";
            brandTitle.ForeColor = Color.White;
            brandTitle.Font = new Font("Microsoft YaHei UI", Dpi.Pt(14F), FontStyle.Bold);
            brandTitle.AutoSize = true;
            brandTitle.Location = new Point(50, 14);
            var brandSub = new Label();
            brandSub.Text = "开源电脑助手";
            brandSub.ForeColor = Color.FromArgb(140, 150, 160);
            brandSub.Font = new Font("Microsoft YaHei UI", Dpi.Pt(9F));
            brandSub.AutoSize = true;
            brandSub.Location = new Point(52, 46);
            brand.Controls.Add(brandIcon);
            brand.Controls.Add(brandSub);
            brand.Controls.Add(brandTitle);

            navFlow = new FlowLayoutPanel();
            navFlow.Dock = DockStyle.Fill;
            navFlow.FlowDirection = FlowDirection.TopDown;
            navFlow.WrapContents = false;
            navFlow.BackColor = NavBg;
            navFlow.Padding = new Padding(0, 8, 0, 0);

            AddNav("电脑体检", "home", Glyph.Health);
            AddNav("开机启动", "startup", Glyph.Power);
            AddNav("运行进程", "process", Glyph.Tasks);
            AddNav("垃圾清理", "clean", Glyph.Broom);
            AddNav("网络修复", "net", Glyph.Wifi);
            AddNav("安全护盾", "security", Glyph.Shield);
            AddNav("软件卸载", "uninstall", Glyph.Uninstall);
            AddNav("软件搬家", "relocate", Glyph.Move);
            AddNav("守夜模式", "focus", Glyph.Moon);

            // 左下角版本号：点一下就是「关于」（版本号读程序目录的 VERSION 文件）
            var verLbl = new Label();
            verLbl.Dock = DockStyle.Bottom;
            verLbl.Height = 34;
            verLbl.Text = (Program.Version.Length > 0) ? ("v" + Program.Version) : "";
            verLbl.TextAlign = ContentAlignment.MiddleCenter;
            verLbl.Font = new Font("Microsoft YaHei UI", Dpi.Pt(9F));
            verLbl.ForeColor = Color.FromArgb(118, 126, 136);
            verLbl.BackColor = NavBg;
            verLbl.Cursor = Cursors.Hand;
            verLbl.Click += delegate { Program.ShowAbout(this); };

            // Dock 是按 Controls 集合倒序处理的：先加 Fill 的，后加要贴边的，
            // 否则 Fill 会把整块吃光，贴边的挤不进去。
            nav.Controls.Add(navFlow);
            nav.Controls.Add(verLbl);
            nav.Controls.Add(brand);

            // ===== 右侧主体 =====
            var bodyPanel = new Panel();
            bodyPanel.Dock = DockStyle.Fill;
            bodyPanel.BackColor = Body;

            var header = new Panel();
            header.Dock = DockStyle.Top;
            header.Height = 70;
            header.BackColor = Body;
            header.Padding = new Padding(22, 0, 22, 0);
            headTitle = new Label();
            headTitle.Font = new Font("Microsoft YaHei UI", Dpi.Pt(15F), FontStyle.Bold);
            headTitle.ForeColor = Color.FromArgb(30, 36, 44);
            headTitle.AutoSize = true;
            headTitle.Location = new Point(22, 14);
            headSub = new Label();
            headSub.Font = new Font("Microsoft YaHei UI", Dpi.Pt(9F));
            headSub.ForeColor = Color.Gray;
            headSub.AutoSize = true;
            headSub.Location = new Point(24, 44);
            header.Controls.Add(headSub);
            header.Controls.Add(headTitle);

            content = new Panel();
            content.Dock = DockStyle.Fill;
            content.BackColor = Body;
            content.Padding = new Padding(16, 4, 16, 12);

            bodyPanel.Controls.Add(content);
            bodyPanel.Controls.Add(header);

            Controls.Add(bodyPanel);
            Controls.Add(nav);

            BuildHomePage();
            BuildStartupPage();
            BuildProcPage();
            BuildCleanPage();
            BuildNetPage();
            BuildSecurityPage();
            BuildUninstallPage();
            BuildRelocatePage();
            BuildFocusPage();

            // 控件全部建完之后再缩放（在这之后创建的控件，尺寸得自己走 Dpi.Px）
            Dpi.Apply(this);

            FormClosed += (s, e) => { Instance = null; };
        }

        // ---------- 导航 ----------
        static readonly Color NavIconDim = Color.FromArgb(150, 156, 165);

        void AddNav(string text, string key, string glyph)
        {
            var b = new Button();
            b.Text = "   " + text;
            b.Tag = key;
            b.Width = 172;
            b.Height = 50;
            b.Margin = new Padding(0);
            b.FlatStyle = FlatStyle.Flat;
            b.FlatAppearance.BorderSize = 0;
            b.FlatAppearance.MouseOverBackColor = NavHover;
            b.TextAlign = ContentAlignment.MiddleLeft;
            b.TextImageRelation = TextImageRelation.ImageBeforeText;
            b.ImageAlign = ContentAlignment.MiddleLeft;
            b.Padding = new Padding(16, 0, 0, 0);
            b.Image = Program.MdlIcon(glyph, NavIconDim, 17);
            b.Font = new Font("Microsoft YaHei UI", Dpi.Pt(10.5F));
            b.ForeColor = Color.Gainsboro;
            b.BackColor = NavBg;
            b.Cursor = Cursors.Hand;
            b.Click += (s, e) => ShowPage(key);
            navButtons[key] = b;
            navGlyphs[key] = glyph;
            navFlow.Controls.Add(b);
        }

        void SetNavActive(string key)
        {
            foreach (var kv in navButtons)
            {
                bool on = kv.Key == key;
                kv.Value.BackColor = on ? NavActive : NavBg;
                kv.Value.ForeColor = on ? Color.White : Color.Gainsboro;
                kv.Value.Font = new Font("Microsoft YaHei UI", Dpi.Pt(10.5F), on ? FontStyle.Bold : FontStyle.Regular);
                kv.Value.Image = Program.MdlIcon(navGlyphs[kv.Key], on ? Color.White : NavIconDim, 17);
            }
        }

        // ---------- 页面切换 ----------

        /// 把功能页挂进右侧主体。所有页面**必须**走这里，别直接 content.Controls.Add ——
        /// 各页是游离面板，构造期那次 Dpi.Apply 缩不到它们，得在挂载前补缩一次（只缩一次）。
        void Mount(Control page)
        {
            Dpi.ScaleOnce(page);
            content.Controls.Add(page);
        }

        internal void ShowPage(string key)
        {
            if (string.IsNullOrEmpty(key)) key = "home";
            current = key;
            SetNavActive(key);
            content.Controls.Clear();
            switch (key)
            {
                case "home":
                    headTitle.Text = "电脑体检";
                    headSub.Text = "一键体检：安全防线 / 垃圾文件 / 开机自启 / 网络连通，一屏看全";
                    Mount(pageHome);
                    if (!homeRan) RunCheckup();
                    LoadSysInfo();
                    break;
                case "startup":
                    headTitle.Text = "开机启动项";
                    headSub.Text = "管理开机自动启动的程序 · 禁用可一键还原（移到备份处，不删除）";
                    Mount(pageStartup);
                    LoadStartup();
                    break;
                case "process":
                    headTitle.Text = "运行进程";
                    headSub.Text = "结束占用资源的进程 · 关键系统进程已保护、禁止结束";
                    Mount(pageProc);
                    LoadProc();
                    break;
                case "net":
                    headTitle.Text = "网络修复";
                    headSub.Text = "专治“微信能上、网页打不开” · 先体检定位病因，再最小修复";
                    Mount(pageNet);
                    if (!netRan) LoadNet();
                    break;
                case "clean":
                    headTitle.Text = "垃圾清理";
                    headSub.Text = "只碰公认安全的缓存 / 临时目录 · 先扫描再勾选，绝不乱删";
                    Mount(pageClean);
                    LoadClean();
                    break;
                case "security":
                    headTitle.Text = "安全护盾";
                    headSub.Text = "Windows 自带三道防线：实时杀毒 / 防火墙 / 系统更新 · 体检与一键复位";
                    Mount(pageSecurity);
                    LoadSecurity();
                    break;
                case "uninstall":
                    headTitle.Text = "软件卸载";
                    headSub.Text = "搜索并卸载软件（顽固 / 捆绑软件也能卸）· 卸完可扫残留";
                    Mount(pageUninstall);
                    if (!unLoaded) LoadApps("");
                    break;
                case "relocate":
                    headTitle.Text = "软件搬家";
                    headSub.Text = "把微信 / QQ / 钉钉 / 企业微信的数据目录搬到别的盘 · 原位置留联接，可一键还原";
                    Mount(pageRelocate);
                    if (!relLoaded) LoadRelocate();
                    break;
                case "focus":
                    headTitle.Text = "守夜模式";
                    headSub.Text = "让 AI 通宵干活：不熄屏 / 不睡眠 / 不被更新重启 · 退出自动还原";
                    Mount(pageFocus);
                    RefreshFocusUi();
                    break;
            }
        }

        // ---------- 通用：一张列表 + 底部条 ----------
        DataGridView NewGrid()
        {
            var g = new DataGridView();
            g.Dock = DockStyle.Fill;
            g.BackgroundColor = Body;
            g.BorderStyle = BorderStyle.None;
            g.RowHeadersVisible = false;
            g.AllowUserToAddRows = false;
            g.AllowUserToDeleteRows = false;
            g.AllowUserToResizeRows = false;
            g.ReadOnly = true;
            g.MultiSelect = false;
            g.SelectionMode = DataGridViewSelectionMode.FullRowSelect;
            g.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill;
            g.ColumnHeadersHeightSizeMode = DataGridViewColumnHeadersHeightSizeMode.DisableResizing;
            // 行高 / 表头高不是控件 Bounds，Form.Scale() 碰不到，得自己缩 ——
            // 否则高 DPI 下字变大、行没变高，文字直接被切掉半截。
            g.ColumnHeadersHeight = Dpi.Px(36);
            g.RowTemplate.Height = Dpi.Px(34);
            g.GridColor = Color.FromArgb(232, 236, 240);
            g.CellBorderStyle = DataGridViewCellBorderStyle.SingleHorizontal;
            g.EnableHeadersVisualStyles = false;
            g.ColumnHeadersDefaultCellStyle.BackColor = Color.FromArgb(243, 244, 246);
            g.ColumnHeadersDefaultCellStyle.ForeColor = Color.FromArgb(60, 70, 80);
            g.ColumnHeadersDefaultCellStyle.Font = new Font("Microsoft YaHei UI", Dpi.Pt(9.5F), FontStyle.Bold);
            g.DefaultCellStyle.Font = new Font("Microsoft YaHei UI", Dpi.Pt(9.5F));
            g.DefaultCellStyle.SelectionBackColor = Color.FromArgb(226, 240, 231);
            g.DefaultCellStyle.SelectionForeColor = Color.Black;
            g.AlternatingRowsDefaultCellStyle.BackColor = AltRow;
            return g;
        }

        Panel NewBottomBar(out Button refresh, out Label count, EventHandler onRefresh)
        {
            var bar = new Panel();
            bar.Dock = DockStyle.Bottom;
            bar.Height = 48;
            bar.BackColor = Body;
            var rf = new Button();
            rf.Text = " 刷新";
            rf.Image = Program.MdlIcon(Glyph.Refresh, Accent, 15);
            rf.TextImageRelation = TextImageRelation.ImageBeforeText;
            rf.Size = new Size(96, 32);
            rf.Location = new Point(2, 8);
            rf.FlatStyle = FlatStyle.Flat;
            rf.FlatAppearance.BorderColor = Accent;
            rf.ForeColor = Accent;
            rf.BackColor = Body;
            rf.Cursor = Cursors.Hand;
            rf.Click += onRefresh;
            var cnt = new Label();
            cnt.AutoSize = true;
            cnt.ForeColor = Color.Gray;
            cnt.Font = new Font("Microsoft YaHei UI", Dpi.Pt(9.5F));
            cnt.Anchor = AnchorStyles.Right | AnchorStyles.Top;
            cnt.Text = "";
            bar.Controls.Add(rf);
            bar.Controls.Add(cnt);
            // Resize 在窗体缩放之后还会再跑，常数必须是缩放过的，否则把布局又拽回 96 DPI
            bar.Resize += (s, e) =>
            {
                cnt.Location = new Point(bar.Width - cnt.Width - Dpi.Px(6), Dpi.Px(14));
            };
            refresh = rf;
            count = cnt;
            return bar;
        }

        // ---------- 开机启动 页 ----------
        void BuildStartupPage()
        {
            pageStartup = new Panel();
            pageStartup.Dock = DockStyle.Fill;
            pageStartup.BackColor = PageBg;
            gridStartup = NewGrid();
            gridStartup.Columns.Add(TextCol("name", "名称", 24));
            gridStartup.Columns.Add(TextCol("source", "来源", 18));
            gridStartup.Columns.Add(TextCol("state", "状态", 13));
            gridStartup.Columns.Add(TextCol("advice", "建议（本地判断，不联网）", 29));
            var act = new DataGridViewButtonColumn();
            act.Name = "Open365.Gui.StartupToggle"; act.HeaderText = "操作"; act.Text = ""; act.UseColumnTextForButtonValue = false;
            act.FillWeight = 16; act.FlatStyle = FlatStyle.Standard;
            gridStartup.Columns.Add(act);
            gridStartup.Columns.Add(HiddenCol("id"));
            gridStartup.AccessibleName = "Open365.Gui.StartupList";
            gridStartup.CellContentClick += StartupAction;

            Button rf; Label cnt;
            var bar = NewBottomBar(out rf, out cnt, (s, e) => LoadStartup());
            lblStartupCount = cnt;
            pageStartup.Controls.Add(gridStartup);
            pageStartup.Controls.Add(bar);
        }

        void PopulateStartup(string json)
        {
            gridStartup.SuspendLayout();
            gridStartup.Rows.Clear();
            var d = Program.ParseJson(json);
            var items = (d == null) ? null : Program.Arr(d, "items");
            int total = 0, enabled = 0;
            if (items != null)
                foreach (var o in items)
                {
                    var it = o as Dictionary<string, object>;
                    if (it == null) continue;
                    string id = Program.Str(it, "id");
                    string name = Program.Str(it, "name");
                    string source = Program.Str(it, "source");
                    bool on = Program.Str(it, "state") == "enabled";
                    string advice = Program.Str(it, "advice");
                    string adviceReason = Program.Str(it, "advice_reason");
                    string adviceText = (advice == "keep") ? "建议保留" : adviceReason;
                    total++; if (on) enabled++;
                    int r = gridStartup.Rows.Add(name, source, on ? "✓ 启用中" : "✗ 已禁用", adviceText, on ? "禁用" : "启用", id);
                    var row = gridStartup.Rows[r];
                    row.Tag = on ? "enabled" : "disabled";
                    if (!on) row.DefaultCellStyle.ForeColor = Color.Gray;
                    // 「建议」列按等级上色：可关=橙、保留=绿、未知=灰；配上悬停全文
                    var advCell = row.Cells["advice"];
                    advCell.ToolTipText = adviceReason;
                    if (!on) advCell.Style.ForeColor = Color.Silver;
                    else if (advice == "optional") advCell.Style.ForeColor = WarnOrange;
                    else if (advice == "keep") advCell.Style.ForeColor = OkGreen;
                    else advCell.Style.ForeColor = Color.Gray;
                }
            lblStartupCount.Text = "共 " + total + " 项 / " + enabled + " 启用";
            gridStartup.ResumeLayout();
            if (total == 0 && json == null) lblStartupCount.Text = "读取失败，请点刷新重试";
        }

        void StartupAction(object sender, DataGridViewCellEventArgs e)
        {
            if (e.RowIndex < 0 || gridStartup.Columns[e.ColumnIndex].Name != "Open365.Gui.StartupToggle") return;
            var row = gridStartup.Rows[e.RowIndex];
            string id = (row.Cells["id"].Value ?? "").ToString();
            bool on = ((string)row.Tag) == "enabled";
            string action = on ? "disable" : "enable";
            Cursor = Cursors.WaitCursor;
            // 与 CLI/AI 同一个动作与同一道闸门；GUI 的点击就是这里的显式确认
            string res = Program.RunAction("startup." + action, Program.JsonInput("id", id), true);
            Cursor = Cursors.Default;
            var rd = Program.ParseJson(res);
            if (rd == null || !Program.Bool(rd, "ok"))
                MessageBox.Show("操作失败：该启动项可能正被占用，或需要更高权限。\n请确认用 Open365.exe（已自动提权）打开。",
                    "Open365", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            LoadStartup();
        }

        void LoadStartup()
        {
            lblStartupCount.Text = "正在加载…";
            var th = new Thread(() =>
            {
                string j = Program.RunAction("startup.list", null, false);
                try { BeginInvoke((Action)(() => PopulateStartup(j))); } catch { }
            });
            th.IsBackground = true;
            th.Start();
        }

        // ---------- 运行进程 页 ----------
        void BuildProcPage()
        {
            pageProc = new Panel();
            pageProc.Dock = DockStyle.Fill;
            pageProc.BackColor = PageBg;
            gridProc = NewGrid();
            gridProc.Columns.Add(TextCol("name", "名称", 26));
            gridProc.Columns.Add(TextCol("pid", "PID", 10));
            gridProc.Columns.Add(TextCol("mem", "内存", 12));
            gridProc.Columns.Add(TextCol("hint", "说明 / 窗口", 34));
            var act = new DataGridViewButtonColumn();
            act.Name = "act"; act.HeaderText = "操作"; act.UseColumnTextForButtonValue = false;
            act.FillWeight = 14; act.FlatStyle = FlatStyle.Standard;
            gridProc.Columns.Add(act);
            gridProc.Columns.Add(HiddenCol("pidv"));
            gridProc.AccessibleName = "Open365.Gui.ProcessList";
            gridProc.CellContentClick += ProcAction;

            Button rf; Label cnt;
            var bar = NewBottomBar(out rf, out cnt, (s, e) => LoadProc());
            lblProcCount = cnt;
            pageProc.Controls.Add(gridProc);
            pageProc.Controls.Add(bar);
        }

        void PopulateProc(string json)
        {
            gridProc.SuspendLayout();
            gridProc.Rows.Clear();
            var d = Program.ParseJson(json);
            var procs = (d == null) ? null : Program.Arr(d, "processes");
            int total = 0, killable = 0;
            if (procs != null)
                foreach (var o in procs)
                {
                    var it = o as Dictionary<string, object>;
                    if (it == null) continue;
                    int pid = Program.Int(it, "id");
                    string name = Program.Str(it, "name");
                    string mem = Program.Str(it, "mem_human");
                    string title = Program.Str(it, "title");
                    bool prot = Program.Bool(it, "protected");
                    total++;
                    string hint = (title.Length > 0) ? title : (prot ? "系统 / 受保护进程" : "");
                    int r = gridProc.Rows.Add(name, pid.ToString(), mem, hint, prot ? "受保护" : "结束", pid.ToString());
                    var row = gridProc.Rows[r];
                    row.Tag = prot ? "prot" : "ok";
                    if (prot) row.DefaultCellStyle.ForeColor = Color.Silver;
                    else killable++;
                }
            lblProcCount.Text = "共 " + total + " 个进程（可结束 " + killable + "）";
            gridProc.ResumeLayout();
            if (total == 0 && json == null) lblProcCount.Text = "读取失败，请点刷新重试";
        }

        void ProcAction(object sender, DataGridViewCellEventArgs e)
        {
            if (e.RowIndex < 0 || gridProc.Columns[e.ColumnIndex].Name != "act") return;
            var row = gridProc.Rows[e.RowIndex];
            if (((string)row.Tag) == "prot") return;   // 受保护：忽略点击
            string pid = (row.Cells["pidv"].Value ?? "").ToString();
            string name = (row.Cells["name"].Value ?? "").ToString();
            if (MessageBox.Show("确定结束 " + name + " (PID " + pid + ") 吗？\n该程序未保存的内容会丢失。",
                    "结束进程", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK) return;
            Cursor = Cursors.WaitCursor;
            string res = Program.RunJsonId("process.ps1", "kill", pid);
            Cursor = Cursors.Default;
            var rd = Program.ParseJson(res);
            if (rd == null || !Program.Bool(rd, "ok"))
                MessageBox.Show("结束失败：进程可能已退出，或它是受保护 / 更高权限的进程。",
                    "Open365", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            LoadProc();
        }

        void LoadProc()
        {
            lblProcCount.Text = "正在加载…";
            var th = new Thread(() =>
            {
                string j = Program.RunAction("process.list", null, false);
                try { BeginInvoke((Action)(() => PopulateProc(j))); } catch { }
            });
            th.IsBackground = true;
            th.Start();
        }

        // ---------- 列定义小工具 ----------
        static DataGridViewTextBoxColumn TextCol(string name, string header, int weight)
        {
            var c = new DataGridViewTextBoxColumn();
            c.Name = name; c.HeaderText = header; c.FillWeight = weight;
            c.DefaultCellStyle.Padding = new Padding(Dpi.Px(6), 0, 0, 0);   // 单元格样式 Scale() 也碰不到
            return c;
        }
        static DataGridViewTextBoxColumn HiddenCol(string name)
        {
            var c = new DataGridViewTextBoxColumn();
            c.Name = name; c.Visible = false;
            return c;
        }
    }
}
