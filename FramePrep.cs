using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Collections.Generic;

// ══════════════════════════════════════════════════════════════════
//  FramePrep —— 把一组同构图的立绘处理成可对齐的桌宠帧
//    1. 从四边泛洪去背景（利用背景是平滑的浅灰渐变）
//    2. 清掉"被包住但其实还是背景色"的残块（用局部背景色判断）
//    3. 边缘做反混合（unblend），去掉白边/灰边
//    4. 取所有帧的并集包围盒统一裁剪，保证帧之间对位不跳
//    5. 等比缩放到统一高度
// ══════════════════════════════════════════════════════════════════
public static class FramePrep
{
    class Frame
    {
        public string Name;
        public Bitmap Img;
        public Rectangle Bbox;
    }

    public static string Run(string[] paths, string[] names, string outDir, int targetH, int workH,
                             int tol, bool patchCursor)
    {
        var frames = new List<Frame>();
        for (int i = 0; i < paths.Length; i++)
        {
            Bitmap src = new Bitmap(paths[i]);
            double sc = (double)workH / src.Height;
            int w = Math.Max(8, (int)Math.Round(src.Width * sc));
            int h = workH;
            var work = new Bitmap(w, h, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(work))
            {
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;
                g.DrawImage(src, 0, 0, w, h);
            }
            src.Dispose();

            if (patchCursor && names[i] == "look") PatchRect(work, 0.852f, 0.228f, 0.098f, 0.118f);

            Cutout(work, tol);

            var f = new Frame();
            f.Name = names[i];
            f.Img = work;
            f.Bbox = AlphaBounds(work, 10);
            frames.Add(f);
        }

        int minX = int.MaxValue, minY = int.MaxValue, maxX = -1, maxY = -1;
        foreach (var f in frames)
        {
            if (f.Bbox.Width <= 0) continue;
            if (f.Bbox.X < minX) minX = f.Bbox.X;
            if (f.Bbox.Y < minY) minY = f.Bbox.Y;
            if (f.Bbox.Right > maxX) maxX = f.Bbox.Right;
            if (f.Bbox.Bottom > maxY) maxY = f.Bbox.Bottom;
        }
        if (maxX <= minX || maxY <= minY) return "ERR empty bbox";

        var union = new Rectangle(minX, minY, maxX - minX, maxY - minY);
        double scale = (double)targetH / union.Height;
        int outW = (int)Math.Round(union.Width * scale);
        int outH = targetH;

        var sb = new System.Text.StringBuilder();
        sb.Append("union=").Append(union.X).Append(",").Append(union.Y).Append(",")
          .Append(union.Width).Append("x").Append(union.Height)
          .Append(" -> ").Append(outW).Append("x").Append(outH);

        foreach (var f in frames)
        {
            var outBmp = new Bitmap(outW, outH, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(outBmp))
            {
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;
                g.CompositingQuality = System.Drawing.Drawing2D.CompositingQuality.HighQuality;
                g.Clear(Color.Transparent);
                g.DrawImage(f.Img, new Rectangle(0, 0, outW, outH), union, GraphicsUnit.Pixel);
            }
            outBmp.Save(System.IO.Path.Combine(outDir, f.Name + ".png"), ImageFormat.Png);
            sb.Append("  ").Append(f.Name).Append("=").Append(f.Bbox.Width).Append("x").Append(f.Bbox.Height);
            outBmp.Dispose();
            f.Img.Dispose();
        }
        return "ok " + sb.ToString();
    }

