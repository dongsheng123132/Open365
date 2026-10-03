// 启动项工作区。业务写入只调用 Action Core，页面只负责筛选、呈现和确认。
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Windows.Forms;
using System.Web.Script.Serialization;

namespace Open365
{
    public partial class ManagerForm
    {
        readonly List<Dictionary<string, object>> startupItems = new List<Dictionary<string, object>>();
        readonly Dictionary<string, Button> startupFilters = new Dictionary<string, Button>();
        TextBox startupSearch, startupCommand;
        Label startupEnabled, startupDisabled, startupOptional, startupEmpty, startupDetail, startupReason;
        Button startupRefresh, startupAdd, startupToggle;
        string startupFilter = "all", startupSelectedId = "";
        string startupLoadError = "", startupNotice = "";
        bool startupBusy, startupRendering, startupLoaded;

        Label StartupLabel(string text, float size, Color color)
        {
            return new Label { Text = text, Font = Theme.F(size), ForeColor = color,
                BackColor = Theme.Surface, AutoEllipsis = true, TextAlign = ContentAlignment.MiddleLeft };
        }

        Card StartupStat(string title, string subtitle, out Label value)
        {
            var card = new Card { Dock = DockStyle.Fill, Margin = new Padding(0, 0, 8, 0), Padding = new Padding(16, 8, 12, 8) };
            value = StartupLabel("—", Theme.PtDisplay, Theme.Text);
            value.Font = Theme.FB(Theme.PtDisplay);
            value.Dock = DockStyle.Top; value.Height = 28;
            var caption = StartupLabel(title + " · " + subtitle, Theme.PtCaption, Theme.TextSub);
            caption.Dock = DockStyle.Fill;
            card.Controls.Add(caption); card.Controls.Add(value);
            return card;
        }

        void BuildStartupPage()
        {
            pageStartup = new Panel { Dock = DockStyle.Fill, BackColor = PageBg };
            var stats = new TableLayoutPanel { Dock = DockStyle.Top, Height = 74, ColumnCount = 3, RowCount = 1, Padding = new Padding(0, 0, 0, 10) };
            stats.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            for (int i = 0; i < 3; i++) stats.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 33.333F));
            stats.Controls.Add(StartupStat("已启用", "登录后自动运行", out startupEnabled), 0, 0);
            stats.Controls.Add(StartupStat("已禁用", "随时可以恢复", out startupDisabled), 1, 0);
            var last = StartupStat("可按需关闭", "依据本地名称匹配", out startupOptional);
            last.Margin = Padding.Empty; stats.Controls.Add(last, 2, 0);

