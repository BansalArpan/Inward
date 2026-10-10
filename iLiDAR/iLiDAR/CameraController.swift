// ARKit-backed camera controller for the original iLiDAR UI and socket protocol.
// RGB, depth, intrinsics, pose, and timestamp come from the same ARFrame.

import Foundation
import ARKit
import Metal
import simd
import AVFoundation
import CoreImage
import Combine

protocol CaptureDataReceiver: AnyObject {
    func onNewData(capturedData: CameraCapturedData)
    func onNewPhotoData(capturedData: CameraCapturedData)
}

final class CameraCapturedData {
    var depth: MTLTexture?
    var colorY: MTLTexture?
    var colorCbCr: MTLTexture?
    var cameraIntrinsics: matrix_float3x3
    var cameraReferenceDimensions: CGSize

    init(depth: MTLTexture? = nil,
         colorY: MTLTexture? = nil,
         colorCbCr: MTLTexture? = nil,
         cameraIntrinsics: matrix_float3x3 = matrix_float3x3(),
         cameraReferenceDimensions: CGSize = .zero) {
        self.depth = depth
        self.colorY = colorY
        self.colorCbCr = colorCbCr
        self.cameraIntrinsics = cameraIntrinsics
        self.cameraReferenceDimensions = cameraReferenceDimensions
    }
}

final class CameraController: NSObject, ObservableObject, ARSessionDelegate {
    enum ConfigurationError: Error {
        case sceneDepthUnavailable
        case textureCacheCreationFailed
    }

    @Published var enableNetworkTransfer = false
    @Published var eventName = ""

    var transmissionFrequency = 4
    var isFilteringEnabled = false

    let session = ARSession()
    private let videoQueue = DispatchQueue(label: "com.ilidar.ARFrameQueue", qos: .userInteractive)
    private var textureCache: CVMetalTextureCache?
    private var configuration: ARWorldTrackingConfiguration?
    private var lastTransmissionTime: TimeInterval = -.infinity
    private var frameCounter = 0
    private var isConfigTransmitted = false
    weak var delegate: CaptureDataReceiver?

    override init() {
        super.init()
        var cache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil,
                                               MetalEnvironment.shared.metalDevice,
                                               nil, &cache)
        guard result == kCVReturnSuccess, let cache else {
            fatalError("Could not create the Metal texture cache.")
        }
        textureCache = cache
        session.delegate = self
        session.delegateQueue = videoQueue
        configureARSession()
    }

    private func configureARSession() {
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            fatalError("This iPhone does not support ARKit scene depth.")
        }
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics.insert(.sceneDepth)
        config.worldAlignment = .gravity
        configuration = config
    }

    func startStream() {
        guard let configuration else { return }
        session.run(configuration)
    }

    func stopStream() {
        session.pause()
    }

    func toggleNetworkTransfer() {
        if !enableNetworkTransfer {
            eventName = DataStorage.shared.eventName()
            frameCounter = 0
            lastTransmissionTime = -.infinity
            isConfigTransmitted = false
            print("A new record event begins: \(eventName)")
        }
        enableNetworkTransfer.toggle()
    }

    func capturePhoto() {
        guard let frame = session.currentFrame,
              let captured = makeCapturedData(frame) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.onNewPhotoData(capturedData: captured)
            self.stopStream()
        }
    }

    private func makeCapturedData(_ frame: ARFrame) -> CameraCapturedData? {
        guard let cache = textureCache else { return nil }
        let depthFrame = isFilteringEnabled ? (frame.smoothedSceneDepth ?? frame.sceneDepth) : frame.sceneDepth
        guard let depthBuffer = depthFrame?.depthMap else { return nil }

        let image = frame.capturedImage
        let depthTexture = depthBuffer.texture(withFormat: .r32Float, planeIndex: 0, addToCache: cache)
        let colorY = image.texture(withFormat: .r8Unorm, planeIndex: 0, addToCache: cache)
        let colorCbCr = image.texture(withFormat: .rg8Unorm, planeIndex: 1, addToCache: cache)
        guard let depthTexture, let colorY, let colorCbCr else { return nil }

        return CameraCapturedData(depth: depthTexture,
                                  colorY: colorY,
                                  colorCbCr: colorCbCr,
                                  cameraIntrinsics: frame.camera.intrinsics,
                                  cameraReferenceDimensions: frame.camera.imageResolution)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let captured = makeCapturedData(frame) else { return }
        delegate?.onNewData(capturedData: captured)

        guard enableNetworkTransfer,
              let depth = (isFilteringEnabled ? (frame.smoothedSceneDepth ?? frame.sceneDepth) : frame.sceneDepth)?.depthMap else {
            return
        }
        let interval = 1.0 / Double(max(transmissionFrequency, 1))
        guard frame.timestamp - lastTransmissionTime >= interval else { return }
        lastTransmissionTime = frame.timestamp
        frameCounter += 1

        let name = "\(eventName)_\(DataStorage.shared.frameName(frameCounter: frameCounter))"
        let poseCSV = poseCSV(for: frame)
        DataStorage.shared.transmitFrame(imageData: frame.capturedImage,
                                         depthData: depth,
                                         fileName: name,
                                         poseCSV: poseCSV)

        if !isConfigTransmitted {
            DataStorage.shared.transmitConfig(intrinsicMatrix: frame.camera.intrinsics,
                                              referenceDimensions: frame.camera.imageResolution,
                                              fileName: eventName)
            isConfigTransmitted = true
        }
    }

    private func poseCSV(for frame: ARFrame) -> String {
        let transform = frame.camera.transform
        let position = transform.columns.3
        let q = simd_quatf(transform)
        let tracking: String
        switch frame.camera.trackingState {
        case .normal: tracking = "normal"
        case .notAvailable: tracking = "not_available"
        case .limited(let reason): tracking = "limited_\(String(describing: reason))"
        }

        var fields = [
            String(format: "%.9f", frame.timestamp), tracking,
            String(format: "%.8f", position.x),
            String(format: "%.8f", position.y),
            String(format: "%.8f", position.z),
            String(format: "%.8f", q.imag.x),
            String(format: "%.8f", q.imag.y),
            String(format: "%.8f", q.imag.z),
            String(format: "%.8f", q.real)
        ]
        for row in 0..<4 {
            for column in 0..<4 {
                fields.append(String(format: "%.8f", transform[column][row]))
            }
        }
        let header = "timestamp_seconds,tracking_state,position_x_m,position_y_m,position_z_m,quaternion_x,quaternion_y,quaternion_z,quaternion_w," +
            (0..<4).flatMap { row in (0..<4).map { column in "camera_to_world_r\(row)c\(column)" } }.joined(separator: ",")
        return header + "\n" + fields.joined(separator: ",") + "\n"
    }
}
