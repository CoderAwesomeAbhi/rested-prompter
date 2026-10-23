// Rested Prompter: a thin, always-on-top teleprompter that sits right under the webcam, so the reader's eyes stay
// close to the lens. It follows the reader's voice with Windows' built-in speech recognizer (on this computer, no
// internet), listening only for the words in the script, and predicts a little ahead to hide the recognizer's delay.
//
// Keys: V follow my voice · A auto pace · Space/→ next line · ← back · R restart · 1/2/3 Abhijay/Deepam/Vihaan
//       ↑/↓ or mouse wheel text size · [ ] lead (how far ahead of the recognizer the highlight runs) · Esc quit
//       Drag anywhere to move the window.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Text;
using System.Globalization;
using System.Linq;
using System.Runtime.InteropServices;
using System.Speech.Recognition;
using System.Text.RegularExpressions;
using System.Windows.Forms;

static class Spoken
{
    static readonly string[] Ones = { "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen" };
    static readonly string[] Tens = { "", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety" };

    public static string Num(int n)
    {
        if (n < 20) return Ones[n];
        if (n < 100) return Tens[n / 10] + (n % 10 != 0 ? " " + Ones[n % 10] : "");
        if (n < 1000) return Ones[n / 100] + " hundred" + (n % 100 != 0 ? " " + Num(n % 100) : "");
        if (n < 1000000) return Num(n / 1000) + " thousand" + (n % 1000 != 0 ? " " + Num(n % 1000) : "");
        return n.ToString(CultureInfo.InvariantCulture);
    }

    // How a piece of script is said: times and numbers as words, acronyms as letters, camelCase split, lower case.
    public static List<string> Tokens(string text)
    {
        string t = text.Replace("’", "'");
        t = Regex.Replace(t, @"(\d{1,2}):(\d{2})", m =>
        {
            int h = int.Parse(m.Groups[1].Value), mi = int.Parse(m.Groups[2].Value);
            return Num(h) + (mi == 0 ? "" : mi < 10 ? " oh " + Num(mi) : " " + Num(mi));
        });
        t = Regex.Replace(t, @"\d{1,3}(,\d{3})+|\d+", m => Num(int.Parse(m.Value.Replace(",", ""))));
        t = Regex.Replace(t, @"\b([A-Z]{2,4})\b", m => string.Join(" ", m.Value.Select(c => c.ToString()).ToArray()));
        t = Regex.Replace(t, "([a-z])([A-Z])", "$1 $2");
        t = t.ToLowerInvariant().Replace("'", "");
        t = Regex.Replace(t, "[^a-z ]+", " ");
        return t.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries).ToList();
    }
}

// Where in the script the reader is: what the recognizer heard, plus a short prediction at the measured speaking rate.
class Follower
{
    public readonly List<string> G = new List<string>();
    readonly List<int> lineOf = new List<int>();
    public readonly List<int> Starts = new List<int>();
    public int Rec, Base, Off;
    public double Disp, Rate = 2.6, LastT = -1, Lead = 100;
    public List<string> Heard = new List<string>();

    public Follower(List<List<string>> lines)
    {
        for (int l = 0; l < lines.Count; l++) { Starts.Add(G.Count); foreach (var t in lines[l]) { G.Add(t); lineOf.Add(l); } }
        Starts.Add(G.Count);
    }

