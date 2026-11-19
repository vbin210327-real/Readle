import SwiftUI
import AVFoundation
import CryptoKit
import NaturalLanguage
import ReadleSpeechRuntime
import MediaPlayer

// A fixed Kokoro v1.0 export: af_heart is speaker 3 in the upstream voice table.
// Keep only that speaker's 510 x 256 float32 style vectors on disk.
actor HeartModel {
    static let revision = "57adb37fc0e8d4bd430cfc1b8f8c2294945b9af2"
    private static let timedModelHash = "9af45c8a1fe1d60f6647cd96ddace4684fe81ae7cdead5faec16f0af53816ec2"
    private static let timedModelSize = 114203308
    private static let derivedModelHash = "cb409296b3e538be794e00da27a4a6c734e939aad9f02c7f7ca5106a1e05cab0"
    static let heartHash = "d583ccff3cdca2f7fae535cb998ac07e9fcb90f09737b9a41fa2734ec44a8f0b"
    static let voiceBytes = 510 * 256 * 4
    static let files: [(String, Int, String)] = [
        ("model.int8.onnx", 114202993, "75635ea3b85a32d00094dcdd61a258aba87c160f7c264c304a7b3ae9d734195e"),
        ("tokens.txt", 687, "6ebb6bb288f20f3ae8d004d3c2ca27697da27c037d75e81a60e2a6a663f95425"),
        ("lexicon-us-en.txt", 5956885, "7daaab53a181be9885b853a8582bf1838186317e5dadacbcef9c426d6fa0da14"),
        ("voices.bin", 28200960, "1c5a5b983d3d50d8586d437a51f3faa2da7919ce76a013c081e65671a3447c29"),
        ("espeak-ng-data/phondata", 550424, "4e0288957874029a8c3c9f41a8f517ad4bf18127046decbdd4b9d1d6807ce3a3"),
        ("espeak-ng-data/phonindex", 39074, "3ca7b8fa3b42624e4b0f152707e7a39245fce569aa99ea47c055d9e622fcf0c4"),
        ("espeak-ng-data/phontab", 55796, "886f3fa402cb0ba73d483aa8ad000af47a6b7cc06293c75a97913fba68a530f6"),
        ("espeak-ng-data/intonations", 2040, "3f8af65fd3eda9759a10f021d61361c120871f463515229c925995c7f90918cc"),
        ("espeak-ng-data/en_dict", 166944, "71bd330ba8a2e3e8076e631508208ef49449d6147c17b7bd2b4b1e1468292e35"),
        ("espeak-ng-data/lang/gmw/en", 140, "4605d5330801de3641c6e366d15f129ea1f5ffbce8722642aba01ace07ab9c83"),
        ("espeak-ng-data/lang/gmw/en-US", 257, "41534c2a22df5dd4f1052ff9e1a33a3ea7bff5a26b5c02bdad5ba8ddb7524704")
    ]
    /// The voice ships inside the app, ready to use; downloading it is only a fallback for a build
    /// without it.
    static let bundled: URL? = {
        guard let url = Bundle.main.url(forResource: "KokoroHeart", withExtension: nil),
              bundledFiles.allSatisfy({ FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }),
              (try? url.appendingPathComponent("model.int8.onnx").resourceValues(forKeys: [.fileSizeKey]).fileSize) == timedModelSize,
              (try? url.appendingPathComponent("voices.bin").resourceValues(forKeys: [.fileSizeKey]).fileSize) == 2 * voiceBytes
        else { return nil }
        // An earlier download is no longer needed: free its space.
        let old = downloaded
        if FileManager.default.fileExists(atPath: old.path) {
            Task.detached(priority: .background) { try? FileManager.default.removeItem(at: old) }
        }
        return url
    }()
    static var downloaded: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KokoroHeart", isDirectory: true)
    }
    /// The built-in voice reads both languages: Heart (speaker 0) for English, xiaoyi (speaker 1)
    /// for Chinese, with the Chinese word splitter and pronunciation rules alongside.
    private static let bundledFiles = ["model.int8.onnx", "voices.bin", "tokens.txt", "lexicon-us-en.txt", "lexicon-zh.txt",
                                       "espeak-ng-data", "dict/jieba.dict.utf8", "dict/hmm_model.utf8", "dict/user.dict.utf8",
                                       "dict/idf.utf8", "dict/stop_words.utf8", "date-zh.fst", "number-zh.fst", "phone-zh.fst"]
    static var speaksChinese: Bool { bundled != nil }
    /// Which voice reads `text`.
    static func speaker(for text: String) -> Int32 { speaksChinese && ReadAloud.isChinese(text) ? 1 : 0 }
    static var directory: URL { bundled ?? downloaded }
    static var ready: Bool { bundled != nil || complete(downloaded) }
    private static func complete(_ directory: URL) -> Bool {
        files.allSatisfy { name, size, _ in
            let url = directory.appendingPathComponent(name == "voices.bin" ? "heart.bin" : name)
            let installed = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            if name == "model.int8.onnx" { return installed == timedModelSize || installed == size - 1 }
            return installed == (name == "voices.bin" ? voiceBytes : size)
        }
    }
    func install(status: @escaping @Sendable (String) async -> Void) async throws {
        guard Self.bundled == nil else { return }
        var directory = Self.downloaded
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        for (index, file) in Self.files.enumerated() {
            try Task.checkCancellation()
            let (name, size, digest) = file
            let target = directory.appendingPathComponent(name == "voices.bin" ? "heart.bin" : name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Finished files are reusable after cancellation; downloads never replace a valid file.
            if name == "model.int8.onnx", (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Self.timedModelSize,
               try Self.hash(target) == Self.timedModelHash { continue }
            if name == "model.int8.onnx", (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) == size - 1,
               try Self.hash(target) == Self.derivedModelHash { continue }
            if name == "voices.bin", (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Self.voiceBytes,
               try Self.hash(target) == Self.heartHash { continue }
            if name != "voices.bin", (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) == size,
               try Self.hash(target) == digest { continue }
            await status("正在下载声音 · \(index + 1)/\(Self.files.count)")
            let url = URL(string: "https://huggingface.co/csukuangfj/kokoro-int8-multi-lang-v1_0/resolve/\(Self.revision)/\(name)")!
            var request = URLRequest(url: url); request.timeoutInterval = 300
            let (temporary, response) = try await URLSession.shared.download(for: request)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  (try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) == size,
                  try Self.hash(temporary) == digest else { throw BookError.invalid("声音文件校验失败，请重试下载。") }
            try Task.checkCancellation()
            if name == "voices.bin" {
                let handle = try FileHandle(forReadingFrom: temporary); defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(3 * Self.voiceBytes))
                guard let data = try handle.read(upToCount: Self.voiceBytes), data.count == Self.voiceBytes else { throw BookError.invalid("声音数据不完整。") }
                try data.write(to: target, options: .atomic)
            } else {
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: temporary, to: target)
            }
        }
        try Self.prepareModel()
    }
    // The pinned graph already returns phone durations. Put those durations and the input
    // token IDs before the PCM in output 0, the only tensor exposed by sherpa's TTS API.
    // The render callback strips this header before any samples reach the player.
    private static func prepareModel() throws {
        let url = downloaded.appendingPathComponent("model.int8.onnx")
        let fingerprint = try hash(url)
        if fingerprint == timedModelHash { return }
        let source = try Data(contentsOf: url, options: .mappedIfSafe)
        var model: Data
        switch fingerprint {
        case files[0].2:
            model = source
            // Specialize the speaker metadata from 54 to 1 for heart.bin.
            model.replaceSubrange(114200681..<114200699, with:
                Data([0x72, 0x0f, 0x0a, 0x0a]) + Data("n_speakers".utf8) + Data([0x12, 0x01, 0x31]))
        case derivedModelHash:
            model = source
        default:
            try? FileManager.default.removeItem(at: url)
            throw BookError.invalid("离线声音版本不匹配，请重新下载。")
        }
        model.replaceSubrange(113838316..<113838321, with: "sound".utf8)
        let nodes = timingNodes()
        model.insert(contentsOf: nodes, at: 114200462)
        var size = 114200433 + nodes.count
        var encodedSize: [UInt8] = []
        while size >= 128 {
            encodedSize.append(UInt8(size & 127) | 128)
            size >>= 7
        }
        encodedSize.append(UInt8(size))
        model.replaceSubrange(25..<29, with: encodedSize)
        let digest = SHA256.hash(data: model).map { String(format: "%02x", $0) }.joined()
        guard model.count == timedModelSize, digest == timedModelHash else {
            throw BookError.invalid("离线声音校验失败，请重新下载。")
        }
        try model.write(to: url, options: .atomic)
    }

    /// ONNX GraphProto nodes for the timing header. The original audio tensor is untouched.
    private static func timingNodes() -> Data {
        func field(_ tag: UInt8, _ bytes: Data) -> Data {
            // All fields here are shorter than one protobuf length byte.
            Data([tag, UInt8(bytes.count)]) + bytes
        }
        func name(_ tag: UInt8, _ value: String) -> Data { field(tag, Data(value.utf8)) }
        func node(_ op: String, _ inputs: [String], _ output: String, attribute: (String, UInt8)? = nil) -> Data {
            var body = inputs.reduce(into: Data()) { $0 += name(0x0a, $1) }
            body += name(0x12, output) + name(0x22, op)
            if let (key, value) = attribute {
                body += field(0x2a, name(0x0a, key) + Data([0x18, value, 0xa0, 0x01, 0x02]))
            }
            return field(0x0a, body)
        }
        let durations = "onnx::Shape_3411"
        return node("Squeeze", ["tokens"], "readle_token_ids")
            + node("Cast", ["readle_token_ids"], "readle_tokens", attribute: ("to", 1))
            + node("Cast", [durations], "readle_durations", attribute: ("to", 1))
            + node("Shape", [durations], "readle_shape")
            + node("Cast", ["readle_shape"], "readle_count", attribute: ("to", 1))
            + node("Concat", ["readle_count", "readle_tokens", "readle_durations", "audio"], "sound", attribute: ("axis", 0))
    }
    // Hashing ~150 MB takes many seconds on a phone. Re-hash only when a file's size or
    // modification date changed since the last successful check.
    private static var installedSignature: String {
        files.map { name, _, _ in
            let url = directory.appendingPathComponent(name == "voices.bin" ? "heart.bin" : name)
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(name):\(values?.fileSize ?? -1):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
    }
    static func verifyInstalledFiles() throws {
        if bundled != nil { return } // inside the app, protected by its code signature
        let model = directory.appendingPathComponent("model.int8.onnx")
        if (try? model.resourceValues(forKeys: [.fileSizeKey]).fileSize) != timedModelSize {
            try prepareModel()
        }
        let signature = installedSignature
        if UserDefaults.standard.string(forKey: "heartVerifiedSignature") == signature { return }
        for (name, _, expected) in files {
            let url = directory.appendingPathComponent(name == "voices.bin" ? "heart.bin" : name)
            let digest = name == "model.int8.onnx" ? timedModelHash : (name == "voices.bin" ? heartHash : expected)
            guard try hash(url) == digest else {
                try? FileManager.default.removeItem(at: url)
                throw BookError.invalid("声音文件已损坏，请再次点击朗读以修复下载。")
            }
        }
        UserDefaults.standard.set(signature, forKey: "heartVerifiedSignature")
    }
    private static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

final class SpeechCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

actor HeartEngine {
    // One loaded model per process: sentence playback and book listening share it.
    static let shared = HeartEngine()
    private var engine: OpaquePointer?
    private var phonemeIDs: [Unicode.Scalar: Int] = [:]
    private var mandarinPronunciation: [Character: [Int]]?
    private let cacheLimit = 64 * 1024 * 1024
    private var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeartSpeech-v1", isDirectory: true)
    }
    private func cacheURL(for text: String) -> URL {
        cacheDirectory.appendingPathComponent(BookAudio.clipName(text)).appendingPathExtension("wav")
    }
    private func cachedAudio(for text: String) -> Data? {
        let url = cacheURL(for: text)
        guard let data = try? Data(contentsOf: url), data.count > 44,
              data.prefix(4) == Data("RIFF".utf8), data.subdata(in: 8..<12) == Data("WAVE".utf8) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }
    private func cache(_ data: Data, for text: String) {
        guard data.count <= cacheLimit else { return }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: cacheURL(for: text), options: .atomic)
            for name in BookAudio.previousClipNames(text) {
                try? manager.removeItem(at: cacheDirectory.appendingPathComponent(name).appendingPathExtension("wav"))
            }
            let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
            let entries = try manager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: Array(keys))
                .compactMap { url -> (URL, Int, Date)? in
                    guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
                    return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
                }.sorted { $0.2 < $1.2 }
            var total = entries.reduce(0) { $0 + $1.1 }
            for (url, size, _) in entries where total > cacheLimit {
                try? manager.removeItem(at: url)
                total -= size
            }
        } catch { /* Playback still works when the cache cannot be written. */ }
    }
    deinit { if let engine { SherpaOnnxDestroyOfflineTts(engine) } }
    /// Load the model ahead of time so the first sentence of a long job doesn't stall.
    func warmUp() throws { try loadEngine() }

    func renderForTiming(_ text: String, legacyCadence: Bool) throws -> Data {
        if !legacyCadence, let data = cachedAudio(for: text), WordTiming.hasMetadata(in: data, text: text) { return data }
        guard HeartModel.ready else { throw BookError.invalid("离线声音尚未安装。") }
        return try render(text, cancellation: SpeechCancellation(), cache: false, legacyCadence: legacyCadence)
    }
    private func loadEngine() throws {
        guard engine == nil else { return }
        try HeartModel.verifyInstalledFiles()
        phonemeIDs = Self.loadPhonemeIDs()
        engine = Self.makeEngine(threads: 2, provider: "cpu")
    }
    private static func makeEngine(threads: Int32, provider: String) -> OpaquePointer? {
        let root = HeartModel.directory, chinese = HeartModel.speaksChinese
        func path(_ name: String) -> String { root.appendingPathComponent(name).path }
        let strings = [path("model.int8.onnx"), path(chinese ? "voices.bin" : "heart.bin"), path("tokens.txt"),
                       chinese ? path("lexicon-us-en.txt") + "," + path("lexicon-zh.txt") : path("lexicon-us-en.txt"),
                       path("espeak-ng-data"), chinese ? path("dict") : "",
                       chinese ? ["date-zh.fst", "phone-zh.fst", "number-zh.fst"].map(path).joined(separator: ",") : ""]
            .map { (value: String) -> UnsafeMutablePointer<CChar>? in strdup(value) }
        let providerName = strdup(provider), lang = strdup("en-us")
        defer { strings.forEach { free($0) }; free(providerName); free(lang) }
        var config = SherpaOnnxOfflineTtsConfig()
        config.model.kokoro.model = UnsafePointer(strings[0])
        config.model.kokoro.voices = UnsafePointer(strings[1])
        config.model.kokoro.tokens = UnsafePointer(strings[2])
        config.model.kokoro.lexicon = UnsafePointer(strings[3])
        config.model.kokoro.data_dir = UnsafePointer(strings[4])
        if chinese {
            config.model.kokoro.dict_dir = UnsafePointer(strings[5])
            config.rule_fsts = UnsafePointer(strings[6])
        }
        config.model.kokoro.lang = UnsafePointer(lang)
        config.model.kokoro.length_scale = 1
        config.model.num_threads = threads; config.model.provider = UnsafePointer(providerName)
        config.max_num_sentences = 1; config.silence_scale = 0.2
        return SherpaOnnxCreateOfflineTts(&config)
    }
    #if DEBUG
    /// Developer benchmark (launch argument -ReadleBenchmark): compares engine settings on this device.
    func benchmark(_ log: @escaping @Sendable (String) async -> Void) async {
        guard HeartModel.ready else { await log("bench: Heart not installed"); return }
        let texts = [
            "The morning was quiet, and the river moved slowly under the old stone bridge.",
            "He wrote down the colors of the sky, one after another, as the sun began to rise.",
            "Essentialism is not about how to get more things done; it is about how to get the right things done.",
            "By noon, the town was full of noise and light, and children ran past the bookshop.",
            "If you don't prioritize your life, someone else will, and you may not like their choices.",
            "The man closed his notebook and smiled, because some days are worth remembering."
        ]
        if HeartModel.speaksChinese {
            // The Chinese voice, through the same path the reader uses, saved for listening.
            let started = Date()
            let sample = "清晨的旧书店里，阳光落在一排排书脊上。她翻开那本发黄的小说，第一句话就让她停了下来：所有的故事，都从一个安静的早晨开始。"
            do {
                let data = try render(sample, cancellation: SpeechCancellation(), cache: false)
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("zh-sample.wav")
                try data.write(to: url)
                await log(String(format: "bench zh: %d bytes in %.1fs, timed %@", data.count, Date().timeIntervalSince(started),
                                 WordTiming.hasMetadata(in: data, text: sample) ? "yes" : "no"))
            } catch { await log("bench zh: failed \(error.localizedDescription)") }
        }
        await log("bench: start, thermal \(ProcessInfo.processInfo.thermalState.rawValue)")
        for (provider, threads) in [("cpu", Int32(2)), ("cpu", 3), ("cpu", 4), ("cpu", 6), ("coreml", 2)] {
            let created = Date()
            guard let engine = Self.makeEngine(threads: threads, provider: provider) else {
                await log("bench \(provider) x\(threads): could not create engine"); continue
            }
            let load = Date().timeIntervalSince(created)
            _ = Self.generate(engine, "Warm up the engine.")
            let started = Date()
            var seconds = 0.0
            for text in texts { seconds += Self.generate(engine, text) }
            let elapsed = Date().timeIntervalSince(started)
            SherpaOnnxDestroyOfflineTts(engine)
            await log(String(format: "bench %@ x%d: load %.1fs, %.1fs to make %.1fs of audio = %.2fx realtime, thermal %d",
                             provider, threads, load, elapsed, seconds, seconds / max(elapsed, 0.001), ProcessInfo.processInfo.thermalState.rawValue))
        }
        await log("bench: done")
    }
    private static func generate(_ engine: OpaquePointer, _ text: String) -> Double {
        var config = SherpaOnnxGenerationConfig()
        config.speed = 1; config.sid = 0; config.silence_scale = 1
        let audio = text.withCString { SherpaOnnxOfflineTtsGenerateWithConfig(engine, $0, &config, { _, _, _, _ in 1 }, nil) }
        guard let audio else { return 0 }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
        return Double(audio.pointee.n) / Double(max(audio.pointee.sample_rate, 1))
    }
    #endif
    func render(_ text: String, cancellation: SpeechCancellation, cache useCache: Bool = true,
                legacyCadence: Bool = false) throws -> Data {
        try Task.checkCancellation()
        guard !cancellation.cancelled else { throw CancellationError() }
        if useCache, !legacyCadence, let data = cachedAudio(for: text), WordTiming.hasMetadata(in: data, text: text) { return data }
        try loadEngine()
        guard let engine, SherpaOnnxOfflineTtsNumSpeakers(engine) >= 1 else { throw BookError.invalid("离线声音加载失败，请重新下载声音。") }
        let speaker = HeartModel.speaker(for: text)
        let chinese = ReadAloud.isChinese(text)
        if speaker == 1, mandarinPronunciation == nil {
            mandarinPronunciation = Self.loadMandarinPronunciation(using: phonemeIDs)
        }
        let naturalCadence = !legacyCadence && BookAudio.usesNewCadence(text)
        let chunks: [String]
        if naturalCadence {
            chunks = chinese ? Self.mandarinNarrationPieces(text) : Self.englishNarrationPieces(text)
        } else {
            chunks = Self.pieces(text, limit: chinese ? 60 : 160)
        }
        var samples: [Float] = []
        var starts: [Int] = []
        var rate: Int32 = 24000
        var completeTiming = true
        for (index, piece) in chunks.enumerated() {
            try Task.checkCancellation()
            let rendered = try Self.generate(engine, piece, cancellation, phonemeIDs: phonemeIDs, speaker: speaker,
                                             mandarin: chinese ? mandarinPronunciation : nil)
            rate = rendered.rate
            var slice = rendered.samples.indices
            if naturalCadence, chunks.count > 1 {
                let before = index > 0 ? Self.pauseAtJoin(after: chunks[index - 1]) : nil
                let after = index + 1 < chunks.count ? Self.pauseAtJoin(after: piece) : nil
                slice = Self.trimJoinSilence(rendered.samples, leading: before, trailing: after)
            }
            if let times = rendered.starts {
                starts += times.map { max(0, $0 - slice.lowerBound) + samples.count }
            } else {
                completeTiming = false
            }
            samples += rendered.samples[slice]
        }
        let timed = completeTiming && starts.count == WordTiming.units(text).count && !starts.isEmpty
        let metadataBytes = timed ? starts.count * 4 : 0
        guard !cancellation.cancelled else { throw CancellationError() }
        guard !samples.isEmpty else { throw BookError.invalid("没有生成朗读音频，请重试。") }
        let count = samples.count, sampleRate = UInt32(rate)
        var data = Data(capacity: 52 + count * 2 + metadataBytes)
        func bytes(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        bytes("RIFF"); u32(UInt32(44 + count * 2 + metadataBytes)); bytes("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16); bytes("data"); u32(UInt32(count * 2))
        var peak: Float = 0
        for value in samples {
            let sample = value.isFinite ? max(-1, min(1, value)) : 0
            peak = max(peak, abs(sample)); u16(UInt16(bitPattern: Int16(sample * 32767)))
        }
        guard peak > 0.0001 else { throw BookError.invalid("未生成有效声音，请重试。") }
        bytes(WordTiming.chunkName(for: text)); u32(UInt32(metadataBytes))
        if timed { for start in starts { u32(UInt32(start)) } }
        if useCache, !legacyCadence { cache(data, for: text) }
        return data
    }

    private static func generate(_ engine: OpaquePointer, _ text: String, _ cancellation: SpeechCancellation,
                                 phonemeIDs: [Unicode.Scalar: Int], speaker: Int32 = 0,
                                 mandarin: [Character: [Int]]? = nil) throws
        -> (samples: [Float], rate: Int32, starts: [Int]?) {
        var config = SherpaOnnxGenerationConfig()
        // The timing header is stripped before shortening pauses in the actual waveform.
        config.speed = 1; config.sid = speaker; config.silence_scale = 1
        let collector = TimedHeartAudio(cancellation: cancellation)
        let opaque = Unmanaged.passUnretained(collector).toOpaque()
        let audio = text.withCString { pointer in
            SherpaOnnxOfflineTtsGenerateWithConfig(engine, pointer, &config, { samples, count, _, raw in
                guard let raw, let samples, count > 0 else { return 0 }
                let collector = Unmanaged<TimedHeartAudio>.fromOpaque(raw).takeUnretainedValue()
                if collector.cancellation.cancelled || Task.isCancelled { return 0 }
                return collector.append(UnsafeBufferPointer(start: samples, count: Int(count))) ? 1 : 0
            }, opaque)
        }
        guard let audio else { throw BookError.invalid("没有生成朗读音频，请重试。") }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
        guard !cancellation.cancelled else { throw CancellationError() }
        let rate = audio.pointee.sample_rate
        guard !collector.failed, rate == 24000, !collector.samples.isEmpty else {
            throw BookError.invalid("音频时间戳无效，请重试。")
        }
        let units = WordTiming.units(text)
        let aligned = align(words: units, to: collector.phones, using: phonemeIDs, mandarin: mandarin)
        let starts = aligned ?? (collector.starts.count == units.count ? collector.starts : nil)
        return (collector.samples, rate, starts.map { refinePauseBoundaries($0, samples: collector.samples) })
    }

    private static func loadMandarinPronunciation(using ids: [Unicode.Scalar: Int]) -> [Character: [Int]] {
        let url = HeartModel.directory.appendingPathComponent("lexicon-zh.txt")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [Character: [Int]] = [:]
        source.enumerateLines { line, _ in
            guard let character = line.first, line.dropFirst().first == " " else { return }
            // Ignore tones in the reference so contextual changes such as 你好 still match.
            let phonemes = line.dropFirst(2).unicodeScalars.compactMap { ids[$0] }
            if !phonemes.isEmpty { result[character] = phonemes }
        }
        return result
    }

    /// The decoder can start making audible sound slightly before a duration boundary.
    /// Use the actual waveform where a quiet pause gives a clear, nearby onset.
    private static func refinePauseBoundaries(_ starts: [Int], samples: [Float]) -> [Int] {
        let frame = 120 // 5 ms at 24 kHz
        let count = samples.count / frame
        guard count > 3 else { return starts }
        let gate: Float = 0.003
        let audible = (0..<count).map { index in
            let start = index * frame
            let energy = samples[start..<(start + frame)].reduce(Float.zero) { $0 + $1 * $1 }
            return energy >= gate * gate * Float(frame)
        }
        var quiet = 8
        var edges: [Int] = []
        for index in 0..<(count - 2) {
            if audible[index] {
                if quiet >= 8, audible[index + 1], audible[index + 2] { edges.append(index * frame) }
                quiet = 0
            } else { quiet += 1 }
        }
        return starts.enumerated().map { index, start in
            let before = index > 0 ? (starts[index - 1] + start) / 2 : -1
            let after = index + 1 < starts.count ? (starts[index + 1] + start) / 2 : samples.count
            return edges.filter { $0 > before && $0 < after && $0 >= start - 2400 && $0 <= start + 1200 }
                .min { abs($0 - start) < abs($1 - start) } ?? start
        }
    }

    private static func loadPhonemeIDs() -> [Unicode.Scalar: Int] {
        let url = HeartModel.directory.appendingPathComponent("tokens.txt")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var ids: [Unicode.Scalar: Int] = [:]
        for line in source.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ")
            guard fields.count == 2, let value = Int(fields[1]), value >= 17,
                  fields[0].unicodeScalars.count == 1, let scalar = fields[0].unicodeScalars.first,
                  scalar.properties.isAlphabetic, !"ˈˌːˑ".unicodeScalars.contains(scalar) else { continue }
            ids[scalar] = value
        }
        return ids
    }

    /// Match the independent pronunciation of each written word to the actual input phones.
    /// The model supplies sample positions, including for words eSpeak joined or expanded.
    private static func align(words: [Substring], to spoken: [TimedHeartAudio.Phone],
                              using ids: [Unicode.Scalar: Int], mandarin: [Character: [Int]]?) -> [Int]? {
        guard !words.isEmpty, !ids.isEmpty else { return nil }
        let known = Set(ids.values)
        let actual = spoken.filter { known.contains($0.id) }
        guard !actual.isEmpty else { return nil }
        var expected: [(id: Int, word: Int)] = []
        for (index, word) in words.enumerated() {
            let text = String(word)
            let phones: [Int]
            if ReadAloud.isChinese(text) {
                guard let mandarin else { return nil }
                let parts = word.compactMap { mandarin[$0] }
                guard parts.count == word.count else { return nil }
                phones = parts.flatMap { $0 }
            } else if let mandarin, word.contains(where: \.isNumber),
                      word.allSatisfy({ $0.isNumber || ".,:．：，".contains($0) }) {
                let digits = Array("零一二三四五六七八九")
                phones = word.compactMap { character -> [Int]? in
                    if let value = character.wholeNumberValue, digits.indices.contains(value) {
                        return mandarin[digits[value]]
                    }
                    return ".:．：".contains(character) ? mandarin["点"] : nil
                }.flatMap { $0 }
            } else {
                phones = text.withCString { string in
                    var next: UnsafeRawPointer? = UnsafeRawPointer(string)
                    var result: [Int] = []
                    while let previous = next {
                        // eSpeak NG's espeakCHARS_UTF8 and espeakPHONEMES_IPA flags.
                        guard let ipa = espeak_TextToPhonemes(&next, 1, 2), next != previous else { break }
                        result += String(cString: ipa).unicodeScalars.compactMap { ids[$0] }
                    }
                    return result
                }
            }
            guard !phones.isEmpty else { return nil }
            expected += phones.map { ($0, index) }
        }
        let n = expected.count, m = actual.count
        guard n <= 2048, m <= 2048 else { return nil }
        let width = m + 1
        enum Step: UInt8 { case match, insert, delete }
        var path = [Step](repeating: .match, count: (n + 1) * width)
        var previous = (0...m).map { 2 * $0 }
        var row = [Int](repeating: 0, count: width)
        for i in 1...n {
            row[0] = i * 2
            for j in 1...m {
                let equal = expected[i - 1].id == actual[j - 1].id
                let match = previous[j - 1] + (equal ? 0 : 3)
                let insert = row[j - 1] + 2
                let delete = previous[j] + 2
                if match <= insert, match <= delete {
                    row[j] = match
                } else if insert <= delete {
                    row[j] = insert; path[i * width + j] = .insert
                } else {
                    row[j] = delete; path[i * width + j] = .delete
                }
            }
            swap(&previous, &row)
        }

        var onset = [Int?](repeating: nil, count: words.count)
        var i = n, j = m, matches = 0
        while i > 0, j > 0 {
            switch path[i * width + j] {
            case .match:
                i -= 1; j -= 1
                onset[expected[i].word] = actual[j].sample
                if expected[i].id == actual[j].id { matches += 1 }
            case .insert: j -= 1
            case .delete: i -= 1
            }
        }
        let starts = onset.compactMap { $0 }
        guard matches * 4 >= max(n, m) * 3, starts.count == words.count else { return nil }
        return starts
    }

    /// eSpeak also supplies Kokoro's inputs. Estimate its phoneme count with headroom
    /// for punctuation and number expansion before going near the model's 510-token limit.
    private static func englishNarrationPieces(_ text: String) -> [String] {
        guard text.unicodeScalars.allSatisfy({
            $0.isASCII || (0x00c0...0x024f).contains($0.value) || (0x0300...0x036f).contains($0.value)
                || "“”‘’—–… ".unicodeScalars.contains($0)
        }), espeak_SetVoiceByName("en-us") == 0
        else { return pieces(text) }

        let words = text.split(whereSeparator: \.isWhitespace)
        var start = 0
        var result: [String] = []
        while start < words.count {
            var end = start
            var characters = 0
            while end < words.count, characters + words[end].count + 1 <= 440 {
                characters += words[end].count + 1
                end += 1
            }
            if start == end {
                result += pieces(String(words[start]))
                start += 1
                continue
            }

            func phrase(through end: Int) -> String { words[start..<end].joined(separator: " ") }
            if englishPhonemeBudget(phrase(through: end)) > 390 {
                var low = start, high = end
                while high - low > 1 {
                    let middle = (low + high) / 2
                    if englishPhonemeBudget(phrase(through: middle)) <= 390 { low = middle }
                    else { high = middle }
                }
                end = low
            }
            if end == start {
                result += pieces(String(words[start]))
                start += 1
                continue
            }

            // When a cut is needed, back up to a nearby punctuation break. Keep
            // abbreviations and numbers together because candidates end at word boundaries.
            if end < words.count {
                let earliest = start + max(1, (end - start) * 2 / 3)
                if let boundary = (earliest...end).reversed().first(where: {
                    let word = words[$0 - 1].drop(while: { #""“‘("#.contains($0) })
                    return word.count > 1 && ",;:—!?".contains(word.last ?? " ")
                }) {
                    end = boundary
                }
            }
            result.append(phrase(through: end))
            start = end
        }
        return result
    }

    private static func englishPhonemeBudget(_ text: String) -> Int {
        var count = text.filter(\.isNumber).count * 4 + 12
        return text.withCString { string in
            var next: UnsafeRawPointer? = UnsafeRawPointer(string)
            while let previous = next {
                guard let ipa = espeak_TextToPhonemes(&next, 1, 2), next != previous else { break }
                count += String(cString: ipa).unicodeScalars.count + 4
                if count > 390 { break }
            }
            return count
        }
    }

    /// At a forced join, keep the natural punctuation pause and cap the silence
    /// introduced by the two separate renders. Values are per side, at 24 kHz.
    private static func pauseAtJoin(after text: String) -> Int {
        let last = text.last { !#""”’）)」』》 】"#.contains($0) }
        switch last {
        case ".", "!", "?", "。", "！", "？": return 2_400
        case ";", ":", "；", "：", "—", "–", "…": return 1_560
        case ",", "，", "、": return 1_080
        default: return 360
        }
    }

    /// The bundled Mandarin lexicon uses at most six input tokens per Han character.
    /// Reserve extra room for normalization of numbers and mixed Latin text.
    private static func mandarinNarrationPieces(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.simplifiedChinese)
        tokenizer.string = text
        let wordEnds = Set(tokenizer.tokens(for: text.startIndex..<text.endIndex).map(\.upperBound))
        let stops = "。！？；：，、…—.!?;:,"
        let closing = #"”’）)」』》】"#
        let budget = 450
        var start = text.startIndex
        var result: [String] = []
        while start < text.endIndex {
            var end = start
            var cost = 0
            var wordBoundary = start
            var phraseBoundary = start
            while end < text.endIndex {
                let character = text[end]
                let units: Int
                if character.isNumber { units = 16 }
                else if character.isWhitespace || character.isPunctuation { units = 2 }
                else if character.unicodeScalars.allSatisfy({ (0x3400...0x9fff).contains($0.value) }) { units = 6 }
                else { units = 12 }
                // Keep a trailing stop and closing quotation mark with the spoken phrase.
                let closingMargin = stops.contains(character) || closing.contains(character) ? 16 : 0
                guard cost + units <= budget + closingMargin else { break }
                cost += units
                text.formIndex(after: &end)
                if wordEnds.contains(end) { wordBoundary = end }
                if stops.contains(character), cost >= budget / 2 {
                    // Treat punctuation inside a token (for example 3.14 or 10:30) as part of it.
                    let punctuation = text.index(before: end)
                    let betweenNumbers = punctuation > start && end < text.endIndex
                        && text[text.index(before: punctuation)].isNumber && text[end].isNumber
                    if !betweenNumbers {
                        phraseBoundary = end
                    }
                } else if closing.contains(character) && phraseBoundary == text.index(before: end) {
                    phraseBoundary = end
                }
            }
            if end < text.endIndex {
                if phraseBoundary > start { end = phraseBoundary }
                else if wordBoundary > start { end = wordBoundary }
            }
            let phrase = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if phrase.rangeOfCharacter(from: .alphanumerics) != nil { result.append(phrase) }
            start = end
        }
        return result
    }

    private static func trimJoinSilence(_ samples: [Float], leading: Int?, trailing: Int?) -> Range<Int> {
        guard !samples.isEmpty else { return samples.indices }
        // A conservative peak gate preserves quiet consonants and breath sounds.
        let gate: Float = 0.003
        let lower = leading.map { keep in
            max(0, (samples.firstIndex(where: { abs($0) > gate }) ?? 0) - keep)
        } ?? 0
        let upper = trailing.map { keep in
            min(samples.count, (samples.lastIndex(where: { abs($0) > gate }) ?? samples.count - 1) + 1 + keep)
        } ?? samples.count
        return lower < upper ? lower..<upper : samples.indices
    }

    /// Split text into pieces of at most `limit` characters, breaking at the strongest
    /// punctuation available (sentence end, then ; : — , and finally spaces). 160 characters
    /// stays well under Kokoro's 510-token ceiling even after numbers are spelled out.
    nonisolated static func pieces(_ text: String, limit: Int = 160) -> [String] {
        func split(_ s: String, _ separators: [Character]) -> [String] {
            if s.count <= limit { return [s] }
            guard let separator = separators.first else {
                var out: [String] = [], current = ""
                for word in s.split(separator: " ") {
                    if !current.isEmpty, current.count + word.count + 1 > limit { out.append(current); current = "" }
                    current += (current.isEmpty ? "" : " ") + word
                }
                if !current.isEmpty { out.append(current) }
                return out.flatMap { piece -> [String] in
                    guard piece.count > limit else { return [piece] }
                    let chars = Array(piece)
                    return stride(from: 0, to: chars.count, by: limit).map { String(chars[$0..<min($0 + limit, chars.count)]) }
                }
            }
            var parts: [String] = [], current = ""
            for character in s { current.append(character); if character == separator { parts.append(current); current = "" } }
            if !current.isEmpty { parts.append(current) }
            var merged: [String] = [], buffer = ""
            for part in parts {
                if !buffer.isEmpty, buffer.count + part.count > limit { merged.append(buffer); buffer = "" }
                buffer += part
            }
            if !buffer.isEmpty { merged.append(buffer) }
            return merged.flatMap { split($0, Array(separators.dropFirst())) }
        }
        return split(text, [".", "!", "?", ";", ":", "—", ",", "，", "。", "！", "？", "；", "：", "、"])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.rangeOfCharacter(from: .alphanumerics) != nil }
    }
}

/// Receives one Kokoro inference at a time, with timing metadata followed by 24 kHz PCM.
private final class TimedHeartAudio {
    let cancellation: SpeechCancellation
    private(set) var samples: [Float] = []
    struct Phone { let id: Int; let sample: Int }

    private(set) var starts: [Int] = []
    private(set) var phones: [Phone] = []
    private(set) var failed = false

    init(cancellation: SpeechCancellation) { self.cancellation = cancellation }

    func append(_ packet: UnsafeBufferPointer<Float>) -> Bool {
        guard let value = packet.first, let count = Int(exactly: value),
              (2...512).contains(count), 1 + 2 * count < packet.count else {
            failed = true
            return false
        }
        let pcm = packet.dropFirst(1 + 2 * count)
        var sample = 0
        var inWord = false
        var rawStarts: [Int] = []
        var rawPhones: [Phone] = []
        for index in 0..<count {
            guard let token = Int(exactly: packet[1 + index]), (0...255).contains(token),
                  let frames = Int(exactly: packet[1 + count + index]),
                  frames > 0, frames <= (pcm.count - sample) / 600 else {
                failed = true
                return false
            }
            // IDs are from the pinned tokens.txt. Spaces separate phonetic words.
            if token == 0 || token == 16 { inWord = false }
            else if token >= 17 {
                let start = pcm.startIndex + sample
                rawPhones.append(Phone(id: token, sample: start))
                if !inWord {
                    rawStarts.append(start)
                    inWord = true
                }
            }
            sample += frames * 600
        }
        guard sample == pcm.count else { failed = true; return false }

        // Match sherpa-onnx v1.13.8's ScaleSilence(0.2), and apply the same cuts to the
        // timestamps. This keeps the voice and pauses compatible with existing audio.
        var cursor = pcm.startIndex
        var silence: Int?
        var word = 0
        var phone = 0
        func append(to end: Int, skippingUntil next: Int) {
            while word < rawStarts.count, rawStarts[word] < next {
                starts.append(samples.count + min(rawStarts[word], end) - cursor)
                word += 1
            }
            while phone < rawPhones.count, rawPhones[phone].sample < next {
                let item = rawPhones[phone]
                phones.append(Phone(id: item.id, sample: samples.count + min(item.sample, end) - cursor))
                phone += 1
            }
            samples.append(contentsOf: pcm[cursor..<end])
            cursor = next
        }
        for index in pcm.indices {
            if abs(pcm[index]) <= 0.01 {
                if silence == nil { silence = index }
            } else if let begin = silence {
                if index - begin >= 4800 {
                    append(to: begin + Int(Float(index - begin) * 0.2), skippingUntil: index)
                }
                silence = nil
            }
        }
        if let begin = silence, pcm.endIndex - begin > 4800 {
            append(to: begin + Int(Float(pcm.endIndex - begin) * 0.2), skippingUntil: pcm.endIndex)
        }
        append(to: pcm.endIndex, skippingUntil: pcm.endIndex)
        return true
    }
}

@MainActor
final class ReadAloud: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    @Published private(set) var activeID: String?
    @Published private(set) var isPaused = false
    @Published private(set) var isPreparing = false
    @Published private(set) var status = ""
    @Published var error: String?
    @Published var needsDownload = false
    private var pending: (String, String)?
    private var task: Task<Void, Never>?
    private var cancellation = SpeechCancellation()
    private let model = HeartModel()
    private let engine = HeartEngine.shared
    private var player: AVAudioPlayer?
    private let chinese = AVSpeechSynthesizer()
    private var chineseUtterance: AVSpeechUtterance?
    override init() { super.init(); chinese.delegate = self }
    nonisolated static func isChinese(_ text: String) -> Bool { text.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) } }
    /// Chinese goes to the iPhone's own voice only when the built-in voice can't read it.
    nonisolated static func usesSystemVoice(_ text: String) -> Bool { isChinese(text) && !HeartModel.speaksChinese }
    func toggle(_ text: String, id: String) {
        if activeID == id {
            if isPreparing { stop(); return }
            if isPaused { resume() } else { pause() }
            return
        }
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard text.count <= 2000 else { error = "这句文字太长，请选择更短的句子朗读。"; return }
        if !Self.usesSystemVoice(text), !HeartModel.ready {
            pending = (text, id); needsDownload = true; return
        }
        play(text, id: id)
    }
    func downloadAndPlay() {
        guard let pending else { return }
        self.pending = nil; needsDownload = false
        play(pending.0, id: pending.1)
    }
    func cancelDownloadPrompt() { pending = nil; needsDownload = false }
    func stop() {
        task?.cancel(); task = nil; cancellation.cancel()
        player?.stop(); player = nil; chineseUtterance = nil; chinese.stopSpeaking(at: .immediate)
        activeID = nil; isPaused = false; isPreparing = false; status = ""; pending = nil; needsDownload = false
        // Only release the audio session if sentence read-aloud turned it on. Deactivating it
        // unconditionally stopped whole-book listening whenever Readle left the screen.
        if sessionActive {
            sessionActive = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    private func pause() {
        if let player {
            player.pause()
        } else if chineseUtterance != nil {
            guard chinese.pauseSpeaking(at: .immediate) else { return }
        } else { return }
        isPaused = true
        status = "已暂停"
    }
    private func resume() {
        do {
            try activateAudio()
            if let player {
                guard player.play() else { throw BookError.invalid("音频无法继续播放，请重试。") }
                status = "正在朗读"
            } else if chineseUtterance != nil {
                guard chinese.continueSpeaking() else { throw BookError.invalid("朗读无法继续，请重试。") }
                status = "正在朗读"
            } else { return }
            isPaused = false
        } catch {
            stop(); self.error = error.localizedDescription
        }
    }
    private func play(_ text: String, id: String) {
        activeID = id; isPaused = false; isPreparing = true; error = nil; cancellation = SpeechCancellation()
        let flag = cancellation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if Self.usesSystemVoice(text) {
                    try activateAudio()
                    let utterance = AVSpeechUtterance(string: text)
                    guard let voice = AVSpeechSynthesisVoice.speechVoices().filter({ $0.language == "zh-CN" && $0.gender == .female }).sorted(by: { $0.quality.rawValue > $1.quality.rawValue }).first ?? AVSpeechSynthesisVoice(language: "zh-CN") else {
                        throw BookError.invalid("此设备尚无中文系统声音，可在系统设置的辅助功能中下载中文声音后使用。")
                    }
                    utterance.voice = voice
                    utterance.rate = 0.46; status = "正在朗读"
                    chineseUtterance = utterance
                    chinese.speak(utterance)
                    isPreparing = false
                } else {
                    if !HeartModel.ready {
                        try await model.install { [weak self] value in await self?.downloadStatus(value, id: id) }
                    }
                    guard !Task.isCancelled, !flag.cancelled else { return }
                    status = "正在准备朗读"
                    let data = try await engine.render(text, cancellation: flag)
                    guard !Task.isCancelled, !flag.cancelled, activeID == id else { return }
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-ReadleVerifySpeech") {
                        try data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("heart-verification-\(id).wav"), options: .atomic)
                    }
                    #endif
                    try activateAudio()
                    player = try AVAudioPlayer(data: data); player?.delegate = self
                    status = "正在朗读"
                    guard player?.play() == true else { throw BookError.invalid("音频无法播放，请重试。") }
                    isPreparing = false
                }
            } catch {
                guard !Task.isCancelled, !flag.cancelled else { return }
                stop(); self.error = error.localizedDescription
            }
        }
    }
    private func downloadStatus(_ value: String, id: String) { if activeID == id { status = value } }
    private var sessionActive = false
    private func activateAudio() throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        sessionActive = true
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in if self?.player === player { self?.stop() } }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in if self?.chineseUtterance === utterance { self?.stop() } }
    }
}

