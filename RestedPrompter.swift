// Rested Prompter for Mac: a thin, always-on-top teleprompter that sits right under the webcam, so the reader's eyes
// stay close to the lens. It follows the reader's voice with Apple's speech recognizer (on this Mac when it can, which
// is faster) and predicts a little ahead to hide the recognizer's delay. Same scripts and keys as the Windows version.
//
// Keys: V follow my voice · A auto pace · Space/→ next line · ← back · R restart · 1/2/3 or Tab Abhijay/Deepam/Vihaan
//       ↑/↓ or scroll text size · [ ] lead (how far ahead of the recognizer the highlight runs) · Esc quit
//       Drag anywhere to move the window.
import AppKit
import AVFoundation
import Speech

enum Spoken {
    static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    static func num(_ n: Int) -> String {
        if n < 20 { return ones[n] }
        if n < 100 { return tens[n / 10] + (n % 10 != 0 ? " " + ones[n % 10] : "") }
        if n < 1000 { return ones[n / 100] + " hundred" + (n % 100 != 0 ? " " + num(n % 100) : "") }
        if n < 1_000_000 { return num(n / 1000) + " thousand" + (n % 1000 != 0 ? " " + num(n % 1000) : "") }
        return String(n)
    }

    // Regex replace where each match (with its groups) is turned into text by a function.
    static func replace(_ s: String, _ pattern: String, _ f: ([String]) -> String) -> String {
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = s as NSString
        var out = "", last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var groups: [String] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            out += f(groups)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    // How a piece of script is said: times and numbers as words, acronyms as letters, camelCase split, lower case.
    static func tokens(_ text: String) -> [String] {
        var t = text.replacingOccurrences(of: "’", with: "'")
        t = replace(t, "(\\d{1,2}):(\\d{2})") { g in
            let h = Int(g[1]) ?? 0, mi = Int(g[2]) ?? 0
            return num(h) + (mi == 0 ? "" : mi < 10 ? " oh " + num(mi) : " " + num(mi))
        }
        t = replace(t, "\\d{1,3}(,\\d{3})+|\\d+") { g in
            guard let n = Int(g[0].replacingOccurrences(of: ",", with: "")), n < 1_000_000 else { return " " }
            return num(n)
        }
        t = replace(t, "\\b([A-Z]{2,4})\\b") { g in g[0].map { String($0) }.joined(separator: " ") }
        t = replace(t, "([a-z])([A-Z])") { g in g[1] + " " + g[2] }
        t = t.lowercased().replacingOccurrences(of: "'", with: "")
        t = replace(t, "[^a-z ]+") { _ in " " }
        return t.split(separator: " ").map(String.init)
    }
}

// Where in the script the reader is: what the recognizer heard, plus a short prediction at the measured speaking rate.
final class Follower {
    private(set) var g: [String] = []
    private var lineOf: [Int] = []
    private(set) var starts: [Int] = []
    var rec = 0, base = 0, off = 0
    var disp = 0.0, rate = 2.6, lastT = -1.0, lead = 100.0
    var heard: [String] = []

    init(_ lines: [[String]]) {
        for (l, toks) in lines.enumerated() {
            starts.append(g.count)
            for t in toks { g.append(t); lineOf.append(l) }
        }
        starts.append(g.count)
    }

    static func lev(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [Int](repeating: 0, count: b.count + 1)
            cur[0] = i
            for j in 1...b.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
            prev = cur
        }
        return prev[b.count]
    }

