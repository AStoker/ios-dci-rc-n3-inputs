#if canImport(ExternalAccessory) && os(iOS)
import ExternalAccessory
#endif

/// Metadata for one connected External Accessory (a value copy of `EAAccessory`).
public struct AccessoryInfo: Sendable, Identifiable, Hashable, Codable {
    public var id: Int { connectionID }
    public let connectionID: Int
    public let name: String
    public let manufacturer: String
    public let modelNumber: String
    public let serialNumber: String
    public let firmwareRevision: String
    public let hardwareRevision: String
    public let protocolStrings: [String]
    public let isConnected: Bool

    public init(connectionID: Int, name: String, manufacturer: String, modelNumber: String, serialNumber: String,
                firmwareRevision: String, hardwareRevision: String, protocolStrings: [String], isConnected: Bool) {
        self.connectionID = connectionID
        self.name = name
        self.manufacturer = manufacturer
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.firmwareRevision = firmwareRevision
        self.hardwareRevision = hardwareRevision
        self.protocolStrings = protocolStrings
        self.isConnected = isConnected
    }

    #if canImport(ExternalAccessory) && os(iOS)
    package init(_ accessory: EAAccessory) {
        self.init(connectionID: accessory.connectionID, name: accessory.name, manufacturer: accessory.manufacturer,
                  modelNumber: accessory.modelNumber, serialNumber: accessory.serialNumber,
                  firmwareRevision: accessory.firmwareRevision, hardwareRevision: accessory.hardwareRevision,
                  protocolStrings: accessory.protocolStrings, isConnected: accessory.isConnected)
    }
    #endif

    public var logDescription: String {
        "name=\"\(name)\" manufacturer=\"\(manufacturer)\" model=\"\(modelNumber)\" serial=\"\(serialNumber)\" "
            + "fw=\"\(firmwareRevision)\" hw=\"\(hardwareRevision)\" connectionID=\(connectionID) "
            + "connected=\(isConnected) protocols=[\(protocolStrings.joined(separator: ", "))]"
    }
}
