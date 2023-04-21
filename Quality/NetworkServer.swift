//
//  NetworkServer.swift
//  LosslessSwitcherNetworkServer
//
//  Created by Kris Roberts on 4/7/23.
//

import Foundation
import Network
import SystemConfiguration
import CoreAudioTypes

class NetworkServer {
    var outputDevices: OutputDevices

    private let defaults = Defaults.shared
    private let hostName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Unknown"
    private var listener: NWListener?
    private var clientConnections: [NWConnection] = []
    
    init(_ outputDevices: OutputDevices) {
        self.outputDevices = outputDevices
    }
    
    func startListener() {
        let txtRecordData: [String: String] = ["serverHostName": hostName]
        let txtRecord = NWTXTRecord(txtRecordData)

        let tcpParameters = NWParameters.tcp
        let endpointPort = NWEndpoint.Port.any
        
        do {
            listener = try NWListener(using: tcpParameters, on: endpointPort)
        } catch {
            print("startListener: Failed to create listener: \(error) \(timeStamp())")
            return
        }
        
        listener?.service = NWListener.Service(name: "lossless-switcher", type: "_lossless-switcher._tcp", domain: "local", txtRecord: txtRecord)

        listener?.stateUpdateHandler = { newState in
            switch newState {
            case .ready:
                print("stateUpdateHandler: Listener ready \(self.timeStamp())")
            case .failed(let error):
                print("stateUpdateHandler: Listener failed with error: \(error) \(self.timeStamp())")
            default:
                break
            }
        }
        
        listener?.newConnectionHandler = { newConnection in
            newConnection.start(queue: .main)
            newConnection.stateUpdateHandler = { newState in
                // Check if the connection already exists in the array
                if !self.clientConnections.contains(where: { $0 === newConnection }) {
                    // Add the new connection to the clientConnections array if it doesn't already exist
                    //print("newConnection: Adding connection: \(newConnection.endpoint) \(self.timeStamp())")
                    self.clientConnections.append(newConnection)
                }
                switch newState {
                case .ready:
                    //print("newConnection: .ready: \(newConnection.state) \(newConnection.endpoint) \(self.timeStamp())")
                    self.receiveClientMessage(connection: newConnection)
                default:
                    //handle failre cases by closing connection?
                    //print("newConnection: default: \(newConnection.state) \(newConnection.endpoint) \(self.timeStamp())")
                    break
                }
            }
        }
        listener?.start(queue: .main)
    }
    