    static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.count >= 4 && b.count >= 4 && (a.hasPrefix(b) || b.hasPrefix(a)) { return true }
        let n = min(a.count, b.count)
        return n >= 5 ? lev(a, b) <= 2 : n >= 3 ? lev(a, b) <= 1 : false
    }

    private func alignFrom(_ start: Int, _ w: [String]) -> Int {
        var p = start, k = 0
        while k < w.count && p < g.count {
            var hit = false, j = p
            while j < min(g.count, p + 5) {
                if Follower.same(g[j], w[k]) { p = j + 1; hit = true; break }
                j += 1
            }
            if !hit && k + 1 < w.count {
                let l = lineOf[min(p, g.count - 1)]
                for L in [l + 1, l + 2] where L < starts.count - 1 {
                    let s = starts[L]
                    if s > p && s < g.count - 1 && Follower.same(w[k], g[s]) && Follower.same(w[k + 1], g[s + 1]) { p = s + 1; break }
                }
            }
            k += 1
        }
        return p
    }

    func session() { base = rec; off = 0; heard = [] }

    func hear(_ words: [String], _ now: Double) {
        heard = words
        let p = alignFrom(base, Array(words.dropFirst(min(off, words.count))))
        if p > rec {
            let dt = (now - lastT) / 1000
            if lastT >= 0 && dt > 0.08 && dt < 2.5 { rate = min(5, max(1.3, rate * 0.7 + Double(p - rec) / dt * 0.3)) }
            rec = p; lastT = now
        }
    }

    func jumpTo(_ line: Int) { rec = starts[line]; base = rec; disp = Double(rec); off = heard.count; lastT = -1 }

    // The line to show and how many of its words are already said (fractional).
    func view(_ now: Double) -> (line: Int, said: Double) {
        if rec >= g.count { return (starts.count - 1, 0) }
        let l = lineOf[rec], end = starts[l + 1]
        var pred = Double(rec)
        // Predict only inside a line the reader has started (never through the pause before the next line),
        // and never more than two words past what the recognizer actually heard.
        if lastT >= 0 && now - lastT < 1300 && rec > starts[l] { pred = Double(rec) + rate * (now - lastT + lead) / 1000 }
        pred = min(pred, Double(end), Double(rec + 2))
        disp = max(disp, pred)
        if disp >= Double(end) - 0.25 { return (l + 1, 0) }
        let dl = lineOf[min(Int(disp), g.count - 1)]
        return (dl, disp - Double(starts[dl]))
    }
}

enum Script {
    static let names = ["Abhijay", "Deepam", "Vihaan"]
    static let all: [[[String]]] = [
        [
            ["Day · 0:42", "Three forty-five. One-time setup: when you wake up, how much sleep you need. Bedtime: nine forty-five."],
            ["Night · 0:01 voice", "Eleven-forty. Practice, dinner, homework... If I fall asleep right now, seven hours."],
            ["Night · 0:18", "I'm Abhijay."],
            ["Night · 1:03", "Eight-thirty. Surprise essay, due tomorrow: two and a half hours. An hour fifteen until bed."],
            ["Night · 1:10", "Watch the line."],
            ["Night · 1:17", "It doesn't move."],
            ["Night · 1:18", "Rested says exactly what won't fit and offers options, even a draft asking for more time."],
            ["Night · 1:25", "Nothing is sent."],
            ["Night · 1:26", "Rested won't do your homework. It just won't plan it past your bedtime."],
            ["Night · 2:14", "Remember eleven-forty? It's the average bedtime thirty students in our district reported."],
            ["Night · 2:43 lamp off", "Every assignment has a deadline."],
        ],
        [
            ["Day · 0:52", "Before soccer, add the chem lab with a note: soccer till six, nothing before six-thirty. Gemini turns that into a rule. The lab waits till six-thirty."],
            ["Night · 0:11", "He's not alone. The CDC says about one in four high schoolers gets eight hours."],
            ["Night · 0:19", "I'm Deepam."],
            ["Night · 0:35", "It works offline, needs no account, and your plan stays on your device."],
            ["Night · 2:21", "Then they used Rested for two weeks."],
            ["Night · 2:25", "In their own apps, four hundred eleven of four hundred twenty study nights ended before bedtime."],
            ["Night · 2:31", "All thirty said they got to bed earlier than usual: about ninety minutes, they estimated."],
            ["Night · 2:38", "A teacher said it would help with test prep, because sleep is essential."],
            ["Night · 2:46 lamp off", "Rested makes bedtime the first one."],
        ],
        [
            ["Desk · 0:20", "I'm Vihaan. We built Rested: a homework planner for high school students that never plans study past your bedtime."],
            ["Desk · 0:28", "It's TypeScript, HTML and CSS, with React. Gemini reads your notes; the planner uses no AI."],
            ["Desk · 1:37", "It shows its work."],
            ["Desk · 1:53", "Sometimes deadline order gets stuck. Picture water in pipes: a maximum-flow algorithm re-matches all required work at once."],
            ["Desk · 2:01", "A separate checker tests every block. We tried to break it: ten thousand simulated student weeks. Plans past bedtime: zero."],
            ["Desk · 2:49 lamp off", "Goodnight."],
            ["Jar · 1:41", "Think of tonight as a jar."],
            ["Jar · 1:43", "Pour homework in first, and sleep won't fit. Rested puts sleep in first, then practice and dinner, then homework: required first, due soonest."],
        ],
    ]
    // Unusual words the recognizer should expect.
    static let hints = names + ["Rested", "Gemini", "CDC", "TypeScript", "React", "HTML", "CSS", "chem lab",
        "maximum-flow algorithm", "bedtime", "high schoolers"]

