import AVFAudio
import Combine
import Foundation

@MainActor
final class AudioPlayback: ObservableObject {
    private var engine: AVAudioEngine?
    private var observers: [NSObjectProtocol] = []
    private var sampleRate = 0.0
    private var lifecycle = AudioLifecycle()
    private var failed = false
    private var gain: Float = 1
    private var mixWithOtherAudio = true

    func setMixWithOtherAudio(_ enabled: Bool) {
        guard mixWithOtherAudio != enabled else { return }
        mixWithOtherAudio = enabled
        if engine != nil {
            stop()
            if lifecycle.shouldPlay { start() }
        }
    }

    func setStallReserve(_ enabled: Bool, sampleRate: Double) {
        // Alternate rendering ticks and GPU shader stalls need a small audio
        // reserve. Keep it bounded to ~60 ms, never seconds of latency.
        let reserve = enabled && sampleRate.isFinite && sampleRate > 0 ? min(3072, max(1024, Int(sampleRate * 0.06))) : 1024
        dstv_audio_set_reserve_frames(UInt32(reserve))
    }

    func setVolume(percent: Int, muted: Bool) {
        let next = muted ? 0 : Float(min(100, max(0, percent))) / 100
        guard next != gain else { return }
        gain = next
        engine?.mainMixerNode.outputVolume = gain
    }

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                             object: nil, queue: .main) { [weak self] note in
            guard let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
            // queue: .main guarantees isolation; don't defer lifecycle changes
            // to a Task that might run after a newer scene transition.
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.lifecycle.interruptionBegan()
                } else {
                    self.lifecycle.interruptionEnded()
                }
                self.stop()
                if self.lifecycle.shouldPlay { self.start() }
            }
        })
        for name in [Notification.Name.AVAudioEngineConfigurationChange,
                     AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, self.lifecycle.shouldPlay else { return }
                    // Ignore a retired engine's notification after rebuilding.
                    if name == .AVAudioEngineConfigurationChange {
                        guard let changed = note.object as? AVAudioEngine,
                              changed === self.engine else { return }
                    }
                    self.stop()
                    self.start()
                }
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func setActive(_ value: Bool, sampleRate: Double) {
        #if DEBUG
        print("Audio lifecycle: active=\(value)")
        #endif
        self.sampleRate = sampleRate
        let wasActive = lifecycle.active
        lifecycle.setActive(value)
        if !value {
            stop()
            guard !mixWithOtherAudio else { return }
            // Avoid tvOS deactivating a suspended session itself and delivering
            // a delayed interruption-began notification on the next foreground.
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                print("Audio session deactivation failed: \(error)")
            }
        } else if lifecycle.shouldPlay {
            if !wasActive || engine?.isRunning != true { stop() }
            start()
        }
    }

    // Main thread; never called from libretro/audio callbacks.
    private func start() {
        guard engine == nil, sampleRate.isFinite, sampleRate > 0 else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // Ambient audio is mixable by default and doesn't take over the
            // Now Playing session from music playing alongside the game.
            try session.setCategory(
                mixWithOtherAudio ? .ambient : .playback,
                mode: .default,
                policy: .default,
                options: []
            )
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
                throw NSError(domain: "DualScreenTV.Audio", code: 1)
            }
            dstv_audio_reset()
            let engine = AVAudioEngine()
            let source = AVAudioSourceNode(format: format) { _, _, frames, buffers in
                // No captured Swift objects, allocations, locks, or logging.
                dstv_audio_render(frames, buffers)
            }
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = gain
            engine.prepare()
            try engine.start()
            self.engine = engine
            failed = false
            print("Audio started: stereo \(sampleRate) Hz")
            logTiming()
        } catch {
            failed = true
            print("Audio unavailable: \(error)")
        }
    }

    private func stop() {
        if engine != nil {
            #if DEBUG
            print("Audio underruns: \(dstv_audio_underruns()), dropped frames: \(dstv_audio_dropped_frames())")
            #endif
        }
        engine?.stop()
        engine = nil
        dstv_audio_reset()
    }

    func logTiming() {
        #if DEBUG
        guard let engine else { return }
        let session = AVAudioSession.sharedInstance()
        let queueMS = sampleRate > 0 ? Double(dstv_audio_buffered_frames()) / sampleRate * 1000 : 0
        let ports = session.currentRoute.outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
        print(String(format: "Audio timing: queue=%.1f ms, output=%.1f ms, presentation=%.1f ms, IO=%.1f ms, policy=%lu, route=%@",
                     queueMS, session.outputLatency * 1000,
                     engine.outputNode.presentationLatency * 1000, session.ioBufferDuration * 1000,
                     session.routeSharingPolicy.rawValue, ports))
        #endif
    }

    // Render failures should remain visible without flooding the log per frame.
    var hasFailed: Bool { failed }
}
