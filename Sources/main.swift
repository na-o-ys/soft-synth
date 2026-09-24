// soft-synth: MIDI 鍵盤を常駐・軽量なやわらかいシンセ音で鳴らすだけのデーモン
import AVFoundation
import CoreBluetooth
import CoreMIDI
import Foundation
import os

// MARK: - MIDI スレッド → オーディオスレッドのイベント受け渡し

enum SynthEvent {
    case noteOn(note: Int, velocity: Int)
    case noteOff(note: Int)
    case sustain(Bool)
    case allNotesOff
}

let eventQueue = OSAllocatedUnfairLock(initialState: [SynthEvent]())

func post(_ e: SynthEvent) {
    eventQueue.withLock { $0.append(e) }
}

// MARK: - シンセ本体（サイン波の加算合成。倍音を控えめにして耳当たりを柔らかく）

struct Voice {
    enum Stage { case attack, decay, release }
    var active = false
    var note = -1
    var gate = false       // 鍵盤を押している
    var sustained = false  // 離したがペダルで保持中
    var stage = Stage.attack
    var env: Float = 0
    var gain: Float = 0
    var panL: Float = 0, panR: Float = 0
    var p1: Float = 0, p2: Float = 0, p3: Float = 0, p4: Float = 0 // 位相
    var i1: Float = 0, i2: Float = 0, i3: Float = 0, i4: Float = 0 // 位相増分
    var h2: Float = 0, h3: Float = 0 // 倍音の量（時間で減衰）
    var age: UInt64 = 0
}

final class Synth {
    static let maxVoices = 32
    let sr: Float
    let voices = UnsafeMutablePointer<Voice>.allocate(capacity: maxVoices)
    var sustainDown = false
    var counter: UInt64 = 0
    let reverb: Reverb

    // エンベロープ係数
    let attackInc: Float
    let decayCoef: Float
    let releaseCoef: Float
    let h2Coef: Float
    let h3Coef: Float
    let sustainLevel: Float = 0.3
    let masterGain: Float = 0.22

    init(sampleRate: Double) {
        sr = Float(sampleRate)
        voices.initialize(repeating: Voice(), count: Synth.maxVoices)
        reverb = Reverb(sampleRate: sr)
        attackInc = 1 / (0.008 * sr)            // 8ms
        decayCoef = expf(-1 / (1.6 * sr))       // 減衰の時定数 1.6s
        releaseCoef = expf(-1 / (0.28 * sr))    // リリース 0.28s
        h2Coef = expf(-1 / (0.5 * sr))
        h3Coef = expf(-1 / (0.18 * sr))
    }

    func handle(_ e: SynthEvent) {
        switch e {
        case let .noteOn(n, v): noteOn(n, v)
        case let .noteOff(n): noteOff(n)
        case let .sustain(down):
            sustainDown = down
            if !down {
                for i in 0..<Synth.maxVoices where voices[i].active && voices[i].sustained {
                    voices[i].sustained = false
                    voices[i].stage = .release
                }
            }
        case .allNotesOff:
            sustainDown = false
            for i in 0..<Synth.maxVoices where voices[i].active {
                voices[i].gate = false
                voices[i].sustained = false
                voices[i].stage = .release
            }
        }
    }