    func receiveClientMessage(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, error in
            if let data = data, data.count == 4 {
                let length = data.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
                print("receiveClientMessage: New request, length: \(length) bytes")
                self.receiveData(connection: connection, totalLength: Int(length), receivedLength: 0, receivedData: Data())
            } else if let error = error {
                print("Error receiving cient request length: \(error) \(self.timeStamp())")
            }
        }
    }
    
    func receiveData(connection: NWConnection, totalLength: Int, receivedLength: Int, receivedData: Data) {
        let remainingLength = totalLength - receivedLength
        let chunkSize = min(connection.maximumDatagramSize, remainingLength)

        connection.receive(minimumIncompleteLength: chunkSize, maximumLength: chunkSize) { data, _, _, error in
            if let data = data {
                let newReceivedData = receivedData + data
                let newReceivedLength = receivedLength + data.count

                if newReceivedLength == totalLength {
                    do {
                        let clientMessage = try JSONDecoder().decode(ClientMessage.self, from: newReceivedData)
                        print("receiveData: received/decoded: \(clientMessage.description)")
                        self.processClientMessage(clientMessage, connection: connection)
                    } catch {
                        print("Error decoding client message data: \(error) \(self.timeStamp())")
                    }
                } else {
                    // Keep receiving data until we have the complete message
                    self.receiveData(connection: connection, totalLength: totalLength, receivedLength: newReceivedLength, receivedData: newReceivedData)
                }
            } else if let error = error {
                print("Error receiving client message data: \(error) \(self.timeStamp())")
            }
        }
    }

    func processClientMessage(_ clientMessage: ClientMessage, connection: NWConnection) {
        switch clientMessage.request {
        case .refresh:
            self.sendServerResponse(self.getResponseData(), connection: connection)
            break
        case .toggleAutoSwitching:
            Task {
                await MainActor.run {
                    defaults.setPreferAutoSwitch(newValue: !defaults.userPreferAutoSwitch)
                    AppDelegate.instance.updateAutoSwitchingMenuItemState()
                }
            }
            break
        case .toggleBitDepthDetection:
            Task {
                await MainActor.run {
                    defaults.setPreferBitDepthDetection(newValue: !defaults.userPreferBitDepthDetection)
                    AppDelegate.instance.updateBitDepthDetectionMenuItemState()
                }
            }
            break
        case .setDeviceSampleRate(let asbdRate):
            let formatSampleRate = asbdRate.audioStreamBasicDescription
            outputDevices.manualSetFormat(formatSampleRate)
            break
        case .setDeviceBitDepth(let asbdBits):
            let formatBitDepth = asbdBits.audioStreamBasicDescription
            outputDevices.manualSetFormat(formatBitDepth)
            break
        case .setCurrentToDetected:
            outputDevices.setCurrentToDetected()
            break
        }
        
        // Call receiveClientMessage(connection:) again to continue listening for messages
        self.receiveClientMessage(connection: connection)
    }
    
    func getResponseData() -> ServerResponse {
        let response = ServerResponse(
            currentSampleRate: self.outputDevices.currentSampleRate ?? 1,
            currentBitDepth: self.outputDevices.currentBitDepth ?? 0,
            detectedSampleRate: self.outputDevices.detectedSampleRate ?? 1,
            detectedBitDepth: self.outputDevices.detectedBitDepth ?? 0,
            autoSwitchingEnabled: self.outputDevices.enableAutoSwitch,
            bitDepthDetectionEnabled: self.outputDevices.enableBitDepthDetection,
            sampleRatesForCurrentBitDepth: self.outputDevices.sampleRatesForCurrentBitDepth.map { CodableAudioStreamBasicDescription(from: $0)},
            bitDepthsForCurrentSampleRate: self.outputDevices.bitDepthsForCurrentSampleRate.map { CodableAudioStreamBasicDescription(from: $0)},
            defaultOutputDeviceName: self.outputDevices.defaultOutputDevice?.name ?? "Unknown Output Device",
            serverHostName: self.hostName,
            timeStamp: self.timeStamp()
        )
        return response
    }
    
    func timeStamp() -> String {
        let currentDate = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return dateFormatter.string(from: currentDate)
    }
    
    func cleanupInactiveConnections() {
        clientConnections.removeAll { connection in
            switch connection.state {
            case .failed(_):
                //print("Closing connection due to failure: \(connection.debugDescription)")
                connection.cancel()
                return true
            case .cancelled:
                //print("Closing connection due to cancellation: \(connection.debugDescription)")
                connection.cancel()
                return true
            default:
                //print("cleanupInactiveConnections: Leaving \(connection.state) - \(connection.endpoint)")
                return false
            }
        }
    }
    
    func updateClients() {
        // Call cleanupInactiveConnections to remove connections that are not in .ready state
        cleanupInactiveConnections()

        // Iterate through the client connections and send updates to any that are .ready
        for connection in clientConnections {
            if connection.state == .ready {
                //print("updateClients: About to send to: \(connection.endpoint) \(timeStamp())")
                sendServerResponse(getResponseData(), connection: connection)
            }
        }
    }
    
    func sendServerResponse(_ response: ServerResponse, connection: NWConnection) {
        do {
            let data = try JSONEncoder().encode(response)
            let dataLength = UInt32(data.count)
            let lengthData = withUnsafeBytes(of: dataLength.bigEndian) { Data($0) }
            let combinedData = lengthData + data
            connection.send(content: combinedData, completion: .contentProcessed({ error in
                if let error = error {
                    print("sendServerResponse: Error sending: \(error) \(self.timeStamp())")
                } else {
                    print("sendServerResponse: Sent - Data size: \(data.count) bytes, MTU: \(connection.maximumDatagramSize)")
                    print(" \(response.description)")
                }
            }))
        } catch {
            print("Error encoding ServerResponse: \(error)")
            print(response.description)
        }
    }
}

struct ServerResponse: Codable, CustomStringConvertible {
    let currentSampleRate: Float64
    let currentBitDepth: UInt32
    let detectedSampleRate: Float64
    let detectedBitDepth: UInt32
    let autoSwitchingEnabled: Bool
    let bitDepthDetectionEnabled: Bool
    let sampleRatesForCurrentBitDepth: [CodableAudioStreamBasicDescription]
    let bitDepthsForCurrentSampleRate: [CodableAudioStreamBasicDescription]
    let defaultOutputDeviceName: String
    let serverHostName: String
    let timeStamp: String
    
    var description: String {
        return "ServerResponse(currentSampleRate: \(currentSampleRate), detectedSampleRate: \(detectedSampleRate), autoSwitchingEnabled: \(autoSwitchingEnabled), serverHostName: \(serverHostName), defaultOutputDeviceName: \(defaultOutputDeviceName), timeStamp: \(timeStamp)\n SR4BD: \(sampleRatesForCurrentBitDepth)\n BD4SR: \(bitDepthsForCurrentSampleRate)"
    }
}

struct CodableAudioStreamBasicDescription: Codable, Equatable, CustomStringConvertible {
    let mSampleRate: Float64
    let mFormatID: UInt32
    let mFormatFlags: UInt32
    let mBytesPerPacket: UInt32
    let mFramesPerPacket: UInt32
    let mBytesPerFrame: UInt32
    let mChannelsPerFrame: UInt32
    let mBitsPerChannel: UInt32
    let mReserved: UInt32
    
