import Foundation

// MARK: - Dual subtitles (Japanese + translation)
//
// For a Japanese caption track the player shows two lines: the Japanese sentence (with
// furigana) and its translation. YouTube's own caption translation (`tlang=`) is refused
// with HTTP 429 unless the request carries a browser proof-of-origin token, so the
// translation comes from Google Translate instead (the engine behind YouTube's).
//
// Pipeline: json3 cues → `CaptionSentences.group` (auto-generated tracks arrive as
// roll-up line fragments) → `GoogleTranslator.translate` (batched, one line per sentence)
// → `CaptionCue.translation`.

/// What the caption manager should do for a Japanese track.
public struct DualSubtitleOptions: Sendable, Equatable {
    /// Google Translate target code ("en", "zh-CN"); `nil` loads the Japanese line only.
    public var translationLanguage: String?

    public init(translationLanguage: String?) {
        self.translationLanguage = translationLanguage
    }

    /// Translation-line choices: Google Translate codes ("" = no translation line) and labels.
    public static let translationChoices: [(code: String, label: String)] = [
        ("", "Off"), ("en", "English"), ("zh-CN", "中文"),
    ]

    /// True for the tracks dual subtitles apply to (Japanese, manual or auto-generated).
    public static func applies(to track: CaptionTrack) -> Bool {
        track.languageCode == "ja" || track.languageCode.hasPrefix("ja-")
    }
}

// MARK: - json3

public enum Json3Captions {
    /// The track's URL with `fmt=json3` instead of the `fmt=vtt` the parser normally asks for.
    public static func url(for track: CaptionTrack) -> URL {
        guard var comps = URLComponents(url: track.baseURL, resolvingAgainstBaseURL: false) else {
            return track.baseURL
        }
        var items = comps.queryItems ?? []
        items.removeAll { $0.name == "fmt" }
        items.append(URLQueryItem(name: "fmt", value: "json3"))
        comps.queryItems = items
        return comps.url ?? track.baseURL
    }

    /// Parses YouTube's json3 caption format (`events[].segs[].utf8`, times in ms).
    /// Speaker-change markers (">>") are dropped; events without text are skipped.
    public static func parse(_ data: Data) -> [CaptionCue] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let events = root["events"] as? [[String: Any]]
        else { return [] }
        var cues: [CaptionCue] = []
        for ev in events {
            guard let segs = ev["segs"] as? [[String: Any]] else { continue }
            var text = segs.compactMap { $0["utf8"] as? String }.joined()
            text = text.replacingOccurrences(of: #"(^|\s)>{2,}\s*"#, with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = (ev["tStartMs"] as? Double ?? Double(ev["tStartMs"] as? Int ?? 0)) / 1000
            let dur = (ev["dDurationMs"] as? Double ?? Double(ev["dDurationMs"] as? Int ?? 0)) / 1000
            cues.append(CaptionCue(startTime: start, endTime: start + dur, text: text))
        }
        return cues.sorted { $0.startTime < $1.startTime }
    }
}

// MARK: - Sentences

public enum CaptionSentences {
    /// Joins caption lines into sentences: a sentence ends after 。！？!?, after a pause, or
    /// before it grows past `maxChars`. Each sentence lasts until the next one starts, since
    /// rolled-up lines linger on screen after they are complete.
    public static func group(_ cues: [CaptionCue], maxChars: Int = 60, pause: TimeInterval = 1.2) -> [CaptionCue] {
        var out: [CaptionCue] = []
        var start = 0.0, end = 0.0, lastEnd = 0.0, text = ""
        func flush() {
            if !text.isEmpty { out.append(CaptionCue(startTime: start, endTime: end, text: text)) }
            text = ""
        }
        for c in cues {
            if !text.isEmpty && (text.count + c.text.count > maxChars || c.startTime - lastEnd > pause) { flush() }
            if text.isEmpty { start = c.startTime; end = c.endTime }
            text += c.text
            end = max(end, c.endTime)
            lastEnd = c.endTime
            if let last = c.text.last, "。！？!?".contains(last) { flush() }
        }
        flush()
        for i in out.indices.dropLast() where out[i + 1].startTime < out[i].endTime {
            out[i] = CaptionCue(startTime: out[i].startTime, endTime: out[i + 1].startTime, text: out[i].text)
        }
        return out
    }
}

// MARK: - Google Translate

