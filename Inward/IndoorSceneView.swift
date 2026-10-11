import SwiftUI
import RealityKit
import UIKit
import simd

/// RealityKit's non-AR camera: both modes are views of the same world-space route.
struct IndoorSceneView: UIViewRepresentable {
    @ObservedObject var model: NavigationModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(UIColor(red: 0.94, green: 0.95, blue: 0.98, alpha: 1))
        context.coordinator.configure(view)
        return view
    }
    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.update()
    }

    @MainActor
    final class Coordinator: NSObject {
        let model: NavigationModel
        weak var view: ARView?
        let world = AnchorEntity(world: .zero)
        let camera = PerspectiveCamera()
        let mockGeometry = Entity()
        let wallRoot = Entity()
        let mapLabels = Entity()
        let routeRoot = Entity()
        let userMarker = Entity()
        var scan: Entity?
        var roomFloors: [String: ModelEntity] = [:]
        var doorSigns: [Entity] = []
        var routeRevision = -1
        var recenterRevision = -1
        var lastMode: MapViewMode?
        var orbitYaw: Float = 0
        var pitch: Float = 1.0
        var zoom: Float = 1
        var lookOffset: Float = 0
        var center = SIMD3<Float>(18, 0, 15)
        var extent = SIMD2<Float>(38, 32)
        let purple = UIColor(red: 0.43, green: 0.31, blue: 0.90, alpha: 1)

        init(model: NavigationModel) { self.model = model }

        func configure(_ view: ARView) {
            self.view = view
            view.scene.addAnchor(world)
            world.addChild(mockGeometry)
            mockGeometry.addChild(wallRoot)
            mockGeometry.addChild(mapLabels)
            world.addChild(routeRoot)
            world.addChild(userMarker)
            world.addChild(camera)
            camera.camera.fieldOfViewInDegrees = 58
            buildMockBuilding()
            let marker = box(size: [0.48, 0.2, 0.48], color: purple)
            marker.position.y = 0.2
            userMarker.addChild(marker)
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
            view.addGestureRecognizer(tap); view.addGestureRecognizer(pan); view.addGestureRecognizer(pinch)
            // USDZ is optional. Keep the mock overview even when a scan is present,
            // so roofs and ceilings cannot occlude the bird's-eye navigation layer.
            if let url = Bundle.main.url(forResource: "building", withExtension: "usdz") {
                do {
                    let entity = try Entity.load(contentsOf: url)
                    scan = entity; world.addChild(entity)
                    DispatchQueue.main.async { [weak self] in self?.model.hasScan = true }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.model.sceneMessage = "The scan could not load. Showing the mock building: \(error.localizedDescription)"
                    }
                }
            }
            update()
            DispatchQueue.main.async { [weak self] in self?.update() }
        }

        func box(size: SIMD3<Float>, color: UIColor) -> ModelEntity {
            ModelEntity(mesh: .generateBox(size: size), materials: [UnlitMaterial(color: color)])
        }
        func point(_ p: MapPoint, y: Float = 0) -> SIMD3<Float> { [Float(p.x), y, Float(p.z)] }

        func buildMockBuilding() {
            let rects = model.map.rooms.map(\.rect)
            let minX = Float(min(rects.map { $0[0] }.min()!, model.map.nodes.map(\.x).min()!)) - 2
            let maxX = Float(max(rects.map { $0[0] + $0[2] }.max()!, model.map.nodes.map(\.x).max()!)) + 2
            let minZ = Float(min(rects.map { $0[1] }.min()!, model.map.nodes.map(\.z).min()!)) - 2
            let maxZ = Float(max(rects.map { $0[1] + $0[3] }.max()!, model.map.nodes.map(\.z).max()!)) + 2
            center = [(minX + maxX) / 2, 0, (minZ + maxZ) / 2]
            extent = [maxX - minX, maxZ - minZ]
            let ground = box(size: [extent.x, 0.1, extent.y], color: UIColor(red: 0.86, green: 0.89, blue: 0.94, alpha: 1))
            ground.position = center + [0, -0.08, 0]; mockGeometry.addChild(ground)
            let lookup = model.map.nodeLookup
            for edge in model.map.edges {
                let a = point(lookup[edge[0]]!.point), b = point(lookup[edge[1]]!.point)
                mockGeometry.addChild(segment(a, b, width: 2.3, height: 0.04, color: .white))
            }
            for room in model.map.rooms {
                let r = room.rect.map(Float.init)
                let floor = box(size: [r[2], 0.08, r[3]], color: floorColor(room))
                floor.position = [r[0] + r[2] / 2, 0.05, r[1] + r[3] / 2]
                floor.name = "room:" + room.id
                floor.generateCollisionShapes(recursive: false)
                mockGeometry.addChild(floor); roomFloors[room.id] = floor
                let door = point(lookup[room.node]!.point)
                addWalls(rect: r, door: door, id: room.id)
                let label = text(room.name, size: min(0.48, r[2] / Float(max(1, room.name.count)) * 1.6), color: UIColor(red: 0.29, green: 0.34, blue: 0.45, alpha: 1))
                label.position = [r[0] + r[2] / 2, 0.16, r[1] + r[3] / 2]
                label.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
                mapLabels.addChild(label)
                let sign = text(room.name, size: 0.22, color: UIColor(red: 0.22, green: 0.25, blue: 0.36, alpha: 1))
                sign.position = [door.x, 2.1, door.z]
                mockGeometry.addChild(sign); doorSigns.append(sign)
            }
        }

        func floorColor(_ room: MapRoom) -> UIColor {
            if room.id == model.destinationID { return UIColor(red: 0.95, green: 0.82, blue: 0.65, alpha: 1) }
            if room.kind == "Quiet space" { return UIColor(red: 0.70, green: 0.83, blue: 0.75, alpha: 1) }
            return UIColor(red: 0.80, green: 0.83, blue: 0.91, alpha: 1)
        }

        func text(_ value: String, size: Float, color: UIColor) -> Entity {
            let mesh = MeshResource.generateText(value, extrusionDepth: 0.002,
                font: .systemFont(ofSize: CGFloat(size), weight: .semibold),
                containerFrame: .zero, alignment: .center, lineBreakMode: .byWordWrapping)
            let label = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])
            let bounds = label.visualBounds(relativeTo: label)
            label.position.x = -(bounds.min.x + bounds.max.x) / 2
            let parent = Entity(); parent.addChild(label); return parent
        }

        func addWalls(rect r: [Float], door: SIMD3<Float>, id: String) {
            let corners: [SIMD3<Float>] = [[r[0], 0, r[1]], [r[0] + r[2], 0, r[1]], [r[0] + r[2], 0, r[1] + r[3]], [r[0], 0, r[1] + r[3]]]
            let distances = [abs(door.z - r[1]), abs(door.x - (r[0] + r[2])), abs(door.z - (r[1] + r[3])), abs(door.x - r[0])]
            let openingSide = distances.indices.min { distances[$0] < distances[$1] }!
            func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>, side: Int) {
                guard simd_distance(a, b) > 0.03 else { return }
                let colors = [UIColor(red: 0.92, green: 0.94, blue: 0.98, alpha: 1), UIColor(red: 0.77, green: 0.81, blue: 0.88, alpha: 1)]
                let wall = segment(a, b, width: 0.12, height: 2.7, color: colors[side % 2])
                wall.position.y = 1.35; wall.name = "room:" + id
                wall.generateCollisionShapes(recursive: false); wallRoot.addChild(wall)
            }
            for i in 0..<4 {
                let a = corners[i], b = corners[(i + 1) % 4]
                if i == openingSide {
                    let length = simd_distance(a, b), direction = simd_normalize(b - a)
                    let along = simd_dot(door - a, direction)
                    let left = max(0, min(length, along - 0.8)), right = max(0, min(length, along + 0.8))
                    add(a, a + direction * left, side: i)
                    add(a + direction * right, b, side: i)
                } else { add(a, b, side: i) }
            }
        }

        func segment(_ a: SIMD3<Float>, _ b: SIMD3<Float>, width: Float, height: Float, color: UIColor) -> ModelEntity {
            let delta = b - a
            let entity = box(size: [width, height, max(0.001, simd_length(delta))], color: color)
            entity.position = (a + b) / 2
            entity.orientation = simd_quatf(angle: atan2(delta.x, delta.z), axis: [0, 1, 0])
            return entity
        }

        func arrow() -> Entity {
            let group = Entity()
            group.addChild(segment([0, 0, 0.35], [0, 0, -0.35], width: 0.14, height: 0.025, color: purple))
            group.addChild(segment([-0.32, 0, -0.03], [0, 0, -0.39], width: 0.14, height: 0.025, color: purple))
            group.addChild(segment([0.32, 0, -0.03], [0, 0, -0.39], width: 0.14, height: 0.025, color: purple))
            return group
        }

        func rebuildRoute() {
            for child in Array(routeRoot.children) { child.removeFromParent() }
            for room in model.map.rooms { roomFloors[room.id]?.model?.materials = [UnlitMaterial(color: floorColor(room))] }
            if let route = model.route {
                for (a, b) in zip(route.points, route.points.dropFirst()) {
                    let start = point(a, y: 0.12), end = point(b, y: 0.12)
                    let length = simd_distance(start, end), direction = simd_normalize(end - start)
                    let line = segment(start, end, width: 0.07, height: 0.015, color: purple.withAlphaComponent(0.55))
                    routeRoot.addChild(line)
                    for d in stride(from: Float(0.8), to: length, by: 1.6) {
                        let chevron = arrow(); chevron.position = start + direction * d
                        chevron.orientation = simd_quatf(angle: atan2(-direction.x, -direction.z), axis: [0, 1, 0])
                        routeRoot.addChild(chevron)
                    }
                }
            }
            if let target = model.map.nodeLookup[model.destination.node] {
                let destination = box(size: [0.65, 0.14, 0.65], color: .systemOrange)
                destination.position = point(target.point, y: 0.17); routeRoot.addChild(destination)
            }
            if model.hallwayClosed, let edge = model.map.demoClosure {
                let a = point(model.map.nodeLookup[edge[0]]!.point, y: 0.2)
                let b = point(model.map.nodeLookup[edge[1]]!.point, y: 0.2)
                let blocker = segment((a + b) / 2 - [0, 0, 1], (a + b) / 2 + [0, 0, 1], width: 0.12, height: 0.4, color: .systemRed)
                routeRoot.addChild(blocker)
            }
        }

        func update() {
            guard let view else { return }
            if routeRevision != model.routeRevision {
                routeRevision = model.routeRevision; lookOffset = 0; rebuildRoute()
            }
            if recenterRevision != model.recenterRevision {
                recenterRevision = model.recenterRevision; orbitYaw = 0; pitch = 1.0; zoom = 1; lookOffset = 0
            }
            let overview = model.mode == .overview
            if lastMode != model.mode { lookOffset = 0; lastMode = model.mode }
            mockGeometry.isEnabled = overview || scan == nil
            scan?.isEnabled = !overview
            wallRoot.scale.y = overview ? 0.22 : 1
            mapLabels.isEnabled = overview
            for sign in doorSigns { sign.isEnabled = !overview }
            userMarker.isEnabled = overview
            userMarker.position = point(model.position)
            if overview {
                let aspect = max(0.35, Float(view.bounds.width / max(1, view.bounds.height)))
                let radius = max(extent.x / (1.02 * aspect), extent.y / 1.02) * 1.3 * zoom
                let eye = center + SIMD3<Float>(sin(orbitYaw) * cos(pitch) * radius, sin(pitch) * radius, cos(orbitYaw) * cos(pitch) * radius)
                camera.look(at: center, from: eye, relativeTo: nil)
            } else {
                let eye = point(model.position, y: 1.6), heading = model.heading
                let dx = Float(heading.x), dz = Float(heading.z)
                let direction = SIMD3<Float>(dx * cos(lookOffset) + dz * sin(lookOffset), -0.13, -dx * sin(lookOffset) + dz * cos(lookOffset))
                camera.look(at: eye + direction, from: eye, relativeTo: nil)
                for sign in doorSigns {
                    let offset = eye - sign.position
                    sign.orientation = simd_quatf(angle: atan2(offset.x, offset.z), axis: [0, 1, 0])
                }
            }
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard model.mode == .overview, let view else { return }
            var hit = view.entity(at: recognizer.location(in: view))
            while let entity = hit {
                if entity.name.hasPrefix("room:") {
                    model.selectDestination(String(entity.name.dropFirst(5))); return
                }
                hit = entity.parent
            }
        }
        @objc func panned(_ recognizer: UIPanGestureRecognizer) {
            let change = recognizer.translation(in: view)
            if model.mode == .overview {
                orbitYaw -= Float(change.x) * 0.006
                pitch = min(1.5, max(0.6, pitch + Float(change.y) * 0.003))
            } else { lookOffset -= Float(change.x) * 0.005 }
            recognizer.setTranslation(.zero, in: view); update()
        }
        @objc func pinched(_ recognizer: UIPinchGestureRecognizer) {
            guard model.mode == .overview else { return }
            zoom = min(2.5, max(0.45, zoom / Float(recognizer.scale)))
            recognizer.scale = 1; update()
        }
    }
}
