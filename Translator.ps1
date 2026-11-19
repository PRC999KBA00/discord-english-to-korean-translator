param([switch]$SelfTest, [switch]$SmokeTest, [switch]$LiveTest)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Runtime.WindowsRuntime, System.Net.Http
[Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType=WindowsRuntime] | Out-Null
[Windows.Graphics.Imaging.SoftwareBitmap, Windows.Foundation, ContentType=WindowsRuntime] | Out-Null
[Windows.Globalization.Language, Windows.Foundation, ContentType=WindowsRuntime] | Out-Null
Add-Type -ReferencedAssemblies System.Drawing,System.Windows.Forms @"
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Diagnostics;
using System.Threading;
using Microsoft.Win32.SafeHandles;
using System.Windows.Forms;

public sealed class MirrorView : Panel {
    public sealed class Line {
        public string Source;
        public string Key;
        public Rectangle Box;
        public long Pixels;
    }

    public Bitmap Frame;
    public Line[] Lines = new Line[0];
    public readonly Dictionary<string, string> Translations = new Dictionary<string, string>(StringComparer.Ordinal);
    public bool ShowTranslations = true;
    public bool OverlayOnly;
    private sealed class Glyph : IDisposable {
        public readonly GraphicsPath Path = new GraphicsPath();
        public float Width;
        public float Height;
        public void Dispose() { Path.Dispose(); }
    }

    private readonly Dictionary<Tuple<string, float, float>, Glyph> glyphs =
        new Dictionary<Tuple<string, float, float>, Glyph>();
    private readonly FontFamily font = new FontFamily("Malgun Gothic");
    private readonly Pen outline = new Pen(Color.FromArgb(245, 14, 15, 19), 2.4f);
    private readonly Brush backdrop = new SolidBrush(Color.FromArgb(28, 30, 35));

    private Glyph GetGlyph(string translated, float height, float available) {
        Tuple<string, float, float> key = Tuple.Create(translated, height, available);
        Glyph result;
        if (glyphs.TryGetValue(key, out result)) return result;
        if (glyphs.Count >= 512) ClearGlyphs();
        translated = translated.Replace((char)10, ' ').Replace(((char)13).ToString(), "");
        result = new Glyph();
        result.Path.AddString(translated, font, (int)FontStyle.Bold, height, PointF.Empty, StringFormat.GenericTypographic);
        RectangleF bounds = result.Path.GetBounds();
        if (bounds.Width > 0 && bounds.Height > 0) {
            float fit = Math.Min(1, available / bounds.Width);
            using (Matrix transform = new Matrix()) {
                transform.Scale(fit, fit);
                transform.Translate(-bounds.Left, -bounds.Top);
                result.Path.Transform(transform);
            }
            result.Width = bounds.Width * fit;
            result.Height = bounds.Height * fit;
        }
        glyphs.Add(key, result);
        return result;
    }

    private void ClearGlyphs() {
        foreach (Glyph glyph in glyphs.Values) glyph.Dispose();
        glyphs.Clear();
    }

    private Bitmap spareFrame;

    public void CaptureFrame(Rectangle region) {
        Bitmap next = spareFrame;
        spareFrame = null;
        if (next == null || next.Size != region.Size) {
            if (next != null) next.Dispose();
            next = new Bitmap(region.Width, region.Height, PixelFormat.Format32bppRgb);
        }
        try {
            using (Graphics capture = Graphics.FromImage(next)) {
                capture.CopyFromScreen(region.Location, Point.Empty, region.Size);
            }
            if (Frame != null) {
                Line[] tracked = FollowLines(Frame, next, Lines);
                bool moved = tracked.Length != Lines.Length;
                for (int i = 0; !moved && i < tracked.Length; i++) moved = tracked[i] != Lines[i];
                Lines = tracked;
                if (moved) Invalidate();
            }
            spareFrame = Frame;
            Frame = next;
            next = null;
        } finally {
            if (next != null) next.Dispose();
        }
    }

    private sealed class PixelMap : IDisposable {
        private readonly Bitmap bitmap;
        private readonly BitmapData data;
        public int Width { get { return bitmap.Width; } }
        public int Height { get { return bitmap.Height; } }
        public Size Size { get { return bitmap.Size; } }

        public PixelMap(Bitmap source) {
            bitmap = source;
            data = source.LockBits(new Rectangle(Point.Empty, source.Size), ImageLockMode.ReadOnly, source.PixelFormat);
        }

        public int Rgb(int x, int y) {
            return Marshal.ReadInt32(data.Scan0, y * data.Stride + x * 4) & 0x00ffffff;
        }

        public void Dispose() { bitmap.UnlockBits(data); }
    }

    public MirrorView() {
        outline.LineJoin = LineJoin.Round;
        DoubleBuffered = true;
        ResizeRedraw = true;
        BackColor = Color.FromArgb(30, 31, 35);
    }

    public void UpdateFrame(Bitmap frame) {
        Bitmap previous = Frame;
        if (previous != null && frame != null) {
            Lines = FollowLines(previous, frame, Lines);
        }
        Frame = frame;
        if (previous != null) previous.Dispose();
        Invalidate();
    }

    public void MergeRecognizedLines(Bitmap recognizedFrame, Line[] recognized) {
        if (Frame == null) return;
        List<Line> merged = new List<Line>(Lines);
        foreach (Line line in FollowLines(recognizedFrame, Frame, recognized)) {
            int existing = merged.FindIndex(delegate(Line item) {
                Rectangle overlap = Rectangle.Intersect(item.Box, line.Box);
                return overlap.Height * 2 >= Math.Min(item.Box.Height, line.Box.Height) &&
                    overlap.Width * 2 >= Math.Min(item.Box.Width, line.Box.Width);
            });
            if (existing < 0) merged.Add(line);
            else if (!Translations.ContainsKey(merged[existing].Key) && Translations.ContainsKey(line.Key)) {
                merged[existing] = line;
            }
        }
        merged.Sort(delegate(Line first, Line second) { return first.Box.Top.CompareTo(second.Box.Top); });
        Lines = merged.ToArray();
        Invalidate();
    }

    public static Line[] FollowLines(Bitmap previous, Bitmap current, Line[] lines) {
        if (lines.Length == 0 || previous.Size != current.Size) return new Line[0];
        if (Object.ReferenceEquals(previous, current)) return lines;
        using (PixelMap before = new PixelMap(previous))
        using (PixelMap after = new PixelMap(current)) {
            return FollowPixels(before, after, lines);
        }
    }

