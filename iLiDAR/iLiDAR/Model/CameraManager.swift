/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
An object that connects the camera controller and the views.
*/

// Modified by Bo Liang in 2024.

import Foundation
import SwiftUI
import Combine
import simd
import ARKit

class CameraManager: ObservableObject, CaptureDataReceiver {

    var capturedData: CameraCapturedData
    @Published var isFilteringDepth: Bool {
        didSet {
            controller.isFilteringEnabled = isFilteringDepth
        }
    }
    @Published var orientation = UIDevice.current.orientation // 使用当前设备方向
    @Published var waitingForCapture = false
    @Published var processingCapturedResult = false
    @Published var dataAvailable = false
    
    @Published var enableNetworkTransfer: Bool = false
    @Published var eventName: String = ""
    @Published var transmissionFrequency: Int = 4 { // 默认4 FPS
        didSet {
            controller.transmissionFrequency = transmissionFrequency
        }
    }
    
    let controller: CameraController
    var cancellables = Set<AnyCancellable>()
    var session: ARSession { controller.session }
    
    init() {
        // Create an object to store the captured data for the views to present.
        capturedData = CameraCapturedData()
        controller = CameraController()
        controller.isFilteringEnabled = true
        controller.startStream()
        isFilteringDepth = controller.isFilteringEnabled
        
        // Ensure transmission frequency is set correctly
        transmissionFrequency = controller.transmissionFrequency
        
        enableNetworkTransfer = controller.enableNetworkTransfer
        controller.$enableNetworkTransfer
            .receive(on: DispatchQueue.main)
            .assign(to: \.enableNetworkTransfer, on:self)
            .store(in: &cancellables)
        controller.$eventName
            .receive(on: DispatchQueue.main)
            .assign(to: \.eventName, on: self)
            .store(in: &cancellables)
        
        // 移除设备方向监听，因为应用已锁定为竖屏
        // NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification).sink { _ in
        //     DispatchQueue.main.async {
        //         self.orientation = UIDevice.current.orientation
        //     }
        // }.store(in: &cancellables)
        
        controller.delegate = self
    }
    
    func toggleNetworkTransfer() {
        controller.toggleNetworkTransfer()
    }
    
    func startPhotoCapture() {
        controller.capturePhoto()
        waitingForCapture = true
    }
    
    func resumeStream() {
        controller.startStream()
        processingCapturedResult = false
        waitingForCapture = false
    }
    
    func onNewPhotoData(capturedData: CameraCapturedData) {
        // Because the views hold a reference to `capturedData`, the app updates each texture separately.
        self.capturedData.depth = capturedData.depth
        self.capturedData.colorY = capturedData.colorY
        self.capturedData.colorCbCr = capturedData.colorCbCr
        self.capturedData.cameraIntrinsics = capturedData.cameraIntrinsics
        self.capturedData.cameraReferenceDimensions = capturedData.cameraReferenceDimensions
        waitingForCapture = false
        processingCapturedResult = true
    }
    
    func onNewData(capturedData: CameraCapturedData) {
        DispatchQueue.main.async {
            if !self.processingCapturedResult {
                // Because the views hold a reference to `capturedData`, the app updates each texture separately.
                self.capturedData.depth = capturedData.depth
                self.capturedData.colorY = capturedData.colorY
                self.capturedData.colorCbCr = capturedData.colorCbCr
                self.capturedData.cameraIntrinsics = capturedData.cameraIntrinsics
                self.capturedData.cameraReferenceDimensions = capturedData.cameraReferenceDimensions
                if self.dataAvailable == false {
                    self.dataAvailable = true
                }
            }
        }
    }
   
}