    // 用附近背景色涂掉一块区域（处理原图里画着的鼠标指针）
    static void PatchRect(Bitmap bmp, float nx, float ny, float nw, float nh)
    {
        int w = bmp.Width, h = bmp.Height;
        int x0 = (int)(w * nx), y0 = (int)(h * ny);
        int x1 = (int)(w * (nx + nw)), y1 = (int)(h * (ny + nh));
        long r = 0, g2 = 0, b = 0; int n = 0;
        int sx = Math.Max(0, x0 - 6);
        for (int y = y0; y < y1; y++)
        {
            if (y < 0 || y >= h) continue;
            for (int x = sx; x < Math.Min(w, sx + 4); x++)
            {
                Color c = bmp.GetPixel(x, y);
                r += c.R; g2 += c.G; b += c.B; n++;
            }
        }
        Color fill = n > 0 ? Color.FromArgb(255, (int)(r / n), (int)(g2 / n), (int)(b / n))
                           : Color.FromArgb(255, 232, 230, 232);
        using (var g = Graphics.FromImage(bmp))
        using (var br = new SolidBrush(fill))
            g.FillRectangle(br, x0, y0, x1 - x0, y1 - y0);
    }

    static void Cutout(Bitmap bmp, int tol)
    {
        int w = bmp.Width, h = bmp.Height;
        var data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        int stride = data.Stride;
        byte[] buf = new byte[stride * h];
        System.Runtime.InteropServices.Marshal.Copy(data.Scan0, buf, 0, buf.Length);
        int n = w * h;

        // ── 1. 从四边泛洪，标出"和边缘连通"的背景 ──
        bool[] bg = new bool[n];
        var q = new Queue<int>();
        for (int x = 0; x < w; x++)
        {
            int a = x, b = (h - 1) * w + x;
            if (!bg[a]) { bg[a] = true; q.Enqueue(a); }
            if (!bg[b]) { bg[b] = true; q.Enqueue(b); }
        }
        for (int y = 0; y < h; y++)
        {
            int a = y * w, b = y * w + w - 1;
            if (!bg[a]) { bg[a] = true; q.Enqueue(a); }
            if (!bg[b]) { bg[b] = true; q.Enqueue(b); }
        }

        // 背景是"亮且中性"的浅灰。只靠相邻像素相近会顺着渐变一路渗进角色，
        // 所以这里用颜色模型做闸门：亮度够高 + 饱和度够低，才允许算背景。
        int lumaMin = 172, satMax = 26;
        while (q.Count > 0)
        {
            int cur = q.Dequeue();
            int cx = cur % w, cy = cur / w;
            if (cx + 1 < w) TryPush(buf, bg, q, cur + 1, w, stride, lumaMin, satMax);
            if (cx - 1 >= 0) TryPush(buf, bg, q, cur - 1, w, stride, lumaMin, satMax);
            if (cy + 1 < h) TryPush(buf, bg, q, cur + w, w, stride, lumaMin, satMax);
            if (cy - 1 >= 0) TryPush(buf, bg, q, cur - w, w, stride, lumaMin, satMax);
        }

        // ── 2. 清掉被包住的背景残块（局部背景色判断，避免误删皮肤高光） ──
        double refR = 232, refG = 230, refB = 232;
        {
            long rr = 0, rg = 0, rb = 0; int rn = 0;
            for (int y = 0; y < h; y++)
            {
                if (y >= 4 && y < h - 4) continue;
                for (int x = 0; x < w; x++)
                {
                    if (!bg[y * w + x]) continue;
                    int i = y * stride + x * 4;
                    rr += buf[i + 2]; rg += buf[i + 1]; rb += buf[i]; rn++;
                }
            }
            if (rn > 0) { refR = (double)rr / rn; refG = (double)rg / rn; refB = (double)rb / rn; }
        }

        bool[] seen = new bool[n];
        for (int i = 0; i < n; i++)
        {
            if (seen[i] || bg[i]) continue;
            int ii = i * 4;
            int r = buf[ii + 2], gg = buf[ii + 1], b = buf[ii];
            int mx = Math.Max(r, Math.Max(gg, b)), mn = Math.Min(r, Math.Min(gg, b));
            int luma = (r * 299 + gg * 587 + b * 114) / 1000;
            if ((mx - mn) > 26 || luma < 190) { seen[i] = true; continue; }

            var comp = new List<int>();
            var st = new Stack<int>();
            st.Push(i); seen[i] = true;
            bool border = false;
            long sr = 0, sg = 0, sb = 0;
            while (st.Count > 0)
            {
                int cur = st.Pop();
                comp.Add(cur);
                int cx = cur % w, cy = cur / w;
                if (cx == 0 || cy == 0 || cx == w - 1 || cy == h - 1) border = true;
                int ci2 = cy * stride + cx * 4;
                sr += buf[ci2 + 2]; sg += buf[ci2 + 1]; sb += buf[ci2];
                int[] nb = { cur + 1, cur - 1, cur + w, cur - w };
                for (int k = 0; k < 4; k++)
                {
                    int t = nb[k];
                    if (k == 0 && cx + 1 >= w) continue;
                    if (k == 1 && cx - 1 < 0) continue;
                    if (k == 2 && cy + 1 >= h) continue;
                    if (k == 3 && cy - 1 < 0) continue;
                    if (t < 0 || t >= n || seen[t]) continue;
                    int ti = t * 4;
                    int tr = buf[ti + 2], tg = buf[ti + 1], tb = buf[ti];
                    int tmx = Math.Max(tr, Math.Max(tg, tb)), tmn = Math.Min(tr, Math.Min(tg, tb));
                    int tl = (tr * 299 + tg * 587 + tb * 114) / 1000;
                    seen[t] = true;
                    if ((tmx - tmn) <= 26 && tl >= 190) st.Push(t);
                }
            }
            if (border || comp.Count == 0) continue;

            double ar = (double)sr / comp.Count, ag = (double)sg / comp.Count, ab = (double)sb / comp.Count;

            int bx0 = w, by0 = h, bx1 = -1, by1 = -1;
            foreach (int pix in comp)
            {
                int px2 = pix % w, py2 = pix / w;
                if (px2 < bx0) bx0 = px2;
                if (px2 > bx1) bx1 = px2;
                if (py2 < by0) by0 = py2;
                if (py2 > by1) by1 = py2;
            }
            long lr = 0, lg = 0, lb = 0; int ln = 0;
            int ex0 = Math.Max(0, bx0 - 8), ey0 = Math.Max(0, by0 - 8);
            int ex1 = Math.Min(w - 1, bx1 + 8), ey1 = Math.Min(h - 1, by1 + 8);
            for (int yy = ey0; yy <= ey1; yy++)
                for (int xx = ex0; xx <= ex1; xx++)
                {
                    if (!bg[yy * w + xx]) continue;
                    int j2 = yy * stride + xx * 4;
                    lr += buf[j2 + 2]; lg += buf[j2 + 1]; lb += buf[j2];
                    ln++;
                }
            double lR = ln > 0 ? (double)lr / ln : refR;
            double lG = ln > 0 ? (double)lg / ln : refG;
            double lB = ln > 0 ? (double)lb / ln : refB;

            double dLoc = Math.Sqrt((ar - lR) * (ar - lR) + (ag - lG) * (ag - lG) + (ab - lB) * (ab - lB));
            // 还要够"中性"：背景是冷灰（B 略高于 R），皮肤偏暖（R 明显高于 B）
            bool neutral = Math.Abs(ar - ab) <= 7 && Math.Abs(ar - ag) <= 7;
            if (dLoc <= 16.0 && neutral && comp.Count <= 15000)
                foreach (int pix in comp) bg[pix] = true;
        }

        // ── 3. 写 alpha，边缘反混合去白边 ──
        for (int y = 0; y < h; y++)
        {
            int off = y * stride;
            for (int x = 0; x < w; x++)
            {
                int id = y * w + x;
                int i = off + x * 4;
                if (bg[id]) { buf[i + 3] = 0; continue; }

                bool edge = false;
                for (int dy = -1; dy <= 1 && !edge; dy++)
                    for (int dx = -1; dx <= 1; dx++)
                    {
                        int ax = x + dx, ay = y + dy;
                        if (ax < 0 || ay < 0 || ax >= w || ay >= h) continue;
                        if (bg[ay * w + ax]) { edge = true; break; }
                    }
                if (!edge) { buf[i + 3] = 255; continue; }

                long br = 0, bgc = 0, bb = 0; int bn = 0;
                for (int dy = -2; dy <= 2; dy++)
                    for (int dx = -2; dx <= 2; dx++)
                    {
                        int ax = x + dx, ay = y + dy;
                        if (ax < 0 || ay < 0 || ax >= w || ay >= h) continue;
                        if (!bg[ay * w + ax]) continue;
                        int j = ay * stride + ax * 4;
                        br += buf[j + 2]; bgc += buf[j + 1]; bb += buf[j];
                        bn++;
                    }
                if (bn == 0) { buf[i + 3] = 255; continue; }

                double Br = (double)br / bn, Bg = (double)bgc / bn, Bb = (double)bb / bn;
                double cr = buf[i + 2], cg = buf[i + 1], cb = buf[i];
                double dr = cr - Br, dg = cg - Bg, db = cb - Bb;
                double dist = Math.Sqrt(dr * dr + dg * dg + db * db);

                double lo = tol * 0.45, hi = tol * 2.0;
                double a = (dist - lo) / (hi - lo);
                if (a < 0) a = 0;
                if (a > 1) a = 1;
                if (a < 0.10) { buf[i + 3] = 0; continue; }

                double fr = (cr - (1 - a) * Br) / a;
                double fg = (cg - (1 - a) * Bg) / a;
                double fb = (cb - (1 - a) * Bb) / a;
                buf[i + 2] = (byte)Math.Max(0, Math.Min(255, (int)Math.Round(fr)));
                buf[i + 1] = (byte)Math.Max(0, Math.Min(255, (int)Math.Round(fg)));
                buf[i] = (byte)Math.Max(0, Math.Min(255, (int)Math.Round(fb)));
                buf[i + 3] = (byte)Math.Max(1, Math.Min(255, (int)Math.Round(a * 255)));
            }
        }

        System.Runtime.InteropServices.Marshal.Copy(buf, 0, data.Scan0, buf.Length);
        bmp.UnlockBits(data);
    }

