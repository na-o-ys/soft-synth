// メニューバーのアイコン。クリックで音の on/off を切り替える（状態は再起動後も保持）
import AppKit

final class StatusBar: NSObject {
    private static let defaultsKey = "enabled"
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let onChange: (Bool) -> Void
    private(set) var isOn: Bool

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        isOn = UserDefaults.standard.object(forKey: StatusBar.defaultsKey) as? Bool ?? true
        super.init()
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "pianokeys", accessibilityDescription: "soft-synth")
            button.target = self
            button.action = #selector(toggle)
        }
        update()
    }

    @objc private func toggle() {
        isOn.toggle()
        UserDefaults.standard.set(isOn, forKey: StatusBar.defaultsKey)
        onChange(isOn)
        update()
    }

    private func update() {
        item.button?.appearsDisabled = !isOn
        item.button?.toolTip = isOn ? "soft-synth: On（クリックでオフ）" : "soft-synth: Off（クリックでオン）"
    }
}