    // Display words per line, the spoken-token count after each display word, and a follower for the script.
    static func prepare(_ script: [[String]]) -> (words: [[String]], tokEnd: [[Int]], follower: Follower) {
        var words: [[String]] = [], tokEnd: [[Int]] = [], lineTokens: [[String]] = []
        for l in script {
            let ws = l[1].split(separator: " ").map(String.init)
            var ends: [Int] = [], toks: [String] = []
            for w in ws { toks += Spoken.tokens(w); ends.append(toks.count) }
            words.append(ws); tokEnd.append(ends); lineTokens.append(toks)
        }
        return (words, tokEnd, Follower(lineTokens))
    }
}

func nowMs() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }

// Streams the microphone into Apple's speech recognizer. Each request's partial results are the whole transcript
// of that request so far; the prompter starts a fresh request when one ends or gets long.
final class Listener {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var running = false
    private(set) var startedAt = 0.0, lastResultAt = 0.0
    private(set) var onDevice = false
    var useOnDevice = true
    var onWords: (([String]) -> Void)?
    var onEnd: ((Error?) -> Void)?

    static func authorize(_ done: @escaping (String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    done("Speech Recognition is off for Rested Prompter: System Settings → Privacy & Security → Speech Recognition")
                    return
                }
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: done(nil)
                case .notDetermined:
                    AVCaptureDevice.requestAccess(for: .audio) { ok in
                        DispatchQueue.main.async { done(ok ? nil : "Microphone is off for Rested Prompter: System Settings → Privacy & Security → Microphone") }
                    }
                default: done("Microphone is off for Rested Prompter: System Settings → Privacy & Security → Microphone")
                }
            }
        }
    }

    func start() throws {
        guard let r = recognizer, r.isAvailable else {
            throw NSError(domain: "RestedPrompter", code: 1, userInfo: [NSLocalizedDescriptionKey: "speech recognition isn't available right now"])
        }
        if !running {
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 && format.channelCount > 0 else {
                throw NSError(domain: "RestedPrompter", code: 2, userInfo: [NSLocalizedDescriptionKey: "no microphone found"])
            }
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self = self else { return }
                self.lock.lock(); let req = self.request; self.lock.unlock()
                req?.append(buffer)
            }
            engine.prepare()
            try engine.start()
            running = true
        }
        newRequest()
    }

    func newRequest() {
        guard let r = recognizer else { return }
        generation += 1
        let gen = generation
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.contextualStrings = Script.hints
        onDevice = useOnDevice && r.supportsOnDeviceRecognition
        req.requiresOnDeviceRecognition = onDevice
        if #available(macOS 13.0, *) { req.addsPunctuation = false }
        lock.lock(); let old = request; request = req; lock.unlock()
        old?.endAudio()
        task?.cancel()
        startedAt = nowMs(); lastResultAt = startedAt
        task = r.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self, gen == self.generation else { return }
                if let result = result {
                    self.lastResultAt = nowMs()
                    self.onWords?(Spoken.tokens(result.bestTranscription.formattedString))
                    if result.isFinal { self.onEnd?(nil) }
                } else if let error = error {
                    self.onEnd?(error)
                }
            }
        }
    }

    func stop() {
        generation += 1
        lock.lock(); let old = request; request = nil; lock.unlock()
        old?.endAudio()
        task?.cancel(); task = nil
        if running { engine.stop(); engine.inputNode.removeTap(onBus: 0); running = false }
    }
}

