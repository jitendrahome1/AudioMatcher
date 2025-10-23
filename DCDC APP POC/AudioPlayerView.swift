import SwiftUI

import AVFoundation



struct AudioPlayerView: View {

    @State private var isPlaying = false

    @State private var currentTime: Double = 0

    @State private var duration: Double = 0

    @State private var audioPlayer: AVAudioPlayer?



    @State private var lastKnownTheaterTime: Double = 0

    @State private var lastUpdateTime: Date = Date()

    @State private var targetPlaybackRate: Float = 1.0

    @State private var syncHistory: [(theaterTime: Double, phoneTime: Double, timestamp: Date)] = []


    @State private var theaterStartTime: Date?

    @State private var theaterStartOffset: Double = 0

    @State private var timer: Timer?

    // MARK: - Directional Seek Smoothing
    @State private var seekVelocityHistory: [(time: Double, timestamp: Date)] = []
    @State private var lastSeekDirection: Int = 0  // -1 backward, 0 none, 1 forward
    @State private var consecutiveDirectionalSeeks: Int = 0
    @State private var smoothingBuffer: [Double] = []
    
    private struct Constants {
        static let defaultVolume: Float = 0.5
        static let timerInterval: TimeInterval = 0.1
        static let microSyncThreshold: Double = 0.03  // Reduced for more responsive micro adjustments
        static let syncThreshold: Double = 0.12  // Reduced to match AudioMatcher's enhanced directional threshold
        static let fallbackSyncThreshold: Double = 0.25  // Reduced for better responsiveness
        static let predictiveCompensation: Double = 0.02  // Predictive offset for directional seeks
    }




    @ObservedObject var syncService: AudioSyncService
    @Binding var shouldSeekTo: Double?
    @Binding var shouldAutoPlay: Bool
    
    @State private var resumeWorkItem: DispatchWorkItem? = nil

