import SwiftUI
import Combine
import AVFoundation
import UIKit

// Apple speech and haptic APIs:
// https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer
// https://developer.apple.com/documentation/uikit/uiimpactfeedbackgenerator

private let inwardPurple = Color(red: 0.40, green: 0.30, blue: 0.87)
private let inwardInk = Color(red: 0.13, green: 0.17, blue: 0.24)

@MainActor
private final class FavoriteRooms: ObservableObject {
    @Published private(set) var roomIDs: Set<String>
    private let defaults: UserDefaults
    private let storageKey: String

    init(building: String, floor: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // JSON prevents collisions when names contain separator characters.
        let scope = (try? JSONEncoder().encode([building, floor])) ?? Data()
        storageKey = "inward.favorites.v1." + scope.base64EncodedString()
        roomIDs = Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    func contains(_ id: String) -> Bool { roomIDs.contains(id) }

    func toggle(_ id: String) {
        if roomIDs.contains(id) { roomIDs.remove(id) }
        else { roomIDs.insert(id) }
        defaults.set(roomIDs.sorted(), forKey: storageKey)
    }
}

@MainActor
private final class NavigationFeedback: ObservableObject {
    private let speaker = AVSpeechSynthesizer()
    private let turnGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let arrivalGenerator = UINotificationFeedbackGenerator()
    private var revision = -1
    private var previousDistance: Double = 0
    private var previousSegment: Int?
    private var wasPlaying = false
    private var previousVoice = false
    private var announcedArrival = false

    init() {
        // Let iOS manage the speech audio session and interruptions.
        speaker.usesApplicationAudioSession = false
    }

    func stopSpeech() {
        speaker.stopSpeaking(at: .immediate)
    }

    func update(model: NavigationModel, voice: Bool, vibration: Bool, manualWaypoint: Bool = false) {
        if revision != model.routeRevision || model.traveled < previousDistance - 0.001 {
            stopSpeech()
            revision = model.routeRevision
            previousSegment = nil
            wasPlaying = false
            announcedArrival = false
        }
        defer {
            previousDistance = model.traveled
            previousSegment = model.currentSegment
            wasPlaying = model.isPlaying
            previousVoice = voice
        }
        if !voice && previousVoice { stopSpeech() }
        guard let route = model.route, route.length > 0 else {
            stopSpeech()
            return
        }

        if model.arrived {
            if !announcedArrival && (wasPlaying || manualWaypoint) {
                announcedArrival = true
                if vibration { arrivalGenerator.notificationOccurred(.success) }
                if voice { say("You have arrived at \(model.destination.name).") }
            }
            return
        }

        guard model.isPlaying || manualWaypoint else {
            if wasPlaying { stopSpeech() }
            return
        }

        let changedSegment = previousSegment != model.currentSegment
        let starting = model.isPlaying && !wasPlaying
        let instruction = route.instruction(for: model.currentSegment)
        if changedSegment && model.currentSegment > 0 && instruction.symbol != "arrow.up" && vibration {
            turnGenerator.impactOccurred()
        }
        if voice && (changedSegment || starting || !previousVoice || manualWaypoint) {
            let meters = Int(ceil(model.nextDistance))
            let message = instruction.symbol == "arrow.up"
                ? "Continue straight for \(meters) meters."
                : "\(instruction.text), then continue for \(meters) meters."
            say(message)
        }
        if starting && vibration {
            turnGenerator.prepare()
            arrivalGenerator.prepare()
        }
    }

    private func say(_ message: String) {
        // Replace stale directions instead of queuing them behind newer ones.
        stopSpeech()
        let utterance = AVSpeechUtterance(string: message)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speaker.speak(utterance)
    }
}

@MainActor
struct ContentView: View {
    @ObservedObject var model: NavigationModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showRooms = false
    @State private var showGuide = false
    @StateObject private var favorites: FavoriteRooms
    @StateObject private var feedback = NavigationFeedback()
    @AppStorage("inward.spokenDirections") private var spokenDirections = false
    @AppStorage("inward.turnVibrations") private var turnVibrations = true
    private let timer = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()