final class PromptView: NSView {
    let bg = NSColor(srgbRed: 15 / 255, green: 20 / 255, blue: 27 / 255, alpha: 1)
    let ink = NSColor(srgbRed: 242 / 255, green: 245 / 255, blue: 248 / 255, alpha: 1)
    let gold = NSColor(srgbRed: 242 / 255, green: 200 / 255, blue: 121 / 255, alpha: 1)
    let dim = NSColor(srgbRed: 125 / 255, green: 138 / 255, blue: 152 / 255, alpha: 1)
    let teal = NSColor(srgbRed: 127 / 255, green: 200 / 255, blue: 179 / 255, alpha: 1)
    let edge = NSColor(srgbRed: 70 / 255, green: 84 / 255, blue: 100 / 255, alpha: 1)
    let small = NSFont.systemFont(ofSize: 12)
    let tabFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    let visibleRows = 2
    let pad: CGFloat = 20

    var who = 0, line = 0
    var said = 0.0
    var script: [[String]] = []
    var words: [[String]] = []
    var tokEnd: [[Int]] = []
    var f = Follower([])
    let listener = Listener()
    var voice = false, auto = false, autoPausing = false
    var autoT0 = 0.0, wpm = 155.0
    var failures = 0
    var status = "V listen · A auto · Space next"
    var fontSize: CGFloat = 26
    var tabs = [NSRect](repeating: .zero, count: 3)
    var timer: Timer?
    var scrollAcc: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        loadScript(0)
        listener.onWords = { [weak self] words in
            guard let self = self, self.voice else { return }
            self.failures = 0
            self.f.hear(words, nowMs())
        }
        listener.onEnd = { [weak self] error in
            guard let self = self, self.voice else { return }
            // A request that fails right away, again and again, means the recognizer can't run: try online, then give up.
            if error != nil && nowMs() - self.listener.startedAt < 1500 { self.failures += 1 } else { self.failures = 0 }
            if self.failures >= 3 {
                if self.listener.useOnDevice {
                    self.listener.useOnDevice = false; self.failures = 0; self.status = "Listening (online)"
                } else {
                    let why = error?.localizedDescription ?? "speech recognition stopped"
                    self.stopAll("Can't listen: \(why). Turn on Dictation (System Settings → Keyboard), then press V. Or use A / Space.")
                    return
                }
            }
            self.f.session(); self.listener.newRequest()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func start() {
        timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func loadScript(_ w: Int) {
        who = w; script = Script.all[w]; line = 0; said = 0
        let lead = f.lead
        let p = Script.prepare(script)
        words = p.words; tokEnd = p.tokEnd; f = p.follower; f.lead = lead
        f.session()
        autoPausing = false; autoT0 = nowMs()
    }

    var big: NSFont { NSFont.systemFont(ofSize: fontSize, weight: .semibold) }
    func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }
    var rowHeight: CGFloat { ceil(lineHeight(big) * 1.12) }
    var tabHeight: CGFloat { lineHeight(tabFont) + 8 }
    func preferredHeight() -> CGFloat { 6 + tabHeight + 8 + CGFloat(visibleRows) * rowHeight + 6 + lineHeight(small) + 12 }

    func setFont(_ size: CGFloat) {
        fontSize = max(14, min(48, size))
        if let w = window {
            var fr = w.frame
            let h = preferredHeight()
            fr.origin.y += fr.height - h; fr.size.height = h
            w.setFrame(fr, display: true)
        }
        needsDisplay = true
    }

    func go(_ l: Int) {
        line = max(0, min(script.count, l)); said = 0
        if line < script.count { f.jumpTo(line) }
        autoPausing = false; autoT0 = nowMs()
    }

    // Switch to another person's script from the top; if it was listening, keep listening on the new script.
    func switchTo(_ w: Int) {
        let wasListening = voice
        stopAll("")
        loadScript(w)
        if wasListening { startVoice() } else { status = "V listen · A auto · Space next" }
        needsDisplay = true
    }

    func startVoice() {
        stopAll("")
        status = "Asking for the microphone…"
        Listener.authorize { [weak self] problem in
            guard let self = self else { return }
            if let problem = problem { self.status = problem; return }
            do {
                if self.line < self.script.count { self.f.jumpTo(self.line) }
                self.f.session()
                self.failures = 0
                try self.listener.start()
                self.voice = true
                self.status = self.listener.onDevice ? "Listening (on this Mac)" : "Listening (online)"
            } catch {
                self.voice = false
                self.status = "Can't listen: \(error.localizedDescription) (use A or Space)"
            }
        }
    }

    func stopAll(_ msg: String) {
        voice = false; auto = false
        listener.stop()
        if !msg.isEmpty { status = msg }
    }

    func tick() {
        let now = nowMs()
        if voice {
            // Apple limits how long one request can run, so start a fresh one in a pause once it gets old.
            if now - listener.startedAt > 45000 && now - listener.lastResultAt > 800 { f.session(); listener.newRequest() }
            let v = f.view(now); line = v.line; said = v.said
            if line >= script.count { stopAll("Done. Stop recording.") }
        } else if auto && line < script.count {
            let toks = Double(f.starts[line + 1] - f.starts[line])
            let dur = toks / (wpm / 60000) + 400, el = now - autoT0
            if !autoPausing {
                said = min(toks, el / dur * toks)
                if el >= dur { autoPausing = true; autoT0 = now }
            } else if el >= 2000 {
                autoPausing = false; line += 1; said = 0; autoT0 = now
                if line >= script.count { stopAll("Done. Stop recording.") }
            }
        }
        needsDisplay = true
    }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 53: NSApp.terminate(nil)
        case 49, 124: go(line + 1)
        case 123: go(line - 1)
        case 126: setFont(fontSize + 2)
        case 125: setFont(fontSize - 2)
        case 48: switchTo((who + (e.modifierFlags.contains(.shift) ? 2 : 1)) % 3)
        default:
            switch (e.charactersIgnoringModifiers ?? "").lowercased() {
            case "v": if voice { stopAll("Voice follow off") } else { startVoice() }
            case "a":
                if auto { stopAll("Auto paused") } else {
                    stopAll(""); auto = true; autoPausing = false; autoT0 = nowMs(); status = "Auto pacing"
                }
            case "r": stopAll("Restarted"); loadScript(who)
            case "1": switchTo(0)
            case "2": switchTo(1)
            case "3": switchTo(2)
            case "[": f.lead = max(0, f.lead - 50); status = String(format: "Lead %.2f s", f.lead / 1000)
            case "]": f.lead = min(1200, f.lead + 50); status = String(format: "Lead %.2f s", f.lead / 1000)
            default: super.keyDown(with: e)
            }
        }
        needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let k = tabs.firstIndex(where: { $0.contains(p) }) { switchTo(k); return }
        window?.performDrag(with: e)
    }

    override func scrollWheel(with e: NSEvent) {
        if !e.hasPreciseScrollingDeltas {
            if e.scrollingDeltaY != 0 { setFont(fontSize + (e.scrollingDeltaY > 0 ? 2 : -2)) }
            return
        }
        scrollAcc += e.scrollingDeltaY
        if abs(scrollAcc) >= 24 { setFont(fontSize + (scrollAcc > 0 ? 2 : -2)); scrollAcc = 0 }
    }

    func attrs(_ font: NSFont, _ color: NSColor) -> [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: color] }

    override func draw(_ dirtyRect: NSRect) {
        bg.setFill(); bounds.fill()
        // Name tabs: click one (or press 1/2/3, or Tab) to switch person.
        var tx = pad
        for k in 0..<Script.names.count {
            let label = "\(k + 1)  \(Script.names[k])" as NSString
            let a = attrs(tabFont, k == who ? bg : ink)
            let s = label.size(withAttributes: a)
            let r = NSRect(x: tx, y: 6, width: ceil(s.width) + 18, height: tabHeight)
            tabs[k] = r
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            if k == who { gold.setFill(); path.fill() } else { edge.setStroke(); path.lineWidth = 1; path.stroke() }
            label.draw(at: NSPoint(x: r.minX + (r.width - s.width) / 2, y: r.minY + (r.height - s.height) / 2), withAttributes: a)
            tx = r.maxX + 6
        }
        let head = (line < script.count ? "\(line + 1)/\(script.count)  \(script[line][0])" : "done") as NSString
        let ha = attrs(small, dim), hs = head.size(withAttributes: ha), midY = tabs[0].midY
        head.draw(at: NSPoint(x: tx + 8, y: midY - hs.height / 2), withAttributes: ha)
        let rightAligned = NSMutableParagraphStyle()
        rightAligned.alignment = .right; rightAligned.lineBreakMode = .byTruncatingTail
        var sa = attrs(small, voice ? gold : dim); sa[.paragraphStyle] = rightAligned
        let sx = tx + 8 + ceil(hs.width) + 16
        (status as NSString).draw(in: NSRect(x: sx, y: midY - hs.height / 2, width: max(0, bounds.width - pad - sx), height: hs.height + 2), withAttributes: sa)

        let top = tabs[0].maxY + 8, rowH = rowHeight, font = big
        if line >= script.count {
            ("Done. Stop recording." as NSString).draw(at: NSPoint(x: pad, y: top), withAttributes: attrs(font, teal))
            return
        }
        let ws = words[line], ends = tokEnd[line]
        var saidWords = 0
        while saidWords < ws.count && Double(ends[saidWords]) <= said + 0.001 { saidWords += 1 }
        let space = ("x x" as NSString).size(withAttributes: [.font: font]).width - ("xx" as NSString).size(withAttributes: [.font: font]).width
        let maxW = bounds.width - 2 * pad
        let widths = ws.map { ($0 as NSString).size(withAttributes: [.font: font]).width }
        var rows: [[Int]] = [], cur: [Int] = [], x: CGFloat = 0
        for k in 0..<ws.count {
            if !cur.isEmpty && x + widths[k] > maxW { rows.append(cur); cur = []; x = 0 }
            cur.append(k); x += widths[k] + space
        }
        rows.append(cur)
        let target = min(saidWords, ws.count - 1)
        let rowOfCur = rows.firstIndex { $0.contains(target) } ?? 0
        let first = max(0, min(rowOfCur, rows.count - visibleRows))
        for r in first..<min(rows.count, first + visibleRows) {
            let y = top + CGFloat(r - first) * rowH
            x = pad
            for k in rows[r] {
                (ws[k] as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs(font, k < saidWords ? gold : ink))
                if k == saidWords {
                    let u = NSBezierPath(), uy = y + lineHeight(font) - 1
                    u.lineWidth = 3
                    u.move(to: NSPoint(x: x, y: uy)); u.line(to: NSPoint(x: x + widths[k], y: uy))
                    gold.setStroke(); u.stroke()
                }
                x += widths[k] + space
            }
        }
        let next = (line + 1 < script.count ? "Next: " + script[line + 1][1] : "Next: (end)") as NSString
        let truncated = NSMutableParagraphStyle()
        truncated.lineBreakMode = .byTruncatingTail
        var na = attrs(small, teal); na[.paragraphStyle] = truncated
        next.draw(in: NSRect(x: pad, y: top + CGFloat(visibleRows) * rowH + 6, width: maxW, height: lineHeight(small) + 2), withAttributes: na)
    }
}

