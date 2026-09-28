//
//  MediaRemoteController.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 1/5/22.
//

import Cocoa
//import Combine
//import PrivateMediaRemote
import MediaRemoteAdapter

fileprivate let kMusicAppBundle = "com.apple.Music"

class MediaRemoteController {
    
    private let controller: MediaController
    
    init(outputDevices: OutputDevices) {
        
        Self.stopOrphanedHelpers()
        let controller = MediaController()
        self.controller = controller
        controller.startListening()
        
        controller.onTrackInfoReceived = { [weak outputDevices] trackInfo in
            print("track \(trackInfo.payload.uniqueIdentifier) \(trackInfo.payload.title ?? "nil")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let outputDevices else { return }
                outputDevices.trackDidChange(trackInfo)
            }
        }
        
    }
    
    deinit {
        controller.stopListening()
    }

    /// On quit (deinit never runs then): MediaRemoteAdapter's helper, `perl run.pl ... loop`, only
    /// writes to its pipe when a track changes, so it would run on after the app is gone.
    func stop() {
        controller.stopListening()
    }

    /// A crash or kill -9 leaves the helper behind, adopted by launchd. At launch, stop those: this
    /// user's `perl .../MediaRemoteAdapter_MediaRemoteAdapter.bundle/.../run.pl ... loop` processes
    /// whose parent is launchd (pid 1). One ps at launch; nothing afterwards.
    static func stopOrphanedHelpers() {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-x", "-o", "pid=,ppid=,command="]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let pid = Int32(f[0]), f[1] == "1" else { continue }
            let cmd = f[2]
            guard cmd.hasPrefix("/usr/bin/perl "), cmd.contains("MediaRemoteAdapter_MediaRemoteAdapter.bundle"),
                  cmd.contains("run.pl"), cmd.hasSuffix(" loop") else { continue }
            let st = kill(pid, SIGTERM)
            print("[MediaRemoteController] stopped an orphaned MediaRemoteAdapter helper, pid \(pid): \(st)")
        }
    }
    
}
