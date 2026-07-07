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
    public class ManagerForm : Form
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

        // ---- 配色 ----
        static readonly Color NavBg = Color.FromArgb(32, 38, 46);
        static readonly Color NavHover = Color.FromArgb(45, 53, 64);
        static readonly Color NavActive = Color.FromArgb(0, 120, 180);
        static readonly Color Accent = Color.FromArgb(0, 120, 180);
        static readonly Color Body = Color.White;
        static readonly Color AltRow = Color.FromArgb(247, 249, 252);

        // ---- 控件 ----
        readonly FlowLayoutPanel navFlow;
        readonly Dictionary<string, Button> navButtons = new Dictionary<string, Button>();
        readonly Label headTitle, headSub;
        readonly Panel content;

        Panel pageStartup, pageProc, pageNet, pageClean, pageSecurity;
        DataGridView gridStartup, gridProc;
        Label lblStartupCount, lblProcCount;
        string current = "";

        public ManagerForm()
        {
            Text = "Open365 管理中心";
            Font = new Font("Microsoft YaHei UI", 9.5F);
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(900, 580);
            MinimumSize = new Size(720, 460);
            BackColor = Body;
            try { Icon = SystemIcons.Shield; } catch { }

            // ===== 左侧导航 =====
            var nav = new Panel();
            nav.Dock = DockStyle.Left;
            nav.Width = 172;
            nav.BackColor = NavBg;

            var brand = new Panel();
            brand.Dock = DockStyle.Top;
            brand.Height = 72;
            brand.BackColor = NavBg;
            var brandTitle = new Label();
            brandTitle.Text = "Open365";
            brandTitle.ForeColor = Color.White;
            brandTitle.Font = new Font("Microsoft YaHei UI", 14F, FontStyle.Bold);
            brandTitle.AutoSize = true;
            brandTitle.Location = new Point(16, 14);
            var brandSub = new Label();
            brandSub.Text = "管理中心";
            brandSub.ForeColor = Color.FromArgb(140, 150, 160);
            brandSub.Font = new Font("Microsoft YaHei UI", 9F);
            brandSub.AutoSize = true;
            brandSub.Location = new Point(18, 44);
            brand.Controls.Add(brandSub);
            brand.Controls.Add(brandTitle);

            navFlow = new FlowLayoutPanel();
            navFlow.Dock = DockStyle.Fill;
            navFlow.FlowDirection = FlowDirection.TopDown;
            navFlow.WrapContents = false;
            navFlow.BackColor = NavBg;
            navFlow.Padding = new Padding(0, 8, 0, 0);

            AddNav("🚀  开机启动", "startup");
            AddNav("🧠  运行进程", "process");
            AddNav("🔧  网络修复", "net");
            AddNav("🧹  垃圾清理", "clean");
            AddNav("🛡️  安全护盾", "security");

            nav.Controls.Add(navFlow);
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
            headTitle.Font = new Font("Microsoft YaHei UI", 15F, FontStyle.Bold);
            headTitle.ForeColor = Color.FromArgb(30, 36, 44);
            headTitle.AutoSize = true;
            headTitle.Location = new Point(22, 14);
            headSub = new Label();
            headSub.Font = new Font("Microsoft YaHei UI", 9F);
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

            BuildStartupPage();
            BuildProcPage();
            pageNet = BuildActionPage("点击下方按钮开始网络体检，发现问题会给出一键修复。", "🔧  开始网络体检", () => Program.DoNetwork());
            pageClean = BuildActionPage("点击下方按钮扫描垃圾文件，扫描完可一键清理。", "🧹  开始扫描垃圾", () => Program.DoClean());
            pageSecurity = BuildActionPage("点击下方按钮做安全体检（Defender / 防火墙 / 更新）。", "🛡️  开始安全体检", () => Program.DoSecurity());

            FormClosed += (s, e) => { Instance = null; };
        }

        // ---------- 导航 ----------
        void AddNav(string text, string key)
        {
            var b = new Button();
            b.Text = "  " + text;
            b.Tag = key;
            b.Width = navFlow.Width > 0 ? navFlow.Width - 0 : 172;
            b.Width = 172;
            b.Height = 48;
            b.Margin = new Padding(0);
            b.FlatStyle = FlatStyle.Flat;
            b.FlatAppearance.BorderSize = 0;
            b.FlatAppearance.MouseOverBackColor = NavHover;
            b.TextAlign = ContentAlignment.MiddleLeft;
            b.Font = new Font("Microsoft YaHei UI", 10.5F);
            b.ForeColor = Color.Gainsboro;
            b.BackColor = NavBg;
            b.Cursor = Cursors.Hand;
            b.Click += (s, e) => ShowPage(key);
            navButtons[key] = b;
            navFlow.Controls.Add(b);
        }

        void SetNavActive(string key)
        {
            foreach (var kv in navButtons)
            {
                bool on = kv.Key == key;
                kv.Value.BackColor = on ? NavActive : NavBg;
                kv.Value.ForeColor = on ? Color.White : Color.Gainsboro;
                kv.Value.Font = new Font("Microsoft YaHei UI", 10.5F, on ? FontStyle.Bold : FontStyle.Regular);
            }
        }

        // ---------- 页面切换 ----------
        internal void ShowPage(string key)
        {
            if (string.IsNullOrEmpty(key)) key = "startup";
            current = key;
            SetNavActive(key);
            content.Controls.Clear();
            switch (key)
            {
                case "startup":
                    headTitle.Text = "开机启动项";
                    headSub.Text = "管理开机自动启动的程序 · 禁用可一键还原（移到备份处，不删除）";
                    content.Controls.Add(pageStartup);
                    LoadStartup();
                    break;
                case "process":
                    headTitle.Text = "运行进程";
                    headSub.Text = "结束占用资源的进程 · 关键系统进程已保护、禁止结束";
                    content.Controls.Add(pageProc);
                    LoadProc();
                    break;
                case "net":
                    headTitle.Text = "网络修复";
                    headSub.Text = "专治“微信能上、网页打不开” · 体检后一键修复";
                    content.Controls.Add(pageNet);
                    break;
                case "clean":
                    headTitle.Text = "垃圾清理";
                    headSub.Text = "扫描并清理临时文件 / 缓存 / 回收站";
                    content.Controls.Add(pageClean);
                    break;
                case "security":
                    headTitle.Text = "安全护盾";
                    headSub.Text = "Defender / 防火墙 / 系统更新 体检与一键复位";
                    content.Controls.Add(pageSecurity);
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
            g.ColumnHeadersHeight = 36;
            g.RowTemplate.Height = 34;
            g.GridColor = Color.FromArgb(232, 236, 240);
            g.CellBorderStyle = DataGridViewCellBorderStyle.SingleHorizontal;
            g.EnableHeadersVisualStyles = false;
            g.ColumnHeadersDefaultCellStyle.BackColor = Color.FromArgb(240, 243, 247);
            g.ColumnHeadersDefaultCellStyle.ForeColor = Color.FromArgb(60, 70, 80);
            g.ColumnHeadersDefaultCellStyle.Font = new Font("Microsoft YaHei UI", 9.5F, FontStyle.Bold);
            g.DefaultCellStyle.Font = new Font("Microsoft YaHei UI", 9.5F);
            g.DefaultCellStyle.SelectionBackColor = Color.FromArgb(225, 240, 250);
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
            rf.Text = "🔄  刷新";
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
            cnt.Font = new Font("Microsoft YaHei UI", 9.5F);
            cnt.Anchor = AnchorStyles.Right | AnchorStyles.Top;
            cnt.Text = "";
            bar.Controls.Add(rf);
            bar.Controls.Add(cnt);
            bar.Resize += (s, e) =>
            {
                cnt.Location = new Point(bar.Width - cnt.Width - 6, 14);
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
            gridStartup = NewGrid();
            gridStartup.Columns.Add(TextCol("name", "名称", 30));
            gridStartup.Columns.Add(TextCol("source", "来源", 26));
            gridStartup.Columns.Add(TextCol("state", "状态", 18));
            var act = new DataGridViewButtonColumn();
            act.Name = "act"; act.HeaderText = "操作"; act.Text = ""; act.UseColumnTextForButtonValue = false;
            act.FillWeight = 18; act.FlatStyle = FlatStyle.Standard;
            gridStartup.Columns.Add(act);
            gridStartup.Columns.Add(HiddenCol("id"));
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
                    total++; if (on) enabled++;
                    int r = gridStartup.Rows.Add(name, source, on ? "✅ 启用中" : "⛔ 已禁用", on ? "禁用" : "启用", id);
                    gridStartup.Rows[r].Tag = on ? "enabled" : "disabled";
                    if (!on) gridStartup.Rows[r].DefaultCellStyle.ForeColor = Color.Gray;
                }
            lblStartupCount.Text = "共 " + total + " 项 / " + enabled + " 启用";
            gridStartup.ResumeLayout();
            if (total == 0 && json == null) lblStartupCount.Text = "读取失败，请点刷新重试";
        }

        void StartupAction(object sender, DataGridViewCellEventArgs e)
        {
            if (e.RowIndex < 0 || gridStartup.Columns[e.ColumnIndex].Name != "act") return;
            var row = gridStartup.Rows[e.RowIndex];
            string id = (row.Cells["id"].Value ?? "").ToString();
            bool on = ((string)row.Tag) == "enabled";
            string action = on ? "disable" : "enable";
            Cursor = Cursors.WaitCursor;
            string res = Program.RunJsonId("startup.ps1", action, id);
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
                string j = Program.RunJson("startup.ps1", "list");
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
                string j = Program.RunJson("process.ps1", "list");
                try { BeginInvoke((Action)(() => PopulateProc(j))); } catch { }
            });
            th.IsBackground = true;
            th.Start();
        }

        // ---------- 网络/清理/安全：复用托盘弹窗 ----------
        Panel BuildActionPage(string desc, string btnText, Action onClick)
        {
            var p = new Panel();
            p.Dock = DockStyle.Fill;
            var card = new Panel();
            card.Size = new Size(560, 180);
            card.BackColor = Color.FromArgb(248, 250, 252);
            card.BorderStyle = BorderStyle.FixedSingle;
            var lbl = new Label();
            lbl.Text = desc;
            lbl.Font = new Font("Microsoft YaHei UI", 11F);
            lbl.ForeColor = Color.FromArgb(60, 70, 80);
            lbl.AutoSize = false;
            lbl.TextAlign = ContentAlignment.MiddleCenter;
            lbl.Dock = DockStyle.Top;
            lbl.Height = 90;
            var btn = new Button();
            btn.Text = btnText;
            btn.Size = new Size(220, 44);
            btn.FlatStyle = FlatStyle.Flat;
            btn.FlatAppearance.BorderSize = 0;
            btn.BackColor = Accent;
            btn.ForeColor = Color.White;
            btn.Font = new Font("Microsoft YaHei UI", 11F, FontStyle.Bold);
            btn.Cursor = Cursors.Hand;
            btn.Location = new Point((card.Width - btn.Width) / 2, 110);
            btn.Click += (s, e) => { try { onClick(); } catch { } };
            card.Controls.Add(btn);
            card.Controls.Add(lbl);
            p.Controls.Add(card);
            p.Resize += (s, e) => { card.Location = new Point((p.Width - card.Width) / 2, Math.Max(20, (p.Height - card.Height) / 2 - 20)); };
            return p;
        }

        // ---------- 列定义小工具 ----------
        static DataGridViewTextBoxColumn TextCol(string name, string header, int weight)
        {
            var c = new DataGridViewTextBoxColumn();
            c.Name = name; c.HeaderText = header; c.FillWeight = weight;
            c.DefaultCellStyle.Padding = new Padding(6, 0, 0, 0);
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