    private static Line[] FollowPixels(PixelMap previous, PixelMap current, Line[] lines) {
        bool[] stationary = new bool[lines.Length];
        int motion = 0;
        int attempts = 0;
        for (int i = 0; i < lines.Length; i++) {
            Rectangle box = lines[i].Box;
            bool fullyVisible = box.Left >= 0 && box.Right <= current.Width && box.Top >= 0 && box.Bottom <= current.Height;
            stationary[i] = fullyVisible ? Fingerprint(current, box) == lines[i].Pixels : Matches(previous, current, box, 0);
            if (!stationary[i] && motion == 0 && attempts < 3 &&
                box.Width >= 18 && Math.Min(previous.Height, box.Bottom) - Math.Max(0, box.Top) >= 7) {
                attempts++;
                motion = FindVerticalMotion(previous, current, box);
            }
        }

        List<Line> tracked = new List<Line>(lines.Length);
        for (int i = 0; i < lines.Length; i++) {
            Line line = lines[i];
            if (stationary[i]) {
                tracked.Add(line);
            } else if (motion != 0 && Matches(previous, current, line.Box, motion)) {
                Rectangle moved = line.Box;
                moved.Offset(0, motion);
                tracked.Add(new Line { Source = line.Source, Key = line.Key, Box = moved, Pixels = line.Pixels });
            }
        }
        return tracked.ToArray();
    }

    private static int FindVerticalMotion(PixelMap previous, PixelMap current, Rectangle box) {
        List<Point> probes = new List<Point>();
        Rectangle visible = Rectangle.Intersect(new Rectangle(Point.Empty, previous.Size), box);
        if (visible.Width < 18 || visible.Height < 7) return 0;
        int background = previous.Rgb(visible.Left, visible.Top);
        for (int upper = 0; upper < 3; upper++) {
            for (int segment = 0; segment < 4; segment++) {
                int left = visible.Left + visible.Width * segment / 4;
                int right = visible.Left + visible.Width * (segment + 1) / 4;
                int top = visible.Top + visible.Height * upper / 3;
                int bottom = visible.Top + visible.Height * (upper + 1) / 3;
                for (int y = top; y < bottom; y++) {
                    bool found = false;
                    for (int x = left; x < right; x++) {
                        if (previous.Rgb(x, y) == background) continue;
                        probes.Add(new Point(x, y));
                        found = true;
                        break;
                    }
                    if (found) break;
                }
            }
        }
        if (probes.Count < 4) return 0;
        int[] colors = new int[probes.Count];
        for (int i = 0; i < colors.Length; i++) colors[i] = previous.Rgb(probes[i].X, probes[i].Y);

        int limit = current.Height - 5;
        for (int distance = 1; distance <= limit; distance++) {
            if (MatchesProbes(previous, current, box, probes, colors, -distance)) return -distance;
            if (MatchesProbes(previous, current, box, probes, colors, distance)) return distance;
        }
        return 0;
    }

    private static bool MatchesProbes(PixelMap previous, PixelMap current, Rectangle box, List<Point> probes, int[] colors, int offset) {
        int matched = 0;
        for (int i = 0; i < probes.Count; i++) {
            int y = probes[i].Y + offset;
            if (y < 0 || y >= current.Height) continue;
            if (current.Rgb(probes[i].X, y) != colors[i]) return false;
            matched++;
        }
        return matched >= 4 && Matches(previous, current, box, offset);
    }

    private static bool Matches(PixelMap previous, PixelMap current, Rectangle box, int offset) {
        if (box.Left < 0 || box.Right > previous.Width) return false;
        int top = Math.Max(box.Top, Math.Max(0, -offset));
        int bottom = Math.Min(box.Bottom, Math.Min(previous.Height, current.Height - offset));
        if (bottom - top < Math.Min(5, box.Height)) return false;
        Rectangle oldArea = Rectangle.FromLTRB(box.Left, top, box.Right, bottom);
        Rectangle newArea = oldArea;
        newArea.Offset(0, offset);
        return Fingerprint(previous, oldArea) == Fingerprint(current, newArea);
    }

    public static long Fingerprint(Bitmap frame, Rectangle bounds) {
        using (PixelMap pixels = new PixelMap(frame)) return Fingerprint(pixels, bounds);
    }

    private static long Fingerprint(PixelMap frame, Rectangle bounds) {
        Rectangle area = Rectangle.Intersect(new Rectangle(Point.Empty, frame.Size), bounds);
        if (area.Width == 0 || area.Height == 0) return 0;
        unchecked {
            long hash = 17;
            for (int y = area.Top; y < area.Bottom; y += 2)
                for (int x = area.Left; x < area.Right; x += 3)
                    hash = hash * 31 + frame.Rgb(x, y);
            return hash;
        }
    }

    protected override void OnPaint(PaintEventArgs args) {
        base.OnPaint(args);
        if (Frame == null || ClientSize.Width < 1 || ClientSize.Height < 1) return;
        Graphics graphics = args.Graphics;
        float scale = Math.Min((float)ClientSize.Width / Frame.Width, (float)ClientSize.Height / Frame.Height);
        float left = (ClientSize.Width - Frame.Width * scale) / 2;
        float top = (ClientSize.Height - Frame.Height * scale) / 2;
        graphics.InterpolationMode = InterpolationMode.HighQualityBilinear;
        if (!OverlayOnly) graphics.DrawImage(Frame, new RectangleF(left, top, Frame.Width * scale, Frame.Height * scale));
        if (!ShowTranslations) return;

        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        foreach (Line line in Lines) {
            string translated;
            if (!Translations.TryGetValue(line.Key, out translated) || translated == line.Source) continue;
            float x = left + line.Box.Left * scale;
            float y = top + line.Box.Top * scale;
            float height = Math.Max(9, line.Box.Height * scale);
            float available = left + Frame.Width * scale - x - 3;
            if (available < 6) continue;
            Glyph glyph = GetGlyph(translated, height, available);
            if (glyph.Width == 0 || glyph.Height == 0) continue;
            float width = Math.Min(available, Math.Max(line.Box.Width * scale, glyph.Width) + 2);
            graphics.FillRectangle(backdrop, x - 1, y - 1, width + 2, height + 2);
            GraphicsState transform = graphics.Save();
            graphics.TranslateTransform(x, y + (height - glyph.Height) / 2);
            graphics.DrawPath(outline, glyph.Path);
            graphics.FillPath(Brushes.White, glyph.Path);
            graphics.Restore(transform);
        }
    }

    protected override void Dispose(bool disposing) {
        if (disposing && Frame != null) { Frame.Dispose(); Frame = null; }
        if (disposing && spareFrame != null) { spareFrame.Dispose(); spareFrame = null; }
        if (disposing) {
            ClearGlyphs();
            font.Dispose();
            outline.Dispose();
            backdrop.Dispose();
        }
        base.Dispose(disposing);
    }
}

public sealed class FrameTimer : IDisposable {
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern SafeWaitHandle CreateWaitableTimerEx(IntPtr attributes, string name, uint flags, uint access);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetWaitableTimer(SafeWaitHandle timer, ref long due, int period,
        IntPtr completion, IntPtr argument, bool resume);

    private sealed class Loop {
        public readonly ManualResetEvent Stop = new ManualResetEvent(false);
        public Thread Thread;
        public int Posted;
    }

    private readonly Control target;
    private readonly System.Windows.Forms.Timer fallback = new System.Windows.Forms.Timer();
    private Loop active;
    public event EventHandler Tick;

    public FrameTimer(Control target) {
        this.target = target;
        fallback.Interval = 15;
        fallback.Tick += delegate { RaiseTick(); };
    }

