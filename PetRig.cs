using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

// ══════════════════════════════════════════════════════════════════
//  PetRig —— 多帧 + 弹簧的桌宠渲染器
//
//  · 多张同构图的动作帧（站/走/笑/睡/看），之间做交叉淡入，切换不突兀
//  · 所有运动参数都是弹簧，没有一帧是突变的
//  · 身体绕"脚底"旋转，重心有重量感（幅度只有 1~2 度）
//  · 眼睛快、头中、身体慢 —— 不同时间常数才像活物
// ══════════════════════════════════════════════════════════════════
public class PetRig : IDisposable
{
    Bitmap[] frames;
    public int FrameCount { get { return frames.Length; } }

    int curFrame, prevFrame;
    float fade;               // 0 = 完全是 prev，1 = 完全是 cur
    float fadeSpeed = 1f / 0.18f;

    public Bitmap Canvas;
    int outW, outH;

    // 当前值
    public float GazeX, GazeY, Lean, Lift, Squash, BodyRot, HeadRot, Turn;

    // 弹簧速度
    float vGazeX, vGazeY, vLean, vLift, vSquash, vBodyRot, vHeadRot, vTurn;

    // 目标值
    float tGazeX, tGazeY, tLean, tLift, tSquash, tBodyRot, tHeadRot, tTurn;

    // 响应速度：视线最快 → 头 → 身体最慢
    const float K_GAZE = 150f, C_GAZE = 24f;
    const float K_HEAD = 110f, C_HEAD = 20f;
    const float K_BODY = 65f, C_BODY = 14f;
    const float K_TURN = 230f, C_TURN = 26f;

    public PetRig(string[] framePaths, int outHeight, float supersample)
    {
        frames = new Bitmap[framePaths.Length];
        for (int i = 0; i < framePaths.Length; i++)
            frames[i] = new Bitmap(framePaths[i]);

        outH = Math.Max(8, outHeight);
        outW = Math.Max(8, (int)Math.Round(outH * (double)frames[0].Width / frames[0].Height));
        Canvas = new Bitmap((int)Math.Round(outW * supersample), (int)Math.Round(outH * supersample),
                            PixelFormat.Format32bppArgb);
        outW = Canvas.Width;
        outH = Canvas.Height;

        curFrame = 0; prevFrame = 0; fade = 1f;
        Turn = 1f; tTurn = 1f;
    }

    // 换帧：fadeSeconds 控制过渡时长（眨眼要快，状态切换要慢）
    public void SetFrame(int index, float fadeSeconds)
    {
        if (index < 0 || index >= frames.Length) return;
        if (index == curFrame) return;
        prevFrame = curFrame;
        curFrame = index;
        fade = 0f;
        fadeSpeed = 1f / Math.Max(0.03f, fadeSeconds);
    }

    public int CurrentFrame { get { return curFrame; } }

    public void SetTargets(float gazeX, float gazeY, float lean, float lift, float squash,
                           float bodyRot, float headRot, float turn)
    {
        tGazeX = Clamp(gazeX, -1f, 1f);
        tGazeY = Clamp(gazeY, -1f, 1f);
        tLean = Clamp(lean, -1f, 1f);
        tLift = Clamp(lift, -1f, 1f);
        tSquash = Clamp(squash, -1f, 1f);
        tBodyRot = Clamp(bodyRot, -3f, 3f);
        tHeadRot = Clamp(headRot, -2.5f, 2.5f);
        tTurn = Clamp(turn, -1f, 1f);
    }

    static float Clamp(float v, float a, float b) { return v < a ? a : (v > b ? b : v); }

    static void Spring(ref float x, ref float v, float target, float k, float c, float dt)
    {
        float acc = (target - x) * k - v * c;
        v += acc * dt;
        x += v * dt;
    }

    public void Step(float dt)
    {
        if (dt <= 0f) return;
        if (dt > 0.1f) dt = 0.1f;

        Spring(ref GazeX, ref vGazeX, tGazeX, K_GAZE, C_GAZE, dt);
        Spring(ref GazeY, ref vGazeY, tGazeY, K_GAZE, C_GAZE, dt);
        Spring(ref HeadRot, ref vHeadRot, tHeadRot, K_HEAD, C_HEAD, dt);
        Spring(ref Turn, ref vTurn, tTurn, K_TURN, C_TURN, dt);

        Spring(ref Lean, ref vLean, tLean, K_BODY, C_BODY, dt);
        Spring(ref Lift, ref vLift, tLift, K_BODY, C_BODY, dt);
        Spring(ref Squash, ref vSquash, tSquash, K_BODY, C_BODY, dt);
        Spring(ref BodyRot, ref vBodyRot, tBodyRot, K_BODY, C_BODY, dt);

        if (fade < 1f)
        {
            fade += fadeSpeed * dt;
            if (fade > 1f) fade = 1f;
        }
    }

    public Bitmap Render()
    {
        using (var g = Graphics.FromImage(Canvas))
        {
            g.Clear(Color.Transparent);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.CompositingQuality = CompositingQuality.HighQuality;

            float feetX = outW * 0.5f;
            float feetY = outH * 0.985f;

            // 变换顺序很关键：先把"脚底中心"移到原点，再缩放/旋转，最后放到目标位置。
            // 如果先平移再缩放，负的 X 缩放会把角色镜像到画布外面（朝左走时就会整个消失）。
            float sx = Turn;
            if (Math.Abs(sx) < 0.06f) sx = (sx < 0 ? -0.06f : 0.06f);
            var m = new Matrix();
            m.Translate(-outW * 0.5f, -outH, MatrixOrder.Append);
            m.Scale(sx, 1f + Squash * 0.05f, MatrixOrder.Append);
            m.Rotate(BodyRot + HeadRot * 0.35f + Lean * 0.7f, MatrixOrder.Append);
            m.Translate(feetX + Lean * (outW * 0.026f), feetY + Lift * (outH * 0.011f), MatrixOrder.Append);
            g.Transform = m;

            var dest = new Rectangle(0, 0, outW, outH);
            if (fade < 0.999f && prevFrame != curFrame)
            {
                DrawWithAlpha(g, frames[prevFrame], dest, 1f - fade);
                DrawWithAlpha(g, frames[curFrame], dest, fade);
            }
            else
            {
                g.DrawImage(frames[curFrame], dest);
            }

            g.ResetTransform();
        }
        return Canvas;
    }

    static void DrawWithAlpha(Graphics g, Bitmap bmp, Rectangle dest, float alpha)
    {
        if (alpha <= 0.004f) return;
        if (alpha > 0.996f) { g.DrawImage(bmp, dest); return; }
        var cm = new ColorMatrix();
        cm.Matrix33 = alpha;
        using (var ia = new ImageAttributes())
        {
            ia.SetColorMatrix(cm, ColorMatrixFlag.Default, ColorAdjustType.Bitmap);
            g.DrawImage(bmp, dest, 0, 0, bmp.Width, bmp.Height, GraphicsUnit.Pixel, ia);
        }
    }

    public void Dispose()
    {
        if (frames != null)
        {
            foreach (var f in frames) if (f != null) f.Dispose();
            frames = null;
        }
        if (Canvas != null) { Canvas.Dispose(); Canvas = null; }
    }
}
