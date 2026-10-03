// Uses the actual WinForms controls with deterministic data; never runs startup actions.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Windows.Forms;
using System.Web.Script.Serialization;

namespace Open365
{
    internal static class StartupUiTests
    {
        static object Field(object target, string name) { return target.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic).GetValue(target); }
        static void Call(object target, string name, params object[] args) { target.GetType().GetMethod(name, BindingFlags.Instance | BindingFlags.NonPublic).Invoke(target, args); }
        static void Check(string name, bool ok) { if (!ok) throw new Exception(name); Console.WriteLine("[PASS] " + name); }
        [STAThread]
        static int Main(string[] args)
        {
            try
            {
                Application.EnableVisualStyles(); Dpi.Init();
                string output = args[0]; Directory.CreateDirectory(output);
                using (var form = new ManagerForm())
                {
                    form.StartPosition = FormStartPosition.Manual; form.Location = new Point(-12000, -12000); form.ShowInTaskbar = false;
                    // Mount directly: ShowPage would intentionally read the real machine in the background.
                    Call(form, "Mount", Field(form, "pageStartup")); Call(form, "SetNavActive", "startup");
                    ((Label)Field(form, "headTitle")).Text = "开机启动";
                    ((Label)Field(form, "headSub")).Text = "让开机更清爽。决定哪些程序在登录后自动运行。";
                    var items = new List<Dictionary<string, object>>();
                    string[] names = { "微信", "Microsoft OneDrive", "Windows Security", "Steam", "网易云音乐", "设计工具", "工作台", "显卡控制面板", "会议助手" };
                    for (int i = 0; i < names.Length; i++) items.Add(new Dictionary<string, object> {
                        {"id", "item:" + i}, {"name", names[i]}, {"state", i < 6 ? "enabled" : "disabled"},
                        {"source", i % 2 == 0 ? "注册表 (当前用户)" : "启动文件夹 (当前用户)"},
                        {"advice", i == 2 ? "keep" : i % 2 == 0 ? "unknown" : "optional"},
                        {"advice_reason", i == 2 ? "系统安全相关，建议保留" : "根据使用习惯决定，禁用后仍然可以手动打开程序。"},
                        {"command", "\"C:\\Program Files\\" + names[i] + "\\app.exe\" --background"}
                    });
                    var json = new JavaScriptSerializer().Serialize(new { items = items });
                    form.Show(); Call(form, "PopulateStartup", json); Application.DoEvents();
                    var grid = (DataGridView)Field(form, "gridStartup");
                    var search = (TextBox)Field(form, "startupSearch");
                    Check("all items loaded", grid.Rows.Count == 9);
                    search.Text = "微信"; Check("search by name", grid.Rows.Count == 1);
                    search.Text = "Program Files"; Check("search by command", grid.Rows.Count == 9);
                    search.Text = "不存在"; Check("empty search has no actionable selection", grid.Rows.Count == 0 && !((Button)Field(form, "startupToggle")).Enabled);
                    search.Clear();
                    var filters = (Dictionary<string, Button>)Field(form, "startupFilters");
                    filters["disabled"].PerformClick(); Check("disabled filter", grid.Rows.Count == 3);
                    filters["optional"].PerformClick(); Check("optional filter excludes disabled items", grid.Rows.Count == 3);
                    filters["all"].PerformClick();
                    grid.Sort(grid.Columns["name"], System.ComponentModel.ListSortDirection.Descending);
                    grid.CurrentCell = grid.Rows[0].Cells["name"];
                    var selected = grid.CurrentRow.Tag as Dictionary<string, object>;
                    Check("sorted selection shows matching details", ((Label)Field(form, "startupDetail")).Text.Contains((string)selected["name"]));
                    Call(form, "SetStartupBusy", true, "正在读取…");
                    Check("pending work prevents duplicate actions", !((Button)Field(form, "startupToggle")).Enabled && !((Button)Field(form, "startupAdd")).Enabled);
                    Call(form, "SetStartupBusy", false, null);
                    Call(form, "PopulateStartup", json);
                    grid.CurrentCell = grid.Rows[0].Cells["name"];
                    grid.FirstDisplayedScrollingRowIndex = 0;
                    foreach (int width in new int[] { 1000, 880 })
                    {
                        form.ClientSize = new Size(Dpi.Px(width), Dpi.Px(width == 880 ? 540 : 640)); Application.DoEvents();
                        Check("usable table at " + width + " (" + grid.Width + "x" + grid.Height + ")", grid.Width > Dpi.Px(560) && grid.Height > Dpi.Px(110));
                        var add = (Button)Field(form, "startupAdd");
                        Check("add button in toolbar", add.Left >= 0 && add.Right <= add.Parent.ClientSize.Width);
                        using (var bitmap = new Bitmap(form.Width, form.Height)) { form.DrawToBitmap(bitmap, new Rectangle(0, 0, form.Width, form.Height)); bitmap.Save(Path.Combine(output, "startup-" + width + ".png")); }
                    }
                    Call(form, "PopulateStartup", "{\"items\":[]}"); Check("empty list is valid", grid.Rows.Count == 0);
                    Call(form, "PopulateStartup", "broken-json"); Check("load errors disable stale actions", !grid.Enabled && !((Button)Field(form, "startupToggle")).Enabled);
                }
                using (var dialog = new StartupAddDialog())
                {
                    dialog.StartPosition = FormStartPosition.Manual; dialog.Location = new Point(-12000, -12000); dialog.ShowInTaskbar = false;
                    dialog.Show(); Application.DoEvents();
                    using (var bitmap = new Bitmap(dialog.Width, dialog.Height)) { dialog.DrawToBitmap(bitmap, new Rectangle(0, 0, dialog.Width, dialog.Height)); bitmap.Save(Path.Combine(output, "startup-add.png")); }
                    dialog.Close();
                }
                return 0;
            }
            catch (Exception e) { Console.Error.WriteLine(e); return 1; }
        }
    }
}