    init(model: NavigationModel) {
        self.model = model
        _favorites = StateObject(wrappedValue: FavoriteRooms(building: model.map.building, floor: model.map.floor))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            viewSwitcher
                .padding(.horizontal, 20).padding(.bottom, 14)

            if !favoriteRooms.isEmpty { favoriteShortcuts }

            ZStack(alignment: .topLeading) {
                IndoorSceneView(model: model)
                    .accessibilityLabel(model.mode == .overview ? "3D room map. Use room search as an accessible alternative." : "Simulated first-person walkthrough with floor arrows.")
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(model.map.floor, systemImage: "square.3.layers.3d")
                            .font(.system(size: 12, weight: .semibold))
                        Text(model.mode == .overview ? "Drag to orbit\nPinch to zoom" : "Drag to look around")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    Spacer(minLength: 4)
                    if model.mode == .walkthrough {
                        MiniMap(model: model).frame(width: 94, height: 88)
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }.padding(14).allowsHitTesting(false)
                VStack { Spacer(); HStack {
                    Label(model.mode == .overview ? "Tap a room to explore" : "Route preview · simulated movement", systemImage: "location.fill")
                        .font(.system(size: 10, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                    Spacer()
                    Button { model.recenterRevision += 1 } label: {
                        Image(systemName: "scope").font(.system(size: 20)).frame(width: 44, height: 44)
                            .background(.regularMaterial, in: Circle())
                    }.accessibilityLabel("Recenter camera")
                }}.padding(14)
            }
            .frame(minHeight: 180)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(inwardInk.opacity(0.04)))
            .padding(.horizontal, 12)
            routeCard
        }
        .background(Color(red: 0.97, green: 0.98, blue: 0.99))
        .foregroundStyle(inwardInk).tint(inwardPurple)
        .sheet(isPresented: $showRooms) { RoomSearch(model: model, favorites: favorites).presentationDragIndicator(.visible) }
        .sheet(isPresented: $showGuide) { ProjectGuide(model: model) }
        .onReceive(timer) { date in
            model.tick(date)
            feedback.update(model: model, voice: spokenDirections, vibration: turnVibrations)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.pause(); feedback.stopSpeech() }
        }
        .onChange(of: showRooms) { _, showing in
            if showing { model.pause(); feedback.stopSpeech() }
        }
        .onChange(of: showGuide) { _, showing in
            if showing { model.pause(); feedback.stopSpeech() }
        }
        .onChange(of: spokenDirections) { _, enabled in
            if !enabled { feedback.stopSpeech() }
        }
        .onDisappear { model.pause(); feedback.stopSpeech() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(inwardPurple.gradient, in: RoundedRectangle(cornerRadius: 14))
                .shadow(color: inwardPurple.opacity(0.18), radius: 8, y: 4)
            Text("inward.")
                .font(.system(size: 29, weight: .bold, design: .rounded))
                .tracking(-1)
            Spacer()
            Menu {
                Section("Directions") {
                    Toggle(isOn: $spokenDirections) {
                        Label("Spoken directions", systemImage: "speaker.wave.2")
                    }
                    Toggle(isOn: $turnVibrations) {
                        Label("Vibration cues", systemImage: "iphone.radiowaves.left.and.right")
                    }
                }
                Button("Integration guide", systemImage: "info.circle") { showGuide = true }
                if model.map.demoClosure != nil {
                    Section("Route testing") {
                        Button(model.hallwayClosed ? "Clear test closure" : "Test a hallway closure", systemImage: "exclamationmark.triangle") { model.toggleClosure() }
                    }
                }
                Button("Reset journey", systemImage: "arrow.counterclockwise") { model.reset() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.white, in: Circle())
                    .overlay(Circle().strokeBorder(inwardInk.opacity(0.06)))
            }
            .accessibilityLabel("Map options")
        }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 16)
    }

    private var viewSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(MapViewMode.allCases) { mode in
                Button { model.mode = mode } label: {
                    Label(mode.rawValue, systemImage: mode == .overview ? "square.3.layers.3d" : "figure.walk")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .foregroundStyle(model.mode == mode ? inwardPurple : inwardInk.opacity(0.55))
                        .background {
                            if model.mode == mode {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.white)
                                    .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
            }
        }
        .padding(4)
        .background(inwardInk.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Map view")
    }

    private var favoriteRooms: [MapRoom] {
        model.map.rooms.filter { favorites.contains($0.id) }
    }

    private var favoriteShortcuts: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(favoriteRooms) { room in
                    Button { model.selectDestination(room.id) } label: {
                        Label(room.name, systemImage: "star.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(room.id == model.destinationID ? inwardPurple : inwardInk.opacity(0.7))
                            .padding(.horizontal, 13).frame(minHeight: 44)
                            .background(room.id == model.destinationID ? inwardPurple.opacity(0.08) : .white, in: Capsule())
                            .overlay(Capsule().strokeBorder(inwardInk.opacity(0.05)))
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Navigate to favorite, \(room.name)")
                }
            }.padding(.horizontal, 20)
        }
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Favorite rooms")
    }

    private var routeCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center) {
                Button { showRooms = true } label: {
                    HStack(spacing: 11) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(inwardPurple)
                            .frame(width: 43, height: 43)
                            .background(inwardPurple.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.destination.name).font(.system(size: 19, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.75)
                            Text(model.destination.kind + " · " + model.map.floor).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                }.buttonStyle(.plain)
                Spacer(minLength: 8)
                if let route = model.route {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(Int(ceil(model.remaining))) m").font(.system(size: 21, weight: .bold, design: .rounded))
                        Text("~\(Int(ceil(route.length / 1.2))) sec walk").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 5) {
                Image(systemName: "smallcircle.filled.circle").foregroundStyle(inwardPurple)
                Text("From").foregroundStyle(.secondary)
                Menu {
                    ForEach(model.map.rooms) { room in Button(room.name) { model.setStart(room.id) } }
                } label: { Text(model.startRoom.name); Image(systemName: "chevron.down").font(.system(size: 9)) }
                Spacer()
                Button { spokenDirections.toggle() } label: {
                    Image(systemName: spokenDirections ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 14)).frame(width: 44, height: 44)
                        .foregroundStyle(spokenDirections ? inwardPurple : inwardInk.opacity(0.45))
                }
                .accessibilityLabel("Spoken directions")
                .accessibilityValue(spokenDirections ? "On" : "Off")
                .accessibilityHint("Double tap to toggle spoken directions")
            }
            .font(.system(size: 12))
            .frame(minHeight: 32)
            if model.hallwayClosed {
                Label("Test hallway closure active", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(red: 0.62, green: 0.34, blue: 0.10))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
            }

            HStack(spacing: 11) {
                Image(systemName: model.guidance.symbol).font(.system(size: 23, weight: .semibold))
                    .frame(width: 43, height: 43).foregroundStyle(inwardPurple)
                    .background(inwardPurple.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.guidance.text).font(.system(size: 14, weight: .semibold))
                    Text(guidanceDetail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(inwardPurple.opacity(0.045), in: RoundedRectangle(cornerRadius: 17))
            ProgressView(value: model.progress).tint(inwardPurple)
            HStack(spacing: 9) {
                Button {
                    model.playPause()
                    feedback.update(model: model, voice: spokenDirections, vibration: turnVibrations)
                } label: {
                    Label(model.isPlaying ? "Pause" : model.arrived ? "Replay" : model.traveled > 0 ? "Resume" : "Preview route", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 15)
                }
                .foregroundStyle(.white).background(inwardPurple.gradient, in: RoundedRectangle(cornerRadius: 16))
                .disabled(model.route == nil || model.route?.length == 0)
                .opacity(model.route == nil || model.route?.length == 0 ? 0.45 : 1)
                Button {
                    model.advanceWaypoint()
                    feedback.update(model: model, voice: spokenDirections, vibration: turnVibrations, manualWaypoint: true)
                } label: {
                    Image(systemName: "forward.end.fill").frame(width: 51, height: 49)
                }.background(inwardInk.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                    .disabled(model.route == nil || model.arrived).accessibilityLabel("Advance to next waypoint")
            }
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
        .background(.white)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 27, topTrailingRadius: 27))
        .padding(.top, 10)
    }

    private var guidanceDetail: String {
        if model.route == nil { return "Clear the test closure or choose another location." }
        if model.arrived { return model.destination.name + " · at the door" }
        return "\(Int(ceil(model.nextDistance))) m to the next waypoint"
    }
}

