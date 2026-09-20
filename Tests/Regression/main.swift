import Foundation
struct SimpleConsole { let date: Date; let message: String }
let event = Date(timeIntervalSince1970: 100)
func stat(_ offset: Double, _ rate: Double) -> CMPlayerStats {
    CMPlayerStats(sampleRate: rate, bitDepth: 24, date: event.addingTimeInterval(offset), priority: 5)
}
func check(_ stats: [CMPlayerStats], _ expected: Double?, _ label: String) {
    precondition(RateSelection.candidate(stats, near: event)?.sampleRate == expected, label)
    print("PASS: \(label)")
}
check([stat(-4, 192000)], nil, "reject stale previous-track logs")
check([stat(4, 192000)], nil, "reject late next-track preload")
check([stat(1.8, 192000), stat(-0.1, 44100)], 44100, "prefer transition log over newer prefetch")
check([stat(-0.1, 44100), stat(1.8, 192000)], 44100, "selection independent of log ordering")
check([stat(0.8, 96000)], 96000, "accept delayed decoder log")
check([], nil, "missing logs do not invent fallback")
check([stat(0, 0)], nil, "reject invalid sample rate")
check([stat(0.5, 96000), stat(-0.5, 44100)], 44100, "tie prefers earlier log")

func entry(_ text: String, _ offset: Double = 0) -> SimpleConsole {
    SimpleConsole(date: event.addingTimeInterval(offset), message: text)
}
let prefix = "ACAppleLosslessDecoder.cpp Input format: "
let complete = entry(prefix + "2 ch, 96000 Hz, from 24-bit source")
let parsed = CMPlayerParser.parseCoreAudioConsoleLogs([complete])
precondition(parsed.count == 1 && parsed[0].sampleRate == 96000 && parsed[0].bitDepth == 24)
print("PASS: complete decoder line")
let incomplete = CMPlayerParser.parseCoreAudioConsoleLogs([
 entry(prefix + "2 ch, 192000 Hz"), entry(prefix + "from 16-bit source")])
precondition(incomplete.isEmpty)
print("PASS: never combine fields from different log entries")
let multiple = CMPlayerParser.parseCoreAudioConsoleLogs([
 entry(prefix + "2 ch, 192000 Hz, from 24-bit source", 1.8),
 entry(prefix + "2 ch, 44100 Hz, from 16-bit source", -0.1)])
precondition(multiple.count == 2)
precondition(RateSelection.candidate(multiple, near: event)?.sampleRate == 44100)
print("PASS: parse all candidates and reject newer prefetch")
