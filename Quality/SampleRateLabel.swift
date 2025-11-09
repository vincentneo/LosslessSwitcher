//
//  SampleRateLabel.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 23/6/25.
//

import SwiftUI

struct SampleRateLabel: View {
    @EnvironmentObject private var outputDevices: OutputDevices
    var body: some View {
        if let currentSampleRate = outputDevices.currentSampleRate {
            if outputDevices.enableBitDepthDetection {
                if let bitDepth = outputDevices.currentBitDepth {
                    Text(String(format: "%.1f kHz / %d bit", currentSampleRate, bitDepth))
                } else {
                    Text(String(format: "%.1f kHz / ? bit", currentSampleRate))
                }
            } else {
                Text(String(format: "%.1f kHz", currentSampleRate))
            }
        } else {
            Text("Unknown")
        }
    }
}
