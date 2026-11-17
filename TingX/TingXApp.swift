import SwiftUI

@main
struct TingXApp: App {
    @StateObject private var library = AudioLibrary()
    var body: some Scene {
        WindowGroup { RootView().environmentObject(library) }
    }
}
