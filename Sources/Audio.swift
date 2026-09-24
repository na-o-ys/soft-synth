// AVAudioEngine で Synth を既定の出力デバイスに鳴らす
import AVFoundation
import os

final class AudioOutput {
    let engine = AVAudioEngine()
    let synth: Synth
    private let sampleRate: Double
    /// false のあいだはエンジンを止めて出力デバイスを解放し、MIDI 入力も捨てる
    private let enabledFlag = OSAllocatedUnfairLock(initialState: true)
    var isEnabled: Bool { enabledFlag.withLock { $0 } }

    init() {
        let outFormat = engine.outputNode.outputFormat(forBus: 0)
        sampleRate = outFormat.sampleRate > 0 ? outFormat.sampleRate : 48000
        let synth = Synth(sampleRate: sampleRate)
        self.synth = synth
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

        // 出力デバイス切替（ヘッドホン抜き差し等）で止まったら再開
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            log("audio configuration changed, restarting")
            post(.allNotesOff)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if self?.isEnabled == true { self?.start() }
            }
        }
    }

    func setEnabled(_ on: Bool) {
        enabledFlag.withLock { $0 = on }
        if on {
            // オフ中に溜まった演奏イベントは捨て、鳴りかけの音も止める（音色設定の更新は残す）
            eventQueue.withLock { q in
                q.removeAll { if case .params = $0 { false } else { true } }
                q.append(.allNotesOff)
            }
            start()
        } else {
            post(.allNotesOff)
            engine.stop()
            log("audio stopped")
        }
    }

    func start() {
        do {
            try engine.start()
            log("audio started (\(Int(sampleRate)) Hz)")
        } catch {
            log("audio start failed: \(error)")
        }
    }
}