    private func noteOn(_ n: Int, _ vel: Int) {
        counter += 1
        // 同じ音が鳴っていればそのボイスを再トリガ（位相を保つのでクリックしない）
        var idx = -1
        for i in 0..<Synth.maxVoices where voices[i].active && voices[i].note == n {
            idx = i; break
        }
        if idx < 0 {
            for i in 0..<Synth.maxVoices where !voices[i].active { idx = i; break }
        }
        if idx < 0 {
            // 空きがなければ、リリース中で最も小さい音 → 最も古い音 を奪う
            var best = 0
            var bestScore = Float.greatestFiniteMagnitude
            for i in 0..<Synth.maxVoices {
                let v = voices[i]
                let score = (v.stage == .release ? 0 : 10) + v.env - Float(counter - v.age) * 1e-6
                if score < bestScore { bestScore = score; best = i }
            }
            idx = best
        }

        let v = Float(vel) / 127
        let freq = 440 * powf(2, Float(n - 69) / 12)
        let keyScale = min(max(powf(2, -Float(n - 60) / 36), 0.55), 1.4) // 高音を少し抑える
        let pan = Float(n - 64) / 64 * 0.35

        var voice = voices[idx]
        let retrigger = voice.active
        voice.active = true
        voice.note = n
        voice.gate = true
        voice.sustained = false
        voice.stage = .attack
        voice.age = counter
        voice.gain = (0.2 + 0.8 * powf(v, 1.6)) * keyScale
        voice.panL = cosf((pan + 1) * .pi / 4)
        voice.panR = sinf((pan + 1) * .pi / 4)
        voice.i1 = freq / sr
        voice.i2 = freq * powf(2, 4.0 / 1200) / sr   // +4 cent でうっすらコーラス
        voice.i3 = freq * 2 / sr
        voice.i4 = freq * 3 / sr
        voice.h2 = 0.10 + 0.25 * v                   // 強く弾くほど少し明るく
        voice.h3 = 0.08 * v
        if !retrigger {
            voice.env = 0
            voice.p1 = 0; voice.p2 = 0.25; voice.p3 = 0; voice.p4 = 0
        }
        voices[idx] = voice
    }

    private func noteOff(_ n: Int) {
        for i in 0..<Synth.maxVoices where voices[i].active && voices[i].note == n && voices[i].gate {
            voices[i].gate = false
            if sustainDown {
                voices[i].sustained = true
            } else {
                voices[i].stage = .release
            }
        }
    }

    @inline(__always) private func osc(_ p: Float) -> Float { sinf(2 * .pi * p) }

    func render(frames: Int, _ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>) {
        eventQueue.withLockIfAvailable { q in
            for e in q { handle(e) }
            q.removeAll(keepingCapacity: true)
        }

        L.update(repeating: 0, count: frames)
        R.update(repeating: 0, count: frames)

        for i in 0..<Synth.maxVoices where voices[i].active {
            var v = voices[i]
            for f in 0..<frames {
                switch v.stage {
                case .attack:
                    v.env += attackInc
                    if v.env >= 1 { v.env = 1; v.stage = .decay }
                case .decay:
                    v.env = sustainLevel + (v.env - sustainLevel) * decayCoef
                case .release:
                    v.env *= releaseCoef
                }
                let o1 = osc(v.p1), o2 = osc(v.p2)
                let harm = v.h2 * osc(v.p3) + v.h3 * osc(v.p4)
                let amp = v.env * v.gain
                // デチューン成分を左右で配分を変えて自然な広がりを出す
                L[f] += (o1 + 0.3 * o2 + harm) * amp * v.panL
                R[f] += (0.85 * o1 + 0.55 * o2 + harm) * amp * v.panR

                v.p1 += v.i1; if v.p1 >= 1 { v.p1 -= 1 }
                v.p2 += v.i2; if v.p2 >= 1 { v.p2 -= 1 }
                v.p3 += v.i3; if v.p3 >= 1 { v.p3 -= 1 }
                v.p4 += v.i4; if v.p4 >= 1 { v.p4 -= 1 }
                v.h2 *= h2Coef
                v.h3 *= h3Coef
            }
            if v.stage == .release && v.env < 1e-4 { v.active = false }
            voices[i] = v
        }

        let anyActive = (0..<Synth.maxVoices).contains { voices[$0].active }
        if anyActive { reverb.idle = false }
        if reverb.idle { return } // 無音時はほぼ何もしない（常駐時の CPU 負荷を抑える）

        // マスター: 同時押しで音割れしないよう tanh でソフトクリップ
        for f in 0..<frames {
            L[f] = tanhf(L[f] * masterGain)
            R[f] = tanhf(R[f] * masterGain)
        }
        reverb.process(frames: frames, L, R, anyInput: anyActive)
    }
}

