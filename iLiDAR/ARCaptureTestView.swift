import SwiftUI
import ARKit
import SceneKit
import Combine
import CoreImage
import UIKit
import simd

private func localCaptureError(_ message: String) -> NSError {
    NSError(
        domain: "iLiDARLocalCapture",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}

private func copyPackedPixels(
    _ buffer: CVPixelBuffer,
    format: OSType,
    bytesPerPixel: Int
) throws -> Data {
    guard CVPixelBufferGetPixelFormatType(buffer) == format,
          !CVPixelBufferIsPlanar(buffer) else {
        throw localCaptureError("Unexpected pixel-buffer format.")
    }

    guard CVPixelBufferLockBaseAddress(buffer, .readOnly)
            == kCVReturnSuccess else {
        throw localCaptureError("Could not lock pixel buffer.")
    }

    defer {
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
    }

    guard let base = CVPixelBufferGetBaseAddress(buffer) else {
        throw localCaptureError("Pixel buffer has no data.")
    }

    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let rowSize = width * bytesPerPixel

    guard stride >= rowSize else {
        throw localCaptureError("Invalid pixel-buffer stride.")
    }

    var data = Data(capacity: rowSize * height)

    for row in 0..<height {
        data.append(
            base.advanced(by: row * stride)
                .assumingMemoryBound(to: UInt8.self),
            count: rowSize
        )
    }

    return data
}

final class ARCaptureTestController: NSObject,
    ObservableObject, ARSessionDelegate {

    let session = ARSession()

    @Published var status = "Starting camera…"
    @Published var message = "Ready for local recording."
    @Published var recording = false
    @Published var finishing = false
    @Published var savedFrames = 0
    @Published var droppedFrames = 0
    @Published var failedFrames = 0
    @Published var queuedFrames = 0
    @Published var savedFPS = 0.0
    @Published var recordingName = ""

    private let targetFPS = 30.0

    // Includes the frame currently being written.
    // Bounds retained camera buffers and memory use.
    private let maximumQueuedFrames = 3

    private let writer = DispatchQueue(
        label: "iLiDAR.localWriter",
        qos: .userInitiated
    )

    private let imageContext = CIContext()
    private let worldSessionID = UUID().uuidString

    private var sessionRunning = false
    private var recordingFolder: URL?
    private var frameID = 0
    private var firstTimestamp: TimeInterval?
    private var nextCaptureTimestamp: TimeInterval?
    private var firstSavedTimestamp: TimeInterval?
    private var lastSavedTimestamp: TimeInterval?
    private var lastDisplayTimestamp: TimeInterval = -.infinity

    private var firstWriteError: String?
    private var writingSummary = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = .main
    }

    func startSession() {
        guard !sessionRunning else { return }

        guard ARWorldTrackingConfiguration.supportsFrameSemantics(
            .sceneDepth
        ) else {
            status = "LiDAR scene depth is unavailable."
            message = "Use a supported physical iPhone or iPad."
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics = [.sceneDepth]
        configuration.worldAlignment = .gravity

        session.run(configuration)
        sessionRunning = true
    }

    func pauseSession() {
        stopRecording()
        session.pause()
        sessionRunning = false
    }

    func startRecording() {
        guard !recording, !finishing, queuedFrames == 0 else {
            return
        }

        guard let frame = session.currentFrame,
              frame.sceneDepth != nil else {
            message = "Wait until depth is available."
            return
        }

        guard case .normal = frame.camera.trackingState else {
            message = "Wait until tracking is normal."
            return
        }

        do {
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]

            let name = UUID().uuidString
            let folder = documents
                .appendingPathComponent(
                    "Recordings",
                    isDirectory: true
                )
                .appendingPathComponent(
                    name,
                    isDirectory: true
                )

            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true,
                attributes: nil
            )

            let initialSummary: [String: Any] = [
                "recording_id": name,
                "world_session_id": worldSessionID,
                "status": "recording",
                "target_fps": targetFPS
            ]

            let initialJSON = try JSONSerialization.data(
                withJSONObject: initialSummary,
                options: [.prettyPrinted, .sortedKeys]
            )

            try initialJSON.write(
                to: folder.appendingPathComponent("recording.json"),
                options: .atomic
            )

            recordingFolder = folder
            recordingName = name

            frameID = 0
            savedFrames = 0
            droppedFrames = 0
            failedFrames = 0
            queuedFrames = 0
            savedFPS = 0

            firstTimestamp = nil
            nextCaptureTimestamp = nil
            firstSavedTimestamp = nil
            lastSavedTimestamp = nil
            firstWriteError = nil
            writingSummary = false

            recording = true
            UIApplication.shared.isIdleTimerDisabled = true
            message = "Recording to this iPhone."
        } catch {
            message = "Could not start: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard recording else { return }

        recording = false
        finishing = true
        message = "Finishing queued frames…"

        // Request a short amount of background time to finish writes
        // if the app is moved into the background.
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(
                withName: "Finish LiDAR recording"
            ) { [weak self] in
                self?.endBackgroundTask()
            }
        }

        finishIfReady()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }

        let task = backgroundTask
        backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }

    private func finishIfReady() {
        guard finishing,
              queuedFrames == 0,
              !writingSummary,
              let folder = recordingFolder else {
            return
        }

        writingSummary = true

        let errorText = firstWriteError
        let savedCount = savedFrames

        let summary: [String: Any] = [
            "recording_id": recordingName,
            "world_session_id": worldSessionID,
            "status": errorText == nil
                ? "complete"
                : "stopped_after_write_error",
            "target_fps": targetFPS,
            "saved_frames": savedFrames,
            "skipped_capture_attempts": droppedFrames,
            "failed_frames": failedFrames,
            "average_saved_fps": savedFPS,
            "first_saved_timestamp_seconds":
                firstSavedTimestamp ?? 0,
            "last_saved_timestamp_seconds":
                lastSavedTimestamp ?? 0,
            "error": errorText ?? ""
        ]

        writer.async {
            var summaryError: String?

            do {
                let data = try JSONSerialization.data(
                    withJSONObject: summary,
                    options: [.prettyPrinted, .sortedKeys]
                )

                try data.write(
                    to: folder.appendingPathComponent("recording.json"),
                    options: .atomic
                )
            } catch {
                summaryError = error.localizedDescription
            }

            let finalError = summaryError

            DispatchQueue.main.async {
                self.finishing = false
                self.writingSummary = false
                UIApplication.shared.isIdleTimerDisabled = false
                self.endBackgroundTask()

                if let finalError = finalError {
                    self.message = """
                    Frames saved, but summary failed: \(finalError)
                    """
                } else if let errorText = errorText {
                    self.message = """
                    Stopped: \(errorText)
                    \(savedCount) completed frames remain on the phone.
                    """
                } else {
                    self.message = """
                    Ready to transfer: \(savedCount) frames.
                    Files > On My iPhone > iLiDAR > Recordings
                    """
                }
            }
        }
    }

    private func trackingName(
        _ state: ARCamera.TrackingState
    ) -> String {
        switch state {
        case .normal:
            return "normal"
        case .limited:
            return "limited"
        case .notAvailable:
            return "unavailable"
        }
    }

    func session(
        _ session: ARSession,
        didUpdate frame: ARFrame
    ) {
        let tracking = trackingName(frame.camera.trackingState)
        let transform = frame.camera.transform
        let position = transform.columns.3
        let angles = frame.camera.eulerAngles * (180 / Float.pi)

        if frame.timestamp - lastDisplayTimestamp >= 0.1 {
            lastDisplayTimestamp = frame.timestamp

            status = """
            Tracking: \(tracking)
            X: \(String(format: "%.3f", position.x)) m
            Y: \(String(format: "%.3f", position.y)) m
            Z: \(String(format: "%.3f", position.z)) m
            Rotation X: \(String(format: "%.1f", angles.x))°
            Rotation Y: \(String(format: "%.1f", angles.y))°
            Rotation Z: \(String(format: "%.1f", angles.z))°
            Depth: \(frame.sceneDepth == nil ? "Waiting" : "Available")
            """
        }

        guard recording, let folder = recordingFolder else {
            return
        }

        let interval = 1.0 / targetFPS
        let deadline = nextCaptureTimestamp ?? frame.timestamp

        // Small tolerance avoids skipping due to timestamp rounding.
        guard frame.timestamp + 0.001 >= deadline else {
            return
        }

        var nextDeadline = deadline + interval

        // Do not try to catch up by producing a burst after a pause.
        if nextDeadline <= frame.timestamp {
            nextDeadline = frame.timestamp + interval
        }

        nextCaptureTimestamp = nextDeadline

        // Give every selected capture attempt an ID, including skips.
        let currentFrameID = frameID
        frameID += 1

        guard queuedFrames < maximumQueuedFrames,
              let sceneDepth = frame.sceneDepth else {
            droppedFrames += 1
            return
        }

        if firstTimestamp == nil {
            firstTimestamp = frame.timestamp
        }

        // Retain only the buffers needed by this bounded write job.
        // The worker does not retain the ARFrame itself.
        let rgb = frame.capturedImage
        let depth = sceneDepth.depthMap
        let confidence = sceneDepth.confidenceMap
        let timestamp = frame.timestamp
        let intrinsics = frame.camera.intrinsics
        let quaternion = simd_quatf(transform)

        let rgbWidth = CVPixelBufferGetWidth(rgb)
        let rgbHeight = CVPixelBufferGetHeight(rgb)
        let depthWidth = CVPixelBufferGetWidth(depth)
        let depthHeight = CVPixelBufferGetHeight(depth)

        let poseRows: [[Float]] = (0..<4).map { row in
            (0..<4).map { column in
                transform[column][row]
            }
        }

        let intrinsicRows: [[Float]] = (0..<3).map { row in
            (0..<3).map { column in
                intrinsics[column][row]
            }
        }

        var metadata: [String: Any] = [
            "schema_version": 2,
            "world_session_id": worldSessionID,
            "recording_id": recordingName,
            "frame_id": currentFrameID,
            "timestamp_seconds": timestamp,
            "elapsed_seconds": timestamp - (firstTimestamp ?? timestamp),
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
            "rotation_euler_degrees_xyz": [
                angles.x,
                angles.y,
                angles.z
            ],
            "world_coordinates": "ARKit session-local right-handed, gravity-aligned Y-up",
            "camera_coordinates": "ARKit camera X-right Y-up Z-backward",
            "optical_to_camera_diagonal": [1, -1, -1, 1],
            "tracking_state": tracking,
            "recommended_for_fusion": tracking == "normal"
        ]

        if let confidence = confidence {
            metadata["confidence_file"] = "confidence.bin"
            metadata["confidence_dtype"] = "uint8"
            metadata["confidence_width"] = CVPixelBufferGetWidth(confidence)
            metadata["confidence_height"] = CVPixelBufferGetHeight(confidence)
            metadata["confidence_levels"] = "0=low, 1=medium, 2=high"
        }

        let frameMetadata = metadata
        let frameName = String(
            format: "frame_%06d",
            currentFrameID
        )

        queuedFrames += 1

        writer.async {
            let finalFolder = folder.appendingPathComponent(
                frameName,
                isDirectory: true
            )

            let temporaryFolder = folder.appendingPathComponent(
                ".partial_" + frameName,
                isDirectory: true
            )

            var writeError: String?

            do {
                try autoreleasepool {
                    let manager = FileManager.default

                    try manager.createDirectory(
                        at: temporaryFolder,
                        withIntermediateDirectories: false,
                        attributes: nil
                    )

                    let depthData = try copyPackedPixels(
                        depth,
                        format: kCVPixelFormatType_DepthFloat32,
                        bytesPerPixel: 4
                    )

                    try depthData.write(
                        to: temporaryFolder.appendingPathComponent(
                            "depth.bin"
                        )
                    )

                    if let confidence = confidence {
                        let confidenceData = try copyPackedPixels(
                            confidence,
                            format: kCVPixelFormatType_OneComponent8,
                            bytesPerPixel: 1
                        )

                        try confidenceData.write(
                            to: temporaryFolder.appendingPathComponent(
                                "confidence.bin"
                            )
                        )
                    }

                    let image = CIImage(cvPixelBuffer: rgb)

                    guard let cgImage = self.imageContext.createCGImage(
                        image,
                        from: image.extent
                    ),
                    let jpeg = UIImage(cgImage: cgImage).jpegData(
                        compressionQuality: 0.8
                    ) else {
                        throw localCaptureError(
                            "Could not encode RGB image."
                        )
                    }

                    try jpeg.write(
                        to: temporaryFolder.appendingPathComponent(
                            "rgb.jpg"
                        )
                    )

                    let json = try JSONSerialization.data(
                        withJSONObject: frameMetadata,
                        options: [.sortedKeys]
                    )

                    try json.write(
                        to: temporaryFolder.appendingPathComponent(
                            "metadata.json"
                        )
                    )

                    // A visible frame folder appears only when all
                    // of its files have been written successfully.
                    try manager.moveItem(
                        at: temporaryFolder,
                        to: finalFolder
                    )
                }
            } catch {
                writeError = error.localizedDescription
                try? FileManager.default.removeItem(
                    at: temporaryFolder
                )
            }

            let resultError = writeError

            DispatchQueue.main.async {
                self.queuedFrames -= 1

                if let resultError = resultError {
                    self.failedFrames += 1

                    if self.firstWriteError == nil {
                        self.firstWriteError = resultError
                    }

                    self.stopRecording()
                } else {
                    self.savedFrames += 1

                    if self.firstSavedTimestamp == nil {
                        self.firstSavedTimestamp = timestamp
                    }

                    self.lastSavedTimestamp = timestamp

                    if let first = self.firstSavedTimestamp {
                        let span = timestamp - first

                        if span > 0 {
                            self.savedFPS =
                                Double(self.savedFrames - 1) / span
                        }
                    }
                }

                self.finishIfReady()
            }
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        stopRecording()
        status = "Session interrupted."
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        status = "Session resumed. Wait for normal tracking."
    }

    func session(
        _ session: ARSession,
        didFailWithError error: Error
    ) {
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

    func updateUIView(
        _ uiView: ARSCNView,
        context: Context
    ) {}
}

struct ARCaptureTestView: View {
    @StateObject private var controller = ARCaptureTestController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            ARCameraPreview(session: controller.session)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(controller.status)
                            .font(
                                .system(
                                    size: 15,
                                    design: .monospaced
                                )
                            )
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )

                        Text(
                            "Saved: \(controller.savedFrames) | Skipped: \(controller.droppedFrames)"
                        )

                        Text(
                            "Queued: \(controller.queuedFrames) | Failed: \(controller.failedFrames)"
                        )

                        Text(
                            String(
                                format: "Target: 30 FPS | Saved average: %.1f FPS",
                                controller.savedFPS
                            )
                        )

                        Text(controller.message)
                            .font(.caption)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )

                        if !controller.recordingName.isEmpty {
                            Text(
                                "Recording: \(controller.recordingName)"
                            )
                            .font(.caption2)
                            .textSelection(.enabled)
                        }
                    }
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                }

                Button {
                    if controller.recording {
                        controller.stopRecording()
                    } else {
                        controller.startRecording()
                    }
                } label: {
                    Text(
                        controller.finishing
                            ? "Finishing…"
                            : (
                                controller.recording
                                    ? "Stop Recording"
                                    : "Start Recording"
                            )
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        controller.recording
                            ? Color.red
                            : Color.blue
                    )
                    .cornerRadius(12)
                }
                .disabled(controller.finishing)
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
