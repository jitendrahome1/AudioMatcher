
import Foundation
import ShazamKit
import AVFAudio

// MARK: - Circular Buffer
struct CircularBuffer<T> {
    private var buffer: [T?]
    private var head = 0
    private var count = 0
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = Array<T?>(repeating: nil, count: capacity)
    }

    mutating func append(_ element: T) {
        buffer[head] = element
        head = (head + 1) % capacity
        if count < capacity { count += 1 }
    }

    var isEmpty: Bool { count == 0 }
    var isFull: Bool { count == capacity }
}

// MARK: - AudioMatcher
@MainActor
final class AudioMatcher: NSObject, ObservableObject, SHSessionDelegate {

    // MARK: - Queues
    private let audioQueue = DispatchQueue(label: "audio.processing", qos: .userInteractive)
    private let calculationQueue = DispatchQueue(label: "sync.calculations", qos: .userInitiated)

    // MARK: - Audio / Shazam
    private var session: SHSession?
    private let audioEngine = AVAudioEngine()
    private var catalogManager = ShazamCatalogManager()

    // MARK: - Listening state
    @Published var isListening = false
    @Published var isCurrentlyListening = false
    @Published var isCycleEnabled = false
    @Published var matchCount = 0
    @Published var pauseCountdown = 0
    @Published var isPerformanceGood = true

    private var hasFoundMatchThisSession = false

    // MARK: - Timing diagnostics
    @Published var measuredProcessingDelayMs: Double = 0.0
    @Published var inputBufferDelayMs: Double = 0.0
    @Published var playerSeekDelayMs: Double = 0.0
    @Published var audioOutputLatencyMs: Double = 0.0
    @Published var audioInputLatencyMs: Double = 0.0

    // MARK: - Logging / UI
    @Published var consoleLog: String = "System ready\n"
    private var logBuffer: [String] = []
    private let maxLogEntries = 200

    // MARK: - Matches / History
    @Published var matchTime: Double = 0.0
    @Published var matchHistory: [Double] = []
    
    // MARK: - Distance/Signal Monitoring
    @Published var signalStrength: Double = 1.0  // 0.0 (weak) to 1.0 (strong)
    @Published var isDeviceFarFromSource: Bool = false
    private var lastMatchTime: Date = Date()
    private var signalMonitoringTimer: Timer?

    // MARK: - Host-time anchors (for diagnostics and ignore window)
    private var lastBufferHostTime: UInt64 = 0
    private var bufferProcessingStartHostTime: UInt64 = 0
    private var currentMatchStartTime: UInt64 = 0
    private nonisolated(unsafe) var ignoreMatchesUntil: UInt64 = 0  // Post-seek ignore window
    private nonisolated(unsafe) var lastSeekMach: UInt64 = 0  // For seek hysteresis

    // MARK: - Player integration
    var getCurrentPlayerTime: (() -> Double)?
    var seekWithTimestamp: ((Double, UInt64) -> Void)?
    private var playerBaselineTime: Double = 0.0

    // MARK: - Internal throttling
    private nonisolated(unsafe) var lastHandledMatchMach: UInt64 = 0
    private nonisolated(unsafe) var lastSeekCompletionMach: UInt64 = 0
    private let minMatchIntervalSeconds: Double = 0.15  // Increased to prevent double audio
    private let seekHysteresisSeconds: Double = 0.5  // Increased to prevent rapid re-seeking
    private let minSeekCompletionInterval: Double = 0.8  // Minimum time between seek completions

    // MARK: - Mach time utilities (now nonisolated for safe use in delegate)
    private nonisolated(unsafe) func machToSeconds(_ ticks: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos = Double(ticks) * Double(info.numer) / Double(info.denom)
        return nanos / 1_000_000_000.0
    }

    private nonisolated(unsafe) func machDiffSeconds(from: UInt64, to: UInt64) -> Double {
        guard to > from else { return 0.0 }
        return machToSeconds(to - from)
    }

    // MARK: - Public API
    func prepare() async {
        log("Preparing Shazam catalog...")
        do {
            try await catalogManager.loadCatalog()
            log("Catalog loaded successfully")
        } catch {
            log("Catalog error: \(error.localizedDescription)")
        }
    }

    func startListening() async {
        guard !isListening else { return }
        await resetTimingAnchors()
        isListening = true
        isCurrentlyListening = true
        do {
            try await startSingleListeningSession()
            log("🎧 Listening started.")
        } catch {
            log("⚠️ startListening error: \(error.localizedDescription)")
            await stopListening()  // Cleanup on error
        }
    }