@MainActor
private struct RoomSearch: View {
    @ObservedObject var model: NavigationModel
    @ObservedObject var favorites: FavoriteRooms
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matchingRooms: [MapRoom] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.map.rooms.filter {
            search.isEmpty || ($0.name + " " + $0.kind + " " + $0.id).localizedCaseInsensitiveContains(search)
        }
    }
    private var pinned: [MapRoom] { matchingRooms.filter { favorites.contains($0.id) } }
    private var unpinned: [MapRoom] { matchingRooms.filter { !favorites.contains($0.id) } }

    var body: some View {
        NavigationStack {
            List {
                if !pinned.isEmpty {
                    Section("Favorites") { ForEach(pinned) { room in roomRow(room) } }
                }
                if !unpinned.isEmpty {
                    Section("Rooms & places") { ForEach(unpinned) { room in roomRow(room) } }
                }
            }
            .overlay {
                if matchingRooms.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.97, green: 0.98, blue: 0.99))
            .navigationTitle("Where to?")
            .searchable(text: $query, prompt: "Room number, lab, or amenity")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }.tint(inwardPurple)
    }

    private func roomRow(_ room: MapRoom) -> some View {
        HStack(spacing: 8) {
            Button { model.selectDestination(room.id); dismiss() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "door.left.hand.closed").foregroundStyle(inwardPurple)
                        .frame(width: 35, height: 39)
                        .background(inwardPurple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(room.name).font(.headline).foregroundStyle(.primary)
                        Text(room.kind + " · " + model.map.floor).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if room.id == model.destinationID {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(inwardPurple)
                    }
                }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { favorites.toggle(room.id) } label: {
                Image(systemName: favorites.contains(room.id) ? "star.fill" : "star")
                    .font(.system(size: 18))
                    .foregroundStyle(favorites.contains(room.id) ? Color.orange : Color.secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(favorites.contains(room.id) ? "Remove \(room.name) from favorites" : "Add \(room.name) to favorites")
        }.padding(.vertical, 4)
    }
}

private struct MiniMap: View {
    @ObservedObject var model: NavigationModel
    var body: some View {
        Canvas { context, size in
            let minX = min(model.map.nodes.map(\.x).min()!, model.map.rooms.map { $0.rect[0] }.min()!) - 1
            let minZ = min(model.map.nodes.map(\.z).min()!, model.map.rooms.map { $0.rect[1] }.min()!) - 1
            let maxX = max(model.map.nodes.map(\.x).max()!, model.map.rooms.map { $0.rect[0] + $0.rect[2] }.max()!) + 1
            let maxZ = max(model.map.nodes.map(\.z).max()!, model.map.rooms.map { $0.rect[1] + $0.rect[3] }.max()!) + 1
            let scale = min(size.width / (maxX - minX), size.height / (maxZ - minZ))
            func p(_ point: MapPoint) -> CGPoint { CGPoint(x: (point.x - minX) * scale, y: (point.z - minZ) * scale) }
            for room in model.map.rooms {
                let r = room.rect
                let rect = CGRect(x: (r[0] - minX) * scale, y: (r[1] - minZ) * scale, width: r[2] * scale, height: r[3] * scale)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(room.id == model.destinationID ? .orange.opacity(0.5) : .gray.opacity(0.2)))
            }
            if let route = model.route, let first = route.points.first {
                var path = Path(); path.move(to: p(first))
                for point in route.points.dropFirst() { path.addLine(to: p(point)) }
                context.stroke(path, with: .color(inwardPurple), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            let user = p(model.position)
            context.fill(Path(ellipseIn: CGRect(x: user.x - 3, y: user.y - 3, width: 6, height: 6)), with: .color(inwardPurple))
        }.accessibilityLabel("Mini map showing route and simulated position")
    }
}

private struct ProjectGuide: View {
    @ObservedObject var model: NavigationModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("What works now") {
                    Text("Bird’s-eye room selection, room search, shortest paths, floor arrows, a first-person camera, simulated walking, and hallway-closure rerouting.")
                }
                Section("Favorites & direction cues") {
                    Text("Tap the star beside a room in search to save it. Favorites appear at the top of search and in the shortcut strip above the map. Favorites are saved for this building and floor.")
                    Text("Spoken directions are off by default. Use the speaker button or Map options to turn them on. Vibration cues are on by default and can also be turned off in Map options. These preferences are saved on this device.")
                    Text("Cues follow simulated route movement: one vibration at each turn and a success cue on arrival. Pausing stops speech. Test vibration on a physical iPhone; the simulator cannot reproduce the physical sensation.")
                }
                Section("What is a test closure?") {
                    Text("The route-testing menu can block one mock hallway. The route planner then finds another path. This is a manually activated test, not a live building alert. Choose Clear test closure in Map options to reopen it.")
                }
                Section("Scan handoff") {
                    Text("RealityKit expects USD/USDZ, not glTF directly. Convert a triangle-mesh export to building.usdz and add it to the app target. Replace navigation.json with verified rooms and walkable edges in the same meter coordinate frame.")
                    Text("An optional USDZ appears in Walkthrough. Bird’s-eye stays a roofless schematic. Gaussian splats need a compatible splat renderer or a separately reconstructed mesh.")
                }
                Section("Starting position") {
                    Text("The route preview uses your selected start and a simulated pose. Production navigation needs map-aligned position AND heading, such as a surveyed marker plus ARKit tracking and a re-localization strategy.")
                    let origin = model.map.nodeLookup[model.startRoom.node]!.point
                    Text(String(format: "Simulated offset: X %+.1f m · Z %+.1f m", model.position.x - origin.x, model.position.z - origin.z))
                        .font(.system(.footnote, design: .monospaced))
                }
                Section("Room number extraction") {
                    Text("Run OCR on the original sign images, associate detections with depth and capture poses, and review the door labels. Do not infer room numbers or walkable paths from an unlabeled mesh alone.")
                }
                if let message = model.sceneMessage { Section("Scan status") { Text(message) } }
            }
            .navigationTitle("Prototype guide").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
