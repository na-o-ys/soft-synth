// AVAudioEngine で Synth を既定の出力デバイスに鳴らす
import AVFoundation

final class AudioOutput {
    let engine = AVAudioEngine()
    let synth: Synth
    private let sampleRate: Double

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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.start() }
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
