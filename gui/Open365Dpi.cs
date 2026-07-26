// Open365 高 DPI 缩放 —— 修「有些电脑上界面全挤到一块」
//
// 病根（2026-07-26 定位）：
//   app.manifest 里写着 <dpiAware>true</dpiAware>，等于告诉 Windows
//   「我自己处理缩放，别把我的窗口位图拉伸」。但代码里从来没有任何缩放机制 ——
//   既没设 AutoScaleMode，也没调过 Scale()。于是在 125% / 150% 缩放的电脑上：
//     · 字体用的是 point 单位 —— GDI+ 按屏幕 DPI 换算成像素，文字自动变大 1.25~1.5 倍；
//     · 控件的 Location / Size / Padding 全是硬编码像素 —— 一动不动。
//   大字塞进没变大的盒子，就是客户截图里那种「叠成一坨」。
//   开发机是 96 DPI（100%），所以本机永远复现不了 —— 正对上「有些电脑」。
//
// 修法：窗体控件建完之后，把整棵控件树按 DPI/96 缩放一次。
// 两条实测结论（本机 96 DPI 上量的，见 git 提交说明）：
//   1) Form.Scale(1.5) 会缩放 Bounds / Padding / Margin / MinimumSize，
//      但**不碰 Font**（10.5pt 缩放后还是 10.5pt）；
//   2) 同一个 10.5pt 字体，96 DPI 下高 19.53px，144 DPI 下高 29.30px —— 正好 1.5 倍。
//   两者相乘刚好凑成一套一致的布局，既不会漏缩，也不会双重放大。
//
// Scale() 够不到的地方一律走 Dpi.Px()：
//   DataGridView 行高 / 表头高、单元格 Padding、图标位图的像素尺寸、
//   窗体缩放**之后**才创建的控件、Resize 回调里的常数、自绘代码里的偏移量。
//
// OPEN365_UI_SCALE 环境变量：手动指定倍率（0.5~4）。既是「嫌小想调大」的用户旋钮，
// 也是开发机上复现高 DPI 布局的自测开关 —— 它会连字体一起按差额放大，
// 让 96 DPI 的机器也能看到 150% 电脑上的真实排版。
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.Windows.Forms;

namespace Open365
{
    internal static class Dpi
    {
        /// 布局倍率：96 DPI = 1.0，150% 缩放 = 1.5。
        internal static float Factor = 1f;

        /// 字体额外倍率。正常恒为 1（point 字体由 DPI 自己放大，再乘就重复了）；
        /// 只有手动指定 OPEN365_UI_SCALE 时才补上「指定倍率 ÷ 真实 DPI 倍率」这段差额。
        internal static float FontFactor = 1f;

        static bool inited;

        /// 进程启动时调一次（必须在建任何窗体之前）。
        internal static void Init()
        {
            if (inited) return;
            inited = true;

            float dpi = 1f;
            try
            {
                using (var g = Graphics.FromHwnd(IntPtr.Zero)) dpi = g.DpiX / 96f;
            }
            catch { }
            if (dpi < 1f) dpi = 1f;          // 只放大不缩小
            if (dpi > 4f) dpi = 4f;

            float want = dpi;
            try
            {
                string s = Environment.GetEnvironmentVariable("OPEN365_UI_SCALE");
                float ov;
                if (!string.IsNullOrEmpty(s) &&
                    float.TryParse(s.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out ov) &&
                    ov >= 0.5f && ov <= 4f)
                    want = ov;
            }
            catch { }

            Factor = want;
            FontFactor = (dpi > 0.01f) ? (want / dpi) : 1f;
        }

        /// 设计稿像素（按 96 DPI 画的）→ 当前屏幕像素。
        internal static int Px(int designPx)
        {
            if (Factor <= 1.005f && Factor >= 0.995f) return designPx;
            return (int)Math.Round(designPx * Factor);
        }

        internal static Size Px(Size s)
        {
            return new Size(Px(s.Width), Px(s.Height));
        }

        /// 设计稿字号 → 实际字号。正常原样返回；只有手动指定倍率时才补差额。
        internal static float Pt(float designPt)
        {
            if (FontFactor <= 1.005f && FontFactor >= 0.995f) return designPt;
            return designPt * FontFactor;
        }

        // 已经缩放过的控件树（用引用相等去重）。
        static readonly HashSet<Control> scaled = new HashSet<Control>();

        /// 缩放一棵**游离的**控件树，且只缩一次。
        ///
        /// 管理中心的各功能页是「构造期建好先放着、用户点到才挂进 content」的游离面板：
        /// Dpi.Apply(窗体) 跑的时候它们不在控件树上，Form.Scale 够不着 ——
        /// 结果就是字随 DPI 变大、这些页的盒子却一动不动（客户看到的「挤成一坨」）。
        /// 所以挂载前在这里补一次。用 HashSet 保证「只缩一次」，
        /// 页面反复切换不会越缩越大，将来新增页面也不会漏 —— 挂载走这条路就行。
        internal static void ScaleOnce(Control c)
        {
            if (c == null) return;
            if (!scaled.Add(c)) return;
            if (Factor > 1.005f) c.Scale(new SizeF(Factor, Factor));
        }

        /// 窗体的控件全部建完之后调一次：整棵树缩放 + 别顶出屏幕。
        internal static void Apply(Form f)
        {
            if (f == null) return;
            // 我们自己算缩放，别让 WinForms 的自动缩放再插一脚（避免缩两遍）
            f.AutoScaleMode = AutoScaleMode.None;
            if (Factor > 1.005f) f.Scale(new SizeF(Factor, Factor));
            ClampToWorkingArea(f);
        }

        /// 150% 缩放 + 1366×768 的小笔记本上，等比放大后的窗口会比屏幕还大 ——
        /// 顶出屏幕一样是「看不全」。所以下限和窗口本身都要压回工作区。
        static void ClampToWorkingArea(Form f)
        {
            Rectangle wa;
            try { wa = Screen.PrimaryScreen.WorkingArea; }
            catch { return; }
            if (wa.Width <= 0 || wa.Height <= 0) return;

            Size min = f.MinimumSize;
            if (min.Width > wa.Width || min.Height > wa.Height)
                f.MinimumSize = new Size(Math.Min(min.Width, wa.Width), Math.Min(min.Height, wa.Height));

            Size sz = f.Size;
            if (sz.Width > wa.Width || sz.Height > wa.Height)
                f.Size = new Size(Math.Min(sz.Width, wa.Width), Math.Min(sz.Height, wa.Height));
        }
    }
}
