import SwiftUI

@main
struct InwardApp: App {
    var body: some Scene {
        //WindowGroup { BootstrapView() }
        WindowGroup { BuildingEditorView() }
    }
}

@MainActor
private struct BootstrapView: View {
    @State private var model: NavigationModel?
    @State private var error: String?
    var body: some View {
        Group {
            if let model { ContentView(model: model) }
            else if let error {
                ContentUnavailableView("Map unavailable", systemImage: "map", description: Text(error))
            } else { ProgressView("Opening your building…") }
        }
        .task {
            guard model == nil && error == nil else { return }
            do {
                guard let url = Bundle.main.url(forResource: "navigation", withExtension: "json") else {
                    throw MapError.invalid("navigation.json is missing from the app target’s resources.")
                }
                model = NavigationModel(map: try BuildingMap.load(from: url))
            } catch { self.error = error.localizedDescription }
        }
    }
}
