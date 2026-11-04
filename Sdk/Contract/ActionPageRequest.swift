import Foundation

/// A selection action can open a module page with its frozen IDs and review metadata.
/// The host carries this envelope; only the owning module interprets its parameters.
public struct ActionPageRequest: Codable, Equatable, Sendable {
    public var destination: String
    public var parameters: [String: String]
    public init(destination: String, parameters: [String: String]) {
        self.destination = destination; self.parameters = parameters
    }
    public var pageID: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return "action-page:" + ((try? encoder.encode(self)) ?? Data()).base64EncodedString()
    }
    public init?(pageID: String) {
        guard pageID.hasPrefix("action-page:"), pageID.utf8.count <= 1_500_000,
              let data = Data(base64Encoded: String(pageID.dropFirst("action-page:".count))), data.count <= 1_048_576,
              let value = try? JSONDecoder().decode(Self.self, from: data), !value.destination.isEmpty,
              value.destination.utf8.count <= 4096, value.parameters.count <= 256 else { return nil }
        self = value
    }
}
