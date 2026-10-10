/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
The app's main user interface.
*/

import SwiftUI
import MetalKit
import Metal
import Combine
import AVFoundation

// 添加方向锁定
struct OrientationLockModifier: ViewModifier {
    @State private var isOrientationLocked: Bool = true
    
    func body(content: Content) -> some View {
        content
            .onAppear {
                // Lock to portrait orientation - use Info.plist settings, no longer manually set UIDevice.orientation
                isOrientationLocked = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                // Listen for orientation changes but don't manually set (controlled by Info.plist)
                if isOrientationLocked {
                    // Only log orientation changes, don't force set
                    print("📱 Device orientation changed, but app is locked to portrait")
                }
            }
    }
}

extension View {
    func lockOrientation() -> some View {
        self.modifier(OrientationLockModifier())
    }
}

// MARK: - Models
struct SavedIPAddress: Identifiable, Codable {
    let id = UUID()
    let name: String
    let ip: String
    let port: Int
    let isDefault: Bool
    
    init(name: String, ip: String, port: Int, isDefault: Bool = false) {
        self.name = name
        self.ip = ip
        self.port = port
        self.isDefault = isDefault
    }
}

// MARK: - IP Address Manager
class IPAddressManager: ObservableObject {
    @Published var savedAddresses: [SavedIPAddress] = []
    @Published var selectedAddress: SavedIPAddress?
    
    private let userDefaults = UserDefaults.standard
    private let savedAddressesKey = "SavedIPAddresses"
    
    init() {
        loadSavedAddresses()
        if savedAddresses.isEmpty {
            // Add default addresses
            savedAddresses = [
                SavedIPAddress(name: "Local Network", ip: "192.168.1.100", port: 5678, isDefault: true),
                SavedIPAddress(name: "Home Server", ip: "10.0.0.50", port: 5678),
                SavedIPAddress(name: "Lab Computer", ip: "10.129.164.22", port: 5678)
            ]
            saveAddresses()
        }
        selectedAddress = savedAddresses.first { $0.isDefault } ?? savedAddresses.first
    }
    
    func addAddress(_ address: SavedIPAddress) {
        // Add new address to the first position
        savedAddresses.insert(address, at: 0)
        saveAddresses()
    }
    
    func removeAddress(_ address: SavedIPAddress) {
        savedAddresses.removeAll { $0.id == address.id }
        saveAddresses()
    }
    
    func moveAddress(from source: IndexSet, to destination: Int) {
        savedAddresses.move(fromOffsets: source, toOffset: destination)
        saveAddresses()
    }
    
    private func saveAddresses() {
        if let encoded = try? JSONEncoder().encode(savedAddresses) {
            userDefaults.set(encoded, forKey: savedAddressesKey)
        }
    }
    
    private func loadSavedAddresses() {
        if let data = userDefaults.data(forKey: savedAddressesKey),
           let decoded = try? JSONDecoder().decode([SavedIPAddress].self, from: data) {
            savedAddresses = decoded
        }
    }
}

// MARK: - Custom Styles
struct ModernButtonStyle: ButtonStyle {
    let backgroundColor: Color
    let isDestructive: Bool
    
    init(backgroundColor: Color, isDestructive: Bool = false) {
        self.backgroundColor = backgroundColor
        self.isDestructive = isDestructive
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(backgroundColor)
            .foregroundColor(.white)
            .cornerRadius(12)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(Color(.systemBackground))
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
    }
}

// MARK: - Connection States
enum ConnectionState {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case failed
    
    var color: Color {
        switch self {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected, .failed, .disconnecting: return .red
        }
    }
    
    var icon: String {
        switch self {
        case .connected: return "wifi"
        case .connecting: return "wifi.exclamationmark"
        case .disconnected: return "wifi.slash"
        case .failed: return "exclamationmark.triangle"
        case .disconnecting: return "wifi.slash"
        }
    }
    
    var isConnected: Bool {
        return self == .connected
    }
    
    var isConnecting: Bool {
        return self == .connecting
    }
    
