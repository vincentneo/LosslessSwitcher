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
    static func getRecentEntries() throws -> [OSLogEntry] {
        let store = try OSLogStore.local()
        let fiveMinutesAgo = store.position(timeIntervalSinceEnd: -60.0 * 3)
        let entries = try store.getEntries(with: [], at: fiveMinutesAgo, matching: nil)
        
        return entries.reversed()
    }
}
