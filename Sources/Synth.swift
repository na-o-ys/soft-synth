// シンセ本体（サイン波の加算合成 + 軽量リバーブ）。render はオーディオスレッドで呼ばれる
import Foundation
import os

// MARK: - 他スレッド → オーディオスレッドのイベント受け渡し

enum SynthEvent {
    case noteOn(key: Int, velocity: Int)
    case noteOff(key: Int)
    case sustain(Bool)
    case allNotesOff
    case params(SynthParams)
}

let eventQueue = OSAllocatedUnfairLock(initialState: [SynthEvent]())

func post(_ e: SynthEvent) {
    eventQueue.withLock { $0.append(e) }
}

// MARK: - ボイス

struct Voice {
    enum Stage { case attack, decay, release }
    var active = false
    var key = -1           // 押された鍵盤（transpose 前）。noteOff の照合に使う
    var gate = false       // 鍵盤を押している
    var sustained = false  // 離したがペダルで保持中
    var stage = Stage.attack
    var env: Float = 0
    var gain: Float = 0
    var panL: Float = 0, panR: Float = 0
    var freq: Float = 0
    var phase = SIMD8<Float>(repeating: 0)
    var amp = SIMD8<Float>(repeating: 0)  // 各 partial の現在の音量（時間で減衰）
    var chorusPhase: Float = 0.25
    var age: UInt64 = 0
}

final class Synth {
    static let maxVoices = 32
    let sr: Float
    let voices = UnsafeMutablePointer<Voice>.allocate(capacity: maxVoices)
    let reverb: Reverb
    var params = SynthParams()
    var sustainDown = false
    var counter: UInt64 = 0
    var lfoPhase: Float = 0

    // params から計算する係数
    var attackInc: Float = 0
    var decayCoef: Float = 0
    var releaseCoef: Float = 0
    var partialDecayCoef = SIMD8<Float>(repeating: 1)

    init(sampleRate: Double) {
        sr = Float(sampleRate)
        voices.initialize(repeating: Voice(), count: Synth.maxVoices)
        reverb = Reverb(sampleRate: sr)
        apply(params)
    }

    private func apply(_ p: SynthParams) {
        params = p
        attackInc = 1 / (max(p.attack, 0.001) * sr)
        decayCoef = expf(-1 / (max(p.decay, 0.01) * sr))
        releaseCoef = expf(-1 / (max(p.release, 0.01) * sr))
        for k in 0..<Partials.capacity {
            let d = p.partials.decay[k]
            partialDecayCoef[k] = d > 0 ? expf(-1 / (d * sr)) : 1
        }
        reverb.feedback = min(max(p.reverbSize, 0), 0.97)
        reverb.dampCoef = 1 - min(max(p.reverbDamp, 0), 0.99)
        reverb.wet = max(p.reverb, 0)
    }

