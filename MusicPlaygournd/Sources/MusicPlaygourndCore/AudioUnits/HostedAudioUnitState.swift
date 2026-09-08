import Foundation

public struct HostedAudioUnitState: Codable, Hashable, Sendable {
    public let id: HostedAudioUnitID
    public let data: Data

    public init(id: HostedAudioUnitID, data: Data) throws {
        guard data.count >= 1, data.count <= Self.maximumByteCount else {
            throw HostedAudioUnitError.invalidState
        }
        var format = PropertyListSerialization.PropertyListFormat.binary
        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        } catch {
            throw HostedAudioUnitError.invalidState
        }
        guard format == .binary, propertyList is [String: Any] else {
            throw HostedAudioUnitError.invalidState
        }
        self.id = id
        self.data = data
    }

    internal init(id: HostedAudioUnitID, documentState: [String: Any]?) throws {
        guard let documentState else {
            throw HostedAudioUnitError.stateUnavailable
        }
        guard PropertyListSerialization.propertyList(documentState, isValidFor: .binary) else {
            throw HostedAudioUnitError.invalidState
        }
        let data: Data
        do {
            data = try PropertyListSerialization.data(
                fromPropertyList: documentState,
                format: .binary,
                options: 0
            )
        } catch {
            throw HostedAudioUnitError.invalidState
        }
        try self.init(id: id, data: data)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(HostedAudioUnitID.self, forKey: .id)
        let data = try container.decode(Data.self, forKey: .data)
        try self.init(id: id, data: data)
    }

    internal func propertyList() throws -> [String: Any] {
        var format = PropertyListSerialization.PropertyListFormat.binary
        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        } catch {
            throw HostedAudioUnitError.invalidState
        }
        guard format == .binary, let dictionary = propertyList as? [String: Any] else {
            throw HostedAudioUnitError.invalidState
        }
        return dictionary
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case data
    }

    private static let maximumByteCount = 1_048_576
}
