#if WIDGET

import SwiftUI
import WidgetKit

struct Now: TimelineEntry {

    let date: Date
}

struct Source: TimelineProvider {

    func placeholder(in context: Context) -> Now {
        Now(date: Date())
    }

    func getSnapshot(in context: Context,
                     completion: @escaping @Sendable (Now) -> Void) {
        completion(Now(date: Date()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping @Sendable (Timeline<Now>) -> Void
    ) {
        completion(Timeline(entries: [Now(date: Date())], policy: .never))
    }
}

struct Mark: View {

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: "mic.fill")
                .font(.system(size: 20, weight: .semibold))
        }
        .containerBackground(.clear, for: .widget)
    }
}

@main
struct Dial: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "io.github.leok7v.watch.dial",
                            provider: Source()) { _ in
            Mark()
        }
        .configurationDisplayName("AGI")
        .description("Tap to talk.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner,
                            .accessoryRectangular])
    }
}

#else

import AVFoundation
import SwiftUI
import UserNotifications
import WatchKit

let system = "You are a voice assistant on a watch. Answer in one or two "
    + "short spoken sentences. You do not know the time, the battery, the "
    + "weather or the news: call a function for them and for a timer."

nonisolated(unsafe) let halt = UnsafeMutablePointer<Bool>.allocate(capacity: 1)

final class Reply: @unchecked Sendable {

    private let sink: @Sendable (String) -> Void
    private var sent = 0
    var full = false

    init(_ sink: @escaping @Sendable (String) -> Void) {
        self.sink = sink
    }

    func grow(_ text: String, _ ended: Bool) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = sentences(spoken(clean))
        let whole = ended ? all.count : all.count - 1
        let ready = clean.hasPrefix("<") ? 0 : min(2, whole)
        while sent < ready {
            sink(all[sent])
            sent += 1
        }
        full = sent >= 2
    }
}

func reply(_ who: UnsafeMutableRawPointer?) -> Reply? {
    who.map { raw in Unmanaged<Reply>.fromOpaque(raw).takeUnretainedValue() }
}

let alive: @convention(c) (UnsafeMutableRawPointer?) -> Bool = { who in
    !halt.pointee && !(reply(who)?.full ?? false)
}

let said: @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32
) -> Void = { who, text, _ in
    if let text { reply(who)?.grow(String(cString: text), false) }
}

final class Job {

    let work: () -> Void

    init(_ work: @escaping () -> Void) {
        self.work = work
    }
}

func safely(_ what: String, _ work: () -> Void) {
    withoutActuallyEscaping(work) { escaping in
        let job = Job(escaping)
        let failed = withExtendedLifetime(job) {
            guarded({ context in
                if let context {
                    Unmanaged<Job>.fromOpaque(context).takeUnretainedValue()
                        .work()
                }
            }, Unmanaged.passUnretained(job).toOpaque())
        }
        if let failed {
            note(what + ": " + String(cString: failed) + " failed")
        }
    }
}

enum Log {

    static let home = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0].path
    static let path = home + "/watch.log"
    static let lock = NSLock()

    static let file = made()

    static func made() -> FileHandle? {
        let files = FileManager.default
        let size = (try? files.attributesOfItem(atPath: path))?[.size]
        if (size as? Int ?? -1) < 0 || (size as? Int ?? 0) > 1_000_000 {
            try? files.createDirectory(atPath: home,
                                       withIntermediateDirectories: true)
            files.createFile(atPath: path, contents: nil)
        }
        let handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
        return handle
    }
}

func note(_ text: String) {
    let flat = text.replacingOccurrences(of: "\n", with: "\\n")
    let line = Date().ISO8601Format() + " " + flat + "\n"
    Log.lock.lock()
    FileHandle.standardError.write(Data(("watch: " + flat + "\n").utf8))
    Log.file?.write(Data(line.utf8))
    Log.lock.unlock()
}

func string(_ chars: [CChar]) -> String {
    let bytes = chars.prefix { c in c != 0 }.map { c in UInt8(bitPattern: c) }
    return String(decoding: bytes, as: UTF8.self)
}

enum Args {

    static let defaults = [
        "weights=packed", "context=4096", "shift=soft", "tokens=96",
        "temperature=0", "language=en", "voice=F1", "beam=2"]

    static let state = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("talk.state").path

    static let stored = (try? String(contentsOfFile: Log.home + "/words.txt",
                                     encoding: .utf8)) ?? ""

    static let words = defaults + ["state=" + state]
        + stored.split(whereSeparator: { c in c.isWhitespace })
        .map { word in String(word) }
        + CommandLine.arguments.dropFirst()
        .filter { word in word.contains("=") && !word.hasPrefix("-") }

    nonisolated(unsafe) static let list = made()

    static func made() -> UnsafePointer<UnsafePointer<CChar>?> {
        let out = UnsafeMutablePointer<UnsafePointer<CChar>?>
            .allocate(capacity: words.count + 1)
        for (i, word) in words.enumerated() {
            out[i] = UnsafePointer(strdup(word))
        }
        out[words.count] = nil
        return UnsafePointer(out)
    }

    static func value(_ key: String) -> String? {
        words.last { word in word.hasPrefix(key + "=") }
            .map { word in String(word.dropFirst(key.count + 1)) }
    }

    static func on(_ key: String) -> Bool { value(key) == "1" }

    static let steps = ["wav", "mic", "text", "tool", "probe", "tap"]

    static let scripted = on("exit") ||
        steps.contains { key in value(key) != nil }
}

enum Models {

    static let whistle = ("whistle", "whistle.cact")
    static let falcon = ("Falcon-H1-Tiny-Tool-Calling-90M-GGUF",
                         "Falcon-H1-Tiny-90M-Tool-Calling-Q8_0.gguf")
    static let supertonic = ("supertonic", "supertonic-q4.safetensors")

    static func path(_ model: (String, String)) -> String? {
        let root = Args.value("models") ?? ""
        let places = [root + "/" + model.0 + "/" + model.1,
                      root + "/" + model.1,
                      Log.home + "/" + model.1,
                      Bundle.main.bundlePath + "/" + model.1]
        return places.first { place in
            FileManager.default.fileExists(atPath: place)
        }
    }
}

final class Engines: @unchecked Sendable {

    private let queue = DispatchQueue(label: "engines",
                                      qos: .userInitiated)
    private let voice = DispatchQueue(label: "voice", qos: .userInitiated)
    private var back: UnsafeMutablePointer<backend>?
    private var ear: UnsafeMutablePointer<asr>?
    private var mind: UnsafeMutablePointer<llm>?
    private var mouth: UnsafeMutablePointer<tts>?

    static let empty: Set<String> = ["Thank you."]
    static let sure = Float(Args.value("sure") ?? "") ?? -0.4

    func run<T: Sendable>(
        _ work: @escaping @Sendable (Engines) -> T
    ) async -> T {
        await withCheckedContinuation { done in
            queue.async { done.resume(returning: work(self)) }
        }
    }

    func utter(_ text: String, _ name: String) async -> Data {
        await withCheckedContinuation { done in
            voice.async { done.resume(returning: self.speak(text, name)) }
        }
    }

