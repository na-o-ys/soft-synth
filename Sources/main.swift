// soft-synth: MIDI 鍵盤を常駐・軽量なやわらかいシンセ音で鳴らすだけのデーモン
import AppKit

func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts)] \(s)")
    fflush(stdout)
}

let args = CommandLine.arguments

func argValue(_ name: String) -> String? {
    args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
}

if args.contains("--help") || args.contains("-h") {
    print("""
    usage: soft-synth [--config PATH] [--demo] [--no-bluetooth]
           soft-synth --list       接続中の MIDI ソースを表示
           soft-synth --monitor    受信した MIDI メッセージを表示（設定ファイル作成用）
    設定ファイルの既定: ~/.config/soft-synth/config.json
    """)
    exit(0)
}

if args.contains("--list") {
    midiSourceNames().forEach { print($0) }
    exit(0)
}

if args.contains("--monitor") {
    let input = MIDIInput { status, d1, d2 in print(describeMIDI(status: status, d1: d1, d2: d2)); fflush(stdout) }
    withExtendedLifetime(input) { CFRunLoopRun() }
}

let configURL = argValue("--config").map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/soft-synth/config.json")

let controller = Controller()
let audio = AudioOutput()
let watcher = ConfigWatcher(url: configURL) { controller.load($0) }
watcher.start()
let midiInput = MIDIInput { if audio.isEnabled { controller.handle(status: $0, d1: $1, d2: $2) } }
// Bluetooth 権限のない環境（ターミナル等）でも動くよう --demo / --no-bluetooth では BLE を使わない
let bleConnector = args.contains("--demo") || args.contains("--no-bluetooth") ? nil : BLEMIDIConnector()

if args.contains("--demo") {
    // 鍵盤なしでの動作確認用: C メジャー7 の和音を鳴らす
    let chord = [48, 60, 64, 67, 71]
    for n in chord { post(.noteOn(key: n, velocity: 80)) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        for n in chord { post(.noteOff(key: n)) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(0) }
}

signal(SIGTERM) { _ in exit(0) }

// メニューバー常駐（Dock には出さない）。NSApplication がメインスレッドの RunLoop を回すので
// CoreMIDI の接続変更通知もここで届く
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let statusBar = StatusBar { audio.setEnabled($0) }
audio.setEnabled(args.contains("--demo") || statusBar.isOn)
withExtendedLifetime((midiInput, bleConnector, watcher, statusBar)) { app.run() }
