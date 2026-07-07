// Open365 管理中心 —— 新增图形页（ManagerForm 的另一半，partial class）
//   电脑体检 —— 并行跑 安全/垃圾/启动项/网络 四项检查，算综合分 + 防护数值仪表，逐项给修复按钮。
//   垃圾清理 —— 扫描结果列表 + 勾选清理（cleaner.ps1 -Only 精确到类别）。
//   网络修复 —— 五项连通性亮灯 + 按病因给修复按钮。
//   安全护盾 —— 三道防线逐行状态 + 单项开启 / 一键复位 / 快速查杀。
//   软件卸载 —— 搜索 + 列表 + 行内 [卸载][查残留]。
//   守夜模式 —— 图形开关（NightWatch 在本进程实现，见 Open365Tray.cs）。
// 图标一律用 Segoe MDL2 Assets 渲染（Program.MdlIcon），不用 emoji（WinForms 会画成"口"）。
// 状态符号用 √ / × / ! / ?（GBK 基本区字符，任何中文字体都有，绝不豆腐块）。
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Threading;
using System.Windows.Forms;

namespace Open365
{
    public partial class ManagerForm
    {
        // ---------- 通用小工具 ----------

        // 后台跑引擎，回到 UI 线程交结果（窗体已关就丢弃）
        void Engine(string file, string args, Action<string> done)
        {
            var th = new Thread(delegate ()
            {
                string j = Program.RunJson(file, args);
                try { BeginInvoke((Action)(delegate { done(j); })); } catch { }
            });
            th.IsBackground = true;
            th.Start();
        }

        Button MakeBtn(string text, int w, int h, bool solid)
        {
            var b = new Button();
            b.Text = text; b.Size = new Size(w, h);
            b.FlatStyle = FlatStyle.Flat; b.Cursor = Cursors.Hand;
            b.Font = new Font("Microsoft YaHei UI", 9.5F);
            if (solid)
            {
                b.FlatAppearance.BorderSize = 0;
                b.BackColor = Accent; b.ForeColor = Color.White;
            }
            else
            {
                b.FlatAppearance.BorderColor = Accent;
                b.ForeColor = Accent; b.BackColor = Color.White;
            }
            return b;
        }

        Button MakeIconBtn(string glyph, string text, int w, int h, bool solid)
        {
            var b = MakeBtn(" " + text, w, h, solid);
            b.Image = Program.MdlIcon(glyph, solid ? Color.White : Accent, 15);
            b.TextImageRelation = TextImageRelation.ImageBeforeText;
            b.ImageAlign = ContentAlignment.MiddleLeft;
            b.TextAlign = ContentAlignment.MiddleLeft;
            b.Padding = new Padding(10, 0, 6, 0);
            return b;
        }

        static readonly Color OkGreen = Color.FromArgb(35, 134, 54);
        static readonly Color BadRed = Color.FromArgb(207, 34, 46);
        static readonly Color WarnOrange = Color.FromArgb(191, 111, 0);

        // 状态行：左名称 + 中状态 + 右修复按钮（网络/安全页共用）
        void AddStatusRow(Panel host, int y, string name, out Label val, out Button fix, EventHandler onFix)
        {
            var n = new Label();
            n.Text = name; n.AutoSize = true;
            n.Font = new Font("Microsoft YaHei UI", 10F, FontStyle.Bold);
            n.ForeColor = Color.FromArgb(60, 70, 80);
            n.Location = new Point(8, y);
            host.Controls.Add(n);

            val = new Label();
            val.Text = "…"; val.AutoSize = true;
            val.Font = new Font("Microsoft YaHei UI", 10F);
            val.ForeColor = Color.Gray;
            val.Location = new Point(190, y);
            host.Controls.Add(val);

            fix = MakeBtn("开启", 76, 27, false);
            fix.Location = new Point(470, y - 4);
            fix.Visible = false;
            if (onFix != null) fix.Click += onFix;
            host.Controls.Add(fix);
        }

        // =====================================================================
        //  电脑体检（首页）
        // =====================================================================
        Panel pageHome;
        ScoreDial dial;
        Label lblHomeVerdict, lblHomeSub;
        Button btnCheckup;
        FlowLayoutPanel homeIssues;
        Label valGuard, valLines, valCleaned, valSig;
        internal bool homeRan;
        bool checkingUp;

        void BuildHomePage()
        {
            pageHome = new Panel();
            pageHome.Dock = DockStyle.Fill;

            var top = new Panel();
            top.Dock = DockStyle.Top;
            top.Height = 172;

            dial = new ScoreDial();
            dial.Size = new Size(158, 158);
            dial.Location = new Point(10, 4);
            top.Controls.Add(dial);

            lblHomeVerdict = new Label();
            lblHomeVerdict.Text = "点击「一键体检」全面检查电脑";
            lblHomeVerdict.Font = new Font("Microsoft YaHei UI", 15F, FontStyle.Bold);
            lblHomeVerdict.ForeColor = Color.FromArgb(30, 36, 44);
            lblHomeVerdict.AutoSize = true;
            lblHomeVerdict.Location = new Point(196, 22);
            top.Controls.Add(lblHomeVerdict);

            lblHomeSub = new Label();
            lblHomeSub.Text = "安全防线 / 垃圾文件 / 开机自启 / 网络连通，一次看全";
            lblHomeSub.Font = new Font("Microsoft YaHei UI", 9.5F);
            lblHomeSub.ForeColor = Color.Gray;
            lblHomeSub.AutoSize = true;
            lblHomeSub.Location = new Point(198, 58);
            top.Controls.Add(lblHomeSub);

            btnCheckup = MakeIconBtn(Glyph.Health, "一键体检", 176, 44, true);
            btnCheckup.Font = new Font("Microsoft YaHei UI", 11F, FontStyle.Bold);
            btnCheckup.Location = new Point(198, 92);
            btnCheckup.Click += delegate { RunCheckup(); };
            top.Controls.Add(btnCheckup);

            // ---- 防护数值仪表（安全感来自真实数字：全部本机统计，不联网、不编造） ----
            var stats = new FlowLayoutPanel();
            stats.Dock = DockStyle.Top;
            stats.Height = 74;
            stats.Padding = new Padding(0, 6, 0, 0);
            stats.Controls.Add(MakeTile("已守护本机", out valGuard));
            stats.Controls.Add(MakeTile("安全防线开启", out valLines));
            stats.Controls.Add(MakeTile("累计清理垃圾", out valCleaned));
            stats.Controls.Add(MakeTile("病毒库更新", out valSig));

            homeIssues = new FlowLayoutPanel();
            homeIssues.Dock = DockStyle.Fill;
            homeIssues.FlowDirection = FlowDirection.TopDown;
            homeIssues.WrapContents = false;
            homeIssues.AutoScroll = true;
            homeIssues.Padding = new Padding(0, 6, 0, 0);
            homeIssues.Resize += delegate
            {
                foreach (Control c in homeIssues.Controls)
                    c.Width = Math.Max(320, homeIssues.ClientSize.Width - 25);
            };

            pageHome.Controls.Add(homeIssues);
            pageHome.Controls.Add(stats);
            pageHome.Controls.Add(top);
            UpdateStatTiles(-1, -1);
        }