    public void Start() {
        if (active != null || fallback.Enabled) return;
        SafeWaitHandle handle = CreateWaitableTimerEx(IntPtr.Zero, null, 2, 0x001f0003);
        if (handle.IsInvalid) {
            handle.Dispose();
            fallback.Start();
            return;
        }
        Loop loop = new Loop();
        active = loop;
        loop.Thread = new Thread(delegate() { Run(loop, handle); });
        loop.Thread.IsBackground = true;
        loop.Thread.Start();
    }

    private void Run(Loop loop, SafeWaitHandle handle) {
        using (EventWaitHandle alarm = new EventWaitHandle(false, EventResetMode.AutoReset)) {
            alarm.SafeWaitHandle = handle;
            WaitHandle[] signals = new WaitHandle[] { loop.Stop, alarm };
            Stopwatch watch = Stopwatch.StartNew();
            double next = 0;
            const double step = 1.0 / 60;
            while (true) {
                double elapsed = watch.Elapsed.TotalSeconds;
                next += step;
                if (next <= elapsed) next = (Math.Floor(elapsed / step) + 1) * step;
                long due = -Math.Max(1, (long)((next - elapsed) * 10000000));
                if (!SetWaitableTimer(handle, ref due, 0, IntPtr.Zero, IntPtr.Zero, false)) break;
                if (WaitHandle.WaitAny(signals) == 0) break;

                if (Interlocked.Exchange(ref loop.Posted, 1) != 0) continue;
                try {
                    target.BeginInvoke((MethodInvoker)delegate {
                        Interlocked.Exchange(ref loop.Posted, 0);
                        if (active == loop) RaiseTick();
                    });
                } catch (InvalidOperationException) {
                    break;
                }
            }
        }
    }

    private void RaiseTick() {
        EventHandler callback = Tick;
        if (callback != null) callback(this, EventArgs.Empty);
    }

    public void Stop() {
        fallback.Stop();
        Loop loop = active;
        active = null;
        if (loop == null) return;
        loop.Stop.Set();
        loop.Thread.Join();
        loop.Stop.Dispose();
    }

    public void Dispose() {
        Stop();
        fallback.Dispose();
    }
}

public sealed class TranslationOverlay : Form {
    public static readonly Color ClearColor = Color.Magenta;

    public TranslationOverlay() {
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        AutoScaleMode = AutoScaleMode.None;
        TopMost = true;
        BackColor = ClearColor;
        TransparencyKey = ClearColor;
    }

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SetWindowDisplayAffinity(IntPtr window, uint affinity);
    public bool CaptureExcluded;
    protected override void OnShown(EventArgs args) {
        base.OnShown(args);
        CaptureExcluded = SetWindowDisplayAffinity(Handle, 0x11);
    }

    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get {
            CreateParams p = base.CreateParams;
            p.ExStyle |= 0x08000000 | 0x00000020 | 0x00000080;
            return p;
        }
    }

    protected override void WndProc(ref Message message) {
        if (message.Msg == 0x0084) {
            message.Result = new IntPtr(-1);
            return;
        }
        base.WndProc(ref message);
    }
}

public static class ScreenReaderNative {
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point point);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    public static IntPtr RootAt(int x, int y) {
        return GetAncestor(WindowFromPoint(new Point(x, y)), 2);
    }

    public static bool SourceVisible(Rectangle area, IntPtr source) {
        if (source == IntPtr.Zero) return false;
        for (int column = 1; column <= 3; column++)
            for (int row = 1; row <= 3; row++)
                if (RootAt(area.Left + area.Width * column / 4, area.Top + area.Height * row / 4) != source)
                    return false;
        return true;
    }

    public static void DragWindow(IntPtr window) {
        ReleaseCapture();
        SendMessage(window, 0x00A1, new IntPtr(2), IntPtr.Zero);
    }
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
try {
    [void][ScreenReaderNative]::SetProcessDpiAwarenessContext([IntPtr](-4))
} catch {
    [void][ScreenReaderNative]::SetProcessDPIAware()
}

$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and
    $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq ('IAsyncOperation' + [char]96 + '1')
} | Select-Object -First 1
$ocrTaskMethod = $asTask.MakeGenericMethod([Windows.Media.Ocr.OcrResult, Windows.Foundation, ContentType=WindowsRuntime])
$model = 'translategemma:4b'
$fastModel = 'hf.co/tencent/HY-MT1.5-1.8B-GGUF:Q4_K_M'
$fastLanguages = 'zh en fr pt es ja tr ru ar th it de vi ms id tl hi pl cs nl km my fa gu ur te mr he bn ta uk bo kk mn ug yue' -split ' '
$handler = [Net.Http.HttpClientHandler]::new()
$handler.UseProxy = $false
$handler.AllowAutoRedirect = $false
$http = [Net.Http.HttpClient]::new($handler)
$http.Timeout = [TimeSpan]::FromSeconds(90)

function New-OcrInput([Drawing.Bitmap]$image) {
    $area = [Drawing.Rectangle]::new(0, 0, $image.Width, $image.Height)
    $pixels = $image.LockBits($area, 'ReadOnly', 'Format32bppRgb')
    try {
        $bytes = [byte[]]::new($pixels.Stride * $pixels.Height)
        [Runtime.InteropServices.Marshal]::Copy($pixels.Scan0, $bytes, 0, $bytes.Length)
    } finally {
        $image.UnlockBits($pixels)
    }

    $buffer = [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions]::AsBuffer($bytes)
    $softwareBitmap = [Windows.Graphics.Imaging.SoftwareBitmap]::new('Bgra8', $image.Width, $image.Height, 'Ignore')
    try {
        $softwareBitmap.CopyFromBuffer($buffer)
        return $softwareBitmap
    } catch {
        $softwareBitmap.Dispose()
        throw
    }
}

function Start-Ocr($engine, $inputImage) {
    $operation = $engine.RecognizeAsync($inputImage)
    return $ocrTaskMethod.Invoke($null, @($operation))
}

function Get-LineKey([string]$text) {
    $text = $text.Normalize([Text.NormalizationForm]::FormKC)
    $text = $text -replace '[\u2018\u2019]', "'" -replace '[\u201c\u201d]', '"' -replace '[\u2010\u2011\u2013]', '-'
    return ($text -replace '(?<=\S)\s+(?=[,.;:!?])|(?<=\p{L})\s+(?=\x27)|(?<=\x27)\s+(?=\p{L})', '' -replace '\s+', ' ').Trim()
}

function Get-LineImageKey($line) {
    return "$($line.Box.Width):$($line.Box.Height):$($line.Pixels)"
}

