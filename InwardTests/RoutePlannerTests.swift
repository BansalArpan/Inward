import XCTest
@testable import Inward

final class RoutePlannerTests: XCTestCase {
    private func fixture() throws -> BuildingMap {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "navigation", withExtension: "json"))
        return try BuildingMap.load(from: url)
    }

    func testEntranceTo103() throws {
        let map = try fixture()
        let route = try XCTUnwrap(RoutePlanner.route(in: map, from: "entry", to: "103"))
        XCTAssertEqual(route.nodeIDs, ["entry", "D", "A", "B", "C", "103"])
        XCTAssertEqual(route.length, 33, accuracy: 0.001)
        XCTAssertEqual(route.instruction(for: 1).text, "Turn left")
        XCTAssertEqual(route.instruction(for: 2).text, "Turn right")
    }

    func testClosureFindsDetour() throws {
        let map = try fixture()
        let route = try XCTUnwrap(RoutePlanner.route(in: map, from: "entry", to: "103", blocked: [RoutePlanner.edgeKey("B", "C")]))
        XCTAssertEqual(route.length, 47, accuracy: 0.001)
        let keys = zip(route.nodeIDs, route.nodeIDs.dropFirst()).map { RoutePlanner.edgeKey($0, $1) }
        XCTAssertFalse(keys.contains(RoutePlanner.edgeKey("B", "C")))
    }

    func testDisconnectedDestinationIsUnreachable() throws {
        let map = try fixture()
        XCTAssertNil(RoutePlanner.route(in: map, from: "entry", to: "103", blocked: [RoutePlanner.edgeKey("C", "103")]))
    }

    func testAlreadyAtDestination() throws {
        let map = try fixture()
        let route = try XCTUnwrap(RoutePlanner.route(in: map, from: "entry", to: "entry"))
        XCTAssertEqual(route.length, 0)
        XCTAssertEqual(route.sample(at: 100).point, MapPoint(x: 4, z: 15))
    }

    func testSamplingStaysOnPath() throws {
        let map = try fixture()
        let route = try XCTUnwrap(RoutePlanner.route(in: map, from: "entry", to: "103"))
        XCTAssertEqual(route.sample(at: 2).point, MapPoint(x: 6, z: 15))
        XCTAssertEqual(route.sample(at: 4).point, MapPoint(x: 8, z: 15))
        XCTAssertEqual(route.sample(at: 5).point, MapPoint(x: 8, z: 14))
        XCTAssertEqual(route.sample(at: 100).point, MapPoint(x: 28, z: 6))
    }

    func testAllRoomPairsFollowExistingEdges() throws {
        let map = try fixture()
        let edges = Set(map.edges.map { RoutePlanner.edgeKey($0[0], $0[1]) })
        for a in map.rooms {
            for b in map.rooms {
                let route = try XCTUnwrap(RoutePlanner.route(in: map, from: a.node, to: b.node))
                XCTAssertEqual(route.nodeIDs.first, a.node)
                XCTAssertEqual(route.nodeIDs.last, b.node)
                for (u, v) in zip(route.nodeIDs, route.nodeIDs.dropFirst()) {
                    XCTAssertTrue(edges.contains(RoutePlanner.edgeKey(u, v)))
                }
            }
        }
    }

    func testBadRoomMetadataIsRejected() throws {
        let map = try fixture()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(map)) as? [String: Any])
        object["rooms"] = [["id": "broken", "name": "Broken room", "kind": "Test", "node": "missing", "rect": [1, 1, 4, 4]]]
        let broken = try JSONDecoder().decode(BuildingMap.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try broken.validate())
    }
}
