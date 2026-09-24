// 設定ファイル（JSON）の読み込みと変更監視。形式は README.md を参照
import Foundation

struct Preset {
    var name: String
    var values: [Param: Float] = [:]
    var partials: Partials?
}

struct Control {
    enum Source: Equatable {
        case cc(Int)
        case note(Int)
        case pitchBend
    }

    enum Target {
        case param(Param, min: Float, max: Float, exponential: Bool, step: Float)
        case preset(String)
        case nextPreset
        case prevPreset
        case set(Param, Float)
        case add(Param, Float, min: Float, max: Float)
        case toggle(Param, Float, Float)
        case panic
    }

    var source: Source
    var channel: Int? // 0 始まり。nil なら全チャンネル
    var target: Target
}

struct Config {
    var params: [Param: Float] = [:]
    var presets: [Preset] = [Preset(name: "default")]
    var initialPreset: String?
    var controls: [Control] = []
    var logMIDI = false

    /// 設定ファイルがないときの既定値（一般的な MIDI 鍵盤向け）
    static let builtin = Config(controls: [
        Control(source: .pitchBend, target: .param(.bend, min: -2, max: 2, exponential: false, step: 0)),
        Control(source: .cc(1), target: .param(.vibrato, min: 0, max: 0.5, exponential: false, step: 0)),
        Control(source: .cc(7), target: .param(.volume, min: 0, max: 1, exponential: false, step: 0)),
    ])
}

struct ConfigError: Error, CustomStringConvertible {
    var description: String
}