    static int Lev(string a, string b)
    {
        var prev = new int[b.Length + 1];
        for (int j = 0; j <= b.Length; j++) prev[j] = j;
        for (int i = 1; i <= a.Length; i++)
        {
            var cur = new int[b.Length + 1]; cur[0] = i;
            for (int j = 1; j <= b.Length; j++)
                cur[j] = Math.Min(Math.Min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
            prev = cur;
        }
        return prev[b.Length];
    }

    public static bool Same(string a, string b)
    {
        if (a == b) return true;
        if (a.Length >= 4 && b.Length >= 4 && (a.StartsWith(b) || b.StartsWith(a))) return true;
        int n = Math.Min(a.Length, b.Length);
        return n >= 5 ? Lev(a, b) <= 2 : n >= 3 ? Lev(a, b) <= 1 : false;
    }

    int AlignFrom(int p, List<string> w)
    {
        for (int k = 0; k < w.Count && p < G.Count; k++)
        {
            bool hit = false;
            for (int j = p; j < Math.Min(G.Count, p + 5); j++) if (Same(G[j], w[k])) { p = j + 1; hit = true; break; }
            if (!hit && k + 1 < w.Count)
            {
                int l = lineOf[Math.Min(p, G.Count - 1)];
                foreach (int L in new[] { l + 1, l + 2 })
                {
                    if (L >= Starts.Count - 1) continue;
                    int s = Starts[L];
                    if (s > p && s < G.Count - 1 && Same(w[k], G[s]) && Same(w[k + 1], G[s + 1])) { p = s + 1; break; }
                }
            }
        }
        return p;
    }

    public void Session() { Base = Rec; Off = 0; Heard = new List<string>(); }

    public void Hear(List<string> words, double now)
    {
        Heard = words;
        int p = AlignFrom(Base, words.Skip(Off).ToList());
        if (p > Rec)
        {
            double dt = (now - LastT) / 1000;
            if (LastT >= 0 && dt > 0.08 && dt < 2.5) Rate = Math.Min(5, Math.Max(1.3, Rate * 0.7 + (p - Rec) / dt * 0.3));
            Rec = p; LastT = now;
        }
    }

    public void JumpTo(int line) { Rec = Base = Starts[line]; Disp = Rec; Off = Heard.Count; LastT = -1; }

    // The line to show and how many of its words are already said (fractional).
    public void View(double now, out int line, out double said)
    {
        int lines = Starts.Count - 1;
        if (Rec >= G.Count) { line = lines; said = 0; return; }
        int l = lineOf[Rec], end = Starts[l + 1];
        double pred = Rec;
        // Predict only inside a line the reader has started (never through the pause before the next line),
        // and never more than two words past what the recognizer actually heard.
        if (LastT >= 0 && now - LastT < 1300 && Rec > Starts[l]) pred = Rec + Rate * (now - LastT + Lead) / 1000;
        pred = Math.Min(Math.Min(pred, end), Rec + 2);
        Disp = Math.Max(Disp, pred);
        if (Disp >= end - 0.25) { line = l + 1; said = 0; return; }
        int dl = lineOf[Math.Min((int)Disp, G.Count - 1)];
        line = dl; said = Disp - Starts[dl];
    }
}

class Prompter : Form
{
    static readonly string[] Names = { "Abhijay", "Deepam", "Vihaan" };
    static readonly string[][][] Scripts = {
        new[] {
            new[] { "Day · 0:42", "Three forty-five. One-time setup: when you wake up, how much sleep you need. Bedtime: nine forty-five." },
            new[] { "Night · 0:01 voice", "Eleven-forty. Practice, dinner, homework... If I fall asleep right now, seven hours." },
            new[] { "Night · 0:18", "I'm Abhijay." },
            new[] { "Night · 1:03", "Eight-thirty. Surprise essay, due tomorrow: two and a half hours. An hour fifteen until bed." },
            new[] { "Night · 1:10", "Watch the line." },
            new[] { "Night · 1:17", "It doesn't move." },
            new[] { "Night · 1:18", "Rested says exactly what won't fit and offers options, even a draft asking for more time." },
            new[] { "Night · 1:25", "Nothing is sent." },
            new[] { "Night · 1:26", "Rested won't do your homework. It just won't plan it past your bedtime." },
            new[] { "Night · 2:14", "Remember eleven-forty? It's the average bedtime thirty students in our district reported." },
            new[] { "Night · 2:43 lamp off", "Every assignment has a deadline." },
        },
        new[] {
            new[] { "Day · 0:52", "Before soccer, add the chem lab with a note: soccer till six, nothing before six-thirty. Gemini turns that into a rule. The lab waits till six-thirty." },
            new[] { "Night · 0:11", "He's not alone. The CDC says about one in four high schoolers gets eight hours." },
            new[] { "Night · 0:19", "I'm Deepam." },
            new[] { "Night · 0:35", "It works offline, needs no account, and your plan stays on your device." },
            new[] { "Night · 2:21", "Then they used Rested for two weeks." },
            new[] { "Night · 2:25", "In their own apps, four hundred eleven of four hundred twenty study nights ended before bedtime." },
            new[] { "Night · 2:31", "All thirty said they got to bed earlier than usual: about ninety minutes, they estimated." },
            new[] { "Night · 2:38", "A teacher said it would help with test prep, because sleep is essential." },
            new[] { "Night · 2:46 lamp off", "Rested makes bedtime the first one." },
        },
        new[] {
            new[] { "Desk · 0:20", "I'm Vihaan. We built Rested: a homework planner for high school students that never plans study past your bedtime." },
            new[] { "Desk · 0:28", "It's TypeScript, HTML and CSS, with React. Gemini reads your notes; the planner uses no AI." },
            new[] { "Desk · 1:37", "It shows its work." },
            new[] { "Desk · 1:53", "Sometimes deadline order gets stuck. Picture water in pipes: a maximum-flow algorithm re-matches all required work at once." },
            new[] { "Desk · 2:01", "A separate checker tests every block. We tried to break it: ten thousand simulated student weeks. Plans past bedtime: zero." },
            new[] { "Desk · 2:49 lamp off", "Goodnight." },
            new[] { "Jar · 1:41", "Think of tonight as a jar." },
            new[] { "Jar · 1:43", "Pour homework in first, and sleep won't fit. Rested puts sleep in first, then practice and dinner, then homework: required first, due soonest." },
        },
    };

