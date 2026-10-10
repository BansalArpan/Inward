//
//  SocketManager.swift
//  iLiDAR
//
//  Created by Bo Liang on 2024/12/8.
//



import Foundation

enum DataType: UInt8 {
    case jpg = 0x01
    case bin = 0x02
    case csv = 0x03
}

/*
 Data packet: [Header][Payload]
 
 In [Header]:
 [Filename length] 1 byte UInt8
 [Filename] Variable length
 [Data type] 1 byte UInt8
 [Data size] 4 bytes UInt32 big-endian
 [Sequence number] 4 bytes UInt32 big-endian
 [Is last chunk] 1 byte UInt8
 
 In [Payload] is Binary data
 */

struct DataPacket {
    let dataType: DataType
    let fileName: String
    let data: Data
    let sequenceNumber: UInt32
    let isLast: Bool
    
    func toData() -> Data {
        var packet = Data()
        
        if let fileNameData = fileName.data(using: .utf8) {
            let fileNameLength = UInt8(fileName.count)
            packet.append(fileNameLength)
            packet.append(fileNameData)
        } else {
            packet.append(UInt8(0)) // fail to encode fileName, send length 0
        }
        
        packet.append(dataType.rawValue)
        
        var dataSize = UInt32(data.count).bigEndian
        packet.append(Data(bytes: &dataSize, count: 4))
        
        var seqNum = sequenceNumber.bigEndian
        packet.append(Data(bytes: &seqNum, count: 4))
        
        if isLast {
            packet.append(UInt8(1))
        } else {
            packet.append(UInt8(0))
        }        
        
        packet.append(data)
        return packet
    }
}


class SocketManager {
    let socketHandler = CocoaAsyncSocketHandler()

    init() {
        // Configure response handling closure
        socketHandler.getResponseBlock = { response in
            print("Received server response: \(response)")
        }
    }
    
    func connectToServer(host_ip: String, port: Int, completion: @escaping (Bool) -> Void) {
        // Set the completion block on the Objective-C side
        socketHandler.connectionCallback = { success in
            DispatchQueue.main.async {
                completion(success)
            }
        }
        
        socketHandler.setupSocketHost(host_ip, port: port)
    }
    
    func disconnect() {
        socketHandler.disconnect()
    }
    
    func sendData(dataType: DataType, fileName: String, data: Data, chunkSize: Int = 1024) {
        let totalSize = data.count
        var offset = 0
        var sequenceNumber: UInt32 = 0
        
        while offset < totalSize {
            let thisChunkSize = min(chunkSize, totalSize - offset)
            let chunk = data.subdata(in: offset..<offset + thisChunkSize)
            let isLast = (offset + thisChunkSize) >= totalSize
            let packet = DataPacket (dataType: dataType, fileName: fileName, data: chunk, sequenceNumber: sequenceNumber, isLast: isLast)
            let packetData = packet.toData()
            socketHandler.sendMyData(packetData)
            offset += thisChunkSize
            sequenceNumber += 1
        }
        
    }
    
    func sendJPG(fileName: String, data: Data, chunkSize: Int = 1024) {
        sendData(dataType: .jpg, fileName: fileName, data: data, chunkSize: chunkSize)
    }
    
    func sendBIN(fileName: String, data: Data, chunkSize: Int = 1024) {
        sendData(dataType: .bin, fileName: fileName, data: data, chunkSize: chunkSize)
    }
    
    func sendCSV(fileName: String, data: Data, chunkSize: Int = 1024) {
        sendData(dataType: .csv, fileName: fileName, data: data, chunkSize: chunkSize)
    }
    
    // MARK: - Real-time Visualization Support
    
    func sendRawData(_ data: Data) {
        // Send raw data without packet structure for real-time visualization
        socketHandler.sendMyData(data)
    }
}

// ARKit streaming uses a versioned, whole-frame protocol on TCP port 5678.
// The original SocketManager above remains for source compatibility only.
import Network

final class ARFrameStreamClient {
    private var connection: NWConnection?
    private var timeout: DispatchWorkItem?
    private var pending: ((Result<Void, Error>) -> Void)?
    private(set) var connected = false
    var onState: ((Bool, String) -> Void)?