    func open() -> String {
        let started = Date()
        var had = 0
        if Args.on("fresh") {
            try? FileManager.default.removeItem(atPath: Args.state)
        }
        safely("open") {
            back = backend_open(Args.value("gemm"), Args.list)
            ear = asr_open("whistle", Models.path(Models.whistle), back,
                           Args.list)
            mind = llm_open("falcon", Models.path(Models.falcon), back,
                            Args.list)
            mouth = tts_open("supertonic", Models.path(Models.supertonic),
                             back, Args.list)
            had = kept()
            if had == 0 {
                prime()
            } else if let mind, !Args.on("plain") {
                mind.pointee.message(mind, "tools", Tools.json)
            }
        }
        let took = String(format: "%.2f", Date().timeIntervalSince(started))
        note("open: " + took + " s, \(had) tokens of talk kept")
        return back == nil ? "backend" : ear == nil ? "whistle" :
               mind == nil ? "falcon" : mouth == nil ? "supertonic" : ""
    }

    func settle(_ text: String) {
        add("tool", text)
        if answer(literal(text), { _ in }).isEmpty {
            add("assistant", text)
        }
    }

    func probe() {
        let x = (0 ..< 256 * 512).map { i in Float(i % 13) * 0.1 }
        let w = (0 ..< 1688 * 512).map { i in Float(i % 17) * 0.01 }
        var y = [Float](repeating: 0, count: 256 * 1688)
        let cores = ProcessInfo.processInfo.activeProcessorCount
        note("probe: \(cores) processors")
        for _ in 0 ..< 5 {
            let started = Date()
            x.withUnsafeBufferPointer { a in
                w.withUnsafeBufferPointer { b in
                    y.withUnsafeMutableBufferPointer { c in
                        product(a.baseAddress, b.baseAddress, c.baseAddress)
                    }
                }
            }
            let took = Date().timeIntervalSince(started)
            let rate = 2.0 * 256 * 1688 * 512 / took / 1e9
            note("probe: gemm 256x1688x512 in "
                + String(format: "%.2f ms, %.0f GFLOPS", took * 1e3, rate))
        }
    }

    func product(_ a: UnsafePointer<Float>?, _ b: UnsafePointer<Float>?,
                 _ c: UnsafeMutablePointer<Float>?) {
        if let back {
            var g = gemm_args(a: a, b: b, c: c, m: 256, n: 1688, k: 512,
                              lda: 512, ldb: 512, ldc: 1688, ta: false,
                              tb: true)
            back.pointee.gemm(back, &g)
        }
    }

    func kept() -> Int {
        let context = Int(Args.value("context") ?? "") ?? 0
        return mind.map { m in context - Int(m.pointee.room(m)) } ?? 0
    }

    func prime() {
        if let mind {
            mind.pointee.reset(mind)
            if !Args.on("plain") {
                mind.pointee.message(mind, "tools", Tools.json)
            }
            mind.pointee.message(mind, "system", system)
        }
    }

