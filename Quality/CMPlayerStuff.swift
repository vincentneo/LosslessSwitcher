//
//  CMPlayerStats.swift
//  Quality
//
//  Created by Vincent Neo on 19/4/22.
//

import Foundation
import OSLog
import Sweep

struct CMPlayerStats {
    let sampleRate: Double // Hz
    let bitDepth: Int
    let date: Date
}

class CMPlayerParser {
    static func parseMusicConsoleLogs(_ entries: [SimpleConsole]) -> [CMPlayerStats] {
        let kTimeDifferenceAcceptance = 5.0 // seconds
        var lastDate: Date?
        var sampleRate: Double?
        var bitDepth: Int?
        
        var stats = [CMPlayerStats]()
        
        for entry in entries {
            //if let log = entry as? OSLogEntryLog {
             //   if log.subsystem == "com.apple.Music" {
                    let date = entry.date
                    let rawMessage = entry.message
                    
                    if let lastDate = lastDate, date.timeIntervalSince(lastDate) > kTimeDifferenceAcceptance {
                        sampleRate = nil
                        bitDepth = nil
                    }
                    
                    if let subSampleRate = rawMessage.firstSubstring(between: "asbdSampleRate = ", and: " kHz") {
                        let strSampleRate = String(subSampleRate)
                        sampleRate = Double(strSampleRate)
                    }
                    
                    if let subBitDepth = rawMessage.firstSubstring(between: "sdBitDepth = ", and: " bit") {
                        let strBitDepth = String(subBitDepth)
                        bitDepth = Int(strBitDepth)
                    }
                    else if rawMessage.contains("sdBitRate") { // lossy
                        bitDepth = 16
                    }
                    
                    if let sr = sampleRate,
                       let bd = bitDepth {
                        let stat = CMPlayerStats(sampleRate: sr * 1000, bitDepth: bd, date: date)
                        stats.append(stat)
                        sampleRate = nil
                        bitDepth = nil
                        print(rawMessage)
                    }
                    
                    lastDate = date
                    
                }
            //}
        //}
        return stats
    }
}
