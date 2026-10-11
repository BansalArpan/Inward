import Foundation

struct MapPoint: Codable, Equatable {
    var x: Double
    var z: Double

    func distance(to other: MapPoint) -> Double { hypot(x - other.x, z - other.z) }
    func interpolated(to other: MapPoint, fraction: Double) -> MapPoint {
        MapPoint(x: x + (other.x - x) * fraction, z: z + (other.z - z) * fraction)
    }
}

struct MapNode: Codable, Identifiable {
    let id: String
    let x: Double
    let z: Double
    var point: MapPoint { MapPoint(x: x, z: z) }
}

struct MapRoom: Codable, Identifiable {
    let id: String
    let name: String
    let kind: String
    let node: String
    /// [minimum X, minimum Z, width, depth], meters, one floor.
    let rect: [Double]
}

struct BuildingMap: Codable {
    let version: Int
    let units: String
    let building: String
    let floor: String
    let nodes: [MapNode]
    let edges: [[String]]
    let rooms: [MapRoom]
    let demoClosure: [String]?

    var nodeLookup: [String: MapNode] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    }

    static func load(from url: URL) throws -> BuildingMap {
        let map = try JSONDecoder().decode(BuildingMap.self, from: Data(contentsOf: url))
        try map.validate()
        return map
    }

    func validate() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw MapError.invalid(message) }
        }
        try require(version == 1 && units == "m", "Use schema version 1 and meter units.")
        try require(!building.isEmpty && !floor.isEmpty, "Building and floor names are required.")
        try require((2...500).contains(nodes.count), "Provide 2–500 nodes.")
        let ids = Set(nodes.map(\.id))
        try require(ids.count == nodes.count, "Node IDs must be unique.")
        try require(nodes.allSatisfy { !$0.id.isEmpty && $0.x.isFinite && $0.z.isFinite && abs($0.x) < 10000 && abs($0.z) < 10000 }, "Node coordinates must be finite meter values.")
        let lookup = nodeLookup
        try require(edges.count <= 1500, "Maximum 1,500 edges.")
        for edge in edges {
            try require(edge.count == 2, "Each edge has two node IDs.")
            guard let a = lookup[edge[0]], let b = lookup[edge[1]] else {
                throw MapError.invalid("An edge references a missing node.")
            }
            try require(a.point.distance(to: b.point) > 0.001, "Edges must have nonzero length.")
        }
        try require((1...150).contains(rooms.count), "Provide 1–150 rooms.")
        try require(Set(rooms.map(\.id)).count == rooms.count, "Room IDs must be unique.")
        for room in rooms {
            try require(!room.id.isEmpty && !room.name.isEmpty && ids.contains(room.node), "A room needs a name, ID and valid door node.")
            try require(room.rect.count == 4, "Room rectangles contain [x, z, width, depth].")
            try require(room.rect.allSatisfy { $0.isFinite && abs($0) < 10000 } && room.rect[2] > 0 && room.rect[3] > 0, "Invalid room rectangle.")
        }
        if let closure = demoClosure {
            try require(closure.count == 2 && edges.contains { Set($0) == Set(closure) }, "The demo closure must match an edge.")
        }
    }
}

enum MapError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

struct IndoorRoute {
    let nodeIDs: [String]
    let points: [MapPoint]
    var segmentLengths: [Double] {
        zip(points, points.dropFirst()).map { $0.distance(to: $1) }
    }
    var length: Double { segmentLengths.reduce(0, +) }

    func sample(at distance: Double) -> (point: MapPoint, segment: Int, remainingInSegment: Double) {
        precondition(!points.isEmpty)
        var remaining = max(0, distance)
        for (index, length) in segmentLengths.enumerated() {
            if remaining < length {
                return (points[index].interpolated(to: points[index + 1], fraction: remaining / length), index, length - remaining)
            }
            remaining -= length
        }
        return (points[points.count - 1], max(0, points.count - 1), 0)
    }

    func instruction(for segment: Int) -> (text: String, symbol: String) {
        guard segment > 0, segment < points.count - 1 else {
            return ("Continue straight", "arrow.up")
        }
        let a = points[segment - 1], b = points[segment], c = points[segment + 1]
        let cross = (b.x - a.x) * (c.z - b.z) - (b.z - a.z) * (c.x - b.x)
        let dot = (b.x - a.x) * (c.x - b.x) + (b.z - a.z) * (c.z - b.z)
        if abs(cross) < 0.001 {
            return dot < 0 ? ("Turn around", "arrow.uturn.backward") : ("Continue straight", "arrow.up")
        }
        // X right, Z toward the bottom of a north-up schematic, Y up.
        return cross > 0 ? ("Turn right", "arrow.turn.up.right") : ("Turn left", "arrow.turn.up.left")
    }
}

enum RoutePlanner {
    static func edgeKey(_ a: String, _ b: String) -> String {
        // JSON encodes the pair without collisions from punctuation in IDs.
        String(data: try! JSONEncoder().encode([a, b].sorted()), encoding: .utf8)!
    }

    /// Dijkstra, bidirectional graph with Euclidean edge cost in meters.
    static func route(in map: BuildingMap, from start: String, to goal: String, blocked: Set<String> = []) -> IndoorRoute? {
        let nodes = map.nodeLookup
        guard nodes[start] != nil, nodes[goal] != nil else { return nil }
        var adjacency: [String: [(String, Double)]] = [:]
        for edge in map.edges where !blocked.contains(edgeKey(edge[0], edge[1])) {
            guard let a = nodes[edge[0]], let b = nodes[edge[1]] else { continue }
            let cost = a.point.distance(to: b.point)
            adjacency[a.id, default: []].append((b.id, cost))
            adjacency[b.id, default: []].append((a.id, cost))
        }
        var unvisited = Set(nodes.keys)
        var distances: [String: Double] = [start: 0]
        var previous: [String: String] = [:]
        while let u = unvisited.min(by: {
            let a = distances[$0, default: .infinity], b = distances[$1, default: .infinity]
            return a == b ? $0 < $1 : a < b
        }) {
            guard let cost = distances[u] else { break }
            unvisited.remove(u)
            if u == goal { break }
            for (v, length) in adjacency[u, default: []] where unvisited.contains(v) {
                if cost + length < distances[v, default: .infinity] {
                    distances[v] = cost + length
                    previous[v] = u
                }
            }
        }
        guard distances[goal] != nil else { return nil }
        var ids = [goal]
        while ids[0] != start {
            guard let predecessor = previous[ids[0]] else { return nil }
            ids.insert(predecessor, at: 0)
        }
        return IndoorRoute(nodeIDs: ids, points: ids.compactMap { nodes[$0]?.point })
    }
}