    func hear(_ samples: [Float]) -> (String, Float) {
        var text = [CChar](repeating: 0, count: 8192)
        var list = [piece](repeating: piece(), count: 1024)
        var count = 0
        let started = Date()
        if let ear {
            safely("hear") {
                list.withUnsafeMutableBufferPointer { room in
                    var got = pieces(list: room.baseAddress, capacity: 1024,
                                     count: 0)
                    _ = ear.pointee.transcribe(
                        ear, samples, Int32(samples.count),
                        Args.value("language") ?? "", &text,
                        Int32(text.count), &got)
                    count = Int(got.count)
                }
            }
        }
        let took = String(format: "%.2f", Date().timeIntervalSince(started))
        let length = String(format: "%.2f", Double(samples.count) / 16000)
        var sum: Float = 0
        for one in list.prefix(count) { sum += one.score }
        let score = sum / Float(max(1, count))
        note("hear: " + length + " s of sound in " + took + " s, score "
            + String(format: "%.2f", score) + ": " + string(text))
        let heard = string(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (Engines.empty.contains(heard) ? "" : heard, score)
    }

    func add(_ role: String, _ content: String) {
        if let mind {
            safely("add") { mind.pointee.message(mind, role, content) }
        }
    }

    func rewind() {
        if let mind {
            safely("rewind") { mind.pointee.rewind(mind, 1) }
        }
    }

    func answer(_ script: String,
                _ sink: @escaping @Sendable (String) -> Void) -> String {
        var text = [CChar](repeating: 0, count: 8192)
        var t = turn()
        let started = Date()
        var count: Int32 = 0
        let heard = Reply(sink)
        turn_read(&t, Args.list)
        t.alive = alive
        t.said = said
        t.who = Unmanaged.passUnretained(heard).toOpaque()
        if let mind {
            safely("answer") {
                script.withCString { s in
                    t.script = s
                    count = mind.pointee.reply(mind, &text,
                                               Int32(text.count), &t)
                }
            }
        }
        withExtendedLifetime(heard) { heard.grow(string(text), true) }
        if t.full { prime() }
        let took = Date().timeIntervalSince(started)
        note("answer: fed \(t.fed), \(count) tokens in "
            + String(format: "%.2f", took) + " s"
            + (t.full ? ", the context was full" : ""))
        return string(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func speak(_ text: String, _ voice: String) -> Data {
        var out = Data()
        var bytes = 0
        let started = Date()
        if let mouth {
            safely("speak") {
                if let wave = mouth.pointee.wave(mouth, text, voice,
                                                 &bytes) {
                    out = Data(bytes: wave, count: bytes)
                    free(wave)
                }
            }
        }
        let took = String(format: "%.2f", Date().timeIntervalSince(started))
        let length = String(format: "%.2f",
                            Double(max(0, out.count - 44)) / 88200)
        note("speak: " + length + " s of sound in " + took + " s")
        return out
    }
}

func resample(_ input: [Float], _ from: Double) -> [Float] {
    let ratio = from / 16000
    let count = ratio > 0 ? Int(Double(input.count) / ratio) : 0
    var out = [Float](repeating: 0, count: count)
    for i in 0 ..< count {
        let begin = Int(Double(i) * ratio)
        let end = min(input.count, max(begin + 1, Int(Double(i + 1) * ratio)))
        var sum: Float = 0
        for k in begin ..< end { sum += input[k] }
        out[i] = sum / Float(max(1, end - begin))
    }
    return out
}

func wave(_ samples: [Float]) -> Data {
    let bytes = UInt32(samples.count * 2)
    let head: [UInt32] = [
        0x46464952, 36 + bytes, 0x45564157, 0x20746d66, 16, 0x00010001,
        16000, 32000, 0x00100002, 0x61746164, bytes]
    var out = Data()
    for word in head {
        withUnsafeBytes(of: word.littleEndian) { raw in
            out.append(contentsOf: raw)
        }
    }
    for v in samples {
        let one = Int16(max(-1, min(1, v)) * 32767)
        withUnsafeBytes(of: one.littleEndian) { raw in
            out.append(contentsOf: raw)
        }
    }
    return out
}

func clip(_ name: String) -> [Float] {
    let path = name.hasPrefix("/") ? name : Log.home + "/" + name
    var out: [Float] = []
    var samples: UnsafeMutablePointer<Float>? = nil
    if let data = FileManager.default.contents(atPath: path) {
        let count = data.withUnsafeBytes { raw in
            wav_samples(raw.bindMemory(to: UInt8.self).baseAddress,
                        data.count, &samples)
        }
        if let samples, count > 0 {
            out = Array(UnsafeBufferPointer(start: samples,
                                            count: Int(count)))
        }
        free(samples)
    }
    if out.isEmpty { note("wav: cannot read " + path) }
    return out
}

func loudness(_ buffer: AVAudioPCMBuffer) -> Float {
    let count = Int(buffer.frameLength)
    var sum: Float = 0
    if let channels = buffer.floatChannelData {
        for i in 0 ..< count { sum += channels[0][i] * channels[0][i] }
    }
    return (sum / Float(max(1, count))).squareRoot()
}

final class Take: @unchecked Sendable {

    private let lock = NSLock()
    private let rate: Double
    private let floor: Float
    private let ended: @Sendable () -> Void
    private let meter: @Sendable (Float) -> Void
    private var chunks = 0
    private var data: [Float] = []
    private var voiced = 0
    private var quiet = 0
    private var peak: Float = 0
    private var low: Float = 1
    private var fired = false

    init(_ rate: Double = 16000,
         _ ended: @escaping @Sendable () -> Void = {},
         _ meter: @escaping @Sendable (Float) -> Void = { _ in }) {
        self.rate = rate
        self.ended = ended
        self.meter = meter
        floor = Float(Args.value("floor") ?? "") ?? 0.004
    }

    func add(_ buffer: AVAudioPCMBuffer) {
        let count = Int(buffer.frameLength)
        if let channels = buffer.floatChannelData, count > 0 {
            let chunk = UnsafeBufferPointer(start: channels[0], count: count)
            let level = loudness(buffer)
            lock.lock()
            low = level > 0 ? min(low, level) : low
            peak = max(peak, level)
            let loud = level > max(floor, 3 * low, 0.4 * peak)
            data.append(contentsOf: chunk)
            voiced += loud ? count : 0
            quiet = loud ? 0 : quiet + count
            let spoke = Double(voiced) > 0.2 * rate &&
                        Double(quiet) > 0.9 * rate
            let long = Double(data.count) > 28 * rate
            let silent = Double(voiced) < 0.1 * rate &&
                         Double(data.count) > 4 * rate
            let fire = !fired && (spoke || long || silent)
            fired = fired || fire
            chunks += 1
            let show = chunks % 3 == 0
            let shown = loud ? min(1, level / peak) : 0
            lock.unlock()
            if show { meter(shown) }
            if fire { ended() }
        }
    }

    func samples() -> [Float] {
        lock.lock()
        let tail = max(0, quiet - Int(0.2 * rate))
        let none = Double(voiced) < 0.1 * rate
        let all = none ? [] : Array(data.dropLast(tail))
        let loud = Int(Double(voiced) / rate * 1000)
        let top = String(format: "%.4f", peak)
        let least = String(format: "%.4f", low)
        lock.unlock()
        note("take: \(loud) ms of voice, level \(least) to \(top)")
        return resample(all, rate)
    }

    func done() -> Bool {
        lock.lock()
        let out = fired
        lock.unlock()
        return out
    }

    func spoke() -> Bool {
        lock.lock()
        let out = Double(voiced) >= 0.1 * rate
        lock.unlock()
        return out
    }

    static func fed(_ samples: [Float]) -> [Float] {
        let take = Take()
        let form = AVAudioFormat(standardFormatWithSampleRate: 16000,
                                 channels: 1)
        for start in stride(from: 0, to: samples.count, by: 1024)
        where !take.done() {
            let count = min(1024, samples.count - start)
            if let form,
               let buffer = AVAudioPCMBuffer(pcmFormat: form,
                                             frameCapacity: 1024),
               let to = buffer.floatChannelData {
                buffer.frameLength = UInt32(count)
                for i in 0 ..< count { to[0][i] = samples[start + i] }
                take.add(buffer)
            }
        }
        let out = take.samples()
        note("take: " + (take.done() ? "ended" : "ran out")
            + " at \(out.count / 16) ms of \(samples.count / 16) ms")
        return out
    }
}

final class Ward: @unchecked Sendable {

    private let lock = NSLock()
    private let bar: Float
    private let barged: @Sendable () -> Void
    private var run = 0
    private var fired = false
    private var top: Float = 0

    init(_ bar: Float = 1, _ barged: @escaping @Sendable () -> Void = {}) {
        self.bar = bar
        self.barged = barged
    }

    func add(_ level: Float) {
        lock.lock()
        top = max(top, level)
        run = level > bar ? run + 1 : 0
        let fire = !fired && run >= 3
        fired = fired || fire
        lock.unlock()
        if fire { barged() }
    }

    func peak() -> Float {
        lock.lock()
        let out = top
        lock.unlock()
        return out
    }
}

final class Sound: @unchecked Sendable {

    private let duplex = Args.on("vp")
    private let bar = Float(Args.value("bar") ?? "") ?? 0.05
    private var ward = Ward()
    private let engine = AVAudioEngine()
    private let ear = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100,
                                       channels: 1)!
    private var wired = false
    private var take = Take()
    private var ends = Date()
    var heard: @Sendable (Float) -> Void = { _ in }
    var played: @Sendable (Float) -> Void = { _ in }

    private func ready() -> Bool {
        do {
            if !wired {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord,
                                        mode: duplex ? .voiceChat : .default)
                try session.setActive(true)
                if duplex {
                    try engine.inputNode.setVoiceProcessingEnabled(true)
                }
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode,
                               format: format)
                engine.mainMixerNode.installTap(
                    onBus: 0, bufferSize: 2048, format: nil
                ) { [weak self] buffer, _ in
                    self?.played(loudness(buffer))
                }
                wired = true
            }
            if !engine.isRunning { try engine.start() }
        } catch {
            note("audio: " + error.localizedDescription)
        }
        return wired && engine.isRunning
    }

    func listen(_ ended: @escaping @Sendable () -> Void) async -> Bool {
        var ok = false
        let allowed = await AVAudioApplication.requestRecordPermission()
        if !allowed { note("listen: no permission") }
        if allowed, ready() {
            let input = (duplex ? engine : ear).inputNode
            let form = input.outputFormat(forBus: 0)
            note("listen: \(Int(form.sampleRate)) Hz")
            if form.sampleRate > 0 {
                let fresh = Take(form.sampleRate, ended, heard)
                take = fresh
                input.removeTap(onBus: 0)
                input.installTap(onBus: 0, bufferSize: 1024,
                                 format: form) { buffer, _ in
                    fresh.add(buffer)
                }
                ok = duplex ? ready() : (try? ear.start()) != nil
            }
            if !ok { _ = stop() }
        }
        return ok
    }

