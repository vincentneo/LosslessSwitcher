//
//  MenuView.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 23/6/25.
//

import SwiftUI

struct MenuView: View {
    
    @EnvironmentObject private var outputDevices: OutputDevices
    @EnvironmentObject private var defaults: Defaults
    
    var body: some View {
        VStack {
            ContentView()
            
            Divider()
            
            Button {
                defaults.userPreferIconStatusBarItem.toggle()
            } label: {
                Text(defaults.statusBarItemTitle)
            }
            
            Button {
                defaults.userPreferBitDepthDetection.toggle()
            } label: {
                HStack {
                    Text("Bit Depth Switching")
                    if defaults.userPreferBitDepthDetection {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Button {
                defaults.userPreferSampleRateMultiples.toggle()
            } label: {
                HStack {
                    Text("Prefer Closest Sample Rate Multiple")
                    if defaults.userPreferSampleRateMultiples {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Button {
                defaults.userPreferLocalFileDetection.toggle()
            } label: {
                HStack {
                    Text("Detect Local Files")
                    if defaults.userPreferLocalFileDetection {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Button {
                defaults.userPreferPauseWhileSwitching.toggle()
            } label: {
                HStack {
                    Text("Pause While Switching (Local Files)")
                    if defaults.userPreferPauseWhileSwitching {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Menu {
                ForEach(SwitchGap.allCases, id: \.self) { gap in
                    Button {
                        defaults.switchGap = gap
                    } label: {
                        Text(gap.rawValue)
                        if defaults.switchGap == gap {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            } label: {
                Text("Gap After Switching")
            }
            .disabled(!defaults.userPreferPauseWhileSwitching)
            
            Menu {
                Button {
                    outputDevices.selectedOutputDevice = nil
                    defaults.selectedDeviceUID = nil
                } label: {
                    if outputDevices.selectedOutputDevice == nil {
                        Image(systemName: "checkmark")
                    }
                    Text("Default Device")
                }

                ForEach(outputDevices.outputDevices, id: \.uid) { device in
                    Button {
                        outputDevices.selectedOutputDevice = device
                        defaults.selectedDeviceUID = device.uid
                    } label: {
                        Text(device.name)
                        if outputDevices.selectedOutputDevice?.uid == device.uid {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            } label: {
                Text("Selected Device")
            }
            
            Menu {
                Text("Version - \(currentVersion)")
                Text("Build - \(currentBuild)")
            } label: {
                Text("About")
            }
            
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
            
            Button {
                NSApp.terminate(self)
            } label: {
                Text("Quit LosslessSwitcher")
            }
        }
    }
}
