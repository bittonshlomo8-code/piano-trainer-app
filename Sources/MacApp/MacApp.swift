import SwiftUI

@main
struct PianoTrainerApp: App {
    @StateObject private var appVM = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appVM)
                .onAppear { appVM.loadProjects() }
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Import Media…") {
                    NotificationCenter.default.post(name: .importMedia, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let importMedia = Notification.Name("PianoTrainer.importMedia")
}
