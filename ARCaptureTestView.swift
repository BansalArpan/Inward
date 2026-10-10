import SwiftUI
import ARKit
import SceneKit
import Combine
import CoreImage
import UIKit
import simd

private func captureError(_ message: String) -> NSError {
    NSError(
        domain: "iLiDARCapture",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}

// Copies a nonplanar buffer without copying row padding.
private func packedData(
    _ buffer: CVPixelBuffer,
    expectedFormat: OSType,
    bytesPerPixel: Int
) throws -> Data {
    guard CVPixelBufferGetPixelFormatType(buffer) == expectedFormat else {
        throw captureError("Unexpected pixel format.")
    }

    guard !CVPixelBufferIsPlanar(buffer) else {
        throw captureError("Expected a nonplanar buffer.")
    }

    guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
        throw captureError("Could not lock pixel buffer.")
    }

    defer {
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
    }

    guard let base = CVPixelBufferGetBaseAddress(buffer) else {
        throw captureError("Pixel buffer has no base address.")
    }

    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let rowSize = width * bytesPerPixel

    guard stride >= rowSize else {
        throw captureError("Invalid pixel-buffer row size.")
    }

    var result = Data(capacity: rowSize * height)

    for row in 0..<height {
        result.append(
            base.advanced(by: row * stride)
                .assumingMemoryBound(to: UInt8.self),
            count: rowSize
        )
    }

    return result
}