/// Google Translate's keyless web endpoint (`translate_a/single?client=gtx`). Lines are sent
/// joined by newlines, which the endpoint keeps, so line *i* of the answer translates line *i*.
public actor GoogleTranslator {
    public static let shared = GoogleTranslator()

    private let session: URLSession
    private var cache: [String: [String]] = [:]
    /// Characters per request; the endpoint takes a few thousand comfortably.
    private let batchLimit = 3500

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Translates `lines` (one sentence each) from `source` to `target`; the result has the
    /// same count and order. Throws when the endpoint fails.
    public func translate(_ lines: [String], from source: String = "ja", to target: String) async throws -> [String] {
        let key = "\(source)>\(target)\n" + lines.joined(separator: "\n")
        if let hit = cache[key] { return hit }
        var result: [String] = []
        var batch: [String] = []
        var size = 0
        for line in lines {
            if !batch.isEmpty && size + line.count > batchLimit {
                result += try await translateBatch(batch, source, target)
                batch = []
                size = 0
            }
            batch.append(line)
            size += line.count + 1
        }
        if !batch.isEmpty { result += try await translateBatch(batch, source, target) }
        if cache.count > 20 { cache.removeAll() }
        cache[key] = result
        return result
    }

    private func translateBatch(_ lines: [String], _ source: String, _ target: String) async throws -> [String] {
        // Newlines inside a line would shift the alignment; captions are single-line already.
        let clean = lines.map { $0.replacingOccurrences(of: "\n", with: " ") }
        let out = try await request(clean.joined(separator: "\n"), source, target).components(separatedBy: "\n")
        if out.count == clean.count { return out.map { $0.trimmingCharacters(in: .whitespaces) } }
        // The endpoint merged or split a line: fall back to one request per line.
        var each: [String] = []
        for line in clean { each.append(try await request(line, source, target).trimmingCharacters(in: .whitespacesAndNewlines)) }
        return each
    }

    private func request(_ text: String, _ source: String, _ target: String) async throws -> String {
        var comps = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        comps.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: source),
            URLQueryItem(name: "tl", value: target),
            URLQueryItem(name: "dt", value: "t"),
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
        var form = CharacterSet.alphanumerics
        form.insert(charactersIn: "-._*")
        req.httpBody = Data(("q=" + (text.addingPercentEncoding(withAllowedCharacters: form) ?? "")).utf8)
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return Self.parseResponse(data)
    }

    /// `[[["translated","source",…],…],…]` → the translated pieces concatenated.
    static func parseResponse(_ data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
            let parts = root.first as? [Any]
        else { return "" }
        return parts.compactMap { ($0 as? [Any])?.first as? String }.joined()
    }
}

// MARK: - Furigana

/// A run of caption text; `reading` (hiragana) is set for runs that contain kanji.
public struct FuriganaSegment: Sendable, Equatable {
    public let text: String
    public let reading: String?

    public init(text: String, reading: String? = nil) {
        self.text = text
        self.reading = reading
    }
}

public enum Furigana {
    /// Splits Japanese text into word-sized runs (the renderer wraps lines between them),
    /// with readings, using the system's Japanese tokenizer
    /// (CFStringTokenizer's Latin transcription, turned back into hiragana). Kana shared by a
    /// word and its reading at either end (食べる / たべる) stays outside the reading.
    public static func segments(_ text: String) -> [FuriganaSegment] {
        let ns = text as NSString
        let cf = text as CFString
        let tokenizer = CFStringTokenizerCreate(
            nil, cf, CFRangeMake(0, ns.length), kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale)
        var out: [FuriganaSegment] = []
        var pos = 0
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if r.location > pos { out.append(FuriganaSegment(text: ns.substring(with: NSRange(location: pos, length: r.location - pos)))) }
            let surface = ns.substring(with: NSRange(location: r.location, length: r.length))
            let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
            out += annotate(surface, reading: latin.map(hiragana(fromLatin:)))
            pos = r.location + r.length
        }
        if pos < ns.length { out.append(FuriganaSegment(text: ns.substring(from: pos))) }
        return out
    }

    static func hasKanji(_ s: Substring) -> Bool { s.unicodeScalars.contains(where: isKanji) }
    static func hasKanji(_ s: String) -> Bool { s.unicodeScalars.contains(where: isKanji) }

    static func isKanji(_ u: Unicode.Scalar) -> Bool {
        (0x3400...0x9FFF).contains(u.value) || (0xF900...0xFAFF).contains(u.value) || u == "々" || u == "〆" || u == "ヶ"
    }

    /// Romaji (with macrons, as the tokenizer writes long vowels) → hiragana.
    /// Long vowels become the usual spelling: ō→おう, ū→うう, ē→えい, ā→ああ, ī→いい.
    static func hiragana(fromLatin latin: String) -> String {
        var s = latin.lowercased()
        for (m, r) in [("ō", "ou"), ("ū", "uu"), ("ē", "ei"), ("ā", "aa"), ("ī", "ii"), ("ô", "ou"), ("û", "uu"), ("ê", "ei"), ("â", "aa"), ("î", "ii")] {
            s = s.replacingOccurrences(of: m, with: r)
        }
        let m = NSMutableString(string: s)
        CFStringTransform(m, nil, kCFStringTransformLatinHiragana, false)
        return (m as String).replacingOccurrences(of: "'", with: "")
    }

    static func toHiragana(_ s: String) -> String {
        let m = NSMutableString(string: s)
        CFStringTransform(m, nil, kCFStringTransformHiraganaKatakana, true)
        return m as String
    }

    static func annotate(_ surface: String, reading: String?) -> [FuriganaSegment] {
        guard hasKanji(surface), let reading, !reading.isEmpty,
            reading.unicodeScalars.allSatisfy({ (0x3040...0x309F).contains($0.value) || $0 == "ー" })
        else { return [FuriganaSegment(text: surface)] }
        var s = Array(surface), r = Array(reading)
        var head = "", tail = ""
        while let a = s.last, let b = r.last, !hasKanji(String(a)), toHiragana(String(a)) == String(b) {
            tail = String(a) + tail
            s.removeLast()
            r.removeLast()
        }
        while let a = s.first, let b = r.first, !hasKanji(String(a)), toHiragana(String(a)) == String(b) {
            head += String(a)
            s.removeFirst()
            r.removeFirst()
        }
        guard !s.isEmpty, !r.isEmpty else { return [FuriganaSegment(text: surface)] }
        var out: [FuriganaSegment] = []
        if !head.isEmpty { out.append(FuriganaSegment(text: head)) }
        out.append(FuriganaSegment(text: String(s), reading: String(r)))
        if !tail.isEmpty { out.append(FuriganaSegment(text: tail)) }
        return out
    }
}
