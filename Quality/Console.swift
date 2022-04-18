//
//  Console.swift
//  Quality
//
//  Created by Vincent Neo on 19/4/22.
//
// https://developer.apple.com/forums/thread/677068

import OSLog
import Cocoa

class Console {
    func getMusicEntries() {
        do {
            let store = try OSLogStore.local()
            let fiveMinutesAgo = store.position(timeIntervalSinceEnd: -60.0 * 5)
            let entries = try store.getEntries(with: [.reverse], at: fiveMinutesAgo, matching: nil)
            for e in entries {
                if let log = e as? OSLogEntryLog {
                    if log.subsystem == "com.apple.Music" {
                        print(e.date, e.composedMessage)
                    }
                }
            }
        }
        catch {
            print(error)
        }
    }
}
