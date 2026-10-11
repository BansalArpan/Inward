import SwiftUI
import RealityKit
import UIKit
import Combine
import simd
import UniformTypeIdentifiers

/*
 Inward indoor navigator — iOS 17+, no third-party dependencies.
 Replace the previous BuildingEditorView.swift; keep BuildingEditorView() as
 the existing app entry point. This phone view is now read-only.
 Design/edit buildings in InwardStudio.html, then import JSON versions 2–4.
 The working Files-copy, paste-text and app-bundle import options are retained.
 Existing saved geometry remains in Application Support/Inward/building-transfer-v2.json.
 Bird’s-eye and 3D views share the imported room and hallway geometry.
 Navigation searches walkable rooms/hallways around walls and doorway gaps.
 Walking is a simulation from a selected location, not sensor-based positioning.
 Routes retry on 25 cm then 10 cm grids, using wall thickness plus 12 cm clearance.
 The starter trace is approximate and not a surveyed building plan.
*/

private enum DisplayDistance {
    static func feet(_ meters: Double) -> String {
        (meters / 0.3048).formatted(.number.precision(.fractionLength(1))) + " ft"
    }
}

private let builderPurple = Color(red: 0.40, green: 0.30, blue: 0.87)
private let builderInk = Color(red: 0.13, green: 0.17, blue: 0.24)

// MARK: - Screenshot trace shared by the 2D and 3D views

private struct HallwayPoint: Codable, Equatable, Sendable {
    var x: Double
    var z: Double
    var cg: CGPoint { CGPoint(x: x, y: z) }
}

private struct BuilderHallway: Codable, Equatable, Sendable {
    var id: UUID? = UUID()
    var name: String? = "Hallway"
    var vertices: [HallwayPoint]
    var doors: [Door]
    var openEdges: [Int]? = nil
    static let doorWidth: Double = 1.5
    var outline: [CGPoint] { vertices.map(\.cg) }

    struct Door: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var name: String
        var edge: Int
        var fraction: Double
        func center(in points: [CGPoint]) -> CGPoint {
            let a = points[edge], b = points[(edge + 1) % points.count]
            return CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
        }
        func offset(in points: [CGPoint]) -> CGPoint {
            let a = points[edge], b = points[(edge + 1) % points.count]
            let length = hypot(b.x - a.x, b.y - a.y)
            return CGPoint(x: (b.y - a.y) / length * 1.7, y: -(b.x - a.x) / length * 1.7)
        }
    }
    static let sample = BuilderHallway(vertices: [
        HallwayPoint(x: 19.68468468468468, z: 48.19819819819820),
        HallwayPoint(x: 79.68468468468468, z: 48.19819819819820),
        HallwayPoint(x: 79.68468468468468, z: 40.00000000000000),
        HallwayPoint(x: 82.38738738738739, z: 40.00000000000000),
        HallwayPoint(x: 82.38738738738739, z: 45.67567567567568),
        HallwayPoint(x: 93.37837837837837, z: 45.67567567567568),
        HallwayPoint(x: 93.37837837837837, z: 53.06306306306306),
        HallwayPoint(x: 79.68468468468468, z: 53.06306306306306),
        HallwayPoint(x: 79.68468468468468, z: 51.08108108108108),
        HallwayPoint(x: 20.58558558558558, z: 51.08108108108108),
        HallwayPoint(x: 18.60360360360360, z: 53.06306306306306),
        HallwayPoint(x: 16.44144144144144, z: 50.90090090090090),
        HallwayPoint(x: 17.70270270270270, z: 49.63963963963964),
        HallwayPoint(x: 15.00000000000000, z: 46.93693693693694),
        HallwayPoint(x: 16.98198198198198, z: 44.95495495495496)
    ], doors: [
        Door(id: UUID(uuidString: "5BFA67A2-4863-4EC9-90E9-F2A753CEB8F2")!, name: "2A01", edge: 2, fraction: 0.5000000000000000),
        Door(id: UUID(uuidString: "014CF1F9-5260-4CCB-B3B8-B04258AD227A")!, name: "2B46", edge: 0, fraction: 0.0525525525525526),
        Door(id: UUID(uuidString: "820C2190-1F1A-408B-BDBB-68594D19F3A7")!, name: "2B44", edge: 0, fraction: 0.1291291291291291),
        Door(id: UUID(uuidString: "279DCCBE-A645-47F3-9A45-7736507FA4E3")!, name: "2B40", edge: 0, fraction: 0.2117117117117117),
        Door(id: UUID(uuidString: "03359686-1B49-4C20-9BA8-DB6879C0684F")!, name: "2B36", edge: 0, fraction: 0.3483483483483483),
        Door(id: UUID(uuidString: "C8F39954-D6CD-441E-B780-7583A388FD98")!, name: "2B30", edge: 0, fraction: 0.5555555555555556),
        Door(id: UUID(uuidString: "EE30124D-99D4-4504-B0D5-140D442B185F")!, name: "2B24", edge: 0, fraction: 0.6756756756756757),
        Door(id: UUID(uuidString: "FE60EEC8-8176-40E4-A844-6290A2ED13B9")!, name: "2B15", edge: 8, fraction: 0.1402439024390244),
        Door(id: UUID(uuidString: "86BC160B-C655-4684-9198-7BD4C340F158")!, name: "2B19", edge: 8, fraction: 0.2545731707317073),
        Door(id: UUID(uuidString: "55E49C2F-DFF8-41EB-B75D-378823FBC760")!, name: "2B25", edge: 8, fraction: 0.3414634146341464),
        Door(id: UUID(uuidString: "7B97EF4D-A020-42E8-BC94-DBA8641370B1")!, name: "2B29", edge: 8, fraction: 0.4161585365853658),
        Door(id: UUID(uuidString: "5946E415-7288-4E2D-B51A-E7AFF923E7D0")!, name: "2B33", edge: 8, fraction: 0.5487804878048781),
        Door(id: UUID(uuidString: "74F88C4D-A59B-4220-AD67-3770ADA0DBA8")!, name: "2B37", edge: 8, fraction: 0.6615853658536586),
        Door(id: UUID(uuidString: "635404EB-D49D-4AA2-B8F7-BABB4B366D0D")!, name: "2B41", edge: 8, fraction: 0.7774390243902439),
        Door(id: UUID(uuidString: "BC9DE4DE-D8A5-49BA-867B-D2D3EF1E0E8E")!, name: "2B47", edge: 8, fraction: 0.9359756097560976),
        Door(id: UUID(uuidString: "CE339279-70D4-4E6A-AAD2-FF347CBE0669")!, name: "2B51", edge: 9, fraction: 0.5000000000000000)
    ])

    func path(scale: CGFloat) -> Path {
        var path = Path()
        guard !outline.isEmpty else { return path }
        path.move(to: CGPoint(x: outline[0].x * scale, y: outline[0].y * scale))
        for p in outline.dropFirst() { path.addLine(to: CGPoint(x: p.x * scale, y: p.y * scale)) }
        path.closeSubpath()
        return path
    }

    // Split every boundary edge at its door intervals; both renderers use
    // these same segments, so openings have identical dimensions in 2D/3D.
    var walls: [(CGPoint, CGPoint)] {
        var result: [(CGPoint, CGPoint)] = []
        for i in outline.indices {
            if (openEdges ?? []).contains(i) { continue }
            let a = outline[i], b = outline[(i + 1) % outline.count]
            let length = hypot(b.x - a.x, b.y - a.y)
            let half = CGFloat(Self.doorWidth) / (2 * length)
            func at(_ t: CGFloat) -> CGPoint {
                CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            var cursor: CGFloat = 0
            for door in doors.filter({ $0.edge == i }).sorted(by: { $0.fraction < $1.fraction }) {
                let left = max(0, CGFloat(door.fraction) - half)
                let right = min(1, CGFloat(door.fraction) + half)
                if left > cursor { result.append((at(cursor), at(left))) }
                cursor = max(cursor, right)
            }
            if cursor < 1 { result.append((at(cursor), b)) }
        }
        return result
    }

    private func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        (b.x-a.x)*(c.y-a.y) - (b.y-a.y)*(c.x-a.x)
    }
    // Positive area is clockwise on the X/Z floor-plan screen.
    var signedArea: CGFloat {
        guard outline.count >= 3 else { return 0 }
        return outline.indices.reduce(0) { total, i in
            let a = outline[i], b = outline[(i+1) % outline.count]
            return total + (a.x*b.y-a.y*b.x)/2
        }
    }
    func isValid(width: Double, depth: Double) -> Bool {
        let points = outline, n = vertices.count
        if n == 0 { return doors.isEmpty && (openEdges ?? []).isEmpty }
        let open = openEdges ?? []
        guard Set(open).count == open.count, open.allSatisfy({ (0..<n).contains($0) }) else { return false }
        guard (3...200).contains(n), doors.count <= 200,
              vertices.allSatisfy({ $0.x.isFinite && $0.z.isFinite && $0.x >= -0.000001 && $0.z >= -0.000001 && $0.x <= width+0.000001 && $0.z <= depth+0.000001 }),
              signedArea > 0.01, Set(doors.map(\.id)).count == doors.count else { return false }
        func onSegment(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> Bool {
            abs(cross(a,b,p)) < 0.0000001 && p.x >= min(a.x,b.x)-0.0000001 &&
            p.x <= max(a.x,b.x)+0.0000001 && p.y >= min(a.y,b.y)-0.0000001 && p.y <= max(a.y,b.y)+0.0000001
        }
        for i in 0..<n {
            let a = points[i], b = points[(i+1)%n]
            guard hypot(b.x-a.x,b.y-a.y) >= 0.1-0.000000001 else { return false }
            for j in (i+1)..<n where j != (i+1)%n && (j+1)%n != i {
                let c = points[j], d = points[(j+1)%n]
                let crosses = cross(a,b,c)*cross(a,b,d) < 0 && cross(c,d,a)*cross(c,d,b) < 0
                if crosses || onSegment(a,b,c) || onSegment(a,b,d) || onSegment(c,d,a) || onSegment(c,d,b) { return false }
            }
        }
        for door in doors {
            guard (0..<n).contains(door.edge), !open.contains(door.edge), door.fraction.isFinite, !door.name.isEmpty, door.name.count <= 60 else { return false }
            let a = points[door.edge], b = points[(door.edge+1)%n]
            let length = Double(hypot(b.x-a.x,b.y-a.y))
            guard door.fraction * length >= 0.75-0.000001,
                  (1-door.fraction) * length >= 0.75-0.000001 else { return false }
        }
        for i in 0..<n {
            let sorted = doors.filter { $0.edge == i }.sorted { $0.fraction < $1.fraction }
            let a = points[i], b = points[(i+1)%n]
            let length = Double(hypot(b.x-a.x,b.y-a.y))
            for (a,b) in zip(sorted,sorted.dropFirst()) where (b.fraction-a.fraction)*length < Self.doorWidth-0.000001 { return false }
        }
        return triangles != nil
    }
    // Ear clipping triangulates the imported outline, rather than using a
    // hard-coded triangle list tied to the starter layout.
    var triangles: [UInt32]? {
        let p = outline
        guard p.count >= 3 else { return nil }
        var remaining = Array(p.indices), result: [UInt32] = []
        while remaining.count > 3 {
            var clipped = false
            for k in remaining.indices {
                let a = remaining[(k+remaining.count-1)%remaining.count]
                let b = remaining[k], c = remaining[(k+1)%remaining.count]
                guard cross(p[a],p[b],p[c]) > 0.00000001 else { continue }
                let contains = remaining.contains { v in
                    v != a && v != b && v != c && cross(p[a],p[b],p[v]) >= -0.00000001 &&
                    cross(p[b],p[c],p[v]) >= -0.00000001 && cross(p[c],p[a],p[v]) >= -0.00000001
                }
                if contains { continue }
                result += [UInt32(a), UInt32(c), UInt32(b)] // Y-up winding
                remaining.remove(at: k); clipped = true; break
            }
            if !clipped { return nil }
        }
        result += [UInt32(remaining[0]),UInt32(remaining[2]),UInt32(remaining[1])]
        return result
    }
}

