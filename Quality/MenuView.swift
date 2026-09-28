//
//  MenuView.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 23/6/25.
//

import SwiftUI

/// A menu-style MenuBarExtra is a native NSMenu: an Image(systemName: "checkmark") inside a Button's
/// label is not drawn there (on the Babyface bench, macOS 27, no option showed as selected). Toggles
/// get the menu's own check mark.
struct MenuView: View {
    
    @EnvironmentObject private var outputDevices: OutputDevices
    @EnvironmentObject private var defaults: Defaults
    @EnvironmentObject private var bitPerfectCheck: BitPerfectCheck
    @ObservedObject private var virtualOutput = VirtualOutputPlugin.shared
    @ObservedObject private var musicSettings = MusicSettingsCheck.shared
    
    var body: some View {
        VStack {
            if !musicSettings.problems.isEmpty {
                Text("Music settings: " + musicSettings.problems.map(\.what).joined(separator: "; "))
                Divider()
            }
            ContentView()
            
            Divider()

            Toggle("Exclusive Mode (Experimental)", isOn: $defaults.userPreferRendererEngine)

            Menu {
                Toggle("Default Device", isOn: Binding(get: { outputDevices.selectedOutputDevice == nil }, set: { on in
                    if on { outputDevices.selectedOutputDevice = nil; defaults.selectedDeviceUID = nil }
                }))

                ForEach(outputDevices.outputDevices, id: \.uid) { device in
                    Toggle(device.name, isOn: Binding(get: { outputDevices.selectedOutputDevice?.uid == device.uid }, set: { on in
                        if on { outputDevices.selectedOutputDevice = device; defaults.selectedDeviceUID = device.uid }
                    }))
                }
            } label: {
                Text("Selected Device")
            }

            Menu {
                ForEach(bitPerfectCheck.items) { item in
                    Text("\(item.ok == false ? "⚠︎" : item.ok == true ? "✓" : "?")  \(item.text)")
                }
                Divider()
                Button("Refresh") {
                    bitPerfectCheck.refresh()
                }
            } label: {
                Text(bitPerfectCheck.issueCount == 0 ? "Bit-Perfect Check" : "Bit-Perfect Check (\(bitPerfectCheck.issueCount) to review)")
            }

            // The optional settings. With Exclusive Mode on, Bit Depth Switching, Detect Local Files, Pause
            // While Switching and Gap After Switching do nothing (it always pauses and rewinds at a rate
            // change, for local files and streams, reads local files itself and takes the DAC's deepest
            // format), so they're hidden; they stay for the regular path. Exclusive Mode's own options show
            // only while it's on.
            Menu {
                Button {
                    defaults.userPreferIconStatusBarItem.toggle()
                } label: {
                    Text(defaults.statusBarItemTitle)
                }

                Toggle("Prefer Closest Sample Rate Multiple", isOn: $defaults.userPreferSampleRateMultiples)

                if defaults.userPreferRendererEngine {
                    Divider()
                    Toggle("Release DAC When Music Is Idle", isOn: $defaults.rendererReleaseWhenIdle)
                    Toggle("Inter-sample Overshoot Protection (-3.0 dB)", isOn: $defaults.overshootProtection)
                } else {
                    Toggle("Bit Depth Switching", isOn: $defaults.userPreferBitDepthDetection)
                    Toggle("Detect Local Files", isOn: $defaults.userPreferLocalFileDetection)
                    Toggle("Pause While Switching (Local Files)", isOn: $defaults.userPreferPauseWhileSwitching)
                    Menu {
                        ForEach(SwitchGap.allCases, id: \.self) { gap in
                            Toggle(gap.rawValue, isOn: Binding(get: { defaults.switchGap == gap }, set: { if $0 { defaults.switchGap = gap } }))
                        }
                    } label: {
                        Text("Gap After Switching")
                    }
                    .disabled(!defaults.userPreferPauseWhileSwitching)
                }

                Divider()

                Menu {
                    switch virtualOutput.state {
                    case .notInstalled:
                        Text("Not installed (Exclusive Mode uses a process tap, no hog mode)")
                        Button("Install…") { MenuBarController.shared.changeVirtualDevice(install: true) }
                    case .installed(let version):
                        Text("Installed (\(version))")
                        Button("Reinstall…") { MenuBarController.shared.changeVirtualDevice(install: true) }
                        Button("Remove…") { MenuBarController.shared.changeVirtualDevice(install: false) }
                    case .outdated(let installed, let bundled):
                        Text("Installed \(installed), this app has \(bundled)")
                        Button("Update…") { MenuBarController.shared.changeVirtualDevice(install: true) }
                        Button("Remove…") { MenuBarController.shared.changeVirtualDevice(install: false) }
                    }
                    if let error = virtualOutput.lastError {
                        Text("Last attempt failed: \(error)")
                    }
                } label: {
                    Text(virtualOutput.busy ? "Virtual Output Device (working…)" : "Virtual Output Device")
                }
                .disabled(virtualOutput.busy)

                Menu {
                    Button("Select Script...") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        panel.message = "Select a script that should be invoked when sample rate changes."

                        panel.begin { response in
                            let path = panel.url?.path
                            DispatchQueue.main.async { [weak defaults] in
                                defaults?.shellScriptPath = path
                            }
                        }
                    }

                    Button("Clear Selection") {
                        defaults.shellScriptPath = nil
                    }

                    Text(defaults.shellScriptPath ?? "No selection")

                } label: {
                    Text("Scripting")
                }
            } label: {
                Text("Advanced")
            }

            Menu {
                Text("Version - \(currentVersion)")
                Text("Build - \(currentBuild)")
            } label: {
                Text("About")
            }
            
            Button {
                NSApp.terminate(self)
            } label: {
                Text("Quit LosslessSwitcher")
            }
        }
    }
}