function Get-MirrorLines($result, [Drawing.Bitmap]$frame) {
    foreach ($line in $result.Lines) {
        $value = $line.Text.Trim()
        if ($value -notmatch '\p{L}') { continue }
        $bounds = [Drawing.Rectangle]::Empty
        foreach ($word in $line.Words) {
            $rect = $word.BoundingRect
            $part = [Drawing.Rectangle]::FromLTRB([Math]::Floor($rect.X), [Math]::Floor($rect.Y),
                [Math]::Ceiling($rect.X + $rect.Width), [Math]::Ceiling($rect.Y + $rect.Height))
            if ($bounds.IsEmpty) { $bounds = $part } else { $bounds = [Drawing.Rectangle]::Union($bounds, $part) }
        }
        if ($bounds.IsEmpty -or $bounds.Top -le 1 -or $bounds.Bottom -ge $frame.Height - 1) { continue }
        $mark = New-Object MirrorView+Line
        $mark.Source = $value
        $mark.Key = Get-LineKey $value
        $mark.Box = $bounds
        $mark.Pixels = [MirrorView]::Fingerprint($frame, $bounds)
        $mark
    }
}

function New-TranslationRequest($language, [string[]]$lines, [string]$backend = $model) {
    $line = $lines[0]
    if ($lines.Count -gt 1) {
        $numbered = for ($i = 0; $i -lt $lines.Count; $i++) { '{0}. {1}' -f ($i + 1), $lines[$i] }
        $line = $numbered -join [char]10
    }
    if ($backend -eq $fastModel) {
        $separator = [string][char]10 + [char]10
        if ($language.LanguageTag -like 'zh*') {
            $instruction = '将以下文本翻译为韩语，注意只需要输出翻译后的结果，不要额外解释：'
        } else {
            $instruction = 'Translate the following segment into Korean, without additional explanation.'
        }
        $fastJson = @{
            model = $backend
            prompt = "<｜hy_begin▁of▁sentence｜><｜hy_User｜>$instruction$separator$line<｜hy_Assistant｜>"
            raw = $true
            stream = $false
            keep_alive = '30m'
            options = @{ temperature = 0; num_ctx = 1024; num_predict = 384 }
        } | ConvertTo-Json -Depth 5 -Compress
        $request = [Net.Http.HttpRequestMessage]::new(
            [Net.Http.HttpMethod]::Post, 'http://127.0.0.1:11434/api/generate')
        $request.Content = [Net.Http.StringContent]::new($fastJson, [Text.Encoding]::UTF8, 'application/json')
        return $request
    }
    $source = $language.EnglishDisplayName
    $code = $language.LanguageTag
    $prompt = "You are a professional $source ($code) to Korean (ko) translator. Your goal is to accurately convey the meaning and nuances of the original $source text while adhering to Korean grammar, vocabulary, and cultural sensitivities."
    $prompt += "`nProduce only the Korean translation, without any additional explanations or commentary. Please translate the following $source text into Korean:`n`n`n$line"
    if ($lines.Count -gt 1) {
        $formatNote = 'Translate each numbered line independently. Preserve the same line numbers and order, with one translated line per input line.'
        $prompt = $prompt.Replace('Produce only the Korean translation', "$formatNote Produce only the Korean translation")
    }
    $json = @{
        model = $model
        messages = @(@{ role = 'user'; content = $prompt })
        stream = $false
        keep_alive = '30m'
        options = @{ temperature = 0; num_ctx = 2048; num_predict = 384 }
    } | ConvertTo-Json -Depth 5 -Compress
    $request = [Net.Http.HttpRequestMessage]::new(
        [Net.Http.HttpMethod]::Post, 'http://127.0.0.1:11434/api/chat')
    $request.Content = [Net.Http.StringContent]::new($json, [Text.Encoding]::UTF8, 'application/json')
    return $request
}

function Get-Translation([string]$json) {
    $result = ConvertFrom-Json -InputObject $json
    $content = if ($result.message) { $result.message.content } else { $result.response }
    if (!$result.done -or $result.done_reason -eq 'length' -or $content -isnot [string] -or !$content.Trim()) {
        throw '번역이 비어 있거나 도중에 잘렸습니다.'
    }
    return $content.Trim()
}

function Get-NumberedTranslations([string]$content, [int]$count) {
    if ($count -eq 1) { return $content }
    $items = @($content -split '\r?\n' | Where-Object { $_.Trim() })
    if ($items.Count -ne $count) { return }
    $texts = [Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $count; $i++) {
        if ($items[$i] -notmatch '^\s*(\d+)[.)]\s+(.+)$' -or [int]$Matches[1] -ne $i + 1) { return }
        $texts.Add($Matches[2].Trim())
    }
    return $texts.ToArray()
}

