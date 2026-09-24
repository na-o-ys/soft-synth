// 受信した MIDI メッセージを設定ファイルの controls に従ってパラメータ操作・アクションに変換する
import Foundation

final class Controller {
    private let lock = NSLock()
    private var config = Config.builtin
    private var params = SynthParams()
    private var presetIndex = 0

    func load(_ c: Config) {
        lock.lock()
        defer { lock.unlock() }
        let current = config.presets.indices.contains(presetIndex) ? config.presets[presetIndex].name : nil
        config = c
        params = SynthParams()
        for (p, v) in c.params { params[keyPath: p.keyPath] = v }
        // 読み直し時は同名のプリセットがあればそれを維持する
        let name = current.flatMap { n in c.presets.contains { $0.name == n } ? n : nil } ?? c.initialPreset
        selectPreset(c.presets.firstIndex { $0.name == name } ?? 0)
    }

    /// MIDI 1.0 のチャンネルメッセージを 1 つ処理する（MIDI 受信スレッドから呼ばれる）
    func handle(status: UInt8, d1: UInt8, d2: UInt8) {
        lock.lock()
        defer { lock.unlock() }
        let kind = status & 0xF0
        let channel = Int(status & 0x0F)
        if config.logMIDI { log("midi: \(describeMIDI(status: status, d1: d1, d2: d2))") }

        let source: Control.Source
        let value: Float     // 0...1 に正規化した値
        let pressed: Bool    // ボタンとして押されたか
        switch kind {
        case 0x90, 0x80:
            source = .note(Int(d1))
            pressed = kind == 0x90 && d2 > 0
            value = pressed ? 1 : 0
        case 0xB0:
            source = .cc(Int(d1))
            value = Float(d2) / 127
            pressed = d2 > 0
        case 0xE0:
            source = .pitchBend
            value = Float(Int(d2) << 7 | Int(d1)) / 16383
            pressed = false
        default:
            return
        }

        var matched = false
        for c in config.controls where c.source == source && (c.channel == nil || c.channel == channel) {
            matched = true
            apply(c.target, value: value, pressed: pressed)
        }
        if matched { return }

        // 割り当てのないメッセージは標準の MIDI として扱う
        switch (kind, d1) {
        case (0x90, _) where d2 > 0: post(.noteOn(key: Int(d1), velocity: Int(d2)))
        case (0x90, _), (0x80, _): post(.noteOff(key: Int(d1)))
        case (0xB0, 64): post(.sustain(d2 >= 64))
        case (0xB0, 120), (0xB0, 123): post(.allNotesOff)
        default: break
        }
    }

    private func apply(_ target: Control.Target, value: Float, pressed: Bool) {
        switch target {
        case let .param(p, lo, hi, exponential, step):
            var v = exponential ? lo * powf(hi / lo, value) : lo + (hi - lo) * value
            if step > 0 { v = (v / step).rounded() * step }
            setParam(p, v, announce: step > 0) // 段階的な値（transpose 等）は変化をログに出す
        case let .preset(name):
            if pressed, let i = config.presets.firstIndex(where: { $0.name == name }) { selectPreset(i) }
        case .nextPreset:
            if pressed { selectPreset((presetIndex + 1) % config.presets.count) }
        case .prevPreset:
            if pressed { selectPreset((presetIndex + config.presets.count - 1) % config.presets.count) }
        case let .set(p, v):
            if pressed { setParam(p, v, announce: true) }
        case let .add(p, delta, lo, hi):
            if pressed { setParam(p, min(max(params[keyPath: p.keyPath] + delta, lo), hi), announce: true) }
        case let .toggle(p, off, on):
            if pressed { setParam(p, params[keyPath: p.keyPath] == on ? off : on, announce: true) }
        case .panic:
            if pressed {
                post(.allNotesOff)
                log("panic")
            }
        }
    }

    private func setParam(_ p: Param, _ v: Float, announce: Bool) {
        let v = v + 0 // -0 を 0 にする
        guard params[keyPath: p.keyPath] != v else { return }
        params[keyPath: p.keyPath] = v
        post(.params(params))
        if announce { log("\(p.rawValue) = \(v)") }
    }

    private func selectPreset(_ i: Int) {
        presetIndex = i
        let preset = config.presets[i]
        // 音色パラメータは 既定値 ← params ← プリセット の順で決める。演奏中の状態は引き継ぐ
        var next = SynthParams()
        for (p, v) in config.params { next[keyPath: p.keyPath] = v }
        for (p, v) in preset.values { next[keyPath: p.keyPath] = v }
        for p in Param.allCases where p.isPerformance { next[keyPath: p.keyPath] = params[keyPath: p.keyPath] }
        next.partials = preset.partials ?? Partials.default
        params = next
        post(.params(params))
        log("preset: \(preset.name)")
    }
}

func describeMIDI(status: UInt8, d1: UInt8, d2: UInt8) -> String {
    let ch = "ch\(Int(status & 0x0F) + 1)"
    switch status & 0xF0 {
    case 0x90 where d2 > 0: return "\(ch) note \(d1) on (velocity \(d2))"
    case 0x90, 0x80: return "\(ch) note \(d1) off"
    case 0xB0: return "\(ch) cc \(d1) = \(d2)"
    case 0xE0: return "\(ch) pitchBend = \(Int(d2) << 7 | Int(d1))"
    case 0xC0: return "\(ch) program \(d1)"
    case 0xD0: return "\(ch) aftertouch \(d1)"
    default: return String(format: "%02X %02X %02X", status, d1, d2)
    }
}
