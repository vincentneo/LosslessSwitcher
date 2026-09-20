# Decoder selection regression tests

Run `bash Tests/Regression/run.sh /path/to/Sweep/Sources/Sweep/Sweep.swift` on macOS with Xcode selected. Use the Sweep checkout resolved by the existing Xcode project. The runner builds the production parser and selection policy, uses a temporary directory, and does not change audio devices or play music.

Covers stale logs, late preloads, log ordering, delayed decoder lines, missing/invalid data, deterministic ties, independent per-line parsing, and multiple candidate selection. These tests do not verify real Music event timing or hardware switching. The transition window remains a heuristic because decoder logs have no reliable public track identifier.
