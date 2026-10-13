import SwiftUI

struct ContentView: View {
    // Launch with `-initialTab 3` (Xcode: Scheme > Run > Arguments) to open on a given tab.
    // Launch arguments of the form `-key value` land in UserDefaults automatically.
    @State private var tab = UserDefaults.standard.integer(forKey: "initialTab")

    var body: some View {
        TabView(selection: $tab) {
            Tab("Input", systemImage: "gamecontroller", value: 0) {
                InputView()
            }
            Tab("Overview", systemImage: "antenna.radiowaves.left.and.right", value: 1) {
                OverviewView()
            }
            Tab("Streams", systemImage: "waveform.path.ecg", value: 2) {
                StreamsView()
            }
            Tab("DUML", systemImage: "paperplane", value: 3) {
                DUMLView()
            }
            Tab("Log", systemImage: "list.bullet.rectangle", value: 4) {
                LogView()
            }
        }
    }
}

#Preview {
    ContentView().environment(ProbeModel())
}