struct ListenPoint: Codable, Equatable, Sendable {
    var chapter: Int
    var sentence: Int
}

// Plays a whole book sentence by sentence. Reading clauses are merged back into
// their original sentence so the voice does not pause at every comma; the unit ID
// is the original sentence ID, which is stable across launches.
@MainActor
final class BookListener: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    enum Phase { case idle, preparing, playing, paused }
    struct Unit: Sendable { let paragraph: Int; let ids: [Int]; let text: String }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var chapterIndex = 0
    @Published private(set) var speakingIDs: Set<Int> = []
    @Published private(set) var speakingParagraph: Int?
    @Published private(set) var status = ""
    @Published var error: String?
    @Published var needsDownload = false

    private let book: Book
    /// The current chapter's sentences, and which one is being read (for theater mode).
    @Published private(set) var units: [Unit] = []
    @Published private(set) var currentIndex = 0
    private var index = 0
    private var pendingStart: ListenPoint?
    private var task: Task<Void, Never>?
    private var prefetch: Task<Void, Never>?
    private var preparedTimingTask: Task<Void, Never>?
    private var cancellation = SpeechCancellation()
    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    private var lastPlaybackTime: TimeInterval = 0
    private var playbackDuration: TimeInterval = 0
    private var utterance: AVSpeechUtterance?
    var theaterIsVisible = false {
        didSet {
            saveTheaterPoint()
            guard theaterIsVisible else { return }
            if let player, let file = player.url, let unit = units[safe: index] {
                attachPreparedTiming(file: file, text: unit.text, player: player)
                startPrefetch(after: index, flag: cancellation)
            } else if player == nil, let unit = units[safe: index],
                      BookAudio.preparedFile(book: book.id, text: unit.text) != nil {
                startPrefetch(after: index - 1, flag: cancellation)
            }
        }
    }
    private var remoteTargets: [Any] = []
    private var interruptionObserver: NSObjectProtocol?
    private var storageKey: String { "listenPoint.\(book.id.uuidString)" }
    private var theaterStorageKey: String { "theaterPoint.\(book.id.uuidString)" }

    private var probe: NSObjectProtocol?
    private var pausedByInterruption = false
    private var wordLookupPause: UUID?

    /// Keep ownership of an automatic pause only until the user changes playback.
    func pauseForWordLookup() -> UUID? {
        if let wordLookupPause, phase == .paused { return wordLookupPause }
        guard phase == .playing || phase == .preparing else { return nil }
        pause()
        let id = UUID()
        wordLookupPause = id
        return id
    }

    func resumeAfterWordLookup(_ id: UUID) {
        guard wordLookupPause == id, phase == .paused else { return }
        wordLookupPause = nil
        resume()
    }

    var isPausedForWordLookup: Bool { wordLookupPause != nil }

    private func recoverIfSilent() {
        guard phase == .playing, !(player?.isPlaying ?? false), !synth.isSpeaking else { return }
        BookAudioLog.write("listen: silent on return, restarting current sentence")
        cancelWork()
        activateSession()
        playCurrent()
    }
    /// How far through the current sentence the voice is (0…1). A separate object so its
    /// frequent updates only redraw theater mode, not the whole reader.
    let progress = ListenProgress()
    private var progressTimer: Timer?
    private var spokenLocation = 0
    private var spokenLength = 1

    /// Sentences before each chapter, for whole-book progress.
    private let sentencesBefore: [Int]
    private let totalSentences: Int

    init(book: Book) {
        self.book = book
        var running = 0, before: [Int] = []
        for chapter in book.chapters { before.append(running); running += Self.units(in: chapter).count }
        sentencesBefore = before; totalSentences = max(running, 1)
        super.init()
        synth.delegate = self
        progress.clock = { [weak self] in
            guard let self, let player else { return nil }
            // AVAudioPlayer can briefly report that it isn't playing around startup,
            // interruptions, or completion. Only the real clock can advance the highlight.
            lastPlaybackTime = max(lastPlaybackTime, player.currentTime)
            return lastPlaybackTime
        }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateProgress() }
        }
        // Returning to Readle: if listening claims to be playing but nothing is audible (iOS
        // stopped the audio while Readle was away), restart the current sentence.
        probe = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recoverIfSilent() }
        }
    }

    var isActive: Bool { phase != .idle }

    /// 0…1 through the whole book, including how far into the current sentence the voice is.
    func bookProgress(within fraction: Double) -> Double {
        let before = sentencesBefore.indices.contains(chapterIndex) ? sentencesBefore[chapterIndex] : 0
        return min(1, (Double(before + currentIndex) + min(max(fraction, 0), 1)) / Double(totalSentences))
    }

    private func updateProgress() {
        guard phase == .playing else { return }
        let value: Double
        if let player, playbackDuration > 0 {
            // A finished player reports time 0; ignore it so the sentence doesn't jump back to its start.
            guard player.isPlaying else { return }
            value = player.currentTime / playbackDuration
        }
        else if utterance != nil { value = Double(spokenLocation) / Double(spokenLength) }
        else { return }
        let clamped = min(1, max(0, value))
        if abs(clamped - progress.fraction) > 0.005 { progress.fraction = clamped }
    }
    var chapterTitle: String { book.chapters.indices.contains(chapterIndex) ? book.chapters[chapterIndex].title : "" }
    var savedPoint: ListenPoint? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let point = try? JSONDecoder().decode(ListenPoint.self, from: data),
              book.chapters.indices.contains(point.chapter) else { return nil }
        return point
    }

    /// Theater browsing has its own checkpoint so the ordinary reader's scroll
    /// position and the listening checkpoint do not overwrite the last sentence seen.
    var savedTheaterPoint: ListenPoint? {
        guard let data = UserDefaults.standard.data(forKey: theaterStorageKey),
              let point = try? JSONDecoder().decode(ListenPoint.self, from: data),
              book.chapters.indices.contains(point.chapter),
              Self.units(in: book.chapters[point.chapter]).contains(where: { $0.ids.contains(point.sentence) }) else { return nil }
        return point
    }

    private func saveTheaterPoint() {
        guard let point = currentPoint, let data = try? JSONEncoder().encode(point) else { return }
        UserDefaults.standard.set(data, forKey: theaterStorageKey)
    }

    func start(at point: ListenPoint) {
        stop()
        guard book.chapters.indices.contains(point.chapter) else { return }
        load(chapter: point.chapter)
        index = units.firstIndex { $0.ids.contains(point.sentence) } ?? 0
        if let unit = units[safe: index], !ReadAloud.usesSystemVoice(unit.text), !HeartModel.ready,
           BookAudio.preparedFile(book: book.id, text: unit.text) == nil {
            pendingStart = point; needsDownload = true; return
        }
        activateSession()
        playCurrent()
    }

    func downloadAndStart() {
        guard let point = pendingStart else { return }
        pendingStart = nil; needsDownload = false
        cancelWork()
        pausedByInterruption = false
        load(chapter: point.chapter)
        index = units.firstIndex { $0.ids.contains(point.sentence) } ?? 0
        activateSession()
        playCurrent()
    }

    func cancelDownloadPrompt() { pendingStart = nil; needsDownload = false }

    /// Jump to a sentence in the current chapter and play from there.
    func jump(to target: Int) {
        guard let destination = resolve(target) else { return }
        wordLookupPause = nil
        let unit = destination.units[destination.index]
        if !ReadAloud.usesSystemVoice(unit.text), !HeartModel.ready, BookAudio.preparedFile(book: book.id, text: unit.text) == nil {
            pendingStart = ListenPoint(chapter: destination.chapter, sentence: unit.ids[0]); needsDownload = true; return
        }
        cancelWork()
        pausedByInterruption = false
        if destination.chapter != chapterIndex { load(chapter: destination.chapter) }
        index = destination.index
        activateSession()
        playCurrent()
    }
    func skip(_ delta: Int) { move(to: index + delta) }
    func canMove(to target: Int) -> Bool { resolve(target) != nil }

    /// One step past either end of the chapter continues into the neighbouring chapter.
    var canGoForward: Bool { canMove(to: index + 1) }
    var canGoBack: Bool { canMove(to: index - 1) }

    /// Turns a target one past either end of the chapter into a sentence of the next or previous
    /// chapter (loading it); nil when there is nothing there.
    private func resolve(_ target: Int) -> (chapter: Int, index: Int, units: [Unit])? {
        if units.indices.contains(target) { return (chapterIndex, target, units) }
        let step = target == units.count ? 1 : (target == -1 ? -1 : 0)
        guard step != 0 else { return nil }
        var chapter = chapterIndex + step
        while book.chapters.indices.contains(chapter) {
            let next = Self.units(in: book.chapters[chapter])
            if !next.isEmpty { return (chapter, step > 0 ? 0 : next.count - 1, next) }
            chapter += step
        }
        return nil
    }

    /// Theater mode without the voice: show this sentence, ready to read or to play from.
    func browse(at point: ListenPoint) {
        guard phase == .idle, book.chapters.indices.contains(point.chapter) else { return }
        load(chapter: point.chapter)
        index = units.firstIndex { $0.ids.contains(point.sentence) } ?? 0
        progress.fraction = 0
        progress.timing = nil; progress.spokenRange = nil
        currentIndex = index
        speakingParagraph = units[safe: index]?.paragraph
    }

    /// The sentence theater mode is showing, to start the voice from.
    var currentPoint: ListenPoint? {
        units[safe: index].map { ListenPoint(chapter: chapterIndex, sentence: $0.ids[0]) }
    }

    /// Scrolling in theater mode: while playing, play from the new sentence; while paused or
    /// stopped, just move there so play/resume starts from it.
    func move(to target: Int) {
        guard target != index else { return }
        wordLookupPause = nil
        if phase == .playing || phase == .preparing { jump(to: target); return }
        guard let destination = resolve(target) else { return }
        cancelWork()
        pausedByInterruption = false
        if destination.chapter != chapterIndex { load(chapter: destination.chapter) }
        index = destination.index
        progress.fraction = 0 // a newly chosen sentence always shows from its first line
        progress.timing = nil; progress.spokenRange = nil
        currentIndex = index
        if phase != .idle { speakingIDs = Set(units[index].ids) }
        speakingParagraph = units[index].paragraph // the reader follows, even when silent
        save()
    }

    func togglePause() {
        pausedByInterruption = false
        switch phase {
        case .playing, .preparing: pause()
        case .paused: resume()
        case .idle: break
        }
    }

    func pause() {
        wordLookupPause = nil
        guard phase == .playing || phase == .preparing else { return }
        if let player { player.pause() }
        else if utterance != nil { synth.pauseSpeaking(at: .immediate) }
        else { cancelWork() } // Still rendering: resume re-renders this sentence.
        phase = .paused; status = "已暂停"
        updateNowPlaying()
    }

    func resume() {
        wordLookupPause = nil
        guard phase == .paused else { return }
        do { try AVAudioSession.sharedInstance().setActive(true) } catch { }
        if let player, player.play() {
            phase = .playing; status = "正在朗读"
        } else if utterance != nil, synth.continueSpeaking() {
            phase = .playing; status = "正在朗读"
        } else {
            player = nil; utterance = nil
            playCurrent()
        }
        updateNowPlaying()
    }

    func stop(reason: String = "user") {
        wordLookupPause = nil
        if theaterIsVisible { saveTheaterPoint() }
        if phase != .idle { BookAudioLog.write("listen stop: \(reason)") }
        cancelWork()
        if phase != .idle { save() }
        phase = .idle; status = ""; speakingIDs = []; speakingParagraph = nil
        pendingStart = nil; needsDownload = false
        tearDownSession()
    }

    private func cancelWork() {
        preparedTimingTask?.cancel()
        preparedTimingTask = nil
        task?.cancel(); task = nil; prefetch?.cancel(); prefetch = nil
        cancellation.cancel(); cancellation = SpeechCancellation()
        player?.stop(); player = nil
        utterance = nil; synth.stopSpeaking(at: .immediate)
    }

    private func load(chapter: Int) {
        chapterIndex = chapter
        units = Self.units(in: book.chapters[chapter])
    }

    nonisolated static func units(in chapter: Chapter) -> [Unit] {
        var units: [Unit] = []
        for paragraph in chapter.paragraphs {
            for sentence in paragraph.sentences {
                if sentence.id < 0, let last = units.last, last.paragraph == paragraph.id {
                    units[units.count - 1] = Unit(paragraph: paragraph.id, ids: last.ids + [sentence.id], text: last.text + sentence.text)
                } else {
                    units.append(Unit(paragraph: paragraph.id, ids: [sentence.id], text: sentence.text))
                }
            }
        }
        return units.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func playCurrent() {
        while index >= units.count {
            guard chapterIndex + 1 < book.chapters.count else { finish(); return }
            load(chapter: chapterIndex + 1); index = 0
        }
        let unit = units[index]
        progress.fraction = 0; progress.timing = nil; progress.spokenRange = nil
        let spokenText = unit.text.trimmingCharacters(in: .whitespacesAndNewlines)
        spokenLocation = 0; spokenLength = max(1, spokenText.utf16.count)
        currentIndex = index
        speakingIDs = Set(unit.ids); speakingParagraph = unit.paragraph
        save()
        let flag = cancellation
        phase = .preparing
        updateNowPlaying()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if ReadAloud.usesSystemVoice(unit.text) {
                    guard let voice = AVSpeechSynthesisVoice.speechVoices().filter({ $0.language == "zh-CN" && $0.gender == .female }).sorted(by: { $0.quality.rawValue > $1.quality.rawValue }).first ?? AVSpeechSynthesisVoice(language: "zh-CN") else {
                        throw BookError.invalid("此设备尚无中文系统声音，可在系统设置的辅助功能中下载中文声音后使用。")
                    }
                    let utterance = AVSpeechUtterance(string: spokenText)
                    utterance.voice = voice; utterance.rate = 0.46
                    self.utterance = utterance
                    synth.speak(utterance)
                    phase = .playing; status = "正在朗读"
                } else {
                    let player: AVAudioPlayer
                    let prepared = BookAudio.preparedFile(book: book.id, text: unit.text)
                    if let prepared, let saved = try? AVAudioPlayer(contentsOf: prepared) {
                        player = saved
                    } else {
                        if !HeartModel.ready {
                            try await HeartModel().install { [weak self] value in await self?.setStatus(value) }
                        }
                        guard !Task.isCancelled, !flag.cancelled else { return }
                        status = "正在准备朗读"
                        let data = try await HeartEngine.shared.render(unit.text, cancellation: flag)
                        guard !Task.isCancelled, !flag.cancelled else { return }
                        player = try AVAudioPlayer(data: data)
                        progress.timing = WordTiming.read(from: data, text: unit.text)
                        if progress.timing == nil, ReadAloud.isChinese(unit.text) {
                            progress.timing = WordTiming.estimate(for: unit.text, duration: player.duration, leadingSilence: 0.06)
                        }
                    }
                    player.delegate = self
                    lastPlaybackTime = 0
                    self.player = player
                    guard player.play() else { throw BookError.invalid("音频无法播放，请重试。") }
                    playbackDuration = player.url.flatMap(BookAudio.adtsDuration) ?? player.duration
                    phase = .playing; status = "正在朗读"
                    if theaterIsVisible, let file = player.url {
                        attachPreparedTiming(file: file, text: unit.text, player: player)
                    }
                    startPrefetch(after: index, flag: flag)
                }
                updateNowPlaying()
            } catch {
                guard !Task.isCancelled, !flag.cancelled else { return }
                let message = error.localizedDescription
                stop(reason: "error \(message)"); self.error = message
            }
        }
    }

    private func attachPreparedTiming(file: URL, text: String, player: AVAudioPlayer) {
        preparedTimingTask?.cancel()
        if progress.timing == nil {
            progress.timing = WordTiming.estimate(for: text, duration: playbackDuration,
                                                  leadingSilence: file.pathExtension == "aac" ? 0.15 : 0.06)
        }
        let flag = cancellation
        preparedTimingTask = Task { [weak self, weak player] in
            let worker = Task.detached(priority: .utility) {
                await BookAudioTimings.timing(for: file, text: text, cancellation: flag)
            }
            let timing = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let timing, let self, let player, self.player === player else { return }
            progress.timing = timing
        }
    }

    // Audio on disk can always play immediately. Prefetch synthesizes only missing audio,
    // or prepares timing for already downloaded clips that Theater will play next.
    private func startPrefetch(after current: Int, flag: SpeechCancellation) {
        prefetch?.cancel()
        let bookID = book.id
        let needsTiming = theaterIsVisible
        let upcoming = units.dropFirst(current + 1).prefix(2).map(\.text).filter { !ReadAloud.usesSystemVoice($0) }
        guard !upcoming.isEmpty, HeartModel.ready else { return }
        prefetch = Task.detached(priority: .utility) {
            for text in upcoming {
                guard !Task.isCancelled, !flag.cancelled else { return }
                if let prepared = BookAudio.preparedFile(book: bookID, text: text) {
                    if needsTiming { _ = await BookAudioTimings.timing(for: prepared, text: text, cancellation: flag) }
                } else {
                    _ = try? await HeartEngine.shared.render(text, cancellation: flag)
                }
            }
        }
    }

    private func setStatus(_ value: String) { if phase != .idle { status = value } }

    private func advance() {
        preparedTimingTask?.cancel()
        player = nil; utterance = nil
        switch phase {
        case .playing:
            index += 1
            playCurrent()
        case .paused:
            // The sentence ended at the same moment listening was paused (for example a word
            // lookup): step on now, so play continues with the next sentence instead of repeating.
            index += 1
            if units.indices.contains(index) {
                currentIndex = index; progress.fraction = 0
                progress.timing = nil; progress.spokenRange = nil
                speakingIDs = Set(units[index].ids); speakingParagraph = units[index].paragraph
                save()
            }
        default:
            break
        }
    }

    private func finish() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        cancelWork()
        phase = .idle; status = ""; speakingIDs = []; speakingParagraph = nil
        tearDownSession()
    }

    private func save() {
        guard let unit = units[safe: index], let id = unit.ids.first,
              let data = try? JSONEncoder().encode(ListenPoint(chapter: chapterIndex, sentence: id)) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        if theaterIsVisible { saveTheaterPoint() }
    }

    // MARK: Audio session, lock screen and interruptions

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        guard remoteTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        remoteTargets = [
            center.playCommand.addTarget { [weak self] _ in self?.resume(); return .success },
            center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success },
            center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePause(); return .success }
        ]
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            Task { @MainActor in
                guard let self else { return }
                if type == .began {
                    if self.phase == .playing || self.phase == .preparing { self.pausedByInterruption = true }
                    self.pause()
                } else if self.pausedByInterruption, options.contains(.shouldResume) {
                    // A call, Siri or alarm ended and iOS says playback may continue.
                    self.pausedByInterruption = false
                    self.resume()
                }
            }
        }
    }

    private func tearDownSession() {
        let center = MPRemoteCommandCenter.shared()
        for target in remoteTargets {
            center.playCommand.removeTarget(target)
            center.pauseCommand.removeTarget(target)
            center.togglePlayPauseCommand.removeTarget(target)
        }
        remoteTargets = []
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func updateNowPlaying() {
        guard phase != .idle else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: chapterTitle,
            MPMediaItemPropertyAlbumTitle: book.title,
            MPMediaItemPropertyArtist: book.author,
            MPNowPlayingInfoPropertyPlaybackRate: phase == .playing ? 1.0 : 0.0
        ]
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in if self?.player === player { self?.advance() } }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in if self?.utterance === utterance { self?.advance() } }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.utterance === utterance else { return }
            self.spokenLocation = characterRange.location
            self.progress.spokenRange = characterRange
        }
    }
}

