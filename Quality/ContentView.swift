//
//  ContentView.swift
//  Quality
//
//  Created by Vincent Neo on 18/4/22.
//

import SwiftUI
import OSLog
import SimplyCoreAudio

struct ContentView: View {
    @EnvironmentObject var outputDevices: OutputDevices
    
    private var formattedCurrentSettings: String {
        let currentSampleRate = outputDevices.currentSampleRate ?? 1
        let currentBitDepth = outputDevices.currentBitDepth ?? 0
        return  "C: \(outputDevices.kHzString(currentSampleRate))kHz \(currentBitDepth)bit"
    }
    
    private var formattedDetectedSettings: String {
        let detectedSampleRate = outputDevices.detectedSampleRate ?? 1
        let detectedBitDepth = outputDevices.detectedBitDepth ?? 0
        var formattedSettings = "D: \(outputDevices.kHzString(detectedSampleRate))kHz"
        if outputDevices.enableBitDepthDetection {
            formattedSettings += " \(detectedBitDepth)bit"
        }
        return formattedSettings
    }
    
    var body: some View {
        VStack {
            Text(formattedCurrentSettings)
                .font(.system(size: 23, weight: .semibold, design: .default))
                .lineLimit(1)
            Text(formattedDetectedSettings)
                .font(.system(size: 23, weight: .semibold, design: .default))
                .lineLimit(1)
            if let device = outputDevices.selectedOutputDevice ?? outputDevices.defaultOutputDevice {
                Text(device.name)
                    .font(.system(size: 14.5, weight: .regular, design: .default))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}


