//
//  LogStreamMonitor.swift
//  LosslessSwitcher
//
//  Streams Music's Apple Lossless decoder log lines live via `log stream`,
//  so a new track's format is known the moment Music opens its decoder,
//  instead of polling OSLogStore after a fixed delay.
//

import Foundation

final class LogStreamMonitor {

    /// Called on an arbitrary background queue for every decoder format line seen.
    var onFormat: ((CMPlayerStats) -> Void)?

    private var isRunning = false

    /// Whether a `log stream` process is currently alive and feeding us.
    var isActive: Bool { queue.sync { isRunning } }

    private var process: Process?
    /// Write end of the child's stdin. Closing it (or this app exiting for any reason,
    /// including a crash) makes the wrapper kill `log stream`, so it never outlives us.
    private var lifeline: Pipe?
    private var buffer = Data()
    private var stopped = true
    private var restartDelay: TimeInterval = 1
    private let queue = DispatchQueue(label: "LogStreamMonitor", qos: .userInteractive)

    private static let predicate =
        #"process == "Music" AND subsystem == "com.apple.coreaudio" AND eventMessage CONTAINS "ACAppleLosslessDecoder" AND eventMessage CONTAINS "Input format""#

    func start() {
        queue.async {
            self.stopped = false
            self.launch()
        }
    }

    func stop() {
        queue.sync {
            self.stopped = true
            try? self.lifeline?.fileHandleForWriting.close()
            self.lifeline = nil
            self.process?.terminate()
            self.process = nil
            self.isRunning = false
        }
    }

    private func launch() {
        guard !stopped, process == nil else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Run `log stream` alongside a watcher that kills it once our stdin pipe closes,
        // which happens automatically when this app quits, crashes or is force-killed.
        process.arguments = [
            "-c",
            #"exec 3<&0; /usr/bin/log "$@" </dev/null & p=$!; (cat <&3 >/dev/null; kill $p 2>/dev/null) & wait $p"#,
            "sh", "stream", "--style", "ndjson", "--predicate", Self.predicate,
        ]

        let lifeline = Pipe()
        process.standardInput = lifeline
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.queue.async { self.consume(data) }
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            pipe.fileHandleForReading.readabilityHandler = nil
            self.queue.async {
                print("[LogStreamMonitor] log stream exited (\(proc.terminationStatus))")
                try? lifeline.fileHandleForWriting.close() // release the watcher
                if self.lifeline === lifeline { self.lifeline = nil }
                self.process = nil
                self.isRunning = false
                guard !self.stopped else { return }
                // Back off so a persistently failing `log` doesn't spin.
                let delay = self.restartDelay
                self.restartDelay = min(self.restartDelay * 2, 30)
                self.queue.asyncAfter(deadline: .now() + delay) { self.launch() }
            }
        }

        do {
            try process.run()
            self.process = process
            self.lifeline = lifeline
            self.isRunning = true
            self.buffer.removeAll()
        }
        catch {
            print("[LogStreamMonitor] failed to start: \(error)")
            self.isRunning = false
        }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: Data(line))
        }
    }

    private func handle(line: Data) {
        // The first line is a plain-text "Filtering the log data..." banner; skip non-JSON.
        guard line.first == UInt8(ascii: "{"),
              let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = json["eventMessage"] as? String,
              let format = CMPlayerParser.parseAppleLosslessInputFormat(message)
        else { return }

        restartDelay = 1 // healthy stream
        let stat = CMPlayerStats(sampleRate: format.sampleRate, bitDepth: format.bitDepth, date: Date(), priority: 5)
        print("[LogStreamMonitor] live stat \(stat)")
        onFormat?(stat)
    }
}