    readonly Color bg = Color.FromArgb(15, 20, 27), ink = Color.FromArgb(242, 245, 248), gold = Color.FromArgb(242, 200, 121),
        dim = Color.FromArgb(125, 138, 152), teal = Color.FromArgb(127, 200, 179);
    const int VisibleRows = 2, Pad = 20;

    int who, line;
    double said;
    string[][] script;
    List<string[]> words;          // display words per line
    List<int[]> tokEnd;            // spoken-token count after each display word, per line
    Follower F;
    SpeechRecognitionEngine engine;
    bool voice, auto, autoPausing, engineRunning;
    double autoT0, wpm = 155;
    string status = "V listen · A auto · Space next";
    readonly List<string> committed = new List<string>();
    List<string> hyp = new List<string>();
    readonly Stopwatch clock = Stopwatch.StartNew();
    float fontSize = 24f;
    Point dragFrom; bool dragging;
    readonly Rectangle[] tabs = new Rectangle[3];   // clickable name tabs, set while painting

    public Prompter()
    {
        Text = "Rested Prompter";
        FormBorderStyle = FormBorderStyle.None; TopMost = true; BackColor = bg; DoubleBuffered = true;
        KeyPreview = true; ShowInTaskbar = true; StartPosition = FormStartPosition.Manual;
        LoadScript(0);
        Rectangle scr = Screen.PrimaryScreen.Bounds;
        Width = Math.Min(900, (int)(scr.Width * 0.62));
        Relayout();
        Left = scr.Left + (scr.Width - Width) / 2; Top = scr.Top;          // top centre: right under a laptop webcam
        var timer = new Timer { Interval = 30 };
        timer.Tick += (s, e) => Tick();
        timer.Start();
        MouseDown += (s, e) =>
        {
            if (e.Button != MouseButtons.Left) return;
            int tab = Array.FindIndex(tabs, r => r.Contains(e.Location));
            if (tab >= 0) { SwitchTo(tab); return; }
            dragging = true; dragFrom = e.Location;
        };
        MouseMove += (s, e) =>
        {
            if (dragging) Location = new Point(Left + e.X - dragFrom.X, Top + e.Y - dragFrom.Y);
            else Cursor = tabs.Any(r => r.Contains(e.Location)) ? Cursors.Hand : Cursors.SizeAll;
        };
        MouseUp += (s, e) => dragging = false;
        MouseWheel += (s, e) => SetFont(fontSize + (e.Delta > 0 ? 2 : -2));
        KeyDown += OnKey;
        FormClosing += (s, e) => { try { if (engine != null) { engine.RecognizeAsyncCancel(); engine.Dispose(); } } catch { } };
    }

