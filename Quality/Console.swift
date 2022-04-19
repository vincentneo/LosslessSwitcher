//
//  Console.swift
//  Quality
//
//  Created by Vincent Neo on 19/4/22.
//
// https://developer.apple.com/forums/thread/677068

import OSLog
import Cocoa

struct SimpleConsole {
    let date: Date
    let message: String
}

class Console {
    static func getRecentEntries() throws -> [SimpleConsole] {
        var messages = [SimpleConsole]()
        let store = try OSLogStore.local()
        let duration = store.position(timeIntervalSinceEnd: -5.0)
        let entries = try store.getEntries(with: [], at: duration, matching: NSPredicate(format: "subsystem = %@", "com.apple.Music"))
        // for some reason AnySequence to Array turns it into a empty array?
        for entry in entries {
            let consoleMessage = SimpleConsole(date: entry.date, message: entry.composedMessage)
            messages.append(consoleMessage)
        }
        
        return messages.reversed()//entries.reversed()
    }
}