// 4 本の遅延線による軽量 FDN リバーブ。残響が消えたら idle になり処理を止める
final class Reverb {
    static let n = 4
    let lines = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: n)
    let lengths = UnsafeMutablePointer<Int>.allocate(capacity: n)
    let pos = UnsafeMutablePointer<Int>.allocate(capacity: n)
    let damp = UnsafeMutablePointer<Float>.allocate(capacity: n)
    let feedback: Float = 0.8
    let dampCoef: Float = 0.35 // ループ内ローパス（残響を暗く柔らかく）
    let wet: Float = 0.22
    var idle = true

    init(sampleRate: Float) {
        let base = [1557, 1617, 1491, 1422]
        for k in 0..<Reverb.n {
            let len = Int(Float(base[k]) * sampleRate / 44100)
            lengths[k] = len
            lines[k] = .allocate(capacity: len)
            lines[k].initialize(repeating: 0, count: len)
            pos[k] = 0
            damp[k] = 0
        }
    }

    func process(frames: Int, _ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, anyInput: Bool) {
        let g = feedback * 0.5
        var energy: Float = 0
        for f in 0..<frames {
            let input = (L[f] + R[f]) * 0.25
            let a = lines[0][pos[0]], b = lines[1][pos[1]], c = lines[2][pos[2]], d = lines[3][pos[3]]
            damp[0] += dampCoef * (a - damp[0])
            damp[1] += dampCoef * (b - damp[1])
            damp[2] += dampCoef * (c - damp[2])
            damp[3] += dampCoef * (d - damp[3])
            // Hadamard 行列で混ぜる
            let (w, x, y, z) = (damp[0], damp[1], damp[2], damp[3])
            lines[0][pos[0]] = input + g * (w + x + y + z)
            lines[1][pos[1]] = input + g * (w - x + y - z)
            lines[2][pos[2]] = input + g * (w + x - y - z)
            lines[3][pos[3]] = input + g * (w - x - y + z)
            for k in 0..<Reverb.n {
                pos[k] += 1
                if pos[k] == lengths[k] { pos[k] = 0 }
            }
            L[f] += wet * (a + c)
            R[f] += wet * (b + d)
            energy += abs(a) + abs(b)
        }
        if !anyInput && energy < 1e-4 {
            idle = true
            for k in 0..<Reverb.n {
                lines[k].update(repeating: 0, count: lengths[k])
                damp[k] = 0
            }
        }
    }
}

// MARK: - オーディオ

let engine = AVAudioEngine()
let outFormat = engine.outputNode.outputFormat(forBus: 0)
let sampleRate = outFormat.sampleRate > 0 ? outFormat.sampleRate : 48000
let synth = Synth(sampleRate: sampleRate)
let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

let source = AVAudioSourceNode(format: format) { _, _, frameCount, abl in
    let bufs = UnsafeMutableAudioBufferListPointer(abl)
    let L = bufs[0].mData!.assumingMemoryBound(to: Float.self)
    let R = bufs[1].mData!.assumingMemoryBound(to: Float.self)
    synth.render(frames: Int(frameCount), L, R)
    return noErr
}

engine.attach(source)
engine.connect(source, to: engine.mainMixerNode, format: format)

func startEngine() {
    do {
        try engine.start()
        log("audio started (\(Int(sampleRate)) Hz)")
    } catch {
        log("audio start failed: \(error)")
    }
}

// 出力デバイス切替（ヘッドホン抜き差し等）で止まったら再開
NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
    log("audio configuration changed, restarting")
    post(.allNotesOff)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { startEngine() }
}

// MARK: - MIDI

func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts)] \(s)")
    fflush(stdout)
}

func handleMIDI1(status: UInt32, d1: UInt32, d2: UInt32) {
    switch status & 0xF0 {
    case 0x90 where d2 > 0: post(.noteOn(note: Int(d1), velocity: Int(d2)))
    case 0x90, 0x80: post(.noteOff(note: Int(d1)))
    case 0xB0:
        switch d1 {
        case 64: post(.sustain(d2 >= 64))
        case 120, 123: post(.allNotesOff)
        default: break
        }
    default: break
    }
}