// MARK: - Draft data (independent of the navigation fixture)

private enum BuilderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case floor, wall, room
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .floor: return "square.3.layers.3d"
        case .wall: return "rectangle.split.3x1"
        case .room: return "door.left.hand.closed"
        }
    }
}

private enum BuilderDoorSide: String, Codable, CaseIterable, Identifiable, Sendable {
    case top, right, bottom, left
    var id: String { rawValue }
}

private struct BuilderPiece: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var kind: BuilderKind
    var name: String
    var x: Double
    var z: Double
    var width: Double
    var depth: Double
    // Optional fields preserve decoding of version 2/3 rectangular pieces.
    var vertices: [HallwayPoint]? = nil // normalized local coordinates, 0...1
    var rotation: Double? = nil // clockwise degrees in the X/Z plan
    var roomDoorEdge: Int? = nil
    var angle: Double { rotation ?? 0 }
    var localOutline: [CGPoint] {
        vertices?.map { CGPoint(x: $0.x * width, y: $0.z * depth) } ??
        [CGPoint.zero, CGPoint(x: width, y: 0), CGPoint(x: width, y: depth), CGPoint(x: 0, y: depth)]
    }
    func worldPoint(_ p: CGPoint) -> CGPoint {
        let a = angle * .pi / 180, c = cos(a), s = sin(a)
        let px = Double(p.x) - width/2, pz = Double(p.y) - depth/2
        return CGPoint(x: x+width/2+px*c-pz*s, y: z+depth/2+px*s+pz*c)
    }
    var worldOutline: [CGPoint] { localOutline.map { worldPoint($0) } }
    var localPath: Path {
        Path { path in
            guard let first = localOutline.first else { return }
            path.move(to: first); for p in localOutline.dropFirst() { path.addLine(to: p) }; path.closeSubpath()
        }
    }
    func validGeometry(boardWidth: Double, boardDepth: Double) -> Bool {
        guard angle.isFinite, abs(angle) <= 360000,
              worldOutline.allSatisfy({ $0.x >= -0.000001 && $0.y >= -0.000001 && $0.x <= boardWidth+0.000001 && $0.y <= boardDepth+0.000001 }) else { return false }
        if let edge = roomDoorEdge, !(0..<localOutline.count).contains(edge) { return false }
        if let vertices {
            guard kind == .room, (3...200).contains(vertices.count), vertices.allSatisfy({ $0.x.isFinite && $0.z.isFinite && (0...1).contains($0.x) && (0...1).contains($0.z) }) else { return false }
            let h = BuilderHallway(vertices: worldOutline.map { HallwayPoint(x: Double($0.x), z: Double($0.y)) }, doors: [])
            return h.isValid(width: boardWidth, depth: boardDepth)
        }
        return true
    }
    var doorSide: BuilderDoorSide? = .top
    var doorEdge: Int {
        if let roomDoorEdge { return roomDoorEdge }
        switch doorSide ?? .top {
        case .top: return 0
        case .right: return 1
        case .bottom: return 2
        case .left: return 3
        }
    }
    var doorFits: Bool {
        guard (0..<localOutline.count).contains(doorEdge) else { return false }
        let a = localOutline[doorEdge], b = localOutline[(doorEdge+1)%localOutline.count]
        return hypot(b.x-a.x, b.y-a.y) >= BuilderHallway.doorWidth
    }
    // Room-local wall coordinates, shared by both renderers.
    var roomWalls: [(CGPoint, CGPoint)] {
        let corners = localOutline
        var walls: [(CGPoint, CGPoint)] = []
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            if i == doorEdge && doorFits {
                let length = hypot(b.x - a.x, b.y - a.y)
                let left = (length - CGFloat(BuilderHallway.doorWidth)) / (2 * length)
                let right = 1 - left
                func at(_ t: CGFloat) -> CGPoint {
                    CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                }
                if left > 0 { walls.append((a, at(left))); walls.append((at(right), b)) }
            } else { walls.append((a, b)) }
        }
        return walls
    }
    var rect: CGRect { CGRect(x: x, y: z, width: width, height: depth) }
    var minimum: Double { 0.1 }

    mutating func constrain(boardWidth: Double, boardDepth: Double) {
        // Keep the complete footprint inside the imported board.
        width = min(boardWidth, max(minimum, width))
        depth = min(boardDepth, max(minimum, depth))
        let points = worldOutline
        let minX = Double(points.map(\.x).min() ?? 0), maxX = Double(points.map(\.x).max() ?? 0)
        let minZ = Double(points.map(\.y).min() ?? 0), maxZ = Double(points.map(\.y).max() ?? 0)
        if minX < 0 { x -= minX }; if maxX > boardWidth { x -= maxX-boardWidth }
        if minZ < 0 { z -= minZ }; if maxZ > boardDepth { z -= maxZ-boardDepth }
        x = max(0,x); z = max(0,z)
    }
}

// Exterior boundary of the union; shared and overlapping walls disappear.
private enum HallwayUnion {
    typealias Segment = (CGPoint, CGPoint)
    static func mix(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x-a.x)*t, y: a.y + (b.y-a.y)*t)
    }
    static func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        (b.x-a.x)*(c.y-a.y) - (b.y-a.y)*(c.x-a.x)
    }
    static func contains(_ p: CGPoint, _ halls: [BuilderHallway]) -> Bool {
        halls.contains { h in
            let v = h.outline
            guard !v.isEmpty else { return false }
            var inside = false, j = v.count-1
            for i in v.indices {
                let a = v[i], b = v[j]
                if (a.y > p.y) != (b.y > p.y), p.x < (b.x-a.x)*(p.y-a.y)/(b.y-a.y)+a.x { inside.toggle() }
                j = i
            }
            return inside
        }
    }
    static func exterior(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint, _ halls: [BuilderHallway]) -> Bool {
        let l = hypot(b.x-a.x, b.y-a.y)
        guard l > 0 else { return false }
        let nx = -(b.y-a.y)/l*0.000001, ny = (b.x-a.x)/l*0.000001
        return contains(CGPoint(x:p.x+nx,y:p.y+ny), halls) != contains(CGPoint(x:p.x-nx,y:p.y-ny), halls)
    }
    static func visible(_ door: BuilderHallway.Door, in h: BuilderHallway, halls: [BuilderHallway]) -> Bool {
        exterior(h.outline[door.edge], h.outline[(door.edge+1)%h.vertices.count], door.center(in:h.outline), halls)
    }
    static func onSegment(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> Bool {
        abs(cross(a,b,p)) < 0.0000001 && p.x >= min(a.x,b.x)-0.0000001 && p.x <= max(a.x,b.x)+0.0000001 && p.y >= min(a.y,b.y)-0.0000001 && p.y <= max(a.y,b.y)+0.0000001
    }
    static func walls(_ halls: [BuilderHallway]) -> [Segment] {
        var edges: [Segment] = [], gaps: [Segment] = []
        for h in halls {
            let v = h.outline
            for i in v.indices {
                let a = v[i], b = v[(i+1)%v.count], l = hypot(b.x-a.x,b.y-a.y)
                edges.append((a,b))
                if (h.openEdges ?? []).contains(i) { gaps.append((a,b)) }
                for d in h.doors where d.edge == i {
                    gaps.append((mix(a,b,CGFloat(d.fraction)-0.75/l),mix(a,b,CGFloat(d.fraction)+0.75/l)))
                }
            }
        }
        var result: [Segment] = [], seen = Set<String>()
        for (a,b) in edges {
            let dx = b.x-a.x, dy = b.y-a.y, len2 = dx*dx+dy*dy
            if len2 < 1e-12 { continue }
            var cuts: [CGFloat] = [0,1]
            for (c,d) in edges + gaps {
                let ex = d.x-c.x, ey = d.y-c.y, den = dx*ey-dy*ex
                if abs(den) > 1e-10 {
                    let t = ((c.x-a.x)*ey-(c.y-a.y)*ex)/den
                    let u = ((c.x-a.x)*dy-(c.y-a.y)*dx)/den
                    if t > 0 && t < 1 && u >= -1e-8 && u <= 1+1e-8 { cuts.append(t) }
                } else if abs(cross(a,b,c)) < 1e-7 {
                    for p in [c,d] {
                        let t = ((p.x-a.x)*dx+(p.y-a.y)*dy)/len2
                        if t > 0 && t < 1 { cuts.append(t) }
                    }
                }
            }
            cuts.sort()
            var unique: [CGFloat] = []
            for t in cuts { if unique.last.map({ t-$0 > 1e-9 }) ?? true { unique.append(t) } }
            for i in 1..<unique.count {
                let start = mix(a,b,unique[i-1]), end = mix(a,b,unique[i]), mid = mix(start,end,0.5)
                if hypot(end.x-start.x,end.y-start.y) < 1e-7 || !exterior(a,b,mid,halls) || gaps.contains(where: { onSegment($0.0,$0.1,mid) }) { continue }
                let key = [start,end].map { "\(Int64(($0.x*1e6).rounded())),\(Int64(($0.y*1e6).rounded()))" }.sorted().joined(separator:"|")
                if seen.insert(key).inserted { result.append((start,end)) }
            }
        }
        return result
    }
}

private struct BuilderDraft: Codable, Equatable, Sendable {
    var version = 4
    var units = "m"
    var gridSize: Double = 100 // Legacy square-board fallback.
    var boardWidth: Double? = nil
    var boardDepth: Double? = nil
    var width: Double { boardWidth ?? gridSize }
    var depth: Double { boardDepth ?? gridSize }
    var hallways = [BuilderHallway.sample]
    var pieces: [BuilderPiece] = []

    enum CodingKeys: String, CodingKey { case version, units, gridSize, boardWidth, boardDepth, hallways, hallway, pieces }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        units = try c.decode(String.self, forKey: .units)
        gridSize = try c.decode(Double.self, forKey: .gridSize)
        boardWidth = try c.decodeIfPresent(Double.self, forKey: .boardWidth)
        boardDepth = try c.decodeIfPresent(Double.self, forKey: .boardDepth)
        pieces = try c.decode([BuilderPiece].self, forKey: .pieces)
        if version == 2 {
            var old = try c.decode(BuilderHallway.self, forKey: .hallway)
            guard old.isValid(width: width, depth: depth) else {
                throw DecodingError.dataCorruptedError(forKey: .hallway, in: c, debugDescription: "Invalid legacy hallway")
            }
            old.id = old.id ?? UUID(); old.name = old.name ?? "Imported hallway"
            hallways = old.vertices.isEmpty ? [] : [old]; version = 4
        } else { hallways = try c.decode([BuilderHallway].self, forKey: .hallways); if version == 3 { version = 4 } }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(units, forKey: .units)
        try c.encode(gridSize, forKey: .gridSize)
        try c.encodeIfPresent(boardWidth, forKey: .boardWidth)
        try c.encodeIfPresent(boardDepth, forKey: .boardDepth)
        try c.encode(hallways, forKey: .hallways); try c.encode(pieces, forKey: .pieces)
    }

    var isValid: Bool {
        version == 4 && units == "m" && gridSize.isFinite && width.isFinite && depth.isFinite &&
        (1...10000).contains(width) && (1...10000).contains(depth) &&
        hallways.count <= 50 && hallways.reduce(0, { $0 + $1.vertices.count }) <= 500 &&
        Set(hallways.compactMap(\.id)).count == hallways.count &&
        hallways.allSatisfy { $0.id != nil && !($0.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ($0.name ?? "").count <= 60 && !$0.vertices.isEmpty && $0.isValid(width: width, depth: depth) } && pieces.count <= 200 &&
        Set(pieces.map(\.id)).count == pieces.count && pieces.allSatisfy {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 60 &&
            [$0.x, $0.z, $0.width, $0.depth].allSatisfy(\.isFinite) &&
            $0.x >= 0 && $0.z >= 0 && $0.width >= $0.minimum &&
            $0.depth >= $0.minimum && $0.validGeometry(boardWidth: width, boardDepth: depth)
        }
    }
}

