//
//  MenuView.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 23/6/25.
//

import SwiftUI
import SimplyCoreAudio

struct MenuView: View {

    @EnvironmentObject private var outputDevices: OutputDevices
    @EnvironmentObject private var defaults: Defaults

    var body: some View {
        // 1. What's happening right now
        Section {
            Text(currentFormatText)
            Text(currentDeviceText)
        }

        Divider()

        // 2. Which device to control
        Picker(selection: deviceSelection) {
            Text(systemDefaultTitle).tag(String?.none)
            Divider()
            ForEach(namedDevices, id: \.uid) { device in
                Text(device.name).tag(device.uid)
            }
        } label: {
            Label("Output Device", systemImage: "hifispeaker")
        }
        .pickerStyle(.menu)

        Divider()

        // 3. How switching behaves
        Section("Switching") {
            Toggle("Match Bit Depth", isOn: $defaults.userPreferBitDepthDetection)
            Toggle("Prefer Sample Rate Multiples", isOn: $defaults.userPreferSampleRateMultiples)
        }

        Divider()

        // 4. Appearance & automation
        Picker(selection: $defaults.userPreferIconStatusBarItem) {
            Text("Icon").tag(true)
            Text("Sample Rate").tag(false)
        } label: {
            Label("Menu Bar Shows", systemImage: "menubar.rectangle")
        }
        .pickerStyle(.menu)

        scriptMenu

        Divider()

        // 5. App
        Text("LosslessSwitcher \(currentVersion) (\(currentBuild))")
        Button("Quit LosslessSwitcher") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    // MARK: - Status

    private var currentFormatText: String {
        guard let rate = outputDevices.currentSampleRate else { return "No format detected yet" }
        let rateText = String(format: "%.1f kHz", rate)
        if outputDevices.enableBitDepthDetection, let bitDepth = outputDevices.currentBitDepth {
            return "\(rateText) · \(bitDepth)-bit"
        }
        return rateText
    }

    private var currentDeviceText: String {
        guard let device = outputDevices.selectedOutputDevice ?? outputDevices.defaultOutputDevice else {
            return "No output device"
        }
        return "on \(device.name)"
    }

    // MARK: - Device selection

    private var namedDevices: [AudioDevice] {
        outputDevices.outputDevices.filter { $0.uid != nil }
    }

    private var systemDefaultTitle: String {
        if let name = outputDevices.defaultOutputDevice?.name {
            return "System Default (\(name))"
        }
        return "System Default"
    }

    private var deviceSelection: Binding<String?> {
        Binding(
            get: { outputDevices.selectedOutputDevice?.uid },
            set: { uid in
                let device = uid.flatMap { uid in outputDevices.outputDevices.first(where: { $0.uid == uid }) }
                outputDevices.select(device: device)
            }
        )
    }

    // MARK: - Script

    @ViewBuilder
    private var scriptMenu: some View {
        Menu {
            if let path = defaults.shellScriptPath {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                Divider()
                Button("Choose Different Script…", action: chooseScript)
                Button("Remove Script") {
                    defaults.shellScriptPath = nil
                }
            }
            else {
                Button("Choose Script…", action: chooseScript)
                Divider()
                Text("Called with sample rate (Hz) and bit depth")
            }
        } label: {
            Label("Run Script on Change",
                  systemImage: "terminal")
        }
    }

    private func chooseScript() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a script to run whenever the sample rate changes."
        panel.prompt = "Use Script"
        // Menu bar apps aren't active by default; bring the panel to the front.
        NSApp.activate()

        panel.begin { response in
            guard response == .OK, let path = panel.url?.path else { return }
            DispatchQueue.main.async { [weak defaults] in
                defaults?.shellScriptPath = path
            }
        }
    }
}
