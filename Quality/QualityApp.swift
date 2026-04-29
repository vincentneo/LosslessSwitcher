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
    @State private var defaults = Defaults.shared
    
    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(appDelegate.outputDevices)
                .environmentObject(defaults)
        } label: {
            if defaults.userPreferIconStatusBarItem {
                Image(systemName: "music.note")
                    .padding(.horizontal, 8)
            }
            else {
                SampleRateLabel()
                    .environmentObject(appDelegate.outputDevices)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