$languages = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages)
if ($SelfTest -or $LiveTest) {
    if (!$languages.Count) { throw 'Windows OCR 언어가 설치되어 있지 않습니다.' }
    $english = [Windows.Globalization.Language]::new('en-US')
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($english)
    if (!$engine) { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($languages[0]) }
    $bitmap = [Drawing.Bitmap]::new(620, 100, 'Format32bppRgb')
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $font = [Drawing.Font]::new('Segoe UI', 24)
    try {
        $graphics.Clear([Drawing.Color]::FromArgb(37, 39, 43))
        $graphics.DrawString('Hello from Discord!', $font, [Drawing.Brushes]::White, 10, 10)
        $inputImage = New-OcrInput $bitmap
        $task = Start-Ocr $engine $inputImage
        if (!$task.Wait(10000)) { throw 'OCR timed out' }

        $marks = @(Get-MirrorLines $task.Result $bitmap)
        if ($marks.Count -ne 1 -or $marks[0].Box.IsEmpty -or
            $marks[0].Pixels -ne [MirrorView]::Fingerprint($bitmap, $marks[0].Box)) {
            throw 'Missing or invalid OCR line bounds'
        }
        if ($marks.Source -cnotcontains 'Hello from Discord!') { throw "Unexpected OCR: $($marks.Source)" }
        $request = New-TranslationRequest $english $marks[0].Source
        $payload = $request.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        if ($request.RequestUri.Host -ne '127.0.0.1' -or $request.RequestUri.AbsolutePath -ne '/api/chat' -or
            $payload.model -ne $model -or $payload.stream -ne $false -or
            !$payload.messages[0].content.EndsWith("`n`n`n$($marks[0].Source)")) { throw 'Invalid request' }
        $result = Get-Translation '{"done":true,"message":{"content":"안녕하세요!"}}'
        if ($result -ne '안녕하세요!') { throw 'Invalid response' }
        $view = [MirrorView]::new()
        $view.Size = $bitmap.Size
        $view.UpdateFrame([Drawing.Bitmap]$bitmap.Clone())
        $view.Lines = $marks
        $view.Translations[$marks[0].Key] = $result
        $rendered = [Drawing.Bitmap]::new($bitmap.Width, $bitmap.Height)
        try {
            $view.DrawToBitmap($rendered, [Drawing.Rectangle]::new([Drawing.Point]::Empty, $bitmap.Size))
            if ([MirrorView]::Fingerprint($rendered, $marks[0].Box) -eq $marks[0].Pixels) {
                throw 'Translation overlay did not render over the detected line'
            }
            $view.ShowTranslations = $false
            $view.DrawToBitmap($rendered, [Drawing.Rectangle]::new([Drawing.Point]::Empty, $bitmap.Size))
            if ([MirrorView]::Fingerprint($rendered, $marks[0].Box) -ne $marks[0].Pixels) {
                throw 'Original-only mode changed the detected line'
            }
        } finally {
            $rendered.Dispose()
            $view.Dispose()
        }
        if ((Get-LineKey ('We' + [char]0x2019 + 're   ready !')) -cne (Get-LineKey "We're ready!") -or
            (Get-LineKey 'Room 11') -ceq (Get-LineKey 'Room 12')) { throw 'Invalid cache key' }
        $scrolled = [Drawing.Bitmap]::new($bitmap.Width, $bitmap.Height)
        $scrollGraphics = [Drawing.Graphics]::FromImage($scrolled)
        try {
            $scrollGraphics.DrawImageUnscaled($bitmap, 0, 24)
            $repositioned = New-Object MirrorView+Line
            $repositioned.Box = $marks[0].Box
            $repositioned.Box = [Drawing.Rectangle]::new($repositioned.Box.X, ($repositioned.Box.Y + 24),
                $repositioned.Box.Width, $repositioned.Box.Height)
            $repositioned.Pixels = [MirrorView]::Fingerprint($scrolled, $repositioned.Box)
            if ((Get-LineImageKey $repositioned) -cne (Get-LineImageKey $marks[0])) {
                throw 'Scrolling changed the image cache key'
            }
            $tracked = @([MirrorView]::FollowLines($bitmap, $scrolled, $marks))
            if ($tracked.Count -ne 1 -or $tracked[0].Box -ne $repositioned.Box -or $tracked[0].Key -cne $marks[0].Key) {
                throw 'Translation failed to follow a scroll without OCR'
            }
            $followView = [MirrorView]::new()
            try {
                $followView.UpdateFrame([Drawing.Bitmap]$bitmap.Clone())
                $followView.Lines = $marks
                $followView.UpdateFrame([Drawing.Bitmap]$scrolled.Clone())
                $followView.MergeRecognizedLines($bitmap, $marks)
                if ($followView.Lines.Length -ne 1 -or $followView.Lines[0].Box -ne $repositioned.Box) {
                    throw 'An older OCR frame displaced the tracked translation'
                }
                $scrollGraphics.Clear([Drawing.Color]::Black)
                $followView.UpdateFrame([Drawing.Bitmap]$scrolled.Clone())
                if ($followView.Lines.Length -ne 0) { throw 'Tracking kept a line after it disappeared' }
            } finally {
                $followView.Dispose()
            }
        } finally {
            $scrollGraphics.Dispose()
            $scrolled.Dispose()
        }
        $parsed = @(Get-NumberedTranslations ("1. 첫 번째" + [char]10 + "2. 두 번째") 2)
        if ($parsed.Count -ne 2 -or $parsed[1] -ne '두 번째' -or
            @(Get-NumberedTranslations ("2. 두 번째" + [char]10 + "1. 첫 번째") 2).Count -ne 0) {
            throw 'Invalid batch parser'
        }
        'PASS: OCR positions, overlay, frame-to-frame scroll tracking, and batch validation'
        if ($LiveTest) {
            $response = $http.SendAsync($request).GetAwaiter().GetResult()
            try {
                [void]$response.EnsureSuccessStatusCode()
                $liveResult = Get-Translation ($response.Content.ReadAsStringAsync().GetAwaiter().GetResult())
                if ($liveResult -notmatch '[가-힣]') { throw "Expected Korean translation: $liveResult" }
                "PASS: live local translation: $liveResult"
            } finally {
                $response.Dispose()
            }
            $samples = @(
                'See you in the next match!',
                'The server will restart in five minutes.',
                'Can you send me the antenna measurements?',
                'I left the spare tools on the workbench.'
            )
            foreach ($backend in @($model, $fastModel)) {
                $totals = [Collections.Generic.List[long]]::new()
                $firstLines = [Collections.Generic.List[long]]::new()
                foreach ($run in 0..3) {
                    $elapsed = [Diagnostics.Stopwatch]::StartNew()
                    $texts = [Collections.Generic.List[string]]::new()
                    $firstLine = 0
                    foreach ($sample in $samples) {
                        $translation = New-TranslationRequest $english $sample $backend
                        try {
                            $answer = $http.SendAsync($translation).GetAwaiter().GetResult()
                            try {
                                [void]$answer.EnsureSuccessStatusCode()
                                $text = Get-Translation ($answer.Content.ReadAsStringAsync().GetAwaiter().GetResult())
                                if ($text -notmatch '[가-힣]') { throw "Unexpected translation ($backend): $text" }
                                $texts.Add($text)
                                if ($texts.Count -eq 1) { $firstLine = $elapsed.ElapsedMilliseconds }
                            } finally { $answer.Dispose() }
                        } finally { $translation.Dispose() }
                    }
                    if ($run -gt 0) {
                        $totals.Add($elapsed.ElapsedMilliseconds)
                        $firstLines.Add($firstLine)
                    }
                }
                "PASS: $backend median first line $(@($firstLines | Sort-Object)[1]) ms, four lines $(@($totals | Sort-Object)[1]) ms"
                $texts
            }
        }
    } finally {
        if ($request) { $request.Dispose() }
        if ($inputImage) { $inputImage.Dispose() }
        $font.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
        $http.Dispose()
    }
    exit
}

[Windows.Forms.Application]::EnableVisualStyles()
$form = [Windows.Forms.Form]::new()
$form.Text = '디스코드 화면 번역'
$form.FormBorderStyle = 'None'
$form.StartPosition = 'Manual'
$form.ClientSize = [Drawing.Size]::new(1010, 46)
$form.BackColor = [Drawing.Color]::FromArgb(35, 36, 41)
$form.ForeColor = [Drawing.Color]::FromArgb(235, 235, 241)
$form.KeyPreview = $true
$form.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $form.Close() } })

$form.Font = [Drawing.Font]::new('Malgun Gothic', 10)
$form.TopMost = $true

$toolbar = [Windows.Forms.FlowLayoutPanel]::new()
$toolbar.Dock = 'Fill'
$toolbar.WrapContents = $false
$toolbar.Padding = [Windows.Forms.Padding]::new(8, 6, 8, 0)
$form.Controls.Add($toolbar)

function Position-Toolbar([Windows.Forms.Screen]$screen) {
    $work = $screen.WorkingArea
    $width = [Math]::Min(1010, $work.Width)
    $form.ClientSize = [Drawing.Size]::new($width, 46)
    $form.Location = [Drawing.Point]::new($work.Left + [int][Math]::Floor(($work.Width - $width) / 2), $work.Top + 4)
}

function Add-ToolbarControl($control, [string]$caption, [int]$width) {
    $control.Text = $caption
    $control.Width = $width
    $control.Height = 29
    $control.Margin = [Windows.Forms.Padding]::new(3)
    if ($control -is [Windows.Forms.Button]) {
        $control.FlatStyle = 'Flat'
        $control.FlatAppearance.BorderSize = 0
        $control.BackColor = [Drawing.Color]::FromArgb(61, 63, 74)
    }
    if ($control -is [Windows.Forms.Label]) { $control.TextAlign = 'MiddleLeft' }
    $toolbar.Controls.Add($control)
}

