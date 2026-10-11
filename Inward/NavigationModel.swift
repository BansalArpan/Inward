import SwiftUI
import Combine

enum MapViewMode: String, CaseIterable, Identifiable {
    case overview = "Bird’s-eye"
    case walkthrough = "Walkthrough"
    var id: String { rawValue }
}

@MainActor
final class NavigationModel: ObservableObject {
    let map: BuildingMap
    @Published var mode: MapViewMode = .overview
    @Published var startID: String
    @Published var destinationID: String
    @Published private(set) var route: IndoorRoute?
    @Published private(set) var traveled: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var hallwayClosed = false
    @Published private(set) var routeRevision = 0
    @Published var sceneMessage: String?
    @Published var hasScan = false
    @Published var recenterRevision = 0
    private var lastTick: Date?

    init(map: BuildingMap) {
        self.map = map
        startID = map.rooms.first(where: { $0.id == "entry" })?.id ?? map.rooms[0].id
        destinationID = map.rooms.first(where: { $0.id == "103" })?.id ?? map.rooms.last!.id
        recalculate()
    }

    var startRoom: MapRoom { map.rooms.first { $0.id == startID }! }
    var destination: MapRoom { map.rooms.first { $0.id == destinationID }! }
    var remaining: Double { max(0, (route?.length ?? 0) - traveled) }
    var arrived: Bool { route != nil && remaining < 0.001 }
    var position: MapPoint {
        route?.sample(at: traveled).point ?? map.nodeLookup[startRoom.node]!.point
    }
    var currentSegment: Int { route?.sample(at: traveled).segment ?? 0 }
    var nextDistance: Double { route?.sample(at: traveled).remainingInSegment ?? 0 }
    var progress: Double {
        guard let route else { return 0 }
        return route.length == 0 ? 1 : min(1, traveled / route.length)
    }
    var guidance: (text: String, symbol: String) {
        guard let route else { return ("No available route", "exclamationmark.triangle") }
        if arrived { return ("You’ve arrived", "checkmark") }
        return route.instruction(for: currentSegment)
    }
    var heading: MapPoint {
        guard let route, route.points.count > 1 else { return MapPoint(x: 0, z: -1) }
        let i = min(currentSegment, route.points.count - 2)
        let a = route.points[i], b = route.points[i + 1]
        let length = a.distance(to: b)
        return MapPoint(x: (b.x - a.x) / length, z: (b.z - a.z) / length)
    }
    var blockedEdges: Set<String> {
        guard hallwayClosed, let edge = map.demoClosure else { return [] }
        return [RoutePlanner.edgeKey(edge[0], edge[1])]
    }

    func setStart(_ id: String) {
        guard map.rooms.contains(where: { $0.id == id }) else { return }
        startID = id; recalculate()
    }
    func selectDestination(_ id: String) {
        guard map.rooms.contains(where: { $0.id == id }) else { return }
        destinationID = id; recalculate()
    }
    func toggleClosure() {
        hallwayClosed.toggle(); recalculate()
    }
    func recalculate() {
        isPlaying = false; traveled = 0; lastTick = nil
        route = RoutePlanner.route(in: map, from: startRoom.node, to: destination.node, blocked: blockedEdges)
        routeRevision += 1
    }
    func playPause() {
        guard let route, route.length > 0 else { return }
        if arrived { traveled = 0 }
        isPlaying.toggle(); lastTick = nil
    }
    func pause() { isPlaying = false; lastTick = nil }
    func reset() { pause(); traveled = 0; recenterRevision += 1 }
    func advanceWaypoint() {
        pause()
        guard let route, !arrived else { return }
        traveled = min(route.length, route.segmentLengths.prefix(currentSegment + 1).reduce(0, +))
    }
    func tick(_ date: Date) {
        guard isPlaying, let route else { lastTick = nil; return }
        defer { lastTick = date }
        guard let lastTick else { return }
        // This is explicitly a simulation, not estimated live phone position.
        traveled = min(route.length, traveled + min(0.1, max(0, date.timeIntervalSince(lastTick))) * 1.6)
        if arrived { isPlaying = false }
    }
}
