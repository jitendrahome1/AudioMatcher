//
//  AudioSyncService.swift
//  DCDC APP POC
//
//  Created by Umid Ghimire on 2025-09-29.
//


import Foundation
import Combine
import AVFoundation

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
    
    private var timer: Timer?

    init() {
        self.audioMatcher = AudioMatcher()
        setupBindings()
        setupAudioPlayer()
    }

    private func setupBindings() {
        audioMatcher.$matchTime.assign(to: &$matchTime)
        audioMatcher.$isListening.assign(to: &$isListening)
        audioMatcher.$matchHistory.assign(to: &$matchHistory)
    }
    
    private func setupAudioPlayer() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true, options: [])
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
        
        // Setup timer for current time updates
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.currentTime = self?.audioPlayer?.currentTime ?? 0
        }
    }

    func togglePlayback() {
        if isPlaying {
            audioPlayer?.pause()
            isPlaying = false
        } else {
            audioPlayer?.play()
            isPlaying = true
        }
    }
    
    func seekToPosition(_ time: Double) {
        audioPlayer?.currentTime = time
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
}