    func watch(_ barged: @escaping @Sendable () -> Void) {
        if duplex, ready() {
            let input = engine.inputNode
            let fresh = Ward(bar, barged)
            ward = fresh
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024,
                             format: input.outputFormat(forBus: 0)
            ) { buffer, _ in
                fresh.add(loudness(buffer))
            }
        }
    }

    func unwatch() -> Float {
        if duplex { engine.inputNode.removeTap(onBus: 0) }
        let top = ward.peak()
        ward = Ward()
        return top
    }

    func voiced() -> Bool {
        take.spoke()
    }

    func stop() -> [Float] {
        (duplex ? engine : ear).inputNode.removeTap(onBus: 0)
        if !duplex { ear.stop() }
        return take.samples()
    }

    private func buffer(_ wav: Data) -> AVAudioPCMBuffer? {
        let count = (wav.count - 44) / 2
        var out: AVAudioPCMBuffer? = nil
        if count > 0,
           let made = AVAudioPCMBuffer(pcmFormat: format,
                                       frameCapacity: UInt32(count)),
           let to = made.floatChannelData {
            made.frameLength = UInt32(count)
            wav.withUnsafeBytes { raw in
                for i in 0 ..< count {
                    let v = raw.loadUnaligned(fromByteOffset: 44 + i * 2,
                                              as: Int16.self)
                    to[0][i] = Float(v) / 32768
                }
            }
            out = made
        }
        return out
    }

    func queue(_ wav: Data) {
        if let made = buffer(wav), ready() {
            let length = Double(made.frameLength) / format.sampleRate
            ends = max(ends, Date()).addingTimeInterval(length)
            player.scheduleBuffer(made, completionHandler: nil)
            if !player.isPlaying { player.play() }
        } else {
            note("audio: the sound did not start")
        }
    }

    func drain() async {
        while Date() < ends && engine.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if Date() < ends { note("audio: the engine stopped in a sound") }
        ends = Date()
    }

    func hush() {
        player.stop()
        ends = Date()
    }
}

func sentences(_ text: String) -> [String] {
    var out: [String] = []
    var piece = ""
    var last: Character = " "
    for c in text {
        let ends = last == "." || last == "!" || last == "?"
        if ends && c.isWhitespace && !piece.isEmpty {
            out.append(piece)
            piece = ""
        }
        if !(piece.isEmpty && c.isWhitespace) {
            piece.append(c.isNewline ? " " : c)
        }
        last = c
    }
    if !piece.isEmpty { out.append(piece) }
    return out
}

func spoken(_ text: String) -> String {
    let marks: Set<Character> = ["*", "#", "`", "_", "<", ">", "{", "}"]
    return String(text.filter { c in !marks.contains(c) })
}

func literal(_ text: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [text])
    let list = String(decoding: data ?? Data(), as: UTF8.self)
    return String(list.dropFirst().dropLast())
}

func number(_ word: String) -> Int? {
    let names = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20,
        "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "ninety": 90]
    return Int(word) ?? names[word]
}

func duration(_ text: String) -> Int? {
    let words = text.lowercased()
        .split(whereSeparator: { c in !c.isLetter && !c.isNumber })
        .map { word in String(word) }
    let units = [("second", 1), ("minute", 60), ("hour", 3600)]
    var total = 0
    for i in words.indices where i > 0 {
        let unit = units.first { unit in words[i].hasPrefix(unit.0) }?.1
        if let unit, let ones = number(words[i - 1]) {
            let tens = i > 1 && ones < 10 ? number(words[i - 2]) ?? 0 : 0
            total += ((tens >= 20 ? tens : 0) + ones) * unit
        }
    }
    return total > 0 ? total : nil
}

func span(_ seconds: Int) -> String {
    let whole = seconds % 60 == 0
    let count = whole ? seconds / 60 : seconds
    return "\(count) " + (whole ? "minute" : "second")
        + (count == 1 ? "" : "s")
}

func phrases(_ sentence: String) -> [String] {
    var out: [String] = []
    var piece = ""
    for word in sentence.split(separator: " ") {
        piece += (piece.isEmpty ? "" : " ") + word
        let pause = word.hasSuffix(",") || word.hasSuffix(";") ||
                    word.hasSuffix(":")
        if pause && piece.count >= 30 {
            out.append(piece)
            piece = ""
        }
    }
    if piece.count < 12, let last = out.popLast() {
        piece = last + " " + piece
    }
    if !piece.isEmpty { out.append(piece) }
    return out
}

struct Outcome: Sendable {

    let ok: Bool
    let text: String

    init(_ ok: Bool, _ text: String) {
        self.ok = ok
        self.text = text
    }
}

struct Call: Sendable {

    let name: String
    let args: [String: String]

    var label: String {
        Tools.specs.first { spec in spec.name == name }?.label ?? name
    }

    static func parse(_ text: String) -> Call? {
        var out: Call? = nil
        for piece in objects(text) where out == nil {
            let parsed = try? JSONSerialization.jsonObject(
                with: Data(piece.utf8))
            if let object = parsed as? [String: Any],
               let name = object["name"] as? String,
               Tools.specs.contains(where: { spec in spec.name == name }) {
                out = Call(name: name, args: strings(object["arguments"]))
            }
        }
        return out
    }

    func timed(_ heard: String) -> Call {
        var fixed = args
        if name == "set_timer" {
            fixed["seconds"] = duration(heard).map { seconds in
                "\(seconds)"
            }
        }
        return Call(name: name, args: fixed)
    }

    static func objects(_ text: String) -> [String] {
        var out: [String] = []
        var piece = ""
        var depth = 0
        var quoted = false
        var escaped = false
        for c in text {
            let closes = !quoted && c == "}" && depth > 0
            depth += !quoted && c == "{" ? 1 : 0
            if depth > 0 { piece.append(c) }
            if c == "\"" && !escaped && depth > 0 { quoted.toggle() }
            escaped = quoted && c == "\\" && !escaped
            depth -= closes ? 1 : 0
            if closes && depth == 0 {
                out.append(piece)
                piece = ""
            }
        }
        return out
    }

    static func strings(_ value: Any?) -> [String: String] {
        var out: [String: String] = [:]
        if let map = value as? [String: Any] {
            for (key, item) in map { out[key] = "\(item)" }
        } else if let text = value as? String {
            let parsed = try? JSONSerialization.jsonObject(
                with: Data(text.utf8))
            if let map = parsed as? [String: Any] {
                for (key, item) in map { out[key] = "\(item)" }
            }
        }
        return out
    }
}

struct Spec: Sendable {

    let name: String
    let label: String
    let about: String
    let cues: [String]
    let kind: String
    let key: String
    let hint: String

    init(_ name: String, _ label: String, _ about: String,
         _ cues: [String], _ kind: String = "", _ key: String = "",
         _ hint: String = "") {
        self.name = name
        self.label = label
        self.about = about
        self.cues = cues
        self.kind = kind
        self.key = key
        self.hint = hint
    }

    var object: [String: Any] {
        let property: [String: Any] = ["type": kind, "description": hint]
        let properties: [String: Any] = key.isEmpty ? [:] : [key: property]
        let required: [String] = key.isEmpty ? [] : [key]
        let parameters: [String: Any] = [
            "type": "object", "properties": properties,
            "required": required]
        let function: [String: Any] = [
            "name": name, "description": about, "parameters": parameters]
        return ["type": "function", "function": function]
    }
}

struct Hit: Sendable {