        Panel MakeTile(string caption, out Label val)
        {
            var p = new Panel();
            p.Size = new Size(176, 60);
            p.BackColor = AltRow;
            p.Margin = new Padding(2, 0, 10, 0);
            val = new Label();
            val.Text = "—";
            val.Font = new Font("Microsoft YaHei UI", 13.5F, FontStyle.Bold);
            val.ForeColor = Accent;
            val.AutoSize = true;
            val.Location = new Point(12, 5);
            var cap = new Label();
            cap.Text = caption;
            cap.Font = new Font("Microsoft YaHei UI", 9F);
            cap.ForeColor = Color.Gray;
            cap.AutoSize = true;
            cap.Location = new Point(13, 36);
            p.Controls.Add(val);
            p.Controls.Add(cap);
            return p;
        }

        // lines / sigAge 传 -1 表示"还没体检，保持 —"
        void UpdateStatTiles(int lines, int sigAge)
        {
            valGuard.Text = LocalStats.GuardDays + " 天";
            long cb = LocalStats.CleanedBytes;
            valCleaned.Text = (cb > 0) ? HumanSize(cb) : "0 MB";
            if (lines >= 0)
            {
                valLines.Text = lines + " / 3";
                valLines.ForeColor = (lines == 3) ? OkGreen : WarnOrange;
            }
            if (sigAge >= 0)
            {
                valSig.Text = (sigAge == 0) ? "今天" : (sigAge + " 天前");
                valSig.ForeColor = (sigAge <= 7) ? OkGreen : WarnOrange;
            }
        }

        void RunCheckup()
        {
            if (checkingUp) return;
            checkingUp = true; homeRan = true;
            btnCheckup.Enabled = false; btnCheckup.Text = " 体检中…";
            dial.Score = -1; dial.Invalidate();
            lblHomeVerdict.Text = "正在全面体检…";
            lblHomeSub.Text = "并行检查：安全 / 垃圾 / 启动项 / 网络（约 10~20 秒）";
            homeIssues.Controls.Clear();

            var res = new string[4];
            var done = new int[1];
            string[][] jobs = new string[][]
            {
                new string[] { "security.ps1", "check" },
                new string[] { "cleaner.ps1", "scan" },
                new string[] { "startup.ps1", "list" },
                new string[] { "network.ps1", "diagnose" }
            };
            for (int i = 0; i < jobs.Length; i++)
            {
                int idx = i;
                var th = new Thread(delegate ()
                {
                    res[idx] = Program.RunJson(jobs[idx][0], jobs[idx][1]);
                    bool all;
                    lock (done) { done[0]++; all = (done[0] == 4); }
                    try
                    {
                        BeginInvoke((Action)(delegate
                        {
                            lblHomeSub.Text = "已完成 " + done[0] + " / 4 项检查…";
                            if (all) FinishCheckup(res);
                        }));
                    }
                    catch { }
                });
                th.IsBackground = true;
                th.Start();
            }
        }

        void FinishCheckup(string[] res)
        {
            checkingUp = false;
            btnCheckup.Enabled = true; btnCheckup.Text = " 重新体检";

            var sec = Program.ParseJson(res[0]);
            var cln = Program.ParseJson(res[1]);
            var stp = Program.ParseJson(res[2]);
            var netd = Program.ParseJson(res[3]);
            int score = 100, issueCount = 0;

            // 1) 安全防线
            var probs = Program.Arr(sec, "problems");
            int np = (probs == null) ? 0 : probs.Length;
            if (sec == null)
            {
                AddIssue(Glyph.Shield, WarnOrange, "安全状态读取失败（可点「安全护盾」页重试）", "去看看", delegate { ShowPage("security"); });
            }
            else if (np > 0)
            {
                score -= Math.Min(np, 4) * 12; issueCount++;
                AddIssue(Glyph.Shield, BadRed, "安全防线有 " + np + " 处隐患（实时杀毒 / 防火墙 / 系统更新）", "去修复",
                    delegate { ShowPage("security"); });
            }

            // 2) 垃圾文件
            long jb = Program.Long(cln, "total_bytes");
            string jh = Program.Str(cln, "total_human");
            int junkPenalty = 0;
            if (jb >= 2L * 1024 * 1024 * 1024) junkPenalty = 15;
            else if (jb >= 500L * 1024 * 1024) junkPenalty = 10;
            else if (jb >= 100L * 1024 * 1024) junkPenalty = 5;
            if (junkPenalty > 0)
            {
                score -= junkPenalty; issueCount++;
                AddIssue(Glyph.Broom, WarnOrange, "垃圾文件可清理 " + jh, "去清理", delegate { ShowPage("clean"); });
            }

            // 3) 开机自启数量
            var items = Program.Arr(stp, "items");
            int enabled = 0;
            if (items != null)
                foreach (var o in items)
                {
                    var it = o as Dictionary<string, object>;
                    if (it != null && Program.Str(it, "state") == "enabled") enabled++;
                }
            if (enabled > 12) { score -= 8; issueCount++; AddIssue(Glyph.Power, WarnOrange, "开机自启动多达 " + enabled + " 项，可能拖慢开机", "去管理", delegate { ShowPage("startup"); }); }
            else if (enabled > 8) { score -= 4; issueCount++; AddIssue(Glyph.Power, WarnOrange, "开机自启动有 " + enabled + " 项，可酌情精简", "去管理", delegate { ShowPage("startup"); }); }

            // 4) 网络
            string sug = Program.Str(netd, "suggestion");
            if (netd != null && sug != "none" && sug != "")
            {
                score -= 20; issueCount++;
                AddIssue(Glyph.Wifi, BadRed, Program.Str(netd, "verdict"), "去修复", delegate { ShowPage("net"); });
            }

            if (score < 20) score = 20;
            dial.Score = score;
            dial.Ring = (score >= 90) ? OkGreen : (score >= 60 ? WarnOrange : BadRed);
            dial.Invalidate();

            // ---- 防护数值仪表 ----
            int lines = 0;
            var def = Program.Obj(sec, "defender");
            var fw = Program.Obj(sec, "firewall");
            var up = Program.Obj(sec, "update");
            if (Program.Bool(def, "available") && Program.Bool(def, "realtime_enabled")) lines++;
            if (Program.Bool(fw, "all_on")) lines++;
            if (Program.Bool(up, "available") && Program.Str(up, "start_mode") != "Disabled") lines++;
            int sigAge = Program.Bool(def, "available") ? Program.Int(def, "signature_age_days") : -1;
            UpdateStatTiles(lines, sigAge);

            lblHomeVerdict.Text =
                (score >= 90) ? "电脑状态极佳" :
                (score >= 75) ? "状态良好，可再优化" :
                (score >= 60) ? "发现一些问题，建议处理" : "问题较多，建议立即处理";
            lblHomeSub.Text = "体检完成 " + DateTime.Now.ToString("HH:mm") +
                " · 已连续守护 " + LocalStats.GuardDays + " 天" +
                (issueCount > 0 ? " · 发现 " + issueCount + " 类问题，点右侧按钮逐项处理" : " · 一切正常");
            if (issueCount == 0)
                AddIssue(Glyph.Check, OkGreen, "太棒了！安全、垃圾、启动项、网络全部正常。", null, null);
        }