@MainActor
final class ListenProgress: ObservableObject {
    @Published var fraction: Double = 0
    /// When each word of the current sentence starts in its audio, once worked out.
    @Published var timing: WordTiming?
    @Published var spokenRange: NSRange?
    /// The audio's own clock (seconds into the current sentence), read every frame for the
    /// word highlight, so it never lags behind the voice.
    var clock: (@MainActor () -> TimeInterval?)?
}

/// Word onsets on the same sample clock as the WAV. Nil means the spoken and displayed
/// word sequences could not be mapped, so the renderer leaves the sentence unhighlighted.
struct WordTiming: Sendable {
    let text: String
    let starts: [Double]

    func lit(at time: Double) -> Double {
        Double(starts.prefix { $0 <= time }.count)
    }

    /// Keep older downloads readable while the recorded timeline is being recovered.
    /// This uses the clip clock and duration, with longer words receiving more time.
    static func estimate(for text: String, duration: Double, leadingSilence: Double) -> WordTiming? {
        let weights = units(text).map { word in
            max(1, Double(word.count) / 3)
        }
        guard !weights.isEmpty, duration.isFinite, duration > 0 else { return nil }
        let begin = min(leadingSilence, duration * 0.25)
        let end = max(begin, duration - min(0.12, duration * 0.12))
        let secondsPerWeight = (end - begin) / weights.reduce(0, +)
        var cursor = begin
        let starts = weights.map { weight in
            defer { cursor += weight * secondsPerWeight }
            return cursor
        }
        return WordTiming(text: text.trimmingCharacters(in: .whitespacesAndNewlines), starts: starts)
    }