    let title: String
    let url: String
    let extract: String
}

enum Web {

    static func get(_ base: String, _ query: [(String, String)],
                    _ agent: String = "") async -> Data? {
        var out: Data? = nil
        var parts = URLComponents(string: base)
        parts?.queryItems = query.map { pair in
            URLQueryItem(name: pair.0, value: pair.1)
        }
        if let url = parts?.url {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            if !agent.isEmpty {
                request.setValue(agent, forHTTPHeaderField: "User-Agent")
            }
            let answer = try? await URLSession.shared.data(for: request)
            let code = (answer?.1 as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { out = answer?.0 }
            if out == nil { note("web: \(base) -> HTTP \(code)") }
        }
        return out
    }

    static func map(_ data: Data?) -> [String: Any] {
        let parsed = try? JSONSerialization.jsonObject(with: data ?? Data())
        return parsed as? [String: Any] ?? [:]
    }
}

actor Parallel {

    static let shared = Parallel()

    private static let endpoint = URL(
        string: "https://search.parallel.ai/mcp")!
    private static let version = "2025-06-18"

    private var session = ""
    private var tool = ""
    private var arrays: [String] = []
    private var scalars: [String] = []
    private var serial = 0

    func search(_ query: String, _ count: Int) async -> [Hit] {
        var out: [Hit] = []
        do {
            try await ready()
            var arguments: [String: Any] = [:]
            for key in arrays { arguments[key] = [query] }
            for key in scalars { arguments[key] = query }
            let answer = try await rpc(
                "tools/call", ["name": tool, "arguments": arguments])
            out = Parallel.hits(Parallel.text(answer), count, query)
        } catch {
            session = ""
            tool = ""
            note("search: parallel failed: " + error.localizedDescription)
        }
        return out
    }

    private func ready() async throws {
        if tool.isEmpty {
            let hello: [String: Any] = [
                "protocolVersion": Parallel.version, "capabilities": [:],
                "clientInfo": ["name": "watch", "version": "1.0"]]
            _ = try await rpc("initialize", hello)
            _ = try await exchange(
                ["jsonrpc": "2.0", "method": "notifications/initialized"])
            let listed = try await rpc("tools/list", [:])
            adopt(listed["tools"] as? [[String: Any]] ?? [])
        }
    }

    private func adopt(_ tools: [[String: Any]]) {
        let chosen = tools.first { item in
            item["name"] as? String == "web_search"
        } ?? tools.first ?? [:]
        let schema = chosen["inputSchema"] as? [String: Any] ?? [:]
        let properties = schema["properties"] as? [String: Any] ?? [:]
        tool = chosen["name"] as? String ?? "web_search"
        arrays = []
        scalars = []
        for key in schema["required"] as? [String] ?? [] {
            let spec = properties[key] as? [String: Any] ?? [:]
            if spec["type"] as? String == "array" {
                arrays.append(key)
            } else {
                scalars.append(key)
            }
        }
    }

    private func rpc(_ method: String,
                     _ params: [String: Any]) async throws -> [String: Any] {
        serial += 1
        let message = try await exchange(
            ["jsonrpc": "2.0", "id": serial, "method": method,
             "params": params])
        if message["error"] != nil { throw URLError(.badServerResponse) }
        return message["result"] as? [String: Any] ?? [:]
    }

    private func exchange(
        _ body: [String: Any]
    ) async throws -> [String: Any] {
        var request = URLRequest(url: Parallel.endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10
        request.setValue("application/json",
                         forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream",
                         forHTTPHeaderField: "Accept")
        request.setValue(Parallel.version,
                         forHTTPHeaderField: "MCP-Protocol-Version")
        if !session.isEmpty {
            request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
        }
        let (answer, response) = try await URLSession.shared.data(
            for: request)
        let http = response as? HTTPURLResponse
        if !(200 ... 299).contains(http?.statusCode ?? 0) {
            throw URLError(.badServerResponse)
        }
        if session.isEmpty {
            session = http?.value(forHTTPHeaderField: "Mcp-Session-Id") ?? ""
        }
        return Parallel.decode(answer)
    }

    static func decode(_ answer: Data) -> [String: Any] {
        let text = String(decoding: answer, as: UTF8.self)
        var body = text
        if text.hasPrefix("event:") || text.hasPrefix("data:") {
            body = text.split(separator: "\n").filter { line in
                line.hasPrefix("data: ")
            }.map { line in
                String(line.dropFirst(6))
            }.joined()
        }
        return Web.map(Data(body.utf8))
    }

    static func text(_ result: [String: Any]) -> String {
        var out = ""
        for item in result["content"] as? [[String: Any]] ?? [] {
            out += item["text"] as? String ?? ""
        }
        return out
    }

    static func hits(_ text: String, _ count: Int,
                     _ query: String) -> [Hit] {
        var out: [Hit] = []
        let items = Web.map(Data(text.utf8))["results"] as? [[String: Any]]
        for item in items ?? [] where out.count < count {
            out.append(Hit(
                title: item["title"] as? String ?? "",
                url: item["url"] as? String ?? "",
                extract: Search.excerpt(item["excerpts"] as? [String] ?? [],
                                        query)))
        }
        return out
    }
}

struct Page {

    static let headings: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
    static let inline: Set<String> = ["b", "i", "em", "strong", "span"]
    static let hidden: Set<String> = ["script", "style"]
    static let marks = [
        ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#x27;", "'"),
        ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")]

    private var rows: [(url: String, title: String, text: String)] = []
    private var heading = 0
    private var mute = 0
    private var titled = false
    private var line = ""

    static func hits(_ html: String, _ count: Int) -> [Hit] {
        var page = Page()
        let pieces = html.split(separator: "<",
                                omittingEmptySubsequences: false)
        for piece in pieces {
            let parts = piece.split(separator: ">", maxSplits: 1,
                                    omittingEmptySubsequences: false)
            if parts.count == 2 {
                page.tag(parts[0])
                page.line += page.mute == 0 ? parts[1] : ""
            }
        }
        page.flush()
        return page.rows.filter { row in !row.title.isEmpty }.prefix(count)
            .map { row in
                Hit(title: row.title, url: row.url, extract: row.text)
            }
    }

    static func plain(_ text: String) -> String {
        var out = text
        for (mark, glyph) in marks {
            out = out.replacingOccurrences(of: mark, with: glyph)
        }
        return out.split(whereSeparator: { c in c.isWhitespace })
            .joined(separator: " ")
    }

    static func target(_ raw: Substring) -> String {
        let parts = raw.components(separatedBy: "href=\"")
        let href = parts.count > 1 ?
            String(parts[1].prefix { c in c != "\"" }) : ""
        let full = plain(href.hasPrefix("//") ? "https:" + href : href)
        let wrapped = URLComponents(string: full)?.queryItems?
            .first { item in item.name == "uddg" }?.value
        let url = wrapped ?? full
        let host = URLComponents(string: url)?.host ?? ""
        return host.isEmpty || host.hasSuffix("duckduckgo.com") ? "" : url
    }

    private mutating func tag(_ raw: Substring) {
        let closes = raw.hasPrefix("/")
        let name = raw.dropFirst(closes ? 1 : 0)
            .prefix { c in c.isLetter || c.isNumber }.lowercased()
        let step = closes ? -1 : 1
        if Page.hidden.contains(name) {
            mute = max(0, mute + step)
        } else if Page.headings.contains(name) {
            flush()
            heading = max(0, heading + step)
        } else if name == "a" {
            let url = closes ? "" : Page.target(raw)
            flush()
            titled = heading > 0 && !url.isEmpty
            if titled { rows.append((url, "", "")) }
        } else if !Page.inline.contains(name) {
            flush()
        }
    }

    private mutating func flush() {
        let text = Page.plain(line)
        line = ""
        if let last = rows.indices.last {
            if titled {
                rows[last].title += text
            } else if text.count > rows[last].text.count {
                rows[last].text = text
            }
        }
    }
}

enum Search {

    static let engines = ["parallel", "duck", "mwmbl"]
    static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 "
        + "Safari/605.1.15"
    static let common: Set<String> = [
        "the", "and", "for", "what", "how", "who", "when", "where", "which",
        "does", "did", "are", "was", "web", "search"]

    static func run(_ query: String) async -> [Hit] {
        let only = Args.value("search") ?? ""
        var hits: [Hit] = []
        for name in engines where hits.isEmpty &&
                                  (only.isEmpty || only == name) {
            hits = await one(name, query)
            note("search: " + name + " gave \(hits.count)")
        }
        return hits
    }

    static func one(_ name: String, _ query: String) async -> [Hit] {
        let out: [Hit]
        switch name {
        case "parallel": out = await Parallel.shared.search(query, 3)
        case "duck": out = await duck(query, 3)
        default: out = await mwmbl(query, 3)
        }
        return out
    }

    static func words(_ query: String) -> [String] {
        query.lowercased()
            .split(whereSeparator: { c in !c.isLetter && !c.isNumber })
            .map { word in String(word) }
            .filter { word in word.count > 2 && !common.contains(word) }
    }

    static func score(_ text: String, _ words: [String]) -> Int {
        let low = text.lowercased()
        let matched = words.filter { word in low.contains(word) }.count
        return 2 * matched + (text.contains { c in c.isNumber } ? 1 : 0)
    }

    static func prose(_ line: Substring) -> String {
        let text = line.trimmingCharacters(
            in: CharacterSet(charactersIn: " \t*-"))
        return text.hasPrefix("#") ? "" : text
            .replacing(/!\[[^\]]*\]\([^)]*\)/, with: "")
            .replacing(/\[([^\]]*)\]\([^)]*\)/) { match in match.1 }
    }

    static func fits(_ text: String) -> Bool {
        (40 ... 240).contains(text.count) && text.contains(" ") &&
        !text.hasSuffix("?") && !text.contains("[") && !text.contains("]")
    }

    static func lines(_ raw: [String]) -> [String] {
        var out: [String] = []
        for block in raw {
            for line in block.split(separator: "\n") {
                for text in sentences(prose(line)) where fits(text) {
                    out.append(text)
                }
            }
        }
        return out
    }

    static func excerpt(_ raw: [String], _ query: String) -> String {
        let wanted = words(query)
        let found = lines(raw)
        let all = found.isEmpty ? Array(raw.prefix(1)) : found
        let ranked = all.indices.sorted { a, b in
            let x = score(all[a], wanted)
            let y = score(all[b], wanted)
            return x > y || (x == y && a < b)
        }
        let text = ranked.prefix(2).sorted().map { i in all[i] }
            .joined(separator: " ")
        return String(Page.plain(text).prefix(400))
    }

    static func duck(_ query: String, _ count: Int) async -> [Hit] {
        let data = await Web.get("https://html.duckduckgo.com/html/",
                                 [("q", query)], agent)
        let html = String(decoding: data ?? Data(), as: UTF8.self)
        return Page.hits(html, count).map { hit in
            Hit(title: hit.title, url: hit.url,
                extract: excerpt([hit.extract], query))
        }
    }

    static func mwmbl(_ query: String, _ count: Int) async -> [Hit] {
        var out: [Hit] = []
        let data = await Web.get("https://api.mwmbl.org/api/v1/search/",
                                 [("s", query)])
        let parsed = try? JSONSerialization.jsonObject(with: data ?? Data())
        for item in parsed as? [[String: Any]] ?? [] where out.count < count {
            out.append(Hit(title: spans(item["title"]),
                           url: item["url"] as? String ?? "",
                           extract: excerpt([spans(item["extract"])],
                                            query)))
        }
        return out
    }

    static func spans(_ value: Any?) -> String {
        var text = ""
        for span in value as? [[String: Any]] ?? [] {
            text += span["value"] as? String ?? ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum Tools {

    static let specs = [
        Spec("cancel_timer", "no timer", "Cancel the countdown timer.",
             ["cancel", "stop the timer"]),
        Spec("set_timer", "timer", "Start a countdown timer.",
             ["timer", "alarm", "wake me", "countdown", "remind me"],
             "integer", "seconds", "The length of the timer in seconds."),
        Spec("get_time", "time", "Get the current time and date.",
             ["what time", "the time", "what day", "what date",
              "the date", "clock"]),
        Spec("get_battery", "battery",
             "Get the battery level of the watch.", ["battery", "charge"]),
        Spec("get_weather", "weather",
             "Get the current weather in a city.",
             ["weather", "rain", "umbrella", "temperature", "forecast",
              "snow", "sunny", "cold", "hot"],
             "string", "city", "The name of the city."),
        Spec("web_search", "search",
             "Search the web for a fact or for news.",
             ["search", "news", "latest"],
             "string", "query", "The words to search for.")]

    static let told: Set<String> = ["set_timer"]

    static let json = made()

    static func cued(_ text: String) -> Spec? {
        let words = text.lowercased()
            .split(whereSeparator: { c in !c.isLetter })
        let flat = " " + words.joined(separator: " ")
        return specs.first { spec in
            spec.cues.contains { cue in flat.contains(" " + cue) }
        }
    }

    static func made() -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: specs.map { spec in spec.object },
            options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data ?? Data(), as: UTF8.self)
    }

    static func run(_ call: Call) async -> Outcome {
        var out = Outcome(false, "Sorry, I cannot do that.")
        switch call.name {
        case "get_time": out = time()
        case "set_timer": out = await timer(call)
        case "cancel_timer": out = cancel()
        case "get_battery": out = await battery()
        case "get_weather": out = await weather(call)
        case "web_search": out = await search(call)
        default: note("tool: unknown " + call.name)
        }
        return out
    }

    static func time() -> Outcome {
        let form = DateFormatter()
        form.dateFormat = "h:mm a, EEEE, MMMM d"
        return Outcome(true, "It is " + form.string(from: Date()) + ".")
    }

    static func timer(_ call: Call) async -> Outcome {
        let seconds = Int(Double(call.args["seconds"] ?? "") ?? 0)
        var out = Outcome(false, "For how long?")
        if seconds > 0 {
            let ok = await (Args.on("mock") ? true : armed(seconds))
            out = Outcome(ok, ok ? "Timer set for " + span(seconds) + "."
                                 : "Sorry, the timer failed.")
        }
        return out
    }

    static func cancel() -> Outcome {
        UNUserNotificationCenter.current()
            .removeAllPendingNotificationRequests()
        return Outcome(true, "Timer cancelled.")
    }

    static func armed(_ seconds: Int) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let allowed = try? await center.requestAuthorization(
            options: [.alert, .sound])
        return await (allowed == true ? alert(center, seconds) : false)
    }

    static func alert(_ center: UNUserNotificationCenter,
                      _ seconds: Int) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = "Timer"
        content.body = span(seconds) + " passed."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: Double(seconds), repeats: false)
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content,
            trigger: trigger)
        return (try? await center.add(request)) != nil
    }

    @MainActor static func level() -> Float {
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        return device.batteryLevel
    }

    static func battery() async -> Outcome {
        let level = await level()
        let percent = Int((level * 100).rounded())
        return level < 0 ? Outcome(false, "Sorry, I cannot read the battery.")
            : Outcome(true, "The battery is at \(percent) percent.")
    }

    static func sky(_ code: Int) -> String {
        let table: [(ClosedRange<Int>, String)] = [
            (0 ... 0, "clear"), (1 ... 2, "partly cloudy"),
            (3 ... 3, "cloudy"), (45 ... 48, "foggy"),
            (51 ... 57, "drizzling"), (61 ... 67, "raining"),
            (71 ... 77, "snowing"), (80 ... 82, "showery"),
            (85 ... 86, "snowing"), (95 ... 99, "stormy")]
        return table.first { row in row.0.contains(code) }?.1 ?? "unsettled"
    }

    static func weather(_ call: Call) async -> Outcome {
        let city = call.args["city"] ?? Args.value("city") ?? ""
        var out = Outcome(false, "Sorry, I could not get the weather.")
        let found = Web.map(await Web.get(
            "https://geocoding-api.open-meteo.com/v1/search",
            [("name", city), ("count", "1")]))
        let place = (found["results"] as? [[String: Any]])?.first
        if let place, let latitude = place["latitude"] as? Double,
           let longitude = place["longitude"] as? Double {
            let now = Web.map(await Web.get(
                "https://api.open-meteo.com/v1/forecast",
                [("latitude", "\(latitude)"), ("longitude", "\(longitude)"),
                 ("current", "temperature_2m,weather_code")]))
            let current = now["current"] as? [String: Any]
            if let degrees = current?["temperature_2m"] as? Double {
                let code = current?["weather_code"] as? Int ?? -1
                let name = place["name"] as? String ?? city
                let whole = Int(degrees.rounded())
                out = Outcome(true, "In \(name) it is \(whole) degrees "
                    + "Celsius and " + sky(code) + ".")
            }
        }
        return out
    }

    static func search(_ call: Call) async -> Outcome {
        let query = call.args["query"] ?? ""
        let hits = query.isEmpty ? [] : await Search.run(query)
        let wanted = Search.words(query)
        let best = hits.filter { hit in !hit.extract.isEmpty }.max { a, b in
            Search.score(a.extract, wanted) < Search.score(b.extract, wanted)
        }
        return best.map { hit in Outcome(true, hit.extract) }
            ?? Outcome(false, "Sorry, the search found nothing.")
    }
}