    private func error(_ text: String) -> NSError {
        NSError(domain: "ARFrameStream", code: 1,
                userInfo: [NSLocalizedDescriptionKey: text])
    }

    func connect(host: String, port: UInt16 = 5678) {
        disconnect()
        let c = NWConnection(host: NWEndpoint.Host(host),
                             port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection = c
        onState?(false, "Connecting…")
        armTimeout(c, seconds: 10, message: "Connection timed out. Check IP, server and firewall.")
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self = self, let c = c, self.connection === c else { return }
            switch state {
            case .ready:
                // Server greeting prevents streaming into an old receiver.
                self.readExactly(c, count: 4) { result in
                    guard self.connection === c else { return }
                    switch result {
                    case .success(let bytes):
                        guard bytes == Data("ILD2".utf8) else {
                            self.fail("Receiver protocol mismatch. Use the new ios_driver.py.")
                            return
                        }
                        self.timeout?.cancel()
                        self.connected = true
                        self.onState?(true, "Connected to receiver")
                    case .failure(let e): self.fail(e.localizedDescription)
                    }
                }
            case .failed(let e): self.fail(e.localizedDescription)
            case .waiting(let e): self.fail(e.localizedDescription)
            default: break
            }
        }
        c.start(queue: .main)
    }

    func disconnect() {
        timeout?.cancel()
        timeout = nil
        let old = connection
        connection = nil
        connected = false
        old?.stateUpdateHandler = nil
        old?.cancel()
        let callback = pending
        pending = nil
        callback?(.failure(error("Disconnected; last frame may or may not have reached the computer.")))
        onState?(false, "Disconnected")
    }

    private func fail(_ message: String) {
        disconnect()
        onState?(false, message)
    }

    private func armTimeout(_ c: NWConnection, seconds: Double, message: String) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self, weak c] in
            guard let self = self, let c = c, self.connection === c else { return }
            self.fail(message)
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func readExactly(_ c: NWConnection, count: Int, accumulated: Data = Data(),
                             completion: @escaping (Result<Data, Error>) -> Void) {
        c.receive(minimumIncompleteLength: 1, maximumLength: count - accumulated.count) {
            [weak self] bytes, _, complete, failure in
            guard let self = self, self.connection === c else { return }
            if let failure = failure { completion(.failure(failure)); return }
            var result = accumulated
            if let bytes = bytes { result.append(bytes) }
            if result.count == count { completion(.success(result)); return }
            if complete { completion(.failure(self.error("Receiver closed the connection."))); return }
            self.readExactly(c, count: count, accumulated: result, completion: completion)
        }
    }

    // Call on main queue. Exactly one complete frame can be in flight.
    func sendFrame(json: Data, rgb: Data, depth: Data, confidence: Data?,
                   completion: @escaping (Result<Void, Error>) -> Void) {
        guard connected, let c = connection, pending == nil else {
            completion(.failure(error("Not connected or a frame is already pending.")))
            return
        }
        let blocks = [json, rgb, depth, confidence ?? Data()]
        let limits = [65536, 16 * 1024 * 1024, 4 * 1024 * 1024, 1024 * 1024]
        guard zip(blocks, limits).allSatisfy({ $0.0.count <= $0.1 }) else {
            completion(.failure(error("Frame exceeds protocol size limits.")))
            return
        }
        var packet = Data("ILD2".utf8)
        for block in blocks {
            var length = UInt32(block.count).bigEndian
            withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
        }
        for block in blocks { packet.append(block) }
        pending = completion
        armTimeout(c, seconds: 15, message: "Frame acknowledgment timed out. Reconnect to continue.")
        c.send(content: packet, completion: .contentProcessed { [weak self] failure in
            guard let self = self, self.connection === c else { return }
            if let failure = failure { self.fail(failure.localizedDescription); return }
            self.readExactly(c, count: 1) { result in
                guard self.connection === c else { return }
                switch result {
                case .success(let ack):
                    guard ack.first == 0x06 else {
                        self.fail("Receiver rejected the frame. Check its terminal.")
                        return
                    }
                    self.timeout?.cancel()
                    self.timeout = nil
                    let callback = self.pending
                    self.pending = nil
                    callback?(.success(()))
                case .failure(let e): self.fail(e.localizedDescription)
                }
            }
        })
    }
}