    void LoadScript(int w)
    {
        who = w; script = Scripts[w]; line = 0; said = 0;
        words = script.Select(l => l[1].Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries)).ToList();
        tokEnd = new List<int[]>();
        var lineTokens = new List<List<string>>();
        foreach (var ws in words)
        {
            var ends = new int[ws.Length]; var toks = new List<string>();
            for (int k = 0; k < ws.Length; k++) { toks.AddRange(Spoken.Tokens(ws[k])); ends[k] = toks.Count; }
            tokEnd.Add(ends); lineTokens.Add(toks);
        }
        double lead = F != null ? F.Lead : 100;
        F = new Follower(lineTokens); F.Lead = lead;
        committed.Clear(); hyp = new List<string>();
        F.Session();
        autoPausing = false; autoT0 = clock.Elapsed.TotalMilliseconds;
    }

    void SetFont(float size) { fontSize = Math.Max(14, Math.Min(48, size)); Relayout(); }

    void Relayout()
    {
        using (var f = new Font("Segoe UI Semibold", fontSize))
        using (var t = new Font("Segoe UI Semibold", 10f))
            Height = (t.Height + 16) + (int)(VisibleRows * f.Height * 1.12) + t.Height + 18;
        Invalidate();
    }

    void Go(int l)
    {
        line = Math.Max(0, Math.Min(script.Length, l)); said = 0;
        if (line < script.Length) F.JumpTo(line);
        autoPausing = false; autoT0 = clock.Elapsed.TotalMilliseconds;
    }

    void OnKey(object sender, KeyEventArgs e)
    {
        switch (e.KeyCode)
        {
            case Keys.Escape: Close(); break;
            case Keys.Space: case Keys.Right: Go(line + 1); break;
            case Keys.Left: Go(line - 1); break;
            case Keys.R: StopAll("Restarted"); LoadScript(who); break;
            case Keys.V: if (voice) StopAll("Voice follow off"); else StartVoice(); break;
            case Keys.A: if (auto) StopAll("Auto paused"); else { StopAll(""); auto = true; autoPausing = false; autoT0 = clock.Elapsed.TotalMilliseconds; status = "Auto pacing"; } break;
            case Keys.D1: case Keys.NumPad1: SwitchTo(0); break;
            case Keys.D2: case Keys.NumPad2: SwitchTo(1); break;
            case Keys.D3: case Keys.NumPad3: SwitchTo(2); break;
            case Keys.Tab: SwitchTo((who + (e.Shift ? 2 : 1)) % 3); break;
            case Keys.Up: SetFont(fontSize + 2); break;
            case Keys.Down: SetFont(fontSize - 2); break;
            case Keys.OemOpenBrackets: F.Lead = Math.Max(0, F.Lead - 50); status = "Lead " + (F.Lead / 1000).ToString("0.00") + " s"; break;
            case Keys.OemCloseBrackets: F.Lead = Math.Min(1200, F.Lead + 50); status = "Lead " + (F.Lead / 1000).ToString("0.00") + " s"; break;
        }
        e.Handled = true;
    }