    func stopListening() async {
        guard isListening else { return }
        restartTimer?.invalidate()
        restartTimer = nil
        isListening = false
        isCurrentlyListening = false
        pauseCountdown = 0

        // Stop audio engine gracefully
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        session?.delegate = nil
        session = nil

        // NEVER deactivate audio session - maintain continuous background operation
        // This prevents audio interruptions when device moves far from source
        log("🛑 Listening paused - audio session maintained for continuous operation.")
        
        // Stop signal monitoring
        signalMonitoringTimer?.invalidate()
        signalMonitoringTimer = nil
    }

    // MARK: - Reset anchors
    private func resetTimingAnchors() async {
        hasFoundMatchThisSession = false
        lastBufferHostTime = 0
        bufferProcessingStartHostTime = 0
        currentMatchStartTime = 0
        ignoreMatchesUntil = 0
        lastSeekMach = 0
        playerBaselineTime = getCurrentPlayerTime?() ?? 0.0

        // Clean engine state
        audioEngine.stop()
        audioEngine.reset()
        audioEngine.inputNode.removeTap(onBus: 0)
        session?.delegate = nil
        session = nil
    }

    // MARK: - Core listening
    private func startSingleListeningSession() async throws {
        // Enhanced audio session configuration for seamless operation
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, 
                                   mode: .default, 
                                   options: [.allowBluetoothA2DP, .mixWithOthers, .defaultToSpeaker])
        
        // Use higher performance settings for continuous operation
        try audioSession.setPreferredSampleRate(44100)
        try audioSession.setPreferredIOBufferDuration(0.005) // 5ms buffer for ultra-low latency
        
        // Keep session active during cycle mode to prevent interruptions
        try audioSession.setActive(true, options: [])

        audioInputLatencyMs = audioSession.inputLatency * 1000.0
        audioOutputLatencyMs = audioSession.outputLatency * 1000.0
        log("🎛️ Input \(String(format: "%.1f", audioInputLatencyMs)) ms / Output \(String(format: "%.1f", audioOutputLatencyMs)) ms")

        let catalog = catalogManager.getCatalog()
        session = SHSession(catalog: catalog)
        session?.delegate = self

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, time in  // Further reduced buffer size
            self?.processAudioBuffer(buffer, at: time)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isCurrentlyListening = true
        log("🎧 Audio engine started — seamless listening (buffer: 512 samples, 5ms latency).")
        