final class ARCaptureTestController: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()

    @Published var status = "Starting ARKit…"
    @Published var message = "Enter your computer's local IP address."
    @Published var host = ""
    @Published var connected = false
    private let stream = ARFrameStreamClient()
    private var connectionGeneration = 0
    private var sessionRunning = false
    private let worldSessionID = UUID().uuidString
    @Published var recording = false
    @Published var busy = false
    @Published var savedFrames = 0
    @Published var droppedFrames = 0

    private let writer = DispatchQueue(label: "iLiDAR.frameWriter")
    private let imageContext = CIContext()

    private var recordingID = ""
    private var frameID = 0
    private var firstTimestamp: TimeInterval?
    private var lastCaptureTime: TimeInterval = -.infinity
    private var lastDisplayTime: TimeInterval = -.infinity

    private let captureInterval: TimeInterval = 0.25

    override init() {
        super.init()
        session.delegate = self

        // Controller state is accessed on the main queue.
        session.delegateQueue = .main
        stream.onState = { [weak self] ready, text in
            guard let self = self else { return }
            self.connected = ready
            if !ready {
                self.recording = false
                UIApplication.shared.isIdleTimerDisabled = false
            }
            self.message = text
        }
    }

    func connect() {
        guard !busy else { return }
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { message = "Enter the computer's IP address."; return }
        connectionGeneration += 1
        stream.connect(host: address)
    }

    func disconnect() {
        stopRecording()
        connectionGeneration += 1
        stream.disconnect()
    }

    func startSession() {
        guard !sessionRunning else { return }
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            message = "This device does not support scene depth."
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics = [.sceneDepth]
        configuration.worldAlignment = .gravity
        session.run(configuration)
        sessionRunning = true
    }

    func pauseSession() {
        disconnect()
        session.pause()
        sessionRunning = false
    }

    func startRecording() {
        guard connected, !recording, !busy else { return }

        // Begin each recording only after tracking has initialized.
        guard let frame = session.currentFrame,
              frame.sceneDepth != nil else {
            message = "Wait for camera and depth data."
            return
        }

        guard case .normal = frame.camera.trackingState else {
            message = "Wait until tracking is Normal."
            return
        }

        recordingID = UUID().uuidString
        frameID = 0
        savedFrames = 0
        droppedFrames = 0
        firstTimestamp = nil
        lastCaptureTime = -.infinity
        recording = true
        UIApplication.shared.isIdleTimerDisabled = true
        message = "Streaming to computer: \(recordingID)"
    }

    func stopRecording() {
        guard recording else { return }
        recording = false
        UIApplication.shared.isIdleTimerDisabled = false
        message = busy ? "Waiting for last server acknowledgment…" : "Computer confirmed \(savedFrames) frames."
    }

    private func trackingInfo(
        _ state: ARCamera.TrackingState
    ) -> (name: String, reason: String) {
        switch state {
        case .normal:
            return ("normal", "")
        case .notAvailable:
            return ("unavailable", "")
        case .limited(let reason):
            switch reason {
            case .initializing:
                return ("limited", "initializing")
            case .excessiveMotion:
                return ("limited", "excessive_motion")
            case .insufficientFeatures:
                return ("limited", "insufficient_features")
            case .relocalizing:
                return ("limited", "relocalizing")
            @unknown default:
                return ("limited", "unknown")
            }
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let tracking = trackingInfo(frame.camera.trackingState)
        let transform = frame.camera.transform
        let position = transform.columns.3

        if frame.timestamp - lastDisplayTime >= 0.25 {
            lastDisplayTime = frame.timestamp
            status = """
            Tracking: \(tracking.name) \(tracking.reason)
            X: \(String(format: "%.3f", position.x)) m
            Y: \(String(format: "%.3f", position.y)) m
            Z: \(String(format: "%.3f", position.z)) m
            Depth: \(frame.sceneDepth == nil ? "Waiting" : "Available")
            """
        }

        guard recording,
              connected,
              frame.timestamp - lastCaptureTime >= captureInterval else {
            return
        }

        lastCaptureTime = frame.timestamp

        // Never build an unlimited queue of retained camera buffers.
        guard !busy, let sceneDepth = frame.sceneDepth else {
            droppedFrames += 1
            return
        }

        if firstTimestamp == nil {
            firstTimestamp = frame.timestamp
        }

        let rgb = frame.capturedImage
        let depth = sceneDepth.depthMap
        let confidence = sceneDepth.confidenceMap
        let intrinsics = frame.camera.intrinsics
        let quaternion = simd_quatf(transform)

        let rgbWidth = CVPixelBufferGetWidth(rgb)
        let rgbHeight = CVPixelBufferGetHeight(rgb)
        let depthWidth = CVPixelBufferGetWidth(depth)
        let depthHeight = CVPixelBufferGetHeight(depth)


        // SIMD indexing is [column][row]; JSON explicitly stores rows.
        let poseRows: [[Float]] = (0..<4).map { row in
            (0..<4).map { column in transform[column][row] }
        }

        let intrinsicRows: [[Float]] = (0..<3).map { row in
            (0..<3).map { column in intrinsics[column][row] }
        }

        var metadata: [String: Any] = [
            "schema_version": 2,
            "world_session_id": worldSessionID,
            "recording_id": recordingID,
            "frame_id": frameID,
            "timestamp_seconds": frame.timestamp,
            "elapsed_seconds": frame.timestamp - (firstTimestamp ?? frame.timestamp),
            "timestamp_timebase": "ARFrame monotonic seconds",
            "rgb_file": "rgb.jpg",
            "depth_file": "depth.bin",
            "rgb_width": rgbWidth,
            "rgb_height": rgbHeight,
            "depth_width": depthWidth,
            "depth_height": depthHeight,
            "depth_dtype": "float32",
            "depth_byte_order": "little",
            "depth_units": "meters",
            "depth_layout": "row_major_tightly_packed",
            "depth_source": "sceneDepth",
            "invalid_depth_rule": "Exclude nonfinite and nonpositive values",
            "image_orientation": "native_buffer_no_rotation_crop_or_resize",
            "camera_intrinsics_3x3": intrinsicRows,
            "intrinsics_reference_width": frame.camera.imageResolution.width,
            "intrinsics_reference_height": frame.camera.imageResolution.height,
            "camera_to_world_4x4": poseRows,
            "matrix_serialization": "rows",
            "position_meters": [
                "x": position.x,
                "y": position.y,
                "z": position.z
            ],
            "rotation_quaternion_xyzw": [
                quaternion.imag.x,
                quaternion.imag.y,
                quaternion.imag.z,
                quaternion.real
            ],
            "world_coordinates": "ARKit session-local right-handed, gravity-aligned Y-up",
            "camera_coordinates": "ARKit camera X-right Y-up Z-backward",
            "optical_to_camera_diagonal": [1, -1, -1, 1],
            "tracking_state": tracking.name,
            "tracking_reason": tracking.reason,
            "recommended_for_fusion": tracking.name == "normal"
        ]

        if let confidence = confidence {
            metadata["confidence_file"] = "confidence.bin"
            metadata["confidence_dtype"] = "uint8"
            metadata["confidence_width"] = CVPixelBufferGetWidth(confidence)
            metadata["confidence_height"] = CVPixelBufferGetHeight(confidence)
            metadata["confidence_levels"] = "0=low, 1=medium, 2=high"
        }

        do {
            // Copy depth and confidence now, before asynchronous writing.
            let depthBytes = try packedData(
                depth,
                expectedFormat: kCVPixelFormatType_DepthFloat32,
                bytesPerPixel: 4
            )

            let confidenceBytes: Data?
            if let confidence = confidence {
                confidenceBytes = try packedData(
                    confidence,
                    expectedFormat: kCVPixelFormatType_OneComponent8,
                    bytesPerPixel: 1
                )
            } else {
                confidenceBytes = nil
            }

            let json = try JSONSerialization.data(
                withJSONObject: metadata,
                options: [.prettyPrinted, .sortedKeys]
            )

            frameID += 1
            busy = true

            let generation = connectionGeneration
            // One RGB buffer retained only until encoding finishes. No ARFrame retained.
            writer.async { [self] in
                do {
                    let jpeg: Data = try autoreleasepool {
                        let image = CIImage(cvPixelBuffer: rgb)
                        guard let cgImage = imageContext.createCGImage(image, from: image.extent),
                              let encoded = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85) else {
                            throw captureError("Could not encode RGB image.")
                        }
                        return encoded
                    }
                    DispatchQueue.main.async {
                        guard self.connectionGeneration == generation, self.connected else {
                            self.busy = false
                            return
                        }
                        self.stream.sendFrame(json: json, rgb: jpeg, depth: depthBytes,
                                              confidence: confidenceBytes) { result in
                            self.busy = false
                            switch result {
                            case .success:
                                self.savedFrames += 1
                                self.message = "Computer confirmed \(self.savedFrames) frames."
                            case .failure(let error):
                                self.recording = false
                                UIApplication.shared.isIdleTimerDisabled = false
                                self.message = error.localizedDescription
                            }
                        }
                    }
                } catch {
                    let details = error.localizedDescription
                    DispatchQueue.main.async {
                        self.busy = false
                        self.recording = false
                        UIApplication.shared.isIdleTimerDisabled = false
                        self.message = "Streaming stopped: \(details)"
                    }
                }
            }
        } catch {
            recording = false
            UIApplication.shared.isIdleTimerDisabled = false
            message = "Streaming stopped: \(error.localizedDescription)"
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        stopRecording()
        status = "Session interrupted. Start a new recording after recovery."
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        status = "Session resumed. Wait for Normal tracking."
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        stopRecording()
        status = "ARKit error: \(error.localizedDescription)"
    }
}