var client = MIDIClientRef()
var inPort = MIDIPortRef()
var connected: [MIDIEndpointRef] = []

func endpointName(_ e: MIDIEndpointRef) -> String {
    var name: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &name)
    return (name?.takeRetainedValue() as String?) ?? "?"
}

func connectAllSources() {
    for e in connected { MIDIPortDisconnectSource(inPort, e) }
    connected.removeAll()
    for i in 0..<MIDIGetNumberOfSources() {
        let src = MIDIGetSource(i)
        if MIDIPortConnectSource(inPort, src, nil) == noErr {
            connected.append(src)
            log("MIDI connected: \(endpointName(src))")
        }
    }
    if connected.isEmpty { log("no MIDI sources (waiting for a device)") }
}

// UMP のメッセージ種別ごとのワード数
let umpWordCount: [Int] = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4]
let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!

MIDIClientCreateWithBlock("soft-synth" as CFString, &client) { notification in
    if notification.pointee.messageID == .msgSetupChanged {
        DispatchQueue.main.async { connectAllSources() }
    }
}

MIDIInputPortCreateWithProtocol(client, "in" as CFString, ._1_0, &inPort) { eventList, _ in
    for packet in eventList.unsafeSequence() {
        let count = Int(packet.pointee.wordCount)
        let words = UnsafeRawPointer(packet).advanced(by: wordsOffset).assumingMemoryBound(to: UInt32.self)
        var i = 0
        while i < count {
            let w = words[i]
            let mt = Int(w >> 28)
            if mt == 0x2 { // MIDI 1.0 channel voice
                handleMIDI1(status: (w >> 16) & 0xFF, d1: (w >> 8) & 0x7F, d2: w & 0x7F)
            }
            i += umpWordCount[mt]
        }
    }
}

// MARK: - Bluetooth MIDI
// macOS はペアリング済みでも BLE MIDI 鍵盤を自動接続しない（通常は Audio MIDI 設定から毎回接続が必要）。
// CoreBluetooth で接続すると CoreMIDI にソースとして現れるので、見つけ次第つなぎ、切れたら再接続を待つ。

final class BLEMIDIConnector: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let midiService = CBUUID(string: "03B80E5A-EDE8-4B33-A751-6CE34EC4C700")
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else {
            log("bluetooth state: \(c.state.rawValue)")
            return
        }
        for p in c.retrieveConnectedPeripherals(withServices: [Self.midiService]) { connect(p) }
        c.scanForPeripherals(withServices: [Self.midiService])
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        if peripherals[p.identifier] == nil { connect(p) }
    }

    private func connect(_ p: CBPeripheral) {
        peripherals[p.identifier] = p
        p.delegate = self
        central.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("bluetooth connected: \(p.name ?? "?")")
        p.discoverServices([Self.midiService])
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {}

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("bluetooth disconnected: \(p.name ?? "?")")
        post(.allNotesOff)
        c.connect(p) // 保留中の接続要求は期限なし。電源が戻れば自動で再接続される
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("bluetooth connect failed: \(p.name ?? "?") \(error.map { "\($0)" } ?? "")")
        peripherals[p.identifier] = nil // 次に見つかったとき再試行
    }
}

// MARK: - 起動

let args = CommandLine.arguments
if args.contains("--list") {
    for i in 0..<MIDIGetNumberOfSources() { print(endpointName(MIDIGetSource(i))) }
    exit(0)
}

startEngine()
connectAllSources()
let bleConnector = BLEMIDIConnector()

if args.contains("--demo") {
    // 鍵盤なしでの動作確認用: C メジャー7 の和音を鳴らす
    for n in [48, 60, 64, 67, 71] { post(.noteOn(note: n, velocity: 80)) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        for n in [48, 60, 64, 67, 71] { post(.noteOff(note: n)) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(0) }
}

signal(SIGTERM) { _ in exit(0) }
dispatchMain()
