//
//  SyncTimingModel.swift
//  DCDC APP POC
//
//  Created by Umid Ghimire on 2025-09-29.
//


import Foundation

struct SyncTimingModel {
    let matchTime: Double
    let processingDelayMs: Double
    let isPerformanceGood: Bool
    let matchCount: Int

    var formattedMatchTime: String {
        let hours = Int(matchTime) / 3600
        let minutes = Int(matchTime) % 3600 / 60
        let seconds = Int(matchTime) % 60
        let milliseconds = Int((matchTime.truncatingRemainder(dividingBy: 1)) * 1000)

        if hours > 0 {
            return String(format: "%d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
        } else if minutes > 0 {
            return String(format: "%d:%02d.%03d", minutes, seconds, milliseconds)
        } else {
            return String(format: "%.3fs", matchTime)
        }
    }

    var performanceStatus: String {
        return isPerformanceGood ? "< 80ms" : "> 80ms"
    }

    var performanceColor: String {
        return isPerformanceGood ? "green" : "red"
    }
}