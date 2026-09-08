import Foundation

public struct HostedAudioUnitDescriptor: Codable, Hashable, Sendable {
    public let id: HostedAudioUnitID
    public let name: String
    public let manufacturerName: String
    public let version: UInt32

    public init(
        id: HostedAudioUnitID,
        name: String,
        manufacturerName: String,
        version: UInt32
    ) throws {
        guard Self.isValidText(name), Self.isValidText(manufacturerName) else {
            throw HostedAudioUnitError.invalidDescriptor
        }
        self.id = id
        self.name = name
        self.manufacturerName = manufacturerName
        self.version = version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(HostedAudioUnitID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            manufacturerName: container.decode(String.self, forKey: .manufacturerName),
            version: container.decode(UInt32.self, forKey: .version)
        )
    }

    private static func isValidText(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case manufacturerName
        case version
    }
}
