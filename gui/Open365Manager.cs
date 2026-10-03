// Open365 管理中心窗口 (WinForms, 仿 WinUtil 左导航 + 右列表)
// 左侧竖排功能，右侧一张大列表 + 行内操作按钮：
//   开机启动 —— 读 startup.ps1 list -Json，每行 [启用]/[禁用] 一键切换（可还原）。
//   运行进程 —— 读 process.ps1 list -Json，每行 [结束]；关键系统进程置灰、禁止结束。
//   网络/清理/安全 —— 复用托盘里已有的体检/修复弹窗。
// 引擎调用、JSON 解析都复用 Program 里的 internal 方法，不重复造轮子（同一个程序集内）。
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
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

        // ---- 配色：全部转发到 Theme（唯一出处），这里只留个别名方便老代码引用 ----
        // Body 从「纯白」改成「浅灰画布」是这次视觉统一的关键一步：
        // 原先首页/清理/网络是灰底白卡，开机启动/运行进程却是白底大表格，切页像换了个软件。
        // 现在整窗统一灰画布，表格也装进白卡里（见 BuildStartupPage / BuildProcPage）。
        static readonly Color NavBg = Theme.NavBg;
        static readonly Color NavHover = Theme.NavHover;
        static readonly Color NavActive = Theme.NavPicked;
        static readonly Color Accent = Theme.Brand;
        static readonly Color Body = Theme.Canvas;

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
            Font = Theme.F(Theme.PtBody);
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
            brandIcon.Image = Program.MdlIcon(Glyph.ShieldSolid, Theme.BrandLite, 26);
            brandIcon.Size = new Size(30, 30);
            brandIcon.Location = new Point(Theme.S4, Theme.S4);
            var brandTitle = new Label();
            brandTitle.Text = "Open365";
            brandTitle.ForeColor = Color.White;
            brandTitle.Font = Theme.FB(Theme.PtTitle);
            brandTitle.AutoSize = true;
            brandTitle.Location = new Point(50, 15);
            var brandSub = new Label();
            brandSub.Text = "开源电脑助手";
            brandSub.ForeColor = Theme.NavIcon;
            brandSub.Font = Theme.F(Theme.PtCaption);
            brandSub.AutoSize = true;
            brandSub.Location = new Point(52, 45);
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
            AddNav("C 盘空间治理", "clean", Glyph.Broom);
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
            verLbl.Font = Theme.F(Theme.PtCaption);
            verLbl.ForeColor = Theme.NavIcon;
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
            header.Padding = new Padding(Theme.S6, 0, Theme.S6, 0);
            headTitle = new Label();
            headTitle.Font = Theme.FB(Theme.PtDisplay);
            headTitle.ForeColor = Theme.Text;
            headTitle.AutoSize = true;
            headTitle.Location = new Point(Theme.S6, Theme.S3);
            headSub = new Label();
            headSub.Font = Theme.F(Theme.PtCaption);
            headSub.ForeColor = Theme.TextSub;
            headSub.AutoSize = true;
            headSub.Location = new Point(Theme.S6 + 2, 44);
            header.Controls.Add(headSub);
            header.Controls.Add(headTitle);

            content = new Panel();
            content.Dock = DockStyle.Fill;
            content.BackColor = Body;
            // 左右内边距对齐标题（header 也是 S6），页面卡片与大标题左边缘就在一条线上
            content.Padding = new Padding(Theme.S6, Theme.S1, Theme.S6, Theme.S3);

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
        static readonly Color NavIconDim = Theme.NavIcon;

        void AddNav(string text, string key, string glyph)
        {
            var b = new NavItem();
            b.Text = text;
            b.Tag = key;
            b.Width = 172;
            b.Height = 48;
            b.Margin = new Padding(0);
            b.Padding = new Padding(Theme.S4, 0, 0, 0);
            b.Image = Program.MdlIcon(glyph, NavIconDim, 17);
            b.Font = Theme.F(Theme.PtStrong);
            b.ForeColor = Theme.NavText;
            b.BackColor = NavBg;
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
                var item = kv.Value as NavItem;
                if (item != null) item.Picked = on;
                kv.Value.ForeColor = on ? Color.White : Theme.NavText;
                kv.Value.Font = on ? Theme.FB(Theme.PtStrong) : Theme.F(Theme.PtStrong);
                // 选中项的图标点亮成品牌绿（深底上用亮一档的 BrandLite，纯 Brand 在 #171A1F 上偏闷）
                kv.Value.Image = Program.MdlIcon(navGlyphs[kv.Key], on ? Theme.BrandLite : NavIconDim, 17);
                kv.Value.Invalidate();
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
                    headSub.Text = "一键体检：安全防线 / 可治理空间 / 开机自启 / 网络连通，一屏看全";
                    Mount(pageHome);
                    if (!homeRan) RunCheckup();
                    LoadSysInfo();
                    break;
                case "startup":
                    headTitle.Text = "开机启动";
                    headSub.Text = "让开机更清爽。决定哪些程序在登录后自动运行。";
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
                    headTitle.Text = "C 盘空间治理";
                    headSub.Text = "按策略观察空间 · 先形成计划并确认，再执行并留下收据";
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
                    RefreshFocusUi(true);
                    break;
            }
        }

        // ---------- 通用：一张列表 + 底部条 ----------

        /// 把表格装进白色圆角卡片，让「表格页」和「卡片页」是同一套视觉。
        /// 卡片留内边距是必须的：DataGridView 会把自己那块矩形画满，
        /// 顶到卡片边上就会把圆角盖掉，看起来又变回直角方块。
        static Card WrapInCard(Control inner)
        {
            var card = new Card();
            card.Dock = DockStyle.Fill;
            card.Padding = new Padding(Theme.S3, Theme.S2, Theme.S3, Theme.S3);
            card.Controls.Add(inner);
            return card;
        }

        DataGridView NewGrid()
        {
            var g = new DataGridView();
            g.Dock = DockStyle.Fill;
            g.BackgroundColor = Theme.Surface;   // 卡片内部是白的（Body 现在是灰画布）
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
            g.ColumnHeadersHeight = Dpi.Px(40);
            g.RowTemplate.Height = Dpi.Px(40);   // 34 太挤，行距撑开一档更好扫读
            g.GridColor = Theme.Divider;
            g.CellBorderStyle = DataGridViewCellBorderStyle.SingleHorizontal;
            g.EnableHeadersVisualStyles = false;
            // 表头不再是一条灰色色块 —— 白底 + 下方一条分隔线，跟卡片融为一体
            g.ColumnHeadersDefaultCellStyle.BackColor = Theme.Surface;
            g.ColumnHeadersDefaultCellStyle.ForeColor = Theme.TextSub;
            g.ColumnHeadersDefaultCellStyle.SelectionBackColor = Theme.Surface;
            g.ColumnHeadersDefaultCellStyle.SelectionForeColor = Theme.TextSub;
            g.ColumnHeadersDefaultCellStyle.Font = Theme.FB(Theme.PtCaption);
            g.ColumnHeadersBorderStyle = DataGridViewHeaderBorderStyle.Single;
            g.DefaultCellStyle.BackColor = Theme.Surface;
            g.DefaultCellStyle.ForeColor = Theme.Text;
            g.DefaultCellStyle.Font = Theme.F(Theme.PtBody);
            g.DefaultCellStyle.SelectionBackColor = Theme.BrandSoft;
            g.DefaultCellStyle.SelectionForeColor = Theme.Text;
            // 去掉斑马纹：行分隔线已经够定位了，纯白列表更干净（Win11 设置/资源管理器同款）
            g.AlternatingRowsDefaultCellStyle.BackColor = Theme.Surface;
            g.CellPainting += PaintPillButton;
            g.CellMouseMove += (s, e) =>
            {
                // 行内操作列给个手型，让「这里能点」变得明显
                g.Cursor = (e.RowIndex >= 0 && e.ColumnIndex >= 0 &&
                            g.Columns[e.ColumnIndex] is DataGridViewButtonColumn)
                           ? Cursors.Hand : Cursors.Default;
            };
            return g;
        }

        /// 行内操作按钮自绘成圆角小药丸。
        /// DataGridViewButtonColumn 默认画的是 Win95 味的立体灰按钮，
        /// 跟外面新的圆角按钮完全两个年代 —— 这里统一。
        /// 空文本（受保护进程之类）不画按钮，只留一行灰字，避免「看着能点其实点不了」。
        static void PaintPillButton(object sender, DataGridViewCellPaintingEventArgs e)
        {
            var grid = sender as DataGridView;
            if (grid == null || e.RowIndex < 0 || e.ColumnIndex < 0) return;
            if (!(grid.Columns[e.ColumnIndex] is DataGridViewButtonColumn)) return;

            string txt = (e.FormattedValue == null) ? "" : e.FormattedValue.ToString();
            e.PaintBackground(e.CellBounds, false);

            if (txt.Length == 0) { e.Handled = true; return; }

            // 「受保护」不是动作，是状态 —— 画成灰字而不是按钮
            bool actionable = txt != "受保护";
            var g = e.Graphics;
            Size ts = TextRenderer.MeasureText(g, txt, grid.DefaultCellStyle.Font,
                                               new Size(int.MaxValue, int.MaxValue), TextFormatFlags.NoPadding);

            if (!actionable)
            {
                TextRenderer.DrawText(g, txt, grid.DefaultCellStyle.Font,
                    new Point(e.CellBounds.X + (e.CellBounds.Width - ts.Width) / 2,
                              e.CellBounds.Y + (e.CellBounds.Height - ts.Height) / 2),
                    Theme.TextDim, TextFormatFlags.NoPadding);
                e.Handled = true;
                return;
            }

            int padX = Dpi.Px(14), h = Dpi.Px(26);
            int w = Math.Min(ts.Width + padX * 2, e.CellBounds.Width - Dpi.Px(8));
            var r = new Rectangle(e.CellBounds.X + (e.CellBounds.Width - w) / 2,
                                  e.CellBounds.Y + (e.CellBounds.Height - h) / 2, w - 1, h - 1);

            var old = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (var path = Theme.RoundRect(r, Dpi.Px(6)))
            {
                using (var b = new SolidBrush(Theme.Surface)) g.FillPath(b, path);
                using (var p = new Pen(Theme.Brand)) g.DrawPath(p, path);
            }
            g.SmoothingMode = old;

            TextRenderer.DrawText(g, txt, grid.DefaultCellStyle.Font,
                new Point(r.X + (r.Width - ts.Width) / 2, r.Y + (r.Height - ts.Height) / 2),
                Theme.Brand, TextFormatFlags.NoPadding);
            e.Handled = true;
        }

        Panel NewBottomBar(out Button refresh, out Label count, EventHandler onRefresh)
        {
            var bar = new Panel();
            bar.Dock = DockStyle.Bottom;
            bar.Height = 52;
            bar.BackColor = Body;
            var rf = new RoundBtn();
            rf.Text = "刷新";
            rf.Image = Program.MdlIcon(Glyph.Refresh, Accent, 15);
            rf.Size = new Size(96, 34);
            rf.Location = new Point(0, Theme.S3);
            rf.Click += onRefresh;
            var cnt = new Label();
            cnt.AutoSize = true;
            cnt.ForeColor = Theme.TextSub;
            cnt.Font = Theme.F(Theme.PtBody);
            cnt.Anchor = AnchorStyles.Right | AnchorStyles.Top;
            cnt.Text = "";
            bar.Controls.Add(rf);
            bar.Controls.Add(cnt);
            // Resize 在窗体缩放之后还会再跑，常数必须是缩放过的，否则把布局又拽回 96 DPI
            bar.Resize += (s, e) =>
            {
                cnt.Location = new Point(bar.Width - cnt.Width - Dpi.Px(2), Dpi.Px(20));
            };
            refresh = rf;
            count = cnt;
            return bar;
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
            pageProc.Controls.Add(WrapInCard(gridProc));
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
                    if (prot) row.DefaultCellStyle.ForeColor = Theme.TextDim;
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
            c.DefaultCellStyle.Padding = new Padding(Dpi.Px(10), 0, 0, 0);   // 单元格样式 Scale() 也碰不到
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
