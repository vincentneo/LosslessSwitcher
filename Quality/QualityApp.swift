//
//  QualityApp.swift
//  Quality
//
//  Created by Vincent Neo on 18/4/22.
//

import SwiftUI

@main
struct QualityApp: App {
    
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    @State private var controller = MenuBarController()
    @ObservedObject private var defaults = Defaults.shared
    
    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(controller.outputDevices)
                .environmentObject(defaults)
        } label: {
            if defaults.userPreferIconStatusBarItem {
                Image(systemName: "music.note")
                    .padding(.horizontal, 8)
            }
            else {
                SampleRateLabel()
                    .environmentObject(controller.outputDevices)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

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
            
            Menu {
                Button {
                    outputDevices.selectedOutputDevice = nil
                    defaults.selectedDeviceUID = nil
                } label: {
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
                
            } label: {
                Text("")
            }
            
            Menu {
                Text("Version - \(currentVersion)")
                Text("Build - \(currentBuild)")
            } label: {
                Text("About")
            }
        }
    }
}