enum Phase: String {

    case loading
    case idle
    case listening
    case thinking
    case speaking
    case failed

    var symbol: String {
        let out: String
        switch self {
        case .loading: out = "hourglass"
        case .idle: out = "mic.fill"
        case .listening: out = "waveform"
        case .thinking: out = "ellipsis"
        case .speaking: out = "speaker.wave.2.fill"
        case .failed: out = "exclamationmark.triangle.fill"
        }
        return out
    }

    var moves: Bool {
        self == .listening || self == .thinking || self == .speaking
    }

    var color: Color {
        let out: Color
        switch self {
        case .loading: out = .gray
        case .idle: out = .blue
        case .listening: out = .red
        case .thinking: out = .orange
        case .speaking: out = .green
        case .failed: out = .gray
        }
        return out
    }
}

final class Keeper: NSObject, WKExtendedRuntimeSessionDelegate {

    func extendedRuntimeSessionDidStart(_ session: WKExtendedRuntimeSession) {
        note("session: started")
    }

    func extendedRuntimeSessionWillExpire(
        _ session: WKExtendedRuntimeSession
    ) {
        note("session: expires")
    }

    func extendedRuntimeSession(
        _ session: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        note("session: ended, reason \(reason.rawValue) "
            + (error?.localizedDescription ?? ""))
    }
}