    static void TryPush(byte[] buf, bool[] bg, Queue<int> q, int id, int w, int stride,
                        int lumaMin, int satMax)
    {
        if (id < 0 || id >= bg.Length || bg[id]) return;
        int y = id / w;
        int x = id - y * w;
        int i = y * stride + x * 4;
        if (i + 3 >= buf.Length) return;
        int r = buf[i + 2], g = buf[i + 1], b = buf[i];
        int mx = Math.Max(r, Math.Max(g, b));
        int mn = Math.Min(r, Math.Min(g, b));
        int luma = (r * 299 + g * 587 + b * 114) / 1000;
        if (luma >= lumaMin && (mx - mn) <= satMax) { bg[id] = true; q.Enqueue(id); }
    }

    static Rectangle AlphaBounds(Bitmap bmp, int threshold)
    {
        int w = bmp.Width, h = bmp.Height;
        var data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        int stride = data.Stride;
        byte[] buf = new byte[stride * h];
        System.Runtime.InteropServices.Marshal.Copy(data.Scan0, buf, 0, buf.Length);
        bmp.UnlockBits(data);
        int minX = w, minY = h, maxX = -1, maxY = -1;
        for (int y = 0; y < h; y++)
        {
            int off = y * stride;
            for (int x = 0; x < w; x++)
            {
                if (buf[off + x * 4 + 3] > threshold)
                {
                    if (x < minX) minX = x;
                    if (x > maxX) maxX = x;
                    if (y < minY) minY = y;
                    if (y > maxY) maxY = y;
                }
            }
        }
        if (maxX < minX) return Rectangle.Empty;
        return new Rectangle(minX, minY, maxX - minX + 1, maxY - minY + 1);
    }
}