final class PromptWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: PromptWindow?
    var view: PromptView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Rested Prompter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = menu

        let v = PromptView(frame: .zero)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let w = min(900, floor(screen.frame.width * 0.62)), h = v.preferredHeight()
        // Top centre, just under the menu bar: right below a MacBook's camera.
        let win = PromptWindow(contentRect: NSRect(x: vf.midX - w / 2, y: vf.maxY - h, width: w, height: h),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        win.title = "Rested Prompter"
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.backgroundColor = v.bg
        win.hasShadow = true
        win.contentView = v
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(v)
        NSApp.activate(ignoringOtherApps: true)
        v.start()
        window = win; view = v
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { view?.listener.stop() }
}

// Checks run on the build machine: number handling, plus a simulated read of every script with recognizer-style
// output (digits, split names, a delay and jitter), measuring when each line hands over to the next.
enum SelfTest {
    static let dictated: [(String, String)] = [
        ("four hundred eleven", "411"), ("four hundred twenty", "420"), ("Eleven-forty", "11:40"), ("eleven-forty", "11:40"),
        ("Three forty-five", "3:45"), ("nine forty-five", "9:45"), ("six-thirty", "6:30"), ("till six,", "till 6,"),
        ("Eight-thirty", "8:30"), ("ten thousand", "10,000"), ("one in four", "1 in 4"), ("eight hours", "8 hours"),
        ("seven hours", "7 hours"), ("two weeks", "2 weeks"), ("thirty", "30"), ("ninety", "90"),
        ("An hour fifteen", "An hour 15"), ("two and a half", "2 1/2"), ("zero", "0"),
        ("Abhijay", "Abhi Jay"), ("Deepam", "Deep um"), ("Vihaan", "Vihan"), ("TypeScript", "typescript"),
        ("maximum-flow", "maximum flow"), ("re-matches", "rematches"),
    ]

