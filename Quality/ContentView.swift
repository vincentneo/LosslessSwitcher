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
    
    private var sampleRateText: String? {
        guard let currentSampleRate = outputDevices.currentSampleRate else { return nil }
        if outputDevices.enableBitDepthDetection {
            if let bitDepth = outputDevices.currentBitDepth {
                return String(format: "%.1f kHz / %d bit", currentSampleRate, bitDepth)
            } else {
                return String(format: "%.1f kHz / ? bit", currentSampleRate)
            }
        } else {
            return String(format: "%.1f kHz", currentSampleRate)
        }
    }
    
    var body: some View {
        VStack {
            if let text = sampleRateText {
                Text(text)
                    .font(.system(size: 23, weight: .semibold, design: .default))
            }
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