$title = [Windows.Forms.Label]::new()
$title.Font = [Drawing.Font]::new('Malgun Gothic', 10, [Drawing.FontStyle]::Bold)
$title.Add_MouseDown({ if ($_.Button -eq 'Left') { [ScreenReaderNative]::DragWindow($form.Handle) } })
Add-ToolbarControl $title '디스코드 번역' 102
$languageBox = [Windows.Forms.ComboBox]::new()
$languageBox.DropDownStyle = 'DropDownList'
$languageBox.FlatStyle = 'Flat'
$languageBox.BackColor = [Drawing.Color]::FromArgb(48, 50, 58)
$languageBox.ForeColor = $form.ForeColor
Add-ToolbarControl $languageBox '' 201

$languageOptions = [Collections.Generic.List[object]]::new()
foreach ($language in $languages) {
    $languageOptions.Add(@{
        Source = $language
        Recognizer = $language
        Label = $language.DisplayName + ' (' + $language.LanguageTag + ')'
    })
}
$englishIndex = -1
for ($index = 0; $index -lt $languageOptions.Count; $index++) {
    if ($languageOptions[$index].Source.LanguageTag -like 'en*') {
        $englishIndex = $index
        break
    }
}
if ($englishIndex -lt 0) {
    $koreanRecognizer = $languages | Where-Object LanguageTag -Like 'ko*' | Select-Object -First 1
    if ($koreanRecognizer) {
        $englishIndex = 0
        $languageOptions.Insert(0, @{
            Source = [Windows.Globalization.Language]::new('en-US')
            Recognizer = $koreanRecognizer
            Label = '영어 (한국어 OCR로 읽기)'
        })
    }
}
foreach ($option in $languageOptions) { [void]$languageBox.Items.Add($option.Label) }
if ($languageOptions.Count) { $languageBox.SelectedIndex = [Math]::Max(0, $englishIndex) }

$pickButton = [Windows.Forms.Button]::new()
$startButton = [Windows.Forms.Button]::new()
Add-ToolbarControl $pickButton '채팅 영역 선택' 113
Add-ToolbarControl $startButton '번역 시작' 93
$startButton.BackColor = [Drawing.Color]::FromArgb(83, 94, 210)

$status = [Windows.Forms.Label]::new()
$status.AutoEllipsis = $true
$status.ForeColor = [Drawing.Color]::FromArgb(185, 187, 204)
Add-ToolbarControl $status '채팅 영역을 먼저 선택하세요.' 420
$tip = [Windows.Forms.ToolTip]::new()
$status.Add_TextChanged({ $tip.SetToolTip($status, $status.Text) })
$tip.SetToolTip($status, $status.Text)
if (!$languages.Count) { $status.Text = '번역하려면 Windows OCR 언어를 설치하세요.' }

$closeButton = [Windows.Forms.Button]::new()
$closeButton.AccessibleName = '닫기'
Add-ToolbarControl $closeButton '×' 29
$closeButton.BackColor = $form.BackColor
$closeButton.Add_Click({ $form.Close() })
$toolbar.Add_SizeChanged({
    $status.Width = [Math]::Max(0, $toolbar.ClientSize.Width - 590)
})
Position-Toolbar ([Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position))
$status.Width = [Math]::Max(0, $form.ClientSize.Width - 590)

$overlay = [TranslationOverlay]::new()
$output = [MirrorView]::new()
$output.OverlayOnly = $true
$output.BackColor = [TranslationOverlay]::ClearColor
$output.Dock = 'Fill'
$overlay.Controls.Add($output)

$timer = [FrameTimer]::new($form)
$state = @{
    Region = [Drawing.Rectangle]::Empty
    SourceWindow = [IntPtr]::Zero
    Running = $false
    CapturedFrames = 0
    Cache = $output.Translations
    Language = $null
    Engine = $null
    OcrTask = $null
    OcrImage = $null
    OcrFrame = $null
    NextOcr = [DateTime]::MinValue
    Request = $null
    HttpTask = $null
    PendingLines = @()
    VisualCache = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    CacheOrder = [Collections.Generic.Queue[object]]::new()
    Backend = ''
    CacheLanguage = ''
    BatchSize = 4
    TranslationError = ''
}

function Move-MirrorOutsideRegion {
    if (!$form.Bounds.IntersectsWith($state.Region)) { return }
    foreach ($screen in [Windows.Forms.Screen]::AllScreens) {
        $area = $screen.WorkingArea
        if ($area.Width -lt $form.Width -or $area.Height -lt $form.Height) { continue }
        foreach ($x in @($area.Left, ($area.Right - $form.Width))) {
            foreach ($y in @($area.Top, ($area.Bottom - $form.Height))) {
                $target = [Drawing.Rectangle]::new($x, $y, $form.Width, $form.Height)
                if (!$target.IntersectsWith($state.Region)) {
                    $form.Location = $target.Location
                    return
                }
            }
        }
    }
}

function Clear-Ocr {
    if ($state.OcrImage) { $state.OcrImage.Dispose() }
    if ($state.OcrFrame) { $state.OcrFrame.Dispose() }
    $state.OcrImage = $null
    $state.OcrFrame = $null
    $state.OcrTask = $null
}

function Stop-Translation {
    $timer.Stop()
    $state.Running = $false
    if ($state.HttpTask) { $http.CancelPendingRequests() }
    if ($state.Request) { $state.Request.Dispose() }
    $state.HttpTask = $null
    $state.Request = $null
    if ($state.OcrTask -and !$state.OcrTask.IsCompleted) {
        try { [void]$state.OcrTask.Wait(3000) } catch { }
    }
    Clear-Ocr
    $overlay.Hide()
    $output.Lines = @()
    $output.UpdateFrame($null)
    $languageBox.Enabled = $true
    $pickButton.Enabled = $true
    $startButton.Text = '번역 시작'
}

