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
        spawnProcess()
    }
    
    private func spawnProcess() {
        let process = Process()
        self.process = process
        
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
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
        process.standardError = nil
        
        // Use a dispatch source for non-blocking reading from the pipe
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
            print("[LogReader] Process error: \(error)")
            self.process = nil
            // Retry after delay
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.spawnProcessIfNeeded()
            }
        }
    }
    
    func stopProcess() {
        process?.terminate()
        process = nil
    }
    
    private func processLine(_ line: String) {
        guard let dateSubstring = line.firstSubstring(between: .start, and: " Df ") else { return }
        guard let messageContentSubstring = line.firstSubstring(between: "[com.apple.Music:ampplay] play> cm>> ", and: .end) else { return }
        let dateString = String(dateSubstring)
        let message = String(messageContentSubstring)
        let date = dateFormatter.date(from: dateString)
        
        let split = message.split(separator: ",")
        var trackName: String?
        var isLossless: Bool?
        var bitDepth: Int?
        var sampleRate: Int?
        
        for element in split {
            if trackName == nil, element.hasPrefix("mediaFormatinfo") {
                guard let substring = element.firstSubstring(between: "\'", and: "\'") else { continue }
                trackName = String(substring)
                continue
            }
            
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
                guard let double = Double(String(substring)) else { continue }
                sampleRate = Int(double * 1000)
                continue
            }
        }
        
        // Track name may be <private> without the privacy profile installed
        if let tn = trackName, tn == "<private>" {
            trackName = nil
        }
        
        guard let date, let isLossless, let sampleRate else { return }
        
        // Discard lossy entries to prevent over-switching
        guard isLossless else { return }
        
        let entry = CMEntry(date: date, trackName: trackName, bitDepth: bitDepth, sampleRate: sampleRate)
        entryStream.send(entry)
    }
    
    deinit {
        stopProcess()
    }
}