    init(from audioStreamBasicDescription: AudioStreamBasicDescription) {
        mSampleRate = audioStreamBasicDescription.mSampleRate
        mFormatID = audioStreamBasicDescription.mFormatID
        mFormatFlags = audioStreamBasicDescription.mFormatFlags
        mBytesPerPacket = audioStreamBasicDescription.mBytesPerPacket
        mFramesPerPacket = audioStreamBasicDescription.mFramesPerPacket
        mBytesPerFrame = audioStreamBasicDescription.mBytesPerFrame
        mChannelsPerFrame = audioStreamBasicDescription.mChannelsPerFrame
        mBitsPerChannel = audioStreamBasicDescription.mBitsPerChannel
        mReserved = audioStreamBasicDescription.mReserved
    }
    
    static func ==(lhs: CodableAudioStreamBasicDescription, rhs: CodableAudioStreamBasicDescription) -> Bool {
        return lhs.mSampleRate == rhs.mSampleRate &&
               lhs.mFormatID == rhs.mFormatID &&
               lhs.mFormatFlags == rhs.mFormatFlags &&
               lhs.mBytesPerPacket == rhs.mBytesPerPacket &&
               lhs.mFramesPerPacket == rhs.mFramesPerPacket &&
               lhs.mBytesPerFrame == rhs.mBytesPerFrame &&
               lhs.mChannelsPerFrame == rhs.mChannelsPerFrame &&
               lhs.mBitsPerChannel == rhs.mBitsPerChannel &&
               lhs.mReserved == rhs.mReserved
    }
    
    var description: String {
        return String(format: "%.1fkHz/%dbit ", mSampleRate, mBitsPerChannel)
    }
}

extension CodableAudioStreamBasicDescription {
    var audioStreamBasicDescription: AudioStreamBasicDescription {
        return AudioStreamBasicDescription(
            mSampleRate: self.mSampleRate,
            mFormatID: self.mFormatID,
            mFormatFlags: self.mFormatFlags,
            mBytesPerPacket: self.mBytesPerPacket,
            mFramesPerPacket: self.mFramesPerPacket,
            mBytesPerFrame: self.mBytesPerFrame,
            mChannelsPerFrame: self.mChannelsPerFrame,
            mBitsPerChannel: self.mBitsPerChannel,
            mReserved: self.mReserved
        )
    }
}

enum ClientRequest: Codable, CustomStringConvertible {
    case refresh
    case toggleAutoSwitching
    case toggleBitDepthDetection
    case setDeviceSampleRate(CodableAudioStreamBasicDescription)
    case setDeviceBitDepth(CodableAudioStreamBasicDescription)
    case setCurrentToDetected
    
    var description: String {
        switch self {
        case .refresh:
            return "ClientRequest.refresh"
        case .toggleAutoSwitching:
            return "ClientRequest.toggleAutoSwitching"
        case .toggleBitDepthDetection:
            return "ClientRequest.toggleBitDepthDetection"
        case .setDeviceSampleRate(let asbdRate):
            return "ClientRequest.setDeviceSampleRate(\(asbdRate.mSampleRate))"
        case .setDeviceBitDepth(let asbdBits):
            return "ClientRequest.setDeviceBitDepth(\(asbdBits.mBitsPerChannel))"
        case .setCurrentToDetected:
            return "ClientRequest.setCurentToDetected"
        }
    }
    
    private enum CodingKeys: CodingKey {
        case type
        case sampleRate
        case bitDepth
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        
        switch type {
        case "refresh":
            self = .refresh
        case "toggleAutoSwitching":
            self = .toggleAutoSwitching
        case "toggleBitDepthDetection":
            self = .toggleBitDepthDetection
        case "setDeviceSampleRate":
            let asbdRate = try container.decode(CodableAudioStreamBasicDescription.self, forKey: .sampleRate)
            self = .setDeviceSampleRate(asbdRate)
        case "setDeviceBitDepth":
            let asbdBits = try container.decode(CodableAudioStreamBasicDescription.self, forKey: .bitDepth)
            self = .setDeviceBitDepth(asbdBits)
        case "setCurrentToDetected":
            self = .setCurrentToDetected
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid request type")
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .refresh:
            try container.encode("refresh", forKey: .type)
        case .toggleAutoSwitching:
            try container.encode("toggleAutoSwitching", forKey: .type)
        case .toggleBitDepthDetection:
            try container.encode("toggleBitDepthDetection", forKey: .type)
        case .setDeviceSampleRate(let asbdRate):
            try container.encode("setDeviceSampleRate", forKey: .type)
            try container.encode(asbdRate, forKey: .sampleRate)
        case .setDeviceBitDepth(let asbdBits):
            try container.encode("setDeviceBitDepth", forKey: .type)
            try container.encode(asbdBits, forKey: .bitDepth)
        case .setCurrentToDetected:
            try container.encode("setCurrentToDetected", forKey: .type)
        }
    }
}

struct ClientMessage: Codable, CustomStringConvertible {
    let request: ClientRequest
    let timeStamp: String
    
    var description: String {
        return "ClientMessage(request: \(request)), timeStamp: \(timeStamp)"
    }
}
