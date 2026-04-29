//
//  Console.swift
//  Quality
//
//  Created by Vincent Neo on 19/4/22.
//
// https://developer.apple.com/forums/thread/677068

import Cocoa

struct SimpleConsole {
    let date: Date
    let message: String
}

enum EntryType: String {
    case music = "com.apple.Music"
    case coreAudio = "com.apple.coreaudio"
    case coreMedia = "com.apple.coremedia"
    
    var predicate: NSPredicate {
        NSPredicate(format: "(subsystem = %@) AND (process = %@)", argumentArray: [rawValue, "Music"])
    }
}

class Console {
    // OSLogStore.local() causes 100% CPU on macOS 26+.
    // Log reading is now handled by LogReader using Process() + log stream.
    // This method is kept as a stub for backward compatibility.
    static func getRecentEntries(type: EntryType) throws -> [SimpleConsole] {
        return []
    }
}
