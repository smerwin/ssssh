import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            HostListView()
                .tabItem { Label("Hosts", systemImage: "server.rack") }

            KeyListView()
                .tabItem { Label("Keys", systemImage: "key.fill") }
        }
    }
}

#Preview {
    ContentView()
}