$pickButton.Add_Click({
    $form.Hide()
    try {
        $desktop = [Windows.Forms.SystemInformation]::VirtualScreen
        $picker = [Windows.Forms.Form]::new()
        $picker.FormBorderStyle = 'None'
        $picker.StartPosition = 'Manual'
        $picker.Bounds = $desktop
        $picker.TopMost = $true
        $picker.BackColor = [Drawing.Color]::Black
        $picker.Opacity = 0.30
        $picker.Cursor = [Windows.Forms.Cursors]::Cross
        $picker.KeyPreview = $true
        $drag = @{ Start = $null; Box = [Drawing.Rectangle]::Empty }
        $picker.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $picker.Close() } })
        $picker.Add_MouseDown({
            if ($_.Button -eq 'Left') { $drag.Start = $_.Location; $picker.Capture = $true }
        })
        $picker.Add_MouseMove({
            if ($null -eq $drag.Start) { return }
            $location = $_.Location
            $x = [Math]::Min([Math]::Max($location.X, 0), $picker.ClientSize.Width)
            $y = [Math]::Min([Math]::Max($location.Y, 0), $picker.ClientSize.Height)
            $drag.Box = [Drawing.Rectangle]::FromLTRB(
                [Math]::Min($drag.Start.X, $x), [Math]::Min($drag.Start.Y, $y),
                [Math]::Max($drag.Start.X, $x), [Math]::Max($drag.Start.Y, $y))
            $picker.Invalidate()
        })
        $picker.Add_Paint({
            if (!$drag.Box.IsEmpty) { $_.Graphics.DrawRectangle([Drawing.Pens]::White, $drag.Box) }
        })
        $picker.Add_MouseUp({
            if ($_.Button -eq 'Left' -and $null -ne $drag.Start) {
                if ($drag.Box.Width -ge 40 -and $drag.Box.Height -ge 24) {
                    $origin = $picker.PointToScreen($drag.Box.Location)
                    $state.Region = [Drawing.Rectangle]::new($origin, $drag.Box.Size)
                    $status.Text = '영역이 선택되었습니다. 번역 시작을 누르세요.'
                }
                $picker.Close()
            }
        })
        [void]$picker.ShowDialog()
        if ($drag.Box.Width -ge 40 -and $drag.Box.Height -ge 24 -and !$state.Region.IsEmpty) {
            $region = $state.Region
            Position-Toolbar ([Windows.Forms.Screen]::FromRectangle($region))
            $state.SourceWindow = [ScreenReaderNative]::RootAt(
                $region.Left + [int]($region.Width / 2), $region.Top + [int]($region.Height / 2))
        }
    } finally {
        if ($picker) { $picker.Dispose() }
        $form.Show()
        $form.Activate()
    }
})

$startButton.Add_Click({
    if ($state.Running) {
        Stop-Translation
        $status.Text = '번역이 중지되었습니다.'
        return
    }
    if ($state.Region.IsEmpty) { $status.Text = '먼저 채팅 영역을 선택하세요.'; return }

    $state.Engine = $null
    $state.Language = $null
    $state.TranslationError = ''
    if ($languageBox.SelectedIndex -ge 0) {
        $option = $languageOptions[$languageBox.SelectedIndex]
        $state.Language = $option.Source
        $state.Backend = $model
        if (($state.Language.LanguageTag -split '-')[0] -in $fastLanguages) { $state.Backend = $fastModel }
        if ($state.Language.LanguageTag -notlike 'ko*') {
            $state.Engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($option.Recognizer)
        }
    }
    if (!$state.Engine) { $state.TranslationError = '외국어 OCR을 설치하고 해당 언어를 선택하면 번역도 표시됩니다.' }
    if (!$state.Engine -and !$SmokeTest) { $status.Text = $state.TranslationError; return }
    if ($state.Language -and $state.CacheLanguage -ne $state.Language.LanguageTag) {
        $state.Cache.Clear()
        $state.VisualCache.Clear()
        $state.CacheOrder.Clear()
        $state.CacheLanguage = $state.Language.LanguageTag
        $state.BatchSize = 4
    }
    $state.NextOcr = [DateTime]::MinValue
    $state.Running = $true
    $languageBox.Enabled = $false
    $pickButton.Enabled = $false
    $startButton.Text = '번역 중지'
    $status.Text = '선택한 영역을 캡처하는 중입니다.'
    Move-MirrorOutsideRegion
    $overlay.Bounds = $state.Region
    $state.CapturedFrames = 0
    $timer.Start()
})

$timer.Add_Tick({
    if (!$state.Running) { return }
    if ($state.HttpTask -and $state.HttpTask.IsCompleted) {
        $response = $null
        try {
            $response = $state.HttpTask.GetAwaiter().GetResult()
            if ([int]$response.StatusCode -eq 404 -and $state.Backend -eq $fastModel) {
                $state.Backend = $model
                return
            }
            if ([int]$response.StatusCode -eq 404) {
                throw "Ollama에 모델이 없습니다. ollama pull $model 을 실행하세요."
            }
            [void]$response.EnsureSuccessStatusCode()
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if ($state.PendingLines.Count -gt 1) {
                try {
                    $texts = @(Get-NumberedTranslations (Get-Translation $body) $state.PendingLines.Count)
                } catch {
                    $texts = @()
                }
            } else {
                $texts = @(Get-Translation $body)
            }
            if ($texts.Count -ne $state.PendingLines.Count) {
                $state.BatchSize = [Math]::Max(1, [int][Math]::Floor($state.BatchSize / 2))
            } else {
                for ($i = 0; $i -lt $texts.Count; $i++) {
                    $line = $state.PendingLines[$i]
                    $imageKey = Get-LineImageKey $line
                    $state.Cache[$line.Key] = $texts[$i]
                    $output.Invalidate()
                    $state.VisualCache[$imageKey] = $line.Key
                    $state.CacheOrder.Enqueue(@{ Text = $line.Key; Image = $imageKey })
                }
                while ($state.CacheOrder.Count -gt 10000) {
                    $expired = $state.CacheOrder.Dequeue()
                    [void]$state.Cache.Remove($expired.Text)
                    [void]$state.VisualCache.Remove($expired.Image)
                }
            }
        } catch {
            $state.TranslationError = "로컬 번역 오류 · Ollama 실행 상태를 확인하세요. $($_.Exception.GetBaseException().Message)"
        } finally {
            if ($response) { $response.Dispose() }
            $state.Request.Dispose()
            $state.Request = $null
            $state.HttpTask = $null
        }
    }

    if (![ScreenReaderNative]::SourceVisible($state.Region, $state.SourceWindow)) {
        $overlay.Hide()
        $status.Text = '디스코드 채팅이 가려졌습니다. 지정한 부분을 화면에 보이게 두세요.'
        return
    }
    if ($form.WindowState -ne 'Minimized' -and $form.Bounds.IntersectsWith($state.Region)) {
        $overlay.Hide()
        $status.Text = '설정 창을 지정 영역 밖으로 옮기세요.'
        return
    }

    $region = $state.Region
    try {
        $output.CaptureFrame($region)
        $state.CapturedFrames++
    } catch {
        $status.Text = "화면 캡처 오류 · $($_.Exception.GetBaseException().Message)"
        return
    }

    if ($state.OcrTask -and $state.OcrTask.IsCompleted) {
        try {
            $ocr = $state.OcrTask.GetAwaiter().GetResult()
            $marks = @(Get-MirrorLines $ocr $state.OcrFrame)
            foreach ($mark in $marks) {
                if (!$state.Cache.ContainsKey($mark.Key)) {
                    $imageKey = Get-LineImageKey $mark
                    if ($state.VisualCache.ContainsKey($imageKey)) { $mark.Key = $state.VisualCache[$imageKey] }
                }
            }
            $output.MergeRecognizedLines($state.OcrFrame, $marks)
        } catch {
            $state.TranslationError = "OCR 오류 · $($_.Exception.GetBaseException().Message)"
        } finally {
            Clear-Ocr
        }
    }

    if ($state.Engine -and !$state.TranslationError) {
        if (!$state.OcrTask -and [DateTime]::UtcNow -ge $state.NextOcr) {
            try {
                $maxSize = [Windows.Media.Ocr.OcrEngine]::MaxImageDimension
                if ($region.Width -gt $maxSize -or $region.Height -gt $maxSize) {
                    throw "번역하려면 한 변이 $maxSize 픽셀 이하인 영역을 지정하세요."
                }
                $state.OcrFrame = [Drawing.Bitmap]$output.Frame.Clone()
                $state.OcrImage = New-OcrInput $state.OcrFrame
                $state.OcrTask = Start-Ocr $state.Engine $state.OcrImage
                $state.NextOcr = [DateTime]::UtcNow.AddMilliseconds(150)
            } catch {
                Clear-Ocr
                $state.TranslationError = "OCR 오류 · $($_.Exception.GetBaseException().Message)"
            }
        }
        foreach ($line in $output.Lines) {
            if (!$state.Cache.ContainsKey($line.Key)) {
                $imageKey = Get-LineImageKey $line
                if ($state.VisualCache.ContainsKey($imageKey)) { $line.Key = $state.VisualCache[$imageKey]; $output.Invalidate() }
            }
        }
        if (!$state.HttpTask -and !$state.TranslationError) {
            $pending = [Collections.Generic.List[object]]::new()
            $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $requestSize = if ($state.Backend -eq $fastModel) { 1 } else { $state.BatchSize }
            for ($index = $output.Lines.Length - 1; $index -ge 0 -and $pending.Count -lt $requestSize; $index--) {
                $line = $output.Lines[$index]
                if ($state.Cache.ContainsKey($line.Key) -or
                    $line.Box.Top -lt 0 -or $line.Box.Bottom -gt $region.Height -or
                    !$keys.Add($line.Key)) { continue }
                $pending.Add($line)
            }
            if ($pending.Count) {
                try {
                    $state.PendingLines = $pending.ToArray()
                    $state.Request = New-TranslationRequest $state.Language @($pending | ForEach-Object Source) $state.Backend
                    $state.HttpTask = $http.SendAsync($state.Request)
                } catch {
                    if ($state.Request) { $state.Request.Dispose(); $state.Request = $null }
                    $state.TranslationError = "로컬 번역 오류 · Ollama 실행 상태를 확인하세요. $($_.Exception.GetBaseException().Message)"
                }
            }
        }
    }

    if (!$overlay.Visible) { $overlay.Show() }
    if ($state.TranslationError) { $status.Text = $state.TranslationError }
    elseif ($state.HttpTask) { $status.Text = '한국어 번역 중…' }
    else { $status.Text = '번역 표시 중' }
})

