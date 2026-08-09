// Open365 视觉基准 —— 颜色 / 间距 / 字号的唯一出处，外加两个自绘控件。
//
// 为什么要有这个文件（2026-08 重构）：
//   改之前颜色散在三个文件里，光「品牌绿」就有两个几乎一样但不相等的值
//   （OkGreen 35,134,54 与 Accent 34,124,79），间距用 4/6/10/14/15/18/22 随手写，
//   字号横跨 9 / 9.5 / 10 / 10.5 / 11 / 13.5 / 14 / 15 八档 —— 单看每处都合理，
//   放到一屏里就是「哪儿哪儿都差半格」。这里收成一套标度，新代码一律引用它。
//
// 注意：这条「共用一个库」只适用于 GUI 层。docs/架构约定.md 里
// 「不许抽公共库」管的是 engine/*.ps1（引擎必须能单独跑），跟 C# 界面无关。
//
// 高 DPI：本文件里的数字全是 96 DPI 设计像素。颜色无所谓缩放；
// 间距常量由调用方按需过 Dpi.Px()；字号一律过 Theme.F()/FB()（内部走 Dpi.Pt）。
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace Open365
{
    internal static class Theme
    {
        // ---------- 画布与卡片 ----------
        internal static readonly Color Canvas = Color.FromArgb(244, 245, 247);   // 页面底色（浅灰）
        internal static readonly Color Surface = Color.White;                    // 卡片底色
        internal static readonly Color Border = Color.FromArgb(231, 234, 238);   // 卡片描边
        internal static readonly Color Divider = Color.FromArgb(238, 241, 244);  // 列表行分隔线（比描边更淡）

        // ---------- 文字三档 ----------
        internal static readonly Color Text = Color.FromArgb(26, 32, 40);        // 主文字
        internal static readonly Color TextSub = Color.FromArgb(92, 102, 114);   // 次要文字 / 表头
        internal static readonly Color TextDim = Color.FromArgb(142, 150, 160);  // 说明 / 禁用

        // ---------- 品牌与语义（全程序只有一个绿）----------
        internal static readonly Color Brand = Color.FromArgb(34, 124, 79);
        internal static readonly Color BrandHot = Color.FromArgb(41, 143, 92);   // 悬停
        internal static readonly Color BrandDark = Color.FromArgb(26, 98, 62);   // 按下
        internal static readonly Color BrandSoft = Color.FromArgb(232, 243, 236);// 选中 / 浅底
        internal static readonly Color BrandLite = Color.FromArgb(90, 190, 120); // 深色底上的亮绿
        internal static readonly Color Ok = Color.FromArgb(34, 124, 79);         // = Brand，语义别名
        internal static readonly Color Warn = Color.FromArgb(191, 111, 0);
        internal static readonly Color WarnInk = Color.FromArgb(90, 70, 20);     // 提示条正文（深琥珀）
        internal static readonly Color WarnBg = Color.FromArgb(255, 250, 235);   // 提示条底（奶油）
        internal static readonly Color Bad = Color.FromArgb(207, 34, 46);

        // ---------- 左侧深色导航 ----------
        internal static readonly Color NavBg = Color.FromArgb(23, 26, 31);
        internal static readonly Color NavHover = Color.FromArgb(33, 37, 44);
        internal static readonly Color NavPicked = Color.FromArgb(38, 43, 51);   // 选中态：浅一档的底 + 左侧绿条
        internal static readonly Color NavText = Color.FromArgb(206, 212, 219);
        internal static readonly Color NavIcon = Color.FromArgb(138, 146, 156);

        // ---------- 间距标度：一律 4 的倍数 ----------
        internal const int S1 = 4;
        internal const int S2 = 8;
        internal const int S3 = 12;
        internal const int S4 = 16;
        internal const int S6 = 24;

        // ---------- 字号五档 ----------
        // 从原来的八档收敛而来，每档改动都 <= 0.5pt（10→10.5、11→10.5、14→13.5），
        // 且以缩小为主，不会把任何固定尺寸的标签撑破。
        internal const float PtDisplay = 15F;    // 页面大标题 / 体检结论
        internal const float PtTitle = 13.5F;    // 卡片数值 / 区块标题
        internal const float PtStrong = 10.5F;   // 导航项 / 状态行名称 / 主按钮
        internal const float PtBody = 9.5F;      // 正文 / 表格 / 普通按钮
        internal const float PtCaption = 9F;     // 说明 / 副标题 / 单位

        const string Face = "Microsoft YaHei UI";

        internal static Font F(float pt) { return new Font(Face, Dpi.Pt(pt)); }
        internal static Font FB(float pt) { return new Font(Face, Dpi.Pt(pt), FontStyle.Bold); }

        /// 抗锯齿圆角矩形路径。调用方负责先把 SmoothingMode 设成 AntiAlias。
        /// radius 传**设备像素**（已过 Dpi.Px）—— 自绘代码不在 Bounds 里，Form.Scale 碰不到。
        internal static GraphicsPath RoundRect(Rectangle r, int radius)
        {
            var path = new GraphicsPath();
            int d = radius * 2;
            if (d <= 0 || d > r.Width || d > r.Height) { path.AddRectangle(r); return path; }
            path.AddArc(r.X, r.Y, d, d, 180, 90);
            path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }

        /// 自绘控件要「铺一层父级底色」才不会在圆角外留脏像素。
        /// 不能直接用 Parent.BackColor：Card 的 BackColor 是 Transparent（它自绘白底），
        /// 照抄会把卡片里按钮的四角刷成黑的。所以往上找第一个真正不透明的底色。
        internal static Color BackdropOf(Control c)
        {
            for (Control p = (c == null) ? null : c.Parent; p != null; p = p.Parent)
            {
                var card = p as Card;
                if (card != null) return card.Fill;
                if (p.BackColor.A == 255) return p.BackColor;
            }
            return Surface;
        }
    }

    // =====================================================================
    //  抗锯齿圆角按钮
    // =====================================================================
    // 旧做法是 Region 裁剪（Open365Pages.Round）：Region 是**二值**的，
    // 每个像素要么在里面要么在外面，没有中间灰度 —— 于是 7px 的圆角边上
    // 排着一串台阶状锯齿，在浅灰画布上尤其明显。
    // 这里整体自绘：GraphicsPath + SmoothingMode.AntiAlias，边缘干净。
    // 顺带补上 悬停 / 按下 / 禁用 三态（UserPaint 之后 FlatAppearance 不再生效）。
    internal class RoundBtn : Button
    {
        internal int Radius = 7;                  // 96 DPI 设计像素
        internal bool Solid;                      // true = 实心主按钮，false = 描边次按钮
        internal Color Tint = Theme.Brand;

        bool hot, down;

        internal RoundBtn()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw |
                     ControlStyles.SupportsTransparentBackColor, true);
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            BackColor = Color.Transparent;
            Cursor = Cursors.Hand;
            Font = Theme.F(Theme.PtBody);
        }

        protected override void OnMouseEnter(EventArgs e) { hot = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hot = false; down = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { down = true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnEnabledChanged(EventArgs e) { hot = false; down = false; Invalidate(); base.OnEnabledChanged(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.Clear(Theme.BackdropOf(this));
            g.SmoothingMode = SmoothingMode.AntiAlias;

            Color fill, edge, ink;
            if (!Enabled)
            {
                fill = Theme.Canvas; edge = Theme.Border; ink = Theme.TextDim;
            }
            else if (Solid)
            {
                fill = down ? Theme.BrandDark : (hot ? Theme.BrandHot : Tint);
                edge = fill; ink = Color.White;
            }
            else
            {
                fill = down ? Theme.BrandSoft : (hot ? Theme.BrandSoft : Theme.Surface);
                edge = Tint; ink = Tint;
            }

            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var path = Theme.RoundRect(r, Dpi.Px(Radius)))
            {
                using (var b = new SolidBrush(fill)) g.FillPath(b, path);
                using (var p = new Pen(edge)) g.DrawPath(p, path);
            }

            // 图标 + 文字作为一组摆放：TextAlign 左对齐时整组从 Padding.Left 起手，
            // 否则整组居中。调用方原先靠在文字前塞空格来腾图标位，这里自己算间距，
            // 所以先把那些空格 Trim 掉，免得左边多一块空。
            string txt = (Text ?? "").Trim();
            g.SmoothingMode = SmoothingMode.None;
            Size ts = TextRenderer.MeasureText(g, txt, Font, new Size(int.MaxValue, int.MaxValue), TextFormatFlags.NoPadding);
            int iw = (Image != null) ? Image.Width : 0;
            int ih = (Image != null) ? Image.Height : 0;
            int gap = (Image != null && txt.Length > 0) ? Dpi.Px(4) : 0;
            int total = iw + gap + ts.Width;

            bool left = TextAlign == ContentAlignment.MiddleLeft ||
                        TextAlign == ContentAlignment.TopLeft ||
                        TextAlign == ContentAlignment.BottomLeft;
            int x = left ? Padding.Left : (Width - total) / 2;
            if (x < Padding.Left) x = Padding.Left;

            if (Image != null)
            {
                g.DrawImage(Image, new Rectangle(x, (Height - ih) / 2, iw, ih));
                x += iw + gap;
            }
            TextRenderer.DrawText(g, txt, Font, new Point(x, (Height - ts.Height) / 2), ink, TextFormatFlags.NoPadding);
        }
    }

    // =====================================================================
    //  左侧导航项
    // =====================================================================
    // 选中态原先是整条按钮刷成品牌绿的实心块 —— 视觉重量太大，一眼就「便宜」。
    // 换成主流深色导航的做法：浅一档的底 + 左侧 3px 品牌绿指示条 + 图标着色。
    internal class NavItem : Button
    {
        internal bool Picked;
        bool hot;

        internal NavItem()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            Cursor = Cursors.Hand;
            TextAlign = ContentAlignment.MiddleLeft;
        }

        protected override void OnMouseEnter(EventArgs e) { hot = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hot = false; Invalidate(); base.OnMouseLeave(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.Clear(Picked ? Theme.NavPicked : (hot ? Theme.NavHover : Theme.NavBg));

            if (Picked)
            {
                int bw = Dpi.Px(3);
                int inset = Dpi.Px(10);
                g.SmoothingMode = SmoothingMode.AntiAlias;
                using (var path = Theme.RoundRect(new Rectangle(0, inset, bw * 2, Height - inset * 2), bw))
                using (var b = new SolidBrush(Theme.Brand))
                    g.FillPath(b, path);   // 画两倍宽再让左半截被圆角吃掉 = 右侧圆、左侧平的指示条
                g.SmoothingMode = SmoothingMode.None;
            }

            string txt = (Text ?? "").Trim();
            Size ts = TextRenderer.MeasureText(g, txt, Font, new Size(int.MaxValue, int.MaxValue), TextFormatFlags.NoPadding);
            int x = Padding.Left;
            if (Image != null)
            {
                g.DrawImage(Image, new Rectangle(x, (Height - Image.Height) / 2, Image.Width, Image.Height));
                x += Image.Width + Dpi.Px(8);
            }
            TextRenderer.DrawText(g, txt, Font, new Point(x, (Height - ts.Height) / 2), ForeColor, TextFormatFlags.NoPadding);
        }
    }
}