    var isDisconnected: Bool {
        return self == .disconnected || self == .failed
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var manager = CameraManager()
    @StateObject private var ipManager = IPAddressManager()
    
    @State private var maxDepth = Float(5.0)
    @State private var minDepth = Float(0.0)
    @State private var connectionState: ConnectionState = .disconnected
    @State private var isConnecting: Bool = false
    @State private var showingSettings = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var currentOrientation: UIDeviceOrientation = .portrait
    @State private var isOrientationLocked: Bool = true
    
    let maxRangeDepth = Float(15)
    let minRangeDepth = Float(0)
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                cameraViewSection
                quickControlsBar
            }
            .navigationBarHidden(true)
            .lockOrientation() // Lock orientation
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                manager: manager,
                ipManager: ipManager,
                maxDepth: $maxDepth,
                minDepth: $minDepth,
                connectionState: $connectionState,
                isConnecting: $isConnecting,
                onConnect: connectToServer // pass closure
            )
        }
        .alert("Network Connection", isPresented: $showingAlert) {
            Button("Settings") {
                showingSettings = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
    }
    
    // MARK: - Camera View Section
    private var cameraViewSection: some View {
        ZStack {
                    if manager.dataAvailable {
                        ZoomOnTap {
                            DepthOverlay(manager: manager,
                                         maxDepth: $maxDepth,
                                 minDepth: $minDepth)
                            .aspectRatio(calcAspect(orientation: viewOrientation, texture: manager.capturedData.depth), contentMode: .fit)
                    .clipped() // Ensure content doesn't overflow
                    .rotationEffect(.degrees(0)) // Force no rotation
                }
                .overlay(
                    // Status overlay - top right corner
                    VStack {
                        HStack {
                            Spacer()
                            VStack(spacing: 6) {
                                // Live indicator
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 8, height: 8)
                                        .scaleEffect(1.2)
                                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: manager.dataAvailable)
                                    Text("LIVE")
                                        .font(.caption2)
                                        .foregroundColor(.white)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.7))
                                .cornerRadius(12)
                                
                                // Network connection indicator
                                HStack(spacing: 4) {
                                    Image(systemName: connectionState.icon)
                                        .font(.caption2)
                                    Text(connectionState.isConnected ? "CONNECTED" : "DISCONNECTED")
                                        .font(.caption2)
                                        .foregroundColor(.white)
                                }
                                .foregroundColor(connectionState.color)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(connectionState.color.opacity(0.8))
                                .cornerRadius(12)
                                
                                // Transfer indicator
                                if manager.enableNetworkTransfer {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.up.arrow.down")
                                            .font(.caption2)
                                        Text("TRANSFERRING")
                                            .font(.caption2)
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.orange.opacity(0.8))
                                    .cornerRadius(12)
                                }
                            }
                            .padding(.top, 12)
                            .padding(.trailing, 12)
                        }
                        Spacer()
                    }
                )
            } else {
                // Loading state
                VStack(spacing: 16) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 50))
                        .foregroundColor(.gray)
                        .scaleEffect(1.0)
                        .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: !manager.dataAvailable)
                    
                    VStack(spacing: 4) {
                        Text("Initializing Camera...")
                            .font(.headline)
                            .foregroundColor(.gray)
                        Text("Please wait while LiDAR sensor initializes")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGray6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black) // 确保背景是黑色
        .rotationEffect(.degrees(0)) // 强制不旋转
    }
    
    // MARK: - Quick Controls Bar
    private var quickControlsBar: some View {
        HStack(spacing: 0) {
            // Depth Filter Toggle
            Button(action: {
                manager.isFilteringDepth.toggle()
            }) {
                VStack(spacing: 4) {
                    Image(systemName: manager.isFilteringDepth ? "slider.horizontal.3" : "slider.horizontal.3")
                        .font(.title3)
                        .foregroundColor(manager.isFilteringDepth ? .blue : .gray)
                    Text("Filter")
                        .font(.caption2)
                        .foregroundColor(manager.isFilteringDepth ? .blue : .gray)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(manager.isFilteringDepth ? Color.blue.opacity(0.1) : Color.clear)
                )
            }
            .buttonStyle(PlainButtonStyle())
            
            Divider()
                .frame(height: 25)
            
            // Network Connection Button
            Button(action: {
                // If there's a selected server, connect directly
                if let selectedAddress = ipManager.selectedAddress {
                    connectToServer(selectedAddress)
                } else {
                    // If no server is selected, show alert
                    alertMessage = "Please select a server first. Go to Settings to add or select a server."
                    showingAlert = true
                }
            }) {
                VStack(spacing: 4) {
                    if isConnecting && connectionState.isConnecting {
                        ProgressView()
                            .scaleEffect(0.8)
                            .foregroundColor(.blue)
                    } else {
                        Image(systemName: connectionState.icon)
                            .font(.title3)
                            .foregroundColor(connectionState.isConnected ? .green : .gray)
                    }
                    Text("Network")
                        .font(.caption2)
                        .foregroundColor(connectionState.isConnected ? .green : .gray)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(connectionState.isConnected ? Color.green.opacity(0.1) : Color.clear)
                )
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isConnecting)
            
            Divider()
                .frame(height: 25)
            
            // Network Transfer Toggle
            Button(action: {
                manager.toggleNetworkTransfer()
            }) {
                VStack(spacing: 4) {
                    Image(systemName: manager.enableNetworkTransfer ? "network" : "network.slash")
                        .font(.title3)
                        .foregroundColor(manager.enableNetworkTransfer ? .orange : .gray)
                    Text("Transfer")
                        .font(.caption2)
                        .foregroundColor(manager.enableNetworkTransfer ? .orange : .gray)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(manager.enableNetworkTransfer ? Color.orange.opacity(0.1) : Color.clear)
                )
            }
            .buttonStyle(PlainButtonStyle())
            
            Divider()
                .frame(height: 25)
            
            // Settings Button
            Button(action: {
                showingSettings = true
            }) {
                VStack(spacing: 4) {
                    Image(systemName: "gearshape")
                        .font(.title3)
                        .foregroundColor(.blue)
                    Text("Settings")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.blue.opacity(0.1))
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }
    
    // MARK: - Connection Actions
    private func connectButtonTapped() {
        guard let selectedAddress = ipManager.selectedAddress else { return }
        
        isConnecting = true
        connectionState = .connecting
        
        DataStorage.shared.updateConnection(host_ip: selectedAddress.ip, port: selectedAddress.port) { success in
            DispatchQueue.main.async {
                if success {
                    self.connectionState = .connected
                } else {
                    self.connectionState = .failed
                }
                self.isConnecting = false
            }
        }
    }
    
    private func disconnectButtonTapped() {
        isConnecting = true
        connectionState = .disconnecting
        
        DataStorage.shared.disconnect()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.connectionState = .disconnected
            self.isConnecting = false
        }
    }
    
    private func connectToServer(_ address: SavedIPAddress) {
        isConnecting = true
        connectionState = .connecting
        DataStorage.shared.updateConnection(host_ip: address.ip, port: address.port) { success in
            DispatchQueue.main.async {
                if success {
                    self.connectionState = .connected
                } else {
                    self.connectionState = .failed
                }
                self.isConnecting = false
            }
        }
    }
    
    // MARK: - Helper Properties
    private var connectionStateText: String {
        switch connectionState {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .disconnecting: return "Disconnecting..."
        case .disconnected: return "Disconnected"
        case .failed: return "Connection Failed"
        }
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject var manager: CameraManager
    @ObservedObject var ipManager: IPAddressManager
    @Binding var maxDepth: Float
    @Binding var minDepth: Float
    @Binding var connectionState: ConnectionState
    @Binding var isConnecting: Bool
    var onConnect: (SavedIPAddress) -> Void // add this line
    
    @Environment(\.dismiss) private var dismiss
    @State private var showingIPManager = false
    @State private var showingAddIP = false
    
    let maxRangeDepth = Float(15)
    let minRangeDepth = Float(0)
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Status overview
                    statusOverviewSection
                    
                    // Camera settings
                    cameraSettingsSection
                    
                    // Network settings
                    networkSettingsSection
                    
                    // Transfer settings
                    transferSettingsSection
                    
                    // Help tips
                    helpTipsSection
                }
                .padding()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showingIPManager) {
            IPAddressManagerView(ipManager: ipManager)
        }
        .sheet(isPresented: $showingAddIP) {
            AddIPAddressView(ipManager: ipManager)
        }
    }
    
    // MARK: - Status Overview Section
    private var statusOverviewSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.blue)
                Text("Status Overview")
                    .font(.headline)
            }
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                    Text("Connection Status")
                        .font(.headline)
                }
                
                // Connection status
                HStack {
                    Image(systemName: connectionState.icon)
                        .foregroundColor(connectionState.color)
                    Text(connectionStateText)
                        .foregroundColor(connectionState.color)
                    Spacer()
                }
                
                // Quick connect button
                if connectionState.isDisconnected {
                    Button(action: {
                        if let selectedAddress = ipManager.selectedAddress {
                            onConnect(selectedAddress)
                        }
                    }) {
                        HStack {
                            Image(systemName: "wifi")
                            Text("Quick Connect")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ModernButtonStyle(backgroundColor: .blue))
                    .disabled(ipManager.selectedAddress == nil)
                }
            }
        }
        .modifier(CardStyle())
    }
    
    // MARK: - Camera Settings Section
    private var cameraSettingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "camera.fill")
                    .foregroundColor(.blue)
                Text("Camera Settings")
                    .font(.headline)
            }
            
            VStack(spacing: 16) {
                // 深度过滤开关
                    Toggle(isOn: $manager.isFilteringDepth) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable Depth Filtering")
                            .font(.body)
                        Text("Filter point cloud by depth range")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                // 深度范围滑块
                if manager.isFilteringDepth {
                    VStack(spacing: 12) {
                        Text("Depth Range")
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                    SliderDepthBoundaryView(val: $maxDepth, label: "Max Depth", minVal: minRangeDepth, maxVal: maxRangeDepth)
                    SliderDepthBoundaryView(val: $minDepth, label: "Min Depth", minVal: minRangeDepth, maxVal: maxRangeDepth)
                    }
                }
            }
        }
        .modifier(CardStyle())
    }
    
    // MARK: - Network Settings Section
    private var networkSettingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "network")
                    .foregroundColor(.blue)
                Text("Network Settings")
                    .font(.headline)
            }
            
            VStack(spacing: 16) {
                // 服务器选择
                    HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Server")
                            .font(.body)
                        if let selected = ipManager.selectedAddress {
                            Text(selected.name)
                                .font(.body)
                            Text("\(selected.ip):\(selected.port)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("No server selected")
                                .font(.body)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Button("Change") {
                        showingIPManager = true
                    }
                    .buttonStyle(ModernButtonStyle(backgroundColor: .blue))
                }
                
                // 快速服务器选择
                if ipManager.savedAddresses.count > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Quick Server Selection")
                            .font(.body)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(ipManager.savedAddresses) { address in
                                    Button(action: {
                                        ipManager.selectedAddress = address
                                    }) {
                                        VStack(spacing: 4) {
                                            Text(address.name)
                                                .font(.caption)
                                                .foregroundColor(address.id == ipManager.selectedAddress?.id ? .white : .primary)
                                            Text("\(address.ip):\(address.port)")
                                                .font(.caption2)
                                                .foregroundColor(address.id == ipManager.selectedAddress?.id ? .white.opacity(0.8) : .secondary)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(address.id == ipManager.selectedAddress?.id ? Color.blue : Color(.systemGray5))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(address.id == ipManager.selectedAddress?.id ? Color.blue : Color.clear, lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                    }
                }
                
                // 连接/断开按钮
                    Button(action: {
                    if connectionState.isConnected {
                            disconnectButtonTapped()
                    } else {
                            connectButtonTapped()
                        }
                    }) {
                        HStack {
                        Image(systemName: connectionState.isConnected ? "wifi.slash" : "wifi")
                        Text(connectionState.isConnected ? "Disconnect" : "Connect")
                        Spacer()
                        if isConnecting {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                }
                .buttonStyle(ModernButtonStyle(
                    backgroundColor: connectionState.isConnected ? .red : .blue
                ))
                .disabled(isConnecting || (connectionState.isDisconnected && ipManager.selectedAddress == nil))
            }
        }
        .modifier(CardStyle())
    }
    
    // MARK: - Transfer Settings Section
    private var transferSettingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "arrow.up.arrow.down")
                    .foregroundColor(.blue)
                Text("Transfer Settings")
                    .font(.headline)
            }
            
            VStack(spacing: 16) {
                // 传输开关
            Button(action: {
                manager.toggleNetworkTransfer()
            }) {
                HStack {
                        Image(systemName: manager.enableNetworkTransfer ? "network.slash" : "network")
                        Text(manager.enableNetworkTransfer ? "Stop Transfer" : "Start Transfer")
                        Spacer()
                    }
                }
                .buttonStyle(ModernButtonStyle(
                    backgroundColor: manager.enableNetworkTransfer ? .red : .green
                ))
                .disabled(!connectionState.isConnected)
                
                // Transmission frequency settings
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "speedometer")
                            .foregroundColor(.blue)
                        Text("Transmission Frequency")
                            .font(.headline)
                        Spacer()
                    }
                    
                    Text("Adjust frames per second (FPS) for data transmission")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Text("1 FPS")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Slider(
                            value: Binding(
                                get: { Float(manager.transmissionFrequency) },
                                set: { manager.transmissionFrequency = Int($0) }
                            ),
                            in: 1...30,
                            step: 1
                        )
                        Text("30 FPS")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // Display current transmission frequency
                    HStack {
                        Image(systemName: "clock")
                            .foregroundColor(.green)
                        Text("Current setting: \(manager.transmissionFrequency) FPS")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
            }
        }
        .modifier(CardStyle())
    }
    
    // MARK: - Help Tips Section
    private var helpTipsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundColor(.blue)
                Text("Help & Tips")
                    .font(.headline)
            }
            
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Depth Range")
                        .font(.body)
                        .foregroundColor(.primary)
                    Text("Adjust the minimum and maximum depth values to filter the point cloud.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Network Transfer")
                        .font(.body)
                        .foregroundColor(.primary)
                    Text("Enable to start streaming RGBD data to the selected server.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transmission Frequency")
                        .font(.body)
                        .foregroundColor(.primary)
                    Text("Lower frequency reduces data usage and improves performance.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .modifier(CardStyle())
    }
    
    // MARK: - Helper Methods
    private var connectionStateText: String {
        switch connectionState {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .disconnecting: return "Disconnecting..."
        case .disconnected: return "Disconnected"
        case .failed: return "Connection Failed"
        }
    }
    
    private func connectButtonTapped() {
        guard let selectedAddress = ipManager.selectedAddress else { return }
        
        isConnecting = true
        connectionState = .connecting
        
        DataStorage.shared.updateConnection(host_ip: selectedAddress.ip, port: selectedAddress.port) { success in
            DispatchQueue.main.async {
                if success {
                    self.connectionState = .connected
                } else {
                    self.connectionState = .failed
                }
                self.isConnecting = false
            }
        }
    }

    private func disconnectButtonTapped() {
        isConnecting = true
        connectionState = .disconnecting
        
        DataStorage.shared.disconnect()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.connectionState = .disconnected
            self.isConnecting = false
        }
    }
}