@MainActor
final class Talk: ObservableObject {

    @Published var phase = Phase.loading
    @Published var line = ""
    @Published var level = 0.0

    private let engines = Engines()
    private let sound = Sound()
    private var saved = 0
    private var front = false
    private var turn = 0

    @TaskLocal static var mine = 0
    private var awake: WKExtendedRuntimeSession?
    private let keeper = Keeper()

    private func meter(_ wanted: Phase, _ value: Float) {
        if phase == wanted { level = Double(value) }
    }

    func boot() async {
        halt.pointee = false
        note("launch: " + Args.words.dropFirst(Args.defaults.count + 1)
            .joined(separator: " "))
        sound.heard = { value in
            Task { @MainActor in self.meter(.listening, value) }
        }
        sound.played = { value in
            Task { @MainActor in self.meter(.speaking, min(1, value * 6)) }
        }
        let missing = await engines.run { e in e.open() }
        phase = missing.isEmpty ? .idle : .failed
        line = missing.isEmpty ? "" : "no " + missing
        note(missing.isEmpty ? "ready" : "failed: no " + missing)
        if missing.isEmpty {
            for word in Args.words {
                let parts = word.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    await Talk.$mine.withValue(turn) {
                        await step(String(parts[0]), String(parts[1]))
                    }
                }
            }
        }
        auto()
        if Args.on("exit") { exit(missing.isEmpty ? 0 : 1) }
    }

    private func step(_ key: String, _ value: String) async {
        if key == "wav" {
            await heard(clip(value))
        } else if key == "mic" {
            await heard(Take.fed(clip(value)))
        } else if key == "text" {
            await converse(value)
        } else if key == "tool", let call = Call.parse(value) {
            await act(call)
            await sound.drain()
            calm()
        } else if key == "say" {
            await say(value)
            await sound.drain()
        } else if key == "probe" {
            await engines.run { e in e.probe() }
        } else if key == "tap" {
            tap()
            try? await Task.sleep(for: .seconds(Double(value) ?? 0))
        }
    }

    func tap() {
        note("tap: " + phase.rawValue)
        switch phase {
        case .idle: listen()
        case .listening: if sound.voiced() { finish() }
        case .thinking, .speaking: stop()
        case .loading, .failed: note("tap: not ready")
        }
    }

    func seen(_ scene: ScenePhase) {
        note("scene: \(scene), phase " + phase.rawValue)
        front = scene == .active
        if scene == .background { rest() }
        auto()
    }

    private func auto() {
        if front && phase == .idle && !Args.scripted { listen() }
    }

    private func barge() {
        if phase == .thinking || phase == .speaking {
            note("barge: " + phase.rawValue)
            stop()
            turn += 1
            WKInterfaceDevice.current().play(.click)
            listen()
        }
    }

    private func close() {
        if Talk.mine == turn {
            let echo = sound.unwatch()
            if echo > 0 { note("echo: peak " + String(format: "%.4f", echo)) }
            calm()
            auto()
        }
    }

    private func keep(_ samples: [Float]) {
        let files = FileManager.default
        let folder = Log.home + "/takes"
        let stamp = Date().ISO8601Format().replacingOccurrences(of: ":",
                                                                with: "-")
        try? files.createDirectory(atPath: folder,
                                   withIntermediateDirectories: true)
        let old = ((try? files.contentsOfDirectory(atPath: folder)) ?? [])
            .sorted()
        for name in old.dropLast(11) {
            try? files.removeItem(atPath: folder + "/" + name)
        }
        files.createFile(atPath: folder + "/take-" + stamp + ".wav",
                         contents: wave(samples))
        note("take: kept take-" + stamp + ".wav")
    }

    private func listen() {
        line = ""
        phase = .listening
        wake()
        Task {
            let ok = await sound.listen {
                Task { @MainActor in self.finish() }
            }
            line = ok ? "" : "no microphone"
            if !ok { calm() }
        }
    }

    private func finish() {
        if phase == .listening {
            let samples = sound.stop()
            Task {
                await Talk.$mine.withValue(turn) { await heard(samples) }
            }
        }
    }

    private func stop() {
        halt.pointee = true
        sound.hush()
    }

    func rest() {
        note("rest: " + phase.rawValue)
        if phase == .listening {
            _ = sound.stop()
            calm()
        }
    }

    private func wake() {
        if awake?.state != .running {
            let session = WKExtendedRuntimeSession()
            session.delegate = keeper
            session.start()
            awake = session
        }
    }

    private func calm() {
        phase = .idle
        level = 0
        awake?.invalidate()
        awake = nil
    }

    private func heard(_ samples: [Float]) async {
        phase = .thinking
        if !samples.isEmpty { keep(samples) }
        let none: (String, Float) = ("", 0)
        let (text, score) = samples.isEmpty ? none : await engines.run { e in
            e.hear(samples)
        }
        if text.isEmpty {
            note("heard: nothing")
            calm()
        } else if score < Engines.sure {
            note("heard: not sure, " + text)
            halt.pointee = false
            await say("Sorry, I did not catch that.")
            await sound.drain()
            calm()
            auto()
        } else {
            await converse(text)
        }
    }

    private func converse(_ text: String) async {
        note("heard: " + text)
        halt.pointee = false
        phase = .thinking
        line = ""
        wake()
        sound.watch {
            Task { @MainActor in self.barge() }
        }
        await engines.run { e in e.add("user", text) }
        let spec = Args.on("plain") ? nil : Tools.cued(text)
        if let call = await fill(spec) {
            await act(call.timed(text))
        } else if await plain().isEmpty {
            await say("Sorry, I did not get that.")
        }
        await sound.drain()
        close()
    }

    private func plain() async -> String {
        var answer = await reply(Args.value("script") ?? "*")
        if answer.hasPrefix("<") || answer.isEmpty {
            await engines.run { e in e.rewind() }
            answer = await reply("S{1,2}")
        }
        return answer
    }

    private func fill(_ spec: Spec?) async -> Call? {
        var args: [String: String] = [:]
        if let spec, !spec.key.isEmpty, !Tools.told.contains(spec.name) {
            let quote = spec.kind == "string" ? "\"" : ""
            let lead = "<tool_call>\n[\n  {\"name\": \"" + spec.name
                + "\", \"arguments\": {\"" + spec.key + "\": " + quote
            let tail = quote + "}}\n]\n</tool_call>"
            let script = literal(lead) + (quote.isEmpty ? " N " : " T ")
                + literal(tail)
            let filled = await engines.run { e in
                e.answer(script) { _ in }
            }
            note("call: " + filled)
            args = Call.parse(filled)?.args ?? [:]
        }
        return spec.map { spec in Call(name: spec.name, args: args) }
    }

    private func reply(_ script: String) async -> String {
        let (lines, feed) = AsyncStream<String>.makeStream()
        let talker = Task {
            for await sentence in lines { await say(sentence) }
        }
        let answer = await engines.run { e in
            e.answer(script) { sentence in feed.yield(sentence) }
        }
        feed.finish()
        note("reply: " + answer)
        await talker.value
        return answer
    }

    private func act(_ call: Call) async {
        line = call.label
        let done = await Tools.run(call)
        note("tool: " + call.name + (done.ok ? " ok: " : " failed: ")
            + done.text)
        line = call.label + (done.ok ? " \u{2713}" : " \u{2717}")
        let brief = String(done.text.prefix(160))
        async let settled: Void = engines.run { e in e.settle(brief) }
        await say(done.text)
        await settled
    }

    private func save(_ wav: Data) {
        if let folder = Args.value("out"), !wav.isEmpty {
            saved += 1
            let path = folder + "/say-\(saved).wav"
            FileManager.default.createFile(atPath: path, contents: wav)
        }
    }

    private func utter(_ sentence: String) async {
        if !halt.pointee && Talk.mine == turn {
            note("said: " + sentence)
            phase = .speaking
            let wav = await engines.utter(sentence,
                                          Args.value("voice") ?? "F1")
            save(wav)
            if !Args.on("mute") && !halt.pointee { sound.queue(wav) }
        }
    }

    private func say(_ text: String) async {
        for sentence in sentences(text) {
            for part in phrases(sentence) { await utter(part) }
        }
    }
}