struct ARCameraPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct ARCaptureTestView: View {
    @StateObject private var controller = ARCaptureTestController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            ARCameraPreview(session: controller.session)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                Text(controller.status)
                    .font(.system(size: 15, design: .monospaced))

                Text("On computer: \(controller.savedFrames) | Skipped: \(controller.droppedFrames)")

                Text(controller.message)
                    .font(.caption)
                    .lineLimit(3)

                HStack {
                    TextField("Computer IP, e.g. 192.168.1.20", text: $controller.host)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .foregroundColor(.black)
                        .disabled(controller.connected || controller.busy)
                    Button(controller.connected ? "Disconnect" : "Connect") {
                        if controller.connected { controller.disconnect() }
                        else { controller.connect() }
                    }
                    .disabled(controller.busy && !controller.connected)
                }

                Spacer()

                Button {
                    if controller.recording {
                        controller.stopRecording()
                    } else {
                        controller.startRecording()
                    }
                } label: {
                    Text(controller.recording ? "Stop Streaming" : "Start Streaming")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(controller.recording ? Color.red : Color.blue)
                        .cornerRadius(12)
                }
                .disabled(!controller.connected || (controller.busy && !controller.recording))
            }
            .foregroundColor(.white)
            .padding()
            .background(Color.black.opacity(0.35))
        }
        .onAppear {
            controller.startSession()
        }
        .onDisappear {
            controller.pauseSession()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                controller.startSession()
            } else {
                controller.pauseSession()
            }
        }
    }
}