    static func run() -> Bool {
        var ok = true
        let cases: [(String, [String])] = [
            ("11:40", ["eleven", "forty"]), ("6:05", ["six", "oh", "five"]), ("411 of 420", ["four", "hundred", "eleven", "of", "four", "hundred", "twenty"]),
            ("10,000", ["ten", "thousand"]), ("CDC", ["c", "d", "c"]), ("TypeScript", ["type", "script"]), ("It’s", ["its"]),
            ("nine forty-five.", ["nine", "forty", "five"]),
        ]
        for (text, want) in cases {
            let got = Spoken.tokens(text)
            if got != want { ok = false; print("FAIL tokens(\(text)) = \(got), want \(want)") }
        }
        print(ok ? "Number and word handling: all \(cases.count) checks pass" : "Number and word handling: FAILED")
        for w in 0..<Script.names.count { ok = simulate(w) && ok }
        return ok
    }

    static func simulate(_ w: Int) -> Bool {
        let script = Script.all[w]
        let f = Script.prepare(script).follower
        let perWord = 400.0, delay = 380.0, pause = 2000.0
        var events: [(t: Double, word: String)] = [], spans: [(start: Double, end: Double)] = []
        var t = 1000.0
        for l in script {
            var text = l[1]
            for (a, b) in dictated { text = text.replacingOccurrences(of: a, with: b) }
            let ws = text.split(separator: " ").map(String.init)
            for (k, word) in ws.enumerated() {
                let jitter = Double((k * 37 + w * 11) % 160) - 80
                events.append((t + Double(k + 1) * perWord + delay + jitter, word))
            }
            spans.append((t, t + Double(ws.count) * perWord))
            t += Double(ws.count) * perWord + pause
        }
        var advance = [Double?](repeating: nil, count: script.count)
        var req: [String] = [], e = 0, sessionStart = 0.0, lastResult = 0.0, now = 0.0
        f.session()
        while now < t + 3000 {
            while e < events.count && events[e].t <= now {
                req.append(events[e].word); e += 1; lastResult = now
                f.hear(Spoken.tokens(req.joined(separator: " ")), now)
            }
            if now - sessionStart > 45000 && now - lastResult > 800 { f.session(); req = []; sessionStart = now }
            let shown = f.view(now).line
            for i in 0..<min(shown, script.count) where advance[i] == nil { advance[i] = now }
            now += 30
        }
        var ok = true
        print("\n\(Script.names[w]): line hand-over vs. the moment the reader finishes the line (− = early)")
        for i in 0..<script.count {
            let s = spans[i]
            guard let a = advance[i] else { print("  \(i + 1). NEVER ADVANCED  \(script[i][1].prefix(50))"); ok = false; continue }
            let d = (a - s.end) / 1000
            let good = a > s.start + perWord && d >= -1.6 && d <= 0.9
            if !good { ok = false }
            print(String(format: "  %2d. %+.2f s %@  %@", i + 1, d, good ? "ok " : "BAD", String(script[i][1].prefix(60))))
        }
        return ok
    }

    // Renders a few states of the prompter to PNGs so the layout can be checked without a screen.
    static func snapshot(_ dir: String) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let states: [(String, Int, Int, Double, String)] = [
            ("1-start", 0, 0, 0, "V listen · A auto · Space next"),
            ("2-deepam-reading", 1, 5, 7.6, "Listening (on this Mac)"),
            ("3-vihaan-long-line", 2, 7, 15.2, "Listening (on this Mac)"),
            ("4-done", 1, 9, 0, "Done. Stop recording."),
        ]
        for (name, who, line, said, status) in states {
            let v = PromptView(frame: NSRect(x: 0, y: 0, width: 900, height: 100))
            v.loadScript(who); v.line = line; v.said = said; v.status = status; v.voice = status.hasPrefix("Listening")
            v.frame.size.height = v.preferredHeight()
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/" + name + ".png"))
            print("wrote \(dir)/\(name).png")
        }
    }
}

let args = CommandLine.arguments
if args.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
} else if let i = args.firstIndex(of: "--snapshot") {
    SelfTest.snapshot(i + 1 < args.count ? args[i + 1] : "shots")
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
