// 音色・効果のパラメータ。設定ファイルのキー名と 1:1 で対応する

struct SynthParams {
    var volume: Float = 0.8
    var attack: Float = 0.008     // 秒
    var decay: Float = 1.6        // 秒（sustain レベルへ向かう時定数）
    var sustain: Float = 0.3      // 0...1
    var release: Float = 0.28     // 秒
    var brightness: Float = 1     // 倍音（ratio != 1 の partial）の量の倍率
    var chorus: Float = 0.5       // デチューンした基音の量
    var detune: Float = 4         // cent
    var reverb: Float = 0.22      // wet 量
    var reverbSize: Float = 0.8   // フィードバック 0...0.97
    var reverbDamp: Float = 0.65  // 残響の暗さ 0...1
    var vibrato: Float = 0        // 深さ（半音）
    var vibratoRate: Float = 5    // Hz
    var transpose: Float = 0      // 半音
    var bend: Float = 0           // 半音（ピッチベンド）
    var velocity: Float = 0.8     // ベロシティ感度 0...1
    var partials = Partials.default
}

/// 加算合成の倍音構成。オーディオスレッドで確保が起きないよう固定長 SIMD で持つ
struct Partials {
    static let capacity = 8
    var count = 0
    var ratio = SIMD8<Float>(repeating: 0)         // 基音に対する周波数比
    var level = SIMD8<Float>(repeating: 0)         // 音量
    var velocityLevel = SIMD8<Float>(repeating: 0) // 強く弾いたときに足される音量
    var decay = SIMD8<Float>(repeating: 0)         // 秒。0 なら減衰しない

    mutating func append(ratio r: Float, level l: Float, velocity v: Float = 0, decay d: Float = 0) {
        guard count < Partials.capacity else { return }
        ratio[count] = r
        level[count] = l
        velocityLevel[count] = v
        decay[count] = d
        count += 1
    }

    static let `default`: Partials = {
        var p = Partials()
        p.append(ratio: 1, level: 1)
        p.append(ratio: 2, level: 0.10, velocity: 0.25, decay: 0.5)
        p.append(ratio: 3, level: 0, velocity: 0.08, decay: 0.18)
        return p
    }()
}

enum Param: String, CaseIterable {
    case volume, attack, decay, sustain, release, brightness, chorus, detune
    case reverb, reverbSize, reverbDamp, vibrato, vibratoRate, transpose, bend, velocity

    var keyPath: WritableKeyPath<SynthParams, Float> {
        switch self {
        case .volume: \.volume
        case .attack: \.attack
        case .decay: \.decay
        case .sustain: \.sustain
        case .release: \.release
        case .brightness: \.brightness
        case .chorus: \.chorus
        case .detune: \.detune
        case .reverb: \.reverb
        case .reverbSize: \.reverbSize
        case .reverbDamp: \.reverbDamp
        case .vibrato: \.vibrato
        case .vibratoRate: \.vibratoRate
        case .transpose: \.transpose
        case .bend: \.bend
        case .velocity: \.velocity
        }
    }

    /// 演奏中の状態。プリセットを切り替えても保持する
    var isPerformance: Bool { self == .volume || self == .transpose || self == .bend }
}
