//
//  AudioSyncService.swift
//  DCDC APP POC
//
//  Created by Umid Ghimire on 2025-09-29.
//


import Foundation
import Combine
import AVFoundation
import Darwin

@MainActor
final class AudioSyncService: ObservableObject {
    @Published var matchTime: Double = 0.0
    @Published var isListening: Bool = false
    @Published var matchHistory: [Double] = []

    let audioMatcher: AudioMatcher
    
    var audioPlayer: AVAudioPlayer?
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0.0
    @Published var duration: Double = 0.0
    @Published var volume: Float = 0.5
    
    // Enhanced timing for precise synchronization
    private var displayLink: CADisplayLink?
    private var lastSeekTime: CFTimeInterval = 0
    private var seekCompensationOffset: Double = 0
    private var playbackStartTime: CFTimeInterval = 0
    private var playbackStartOffset: Double = 0
    
    // Synchronization state
    private var isSyncing: Bool = false
    private var lastSyncTime: CFTimeInterval = 0
    private let syncCooldownInterval: Double = 0.1 // Minimum time between sync operations

    init() {
        self.audioMatcher = AudioMatcher()
        setupBindings()
        setupAudioPlayer()
        setupPreciseTimingUpdates()
    }

    private func setupBindings() {
        audioMatcher.$matchTime.assign(to: &$matchTime)
        audioMatcher.$isListening.assign(to: &$isListening)
        audioMatcher.$matchHistory.assign(to: &$matchHistory)
    }
    
    private func setupAudioPlayer() {
        do {
            // Enhanced audio session configuration for precise synchronization
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, 
                                       mode: .default, 
                                       options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            
            // Set optimal buffer duration for low latency
            try audioSession.setPreferredIOBufferDuration(0.005) // 5ms for ultra-low latency
            try audioSession.setPreferredSampleRate(44100)
            try audioSession.setActive(true, options: [])
        } catch {
            print("Audio session error: \(error)")
        }
        
        guard let url = Bundle.main.url(forResource: "KING OF THE PECOS", withExtension: "wav") else {
            print("Could not find KING OF THE PECOS.wav")
            return
        }
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.prepareToPlay()
            audioPlayer?.volume = volume
            duration = audioPlayer?.duration ?? 0
            print("Audio loaded: \(duration) seconds")
        } catch {
            print("Error setting up audio player: \(error)")
        }
    }
    
    // Replace timer with CADisplayLink for frame-accurate updates
    private func setupPreciseTimingUpdates() {
        displayLink = CADisplayLink(target: self, selector: #selector(updateCurrentTime))
        displayLink?.preferredFramesPerSecond = 60 // 60 FPS for smooth updates
        displayLink?.add(to: .main, forMode: .common)
    }
    
    @objc private func updateCurrentTime() {
        guard let player = audioPlayer else { return }
        
        if isPlaying {
            // Calculate precise current time with compensation
            let rawCurrentTime = player.currentTime
            let compensatedTime = rawCurrentTime + seekCompensationOffset
            
            // Apply playback timing correction if needed
            if playbackStartTime > 0 {
                let elapsedTime = CACurrentMediaTime() - playbackStartTime
                let expectedTime = playbackStartOffset + elapsedTime
                let timeDrift = abs(expectedTime - compensatedTime)
                
                // Micro-adjust for drift > 16ms (one frame at 60fps)
                if timeDrift > 0.016 && !isSyncing {
                    currentTime = expectedTime
                } else {
                    currentTime = compensatedTime
                }
            } else {
                currentTime = compensatedTime
            }
        } else {
            currentTime = player.currentTime + seekCompensationOffset
        }
    }

    func togglePlayback() {
        if isPlaying {
            pausePlayback()
        } else {
            startPlayback()
        }
    }
    
    private func startPlayback() {
        guard let player = audioPlayer else { return }
        
        // Record precise playback start timing
        playbackStartTime = CACurrentMediaTime()
        playbackStartOffset = player.currentTime
        seekCompensationOffset = 0 // Reset compensation on new playback
        
        player.play()
        isPlaying = true
        
        // Setup audio matcher callback for synchronization
        setupAudioMatcherIntegration()
    }
    
    private func pausePlayback() {
        audioPlayer?.pause()
        isPlaying = false
        playbackStartTime = 0 // Reset timing anchor
    }
    
    func seekToPosition(_ time: Double) {
        guard let player = audioPlayer, time >= 0, time <= duration else { return }
        
        let currentMachTime = mach_absolute_time()
        lastSeekTime = CACurrentMediaTime()
        
        // Prevent sync operations during seek
        isSyncing = true
        
        // Calculate seek compensation for immediate UI feedback
        let seekDelta = time - player.currentTime
        seekCompensationOffset = seekDelta
        
        // Perform the actual seek
        player.currentTime = time
        
        // Update playback timing anchors if playing
        if isPlaying {
            playbackStartTime = CACurrentMediaTime()
            playbackStartOffset = time
        }
        
        // Notify audio matcher about the seek with timestamp
        audioMatcher.recordPlayerSeekDelay(seekStartTime: currentMachTime, seekCompletionTime: mach_absolute_time())
        
        // Reset sync flag after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.isSyncing = false
            self?.seekCompensationOffset = 0
        }
    }
    
    private func setupAudioMatcherIntegration() {
        // Provide current player time callback to AudioMatcher
        audioMatcher.getCurrentPlayerTime = { [weak self] in
            return self?.currentTime ?? 0.0
        }
        
        // Provide seek callback with timestamp to AudioMatcher
        audioMatcher.seekWithTimestamp = { [weak self] targetTime, timestamp in
            Task { @MainActor in
                self?.performSynchronizedSeek(to: targetTime, timestamp: timestamp)
            }
        }
    }
    
    private func performSynchronizedSeek(to targetTime: Double, timestamp: UInt64) {
        let currentMachTime = CACurrentMediaTime()
        
        // Prevent rapid successive syncs
        guard currentMachTime - lastSyncTime > syncCooldownInterval else { return }
        lastSyncTime = currentMachTime
        
        // Only sync if the difference is significant enough
        let timeDifference = abs(targetTime - currentTime)
        guard timeDifference > 0.02 else { return } // 20ms threshold
        
        seekToPosition(targetTime)
    }
    
    func updateVolume(_ newVolume: Float) {
        volume = newVolume
        audioPlayer?.volume = newVolume
    }

    func startListening() async {
        await audioMatcher.startListening()
    }

    func stopListening() async {
        await audioMatcher.stopListening()
    }
    
    deinit {
        displayLink?.invalidate()
        displayLink = nil
    }
}