extension Config {
    static func load(from url: URL) throws -> Config {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError(description: "top level must be an object")
        }
        var c = Config()
        c.logMIDI = root["logMIDI"] as? Bool ?? false
        c.initialPreset = root["preset"] as? String
        if let p = root["params"] {
            c.params = try parseValues(p, at: "params")
        }
        if let list = root["presets"] {
            guard let list = list as? [[String: Any]], !list.isEmpty else {
                throw ConfigError(description: "presets: must be a non-empty array of objects")
            }
            c.presets = try list.enumerated().map { try parsePreset($1, at: "presets[\($0)]") }
        }
        if let list = root["controls"] {
            guard let list = list as? [[String: Any]] else {
                throw ConfigError(description: "controls: must be an array of objects")
            }
            c.controls = try list.enumerated().map { try parseControl($1, at: "controls[\($0)]") }
        } else {
            c.controls = Config.builtin.controls
        }
        let names = Set(c.presets.map(\.name))
        if let p = c.initialPreset, !names.contains(p) {
            throw ConfigError(description: "preset: unknown preset \"\(p)\"")
        }
        for (i, ctl) in c.controls.enumerated() {
            if case let .preset(name) = ctl.target, !names.contains(name) {
                throw ConfigError(description: "controls[\(i)]: unknown preset \"\(name)\"")
            }
        }
        return c
    }

    private static func number(_ v: Any?, at path: String) throws -> Float {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else {
            throw ConfigError(description: "\(path): must be a number")
        }
        return n.floatValue
    }

    private static func param(_ v: Any?, at path: String) throws -> Param {
        guard let s = v as? String, let p = Param(rawValue: s) else {
            let names = Param.allCases.map(\.rawValue).joined(separator: ", ")
            throw ConfigError(description: "\(path): must be one of \(names)")
        }
        return p
    }

    private static func parseValues(_ v: Any, at path: String) throws -> [Param: Float] {
        guard let dict = v as? [String: Any] else { throw ConfigError(description: "\(path): must be an object") }
        var out: [Param: Float] = [:]
        for (k, val) in dict {
            out[try param(k, at: "\(path) key")] = try number(val, at: "\(path).\(k)")
        }
        return out
    }

    private static func parsePreset(_ dict: [String: Any], at path: String) throws -> Preset {
        guard let name = dict["name"] as? String else { throw ConfigError(description: "\(path).name: required") }
        var preset = Preset(name: name)
        var rest = dict
        rest["name"] = nil
        if let list = rest.removeValue(forKey: "partials") {
            guard let list = list as? [[String: Any]], (1...Partials.capacity).contains(list.count) else {
                throw ConfigError(description: "\(path).partials: must be 1...\(Partials.capacity) objects")
            }
            var partials = Partials()
            for (i, p) in list.enumerated() {
                let at = "\(path).partials[\(i)]"
                partials.append(
                    ratio: try number(p["ratio"], at: "\(at).ratio"),
                    level: try number(p["level"] ?? 0, at: "\(at).level"),
                    velocity: try number(p["velocity"] ?? 0, at: "\(at).velocity"),
                    decay: try number(p["decay"] ?? 0, at: "\(at).decay"))
            }
            preset.partials = partials
        }
        preset.values = try parseValues(rest, at: path)
        return preset
    }

    private static func parseControl(_ d: [String: Any], at path: String) throws -> Control {
        let source: Control.Source
        if let n = d["cc"] {
            source = .cc(Int(try number(n, at: "\(path).cc")))
        } else if let n = d["note"] {
            source = .note(Int(try number(n, at: "\(path).note")))
        } else if d["pitchBend"] as? Bool == true {
            source = .pitchBend
        } else {
            throw ConfigError(description: "\(path): needs one of \"cc\", \"note\", \"pitchBend\": true")
        }
        var channel: Int?
        if let ch = d["channel"] {
            let n = Int(try number(ch, at: "\(path).channel"))
            guard (1...16).contains(n) else { throw ConfigError(description: "\(path).channel: must be 1...16") }
            channel = n - 1
        }

        let target: Control.Target
        switch d["action"] as? String {
        case nil:
            let p = try param(d["param"], at: "\(path).param")
            let lo = try number(d["min"] ?? 0, at: "\(path).min")
            let hi = try number(d["max"] ?? 1, at: "\(path).max")
            let exp = (d["curve"] as? String) == "exp"
            if exp && (lo <= 0 || hi <= 0) {
                throw ConfigError(description: "\(path): curve \"exp\" needs min and max > 0")
            }
            target = .param(p, min: lo, max: hi, exponential: exp, step: try number(d["step"] ?? 0, at: "\(path).step"))
        case "preset":
            guard let name = d["preset"] as? String else { throw ConfigError(description: "\(path).preset: required") }
            target = .preset(name)
        case "nextPreset": target = .nextPreset
        case "prevPreset": target = .prevPreset
        case "set":
            target = .set(try param(d["param"], at: "\(path).param"), try number(d["value"], at: "\(path).value"))
        case "add":
            target = .add(try param(d["param"], at: "\(path).param"), try number(d["value"], at: "\(path).value"),
                          min: try number(d["min"] ?? -Float.greatestFiniteMagnitude, at: "\(path).min"),
                          max: try number(d["max"] ?? Float.greatestFiniteMagnitude, at: "\(path).max"))
        case "toggle":
            guard let vs = d["values"] as? [Any], vs.count == 2 else {
                throw ConfigError(description: "\(path).values: must be [off, on]")
            }
            target = .toggle(try param(d["param"], at: "\(path).param"),
                             try number(vs[0], at: "\(path).values[0]"), try number(vs[1], at: "\(path).values[1]"))
        case "panic": target = .panic
        case let a?:
            throw ConfigError(description: "\(path).action: unknown action \"\(a)\"")
        }
        return Control(source: source, channel: channel, target: target)
    }
}

/// 設定ファイルの更新日時を 1 秒ごとに見て、変わったら読み直す
final class ConfigWatcher {
    private let url: URL
    private let onChange: (Config) -> Void
    private var lastModified: Date?
    private var timer: DispatchSourceTimer?

    init(url: URL, onChange: @escaping (Config) -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        check(initial: true)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.check(initial: false) }
        t.resume()
        timer = t
    }

    private func check(initial: Bool) {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard initial || modified != lastModified else { return }
        lastModified = modified
        guard modified != nil else {
            log("config not found: \(url.path) (using built-in defaults)")
            onChange(.builtin)
            return
        }
        do {
            let c = try Config.load(from: url)
            log("config loaded: \(url.path)")
            onChange(c)
        } catch {
            // 書きかけの不正な JSON では直前の設定を使い続ける
            log("config error: \(error)")
            if initial { onChange(.builtin) }
        }
    }
}