    func handle(_ e: SynthEvent) {
        switch e {
        case let .noteOn(k, v): noteOn(k, v)
        case let .noteOff(k): noteOff(k)
        case let .params(p): apply(p)
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

    private func noteOn(_ key: Int, _ vel: Int) {
        counter += 1
        // 同じ鍵盤が鳴っていればそのボイスを再トリガ（位相を保つのでクリックしない）
        var idx = -1
        for i in 0..<Synth.maxVoices where voices[i].active && voices[i].key == key {
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

        let note = key + Int(params.transpose.rounded())
        let v = Float(vel) / 127
        let keyScale = min(max(powf(2, -Float(note - 60) / 36), 0.55), 1.4) // 高音を少し抑える
        let pan = Float(min(max(note - 64, -64), 64)) / 64 * 0.35
        let sens = min(max(params.velocity, 0), 1)

        var voice = voices[idx]
        let retrigger = voice.active
        voice.active = true
        voice.key = key
        voice.gate = true
        voice.sustained = false
        voice.stage = .attack
        voice.age = counter
        voice.freq = 440 * powf(2, Float(note - 69) / 12)
        voice.gain = ((1 - sens) + sens * powf(v, 1.6)) * keyScale
        voice.panL = cosf((pan + 1) * .pi / 4)
        voice.panR = sinf((pan + 1) * .pi / 4)
        voice.amp = params.partials.level + params.partials.velocityLevel * v
        if !retrigger {
            voice.env = 0
            voice.phase = SIMD8(repeating: 0)
            voice.chorusPhase = 0.25
        }
        voices[idx] = voice
    }

    private func noteOff(_ key: Int) {
        for i in 0..<Synth.maxVoices where voices[i].active && voices[i].key == key && voices[i].gate {
            voices[i].gate = false
            if sustainDown {
                voices[i].sustained = true
            } else {
                voices[i].stage = .release
            }
        }
    }

    func render(frames: Int, _ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>) {
        eventQueue.withLockIfAvailable { q in
            for e in q { handle(e) }
            q.removeAll(keepingCapacity: true)
        }

        L.update(repeating: 0, count: frames)
        R.update(repeating: 0, count: frames)

        let p = params
        let count = p.partials.count
        let bendMult = powf(2, p.bend / 12)
        let chorusRatio = powf(2, p.detune / 1200)
        // ratio == 1 の partial は基音、それ以外は brightness で量を変える
        var bright = SIMD8<Float>(repeating: p.brightness)
        bright.replace(with: 1, where: p.partials.ratio .== 1)
        let lfoInc = p.vibratoRate / sr
        let twoPi = 2 * Float.pi

        var anyActive = false
        for i in 0..<Synth.maxVoices where voices[i].active {
            var v = voices[i]
            let baseInc = p.partials.ratio * (v.freq * bendMult / sr)
            let chorusInc = v.freq * bendMult * chorusRatio / sr
            var lfo = lfoPhase
            for f in 0..<frames {
                switch v.stage {
                case .attack:
                    v.env += attackInc
                    if v.env >= 1 { v.env = 1; v.stage = .decay }
                case .decay:
                    v.env = p.sustain + (v.env - p.sustain) * decayCoef
                case .release:
                    v.env *= releaseCoef
                }
                var vib: Float = 1
                if p.vibrato > 0 {
                    vib = exp2f(p.vibrato * sinf(twoPi * lfo) / 12)
                    lfo += lfoInc; if lfo >= 1 { lfo -= 1 }
                }

                let a = v.amp * bright
                var main: Float = 0
                for k in 0..<count { main += a[k] * sinf(twoPi * v.phase[k]) }
                let ch = p.chorus * sinf(twoPi * v.chorusPhase)
                let amp = v.env * v.gain
                // デチューン成分を左右で配分を変えて自然な広がりを出す
                L[f] += (main + 0.35 * ch) * amp * v.panL
                R[f] += (0.85 * main + 0.65 * ch) * amp * v.panR

                v.phase += baseInc * vib
                v.phase -= v.phase.rounded(.down)
                v.chorusPhase += chorusInc * vib
                if v.chorusPhase >= 1 { v.chorusPhase -= 1 }
                v.amp *= partialDecayCoef
            }
            if v.env < 1e-4 && (v.stage == .release || (v.stage == .decay && p.sustain < 1e-4)) {
                v.active = false
            }
            voices[i] = v
            anyActive = anyActive || v.active
        }
        if p.vibrato > 0 {
            lfoPhase += lfoInc * Float(frames)
            lfoPhase -= lfoPhase.rounded(.down)
        }

        if anyActive { reverb.idle = false }
        if reverb.idle { return } // 無音時はほぼ何もしない（常駐時の CPU 負荷を抑える）

        // マスター: 同時押しで音割れしないよう tanh でソフトクリップ
        let vol = max(p.volume, 0)
        for f in 0..<frames {
            L[f] = tanhf(L[f] * 0.25) * vol
            R[f] = tanhf(R[f] * 0.25) * vol
        }
        reverb.process(frames: frames, L, R, anyInput: anyActive)
    }
}

// MARK: - リバーブ
// 4 本の遅延線による軽量 FDN リバーブ。残響が消えたら idle になり処理を止める

final class Reverb {
    static let n = 4
    let lines = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: n)
    let lengths = UnsafeMutablePointer<Int>.allocate(capacity: n)
    let pos = UnsafeMutablePointer<Int>.allocate(capacity: n)
    let damp = UnsafeMutablePointer<Float>.allocate(capacity: n)
    var feedback: Float = 0.8
    var dampCoef: Float = 0.65 // ループ内ローパス（小さいほど残響が暗く柔らかい）
    var wet: Float = 0.22
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