if ($SmokeTest) {
    $smokeTimer = [Windows.Forms.Timer]::new()
    $smokeTimer.Interval = 1100
    $form.Add_Shown({
        $startButton.PerformClick()
        $initialArea = [Windows.Forms.Screen]::FromControl($form).WorkingArea
        $state.SmokePassed = $form.Top -eq ($initialArea.Top + 4) -and
            [Math]::Abs(($form.Left + $form.Right) - ($initialArea.Left + $initialArea.Right)) -le 1 -and
            $status.Text -eq '먼저 채팅 영역을 선택하세요.' -and
            $form.ClientSize.Height -eq 46 -and $closeButton.Right -le $toolbar.ClientSize.Width -and
            $pickButton.Top -eq $startButton.Top -and $status.Top -eq $startButton.Top
        if (!$state.SmokePassed) { Write-Host "$($status.Text) height=$($form.ClientSize.Height) close=$($closeButton.Bounds) toolbar=$($toolbar.ClientSize) pick=$($pickButton.Top) start=$($startButton.Top) status=$($status.Top)"; $form.Close(); return }
        $screen = [Windows.Forms.Screen]::FromControl($form).WorkingArea
        $state.SmokeSource = [Windows.Forms.Form]::new()
        $state.SmokeSource.FormBorderStyle = 'None'
        $state.SmokeSource.StartPosition = 'Manual'
        $state.SmokeSource.Bounds = [Drawing.Rectangle]::new($screen.Left + 15, $screen.Top + 15, 720, 400)
        $state.SmokeSource.BackColor = [Drawing.Color]::DarkSlateBlue
        $state.SmokeSource.TopMost = $true
        $state.SmokeSource.Show()
        $state.Region = $state.SmokeSource.Bounds
        $state.SourceWindow = $state.SmokeSource.Handle
        $startButton.PerformClick()
        $state.Engine = $null
        $state.FrameWatch = [Diagnostics.Stopwatch]::StartNew()
        $smokeTimer.Start()
    })
    $smokeTimer.Add_Tick({
        if (!$state.SmokeMark -and $state.Running -and $output.Frame) {
            $state.CapturedFrames = 0
            $state.FrameWatch.Restart()
            $state.SmokeMark = New-Object MirrorView+Line
            $state.SmokeMark.Source = 'Test line'
            $state.SmokeMark.Key = 'Test line'
            $state.SmokeMark.Box = [Drawing.Rectangle]::new(15, 19, 180, 24)
            $state.SmokeMark.Pixels = [MirrorView]::Fingerprint($output.Frame, $state.SmokeMark.Box)
            $output.Lines = @($state.SmokeMark)
            $state.Cache['Test line'] = '번역 표시 확인'
            $output.Invalidate()
            return
        }
        $smokeTimer.Stop()
        if ($state.FrameWatch) { Write-Host ("Overlay capture cadence: {0:N1} FPS" -f ($state.CapturedFrames / $state.FrameWatch.Elapsed.TotalSeconds)) }
        $state.SmokePassed = $state.Running -and $null -ne $state.SmokeMark -and $overlay.CaptureExcluded -and
            $output.Frame.Size -eq $state.Region.Size -and $overlay.Visible -and
            [ScreenReaderNative]::SourceVisible($state.Region, $state.SourceWindow) -and
            [MirrorView]::Fingerprint($output.Frame, $state.SmokeMark.Box) -eq $state.SmokeMark.Pixels
        if (!$state.SmokePassed) {
            Write-Host "$($status.Text) visible=$($overlay.Visible) source=$([ScreenReaderNative]::SourceVisible($state.Region, $state.SourceWindow)) excluded=$($overlay.CaptureExcluded) before=$($state.SmokeMark.Pixels) after=$([MirrorView]::Fingerprint($output.Frame, $state.SmokeMark.Box))"
        }
        $form.Close()
    })
}
$form.Add_FormClosing({ Stop-Translation })
try {
    [void]$form.ShowDialog()
} finally {
    $http.Dispose()
    $timer.Dispose()
    if ($smokeTimer) { $smokeTimer.Dispose() }
    if ($state.SmokeSource) { $state.SmokeSource.Dispose() }
    $tip.Dispose()
    $overlay.Dispose()
    $form.Dispose()
}

if ($SmokeTest) {
    if (!$state.SmokePassed) { throw 'Control window or live overlay validation failed' }
    'PASS: dark control window, live capture and desktop overlay'
}
