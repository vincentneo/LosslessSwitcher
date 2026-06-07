//
//  LogReader.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 1/3/26.
//

import Foundation
import Combine
import Sweep

class LogReader {
    
    let entryStream = PassthroughSubject<CMEntry, Never>()
    
    private var process: Process?
    private let dateFormatter: DateFormatter
    
    init() {
        let dateFormatter = DateFormatter()
        dateFormatter.timeZone = .autoupdatingCurrent
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.dateFormatter = dateFormatter
    }
    
    func spawnProcessIfNeeded() {
        guard process == nil else { return }
        self.spawnProcess()
    }
    
    private func spawnProcess() {
        let process = Process()
        self.process = process
        
        process.executableURL = URL(filePath: "/usr/bin/log")
        process.arguments = [
            "stream",
            "--style",
            "compact",
            "--no-backtrace",
            "--predicate",
            "process = \"Music\" AND category=\"ampplay\""
        ]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            
            guard let line = String(data: data, encoding: .utf8) else { return }
            self?.processLine(line)
        }
        
        do {
            try process.run()
        }
        catch {
            print("ProcessErr \(error)")
        }
    }
    
    private func processLine(_ line: String) {
//        print("\n\nLINE: ", line)
        guard let dateSubstring = line.firstSubstring(between: .start, and: " Df ") else { return }
        guard let messageContentSubstring = line.firstSubstring(between: "[com.apple.Music:ampplay] play> cm>> " , and: .end) else { return }
        let dateString = String(dateSubstring)
        let message = String(messageContentSubstring)
        let date = dateFormatter.date(from: dateString)
        
        let split = message.split(separator: ",")
        var trackName: String?
        var isLossless: Bool?
        var bitDepth: Int?
        var sampleRate: Int?
        
        for element in split {
            
            // <private> in default circumstances
            if trackName == nil, element.hasPrefix("mediaFormatinfo") {
                guard let substring = element.firstSubstring(between: "\'", and: "\'") else { continue }
                trackName = String(substring)
                continue
            }
            
            // notes: there is a field that may be "lossless", "high res lossless" and "stereo (lossy)"
            
            if isLossless == nil, element.hasPrefix(" sdFormatID") {
                guard let substring = element.firstSubstring(between: "= ", and: .end) else { continue }
                isLossless = substring == "alac"
                continue
            }
            
            if bitDepth == nil, element.hasPrefix(" sdBitDepth") {
                guard let substring = element.firstSubstring(between: "= ", and: " bit") else { continue }
                bitDepth = Int(substring)
            }
            
            if sampleRate == nil, element.hasPrefix(" asbdSampleRate") {
                guard let substring = element.firstSubstring(between: "= ", and: " kHz") else { continue }
                let string = String(substring)
                guard let double = Double(string) else { continue }
                sampleRate = Int(double * 1000)
                continue
            }
            
        }
        
        // this requires an external profile to read this info
        // might be helpful to prevent the early track sample rate switch issue.
        // https://eclecticlight.co/2023/03/08/removing-privacy-censorship-from-the-log/
        if let tn = trackName, tn == "<private>" {
            trackName = nil
        }
        
        guard let date, let isLossless, let sampleRate else { return }
        
        // discard if entry is known to be for lossy playback
        // why?: while it could be nice to switch if you're playing a bunch of tracks where some are lossy,
        //       occassionally, there are lossless tracks where logs start off with these lossy information.
        //       to prevent over switching, i'm ignoring all lossy log entries.
        guard isLossless else { return }
        
        let entry = CMEntry(date: date, trackName: trackName, bitDepth: bitDepth, sampleRate: sampleRate)
//        print("\n\nXLINE", date, trackName, isLossless, bitDepth, sampleRate)
//        print("\n\nLINE", date, split)
        
        entryStream.send(entry)
    }
}