// MARK: - IP Address Manager View
struct IPAddressManagerView: View {
    @ObservedObject var ipManager: IPAddressManager
    @Environment(\.dismiss) private var dismiss
    @State private var showingAddIP = false
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(ipManager.savedAddresses) { address in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                                                    Text(address.name)
                                    .font(.body)
                                    if address.isDefault {
                                        Text("Default")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.2))
                                            .foregroundColor(.blue)
                                            .cornerRadius(4)
                                    }
                                }
                                Text("\(address.ip):\(address.port)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            if address.id == ipManager.selectedAddress?.id {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.blue)
                                    Text("Selected")
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                ipManager.selectedAddress = address
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", role: .destructive) {
                                ipManager.removeAddress(address)
                            }
                        }
                    }
                    .onDelete(perform: deleteAddresses)
                    .onMove(perform: ipManager.moveAddress)
                } header: {
                    Text("Saved Servers")
                } footer: {
                    Text("Tap a server to select it, or swipe to delete")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Server Management")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") {
                        showingAddIP = true
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddIP) {
            AddIPAddressView(ipManager: ipManager)
        }
    }
    
    private func deleteAddresses(offsets: IndexSet) {
        for index in offsets {
            let address = ipManager.savedAddresses[index]
            ipManager.removeAddress(address)
        }
    }
}