struct Bars: View {

    let level: Double
    let wave: Bool

    static let shape = [0.5, 0.8, 1.0, 0.7, 0.45]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: !wave)) { now in
            let t = now.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0 ..< 5, id: \.self) { i in
                    Capsule().fill(.white)
                        .frame(width: 9, height: height(i, t))
                }
            }
            .animation(.linear(duration: 0.08), value: level)
        }
    }

    func height(_ i: Int, _ t: Double) -> Double {
        let moving = 0.5 + 0.5 * sin(t * 6 - Double(i) * 0.9)
        return 10 + 56 * Bars.shape[i] * (wave ? moving : level)
    }
}

struct Face: View {

    @ObservedObject var talk: Talk

    var body: some View {
        VStack(spacing: 8) {
            Button {
                talk.tap()
            } label: {
                ZStack {
                    Circle().fill(talk.phase.color)
                    if talk.phase.moves {
                        Bars(level: talk.level,
                             wave: talk.phase == .thinking)
                    } else {
                        Image(systemName: talk.phase.symbol)
                            .font(.system(size: 52, weight: .semibold))
                    }
                }
                .frame(width: 108, height: 108)
            }
            .buttonStyle(.plain)
            Text(talk.line.isEmpty ? talk.phase.rawValue : talk.line)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .multilineTextAlignment(.center)
        }
    }
}

@main
struct WatchApp: App {

    @StateObject private var talk = Talk()
    @Environment(\.scenePhase) private var scene

    var body: some Scene {
        WindowGroup {
            Face(talk: talk).task { await talk.boot() }
        }
        .onChange(of: scene, initial: true) { _, now in
            talk.seen(now)
        }
    }
}

#endif
