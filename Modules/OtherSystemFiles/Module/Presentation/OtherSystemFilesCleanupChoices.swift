import Foundation
import MacSpaceSdk
import MacSpacePlatform

extension OtherSystemFilesScreenBuilder {
    static func cleanupChoices(_ screen: Screen, _ snapshot: PurgeableSnapshot) -> Screen {
        screen.mappingCleanup { row in
            guard let action = row.actions.first(where: { ["purgeFiles", "removeDownloads", "freeSnapshots"].contains($0.id) }) else { return row }
            let bytes: UInt64
            switch action.id {
            case "purgeFiles": bytes = snapshot.freeableBytes
            case "removeDownloads": bytes = snapshot.documents.first { $0.path == action.parameters["path"] }?.bytes ?? 0
            default: bytes = snapshot.services?[CacheDeleteService.timeMachineSnapshots] ?? 0
            }
            return row.selectingCleanup(action, bytes: bytes, defaultSelected: action.id == "purgeFiles")
        }
    }
}