    static func words(_ text: String) -> [Substring] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).map { text[$0] }
    }

    /// Chinese characters have independently spoken syllables. Latin words and numbers
    /// keep their existing grouping, including when they occur in Chinese prose.
    static func units(in word: Substring) -> [Substring] {
        guard word.unicodeScalars.allSatisfy({ (0x3400...0x9fff).contains($0.value) }) else { return [word] }
        return word.indices.map { word[$0..<word.index(after: $0)] }
    }

    static func units(_ text: String) -> [Substring] { words(text).flatMap { units(in: $0) } }

    static func chunkName(for text: String) -> String { ReadAloud.isChinese(text) ? "rdt3" : "rdt2" }

    private static func u32(_ data: Data, _ offset: Int) -> Int {
        Int(UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }))
    }

    private static func metadataOffset(in data: Data, text: String) -> Int? {
        guard data.count >= 52, data.prefix(4) == Data("RIFF".utf8) else { return nil }
        let pcmSize = u32(data, 40)
        let offset = 44 + pcmSize
        guard pcmSize % 2 == 0, offset <= data.count - 8,
              data[offset..<(offset + 4)] == Data(chunkName(for: text).utf8),
              u32(data, offset + 4) == data.count - offset - 8 else { return nil }
        return offset + 8
    }

    static func hasMetadata(in data: Data, text: String) -> Bool { metadataOffset(in: data, text: text) != nil }

    static func read(from data: Data, text: String) -> WordTiming? {
        guard let offset = metadataOffset(in: data, text: text), offset < data.count,
              (data.count - offset) % 4 == 0, u32(data, 24) == 24_000 else { return nil }
        guard (data.count - offset) / 4 == units(text).count else { return nil }
        let samples = stride(from: offset, to: data.count, by: 4).map { u32(data, $0) }
        guard let last = samples.last, last < u32(data, 40) / 2,
              zip(samples, samples.dropFirst()).allSatisfy({ $0 <= $1 }) else { return nil }
        return WordTiming(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                          starts: samples.map { Double($0) / 24000 })
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// Whole-book audio: every English sentence rendered once with Heart, compressed to
// AAC and kept per book in Application Support (not Caches, so iOS won't purge it).
enum BookAudio {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BookAudio", isDirectory: true)
    }
    static func directory(_ book: UUID) -> URL { root.appendingPathComponent(book.uuidString, isDirectory: true) }
    static func usesNewCadence(_ text: String) -> Bool {
        if text.count <= 60 { return false }
        if ReadAloud.isChinese(text) { return HeartModel.speaksChinese }
        return text.count > 160
    }
    static func clipName(_ text: String, legacy: Bool = false) -> String {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        if legacy { return digest }
        if HeartModel.speaksChinese && ReadAloud.isChinese(text) { return digest + "-syllables" }
        return usesNewCadence(text) ? digest + "-phrased" : digest
    }
    static func previousClipNames(_ text: String) -> [String] {
        if HeartModel.speaksChinese && ReadAloud.isChinese(text) {
            let digest = clipName(text, legacy: true)
            return usesNewCadence(text) ? [digest + "-phrased", digest] : [digest]
        }
        return usesNewCadence(text) ? [clipName(text, legacy: true)] : []
    }
    static func file(book: UUID, text: String, legacy: Bool = false) -> URL {
        directory(book).appendingPathComponent(clipName(text, legacy: legacy)).appendingPathExtension("aac")
    }
    private static func existingClip(_ url: URL) -> URL? {
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let wav = url.deletingPathExtension().appendingPathExtension("wav")
        return FileManager.default.fileExists(atPath: wav.path) ? wav : nil
    }
    static func currentFile(book: UUID, text: String) -> URL? { existingClip(file(book: book, text: text)) }
    static func legacyFile(book: UUID, text: String) -> URL? {
        for name in previousClipNames(text) {
            let candidate = directory(book).appendingPathComponent(name).appendingPathExtension("aac")
            if let clip = existingClip(candidate) { return clip }
        }
        return nil
    }
    static func preparedFile(book: UUID, text: String) -> URL? {
        currentFile(book: book, text: text) ?? legacyFile(book: book, text: text)
    }
    /// AVAudioPlayer estimates variable-bitrate ADTS duration from its file size.
    /// Count the actual AAC frames so Theater follows the whole sentence at the right pace.
    static func adtsDuration(_ url: URL) -> TimeInterval? {
        guard url.pathExtension == "aac", let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var offset = 0
            var frames = 0
            while offset + 7 <= bytes.count {
                guard bytes[offset] == 0xff, bytes[offset + 1] & 0xf6 == 0xf0,
                      (bytes[offset + 2] >> 2) & 0x0f == 6 else { return nil }
                let length = (Int(bytes[offset + 3] & 0x03) << 11)
                    | (Int(bytes[offset + 4]) << 3) | Int(bytes[offset + 5] >> 5)
                guard length >= 7, length <= bytes.count - offset else { return nil }
                frames += Int(bytes[offset + 6] & 0x03) + 1
                offset += length
            }
            return offset == bytes.count && frames > 0 ? Double(frames) * 1024 / 24_000 : nil
        }
    }
    /// English sentences only; Chinese uses the instant system voice and needs no preparation.
    static func texts(_ book: Book, startingAt chapter: Int = 0) -> [String] {
        let order = Array(book.chapters.indices.dropFirst(chapter)) + Array(book.chapters.indices.prefix(chapter))
        var seen = Set<String>()
        return order.flatMap { BookListener.units(in: book.chapters[$0]).map(\.text) }
            .filter { !ReadAloud.usesSystemVoice($0) && seen.insert($0).inserted }
    }
    static func size(_ book: UUID) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(book), includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    static func delete(_ book: UUID) { try? FileManager.default.removeItem(at: directory(book)) }

    // Raw AAC-LC in ADTS frames (7-byte header each). Container formats written by
    // AVAudioFile pad every file to 32 KB, which would double a novel's footprint.
    static func encode(_ wav: Data, to destination: URL) throws {
        let fm = FileManager.default
        let folder = destination.deletingLastPathComponent()
        if !fm.fileExists(atPath: folder.path) {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var rootURL = root; try? rootURL.setResourceValues(values)
        }
        let input = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        try wav.write(to: input)
        defer { try? fm.removeItem(at: input) }
        let encoded: Data = try autoreleasepool {
            let source = try AVAudioFile(forReading: input)
            let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000]
            guard let rateIndex = rates.firstIndex(of: source.processingFormat.sampleRate),
                  let pcm = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.length)) else {
                throw BookError.invalid("音频转换失败。")
            }
            try source.read(into: pcm)
            var description = AudioStreamBasicDescription(mSampleRate: source.processingFormat.sampleRate, mFormatID: kAudioFormatMPEG4AAC,
                                                          mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                                                          mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
            guard let aac = AVAudioFormat(streamDescription: &description),
                  let converter = AVAudioConverter(from: pcm.format, to: aac) else { throw BookError.invalid("音频转换失败。") }
            converter.bitRate = 32000
            var output = Data()
            var supplied = false
            while true {
                let packets = AVAudioCompressedBuffer(format: aac, packetCapacity: 16, maximumPacketSize: max(converter.maximumOutputPacketSize, 1536))
                var failure: NSError?
                let status = converter.convert(to: packets, error: &failure) { _, state in
                    if supplied { state.pointee = .endOfStream; return nil }
                    supplied = true; state.pointee = .haveData; return pcm
                }
                if status == .error { throw failure ?? BookError.invalid("音频转换失败。") }
                if let descriptions = packets.packetDescriptions {
                    for index in 0..<Int(packets.packetCount) {
                        let packet = descriptions[index]
                        let size = Int(packet.mDataByteSize), frame = size + 7
                        output.append(contentsOf: [0xFF, 0xF1, UInt8(0x40 | (rateIndex << 2)), UInt8(0x40 | (frame >> 11)),
                                                   UInt8((frame >> 3) & 0xFF), UInt8(((frame & 7) << 5) | 0x1F), 0xFC])
                        output.append(packets.data.advanced(by: Int(packet.mStartOffset)).assumingMemoryBound(to: UInt8.self), count: size)
                    }
                }
                if status == .endOfStream || (status == .inputRanDry && packets.packetCount == 0) { break }
            }
            guard !output.isEmpty else { throw BookError.invalid("音频转换失败。") }
            return output
        }
        try encoded.write(to: destination, options: .atomic)
    }
}