        // Start signal strength monitoring
        startSignalMonitoring()
    }

    // MARK: - Seek delay measurement with ignore window
    func recordPlayerSeekDelay(seekStartTime: UInt64, seekCompletionTime: UInt64) {
        guard seekCompletionTime > seekStartTime else { return }
        let delaySec = machDiffSeconds(from: seekStartTime, to: seekCompletionTime)
        playerSeekDelayMs = delaySec * 1000
        lastSeekMach = seekCompletionTime  // Hysteresis anchor
        lastSeekCompletionMach = seekCompletionTime  // Track completion for double audio prevention

        // Extended ignore window to prevent double audio
        ignoreMatchesUntil = mach_absolute_time() + UInt64(0.2 * 1_000_000_000.0)  // 200ms ignore window

        log("🕐 Seek delay: \(String(format: "%.1f", playerSeekDelayMs))ms. Ignoring matches for 200ms to prevent double audio.")
    }

    // MARK: - Process audio buffers
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        guard let audioTime = time else { return }

        audioQueue.async { [weak self] in
            guard let self = self else { return }
            let audioHost = audioTime.audioTimeStamp.mHostTime
            self.lastBufferHostTime = audioHost

            let startMach = mach_absolute_time()
            self.bufferProcessingStartHostTime = startMach

            let now = mach_absolute_time()
            let delay = self.machDiffSeconds(from: audioHost, to: now)

            DispatchQueue.main.async {
                self.inputBufferDelayMs = delay * 1000.0
            }

            // Send to Shazam
            self.session?.matchStreamingBuffer(buffer, at: audioTime)
        }
    }

    // MARK: - SHSessionDelegate
    nonisolated func session(_ session: SHSession, didFind match: SHMatch) {
        let matchMach = mach_absolute_time()
        let minIntervalTicks = UInt64(minMatchIntervalSeconds * 1_000_000_000)

        // Throttle duplicates
        if lastHandledMatchMach != 0 && (matchMach - lastHandledMatchMach) < minIntervalTicks {
            return
        }

        // Ignore post-seek stale matches
        if matchMach < ignoreMatchesUntil {
            return
        }

        // Hysteresis: Ignore if too soon after last seek (now safe with nonisolated machDiffSeconds)
        if lastSeekMach != 0 {
            let timeSinceSeek = machDiffSeconds(from: lastSeekMach, to: matchMach)
            if timeSinceSeek < seekHysteresisSeconds {
                return
            }
        }
        
        // Prevent double audio: Ignore if seek just completed
        if lastSeekCompletionMach != 0 {
            let timeSinceSeekCompletion = machDiffSeconds(from: lastSeekCompletionMach, to: matchMach)
            if timeSinceSeekCompletion < minSeekCompletionInterval {
                return
            }
        }

        lastHandledMatchMach = matchMach

        calculationQueue.async { [weak self] in
            guard let self = self else { return }
            guard let item = match.mediaItems.first else { return }
            let refTime = item.predictedCurrentMatchOffset  // Current predicted position

            let procDelaySec = self.machDiffSeconds(from: self.bufferProcessingStartHostTime, to: matchMach)
            let measuredProcessingMs = procDelaySec * 1000.0

            // Loop latency: output + input + prop (tuned for delay; predicted handles Shazam proc)
            let loopLatency = (self.audioOutputLatencyMs + self.audioInputLatencyMs + 20.0) / 1000.0  // Further reduced processing overhead
            let currentTheaterTime = refTime + loopLatency

            let playerTime = self.getCurrentPlayerTime?() ?? 0.0
            let diff = currentTheaterTime - playerTime
            let absDiff = abs(diff)
            let isForward = diff > 0
            
            // Enhanced seek decision with conservative thresholds to prevent double audio
            var shouldSeek = absDiff > 0.25 && absDiff < 4.0  // More conservative thresholds
            
            // Only reduce threshold for strong, consistent directional movement
            if consecutiveDirectionalSeeks > 2 && ((isForward && diff > 0.15) || (!isForward && diff < -0.15)) {
                shouldSeek = absDiff > 0.18  // Slightly more responsive for strong directional patterns
            }

            DispatchQueue.main.async {
                self.measuredProcessingDelayMs = measuredProcessingMs
                self.currentMatchStartTime = matchMach
                self.matchCount += 1
                self.matchHistory.append(currentTheaterTime)
                self.matchTime = currentTheaterTime
                
                self.log(String(format: "Match #%d: Predicted=%.2f, Player=%.2f, Δ=%.0fms (loop: %.0fms, proc: %.0fms) %@",
                               self.matchCount, refTime, playerTime, absDiff * 1000.0, loopLatency * 1000.0, measuredProcessingMs,
                               shouldSeek ? "→SEEK" : "→SKIP"))

                if shouldSeek {
                    // Prevent erratic seeking with minimum interval
                    let timeSinceLastSeek = self.machDiffSeconds(from: self.lastSeekMach, to: matchMach)
                    let canSeek = timeSinceLastSeek > 0.5  // 500ms minimum between seeks
                    
                    if canSeek {
                        // Predictive seek compensation based on direction and velocity
                        var compensatedTime = currentTheaterTime
                        
                        // Add predictive offset for fast directional changes
                        if self.consecutiveDirectionalSeeks > 1 {
                            let seekVelocity = abs(currentTheaterTime - self.lastSeekTargetTime)
                            if seekVelocity > 0.5 {  // Fast seeking detected
                                let predictiveOffset = isForward ? 0.03 : -0.03
                                compensatedTime += predictiveOffset
                            }
                        }
                        
                        let seekStart = mach_absolute_time()
                        self.lastSeekMach = seekStart
                        self.seekWithTimestamp?(compensatedTime, seekStart)
                        self.isPerformanceGood = absDiff < 0.1
                        
                        self.log("🎯 Enhanced Seek: \(isForward ? "⏩" : "⏪") Δ=\(String(format: "%.0f", diff * 1000))ms → \(String(format: "%.3f", compensatedTime))s")
                    } else {
                        self.log("⏸️ Seek throttled: Too frequent (last seek \(String(format: "%.0f", timeSinceLastSeek * 1000))ms ago)")
                    }
                } else {
                    self.isPerformanceGood = absDiff < 0.1
                    self.log("✅ Sync OK: \(String(format: "%.0f", absDiff * 1000))ms within threshold")
                }

                // Update signal strength based on match frequency
                self.lastMatchTime = Date()
                self.signalStrength = min(1.0, self.signalStrength + 0.2)  // Boost signal on successful match
                
                // Improved cycle handling - seamless continuous operation
                if self.isCycleEnabled && !self.hasFoundMatchThisSession {
                    self.hasFoundMatchThisSession = true
                    self.log("🔄 Cycle match found - maintaining seamless listening.")
                }
            }
        }
    }

    nonisolated func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.log("No match: \(error?.localizedDescription ?? "none")")
            
            // Reduce signal strength on failed matches
            if let self = self {
                self.signalStrength = max(0.0, self.signalStrength - 0.05)
                self.updateDistanceStatus()
            }
        }
    }
    
    // MARK: - Signal Strength Monitoring
    private func startSignalMonitoring() {
        signalMonitoringTimer?.invalidate()
        signalMonitoringTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // Gradually reduce signal strength over time (simulating distance)
            let timeSinceLastMatch = -self.lastMatchTime.timeIntervalSinceNow
            if timeSinceLastMatch > 5.0 {  // No matches for 5+ seconds
                self.signalStrength = max(0.0, self.signalStrength - 0.1)
            }
            
            self.updateDistanceStatus()
            
            // Auto-recovery: if signal was weak but now improving
            if self.isDeviceFarFromSource && self.signalStrength > 0.3 {
                self.log("📶 Signal recovering (\(String(format: "%.0f", self.signalStrength * 100))%) - attempting auto-restart")
                Task {
                    await self.restartListeningIfNeeded()
                }
            }
            
            self.log("📊 Signal: \(String(format: "%.0f", self.signalStrength * 100))% | Distance: \(self.isDeviceFarFromSource ? "FAR" : "GOOD")")
        }
    }
    
    private func updateDistanceStatus() {
        let wasFar = isDeviceFarFromSource
        isDeviceFarFromSource = signalStrength < 0.2  // Consider far when signal < 20%
        
        if !wasFar && isDeviceFarFromSource {
            log("⚠️ Device moving far from audio source - maintaining session but pausing processing")
        } else if wasFar && !isDeviceFarFromSource {
            log("✅ Device returning to optimal range - resuming full processing")
        }
    }
    
    private func restartListeningIfNeeded() async {
        guard isDeviceFarFromSource && signalStrength > 0.3 && !isCurrentlyListening else { return }
        
        do {
            log("🔄 Auto-restarting listening due to improved signal")
            try await startSingleListeningSession()
            isDeviceFarFromSource = false
        } catch {
            log("⚠️ Auto-restart failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Cycle helper
    private var restartTimer: Timer?

    // MARK: - Sync helper
    private var lastSeekDirection: Int = 0  // -1 for backward, 0 for none, 1 for forward
    private var consecutiveDirectionalSeeks: Int = 0
    private var lastSeekTargetTime: Double = 0.0
    
    func shouldPerformSeek(targetTime: Double, currentPlayerTime: Double) -> Bool {
        let diff = targetTime - currentPlayerTime
        let absDiff = abs(diff)
        
        // Determine seek direction
        let currentDirection = diff > 0 ? 1 : (diff < 0 ? -1 : 0)
        
        // Track consecutive directional seeks for smoothing
        if currentDirection == lastSeekDirection && currentDirection != 0 {
            consecutiveDirectionalSeeks += 1
        } else {
            consecutiveDirectionalSeeks = 0
        }
        lastSeekDirection = currentDirection
        
        // Enhanced thresholds based on direction and pattern
        var threshold: Double = 0.15  // Base threshold
        
        // Reduce threshold for consistent directional seeking (forward/backward)
        if consecutiveDirectionalSeeks > 2 {
            threshold = 0.08  // More aggressive for consistent direction
        }
        
        // Increase threshold for large jumps to prevent overshooting
        if absDiff > 2.0 {
            threshold = 0.25  // More conservative for large seeks
        }
        
        // Predictive compensation for rapid directional changes
        if consecutiveDirectionalSeeks > 1 {
            let seekVelocity = abs(targetTime - lastSeekTargetTime)
            if seekVelocity > 1.0 {  // Fast seeking detected
                threshold *= 0.7  // Reduce threshold for faster response
            }
        }
        
        lastSeekTargetTime = targetTime
        
        return absDiff > threshold
    }

    // MARK: - Logging utilities
    private func timestamp() -> String {
        let df = DateFormatter()
        df.timeStyle = .medium
        return df.string(from: Date())
    }

    private func log(_ message: String) {
        let entry = "[\(timestamp())] \(message)\n"
        logBuffer.append(entry)
        if logBuffer.count > maxLogEntries {
            logBuffer.removeFirst(logBuffer.count - maxLogEntries)
        }
        consoleLog = logBuffer.joined()
        print(entry.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
