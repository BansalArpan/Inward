import Foundation
import AVFoundation
import UIKit
import simd

final class DataStorage {
    static let shared = DataStorage()
    let socketManager = SocketManager()
    let compressionQuality: CGFloat = 0.4
    var readyToSend = false
    private(set) var currentHostIP = "10.129.164.22"
    private(set) var currentPort = 5678
    private let imageContext = CIContext(options: [.useSoftwareRenderer: false])

    private init() {
        socketManager.connectToServer(host_ip: currentHostIP, port: currentPort) { [weak self] success in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.readyToSend = success
                print(success ? "Initial connection established, ready to send." : "Initial connection failed.")
            }
        }
    }

    func disconnect() {
        socketManager.disconnect()
        readyToSend = false
    }

    func updateConnection(host_ip: String, port: Int, completion: @escaping (Bool) -> Void) {
        socketManager.disconnect()
        readyToSend = false
        currentHostIP = host_ip
        currentPort = port
        var finished = false
        let timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            guard let self, !finished else { return }
            finished = true
            self.readyToSend = false
            completion(false)
        }
        socketManager.connectToServer(host_ip: host_ip, port: port) { [weak self] success in
            DispatchQueue.main.async {
                guard let self, !finished else { return }
                finished = true
                timer.invalidate()
                self.readyToSend = success
                completion(success)
            }
        }
    }

    // ARKit sceneDepth is Float32. The original receiver expects tightly packed Float16.
    func convertDepthData(depthData: CVPixelBuffer) -> Data? {
        guard CVPixelBufferLockBaseAddress(depthData, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(depthData, .readOnly) }
        let width = CVPixelBufferGetWidth(depthData)
        let height = CVPixelBufferGetHeight(depthData)
        let stride = CVPixelBufferGetBytesPerRow(depthData)
        let format = CVPixelBufferGetPixelFormatType(depthData)
        guard let base = CVPixelBufferGetBaseAddress(depthData) else { return nil }
        var output = Data()
        output.reserveCapacity(width * height * MemoryLayout<Float16>.size)

        for row in 0..<height {
            if format == kCVPixelFormatType_DepthFloat16 {
                let source = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
                output.append(source, count: width * 2)
            } else if format == kCVPixelFormatType_DepthFloat32 {
                let source = base.advanced(by: row * stride).assumingMemoryBound(to: Float.self)
                for column in 0..<width {
                    var bits = Float16(source[column]).bitPattern.littleEndian
                    withUnsafeBytes(of: &bits) { output.append(contentsOf: $0) }
                }
            } else {
                print("Unsupported depth pixel format: \(format)")
                return nil
            }
        }
        return output
    }

    // Called on the ARSession delegate queue. Convert buffers before returning so ARKit
    // does not have to retain a backlog of ARFrames while a background queue encodes them.
    func transmitFrame(imageData: CVImageBuffer, depthData: CVPixelBuffer,
                       fileName: String, poseCSV: String) {
        guard readyToSend else {
            print("Not connected; skipped frame \(fileName).")
            return
        }
        let image = CIImage(cvImageBuffer: imageData)
        guard let cgImage = imageContext.createCGImage(image, from: image.extent),
              let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: compressionQuality),
              let depth = convertDepthData(depthData: depthData),
              let pose = poseCSV.data(using: .utf8) else {
            print("Could not encode frame \(fileName).")
            return
        }

        socketManager.sendBIN(fileName: fileName + ".bin", data: depth)
        socketManager.sendJPG(fileName: fileName + ".jpg", data: jpeg)
        socketManager.sendCSV(fileName: fileName + ".csv", data: pose)
    }

    func transmitConfig(intrinsicMatrix: matrix_float3x3,
                        referenceDimensions: CGSize, fileName: String) {
        guard readyToSend else { return }
        let fx = intrinsicMatrix.columns.0.x
        let fy = intrinsicMatrix.columns.1.y
        let cx = intrinsicMatrix.columns.2.x
        let cy = intrinsicMatrix.columns.2.y
        let csv = "fx,fy,cx,cy,image_width,image_height\n\(fx),\(fy),\(cx),\(cy),\(Int(referenceDimensions.width)),\(Int(referenceDimensions.height))\n"
        guard let data = csv.data(using: .utf8) else { return }
        socketManager.sendCSV(fileName: fileName + "_camera.csv", data: data)
    }

    func transmitDepthForVisualization(depthData: CVPixelBuffer) {
        guard readyToSend, let raw = convertDepthData(depthData: depthData) else { return }
        var packet = Data()
        var size = UInt32(raw.count).bigEndian
        withUnsafeBytes(of: &size) { packet.append(contentsOf: $0) }
        packet.append(raw)
        socketManager.sendRawData(packet)
    }

    func frameName(frameCounter: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss_SS"
        return formatter.string(from: Date()) + "_frame" + String(format: "%08d", frameCounter)
    }

    func eventName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}