    var body: some View {
        VStack(spacing: 12) {
            Button(action: {
                syncService.togglePlayback()
            }) {
                Image(systemName: syncService.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.blue)
                    .clipShape(Circle())
            }
            
            Slider(value: $syncService.currentTime, in: 0...syncService.duration) { editing in
                if !editing {
                    syncService.seekToPosition(syncService.currentTime)
                }
            }
            .accentColor(.blue)
            
            HStack {
                Image(systemName: "speaker.fill")
                    .foregroundColor(.gray)
                    .font(.caption2)
                
                Slider(value: $syncService.volume, in: 0...1) { _ in
                    syncService.updateVolume(syncService.volume)
                }
                .accentColor(.orange)
                .frame(height: 20)
                
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundColor(.gray)
                    .font(.caption2)
            }
            
            HStack {
                Text(formatTime(syncService.currentTime))
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(4)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                Spacer()
                Text("/")
                    .font(.title3)
                    .foregroundColor(.secondary)
                Spacer()
                Text(formatTime(syncService.duration))
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(4)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .onAppear {
            setupAudioMatcherCallback()
        }
        .onDisappear {
            // No cleanup needed - player managed by service
        }
        .onChange(of: shouldSeekTo) { newValue in
            if let theaterTime = newValue {
                updateTheaterSync(theaterTime: theaterTime)
                
                if shouldAutoPlay && !syncService.isPlaying {
                    syncService.togglePlayback() // This will start playing
                }
                
                shouldSeekTo = nil
            }
        }
    }
    
    // Directional seek smoothing functions
    private func addSeekToHistory(_ targetTime: Double) {
        let now = Date()
        seekVelocityHistory.append((time: targetTime, timestamp: now))
        
        // Keep only last 5 seeks for velocity calculation
        if seekVelocityHistory.count > 5 {
            seekVelocityHistory.removeFirst()
        }
        
        // Calculate seek direction and velocity
        let direction = targetTime > syncService.currentTime ? 1 : (targetTime < syncService.currentTime ? -1 : 0)
        
        if direction == lastSeekDirection && direction != 0 {
            consecutiveDirectionalSeeks += 1
        } else {
            consecutiveDirectionalSeeks = 0
        }
        lastSeekDirection = direction
        
        // Add to smoothing buffer
        smoothingBuffer.append(targetTime)
        if smoothingBuffer.count > 3 {
            smoothingBuffer.removeFirst()
        }
    }
    
    private func getSmoothedSeekTarget(_ rawTarget: Double) -> Double {
        guard smoothingBuffer.count >= 2 else { return rawTarget }
        
        // Calculate velocity and apply smoothing for fast directional seeks
        if consecutiveDirectionalSeeks > 2 {
            let recentSeeks = Array(smoothingBuffer.suffix(3))
            let avgTarget = recentSeeks.reduce(0, +) / Double(recentSeeks.count)
            
            // Apply exponential smoothing for consistent direction
            let smoothingFactor = 0.7
            return rawTarget * smoothingFactor + avgTarget * (1 - smoothingFactor)
        }
        
        return rawTarget
    }
    
    private func calculateSeekVelocity() -> Double {
        guard seekVelocityHistory.count >= 2 else { return 0 }
        
        let recent = seekVelocityHistory.suffix(2)
        let timeDiff = recent.last!.timestamp.timeIntervalSince(recent.first!.timestamp)
        let positionDiff = abs(recent.last!.time - recent.first!.time)
        
        return timeDiff > 0 ? positionDiff / timeDiff : 0
    }
    
    // Seek functions
    private func seekToPosition(_ time: Double) {
        seekToPositionWithTimestamp(time, nil)
    }
    
    private func seekToPositionWithTimestamp(_ time: Double, _ startTime: UInt64?) {
        guard let player = syncService.audioPlayer, time >= 0, time <= syncService.duration else { return }
        
        let diff = abs(time - syncService.currentTime)
        let isForward = time > syncService.currentTime
        
        // Enhanced directional seek handling
        if diff < 0.03 {  // Ultra-micro adjustment - direct set
            player.currentTime = time
            print("🎯 ULTRA-MICRO: Direct set to \(String(format: "%.3f", time))s")
            return
        }
        
        if diff < 0.08 {  // Micro adjustment with direction-aware smoothing
            let wasPlaying = syncService.isPlaying
            
            // Directional fade for smoother transitions
            if wasPlaying {
                // Quick fade out
                player.setVolume(0.3, fadeDuration: 0.02)
            }
            
            player.currentTime = time
            
            if wasPlaying {
                // Quick fade back in
                player.setVolume(syncService.volume, fadeDuration: 0.03)
            }
            
            print("🔧 DIRECTIONAL-MICRO: \(isForward ? "⏩" : "⏪") \(String(format: "%.0f", diff * 1000))ms")
            return
        }
        
        if diff < 0.25 {  // Small adjustment with predictive compensation
            let wasPlaying = syncService.isPlaying
            
            if wasPlaying {
                // Smooth volume fade
                player.setVolume(0.1, fadeDuration: 0.05)
                
                // Predictive seek - compensate for processing delay
                let compensatedTime = isForward ? time + 0.02 : time - 0.02
                player.currentTime = max(0, min(syncService.duration, compensatedTime))
                
                // Quick fade back
                player.setVolume(syncService.volume, fadeDuration: 0.08)
            } else {
                player.currentTime = time
            }
            
            print("🚀 PREDICTIVE-SEEK: \(isForward ? "⏩" : "⏪") to \(String(format: "%.3f", time))s")
            return
        }
        
        // Large seek - minimize interruption with smart buffering
        let wasPlaying = syncService.isPlaying
        
        if wasPlaying {
            player.pause()
            player.currentTime = time
            
            resumeWorkItem?.cancel()
            
            let workItem = DispatchWorkItem {
                if self.syncService.isPlaying {
                    self.syncService.audioPlayer?.play()
                }
            }
            
            resumeWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
        } else {
            player.currentTime = time
        }
        
        print("⚡ FAST-SEEK: \(isForward ? "⏩" : "⏪") Large jump to \(String(format: "%.3f", time))s")
        
        // Record seek timing for AudioMatcher
        if let startTime = startTime {
            let completionTime = mach_absolute_time()
            syncService.audioMatcher.recordPlayerSeekDelay(seekStartTime: startTime, seekCompletionTime: completionTime)
        }
    }
    
    private func microAdjustSync(targetTime: Double) {
        guard let player = syncService.audioPlayer else { return }
        
        let currentPos = player.currentTime
        let difference = targetTime - currentPos
        
        if abs(difference) < Constants.microSyncThreshold {
            return
        }

        let wasPlaying = syncService.isPlaying
        if wasPlaying {
            player.pause()
        }

        player.currentTime = targetTime
        print("🔧 MICRO-ADJUSTED: \(String(format: "%.0f", difference * 1000))ms correction")

        if wasPlaying {
            resumeWorkItem?.cancel()
            
            let workItem = DispatchWorkItem {
                if self.syncService.isPlaying {
                    self.syncService.audioPlayer?.play()
                }
            }
            
            resumeWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: workItem)
        }
    }
    
    private func updateTheaterSync(theaterTime: Double) {
        // Add seek to history for smoothing
        addSeekToHistory(theaterTime)
        
        // Apply smoothing for rapid directional seeks
        let smoothedTheaterTime = getSmoothedSeekTarget(theaterTime)
        let seekVelocity = calculateSeekVelocity()
        
        let phoneTime = syncService.currentTime
        let difference = smoothedTheaterTime - phoneTime
        
        print("🎯 ENHANCED SYNC ANALYSIS:")
        print("   📱 Phone audio at: \(String(format: "%.3f", phoneTime))s")
        print("   🎬 Theater target: \(String(format: "%.3f", theaterTime))s")
        print("   🔧 Smoothed target: \(String(format: "%.3f", smoothedTheaterTime))s")
        print("   📊 Difference: \(String(format: "%.3f", difference))s")
        print("   🚀 Seek velocity: \(String(format: "%.2f", seekVelocity))s/s")
        print("   🔄 Consecutive directional: \(consecutiveDirectionalSeeks)")
        
        let absDifference = abs(difference)
        if absDifference < Constants.syncThreshold {
            print("   ✅ MICRO-DIFF: Only \(String(format: "%.0f", absDifference * 1000))ms - no adjustment needed")
            return
        }
        
        if difference > 0 {
            print("   ⏩ Theater is AHEAD - Phone needs to seek FORWARD")
        } else {
            print("   ⏪ Theater is BEHIND - Phone needs to seek BACKWARD")
        }
        
        print("   🔍 Seeking to: \(String(format: "%.3f", smoothedTheaterTime))s")
        
        let shouldSeek = syncService.audioMatcher.shouldPerformSeek(targetTime: smoothedTheaterTime, currentPlayerTime: phoneTime)
        
        if shouldSeek {
            print("🚀 ENHANCED SEEK:")
            print("   Target: \(String(format: "%.3f", smoothedTheaterTime))s")
            print("   Velocity-aware smoothing applied")
            
            let seekCommandTime = mach_absolute_time()
            seekToPositionWithTimestamp(smoothedTheaterTime, seekCommandTime)
        } else {
            print("✅ SMART SKIP: Within acceptable threshold, no seek needed")
        }
    }
    
    private func setupAudioMatcherCallback() {
        syncService.audioMatcher.getCurrentPlayerTime = {
            return self.syncService.currentTime
        }
        
        syncService.audioMatcher.seekWithTimestamp = { time, startTime in
            self.seekToPositionWithTimestamp(time, startTime)
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let seconds = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    AudioPlayerView(
        syncService: AudioSyncService(),
        shouldSeekTo: .constant(nil),
        shouldAutoPlay: .constant(true)
    )
}