// MARK: - Add IP Address View
struct AddIPAddressView: View {
    @ObservedObject var ipManager: IPAddressManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var name = ""
    @State private var ip = ""
    @State private var port = ""
    @State private var showingError = false
    @State private var errorMessage = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section("Server Information") {
                    TextField("Server Name (e.g., Lab Computer)", text: $name)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .autocapitalization(.words)
                    
                    TextField("IP Address (e.g., 192.168.1.100)", text: $ip)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .keyboardType(.numbersAndPunctuation)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .onReceive(Just(ip)) { newValue in
                            // Auto-format IP address
                            let filtered = newValue.filter { "0123456789.".contains($0) }
                            if filtered != newValue {
                                ip = filtered
                            }
                        }
                    
                    TextField("Port (e.g., 5678)", text: $port)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .keyboardType(.numberPad)
                        .onReceive(Just(port)) { newValue in
                            // Only allow numbers
                            let filtered = newValue.filter { "0123456789".contains($0) }
                            if filtered != newValue {
                                port = filtered
                            }
                        }
                }
                
                Section {
                    Button("Save Server") {
                        saveAddress()
                    }
                    .disabled(name.isEmpty || ip.isEmpty || port.isEmpty)
                    .frame(maxWidth: .infinity)
                }
                
                Section {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        Text("Make sure your server is running and accessible from this device.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section {
                    HStack {
                        Image(systemName: "hand.draw.fill")
                            .foregroundColor(.orange)
                        Text("Tip: You can drag and drop servers to reorder them in the server list.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .alert("Invalid Input", isPresented: $showingError) {
                Button("OK") { }
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    private func saveAddress() {
        // Validate IP address format
        let ipComponents = ip.components(separatedBy: ".")
        guard ipComponents.count == 4 else {
            errorMessage = "Please enter a valid IP address (e.g., 192.168.1.100)"
            showingError = true
            return
        }
        
        for component in ipComponents {
            guard let num = Int(component), num >= 0 && num <= 255 else {
                errorMessage = "Please enter a valid IP address"
                showingError = true
                return
            }
        }
        
        // Validate port
        guard let portInt = Int(port), portInt > 0 && portInt <= 65535 else {
            errorMessage = "Please enter a valid port number (1-65535)"
            showingError = true
            return
        }
        
        // Check for duplicate IP
        if ipManager.savedAddresses.contains(where: { $0.ip == ip && $0.port == portInt }) {
            errorMessage = "A server with this IP and port already exists"
            showingError = true
            return
        }
        
        let address = SavedIPAddress(name: name, ip: ip, port: portInt)
        ipManager.addAddress(address)
        dismiss()
    }
}

// MARK: - Slider Depth Boundary View (Updated)
struct SliderDepthBoundaryView: View {
    @Binding var val: Float
    var label: String
    var minVal: Float
    var maxVal: Float
    let stepsCount = Float(200.0)
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack {
                Text(label)
                    .font(.body)
                Spacer()
                Text(String(format: "%.2f", val))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Slider(
                value: $val,
                in: minVal...maxVal,
                step: (maxVal - minVal) / stepsCount
            ) {
                Text(label)
            } minimumValueLabel: {
                Text(String(format: "%.1f", minVal))
                    .font(.caption)
            } maximumValueLabel: {
                Text(String(format: "%.1f", maxVal))
                    .font(.caption)
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .previewDevice("iPhone 12 Pro Max")
    }
}