@MainActor
private final class BuilderStore: ObservableObject {
    @Published var draft = BuilderDraft()
    @Published var error: String?
    @Published var status = "Saved on this iPhone"
    private var loadingFailed = false

    private func fileURL() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
                                              in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = root.appendingPathComponent("Inward", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("building-transfer-v2.json")
    }

    init() {
        do {
            let url = try fileURL()
            if FileManager.default.fileExists(atPath: url.path) {
                let loaded = try JSONDecoder().decode(BuilderDraft.self, from: Data(contentsOf: url))
                guard loaded.isValid else {
                    throw NSError(domain: "InwardBuilder", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "The saved draft has unsupported or invalid geometry."])
                }
                draft = loaded
            } else {
                // Carry over editable pieces from the previous phone editor.
                // The old file remains untouched; subsequent saves use version 4.
                let legacyURL = url.deletingLastPathComponent().appendingPathComponent("building-swearingen-lower-v1.json")
                if FileManager.default.fileExists(atPath: legacyURL.path) {
                    struct LegacyDraft: Decodable {
                        let version: Int
                        let units: String
                        let pieces: [BuilderPiece]
                    }
                    let old = try JSONDecoder().decode(LegacyDraft.self, from: Data(contentsOf: legacyURL))
                    var migrated = BuilderDraft(); migrated.pieces = old.pieces
                    guard old.version == 1, old.units == "m", migrated.isValid else {
                        throw importError("The earlier saved draft could not be migrated. Import a valid building JSON to continue.")
                    }
                    draft = migrated
                }
                save()
            }
        } catch {
            loadingFailed = true
            status = "Draft could not load"
            self.error = "\(error.localizedDescription) The saved file will not be overwritten."
        }
    }

    func save() {
        guard !loadingFailed else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var saved = draft
            for i in saved.pieces.indices where saved.pieces[i].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                saved.pieces[i].name = saved.pieces[i].kind.title
            }
            try encoder.encode(saved).write(to: fileURL(), options: .atomic)
            status = "Saved on this iPhone"
        } catch {
            status = "Changes not saved"
            self.error = error.localizedDescription
        }
    }

    func decodeImport(_ data: Data) throws -> BuilderDraft {
        guard !data.isEmpty else { throw importError("The file is empty. Export building.json again.") }
        guard data.count <= 2_000_000 else { throw importError("Maximum building size is 2 MB.") }
        let imported: BuilderDraft
        do { imported = try JSONDecoder().decode(BuilderDraft.self, from: data) }
        catch let DecodingError.keyNotFound(key, context) {
            let path = (context.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: ".")
            throw importError("Missing field: \(path). Select the building.json exported by Inward Studio.")
        } catch let DecodingError.typeMismatch(_, context) {
            throw importError("Incorrect value at \(context.codingPath.map(\.stringValue).joined(separator: ".")). \(context.debugDescription)")
        } catch let DecodingError.dataCorrupted(context) {
            throw importError("Cannot decode building JSON: \(context.debugDescription)")
        } catch { throw importError("Cannot decode building JSON: \(error.localizedDescription)") }
        guard imported.isValid else {
            throw importError("JSON was read, but the building is invalid. Supported versions: 2, 3, 4. Check board bounds, crossing walls, room corners and doorway spacing in Inward Studio, then export again.")
        }
        return imported
    }
    func importError(_ message: String) -> NSError {
        NSError(domain: "InwardImport", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    func useImport(_ imported: BuilderDraft) -> Bool {
        do {
            guard imported.isValid else { throw importError("Invalid building data.") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(imported).write(to: fileURL(), options: .atomic)
            draft = imported; loadingFailed = false; status = "Imported & saved on this iPhone"
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

}

// MARK: - Import without open-in-place file dependencies

private enum BuilderImportFile {
    static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            result = Result {
                // Bounded stream: reject oversized/non-file inputs without mapping them.
                guard let stream = InputStream(url: readable) else {
                    throw NSError(domain: "InwardImport", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot open this file. Try Paste JSON instead."])
                }
                stream.open(); defer { stream.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 16384)
                while true {
                    let count = stream.read(&buffer, maxLength: 16384)
                    if count < 0 { throw stream.streamError ?? NSError(domain: "InwardImport", code: 3, userInfo: [NSLocalizedDescriptionKey: "The file could not be read."]) }
                    if count == 0 { break }
                    guard data.count + count <= 2_000_000 else {
                        throw NSError(domain: "InwardImport", code: 4, userInfo: [NSLocalizedDescriptionKey: "Maximum building size is 2 MB."])
                    }
                    data.append(contentsOf: buffer.prefix(count))
                }
                return data
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw NSError(domain: "InwardImport", code: 5, userInfo: [NSLocalizedDescriptionKey: "The file provider did not supply data. Use Paste JSON or the bundled-file option."]) }
        return try result.get()
    }
}

@MainActor
private struct BuilderJSONPicker: UIViewControllerRepresentable {
    let completion: (Result<Data, Error>?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Copy into the app's temporary storage; do not retain a provider URL.
        // Broad filtering also accepts JSON files with generic provider metadata.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .content], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Result<Data, Error>?) -> Void
        init(completion: @escaping (Result<Data, Error>?) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { completion(nil); return }
            // asCopy has already materialized the document. Read it before dismissal.
            completion(Result { try BuilderImportFile.read(url) })
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(nil) }
    }
}

@MainActor
private struct BuilderImportSheet: View {
    @ObservedObject var store: BuilderStore
    let onImported: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var pickerResult: Result<Data, Error>?
    @State private var jsonText = ""
    @State private var candidate: BuilderDraft?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Choose a file") {
                    Button("Choose building.json from Files", systemImage: "doc") {
                        candidate = nil; message = nil; pickerResult = nil; showPicker = true
                    }
                    Text("The selected file is copied into the app before reading. JSON exported by Inward Studio versions 2–4 is supported.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Paste JSON — no file picker needed") {
                    Text("Copy the complete contents of building.json, then touch and hold below and choose Paste.")
                        .font(.caption)
                    TextEditor(text: $jsonText)
                        .font(.system(.caption, design: .monospaced))
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .frame(minHeight: 150)
                        .accessibilityLabel("Building JSON text")
                    Button("Check pasted JSON") { check(Data(jsonText.utf8)) }
                        .disabled(jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("Import from Xcode bundle") {
                    Button("Load bundled building.json") {
                        candidate = nil
                        guard let url = Bundle.main.url(forResource: "building", withExtension: "json") else {
                            message = "Add your exported building.json to the Xcode project, enable the Inward target, and ensure it appears in Copy Bundle Resources. Build and run again, then tap this button."
                            return
                        }
                        do { check(try BuilderImportFile.read(url)) }
                        catch { report(error) }
                    }
                    Text("This option works without the Files picker. It requires adding the JSON to the app target and rebuilding.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message {
                    Section("Import details") { Text(message).foregroundStyle(.red).textSelection(.enabled) }
                }
                if let candidate {
                    Section("Ready to import") {
                        Text("\(candidate.hallways.count) hallways · \(candidate.pieces.count) pieces · \(DisplayDistance.feet(candidate.width)) × \(DisplayDistance.feet(candidate.depth))")
                        Text("Import replaces the current layout and saves this building on your iPhone.").font(.caption)
                        Button("Import this building", systemImage: "square.and.arrow.down") {
                            if store.useImport(candidate) { onImported(); dismiss() }
                            else { message = store.error ?? "The building could not be saved."; store.error = nil }
                        }
                    }
                }
            }
            .navigationTitle("Import building")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(isPresented: $showPicker, onDismiss: consumePickedFile) {
                BuilderJSONPicker { result in pickerResult = result; showPicker = false }
            }
            .onChange(of: jsonText) { _, _ in candidate = nil; message = nil }
        }
    }
    private func consumePickedFile() {
        guard let result = pickerResult else { return }
        pickerResult = nil
        switch result {
        case .success(let data): check(data)
        case .failure(let error): report(error)
        }
    }
    private func check(_ data: Data) {
        candidate = nil; message = nil
        do { candidate = try store.decodeImport(data) }
        catch { report(error) }
    }
    private func report(_ error: Error) {
        candidate = nil
        let e = error as NSError
        message = "\(e.localizedDescription)\n\(e.domain) (\(e.code)).\nIf file access failed, use Paste JSON or Load bundled building.json above."
    }
}

// MARK: - Walkable indoor routes (one level, simulated position)

private struct NavigationPlace: Identifiable {
    let id: String
    let name: String
    let point: CGPoint
}

private enum NavigationGeometry {
    static func polygon(_ points: [CGPoint]) -> BuilderHallway {
        BuilderHallway(vertices: points.map { HallwayPoint(x: Double($0.x), z: Double($0.y)) }, doors: [])
    }
    static func interior(_ points: [CGPoint]) -> CGPoint {
        let h = polygon(points)
        let middle = CGPoint(x: ((points.map(\.x).min() ?? 0)+(points.map(\.x).max() ?? 0))/2,
                             y: ((points.map(\.y).min() ?? 0)+(points.map(\.y).max() ?? 0))/2)
        if HallwayUnion.contains(middle, [h]) { return middle }
        guard let ids = h.triangles else { return middle }
        var best = middle, area: CGFloat = -1
        for i in stride(from: 0, to: ids.count, by: 3) {
            let a = points[Int(ids[i])], b = points[Int(ids[i+1])], c = points[Int(ids[i+2])]
            let value = abs(HallwayUnion.cross(a,b,c))
            if value > area { area = value; best = CGPoint(x: (a.x+b.x+c.x)/3, y: (a.y+b.y+c.y)/3) }
        }
        return best
    }
    static func rooms(_ d: BuilderDraft) -> [NavigationPlace] {
        d.pieces.filter { $0.kind == .room }.map { NavigationPlace(id: $0.id.uuidString, name: $0.name, point: interior($0.worldOutline)) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func starts(_ d: BuilderDraft) -> [NavigationPlace] {
        var places = rooms(d)
        for (i,h) in d.hallways.enumerated() {
            places.append(NavigationPlace(id: "hall-\(i)", name: h.name ?? "Hallway \(i+1)", point: interior(h.outline)))
            for door in h.doors where HallwayUnion.visible(door, in: h, halls: d.hallways) {
                let c = door.center(in: h.outline), a = h.outline[door.edge], b = h.outline[(door.edge+1)%h.vertices.count]
                let l = hypot(b.x-a.x,b.y-a.y)
                // Positive outline orientation: inside is left of the directed edge.
                let p = CGPoint(x: c.x-(b.y-a.y)/l*0.45, y: c.y+(b.x-a.x)/l*0.45)
                places.append(NavigationPlace(id: "door-\(i)-\(door.id)", name: "Hallway door · \(door.name)", point: p))
            }
        }
        return places
    }
    static func bounds(_ d: BuilderDraft) -> CGRect {
        let p = d.hallways.flatMap(\.outline) + d.pieces.flatMap(\.worldOutline)
        let x = p.map(\.x).min() ?? 0, z = p.map(\.y).min() ?? 0
        return CGRect(x:x-3,y:z-3,width:max(10,(p.map(\.x).max() ?? 10)-x+6),height:max(10,(p.map(\.y).max() ?? 10)-z+6))
    }
    static func length(_ route: [CGPoint]) -> Double {
        zip(route,route.dropFirst()).reduce(0) { $0+Double(hypot($1.1.x-$1.0.x,$1.1.y-$1.0.y)) }
    }
    static func position(_ route: [CGPoint], distance: Double) -> CGPoint? {
        guard let first = route.first else { return nil }
        var remaining = max(0,distance), last = first
        for next in route.dropFirst() {
            let length = Double(hypot(next.x-last.x,next.y-last.y))
            if remaining <= length { return HallwayUnion.mix(last,next,CGFloat(remaining/max(length,0.000001))) }
            remaining -= length; last = next
        }
        return last
    }
}

private enum NavigationRouteError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case .unavailable(let message) = self { return message }; return nil }
}

// Effective shared doorways: a room door opens both faces of a shared boundary.
// Only nearby (<= 25 cm), parallel boundaries are reconciled.
private struct NavigationBarrier {
    var a: CGPoint
    var b: CGPoint
    var halfWidth: CGFloat
    var room: Bool
    var solid: Bool = false
}
private struct NavigationLayout {
    var barriers: [NavigationBarrier] = []
    var bridges: [BuilderHallway] = []
    var portals: [CGPoint] = []
    init(_ draft: BuilderDraft) {
        let rooms = draft.pieces.filter { $0.kind == .room }
        let areas = draft.hallways + rooms.map { NavigationGeometry.polygon($0.worldOutline) }
        var doors: [(CGPoint,CGPoint)] = []
        for h in draft.hallways {
            for d in h.doors {
                let a=h.outline[d.edge],b=h.outline[(d.edge+1)%h.outline.count],l=hypot(b.x-a.x,b.y-a.y)
                doors.append((HallwayUnion.mix(a,b,CGFloat(d.fraction)-0.75/l),HallwayUnion.mix(a,b,CGFloat(d.fraction)+0.75/l)))
            }
        }
        for p in rooms where p.doorFits {
            let v=p.worldOutline,a=v[p.doorEdge],b=v[(p.doorEdge+1)%v.count],l=hypot(b.x-a.x,b.y-a.y)
            doors.append((HallwayUnion.mix(a,b,0.5-0.75/l),HallwayUnion.mix(a,b,0.5+0.75/l)))
        }
        // Reconcile small modeling offsets at a door with walkable areas on
        // both sides. This never connects separate hallways across open space.
        for (a,b) in doors {
            let l=hypot(b.x-a.x,b.y-a.y),nx = -(b.y-a.y)/l,ny=(b.x-a.x)/l,m=HallwayUnion.mix(a,b,0.5)
            let left=CGPoint(x:m.x+nx*0.4,y:m.y+ny*0.4),right=CGPoint(x:m.x-nx*0.4,y:m.y-ny*0.4)
            if HallwayUnion.contains(left,areas) && HallwayUnion.contains(right,areas) {
                portals += [m,left,right]
                let v=[CGPoint(x:a.x-nx*0.30,y:a.y-ny*0.30),CGPoint(x:b.x-nx*0.30,y:b.y-ny*0.30),CGPoint(x:b.x+nx*0.30,y:b.y+ny*0.30),CGPoint(x:a.x+nx*0.30,y:a.y+ny*0.30)]
                bridges.append(NavigationGeometry.polygon(v))
            }
        }
        var raw = HallwayUnion.walls(draft.hallways).map { NavigationBarrier(a:$0.0,b:$0.1,halfWidth:0.06,room:false) }
        raw += rooms.flatMap { p in p.roomWalls.map { NavigationBarrier(a:p.worldPoint($0.0),b:p.worldPoint($0.1),halfWidth:CGFloat(min(0.12,min(p.width,p.depth)/4))/2,room:true) } }
        for wall in raw {
            let a=wall.a,b=wall.b,dx=b.x-a.x,dy=b.y-a.y,l=hypot(dx,dy)
            guard l>0.00001 else { continue }
            var cuts: [(CGFloat,CGFloat)] = []
            for (c,d) in doors {
                let length=hypot(d.x-c.x,d.y-c.y)
                guard abs(dx*(d.y-c.y)-dy*(d.x-c.x))/(l*length)<0.001,
                      abs(HallwayUnion.cross(a,b,c))/l <= 0.250001,
                      abs(HallwayUnion.cross(a,b,d))/l <= 0.250001 else { continue }
                let t1=((c.x-a.x)*dx+(c.y-a.y)*dy)/(l*l),t2=((d.x-a.x)*dx+(d.y-a.y)*dy)/(l*l)
                let low=max(0,min(t1,t2)),high=min(1,max(t1,t2))
                if high>low { cuts.append((low,high)) }
            }
            var cursor: CGFloat=0
            for (low,high) in cuts.sorted(by:{$0.0<$1.0}) {
                if low>cursor { var w=wall;w.a=HallwayUnion.mix(a,b,cursor);w.b=HallwayUnion.mix(a,b,low);barriers.append(w) }
                cursor=max(cursor,high)
            }
            if cursor<1 {var w=wall;w.a=HallwayUnion.mix(a,b,cursor);barriers.append(w)}
        }
        for p in draft.pieces where p.kind == .wall {
            let v=p.worldOutline
            for i in v.indices { barriers.append(NavigationBarrier(a:v[i],b:v[(i+1)%v.count],halfWidth:0,room:false,solid:true)) }
        }
    }
}

private struct HallwayCenterline {
    let a: CGPoint
    let b: CGPoint
    let halfWidth: CGFloat
    static func build(_ halls: [BuilderHallway]) -> [HallwayCenterline] {
        // Close door gaps for this calculation: corridor shape, not the openings,
        // defines opposing walls and hence the middle of each hallway run.
        let closed=halls.map { h -> BuilderHallway in var c=h;c.doors=[];c.openEdges=[];return c }
        let edges=HallwayUnion.walls(closed)
        var result: [HallwayCenterline]=[]
        for i in edges.indices {
            let (a,b)=edges[i],dx=b.x-a.x,dy=b.y-a.y,l=hypot(dx,dy)
            guard l>0.1 else {continue}
            let ux=dx/l,uy=dy/l
            for j in edges.indices where j>i {
                let (c,d)=edges[j],ex=d.x-c.x,ey=d.y-c.y,other=hypot(ex,ey)
                guard other>0.1,(dx*ex+dy*ey)/(l*other)<(-0.999) else {continue}
                let width=abs(HallwayUnion.cross(a,b,c))/l
                guard width>0.35 else {continue}
                let tc=(c.x-a.x)*ux+(c.y-a.y)*uy,td=(d.x-a.x)*ux+(d.y-a.y)*uy
                let low=max(0,min(tc,td)),high=min(l,max(tc,td))
                guard high-low>0.2 else {continue}
                func pair(_ t:CGFloat)->(CGPoint,CGPoint) {
                    let p=CGPoint(x:a.x+ux*t,y:a.y+uy*t)
                    let u=((p.x-c.x)*ex+(p.y-c.y)*ey)/(other*other)
                    return (p,HallwayUnion.mix(c,d,u))
                }
                var valid=true
                for f in [CGFloat(0.05),CGFloat(0.5),CGFloat(0.95)] {
                    let (p,q)=pair(low+(high-low)*f)
                    for across in [CGFloat(0.2),CGFloat(0.5),CGFloat(0.8)] {
                        if !HallwayUnion.contains(HallwayUnion.mix(p,q,across),halls) {valid=false}
                    }
                }
                guard valid else {continue}
                let (p0,q0)=pair(low), (p1,q1)=pair(high)
                var start=HallwayUnion.mix(p0,q0,0.5),end=HallwayUnion.mix(p1,q1,0.5)
                // Extend half a corridor width into junctions, while staying in
                // the actual hallway footprint. This joins T and angled branches.
                for sign in [CGFloat(-1),CGFloat(1)] {
                    let origin=sign<0 ? start:end
                    var last=origin
                    let count=max(1,Int(ceil(width/2/0.1)))
                    for k in 1...count {
                        let delta=min(width/2,CGFloat(k)*0.1)
                        let p=CGPoint(x:origin.x+ux*delta*sign,y:origin.y+uy*delta*sign)
                        if !HallwayUnion.contains(p,halls) {break};last=p
                    }
                    if sign<0 {start=last}else{end=last}
                }
                result.append(HallwayCenterline(a:start,b:end,halfWidth:width/2))
            }
        }
        return result
    }
}

private enum NavigatorPathfinder {
    // Wall half-thickness plus 0.12 m clearance, including corners. This is a
    // schematic route, not an accessibility certification or live localization.
    static func route(_ draft: BuilderDraft, from start: CGPoint, to goal: CGPoint) throws -> [CGPoint] {
        let layout = NavigationLayout(draft)
        var last: Error = NavigationRouteError.unavailable("No connected route found.")
        for resolution in [CGFloat(0.25),CGFloat(0.10)] {
            if Task.isCancelled { throw CancellationError() }
            do { return try Search(draft, layout:layout, resolution:resolution).route(start,goal) }
            catch is CancellationError { throw CancellationError() }
            catch { last=error }
        }
        throw last
    }
    private final class Search {
        let hallwayShapes: [[CGPoint]]
        let centerlines: [HallwayCenterline]
        var weightCache: [Int:Double] = [:]
        let shapes: [[CGPoint]]
        let boxes: [CGRect]
        let solidShapes: [[CGPoint]]
        let walls: [NavigationBarrier]
        var buckets: [String:Set<Int>] = [:]
        let bounds: CGRect
        let step: CGFloat
        let columns: Int
        let rows: Int
        let clearance: CGFloat = 0.12
        var validCache: [Int:Bool] = [:]
        init(_ d: BuilderDraft, layout: NavigationLayout, resolution: CGFloat) {
            hallwayShapes = d.hallways.map(\.outline)
            centerlines = HallwayCenterline.build(d.hallways)
            let polygons = layout.bridges + d.hallways + d.pieces.filter { $0.kind == .room }.map { NavigationGeometry.polygon($0.worldOutline) }
            shapes = polygons.map(\.outline)
            boxes = shapes.map { points in
                let xs = points.map(\.x), ys = points.map(\.y)
                return CGRect(x:xs.min() ?? 0,y:ys.min() ?? 0,width:(xs.max() ?? 0)-(xs.min() ?? 0),height:(ys.max() ?? 0)-(ys.min() ?? 0))
            }
            solidShapes = d.pieces.filter { $0.kind == .wall }.map(\.worldOutline)
            walls = layout.barriers
            bounds = NavigationGeometry.bounds(d)
            step = resolution
            columns = Int(ceil(bounds.width/step))+1; rows = Int(ceil(bounds.height/step))+1
            if columns > 2000000/rows { return }
            for (i,w) in walls.enumerated() {
                // Index each wall by the cells it actually crosses, avoiding huge
                // diagonal-wall bounding rectangles.
                let count = max(1,Int(ceil(hypot(w.b.x-w.a.x,w.b.y-w.a.y))))
                for k in 0...count {
                    let p = HallwayUnion.mix(w.a,w.b,CGFloat(k)/CGFloat(count))
                    let x = Int(floor(p.x/2)), y = Int(floor(p.y/2))
                    for dx in -1...1 { for dy in -1...1 { buckets["\(x+dx),\(y+dy)",default:[]].insert(i) } }
                }
            }
        }
        func candidates(_ a: CGPoint, _ b: CGPoint) -> Set<Int> {
            var ids = Set<Int>()
            let count = max(1,Int(ceil(hypot(b.x-a.x,b.y-a.y))))
            for i in 0...count {
                let p = HallwayUnion.mix(a,b,CGFloat(i)/CGFloat(count))
                ids.formUnion(buckets["\(Int(floor(p.x/2))),\(Int(floor(p.y/2)))"] ?? [])
            }
            return ids
        }
        func contains(_ p: CGPoint, _ v: [CGPoint]) -> Bool {
            guard !v.isEmpty else {return false}
            var inside=false,j=v.count-1
            for i in v.indices {
                let a=v[i],b=v[j]
                if (a.y>p.y) != (b.y>p.y),p.x<(b.x-a.x)*(p.y-a.y)/(b.y-a.y)+a.x {inside.toggle()}
                j=i
            }
            return inside
        }
        func inside(_ p: CGPoint) -> Bool {
            var included = false
            for i in shapes.indices where boxes[i].insetBy(dx:-0.000001,dy:-0.000001).contains(p) {
                if contains(p,shapes[i]) { included = true; break }
            }
            return included && !solidShapes.contains(where:{contains(p,$0)})
        }
        func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x-a.x, dy = b.y-a.y, l = dx*dx+dy*dy
            let t = l > 0 ? min(1,max(0,((p.x-a.x)*dx+(p.y-a.y)*dy)/l)) : 0
            let q = HallwayUnion.mix(a,b,t)
            return hypot(q.x-p.x,q.y-p.y)
        }
        func clear(_ a: CGPoint, _ b: CGPoint) -> Bool {
            let count = max(1,Int(ceil(hypot(b.x-a.x,b.y-a.y)/0.12)))
            for i in 0...count { if !inside(HallwayUnion.mix(a,b,CGFloat(i)/CGFloat(count))) { return false } }
            for id in candidates(a,b) {
                let wall=walls[id],c=wall.a,d=wall.b
                let c1 = HallwayUnion.cross(a,b,c), c2 = HallwayUnion.cross(a,b,d)
                let c3 = HallwayUnion.cross(c,d,a), c4 = HallwayUnion.cross(c,d,b)
                if c1*c2 < 0 && c3*c4 < 0 { return false }
                if [distance(a,c,d),distance(b,c,d),distance(c,a,b),distance(d,a,b)].min()! < clearance+wall.halfWidth { return false }
            }
            return true
        }
        func weight(_ p: CGPoint) -> Double {
            guard hallwayShapes.contains(where:{contains(p,$0)}),!centerlines.isEmpty else {return 1}
            let offset=centerlines.map { distance(p,$0.a,$0.b)/max(0.25,$0.halfWidth) }.min() ?? 0
            return 1+40*Double(min(4,offset*offset))
        }
        func nodeWeight(_ id:Int)->Double {
            if let w=weightCache[id] {return w};let w=weight(point(id));weightCache[id]=w;return w
        }
        func segmentCost(_ a:CGPoint,_ b:CGPoint)->Double {
            let length=hypot(b.x-a.x,b.y-a.y),n=max(1,Int(ceil(length/step)))
            var sum=0.0
            for i in 0..<n {sum+=weight(HallwayUnion.mix(a,b,(CGFloat(i)+0.5)/CGFloat(n)))}
            return Double(length)*sum/Double(n)
        }
        func point(_ id: Int) -> CGPoint { CGPoint(x:bounds.minX+CGFloat(id%columns)*step,y:bounds.minY+CGFloat(id/columns)*step) }
        func valid(_ id: Int) -> Bool {
            if let v = validCache[id] { return v }
            let p = point(id), value = clear(p,p); validCache[id] = value; return value
        }
        func nearby(_ p: CGPoint) -> [Int] {
            let x = Int(((p.x-bounds.minX)/step).rounded()), y = Int(((p.y-bounds.minY)/step).rounded())
            var result: [Int] = []
            for dx in -3...3 { for dy in -3...3 {
                let a=x+dx,b=y+dy
                if a>=0 && b>=0 && a<columns && b<rows {
                    let id=b*columns+a
                    if valid(id) && clear(p,point(id)) { result.append(id) }
                }
            }}
            return result
        }
        struct Entry { let id: Int; let score: Double; let cost: Double }
        var heap: [Entry] = []
        func push(_ e: Entry) {
            heap.append(e); var i=heap.count-1
            while i>0 { let p=(i-1)/2; if heap[p].score <= heap[i].score { break }; heap.swapAt(i,p); i=p }
        }
        func pop() -> Entry? {
            guard !heap.isEmpty else { return nil }
            if heap.count==1 { return heap.removeLast() }
            let first=heap[0]; heap[0]=heap.removeLast(); var i=0
            while i*2+1<heap.count { let a=i*2+1,b=a+1,j=b<heap.count && heap[b].score<heap[a].score ? b:a; if heap[i].score<=heap[j].score { break }; heap.swapAt(i,j); i=j }
            return first
        }
        func route(_ start: CGPoint, _ goal: CGPoint) throws -> [CGPoint] {
            if Task.isCancelled { throw CancellationError() }
            guard columns <= 2000000/rows else { throw NavigationRouteError.unavailable("This layout is too large for on-phone routing. Export a smaller building area.") }
            guard clear(start,start),clear(goal,goal) else { throw NavigationRouteError.unavailable("The selected start or room center is too close to a wall. Select a hallway doorway as the start, or check whether this room overlaps a standalone wall in the browser editor.") }
            if hypot(start.x-goal.x,start.y-goal.y)<0.01 { return [start] }

            let starts=nearby(start), ends=Set(nearby(goal))
            guard !starts.isEmpty && !ends.isEmpty else { throw NavigationRouteError.unavailable("No usable space around this start or destination. Check its doorway and room size in the browser editor.") }
            var costs: [Int:Double]=[:], parents: [Int:Int]=[:], expanded=Set<Int>()
            for id in starts { let p=point(id),g=segmentCost(start,p); costs[id]=g; push(Entry(id:id,score:g+Double(hypot(p.x-goal.x,p.y-goal.y)),cost:g)) }
            while let item=pop() {
                if Task.isCancelled { throw CancellationError() }
                if expanded.contains(item.id) || item.cost > (costs[item.id] ?? .infinity) { continue }
                if ends.contains(item.id) {
                    var ids=[item.id],cur=item.id
                    while let p=parents[cur] { ids.append(p);cur=p }
                    let raw=[start]+ids.reversed().map { point($0) }+[goal]
                    // Keep the center-following shape. The old visibility-only
                    // smoother replaced it with shortcuts along hallway edges.
                    var prefix=[0.0]
                    for (a,b) in zip(raw,raw.dropFirst()) {prefix.append(prefix.last!+segmentCost(a,b))}
                    var smooth=[raw[0]],i=0
                    while i<raw.count-1 {
                        if Task.isCancelled {throw CancellationError()}
                        var j=raw.count-1
                        while j>i+1 {
                            let close=(i+1..<j).allSatisfy {distance(raw[$0],raw[i],raw[j])<=step*0.6}
                            if close && clear(raw[i],raw[j]) && segmentCost(raw[i],raw[j]) <= (prefix[j]-prefix[i])*1.02 {break}
                            j-=1
                        }
                        smooth.append(raw[j]);i=j
                    }
                    return smooth
                }
                expanded.insert(item.id)
                if expanded.count>400000 { break }
                let x=item.id%columns,y=item.id/columns,p=point(item.id)
                for dx in -1...1 { for dy in -1...1 where dx != 0 || dy != 0 {
                    let a=x+dx,b=y+dy
                    if a<0 || b<0 || a>=columns || b>=rows { continue }
                    let id=b*columns+a,q=point(id)
                    if expanded.contains(id) || !valid(id) || !clear(p,q) { continue }
                    let g=item.cost+Double(hypot(q.x-p.x,q.y-p.y))*(nodeWeight(item.id)+nodeWeight(id))/2
                    if g < (costs[id] ?? .infinity) { costs[id]=g;parents[id]=item.id;push(Entry(id:id,score:g+Double(hypot(q.x-goal.x,q.y-goal.y)),cost:g)) }
                }}
            }
            throw NavigationRouteError.unavailable("No connected walking route found after checking a 0.3281 ft grid, wall thicknesses and shared doorways. Make sure the selected room has a 4.9213 ft door on the edge next to a hallway. Gaps over 0.8202 ft and standalone walls remain blocked. Export and attach your building.json if this still looks wrong.")
        }
    }
}

// MARK: - Read-only indoor navigator

@MainActor
struct BuildingEditorView: View {
    @StateObject private var store = BuilderStore()
    @State private var preview = false
    @State private var showImport = false
    @State private var startID = ""
    @State private var destinationID = ""
    @State private var route: [CGPoint] = []
    @State private var showDirections = false
    @State private var distance = 0.0
    @State private var walking = false
    @State private var planning = false
    @State private var routeMessage = "Choose a start and destination."
    @State private var zoom = 0.0
    @State private var fitToken = 0
    @State private var focusToken = 0
    @State private var requestID = UUID()
    @State private var routeTask: Task<[CGPoint], Error>?
    @State private var navigationExpanded = true
    private let clock = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()
    private var instructions: [RouteInstruction] { WalkingDirections.build(route) }
    private var currentInstruction: RouteInstruction? { instructions.first { distance < $0.end-0.01 } }
    private var total: Double { NavigationGeometry.length(route) }
    private var person: CGPoint? { NavigationGeometry.position(route,distance:distance) }
    private var starts: [NavigationPlace] { NavigationGeometry.starts(store.draft) }
    private var destinations: [NavigationPlace] { NavigationGeometry.rooms(store.draft) }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment:.leading) {
                    Text("Inward").font(.system(size:29,weight:.bold,design:.rounded))
                    Text("Indoor navigator").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import",systemImage:"square.and.arrow.down") { showImport=true }
                    .buttonStyle(.bordered).disabled(planning)
            }.padding(.horizontal,20)
            Picker("View",selection:$preview) {
                Text("Bird’s-eye").tag(false); Text("3D preview").tag(true)
            }.pickerStyle(.segmented).padding(.horizontal,20)
            Group {
                if preview {
                    BuilderScene(draft:store.draft,route:route,person:person,fitToken:fitToken,focusToken:focusToken)
                        .overlay(alignment:.topLeading) {
                            Text("Orbit: one finger · Pan: two · Pinch zoom").font(.caption).padding(10)
                                .background(.regularMaterial,in:Capsule()).padding(10).allowsHitTesting(false)
                        }
                } else {
                    VStack(spacing:4) {
                        NavigatorPlan(draft:store.draft,route:route,person:person,zoom:$zoom,fitToken:fitToken,focusToken:focusToken)
                        HStack {
                            Image(systemName:"minus.magnifyingglass")
                            Slider(value:$zoom,in:-20...20)
                            Image(systemName:"plus.magnifyingglass")
                            Button("Fit") { zoom=0;fitToken+=1 }
                        }.padding(.horizontal,14).padding(.bottom,6)
                    }
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity).frame(minHeight:180)
                .clipShape(RoundedRectangle(cornerRadius:22)).padding(.horizontal,12)
            HStack {
                Button("Fit building",systemImage:"arrow.up.left.and.arrow.down.right") {zoom=0;fitToken+=1}
                Spacer()
                Button("Focus person",systemImage:"scope") {focusToken+=1}.disabled(person==nil)
            }.font(.caption).padding(.horizontal,20)
            ScrollView {
              VStack(spacing:8) {
                DisclosureGroup("Navigation",isExpanded:$navigationExpanded) {
                    Picker("Start",selection:$startID) {
                        Text("Choose start").tag("")
                        ForEach(starts) { p in Text(p.name).tag(p.id) }
                    }
                    Picker("Destination room",selection:$destinationID) {
                        Text("Choose room").tag("")
                        ForEach(destinations) { p in Text(p.name).tag(p.id) }
                    }
                    Button(action:planRoute) {
                        HStack { if planning { ProgressView() }; Text(planning ? "Finding route…":"Find route") }
                            .frame(maxWidth:.infinity)
                    }.buttonStyle(.borderedProminent).disabled(planning || startID.isEmpty || destinationID.isEmpty)
                }
                ScrollView { Text(routeMessage).font(.callout).foregroundColor(.black).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(8) }.frame(height:72).background(Color.white,in:RoundedRectangle(cornerRadius:8))
                if route.count>1 {
                    Text(currentInstruction?.text(at:distance) ?? "You have arrived at your destination.")
                        .font(.callout.weight(.semibold)).foregroundColor(.black)
                        .frame(maxWidth:.infinity,alignment:.leading).padding(10)
                        .background(Color.blue.opacity(0.08),in:RoundedRectangle(cornerRadius:10))
                    DisclosureGroup("Step-by-step directions",isExpanded:$showDirections) {
                        ScrollView {
                            VStack(alignment:.leading,spacing:10) {
                                Text("Start facing along the blue route. Left and right follow your direction of travel.")
                                    .font(.caption).foregroundColor(.black)
                                ForEach(instructions) { step in
                                    Text("\(step.id+1). \(step.text(at:step.start))")
                                        .font(.callout).foregroundColor(.black)
                                        .frame(maxWidth:.infinity,alignment:.leading)
                                }
                            }.padding(.vertical,6)
                        }.frame(maxHeight:130)
                    }
                    HStack {
                        Button(walking ? "Pause":"Walk",systemImage:walking ? "pause.fill":"figure.walk") {
                            if distance>=total { distance=0 }; walking.toggle()
                        }.buttonStyle(.borderedProminent)
                        Button("Restart") { distance=0;walking=false }
                        Spacer()
                        Text("\(DisplayDistance.feet(max(0,total-distance))) left").font(.caption.monospacedDigit())
                    }
                    Slider(value:$distance,in:0...max(total,0.001),onEditingChanged: { if $0 { walking=false } })
                        .accessibilityLabel("Walking simulation progress")
                }
                Text("Walking preview · selected start, not live position").font(.caption2).foregroundStyle(.secondary)
              }.padding(14)
            }.frame(maxHeight:route.count>1 ? 340:250)
                .background(.white,in:RoundedRectangle(cornerRadius:18)).padding(.horizontal,12)
        }.padding(.vertical,8).background(Color(red:0.94,green:0.97,blue:0.96)).tint(builderPurple).preferredColorScheme(.light)
        .sheet(isPresented:$showImport) {
            BuilderImportSheet(store:store) { startID="";destinationID="";zoom=0;fitToken+=1;resetRoute();routeMessage="Building imported. Choose a start and destination." }
        }
        .alert("Building",isPresented:Binding(get:{store.error != nil},set:{if !$0 {store.error=nil}})) {
            Button("OK") { store.error=nil }
        } message: { Text(store.error ?? "") }
        .onChange(of:startID) { _,_ in resetRoute() }
        .onChange(of:destinationID) { _,_ in resetRoute() }
        .onDisappear { walking=false;routeTask?.cancel() }
        .onReceive(clock) { _ in
            guard walking else { return }
            distance=min(total,distance+0.08*1.25)
            if distance>=total { walking=false;routeMessage="Arrived at the destination room." }
        }
    }
    private func resetRoute() {
        routeTask?.cancel();requestID=UUID();planning=false;walking=false;distance=0;route=[]
        routeMessage=destinations.isEmpty ? "No rooms in this building. Add rooms in the browser editor, export, then import here.":"Choose locations, then tap Find route."
    }
    private func planRoute() {
        guard let start=starts.first(where:{$0.id==startID}),let end=destinations.first(where:{$0.id==destinationID}) else { return }
        resetRoute(); planning=true;routeMessage="Checking hallways, door openings and walls…"
        let token=UUID();requestID=token
        let draft=store.draft,a=start.point,b=end.point
        let work=Task.detached(priority:.userInitiated) { try NavigatorPathfinder.route(draft,from:a,to:b) }
        routeTask=work
        Task {
            do {
                let result=try await work.value
                guard requestID==token else { return }
                route=result;planning=false
                routeMessage=result.count<2 ? "You are already at this room.":"\(start.name) → \(end.name) · \(DisplayDistance.feet(NavigationGeometry.length(result)))"
            } catch {
                guard requestID==token else { return }
                planning=false;routeMessage=error.localizedDescription
            }
        }
    }
}

// Viewport-only drawing avoids allocating a giant canvas at close zoom.
@MainActor
private struct NavigatorPlan: UIViewRepresentable {
    let draft: BuilderDraft
    let route: [CGPoint]
    let person: CGPoint?
    @Binding var zoom: Double // log2 of fit scale
    let fitToken: Int
    let focusToken: Int
    func makeUIView(context: Context) -> NavigatorMapView {
        let v=NavigatorMapView();v.onZoom={zoom=$0};return v
    }
    func updateUIView(_ view: NavigatorMapView, context: Context) {
        view.onZoom={zoom=$0}
        view.update(draft,route:route,person:person,zoom:zoom,fit:fitToken,focus:focusToken)
    }
}
@MainActor
private final class NavigatorMapView: UIView, UIGestureRecognizerDelegate {
    var onZoom: ((Double)->Void)?
    private var draft: BuilderDraft?
    private var layout: NavigationLayout?
    private var route: [CGPoint]=[]
    private var person: CGPoint?
    private var worldBounds=CGRect(x:0,y:0,width:100,height:100)
    private var scale: CGFloat=1
    private var base: CGFloat=1
    private var offset=CGPoint.zero
    private var logZoom=0.0
    private var initialized=false
    private var lastSize=CGSize.zero
    private var lastFit=0,lastFocus=0
    override init(frame:CGRect) {
        super.init(frame:frame);isOpaque=true;backgroundColor=UIColor(red:0.49,green:0.68,blue:0.40,alpha:1)
        let pan=UIPanGestureRecognizer(target:self,action:#selector(panMap(_:)));pan.delegate=self;addGestureRecognizer(pan)
        let pinch=UIPinchGestureRecognizer(target:self,action:#selector(pinchMap(_:)));pinch.delegate=self;addGestureRecognizer(pinch)
        let tap=UITapGestureRecognizer(target:self,action:#selector(doubleTap(_:)));tap.numberOfTapsRequired=2;addGestureRecognizer(tap)
        accessibilityLabel="Read-only building map. Pan, pinch or double tap to zoom."
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) not used") }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        (gestureRecognizer is UIPinchGestureRecognizer && otherGestureRecognizer is UIPanGestureRecognizer) ||
        (gestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer is UIPinchGestureRecognizer)
    }
    func update(_ d:BuilderDraft,route:[CGPoint],person:CGPoint?,zoom:Double,fit:Int,focus:Int) {
        if draft != d {draft=d;layout=NavigationLayout(d);worldBounds=BuildingGrounds.square(d);initialized=false}
        self.route=route;self.person=person
        layoutIfNeeded()
        if !initialized && bounds.width>0 && bounds.height>0 {fitMap()}
        if lastFit != fit {lastFit=fit;fitMap()}
        if abs(logZoom-zoom)>0.00001 {setScale(base*CGFloat(pow(2,zoom)),anchor:CGPoint(x:bounds.midX,y:bounds.midY));logZoom=zoom}
        if lastFocus != focus {
            lastFocus=focus
            if let p=person ?? route.last {
                scale=min(20000,max(base,100));offset=CGPoint(x:bounds.midX-p.x*scale,y:bounds.midY-p.y*scale)
                logZoom=log2(Double(scale/base));let value=logZoom
                DispatchQueue.main.async { [weak self] in self?.onZoom?(value) }
            }
        }
        setNeedsDisplay()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if lastSize != bounds.size && bounds.width>0 && bounds.height>0 {
            lastSize=bounds.size;fitMap();setNeedsDisplay()
        }
    }
    private func fitMap() {
        guard bounds.width>0 && bounds.height>0 else{return}
        base=min(max(1,bounds.width-24)/worldBounds.width,max(1,bounds.height-24)/worldBounds.height)
        scale=base*CGFloat(pow(2,logZoom));scale=min(20000,max(0.01,scale))
        offset=CGPoint(x:bounds.midX-worldBounds.midX*scale,y:bounds.midY-worldBounds.midY*scale);initialized=true
    }
    private func at(_ p:CGPoint)->CGPoint {CGPoint(x:p.x*scale+offset.x,y:p.y*scale+offset.y)}
    private func setScale(_ value:CGFloat,anchor:CGPoint) {
        let p=CGPoint(x:(anchor.x-offset.x)/scale,y:(anchor.y-offset.y)/scale)
        scale=min(20000,max(0.01,value));offset=CGPoint(x:anchor.x-p.x*scale,y:anchor.y-p.y*scale)
    }
    @objc private func panMap(_ g:UIPanGestureRecognizer) {
        let d=g.translation(in:self);offset.x+=d.x;offset.y+=d.y;g.setTranslation(.zero,in:self);setNeedsDisplay()
    }
    @objc private func pinchMap(_ g:UIPinchGestureRecognizer) {
        setScale(scale*g.scale,anchor:g.location(in:self));g.scale=1;logZoom=log2(Double(scale/base));onZoom?(logZoom);setNeedsDisplay()
    }
    @objc private func doubleTap(_ g:UITapGestureRecognizer) {
        setScale(scale*2,anchor:g.location(in:self));logZoom=log2(Double(scale/base));onZoom?(logZoom);setNeedsDisplay()
    }
    override func draw(_ rect:CGRect) {
        guard let c=UIGraphicsGetCurrentContext(),let draft,let layout else{return}
        c.setFillColor(UIColor(red:0.77,green:0.87,blue:0.95,alpha:1).cgColor);c.fill(bounds)
        let grounds = BuildingGrounds.square(draft)
        let origin = at(grounds.origin)
        c.setFillColor(UIColor(red:0.49,green:0.68,blue:0.40,alpha:1).cgColor)
        c.fill(CGRect(x:origin.x,y:origin.y,width:grounds.width*scale,height:grounds.height*scale))
        for tree in BuildingGrounds.trees(grounds,draft:draft) {
            let p = at(tree.point), radius = tree.radius*scale
            c.setFillColor(tree.color.cgColor)
            c.fillEllipse(in:CGRect(x:p.x-radius,y:p.y-radius,width:radius*2,height:radius*2))
        }
        func polygon(_ v:[CGPoint],_ color:UIColor) {
            guard let first=v.first else{return};c.beginPath();c.move(to:at(first));for p in v.dropFirst(){c.addLine(to:at(p))};c.closePath();c.setFillColor(color.cgColor);c.fillPath()
        }
        func line(_ a:CGPoint,_ b:CGPoint,_ color:UIColor,_ width:CGFloat) {
            c.beginPath();c.move(to:at(a));c.addLine(to:at(b));c.setStrokeColor(color.cgColor);c.setLineWidth(width);c.setLineCap(.round);c.strokePath()
        }
        for p in draft.pieces where p.kind == .floor {polygon(p.worldOutline,UIColor(red:0.85,green:0.90,blue:0.90,alpha:1))}
        for h in draft.hallways {polygon(h.outline,UIColor(red:0.89,green:0.96,blue:0.95,alpha:1))}
        for bridge in layout.bridges {polygon(bridge.outline,UIColor(red:0.89,green:0.96,blue:0.95,alpha:1))}
        for p in draft.pieces where p.kind != .floor {
            polygon(p.worldOutline,p.kind == .room ? UIColor(red:0.43,green:0.77,blue:0.76,alpha:1):UIColor.darkGray)
        }
        for w in layout.barriers {line(w.a,w.b,UIColor(red:0.13,green:0.20,blue:0.27,alpha:1),max(1,w.halfWidth*2*scale))}
        for (a,b) in zip(route,route.dropFirst()) {line(a,b,.white,7);line(a,b,.systemBlue,4)}
        for p in draft.pieces where p.kind == .room {
            let point=at(NavigationGeometry.interior(p.worldOutline))
            if bounds.insetBy(dx:-100,dy:-40).contains(point) {
                let attrs:[NSAttributedString.Key:Any]=[.font:UIFont.systemFont(ofSize:12,weight:.semibold),.foregroundColor:UIColor.black,.backgroundColor:UIColor(white:1,alpha:0.85)]
                let size=(p.name as NSString).size(withAttributes:attrs)
                (p.name as NSString).draw(at:CGPoint(x:point.x-size.width/2,y:point.y-size.height/2),withAttributes:attrs)
            }
        }
        if let goal=route.last {let p=at(goal);c.setFillColor(UIColor.systemOrange.cgColor);c.fillEllipse(in:CGRect(x:p.x-6,y:p.y-6,width:12,height:12))}
        if let person {
            let p=at(person);c.setFillColor(UIColor.white.cgColor);c.fillEllipse(in:CGRect(x:p.x-13,y:p.y-13,width:26,height:26))
            UIImage(systemName:"figure.walk")?.withTintColor(.black,renderingMode:.alwaysOriginal).draw(in:CGRect(x:p.x-8,y:p.y-10,width:16,height:20))
        }
    }
}

// MARK: - RealityKit colorful architectural preview

private struct RouteInstruction: Identifiable {
    let id: Int
    let start: Double
    let end: Double
    let maneuver: String
    func text(at progress: Double) -> String {
        "Go straight for \(DisplayDistance.feet(max(0,end-max(start,progress)))), then \(maneuver)."
    }
}

private enum WalkingDirections {
    static func turn(_ angle: Double) -> String {
        let degrees = abs(angle)*180 / .pi
        let side = angle > 0 ? "right" : "left" // Map +z points down; positive cross is right.
        if degrees < 25 { return "continue straight" }
        if degrees < 60 { return "make a slight \(side) turn" }
        if degrees < 120 { return "turn \(side)" }
        if degrees < 160 { return "make a sharp \(side) turn" }
        return "make a U-turn"
    }
    static func build(_ points: [CGPoint]) -> [RouteInstruction] {
        var steps: [RouteInstruction] = []
        var traveled = 0.0, start = 0.0
        var heading: Double?
        for (a,b) in zip(points,points.dropFirst()) {
            let dx = Double(b.x-a.x), dz = Double(b.y-a.y), length = hypot(dx,dz)
            guard length > 0.0001 else { continue }
            let next = atan2(dz,dx)
            if let old = heading {
                let angle = atan2(sin(next-old),cos(next-old))
                if abs(angle) >= 25 * .pi / 180 {
                    steps.append(RouteInstruction(id:steps.count,start:start,end:traveled,maneuver:turn(angle)))
                    start = traveled; heading = next
                }
            } else { heading = next }
            traveled += length
        }
        if traveled > start {
            steps.append(RouteInstruction(id:steps.count,start:start,end:traveled,maneuver:"arrive at your destination"))
        }
        return steps
    }
}

// Decorative grounds use the occupied footprint, without moving imported coordinates.
private enum BuildingGrounds {
    static func square(_ draft: BuilderDraft) -> CGRect {
        let points = draft.hallways.flatMap { $0.outline } + draft.pieces.flatMap { $0.worldOutline }
        let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? CGFloat(draft.width)
        let minZ = points.map(\.y).min() ?? 0, maxZ = points.map(\.y).max() ?? CGFloat(draft.depth)
        let side = max(maxX-minX,maxZ-minZ)+16
        return CGRect(x:(minX+maxX-side)/2,y:(minZ+maxZ-side)/2,width:side,height:side)
    }
    struct Tree {
        let point: CGPoint
        let radius: CGFloat
        let stretch: CGFloat
        let shade: Int
        var color: UIColor {
            [UIColor(red:0.16,green:0.42,blue:0.24,alpha:1),
             UIColor(red:0.27,green:0.53,blue:0.25,alpha:1),
             UIColor(red:0.36,green:0.59,blue:0.29,alpha:1),
             UIColor(red:0.21,green:0.48,blue:0.35,alpha:1)][shade]
        }
    }
    static func trees(_ square: CGRect, draft: BuilderDraft) -> [Tree] {
        let vertices = draft.hallways.flatMap { $0.outline } + draft.pieces.flatMap { $0.worldOutline }
        guard let minX = vertices.map(\.x).min(), let maxX = vertices.map(\.x).max(),
              let minZ = vertices.map(\.y).min(), let maxZ = vertices.map(\.y).max() else { return [] }
        // Exclude the entire occupied bounding box, including courtyards and gaps.
        // Expansion includes the full canopy radius plus an extra walking buffer.
        let building = CGRect(x:minX,y:minZ,width:maxX-minX,height:maxZ-minZ)
        var seed: UInt64 = 73421
        func random() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 40)/CGFloat(16777216)
        }
        var trees: [Tree] = []
        for _ in 0..<1600 {
            let radius = 0.7+random()*0.8
            let stretch = 0.95+random()*0.8
            let shade = min(3,Int(random()*4))
            let point = CGPoint(x:square.minX+random()*square.width,y:square.minY+random()*square.height)
            guard square.insetBy(dx:radius+0.6,dy:radius+0.6).contains(point),
                  !building.insetBy(dx:-(radius+1.5),dy:-(radius+1.5)).contains(point),
                  trees.allSatisfy({ hypot($0.point.x-point.x,$0.point.y-point.y) > $0.radius+radius+1.2 }) else { continue }
            trees.append(Tree(point:point,radius:radius,stretch:stretch,shade:shade))
            if trees.count == 32 { break }
        }
        return trees
    }
}

@MainActor
private struct BuilderScene: UIViewRepresentable {
    let draft: BuilderDraft
    let route: [CGPoint]
    let person: CGPoint?
    let fitToken: Int
    let focusToken: Int
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        context.coordinator.configure(view)
        return view
    }
    func updateUIView(_ uiView: ARView, context: Context) { context.coordinator.update(draft); context.coordinator.updateNavigation(route, person: person); context.coordinator.cameraActions(fitToken,focus:focusToken,person:person) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var view: ARView?
        let root = AnchorEntity(world: .zero)
        let geometry = Entity()
        let routeGeometry = Entity()
        let walker = Entity()
        var previousRoute: [CGPoint] = []
        let camera = PerspectiveCamera()
        let keyLight = DirectionalLight()
        var previous: BuilderDraft?
        var yaw: Float = -0.35
        var pitch: Float = 1.05
        var zoom: Float = 1
        var panOffset = SIMD3<Float>.zero
        var lastFit = 0, lastFocus = 0
        var center = SIMD3<Float>(15, 0, 15)
        var extent = SIMD2<Float>(20, 20)
        var subscription: Cancellable?

        func configure(_ view: ARView) {
            self.view = view
            view.environment.background = .color(UIColor(red: 0.57, green: 0.78, blue: 0.96, alpha: 1))
            view.scene.addAnchor(root); root.addChild(geometry); root.addChild(camera); root.addChild(routeGeometry); root.addChild(walker)
            let body = ModelEntity(mesh: .generateBox(size: [0.28,0.46,0.22]), materials: [UnlitMaterial(color: UIColor.systemBlue)])
            body.position = [0,0.49,0]; walker.addChild(body)
            let head = ModelEntity(mesh: .generateSphere(radius: 0.14), materials: [UnlitMaterial(color: UIColor(red:0.96,green:0.77,blue:0.57,alpha:1))])
            head.position = [0,0.86,0]; walker.addChild(head)
            for x in [Float(-0.09),Float(0.09)] {
                let leg = ModelEntity(mesh:.generateBox(size:[0.11,0.26,0.13]),materials:[UnlitMaterial(color:UIColor(red:0.13,green:0.20,blue:0.32,alpha:1))])
                leg.position=[x,0.16,0];walker.addChild(leg)
            }
            walker.isEnabled = false
            camera.camera.fieldOfViewInDegrees = 52
            camera.camera.near = 0.01
            // Matte surfaces and two directions of light make wall faces legible.
            let key = keyLight
            key.light.color = UIColor(red: 1, green: 0.96, blue: 0.89, alpha: 1)
            key.light.intensity = 1800
            key.shadow = DirectionalLightComponent.Shadow()
            key.look(at: .zero, from: [-30, 60, 25], relativeTo: nil)
            root.addChild(key)
            let fill = DirectionalLight()
            fill.light.color = UIColor(red: 0.80, green: 0.89, blue: 1, alpha: 1)
            fill.light.intensity = 700
            fill.look(at: .zero, from: [30, 35, -25], relativeTo: nil)
            root.addChild(fill)
            let panGesture=UIPanGestureRecognizer(target:self,action:#selector(pan(_:)));panGesture.delegate=self;view.addGestureRecognizer(panGesture)
            let pinchGesture=UIPinchGestureRecognizer(target:self,action:#selector(pinch(_:)));pinchGesture.delegate=self;view.addGestureRecognizer(pinchGesture)
            // Re-evaluate aspect after layout/orientation changes, including initial zero bounds.
            subscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
                self?.positionCamera()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

        func matte(_ color: UIColor) -> SimpleMaterial {
            SimpleMaterial(color: color, roughness: 0.85, isMetallic: false)
        }
        func tint(_ color: UIColor, white: CGFloat) -> UIColor {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return UIColor(red: r+(1-r)*white, green: g+(1-g)*white, blue: b+(1-b)*white, alpha: 1)
        }
        func roomColor(_ id: UUID) -> UIColor {
            UIColor(red: 0.30, green: 0.72, blue: 0.70, alpha: 1)
        }

        func updateNavigation(_ points: [CGPoint], person: CGPoint?) {
            if previousRoute != points {
                previousRoute = points
                for child in Array(routeGeometry.children) { child.removeFromParent() }
                for (a,b) in zip(points,points.dropFirst()) {
                    let dx=Float(b.x-a.x),dz=Float(b.y-a.y),length=hypot(dx,dz)
                    guard length>0.0001 else { continue }
                    let bar=ModelEntity(mesh:.generateBox(size:[0.14,0.025,length]),materials:[UnlitMaterial(color:UIColor.systemBlue)])
                    bar.position=[Float((a.x+b.x)/2),0.095,Float((a.y+b.y)/2)]
                    bar.orientation=simd_quatf(angle:atan2(dx,dz),axis:[0,1,0]);routeGeometry.addChild(bar)
                }
                if let goal=points.last {
                    let marker=ModelEntity(mesh:.generateSphere(radius:0.22),materials:[UnlitMaterial(color:UIColor.systemOrange)])
                    marker.position=[Float(goal.x),0.3,Float(goal.y)];routeGeometry.addChild(marker)
                }
            }
            walker.isEnabled = person != nil
            if let person { walker.position=[Float(person.x),0.06,Float(person.y)] }
        }

        func box(_ size: SIMD3<Float>, at position: SIMD3<Float>, color: UIColor, angle: Double = 0) {
            let item = ModelEntity(mesh: .generateBox(size: size), materials: [matte(color)])
            item.position = position; item.orientation = simd_quatf(angle: -Float(angle * .pi / 180), axis: [0,1,0]); geometry.addChild(item)
        }

        func update(_ draft: BuilderDraft) {
            guard previous != draft else { return }
            previous = draft
            for child in Array(geometry.children) { child.removeFromParent() }
            let grounds = BuildingGrounds.square(draft)
            center = [Float(grounds.midX),0,Float(grounds.midY)]
            extent = [Float(grounds.width),Float(grounds.height)]
            panOffset = .zero; zoom = 1
            var shadow = DirectionalLightComponent.Shadow()
            shadow.maximumDistance = max(50, max(extent.x, extent.y) * 12)
            keyLight.shadow = shadow
            box([extent.x,0.35,extent.y],at:[center.x,-0.34,center.z],
                color:UIColor(red:0.30,green:0.43,blue:0.25,alpha:1))
            box([extent.x,0.04,extent.y],at:[center.x,-0.145,center.z],
                color:UIColor(red:0.43,green:0.65,blue:0.33,alpha:1))
            for tree in BuildingGrounds.trees(grounds,draft:draft) {
                let x = Float(tree.point.x), z = Float(tree.point.y)
                let radius = Float(tree.radius), stretch = Float(tree.stretch)
                let trunkHeight = radius*1.3
                box([radius*0.25,trunkHeight,radius*0.25],at:[x,trunkHeight/2-0.125,z],
                    color:UIColor(red:0.40,green:0.27,blue:0.16,alpha:1))
                let crown = ModelEntity(mesh:.generateSphere(radius:radius),materials:[matte(tree.color)])
                crown.position = [x,trunkHeight+radius*stretch*0.65,z]
                crown.scale = [1,stretch,1]; geometry.addChild(crown)
            }
            // Decorative cloud clusters beyond the lawn keep the building view clear.
            let side = Float(grounds.width)
            for i in 0..<7 {
                let angle = Float(i)*2*Float.pi/7+0.2
                let cloudCenter = center+SIMD3<Float>(cos(angle)*side*0.78,side*(0.13+Float(i%3)*0.025),sin(angle)*side*0.78)
                let size = min(7,max(2,side*0.045))
                for j in 0..<4 {
                    let puff = ModelEntity(mesh:.generateSphere(radius:size*(j==1 ? 1:0.75)),
                        materials:[UnlitMaterial(color:UIColor(white:j==2 ? 0.95:1,alpha:1))])
                    puff.position = cloudCenter+SIMD3<Float>((Float(j)-1.5)*size*0.85,j==1 ? size*0.3:0,0)
                    puff.scale = [1.25,0.55,0.85]; geometry.addChild(puff)
                }
            }
            let navigationLayout=NavigationLayout(draft)
            for h in draft.hallways {buildHallway(h,halls:draft.hallways)}
            for h in navigationLayout.bridges {buildHallway(h,halls:[])}
            for w in navigationLayout.barriers where !w.solid {
                addWall(from:w.a,to:w.b,thickness:Float(w.halfWidth*2),color:w.room ? tint(roomColor(UUID()),white:0.57):UIColor(red:0.38,green:0.55,blue:0.65,alpha:1))
            }
            let wallB = UIColor(red: 0.37, green: 0.44, blue: 0.60, alpha: 1)
            for piece in draft.pieces {
                let x = Float(piece.x), z = Float(piece.z)
                let w = Float(piece.width), d = Float(piece.depth)
                let cx = x + w / 2, cz = z + d / 2
                switch piece.kind {
                case .floor:
                    box([w, 0.1, d], at: [cx, -0.08, cz],
                        color: UIColor(red: 0.83, green: 0.88, blue: 0.95, alpha: 1), angle: piece.angle)
                case .wall:
                    box([w, 0.6, d], at: [cx, 0.3, cz], color: wallB, angle: piece.angle)
                case .room:
                    buildRoomFloor(piece)
                    if piece.doorFits {
                        let a = piece.localOutline[piece.doorEdge]
                        let b = piece.localOutline[(piece.doorEdge+1)%piece.localOutline.count]
                        threshold(from: piece.worldPoint(a), to: piece.worldPoint(b), fraction: 0.5,
                                  elevation: 0.066, color: roomColor(piece.id))
                    }
                    let anchor = roomLabelPoint(piece)
                    label(piece.name, at: [Float(anchor.x), 0.12, Float(anchor.y)], width: min(w, 8), depth: min(d, 2))
                }
            }
            positionCamera()
        }

        func buildRoomFloor(_ piece: BuilderPiece) {
            let points = piece.worldOutline
            let h = BuilderHallway(vertices: points.map { HallwayPoint(x: Double($0.x), z: Double($0.y)) }, doors: [])
            guard let triangles = h.triangles else { return }
            var descriptor = MeshDescriptor(name: "Room floor")
            descriptor.positions = MeshBuffers.Positions(points.map { SIMD3<Float>(Float($0.x),0.05,Float($0.y)) })
            descriptor.normals = MeshBuffers.Normals(Array(repeating: SIMD3<Float>(0,1,0),count: points.count))
            descriptor.primitives = .triangles(triangles)
            if let mesh = try? MeshResource.generate(from: [descriptor]) {
                geometry.addChild(ModelEntity(mesh: mesh, materials: [matte(tint(roomColor(piece.id), white: 0.18))]))
            }
        }

        func buildHallway(_ hallway: BuilderHallway, halls: [BuilderHallway]) {
            guard let triangles = hallway.triangles else { return }
            var descriptor = MeshDescriptor(name: "Swearingen lower hallway")
            descriptor.positions = MeshBuffers.Positions(hallway.outline.map {
                SIMD3<Float>(Float($0.x), 0, Float($0.y))
            })
            descriptor.normals = MeshBuffers.Normals(Array(repeating: SIMD3<Float>(0, 1, 0),
                                                           count: hallway.outline.count))
            descriptor.primitives = .triangles(triangles)
            do {
                let mesh = try MeshResource.generate(from: [descriptor])
                geometry.addChild(ModelEntity(mesh: mesh, materials: [matte(UIColor(red: 0.88, green: 0.96, blue: 0.95, alpha: 1))]))
            } catch {
                // A failed mesh must not silently display a different layout.
                label("Floor preview unavailable", at: center + [0, 0.1, 0], width: 30, depth: 3)
            }
            for door in hallway.doors where HallwayUnion.visible(door, in: hallway, halls: halls) {
                threshold(from: hallway.outline[door.edge],
                          to: hallway.outline[(door.edge+1)%hallway.vertices.count],
                          fraction: door.fraction, elevation: 0.025,
                          color: UIColor(red: 0.95, green: 0.67, blue: 0.25, alpha: 1))
                let c = door.center(in: hallway.outline)
                let offset = door.offset(in: hallway.outline)
                label(door.name, at: [Float(c.x + offset.x), 0.1,
                                     Float(c.y + offset.y)], width: 3.5, depth: 1.2)
            }
        }

        func addWall(from a: CGPoint, to b: CGPoint, thickness: Float, color: UIColor) {
            let dx = Float(b.x - a.x), dz = Float(b.y - a.y)
            let length = hypot(dx, dz)
            guard length > 0.00001 else { return }
            let wall = ModelEntity(mesh: .generateBox(size: [thickness, 0.6, length]),
                                   materials: [matte(color)])
            wall.position = [Float((a.x + b.x) / 2), 0.3, Float((a.y + b.y) / 2)]
            wall.orientation = simd_quatf(angle: atan2(dx, dz), axis: [0, 1, 0])
            geometry.addChild(wall)
            let cap = ModelEntity(mesh: .generateBox(size: [thickness, 0.035, length]),
                                  materials: [matte(tint(color, white: 0.38))])
            cap.position = [wall.position.x, 0.6175, wall.position.z]
            cap.orientation = wall.orientation
            geometry.addChild(cap)
        }

        func threshold(from a: CGPoint, to b: CGPoint, fraction: Double, elevation: Float, color: UIColor) {
            let dx = Float(b.x-a.x), dz = Float(b.y-a.y)
            guard hypot(dx,dz) >= 1.5 else { return }
            let strip = ModelEntity(mesh: .generateBox(size: [0.18, 0.016, 1.5]), materials: [matte(color)])
            strip.position = [Float(a.x)+dx*Float(fraction), elevation, Float(a.y)+dz*Float(fraction)]
            strip.orientation = simd_quatf(angle: atan2(dx,dz), axis: [0,1,0])
            geometry.addChild(strip)
        }

        func roomLabelPoint(_ piece: BuilderPiece) -> CGPoint {
            let h = BuilderHallway(vertices: piece.worldOutline.map { HallwayPoint(x: Double($0.x), z: Double($0.y)) }, doors: [])
            let middle = CGPoint(x: piece.x+piece.width/2, y: piece.z+piece.depth/2)
            if HallwayUnion.contains(middle, [h]) { return middle }
            // A concave room's bounding-box center can fall outside its floor.
            guard let ids = h.triangles else { return middle }
            var best = middle, area: CGFloat = -1
            for i in stride(from: 0, to: ids.count, by: 3) {
                let a = h.outline[Int(ids[i])], b = h.outline[Int(ids[i+1])], c = h.outline[Int(ids[i+2])]
                let candidate = abs(HallwayUnion.cross(a,b,c))
                if candidate > area { area = candidate; best = CGPoint(x: (a.x+b.x+c.x)/3, y: (a.y+b.y+c.y)/3) }
            }
            return best
        }

        func label(_ name: String, at position: SIMD3<Float>, width: Float, depth: Float) {
            guard !name.isEmpty, width > 0.4, depth > 0.4 else { return }
            let mesh = MeshResource.generateText(name, extrusionDepth: 0.002,
                font: .systemFont(ofSize: 0.45, weight: .semibold),
                containerFrame: .zero, alignment: .center, lineBreakMode: .byClipping)
            let text = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color:
                UIColor(red: 0.12, green: 0.19, blue: 0.30, alpha: 1))])
            let bounds = text.visualBounds(relativeTo: text)
            let factor = min(1, min((width - 0.3) / max(0.01, bounds.extents.x),
                                    (depth - 0.3) / max(0.01, bounds.extents.y)))
            let plaque = ModelEntity(mesh: .generateBox(size: [bounds.extents.x*factor+0.22, 0.018, bounds.extents.y*factor+0.16]),
                                     materials: [UnlitMaterial(color: UIColor(white: 0.99, alpha: 1))])
            plaque.position = position - [0, 0.028, 0]
            geometry.addChild(plaque)
            text.scale = SIMD3<Float>(repeating: factor)
            text.position = -(bounds.min + bounds.max) / 2 * factor
            let holder = Entity(); holder.addChild(text)
            holder.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            holder.position = position; geometry.addChild(holder)
        }

        func positionCamera() {
            guard let view else { return }
            let aspect = max(0.25, Float(view.bounds.width / max(1, view.bounds.height)))
            let radius = max(0.5,max(extent.x / aspect, extent.y) * 1.5 * zoom)
            let target = center+panOffset
            let eye = target + SIMD3<Float>(sin(yaw) * cos(pitch) * radius,
                                           sin(pitch) * radius, cos(yaw) * cos(pitch) * radius)
            camera.look(at: target, from: eye, relativeTo: nil)
        }
        func cameraActions(_ fit: Int, focus: Int, person: CGPoint?) {
            if lastFit != fit {lastFit=fit;panOffset = .zero;zoom=1;positionCamera()}
            if lastFocus != focus {
                lastFocus=focus
                if let person,let view {
                    panOffset=[Float(person.x)-center.x,0,Float(person.y)-center.z]
                    let aspect=max(0.25,Float(view.bounds.width/max(1,view.bounds.height)))
                    zoom=6/(max(extent.x/aspect,extent.y)*1.5);positionCamera()
                }
            }
        }
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            let delta=gesture.translation(in:view)
            if gesture.numberOfTouches>=2,let view {
                let aspect=max(0.25,Float(view.bounds.width/max(1,view.bounds.height)))
                let radius=max(0.5,max(extent.x/aspect,extent.y)*1.5*zoom)
                let factor=radius/max(100,Float(view.bounds.height))
                let right=SIMD3<Float>(cos(yaw),0,-sin(yaw)),forward=SIMD3<Float>(sin(yaw),0,cos(yaw))
                panOffset -= right*Float(delta.x)*factor
                panOffset -= forward*Float(delta.y)*factor
            } else {
                yaw -= Float(delta.x)*0.006
                pitch=min(1.55,max(0.35,pitch+Float(delta.y)*0.003))
            }
            gesture.setTranslation(.zero,in:view);positionCamera()
        }
        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            zoom = min(20, max(0.000001, zoom / Float(gesture.scale)))
            gesture.scale = 1; positionCamera()
        }
    }
}
