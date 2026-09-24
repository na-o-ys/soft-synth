// CoreMIDI の全ソースから MIDI 1.0 チャンネルメッセージを受け取る。デバイスの抜き差しに追従する
import CoreMIDI
import Foundation

final class MIDIInput {
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected: [MIDIEndpointRef] = []

    // UMP のメッセージ種別ごとのワード数
    private static let umpWordCount: [Int] = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4]
    private static let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!

    init(handler: @escaping (_ status: UInt8, _ d1: UInt8, _ d2: UInt8) -> Void) {
        MIDIClientCreateWithBlock("soft-synth" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.connectAllSources() }
            }
        }
        MIDIInputPortCreateWithProtocol(client, "in" as CFString, ._1_0, &port) { eventList, _ in
            for packet in eventList.unsafeSequence() {
                let count = Int(packet.pointee.wordCount)
                let words = UnsafeRawPointer(packet).advanced(by: MIDIInput.wordsOffset)
                    .assumingMemoryBound(to: UInt32.self)
                var i = 0
                while i < count {
                    let w = words[i]
                    let mt = Int(w >> 28)
                    if mt == 0x2 { // MIDI 1.0 channel voice
                        handler(UInt8((w >> 16) & 0xFF), UInt8((w >> 8) & 0x7F), UInt8(w & 0x7F))
                    }
                    i += MIDIInput.umpWordCount[mt]
                }
            }
        }
        connectAllSources()
    }

    func connectAllSources() {
        for e in connected { MIDIPortDisconnectSource(port, e) }
        connected.removeAll()
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            if MIDIPortConnectSource(port, src, nil) == noErr {
                connected.append(src)
                log("MIDI connected: \(endpointName(src))")
            }
        }
        if connected.isEmpty { log("no MIDI sources (waiting for a device)") }
    }
}

func endpointName(_ e: MIDIEndpointRef) -> String {
    var name: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &name)
    return (name?.takeRetainedValue() as String?) ?? "?"
}

func midiSourceNames() -> [String] {
    (0..<MIDIGetNumberOfSources()).map { endpointName(MIDIGetSource($0)) }
}