/// Prepared AAC doesn't contain Kokoro's word timestamps. Keep one small index per book
/// and measure the encoder delay against the actual decoded clip before storing a timeline.
private actor BookAudioTimings {
    private static let shared = BookAudioTimings()

    private struct Entry: Codable {
        let clip: String
        let modified: Date
        let starts: [Double]
        let timingFormat: String?
    }

    private var folder: URL?
    private var entries: [String: Entry] = [:]
    private var recovery: (clip: URL, work: Task<WordTiming?, Never>)?

    static func timing(for clip: URL, text: String, cancellation: SpeechCancellation) async -> WordTiming? {
        if clip.pathExtension == "wav",
           let data = try? Data(contentsOf: clip, options: .mappedIfSafe),
           let timing = WordTiming.read(from: data, text: text) {
            return timing
        }
        return await shared.recover(clip, text: text, cancellation: cancellation)
    }

    private func recover(_ clip: URL, text: String, cancellation: SpeechCancellation) async -> WordTiming? {
        while !Task.isCancelled, !cancellation.cancelled {
            if let timing = savedTiming(for: clip, text: text) { return timing }
            if let recovery {
                let timing = await recovery.work.value
                if recovery.clip == clip { return timing }
                continue
            }
            // Keep one migration running even if the player advances before it finishes.
            // A late result is saved for replay and only published to the player that requested it.
            let work = Task.detached(priority: .utility) { [self] () -> WordTiming? in
                var timing: WordTiming?
                let legacyCadence = BookAudio.usesNewCadence(text)
                    && clip.deletingPathExtension().lastPathComponent == BookAudio.clipName(text, legacy: true)
                if let wav = try? await HeartEngine.shared.renderForTiming(text, legacyCadence: legacyCadence) {
                    timing = await Self.store(wav: wav, for: clip, text: text)
                }
                await finishRecovery()
                return timing
            }
            recovery = (clip, work)
            return await work.value
        }
        return nil
    }

    private func finishRecovery() {
        recovery = nil
    }

    @discardableResult
    static func store(wav: Data, for clip: URL, text: String) async -> WordTiming? {
        guard let timing = WordTiming.read(from: wav, text: text),
              let starts = alignedStarts(timing, wav: wav, clip: clip) else { return nil }
        await shared.save(starts, for: clip, timingFormat: WordTiming.chunkName(for: text))
        return WordTiming(text: timing.text, starts: starts)
    }

    private func loadFolder(for clip: URL) -> URL {
        let directory = clip.deletingLastPathComponent()
        let url = directory.appendingPathComponent("word-timing-v1.jsonl")
        if folder != directory {
            folder = directory
            entries.removeAll()
            if let data = try? Data(contentsOf: url) {
                let decoder = JSONDecoder()
                for line in data.split(separator: 10) {
                    if let entry = try? decoder.decode(Entry.self, from: Data(line)) { entries[entry.clip] = entry }
                }
            }
        }
        return url
    }

    private func savedTiming(for clip: URL, text: String) -> WordTiming? {
        _ = loadFolder(for: clip)
        guard let entry = entries[clip.lastPathComponent],
              let modified = try? clip.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              entry.modified == modified, (entry.timingFormat ?? "rdt2") == WordTiming.chunkName(for: text),
              entry.starts.count == WordTiming.units(text).count else { return nil }
        return WordTiming(text: text.trimmingCharacters(in: .whitespacesAndNewlines), starts: entry.starts)
    }

    private func save(_ starts: [Double], for clip: URL, timingFormat: String) {
        let url = loadFolder(for: clip)
        guard let modified = try? clip.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return }
        let key = clip.lastPathComponent
        if let entry = entries[key], entry.modified == modified, entry.timingFormat == timingFormat { return }
        let entry = Entry(clip: key, modified: modified, starts: starts, timingFormat: timingFormat)
        entries[key] = entry
        do {
            // A leading newline lets the next record survive a partial write.
            let record = Data([10]) + (try JSONEncoder().encode(entry)) + Data([10])
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: record)
            } else {
                try record.write(to: url, options: .atomic)
            }
        } catch { /* Playback and the in-memory timing still work. */ }
    }

    /// ADTS can add encoder priming and padding. Search for a single sample offset that
    /// fits the same speech both near its start and later in the clip. A different render
    /// cannot safely share this file's timing.
    private static func alignedStarts(_ timing: WordTiming, wav: Data, clip: URL) -> [Double]? {
        let rate = 24_000
        let maxOffset = rate / 4
        guard timing.starts.count > 0, let file = try? AVAudioFile(forReading: clip),
              file.processingFormat.sampleRate == Double(rate), file.processingFormat.channelCount == 1,
              file.length > 0, file.length <= Int64(rate * 180),
              let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: pcm)) != nil, let decoded = pcm.floatChannelData?[0] else { return nil }
        let pcmBytes = Int(UInt32(littleEndian: wav.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self)
        }))
        let frames = pcmBytes / 2
        let decodedCount = Int(pcm.frameLength)
        guard abs(decodedCount - frames) <= maxOffset else { return nil }

        return wav.withUnsafeBytes { bytes in
            let source = bytes.baseAddress!.advanced(by: 44).assumingMemoryBound(to: Int16.self)
            let first = Int(timing.starts[0] * Double(rate))
            let middle = Int(timing.starts[timing.starts.count / 2] * Double(rate))
            let step = 8
            func reference(at start: Int) -> [Float] {
                stride(from: start, to: min(frames, start + 4_800), by: step).map {
                    Float(Int16(littleEndian: source[$0])) / 32768
                }
            }
            let head = reference(at: first)
            let later = reference(at: middle)
            guard head.count >= 120, later.count >= 120 else { return nil }
            let headEnergy = head.reduce(Float.zero) { $0 + $1 * $1 }
            let laterEnergy = later.reduce(Float.zero) { $0 + $1 * $1 }
            guard headEnergy > 0.001, laterEnergy > 0.001 else { return nil }

            func score(_ reference: [Float], energy: Float, at start: Int) -> Float {
                guard start >= 0, start + (reference.count - 1) * step < decodedCount else { return 0 }
                var dot: Float = 0
                var decodedEnergy: Float = 0
                for i in reference.indices {
                    let y = decoded[start + i * step]
                    dot += reference[i] * y
                    decodedEnergy += y * y
                }
                return decodedEnergy > 0.001 ? dot / (energy * decodedEnergy).squareRoot() : 0
            }
            // Coarse search, then refine by individual samples near the best peak.
            var best = 0
            var bestScore: Float = 0
            func search(_ candidates: StrideThrough<Int>) {
                for offset in candidates {
                    let fit = score(head, energy: headEnergy, at: first + offset)
                    if fit > bestScore { bestScore = fit; best = offset }
                }
            }
            search(stride(from: -maxOffset, through: maxOffset, by: 4))
            search(stride(from: best - 3, through: best + 3, by: 1))
            guard bestScore >= 0.82, score(later, energy: laterEnergy, at: middle + best) >= 0.82 else { return nil }
            let result = timing.starts.map { $0 + Double(best) / Double(rate) }
            guard let first = result.first, first >= 0, let last = result.last,
                  last < Double(decodedCount) / Double(rate) else { return nil }
            return result
        }
    }
}

