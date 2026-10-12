import RCKit
import SwiftUI

/// Connection panel: what iOS exposes right now, across every transport we probe.
struct OverviewView: View {
    @Environment(ProbeModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section {
                    StatusRow(title: "EA accessories", value: "\(model.accessories.count)",
                              good: !model.accessories.isEmpty, symbol: "cable.connector")
                    StatusRow(title: "Open EA sessions", value: "\(model.liveSessionCount) / \(model.sessions.count)",
                              good: model.liveSessionCount > 0, symbol: "arrow.left.arrow.right")
                    StatusRow(title: "DUML frames received", value: "\(model.totalDumlFrames)",
                              good: model.totalDumlFrames > 0, symbol: "shippingbox")
                    StatusRow(title: "Last packet", value: model.lastPacketAge.map(Format.age) ?? "never",
                              good: (model.lastPacketAge ?? .infinity) < 1, symbol: "clock")
                    StatusRow(title: "GameController devices", value: "\(model.devices.count)",
                              good: !model.devices.isEmpty, symbol: "gamecontroller")
                } header: {
                    Text("Summary")
                } footer: {
                    Text("Plug the RC-N3 in and turn it on. Green rows mean iOS is exposing something.")
                }

                Section {
                    Toggle("Auto-open sessions", isOn: $model.autoOpenSessions)
                    if model.accessories.isEmpty {
                        Text("No External Accessory visible. iOS only lists accessories that speak a protocol this app declares.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.accessories) { accessory in
                        AccessoryCard(accessory: accessory)
                    }
                } header: {
                    Text("External Accessory")
                }

                Section("GameController framework") {
                    if model.devices.isEmpty {
                        Text("No controllers, keyboards or mice.").foregroundStyle(.secondary)
                    }
                    ForEach(model.devices) { device in
                        GameControllerCard(device: device)
                    }
                }

                Section {
                    ForEach(model.interfaces.filter { $0.family != "link" || !model.launchInterfaceIDs.contains($0.id) }) { interface in
                        let isNew = !model.launchInterfaceIDs.contains(interface.id)
                        HStack {
                            Text(interface.name).font(.body.monospaced()).bold(isNew)
                            Text(interface.family).foregroundStyle(.secondary)
                            Spacer()
                            Text(interface.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                            if isNew { Text("NEW").font(.caption2.bold()).foregroundStyle(.orange) }
                        }
                    }
                } header: {
                    Text("Network interfaces")
                } footer: {
                    Text("Some DJI devices expose USB networking in PC mode. NEW marks interfaces that appeared after launch.")
                }

                Section("Environment") {
                    LabeledContent("Device", value: model.environment.deviceModel)
                    LabeledContent("OS", value: model.environment.osVersion)
                    LabeledContent("App", value: "\(model.environment.appVersion) (\(model.environment.appBuild))")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Declared EA protocols")
                        ForEach(model.environment.declaredAccessoryProtocols, id: \.self) { proto in
                            Text(proto).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("RC-N3 Probe")
        }
    }
}

private struct StatusRow: View {
    let title: String
    let value: String
    let good: Bool
    let symbol: String

    var body: some View {
        HStack {
            Image(systemName: symbol)
                .foregroundStyle(good ? .green : .secondary)
                .frame(width: 24)
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(good ? .primary : .secondary)
        }
    }
}

private struct AccessoryCard: View {
    @Environment(ProbeModel.self) private var model
    let accessory: AccessoryInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(accessory.name.isEmpty ? "(no name)" : accessory.name).font(.headline)
            Group {
                MetaRow(label: "Manufacturer", value: accessory.manufacturer)
                MetaRow(label: "Model", value: accessory.modelNumber)
                MetaRow(label: "Serial", value: accessory.serialNumber)
                MetaRow(label: "Firmware", value: accessory.firmwareRevision)
                MetaRow(label: "Hardware", value: accessory.hardwareRevision)
                MetaRow(label: "Connection ID", value: "\(accessory.connectionID)")
            }
            Text("Protocol strings").font(.subheadline.bold()).padding(.top, 4)
            ForEach(accessory.protocolStrings, id: \.self) { proto in
                ProtocolRow(accessoryID: accessory.connectionID, protocolString: proto,
                            declared: model.environment.declaredAccessoryProtocols.contains(proto))
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MetaRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "—" : value).font(.callout.monospaced()).textSelection(.enabled)
        }
        .font(.callout)
    }
}

private struct ProtocolRow: View {
    @Environment(ProbeModel.self) private var model
    let accessoryID: Int
    let protocolString: String
    let declared: Bool

    var body: some View {
        let session = model.session(id: "\(accessoryID)|\(protocolString)")
        HStack {
            VStack(alignment: .leading) {
                Text(protocolString).font(.callout.monospaced())
                Text(declared ? (session?.state.label ?? "no session") : "not declared in Info.plist")
                    .font(.caption)
                    .foregroundStyle(session?.state == .open ? .green : .secondary)
            }
            Spacer()
            if declared {
                Button(session?.state.isLive == true ? "Close" : "Open") {
                    model.toggleSession(accessoryID: accessoryID, protocolString: protocolString)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

private struct GameControllerCard: View {
    let device: GameControllerProbe.Device

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(device.vendorName) · \(device.kind.rawValue)").font(.headline)
            Text(device.productCategory).foregroundStyle(.secondary)
            ForEach(device.details, id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.secondary) }
            ForEach(device.elements) { element in
                HStack {
                    Text(element.id).font(.caption)
                    Spacer()
                    Text(element.display).font(.caption.monospaced())
                        .foregroundStyle(element.isPressed == true ? .orange : .primary)
                }
            }
        }
    }
}