    // Switch to another person's script from the top; if it was listening, keep listening on the new script.
    void SwitchTo(int w)
    {
        bool wasListening = voice;
        StopAll("");
        LoadScript(w);
        if (wasListening) StartVoice(); else status = "V listen · A auto · Space next";
        Invalidate();
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        // Tab normally moves focus between controls; here it switches person.
        if (keyData == Keys.Tab || keyData == (Keys.Tab | Keys.Shift)) { SwitchTo((who + (keyData == Keys.Tab ? 1 : 2)) % 3); return true; }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    void StartVoice()
    {
        StopAll("");
        try
        {
            if (engine == null)
            {
                engine = new SpeechRecognitionEngine(new CultureInfo("en-US"));
                // Every script line, starting at any word, as a phrase: the recognizer knows what comes next, which
                // made it both more accurate and faster than plain dictation in testing.
                var phrases = new HashSet<string>();
                foreach (var s in Scripts) foreach (var l in s)
                {
                    var t = Spoken.Tokens(l[1]);
                    for (int a = 0; a < t.Count; a++) phrases.Add(string.Join(" ", t.Skip(a).ToArray()));
                }
                var gb = new GrammarBuilder(new Choices(phrases.ToArray()));
                gb.Culture = engine.RecognizerInfo.Culture;
                engine.LoadGrammar(new Grammar(gb));
                engine.SetInputToDefaultAudioDevice();
                engine.EndSilenceTimeout = TimeSpan.FromMilliseconds(250);
                engine.SpeechHypothesized += (s, e) => { var w = WordsOf(e.Result); BeginInvoke((Action)(() => Heard(w, 0))); };
                engine.SpeechRecognized += (s, e) => { var w = WordsOf(e.Result); BeginInvoke((Action)(() => Heard(w, 1))); };
                engine.SpeechRecognitionRejected += (s, e) => { var w = WordsOf(e.Result); BeginInvoke((Action)(() => Heard(w, 2))); };
                engine.RecognizeCompleted += (s, e) => engineRunning = false;
            }
            committed.Clear(); hyp = new List<string>(); F.Session();
            if (!engineRunning) { engine.RecognizeAsync(RecognizeMode.Multiple); engineRunning = true; }
            voice = true; status = "Listening";
        }
        catch (Exception ex) { voice = false; status = "Can't listen: " + ex.Message + " (use A or Space)"; }
    }

    static List<string> WordsOf(RecognitionResult r)
    {
        return r == null ? new List<string>() : r.Words.SelectMany(w => Spoken.Tokens(w.Text)).ToList();
    }

    // kind: 0 partial, 1 final, 2 rejected (keep whichever of the rejected guess and the last partial is longer)
    void Heard(List<string> w, int kind)
    {
        if (!voice) return;
        if (kind == 0) hyp = w;
        else { committed.AddRange(kind == 1 || w.Count >= hyp.Count ? w : hyp); hyp = new List<string>(); }
        F.Hear(committed.Concat(hyp).ToList(), clock.Elapsed.TotalMilliseconds);
    }

    void StopAll(string msg)
    {
        voice = false; auto = false;
        if (engine != null && engineRunning) { try { engine.RecognizeAsyncCancel(); } catch { } engineRunning = false; }
        if (msg != "") status = msg;
    }

    void Tick()
    {
        double now = clock.Elapsed.TotalMilliseconds;
        if (voice)
        {
            int l; double s; F.View(now, out l, out s); line = l; said = s;
            if (line >= script.Length) StopAll("Done. Stop recording.");
        }
        else if (auto && line < script.Length)
        {
            int toks = F.Starts[line + 1] - F.Starts[line];
            double dur = toks / (wpm / 60000.0) + 400, el = now - autoT0;
            if (!autoPausing) { said = Math.Min(toks, el / dur * toks); if (el >= dur) { autoPausing = true; autoT0 = now; } }
            else if (el >= 2000) { autoPausing = false; line++; said = 0; autoT0 = now; if (line >= script.Length) StopAll("Done. Stop recording."); }
        }
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        using (var small = new Font("Segoe UI", 10f))
        using (var big = new Font("Segoe UI Semibold", fontSize))
        using (var under = new Pen(gold, 3))
        {
            // Name tabs: click one (or press 1/2/3, or Tab) to switch person.
            int tx = Pad;
            using (var tabFont = new Font("Segoe UI Semibold", 10f))
            using (var edge = new Pen(Color.FromArgb(70, 84, 100)))
            using (var fill = new SolidBrush(gold))
                for (int k = 0; k < Names.Length; k++)
                {
                    string label = (k + 1) + "  " + Names[k];
                    var ts = TextRenderer.MeasureText(g, label, tabFont);
                    tabs[k] = new Rectangle(tx, 4, ts.Width + 16, ts.Height + 6);
                    if (k == who) g.FillRectangle(fill, tabs[k]); else g.DrawRectangle(edge, tabs[k]);
                    TextRenderer.DrawText(g, label, tabFont, tabs[k], k == who ? bg : ink,
                        TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
                    tx = tabs[k].Right + 6;
                }
            string head = line < script.Length ? (line + 1) + "/" + script.Length + "  " + script[line][0] : "done";
            var headSize = TextRenderer.MeasureText(g, head, small);
            var headBox = new Rectangle(tx + 8, tabs[0].Top, headSize.Width, tabs[0].Height);
            TextRenderer.DrawText(g, head, small, headBox, dim, TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
            var statusBox = new Rectangle(headBox.Right + 16, tabs[0].Top, Math.Max(0, Width - Pad - headBox.Right - 16), tabs[0].Height);
            TextRenderer.DrawText(g, status, small, statusBox, voice ? gold : dim,
                TextFormatFlags.Right | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix);
            int top = tabs[0].Bottom + 6, rowH = (int)(big.Height * 1.12);
            if (line >= script.Length)
            {
                TextRenderer.DrawText(g, "Done. Stop recording.", big, new Point(Pad, top), teal);
                return;
            }
            var ws = words[line]; var ends = tokEnd[line];
            int saidWords = 0;
            while (saidWords < ws.Length && ends[saidWords] <= said + 0.001) saidWords++;
            var flags = TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix;
            int space = TextRenderer.MeasureText(g, "x x", big, Size.Empty, flags).Width - TextRenderer.MeasureText(g, "xx", big, Size.Empty, flags).Width;
            int maxW = Width - 2 * Pad;
            var rows = new List<List<int>>(); var cur = new List<int>(); int x = 0;
            var widths = ws.Select(w => TextRenderer.MeasureText(g, w, big, Size.Empty, flags).Width).ToArray();
            for (int k = 0; k < ws.Length; k++)
            {
                if (cur.Count > 0 && x + widths[k] > maxW) { rows.Add(cur); cur = new List<int>(); x = 0; }
                cur.Add(k); x += widths[k] + space;
            }
            rows.Add(cur);
            int target = Math.Min(saidWords, ws.Length - 1);
            int rowOfCur = rows.FindIndex(r => r.Contains(target));
            int first = Math.Max(0, Math.Min(rowOfCur, rows.Count - VisibleRows));
            for (int r = first; r < Math.Min(rows.Count, first + VisibleRows); r++)
            {
                int y = top + (r - first) * rowH; x = Pad;
                foreach (int k in rows[r])
                {
                    TextRenderer.DrawText(g, ws[k], big, new Point(x, y), k < saidWords ? gold : ink, flags);
                    if (k == saidWords) g.DrawLine(under, x, y + big.Height - 2, x + widths[k], y + big.Height - 2);
                    x += widths[k] + space;
                }
            }
            string next = line + 1 < script.Length ? "Next: " + script[line + 1][1] : "Next: (end)";
            TextRenderer.DrawText(g, next, small, new Rectangle(Pad, top + VisibleRows * rowH + 4, maxW, 24), teal,
                TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix);
        }
    }

    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

    [STAThread]
    static void Main()
    {
        try { SetProcessDPIAware(); } catch { }
        Application.EnableVisualStyles();
        Application.Run(new Prompter());
    }
}