            var tools = new Panel { Dock = DockStyle.Top, Height = 90 };
            var searchRow = new TableLayoutPanel { Dock = DockStyle.Top, Height = 40, ColumnCount = 3, RowCount = 1 };
            searchRow.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            searchRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            searchRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 86));
            searchRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 126));
            var searchBox = new Panel { Dock = DockStyle.Fill, BackColor = Theme.Surface, Padding = new Padding(12, 9, 10, 5), Margin = new Padding(0, 0, 8, 0) };
            var searchTitle = StartupLabel("搜索", Theme.PtBody, Theme.TextSub);
            searchTitle.Dock = DockStyle.Left; searchTitle.Width = 44;
            startupSearch = new TextBox { Dock = DockStyle.Fill, BorderStyle = BorderStyle.None,
                Font = Theme.F(Theme.PtBody), AccessibleName = "Open365.Gui.StartupSearch" };
            startupSearch.TextChanged += delegate { RenderStartup(); };
            searchBox.Controls.Add(startupSearch); searchBox.Controls.Add(searchTitle);
            startupRefresh = MakeBtn("刷新", 78, 38, false);
            startupRefresh.Dock = DockStyle.Fill; startupRefresh.Margin = new Padding(0, 0, 8, 0);
            startupRefresh.AccessibleName = "Open365.Gui.StartupRefresh";
            startupRefresh.Click += delegate { LoadStartup(); };
            startupAdd = MakeBtn("＋ 新增自启", 126, 38, true);
            startupAdd.Dock = DockStyle.Fill; startupAdd.Margin = Padding.Empty;
            startupAdd.AccessibleName = "Open365.Gui.StartupAdd";
            startupAdd.Click += delegate { AddStartup(); };
            searchRow.Controls.Add(searchBox, 0, 0); searchRow.Controls.Add(startupRefresh, 1, 0); searchRow.Controls.Add(startupAdd, 2, 0);
            var filters = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 48, WrapContents = false, Padding = new Padding(0, 3, 0, 9) };
            string[] keys = { "all", "enabled", "disabled", "optional" };
            string[] labels = { "全部", "已启用", "已禁用", "可按需关闭" };
            for (int i = 0; i < keys.Length; i++)
            {
                string key = keys[i];
                var b = MakeBtn(labels[i], i == 3 ? 126 : 100, 34, key == "all");
                b.Margin = new Padding(0, 0, 8, 0); b.AccessibleName = "Open365.Gui.StartupFilter." + key;
                b.Click += delegate { startupFilter = key; RenderStartup(); };
                startupFilters.Add(key, b); filters.Controls.Add(b);
            }
            tools.Controls.Add(filters); tools.Controls.Add(searchRow);

            gridStartup = NewGrid();
            gridStartup.AccessibleName = "Open365.Gui.StartupList";
            gridStartup.RowTemplate.Height = Dpi.Px(46);
            gridStartup.DefaultCellStyle.Padding = new Padding(Dpi.Px(8), 0, Dpi.Px(4), 0);
            gridStartup.Columns.Add(TextCol("name", "程序名称", 32));
            gridStartup.Columns.Add(TextCol("state", "启动状态", 17));
            gridStartup.Columns.Add(TextCol("advice", "使用建议", 20));
            gridStartup.Columns.Add(TextCol("source", "来源", 31));
            gridStartup.Columns.Add(HiddenCol("id"));
            gridStartup.SelectionChanged += delegate { if (!startupRendering) UpdateStartupDetail(); };
            gridStartup.CurrentCellChanged += delegate { if (!startupRendering) UpdateStartupDetail(); };
            gridStartup.Sorted += delegate { if (!startupRendering) UpdateStartupDetail(); };
            gridStartup.CellDoubleClick += delegate(object s, DataGridViewCellEventArgs e) { if (e.RowIndex >= 0) startupCommand.Focus(); };
            var list = WrapInCard(gridStartup);
            startupEmpty = StartupLabel("正在读取启动项…", Theme.PtStrong, Theme.TextSub);
            startupEmpty.Dock = DockStyle.Fill; startupEmpty.TextAlign = ContentAlignment.MiddleCenter;
            list.Controls.Add(startupEmpty); startupEmpty.BringToFront();

            var details = new Card { Dock = DockStyle.Bottom, Height = 112, Padding = new Padding(16, 10, 16, 10) };
            var detailHead = new Panel { Dock = DockStyle.Top, Height = 34, BackColor = Theme.Surface };
            startupToggle = MakeBtn("禁用自启", 112, 32, false);
            startupToggle.AccessibleName = "Open365.Gui.StartupToggle";
            startupToggle.Dock = DockStyle.Right; startupToggle.Enabled = false;
            startupToggle.Click += delegate { ToggleStartup(); };
            startupDetail = StartupLabel("选择一个程序，查看详情", Theme.PtStrong, Theme.Text);
            startupDetail.Font = Theme.FB(Theme.PtStrong); startupDetail.Dock = DockStyle.Fill;
            detailHead.Controls.Add(startupDetail); detailHead.Controls.Add(startupToggle);
            startupReason = StartupLabel("禁用后仍可手动打开程序，需要时可以恢复自启。", Theme.PtCaption, Theme.TextSub);
            startupReason.Dock = DockStyle.Top; startupReason.Height = 24;
            startupCommand = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, BorderStyle = BorderStyle.None,
                BackColor = Theme.Surface, ForeColor = Theme.TextSub, Font = Theme.F(Theme.PtCaption), ScrollBars = ScrollBars.Vertical,
                AccessibleName = "Open365.Gui.StartupCommand" };
            details.Controls.Add(startupCommand); details.Controls.Add(startupReason); details.Controls.Add(detailHead);
            var gap = new Panel { Dock = DockStyle.Bottom, Height = 10 };
            lblStartupCount = new Label { Dock = DockStyle.Bottom, Height = 26, TextAlign = ContentAlignment.MiddleLeft,
                ForeColor = Theme.TextSub, Font = Theme.F(Theme.PtCaption), AutoEllipsis = true };
            pageStartup.Controls.Add(list); pageStartup.Controls.Add(gap); pageStartup.Controls.Add(details);
            pageStartup.Controls.Add(lblStartupCount); pageStartup.Controls.Add(tools); pageStartup.Controls.Add(stats);
        }

        void PopulateStartup(string json)
        {
            var data = Program.ParseJson(json);
            var items = data == null ? null : Program.Arr(data, "items");
            if (items == null) { StartupLoadFailed("返回的数据无法读取，请刷新重试。"); return; }
            startupItems.Clear();
            foreach (var item in items)
            {
                var d = item as Dictionary<string, object>;
                if (d != null) startupItems.Add(d);
            }
            startupItems.Sort(delegate(Dictionary<string, object> a, Dictionary<string, object> b) {
                int state = string.Compare(Program.Str(b, "state"), Program.Str(a, "state"), StringComparison.Ordinal);
                return state != 0 ? state : string.Compare(Program.Str(a, "name"), Program.Str(b, "name"), StringComparison.CurrentCultureIgnoreCase);
            });
            startupLoaded = true;
            startupLoadError = "";
            RenderStartup();
        }

        void RenderStartup()
        {
            if (gridStartup == null || startupEmpty == null) return;
            int enabled = 0, disabled = 0, optional = 0;
            string query = startupSearch.Text.Trim();
            startupRendering = true;
            gridStartup.SuspendLayout(); gridStartup.Rows.Clear();
            foreach (var item in startupItems)
            {
                bool on = Program.Str(item, "state") == "enabled";
                string advice = Program.Str(item, "advice");
                if (on) enabled++; else disabled++;
                if (on && advice == "optional") optional++;
                if (startupFilter == "enabled" && !on || startupFilter == "disabled" && on || startupFilter == "optional" && (!on || advice != "optional")) continue;
                string search = Program.Str(item, "name") + " " + Program.Str(item, "command") + " " + Program.Str(item, "target_path") + " " + Program.Str(item, "source");
                if (query.Length > 0 && search.IndexOf(query, StringComparison.CurrentCultureIgnoreCase) < 0) continue;
                string adviceText = advice == "keep" ? "建议保留" : advice == "optional" ? "可按需关闭" : "需要你判断";
                int index = gridStartup.Rows.Add(Program.Str(item, "name"), on ? "已启用" : "已禁用", adviceText, Program.Str(item, "source"), Program.Str(item, "id"));
                var row = gridStartup.Rows[index]; row.Tag = item;
                row.Cells["name"].ToolTipText = Program.Str(item, "command");
                row.Cells["state"].Style.ForeColor = on ? Theme.Brand : Theme.TextSub;
                row.Cells["advice"].Style.ForeColor = advice == "keep" ? Theme.Brand : Theme.TextSub;
                row.Cells["advice"].ToolTipText = Program.Str(item, "advice_reason");
            }
            startupEnabled.Text = enabled.ToString(); startupDisabled.Text = disabled.ToString(); startupOptional.Text = optional.ToString();
            foreach (var pair in startupFilters) { ((RoundBtn)pair.Value).Solid = pair.Key == startupFilter; pair.Value.Invalidate(); }
            if (gridStartup.Rows.Count > 0)
            {
                var selected = gridStartup.Rows[0];
                foreach (DataGridViewRow row in gridStartup.Rows) if ((string)row.Cells["id"].Value == startupSelectedId) { selected = row; break; }
                gridStartup.CurrentCell = selected.Cells["name"];
            }
            startupEmpty.Text = startupLoaded ? (startupItems.Count == 0 ? "没有发现启动项\n点击「新增自启」添加常用程序。" : "没有匹配的启动项\n试试其他关键词或切换到「全部」。") : "正在读取启动项…";
            startupEmpty.Visible = gridStartup.Rows.Count == 0;
            gridStartup.ResumeLayout(); startupRendering = false;
            UpdateStartupDetail();
            lblStartupCount.Text = startupLoadError.Length > 0 ? "读取失败 · " + startupLoadError : startupBusy ? "正在处理启动项…" :
                startupNotice + "显示 " + gridStartup.Rows.Count + " / " + startupItems.Count + " 项 · 覆盖注册表和启动文件夹，不含计划任务、服务和商店应用";
        }

        Dictionary<string, object> SelectedStartup()
        {
            return gridStartup.CurrentRow == null ? null : gridStartup.CurrentRow.Tag as Dictionary<string, object>;
        }

        void UpdateStartupDetail()
        {
            var item = SelectedStartup();
            startupToggle.Enabled = item != null && !startupBusy && gridStartup.Enabled;
            if (item == null)
            {
                startupDetail.Text = "选择一个程序，查看详情";
                startupReason.Text = "搜索支持程序名称、完整路径和来源。";
                startupCommand.Text = ""; return;
            }
            startupSelectedId = Program.Str(item, "id");
            bool on = Program.Str(item, "state") == "enabled";
            startupDetail.Text = Program.Str(item, "name") + "  /  " + (on ? "已启用" : "已禁用");
            startupToggle.Text = on ? "禁用自启" : "恢复自启";
            startupReason.Text = Program.Str(item, "advice_reason");
            // Windows / 其他工具的禁用状态尚未纳入，避免把本地备份状态当作系统最终状态。
            startupReason.Text += " · 若在 Windows 中禁用过，请到系统设置核对。";
            string target = Program.Str(item, "target_path");
            startupCommand.Text = target.Length > 0 ? "程序：" + target + " " + Program.Str(item, "arguments") + "\r\n位置：" + Program.Str(item, "command") : "启动命令：" + Program.Str(item, "command");
        }

        void SetStartupBusy(bool busy, string message)
        {
            startupBusy = busy;
            startupRefresh.Enabled = startupAdd.Enabled = !busy;
            startupToggle.Enabled = !busy && gridStartup.Enabled && SelectedStartup() != null;
            if (message != null) lblStartupCount.Text = message;
        }

        void StartupLoadFailed(string message)
        {
            startupLoadError = message;
            SetStartupBusy(false, "读取失败 · " + message);
            startupToggle.Enabled = false;
            gridStartup.Enabled = false;
            if (startupItems.Count == 0) { startupEmpty.Text = "暂时无法读取启动项\n点击「刷新」重试。"; startupEmpty.Visible = true; }
        }

        void LoadStartup()
        {
            if (startupBusy) return;
            SetStartupBusy(true, "正在读取启动项…");
            Act("startup.list", null, delegate(Dictionary<string, object> output, Dictionary<string, object> error) {
                if (output == null) { StartupLoadFailed(Program.Str(error, "message")); return; }
                gridStartup.Enabled = true;
                SetStartupBusy(false, null);
                PopulateStartup(new JavaScriptSerializer().Serialize(output));
            });
        }

        void ToggleStartup()
        {
            var item = SelectedStartup();
            if (startupBusy || item == null || !gridStartup.Enabled) return;
            bool on = Program.Str(item, "state") == "enabled";
            if (on && Program.Str(item, "advice") == "keep" && MessageBox.Show(this,
                "「" + Program.Str(item, "name") + "」可能与驱动或安全防护有关。\n" + Program.Str(item, "advice_reason") + "\n\n仍要禁用它的开机自启吗？",
                "确认禁用", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
            string name = Program.Str(item, "name");
            startupNotice = "";
            SetStartupBusy(true, "正在" + (on ? "禁用 " : "恢复 ") + name + "…");
            ActC(on ? "startup.disable" : "startup.enable", Program.JsonInput("id", Program.Str(item, "id")),
                delegate(Dictionary<string, object> output, Dictionary<string, object> error) {
                    SetStartupBusy(false, null);
                    if (output == null) { MessageBox.Show(this, Program.Str(error, "message"), "操作未完成", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
                    else { startupNotice = (on ? "已禁用 " : "已恢复 ") + name + " · "; }
                    LoadStartup();
                });
        }

        void AddStartup()
        {
            if (startupBusy) return;
            using (var dialog = new StartupAddDialog())
            {
                dialog.SaveRequested += delegate {
                    dialog.SetBusy(true, "正在添加…");
                    var input = new Dictionary<string, object>();
                    input["name"] = dialog.ItemName; input["target_path"] = dialog.TargetPath; input["arguments"] = dialog.Arguments;
                    ActC("startup.add", new JavaScriptSerializer().Serialize(input),
                        delegate(Dictionary<string, object> output, Dictionary<string, object> error) {
                            if (dialog.IsDisposed) return;
                            if (output == null) { dialog.SetBusy(false, Program.Str(error, "message")); return; }
                            startupSelectedId = Program.Str(output, "id");
                            startupNotice = "已添加 " + dialog.ItemName + "，下次登录生效 · ";
                            startupFilter = "all"; startupSearch.Clear();
                            dialog.SetBusy(false, ""); dialog.DialogResult = DialogResult.OK;
                        });
                };
                if (dialog.ShowDialog(this) == DialogResult.OK) LoadStartup();
            }
        }
    }

    internal sealed class StartupAddDialog : Form
    {
        readonly TextBox nameBox, pathBox, argsBox;
        readonly Label message;
        readonly Button save, browse, cancel;
        bool busy;
        internal event Action SaveRequested;
        internal string ItemName { get { return nameBox.Text.Trim(); } }
        internal string TargetPath { get { return pathBox.Text.Trim().Trim('"'); } }
        internal string Arguments { get { return argsBox.Text; } }

        internal StartupAddDialog()
        {
            Text = "新增开机自启"; StartPosition = FormStartPosition.CenterParent;
            ClientSize = new Size(560, 386); FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = MinimizeBox = false; BackColor = Theme.Surface; Font = Theme.F(Theme.PtBody);
            var title = new Label { Text = "把常用程序加入开机自启", Location = new Point(24, 18), Size = new Size(510, 32), Font = Theme.FB(Theme.PtTitle) };
            var hint = new Label { Text = "仅对当前用户生效，下次登录时启动。现在不会打开程序。", Location = new Point(24, 54), Size = new Size(510, 26), ForeColor = Theme.TextSub };
            Controls.Add(title); Controls.Add(hint);
            pathBox = AddField("程序路径", 90, 402);
            pathBox.AccessibleName = "Open365.Gui.StartupAdd.Path";
            browse = new RoundBtn { Text = "浏览…", Location = new Point(434, 112), Size = new Size(100, 29), Tint = Theme.Brand };
            browse.Click += delegate {
                using (var picker = new OpenFileDialog { Title = "选择要自动启动的程序", Filter = "程序 (*.exe;*.com;*.bat;*.cmd)|*.exe;*.com;*.bat;*.cmd", CheckFileExists = true })
                    if (picker.ShowDialog(this) == DialogResult.OK) {
                        pathBox.Text = picker.FileName;
                        if (nameBox.Text.Trim().Length == 0) nameBox.Text = Path.GetFileNameWithoutExtension(picker.FileName);
                    }
            };
            Controls.Add(browse);
            nameBox = AddField("显示名称", 154, 510); nameBox.MaxLength = 100;
            nameBox.AccessibleName = "Open365.Gui.StartupAdd.Name";
            argsBox = AddField("启动参数（可选，不清楚就留空）", 218, 510);
            argsBox.AccessibleName = "Open365.Gui.StartupAdd.Arguments";
            message = new Label { Location = new Point(24, 282), Size = new Size(510, 45), ForeColor = Theme.Bad, AutoEllipsis = true };
            Controls.Add(message);
            cancel = new RoundBtn { Text = "取消", Location = new Point(306, 338), Size = new Size(100, 34), Tint = Theme.Brand, DialogResult = DialogResult.Cancel };
            save = new RoundBtn { Text = "添加自启", Location = new Point(418, 338), Size = new Size(116, 34), Tint = Theme.Brand, Solid = true };
            save.Click += delegate {
                if (ItemName.Length == 0) { message.Text = "请填写显示名称。"; nameBox.Focus(); return; }
                if (!Path.IsPathRooted(TargetPath) || !File.Exists(TargetPath)) { message.Text = "请选择存在的程序文件。"; pathBox.Focus(); return; }
                if (SaveRequested != null) SaveRequested();
            };
            Controls.Add(cancel); Controls.Add(save); AcceptButton = save; CancelButton = cancel;
            FormClosing += delegate(object s, FormClosingEventArgs e) { if (busy) e.Cancel = true; };
            Dpi.Apply(this);
        }

        TextBox AddField(string caption, int top, int width)
        {
            Controls.Add(new Label { Text = caption, Location = new Point(24, top), Size = new Size(510, 22), ForeColor = Theme.TextSub });
            var box = new TextBox { Location = new Point(24, top + 24), Width = width, Font = Theme.F(Theme.PtBody) };
            Controls.Add(box); return box;
        }

        internal void SetBusy(bool value, string text)
        {
            busy = value; save.Enabled = browse.Enabled = cancel.Enabled = !value;
            nameBox.ReadOnly = pathBox.ReadOnly = argsBox.ReadOnly = value;
            message.Text = text; save.Text = value ? "正在添加…" : "添加自启";
        }
    }
}