        void AddIssue(string glyph, Color glyphColor, string text, string btnText, Action act)
        {
            var row = new Panel();
            row.Height = 46;
            row.Width = Math.Max(320, homeIssues.ClientSize.Width - 25);
            row.BackColor = AltRow;
            row.Margin = new Padding(2, 0, 0, 8);

            var ic = new PictureBox();
            ic.Image = Program.MdlIcon(glyph, glyphColor, 18);
            ic.Size = new Size(22, 22);
            ic.Location = new Point(12, 12);
            row.Controls.Add(ic);

            var lbl = new Label();
            lbl.Text = text;
            lbl.Font = new Font("Microsoft YaHei UI", 9.75F);
            lbl.ForeColor = Color.FromArgb(50, 58, 66);
            lbl.AutoSize = false;
            lbl.AutoEllipsis = true;
            lbl.Location = new Point(46, 14);
            lbl.Size = new Size(row.Width - 175, 20);
            lbl.Anchor = AnchorStyles.Left | AnchorStyles.Top | AnchorStyles.Right;
            row.Controls.Add(lbl);

            if (btnText != null)
            {
                var b = MakeBtn(btnText, 100, 30, false);
                b.Location = new Point(row.Width - 114, 8);
                b.Anchor = AnchorStyles.Top | AnchorStyles.Right;
                b.Click += delegate { act(); };
                row.Controls.Add(b);
            }
            homeIssues.Controls.Add(row);
        }

        // =====================================================================
        //  垃圾清理
        // =====================================================================
        Panel pageClean;
        DataGridView gridClean;
        Label lblCleanInfo;
        Button btnCleanRescan, btnCleanRun;
        bool cleanBusy;

        void BuildCleanPage()
        {
            pageClean = new Panel();
            pageClean.Dock = DockStyle.Fill;

            gridClean = NewGrid();
            gridClean.ReadOnly = false;                     // 只让勾选列可编辑
            var chk = new DataGridViewCheckBoxColumn();
            chk.Name = "chk"; chk.HeaderText = "清理"; chk.FillWeight = 8;
            gridClean.Columns.Add(chk);
            var c1 = TextCol("name", "类别", 36); c1.ReadOnly = true; gridClean.Columns.Add(c1);
            var c2 = TextCol("files", "文件数", 12); c2.ReadOnly = true; gridClean.Columns.Add(c2);
            var c3 = TextCol("human", "可释放", 14); c3.ReadOnly = true; gridClean.Columns.Add(c3);
            gridClean.Columns.Add(HiddenCol("key"));
            gridClean.Columns.Add(HiddenCol("bytes"));
            gridClean.CurrentCellDirtyStateChanged += delegate
            {
                if (gridClean.IsCurrentCellDirty)
                    gridClean.CommitEdit(DataGridViewDataErrorContexts.Commit);
            };
            gridClean.CellValueChanged += delegate { UpdateCleanInfo(); };

            var bar = new Panel();
            bar.Dock = DockStyle.Bottom; bar.Height = 48;
            btnCleanRescan = MakeIconBtn(Glyph.Refresh, "重新扫描", 116, 32, false);
            btnCleanRescan.Location = new Point(2, 8);
            btnCleanRescan.Click += delegate { LoadClean(); };
            btnCleanRun = MakeIconBtn(Glyph.Broom, "清理选中项", 132, 32, true);
            btnCleanRun.Location = new Point(128, 8);
            btnCleanRun.Enabled = false;
            btnCleanRun.Click += delegate { RunCleanSelected(); };
            lblCleanInfo = new Label();
            lblCleanInfo.AutoSize = true;
            lblCleanInfo.ForeColor = Color.Gray;
            lblCleanInfo.Font = new Font("Microsoft YaHei UI", 9.5F);
            bar.Controls.Add(btnCleanRescan);
            bar.Controls.Add(btnCleanRun);
            bar.Controls.Add(lblCleanInfo);
            bar.Resize += delegate { lblCleanInfo.Location = new Point(bar.Width - lblCleanInfo.Width - 6, 15); };

            pageClean.Controls.Add(gridClean);
            pageClean.Controls.Add(bar);
        }

        void LoadClean()
        {
            if (cleanBusy) return;
            cleanBusy = true;
            lblCleanInfo.Text = "正在扫描…";
            btnCleanRun.Enabled = false; btnCleanRescan.Enabled = false;
            gridClean.Rows.Clear();
            Engine("cleaner.ps1", "scan", delegate (string j)
            {
                cleanBusy = false; btnCleanRescan.Enabled = true;
                var d = Program.ParseJson(j);
                var items = Program.Arr(d, "items");
                if (items == null) { lblCleanInfo.Text = "扫描失败，请点「重新扫描」"; return; }
                int rows = 0;
                foreach (var o in items)
                {
                    var it = o as Dictionary<string, object>;
                    if (it == null) continue;
                    long bytes = Program.Long(it, "bytes");
                    if (bytes <= 0) continue;
                    string key = Program.Str(it, "key");
                    // 回收站默认不勾：清空后文件找不回，让用户自己决定
                    bool def = (key != "recyclebin");
                    gridClean.Rows.Add(def, Program.Str(it, "name"),
                        Program.Str(it, "files"), Program.Str(it, "human"), key, bytes.ToString());
                    rows++;
                }
                if (rows == 0) { lblCleanInfo.Text = "已经很干净了，没有可清理的垃圾"; return; }
                btnCleanRun.Enabled = true;
                UpdateCleanInfo();
            });
        }