@MainActor
final class BookAudioPreparer: ObservableObject {
    static let shared = BookAudioPreparer()
    @Published private(set) var bookID: UUID?
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var running = false
    @Published var error: String?
    @Published var needsDownload = false
    private var task: Task<Void, Never>?
    private var cancellation = SpeechCancellation()
    private var pending: (Book, Int)?
    private var backgroundObserver: NSObjectProtocol?

    init() {
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running else { return }
                self.pause(reason: "app entered background")
            }
        }
    }

    func isRunning(_ book: UUID) -> Bool { running && bookID == book }

    /// Count what is already on disk, without starting work.
    func counts(_ book: Book) -> (done: Int, total: Int, older: Int) {
        if bookID == book.id, running { return (done, total, 0) }
        let texts = BookAudio.texts(book)
        var ready = 0, older = 0
        for text in texts {
            if BookAudio.currentFile(book: book.id, text: text) != nil { ready += 1 }
            else if BookAudio.legacyFile(book: book.id, text: text) != nil { older += 1 }
        }
        return (ready, texts.count, older)
    }

    func start(_ book: Book, fromChapter chapter: Int) {
        guard HeartModel.ready else { pending = (book, chapter); needsDownload = true; return }
        run(book, fromChapter: chapter)
    }
    func downloadAndStart() {
        guard let (book, chapter) = pending else { return }
        pending = nil; needsDownload = false
        run(book, fromChapter: chapter)
    }
    func cancelDownloadPrompt() { pending = nil; needsDownload = false }

    func pause(reason: String = "user") {
        if running { BookAudioLog.write("pause: \(reason) at \(done)/\(total)") }
        task?.cancel(); task = nil; cancellation.cancel()
        running = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Only called when the book itself is removed from the bookshelf.
    func deleteAudio(for book: UUID) {
        if bookID == book { pause(); done = 0 }
        BookAudio.delete(book)
        objectWillChange.send()
    }

    private func run(_ book: Book, fromChapter chapter: Int) {
        pause(reason: "restart")
        cancellation = SpeechCancellation()
        let flag = cancellation
        bookID = book.id; running = true; error = nil
        let texts = BookAudio.texts(book, startingAt: chapter)
        total = texts.count
        done = texts.filter { BookAudio.currentFile(book: book.id, text: $0) != nil }.count
        BookAudioLog.write("start: \(book.title) \(done)/\(total)")
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task(priority: .userInitiated) { [weak self] in
            do {
                if !HeartModel.ready { try await HeartModel().install { _ in } }
                let warm = Date()
                try await HeartEngine.shared.warmUp()
                BookAudioLog.write(String(format: "engine ready in %.1fs", Date().timeIntervalSince(warm)))
                for text in texts {
                    guard !Task.isCancelled, !flag.cancelled else { return }
                    if BookAudio.currentFile(book: book.id, text: text) != nil { continue }
                    let older = BookAudio.legacyFile(book: book.id, text: text)
                    let url = BookAudio.file(book: book.id, text: text)
                    let started = Date()
                    let wav = try await HeartEngine.shared.render(text, cancellation: flag, cache: false)
                    guard !flag.cancelled else { return }
                    let rendered = Date()
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try BookAudio.encode(wav, to: url)
                            await BookAudioTimings.store(wav: wav, for: url, text: text)
                            if let older { try? FileManager.default.removeItem(at: older) }
                        }.value
                    } catch {
                        if older != nil { throw error }
                        // If AAC encoding is unavailable, keep the sentence as WAV.
                        BookAudioLog.write("encode failed, saved WAV: \(BookAudioLog.describe(error))")
                        try wav.write(to: url.deletingPathExtension().appendingPathExtension("wav"), options: .atomic)
                    }
                    guard !Task.isCancelled, !flag.cancelled else { return }
                    let render = rendered.timeIntervalSince(started), encode = Date().timeIntervalSince(rendered)
                    await MainActor.run {
                        guard let self, !flag.cancelled else { return }
                        self.done += 1
                        if self.done % 10 == 0 || UIApplication.shared.applicationState != .active {
                            BookAudioLog.write(String(format: "progress %d/%d render %.1fs encode %.2fs thermal %d", self.done, self.total, render, encode, ProcessInfo.processInfo.thermalState.rawValue))
                        }
                    }
                }
                guard !Task.isCancelled, !flag.cancelled else { return }
                await MainActor.run {
                    guard !flag.cancelled else { return }
                    BookAudioLog.write("finished")
                    self?.running = false; UIApplication.shared.isIdleTimerDisabled = false
                }
            } catch {
                guard !flag.cancelled, !Task.isCancelled else { return }
                await MainActor.run {
                    self?.pause(reason: "error \(BookAudioLog.describe(error))")
                    self?.error = "生成全书音频时出错：\(error.localizedDescription)。已完成的部分已保存，可以继续生成。"
                }
            }
        }
    }

}


/// A small rolling log for book-audio generation, readable from the device container
/// (Library/Application Support/Diagnostics/bookaudio.log) when something fails in the background.
@MainActor
enum BookAudioLog {
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics/bookaudio.log")
    }
    private static var observers: [NSObjectProtocol] = []
    static func write(_ message: String) {
        startObservingLifecycle()
        let state: String
        switch UIApplication.shared.applicationState {
        case .active: state = "fg"
        case .inactive: state = "inactive"
        default: state = "bg"
        }
        let line = "\(Date().formatted(.iso8601)) [\(state)] \(message)\n"
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 256_000 { try? fm.removeItem(at: url) }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
    nonisolated static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code) \(ns.localizedDescription)"
    }
    private static func startObservingLifecycle() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in BookAudioLog.write("app entered background") }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in BookAudioLog.write("app returning to foreground") }
            },
            center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in BookAudioLog.write("memory warning") }
            }
        ]
    }
}
