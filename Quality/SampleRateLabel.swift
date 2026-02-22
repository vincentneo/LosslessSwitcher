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
            let formattedSampleRate = String(format: "%.1f kHz", currentSampleRate)
            Text(formattedSampleRate)
        }
        else {
            Text("Unknown")
        }
    }
}
