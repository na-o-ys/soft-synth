import CoreBluetooth
import Foundation

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