        void UpdateCleanInfo()
        {
            long sel = 0, total = 0; int nSel = 0;
            foreach (DataGridViewRow r in gridClean.Rows)
            {
                long b; long.TryParse((r.Cells["bytes"].Value ?? "0").ToString(), out b);
                total += b;
                if (r.Cells["chk"].Value is bool && (bool)r.Cells["chk"].Value) { sel += b; nSel++; }
            }
            lblCleanInfo.Text = "已选 " + nSel + " 类 · 约 " + HumanSize(sel) + " / 共可清理 " + HumanSize(total);
        }

        static string HumanSize(long b)
        {
            if (b >= 1024L * 1024 * 1024) return (b / 1024.0 / 1024 / 1024).ToString("0.00") + " GB";
            if (b >= 1024L * 1024) return (b / 1024.0 / 1024).ToString("0.0") + " MB";
            if (b >= 1024L) return (b / 1024.0).ToString("0.0") + " KB";
            return b + " B";
        }

        void RunCleanSelected()
        {
            var keys = new List<string>();
            bool hasBin = false; long sel = 0;
            foreach (DataGridViewRow r in gridClean.Rows)
            {
                if (!(r.Cells["chk"].Value is bool) || !(bool)r.Cells["chk"].Value) continue;
                string k = (r.Cells["key"].Value ?? "").ToString();
                keys.Add(k);
                if (k == "recyclebin") hasBin = true;
                long b; long.TryParse((r.Cells["bytes"].Value ?? "0").ToString(), out b);
                sel += b;
            }
            if (keys.Count == 0)
            {
                MessageBox.Show(this, "请先勾选要清理的类别。", "Open365", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            string warn = "将清理 " + keys.Count + " 类垃圾，约释放 " + HumanSize(sel) + "。";
            if (hasBin) warn += "\n\n注意：包含【回收站】—— 清空后里面的文件将无法找回！";
            if (MessageBox.Show(this, warn + "\n\n确定开始清理吗？", "垃圾清理",
                    MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;

            cleanBusy = true;
            lblCleanInfo.Text = "正在清理…";
            btnCleanRun.Enabled = false; btnCleanRescan.Enabled = false;
            Engine("cleaner.ps1", "clean -Force -Only " + string.Join(",", keys.ToArray()), delegate (string j)
            {
                cleanBusy = false;
                var d = Program.ParseJson(j);
                string freed = Program.Str(d, "total_freed_human");
                if (d != null)
                {
                    LocalStats.AddCleaned(Program.Long(d, "total_freed_bytes"));
                    UpdateStatTiles(-1, -1);
                }
                MessageBox.Show(this, (d == null) ? "清理未能完成，请重试。" : "清理完成，已释放 " + freed + "。",
                    "Open365", MessageBoxButtons.OK, (d == null) ? MessageBoxIcon.Warning : MessageBoxIcon.Information);
                btnCleanRescan.Enabled = true;
                LoadClean();
            });
        }

        // =====================================================================
        //  网络修复
        // =====================================================================
        Panel pageNet;
        Label netWeb, netDns, netInet, netGw, netProxy, lblNetVerdict;
        Button btnNetCheck, btnNetFix, btnNetProxy, btnNetSetDns, btnNetFlush;
        string netSuggestion = "";
        internal bool netRan;
        bool netBusy;

        void BuildNetPage()
        {
            pageNet = new Panel();
            pageNet.Dock = DockStyle.Fill;

            var info = new Panel();
            info.Dock = DockStyle.Top; info.Height = 196;
            Button dummy;
            AddStatusRow(info, 8, "网页能否打开", out netWeb, out dummy, null);
            AddStatusRow(info, 44, "DNS 域名解析", out netDns, out dummy, null);
            AddStatusRow(info, 80, "外网连通 (IP)", out netInet, out dummy, null);
            AddStatusRow(info, 116, "路由器连接", out netGw, out dummy, null);
            AddStatusRow(info, 152, "系统代理", out netProxy, out dummy, null);

            lblNetVerdict = new Label();
            lblNetVerdict.Dock = DockStyle.Top;
            lblNetVerdict.Height = 84;
            lblNetVerdict.Font = new Font("Microsoft YaHei UI", 10F);
            lblNetVerdict.ForeColor = Color.FromArgb(90, 70, 20);
            lblNetVerdict.BackColor = Color.FromArgb(255, 250, 235);
            lblNetVerdict.Padding = new Padding(12, 10, 12, 10);
            lblNetVerdict.Text = "";
            lblNetVerdict.Visible = false;

            var bar = new Panel();
            bar.Dock = DockStyle.Bottom; bar.Height = 50;
            btnNetCheck = MakeIconBtn(Glyph.Refresh, "重新体检", 112, 32, false);
            btnNetCheck.Location = new Point(2, 9);
            btnNetCheck.Click += delegate { LoadNet(); };
            btnNetFix = MakeIconBtn(Glyph.Repair, "一键修复", 148, 32, true);
            btnNetFix.Location = new Point(124, 9);
            btnNetFix.Visible = false;
            btnNetFix.Click += delegate { FixNet(netSuggestion); };
            btnNetProxy = MakeBtn("清除代理", 88, 32, false);
            btnNetProxy.Location = new Point(288, 9);
            btnNetProxy.Click += delegate { FixNet("clear-proxy"); };
            btnNetSetDns = MakeBtn("换公共DNS", 96, 32, false);
            btnNetSetDns.Location = new Point(384, 9);
            btnNetSetDns.Click += delegate { FixNet("set-dns"); };
            btnNetFlush = MakeBtn("清DNS缓存", 96, 32, false);
            btnNetFlush.Location = new Point(488, 9);
            btnNetFlush.Click += delegate { FixNet("flush-dns"); };
            bar.Controls.Add(btnNetCheck);
            bar.Controls.Add(btnNetFix);
            bar.Controls.Add(btnNetProxy);
            bar.Controls.Add(btnNetSetDns);
            bar.Controls.Add(btnNetFlush);

            pageNet.Controls.Add(lblNetVerdict);
            pageNet.Controls.Add(info);
            pageNet.Controls.Add(bar);
            lblNetVerdict.BringToFront();
        }

        void SetVal(Label l, bool ok, string okText, string badText)
        {
            l.Text = ok ? ("√ " + okText) : ("× " + badText);
            l.ForeColor = ok ? OkGreen : BadRed;
        }

        void LoadNet()
        {
            if (netBusy) return;
            netBusy = true; netRan = true;
            btnNetCheck.Enabled = false; btnNetFix.Visible = false;
            netWeb.Text = netDns.Text = netInet.Text = netGw.Text = netProxy.Text = "… 检测中";
            netWeb.ForeColor = netDns.ForeColor = netInet.ForeColor = netGw.ForeColor = netProxy.ForeColor = Color.Gray;
            lblNetVerdict.Visible = false;
            Engine("network.ps1", "diagnose", delegate (string j)
            {
                netBusy = false; btnNetCheck.Enabled = true;
                var d = Program.ParseJson(j);
                if (d == null)
                {
                    netWeb.Text = netDns.Text = netInet.Text = netGw.Text = netProxy.Text = "读取失败";
                    return;
                }
                var t = Program.Obj(d, "tests");
                var px = Program.Obj(d, "proxy");
                SetVal(netWeb, Program.Bool(t, "web_works"), "正常", "打不开");
                SetVal(netDns, Program.Bool(t, "dns_works"), "正常", "解析失败");
                SetVal(netInet, Program.Bool(t, "internet_reachable"), "正常", "不通");
                SetVal(netGw, Program.Bool(t, "gateway_reachable"), "正常", "不通");
                if (Program.Bool(px, "enabled"))
                {
                    netProxy.Text = "! 已开启 → " + Program.Str(px, "server");
                    netProxy.ForeColor = WarnOrange;
                }
                else { netProxy.Text = "√ 未开启"; netProxy.ForeColor = OkGreen; }

                lblNetVerdict.Text = Program.Str(d, "verdict");
                lblNetVerdict.Visible = true;
                netSuggestion = Program.Str(d, "suggestion");
                if (netSuggestion == "clear-proxy") { btnNetFix.Text = " 清除异常代理"; btnNetFix.Visible = true; }
                else if (netSuggestion == "set-dns") { btnNetFix.Text = " 切换公共 DNS"; btnNetFix.Visible = true; }
                else if (netSuggestion == "repair-all") { btnNetFix.Text = " 一键全修复"; btnNetFix.Visible = true; }
            });
        }

        void FixNet(string action)
        {
            if (netBusy || string.IsNullOrEmpty(action) || action == "none") return;
            if (action == "repair-all" &&
                MessageBox.Show(this, "一键全修复会重置 Winsock / TCP-IP、清 DNS、重取 IP、清代理。\n修复后需要【重启电脑】才完全生效。\n\n继续吗？",
                    "网络修复", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;

            netBusy = true;
            btnNetCheck.Enabled = false; btnNetFix.Enabled = false;
            lblNetVerdict.Text = "正在修复…";
            lblNetVerdict.Visible = true;
            Engine("network.ps1", action, delegate (string j)
            {
                netBusy = false;
                btnNetCheck.Enabled = true; btnNetFix.Enabled = true;
                var d = Program.ParseJson(j);
                if (d != null && Program.Bool(d, "ok")) LocalStats.IncFixes();
                if (d != null && Program.Bool(d, "reboot_required"))
                    MessageBox.Show(this, "已执行修复。\n\nWinsock / TCP-IP 重置需要【重启电脑】后才生效，\n请重启后再试浏览器。",
                        "Open365", MessageBoxButtons.OK, MessageBoxIcon.Information);
                LoadNet();
            });
        }

        // =====================================================================
        //  安全护盾
        // =====================================================================
        Panel pageSecurity;
        Label secRt, secAv, secSig, secFw, secWu, lblSecVerdict;
        Button fixRt, fixAv, fixSig, fixFw, fixWu;
        Button btnSecCheck, btnSecAll, btnSecScan, btnSecSig;
        bool secBusy;

        void BuildSecurityPage()
        {
            pageSecurity = new Panel();
            pageSecurity.Dock = DockStyle.Fill;

            var info = new Panel();
            info.Dock = DockStyle.Top; info.Height = 196;
            AddStatusRow(info, 8, "实时杀毒防护", out secRt, out fixRt, delegate { SecAction("enable-defender", "正在开启实时防护…"); });
            AddStatusRow(info, 44, "杀毒引擎", out secAv, out fixAv, delegate { SecAction("enable-defender", "正在启用杀毒引擎…"); });
            AddStatusRow(info, 80, "病毒库", out secSig, out fixSig, delegate { SecAction("update-sig", "正在更新病毒库（可能要几分钟）…"); });
            AddStatusRow(info, 116, "防火墙", out secFw, out fixFw, delegate { SecAction("enable-firewall", "正在开启防火墙…"); });
            AddStatusRow(info, 152, "系统更新服务", out secWu, out fixWu, delegate { SecAction("enable-update", "正在恢复系统更新服务…"); });
            fixSig.Text = "更新";

            lblSecVerdict = new Label();
            lblSecVerdict.Dock = DockStyle.Top;
            lblSecVerdict.Height = 66;
            lblSecVerdict.Font = new Font("Microsoft YaHei UI", 10F);
            lblSecVerdict.Padding = new Padding(12, 10, 12, 10);
            lblSecVerdict.Text = "";
            lblSecVerdict.Visible = false;

            var bar = new Panel();
            bar.Dock = DockStyle.Bottom; bar.Height = 50;
            btnSecCheck = MakeIconBtn(Glyph.Refresh, "重新检测", 112, 32, false);
            btnSecCheck.Location = new Point(2, 9);
            btnSecCheck.Click += delegate { LoadSecurity(); };
            btnSecAll = MakeIconBtn(Glyph.Shield, "一键复位三道防线", 172, 32, true);
            btnSecAll.Location = new Point(124, 9);
            btnSecAll.Click += delegate { SecAction("enable-all", "正在复位（Defender + 防火墙 + 更新）…"); };
            btnSecScan = MakeBtn("快速查杀", 92, 32, false);
            btnSecScan.Location = new Point(310, 9);
            btnSecScan.Click += delegate
            {
                if (MessageBox.Show(this, "用 Windows Defender 做一次快速查杀，通常需要 1~10 分钟，\n期间可正常使用电脑。开始吗？",
                        "快速查杀", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) == DialogResult.OK)
                    SecAction("scan", "正在快速查杀（1~10 分钟，可离开此页）…");
            };
            btnSecSig = MakeBtn("更新病毒库", 100, 32, false);
            btnSecSig.Location = new Point(410, 9);
            btnSecSig.Click += delegate { SecAction("update-sig", "正在更新病毒库…"); };
            bar.Controls.Add(btnSecCheck);
            bar.Controls.Add(btnSecAll);
            bar.Controls.Add(btnSecScan);
            bar.Controls.Add(btnSecSig);

            pageSecurity.Controls.Add(lblSecVerdict);
            pageSecurity.Controls.Add(info);
            pageSecurity.Controls.Add(bar);
            lblSecVerdict.BringToFront();
        }

        void LoadSecurity()
        {
            if (secBusy) return;
            secBusy = true;
            btnSecCheck.Enabled = false;
            secRt.Text = secAv.Text = secSig.Text = secFw.Text = secWu.Text = "… 检测中";
            secRt.ForeColor = secAv.ForeColor = secSig.ForeColor = secFw.ForeColor = secWu.ForeColor = Color.Gray;
            fixRt.Visible = fixAv.Visible = fixSig.Visible = fixFw.Visible = fixWu.Visible = false;
            lblSecVerdict.Visible = false;
            Engine("security.ps1", "check", delegate (string j)
            {
                secBusy = false; btnSecCheck.Enabled = true;
                var d = Program.ParseJson(j);
                if (d == null) { secRt.Text = "读取失败，请重试"; return; }
                var def = Program.Obj(d, "defender");
                var fw = Program.Obj(d, "firewall");
                var up = Program.Obj(d, "update");

                if (Program.Bool(def, "available"))
                {
                    bool rt = Program.Bool(def, "realtime_enabled");
                    SetVal(secRt, rt, "已开启", "已关闭（裸奔风险）");
                    fixRt.Visible = !rt;
                    bool av = Program.Bool(def, "antivirus_enabled");
                    SetVal(secAv, av, "已启用", "未启用");
                    fixAv.Visible = !av;
                    int age = Program.Int(def, "signature_age_days");
                    bool fresh = age <= 7;
                    secSig.Text = fresh ? ("√ " + (age == 0 ? "今天已更新" : age + " 天前更新")) : ("! 已 " + age + " 天未更新");
                    secSig.ForeColor = fresh ? OkGreen : WarnOrange;
                    fixSig.Visible = !fresh;
                }
                else
                {
                    secRt.Text = secAv.Text = "? 读不到（可能被第三方杀软接管）";
                    secRt.ForeColor = secAv.ForeColor = WarnOrange;
                    secSig.Text = "—"; secSig.ForeColor = Color.Gray;
                    fixRt.Visible = true;
                }

                if (Program.Bool(fw, "available"))
                {
                    bool all = Program.Bool(fw, "all_on");
                    if (all) { secFw.Text = "√ 全部开启（域 / 专用 / 公用）"; secFw.ForeColor = OkGreen; }
                    else
                    {
                        secFw.Text = "× 域" + (Program.Bool(fw, "domain") ? "√" : "×")
                                   + " 专用" + (Program.Bool(fw, "private") ? "√" : "×")
                                   + " 公用" + (Program.Bool(fw, "public") ? "√" : "×");
                        secFw.ForeColor = BadRed;
                    }
                    fixFw.Visible = !all;
                }
                else { secFw.Text = "? 读不到"; secFw.ForeColor = WarnOrange; }

                if (Program.Bool(up, "available"))
                {
                    string st = Program.Str(up, "status");
                    string mode = Program.Str(up, "start_mode");
                    if (mode == "Disabled") secWu.Text = "× 被禁用（拿不到系统补丁）";
                    else if (st == "Running") secWu.Text = "√ 运行中";
                    else secWu.Text = "! 未运行（需要时会自动启动）";
                    secWu.ForeColor = (mode == "Disabled") ? BadRed : (st == "Running" ? OkGreen : WarnOrange);
                    fixWu.Visible = (mode == "Disabled");
                }
                else { secWu.Text = "? 读不到"; secWu.ForeColor = WarnOrange; }

                var probs = Program.Arr(d, "problems");
                int np = (probs == null) ? 0 : probs.Length;
                lblSecVerdict.Text = (np == 0 ? "√ " : "! ") + Program.Str(d, "verdict");
                lblSecVerdict.ForeColor = (np == 0) ? OkGreen : Color.FromArgb(90, 70, 20);
                lblSecVerdict.BackColor = (np == 0) ? Color.FromArgb(240, 250, 242) : Color.FromArgb(255, 250, 235);
                lblSecVerdict.Visible = true;
            });
        }

        void SecAction(string action, string busyText)
        {
            if (secBusy) return;
            secBusy = true;
            btnSecCheck.Enabled = btnSecAll.Enabled = btnSecScan.Enabled = btnSecSig.Enabled = false;
            lblSecVerdict.Text = busyText;
            lblSecVerdict.ForeColor = Color.FromArgb(60, 70, 80);
            lblSecVerdict.BackColor = Color.FromArgb(240, 245, 250);
            lblSecVerdict.Visible = true;
            Engine("security.ps1", action, delegate (string j)
            {
                secBusy = false;
                btnSecCheck.Enabled = btnSecAll.Enabled = btnSecScan.Enabled = btnSecSig.Enabled = true;
                var d = Program.ParseJson(j);
                if (d != null && Program.Bool(d, "ok") && action != "scan") LocalStats.IncFixes();
                if (action == "scan")
                    MessageBox.Show(this, "快速查杀已完成。发现的威胁 Defender 会自动隔离，\n详情可在「Windows 安全中心 → 保护历史记录」查看。",
                        "Open365", MessageBoxButtons.OK, MessageBoxIcon.Information);
                LoadSecurity();
            });
        }

        // =====================================================================
        //  软件卸载
        // =====================================================================
        Panel pageUninstall;
        TextBox txtUn;
        Button btnUnSearch;
        DataGridView gridUn;
        Label lblUnCount;
        internal bool unLoaded;
        bool unBusy;
        string unKeyword = "";

        void BuildUninstallPage()
        {
            pageUninstall = new Panel();
            pageUninstall.Dock = DockStyle.Fill;

            var top = new Panel();
            top.Dock = DockStyle.Top; top.Height = 44;
            txtUn = new TextBox();
            txtUn.Font = new Font("Microsoft YaHei UI", 10F);
            txtUn.Size = new Size(240, 30);
            txtUn.Location = new Point(2, 7);
            txtUn.KeyDown += delegate (object s, KeyEventArgs e)
            {
                if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; LoadApps(txtUn.Text.Trim()); }
            };
            btnUnSearch = MakeIconBtn(Glyph.Search, "搜索", 84, 30, true);
            btnUnSearch.Location = new Point(250, 6);
            btnUnSearch.Click += delegate { LoadApps(txtUn.Text.Trim()); };
            var hint = new Label();
            hint.Text = "留空搜索 = 列出全部";
            hint.AutoSize = true;
            hint.ForeColor = Color.Gray;
            hint.Font = new Font("Microsoft YaHei UI", 9F);
            hint.Location = new Point(344, 13);
            top.Controls.Add(txtUn);
            top.Controls.Add(btnUnSearch);
            top.Controls.Add(hint);

            gridUn = NewGrid();
            gridUn.Columns.Add(TextCol("name", "名称", 32));
            gridUn.Columns.Add(TextCol("version", "版本", 12));
            gridUn.Columns.Add(TextCol("publisher", "发行商", 20));
            gridUn.Columns.Add(TextCol("size", "大小", 10));
            var act = new DataGridViewButtonColumn();
            act.Name = "act"; act.HeaderText = "卸载"; act.Text = "卸载";
            act.UseColumnTextForButtonValue = true; act.FillWeight = 10; act.FlatStyle = FlatStyle.Standard;
            gridUn.Columns.Add(act);
            var act2 = new DataGridViewButtonColumn();
            act2.Name = "act2"; act2.HeaderText = "残留"; act2.Text = "查残留";
            act2.UseColumnTextForButtonValue = true; act2.FillWeight = 10; act2.FlatStyle = FlatStyle.Standard;
            gridUn.Columns.Add(act2);
            gridUn.Columns.Add(HiddenCol("id"));
            gridUn.CellContentClick += UnAction;

            var bar = new Panel();
            bar.Dock = DockStyle.Bottom; bar.Height = 40;
            lblUnCount = new Label();
            lblUnCount.AutoSize = true;
            lblUnCount.ForeColor = Color.Gray;
            lblUnCount.Font = new Font("Microsoft YaHei UI", 9.5F);
            lblUnCount.Location = new Point(2, 12);
            bar.Controls.Add(lblUnCount);

            pageUninstall.Controls.Add(gridUn);
            pageUninstall.Controls.Add(bar);
            pageUninstall.Controls.Add(top);
        }

        void LoadApps(string keyword)
        {
            if (unBusy) return;
            unBusy = true; unLoaded = true; unKeyword = keyword;
            lblUnCount.Text = "正在读取已安装软件…";
            btnUnSearch.Enabled = false;
            gridUn.Rows.Clear();
            string args = string.IsNullOrEmpty(keyword) ? "list" : ("search " + Program.Quote(keyword));
            Engine("uninstall.ps1", args, delegate (string j)
            {
                unBusy = false; btnUnSearch.Enabled = true;
                var d = Program.ParseJson(j);
                var apps = Program.Arr(d, "apps");
                if (apps == null) { lblUnCount.Text = "读取失败，请重试"; return; }
                foreach (var o in apps)
                {
                    var a = o as Dictionary<string, object>;
                    if (a == null) continue;
                    long kb = Program.Long(a, "size_kb");
                    string size = (kb > 0) ? HumanSize(kb * 1024) : "";
                    gridUn.Rows.Add(Program.Str(a, "name"), Program.Str(a, "version"),
                        Program.Str(a, "publisher"), size, null, null, Program.Str(a, "id"));
                }
                lblUnCount.Text = "共 " + gridUn.Rows.Count + " 个软件" +
                    (string.IsNullOrEmpty(keyword) ? "" : "（关键词：" + keyword + "）");
            });
        }

        void UnAction(object sender, DataGridViewCellEventArgs e)
        {
            if (e.RowIndex < 0 || unBusy) return;
            string col = gridUn.Columns[e.ColumnIndex].Name;
            if (col != "act" && col != "act2") return;
            var row = gridUn.Rows[e.RowIndex];
            string id = (row.Cells["id"].Value ?? "").ToString();
            string name = (row.Cells["name"].Value ?? "").ToString();

            if (col == "act2") { ShowResidue(name); return; }

            if (MessageBox.Show(this, "即将调用《" + name + "》官方卸载程序。\n卸载不可逆，请在弹出的卸载窗口中完成操作。\n\n继续吗？",
                    "软件卸载", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK) return;

            unBusy = true;
            lblUnCount.Text = "正在调用《" + name + "》的卸载程序，请在弹出的窗口完成卸载…";
            Engine("uninstall.ps1", "uninstall " + Program.Quote(id) + " -Yes", delegate (string j)
            {
                unBusy = false;
                var d = Program.ParseJson(j);
                if (d == null || !Program.Bool(d, "ok"))
                    MessageBox.Show(this, "卸载程序未能启动或已被取消。", "Open365",
                        MessageBoxButtons.OK, MessageBoxIcon.Warning);
                else if (MessageBox.Show(this, "卸载程序已结束。\n要顺手扫一下《" + name + "》的残留（目录 + 注册表）吗？",
                        "Open365", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
                    ShowResidue(name);
                LoadApps(unKeyword);
            });
        }

        void ShowResidue(string name)
        {
            lblUnCount.Text = "正在扫描《" + name + "》的残留…";
            Engine("uninstall.ps1", "residue " + Program.Quote(name), delegate (string j)
            {
                lblUnCount.Text = "共 " + gridUn.Rows.Count + " 个软件";
                var d = Program.ParseJson(j);
                if (d == null)
                {
                    MessageBox.Show(this, "残留扫描失败。", "Open365", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }
                var dirs = Program.Arr(d, "dirs");
                var regs = Program.Arr(d, "reg");
                var sb = new System.Text.StringBuilder();
                sb.AppendLine("《" + name + "》残留扫描结果");
                sb.AppendLine();
                sb.AppendLine("── 残留目录 ──");
                if (dirs == null || dirs.Length == 0) sb.AppendLine("（无）");
                else foreach (var x in dirs) sb.AppendLine(Convert.ToString(x));
                sb.AppendLine();
                sb.AppendLine("── 残留注册表 ──");
                if (regs == null || regs.Length == 0) sb.AppendLine("（无）");
                else foreach (var x in regs) sb.AppendLine(Convert.ToString(x));
                sb.AppendLine();
                sb.AppendLine("安全起见，本版本只报告不自动删除；确认无误后可手动删除。");
                ShowTextDialog("残留扫描 — " + name, sb.ToString());
            });
        }

        void ShowTextDialog(string title, string text)
        {
            var f = new Form();
            f.Text = title;
            f.StartPosition = FormStartPosition.CenterParent;
            f.ClientSize = new Size(620, 420);
            f.MinimizeBox = false; f.ShowInTaskbar = false;
            var tb = new TextBox();
            tb.Multiline = true; tb.ReadOnly = true;
            tb.ScrollBars = ScrollBars.Both; tb.WordWrap = false;
            tb.Dock = DockStyle.Fill;
            tb.Font = new Font("Microsoft YaHei UI", 9.5F);
            tb.Text = text.Replace("\n", "\r\n").Replace("\r\r", "\r");
            f.Controls.Add(tb);
            f.Shown += delegate { tb.SelectionStart = 0; tb.SelectionLength = 0; };
            f.ShowDialog(this);
        }

        // =====================================================================
        //  守夜模式
        // =====================================================================
        Panel pageFocus;
        Label lblFocusState;
        PictureBox picFocusState;
        ComboBox cboFocusHours;
        CheckBox chkScreenOff, chkAllowReboot;
        Button btnFocusToggle;
        Action nightHandler;

        static readonly int[] FocusHourOptions = new int[] { 0, 1, 2, 4, 8, 12 };

        void BuildFocusPage()
        {
            pageFocus = new Panel();
            pageFocus.Dock = DockStyle.Fill;

            picFocusState = new PictureBox();
            picFocusState.Size = new Size(28, 28);
            picFocusState.Location = new Point(6, 12);
            pageFocus.Controls.Add(picFocusState);

            lblFocusState = new Label();
            lblFocusState.Font = new Font("Microsoft YaHei UI", 14F, FontStyle.Bold);
            lblFocusState.AutoSize = true;
            lblFocusState.Location = new Point(42, 12);
            pageFocus.Controls.Add(lblFocusState);

            var lblDur = new Label();
            lblDur.Text = "守夜时长：";
            lblDur.AutoSize = true;
            lblDur.Font = new Font("Microsoft YaHei UI", 10F);
            lblDur.Location = new Point(8, 66);
            pageFocus.Controls.Add(lblDur);

            cboFocusHours = new ComboBox();
            cboFocusHours.DropDownStyle = ComboBoxStyle.DropDownList;
            cboFocusHours.Font = new Font("Microsoft YaHei UI", 10F);
            cboFocusHours.Size = new Size(200, 30);
            cboFocusHours.Location = new Point(96, 62);
            cboFocusHours.Items.Add("一直守夜（手动退出）");
            cboFocusHours.Items.Add("1 小时后自动退出");
            cboFocusHours.Items.Add("2 小时后自动退出");
            cboFocusHours.Items.Add("4 小时后自动退出");
            cboFocusHours.Items.Add("8 小时后自动退出");
            cboFocusHours.Items.Add("12 小时后自动退出");
            cboFocusHours.SelectedIndex = 0;
            pageFocus.Controls.Add(cboFocusHours);

            chkScreenOff = new CheckBox();
            chkScreenOff.Text = "允许屏幕熄灭（只防睡眠，更省电，适合纯下载 / 编译）";
            chkScreenOff.AutoSize = true;
            chkScreenOff.Font = new Font("Microsoft YaHei UI", 10F);
            chkScreenOff.Location = new Point(10, 102);
            pageFocus.Controls.Add(chkScreenOff);

            chkAllowReboot = new CheckBox();
            chkAllowReboot.Text = "不阻止 Windows 更新自动重启（默认会临时挡掉，退出还原）";
            chkAllowReboot.AutoSize = true;
            chkAllowReboot.Font = new Font("Microsoft YaHei UI", 10F);
            chkAllowReboot.Location = new Point(10, 132);
            pageFocus.Controls.Add(chkAllowReboot);

            btnFocusToggle = MakeIconBtn(Glyph.Moon, "开启守夜模式", 196, 46, true);
            btnFocusToggle.Font = new Font("Microsoft YaHei UI", 11F, FontStyle.Bold);
            btnFocusToggle.Location = new Point(8, 176);
            btnFocusToggle.Click += delegate
            {
                if (NightWatch.Active) NightWatch.Off();
                else NightWatch.On(!chkScreenOff.Checked, !chkAllowReboot.Checked,
                        FocusHourOptions[Math.Max(0, cboFocusHours.SelectedIndex)]);
            };
            pageFocus.Controls.Add(btnFocusToggle);

            var hint = new Label();
            hint.Text = "守夜模式让 AI 通宵干活时电脑【不熄屏 / 不睡眠 / 不锁屏 / 不被更新重启】。\n" +
                        "原理：向系统声明「正在忙」，只在开启期间生效；\n" +
                        "退出守夜或退出 Open365 时自动还原所有设置，不会永久改动电源计划。";
            hint.AutoSize = true;
            hint.ForeColor = Color.Gray;
            hint.Font = new Font("Microsoft YaHei UI", 9.5F);
            hint.Location = new Point(8, 244);
            pageFocus.Controls.Add(hint);

            nightHandler = delegate
            {
                if (IsDisposed) return;
                RefreshFocusUi();
            };
            NightWatch.Changed += nightHandler;
            FormClosed += delegate { NightWatch.Changed -= nightHandler; };
            RefreshFocusUi();
        }

        void RefreshFocusUi()
        {
            bool on = NightWatch.Active;
            if (on)
            {
                string s = "守夜中 · 自 " + NightWatch.StartedAt.ToString("HH:mm") + " 起";
                if (NightWatch.Deadline != DateTime.MinValue)
                    s += " · " + NightWatch.Deadline.ToString("HH:mm") + " 自动退出";
                lblFocusState.Text = s;
                lblFocusState.ForeColor = Color.FromArgb(88, 86, 214);
                picFocusState.Image = Program.MdlIcon(Glyph.Moon, Color.FromArgb(88, 86, 214), 24);
                btnFocusToggle.Text = " 退出守夜模式";
                btnFocusToggle.Image = Program.MdlIcon(Glyph.Moon, Color.White, 15);
            }
            else
            {
                lblFocusState.Text = "守夜模式未开启";
                lblFocusState.ForeColor = Color.FromArgb(60, 70, 80);
                picFocusState.Image = Program.MdlIcon(Glyph.Sun, Color.FromArgb(150, 160, 170), 24);
                btnFocusToggle.Text = " 开启守夜模式";
                btnFocusToggle.Image = Program.MdlIcon(Glyph.Moon, Color.White, 15);
            }
            cboFocusHours.Enabled = chkScreenOff.Enabled = chkAllowReboot.Enabled = !on;
        }
    }

    // 体检评分表盘：圆环 + 大字分数
    class ScoreDial : Control
    {
        public int Score = -1;                                     // -1 = 未体检
        public Color Ring = Color.FromArgb(35, 134, 54);

        public ScoreDial()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Color.White;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            int pad = 12;
            var rect = new Rectangle(pad, pad, Width - 2 * pad, Height - 2 * pad);

            using (var bg = new Pen(Color.FromArgb(235, 239, 244), 12))
                g.DrawEllipse(bg, rect);
            if (Score >= 0)
                using (var fg = new Pen(Ring, 12))
                {
                    fg.StartCap = LineCap.Round; fg.EndCap = LineCap.Round;
                    g.DrawArc(fg, rect, -90, (int)Math.Round(360.0 * Score / 100));
                }

            string txt = (Score < 0) ? "—" : Score.ToString();
            using (var f = new Font("Microsoft YaHei UI", 32F, FontStyle.Bold))
            using (var br = new SolidBrush(Color.FromArgb(30, 36, 44)))
            {
                var sz = g.MeasureString(txt, f);
                g.DrawString(txt, f, br, (Width - sz.Width) / 2, (Height - sz.Height) / 2 - 8);
            }
            string sub = (Score < 0) ? "未体检" : "分";
            using (var f2 = new Font("Microsoft YaHei UI", 9F))
            using (var br2 = new SolidBrush(Color.Gray))
            {
                var sz2 = g.MeasureString(sub, f2);
                g.DrawString(sub, f2, br2, (Width - sz2.Width) / 2, Height / 2 + 24);
            }
        }
    }
}
