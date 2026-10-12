import SwiftUI

struct ContentView: View {
    // Launch with `-initialTab 2` (Xcode: Scheme > Run > Arguments) to open on a given tab.
    // Launch arguments of the form `-key value` land in UserDefaults automatically.
    @State private var tab = UserDefaults.standard.integer(forKey: "initialTab")

    var body: some View {
        TabView(selection: $tab) {
            Tab("Overview", systemImage: "antenna.radiowaves.left.and.right", value: 0) {
                OverviewView()
            }
            Tab("Streams", systemImage: "waveform.path.ecg", value: 1) {
                StreamsView()
            }
            Tab("DUML", systemImage: "paperplane", value: 2) {
                DUMLView()
            }
            Tab("Log", systemImage: "list.bullet.rectangle", value: 3) {
                LogView()
            }
        }
    }
}

#Preview {
    ContentView().environment(ProbeModel())
}
