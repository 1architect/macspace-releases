import Foundation
import MacSpaceSdk

extension SystemDataScreenBuilder {
    static func cleanupChoices(_ screen: Screen, _ snapshot: SystemDataSnapshot) -> Screen {
        let sizes: [String: UInt64] = [
            "reports": snapshot.reports.totalBytes, "assets": snapshot.purgeableAssetsBytes ?? 0,
            "system-log": unifiedLogBytes(snapshot), "symbols": symbolsBytes(snapshot),
            "versions": versionHistoryBytes(snapshot),
            "trash": snapshot.report.items.first { $0.id == "trash:user" }?.bytes ?? 0,
            "leftover-update": snapshot.report.items.first { $0.id == "update:staged" }?.bytes ?? 0,
            "wallpaper-downloads": snapshot.report.items.filter { $0.id.hasPrefix(wallpaperDownloadsPrefix) }.compactMap(\.bytes).reduce(0, +)
        ]
        let operations: Set<String> = ["clean", "cleanReports", "purgeAssets", "emptyTrash", "eraseUnifiedLog", "deleteSymbolicationCache", "deleteStagedUpdate", "deleteWallpaperDownloads", "deleteVersions", "removeDownloads"]
        return screen.mappingCleanup { original in
            var row = original
            if row.id == CachesPage.groupID, row.selection != nil {
                let chosen = CachesPage.chosen(snapshot)
                guard !chosen.isEmpty else { return row }
                var action = row.selection!.action
                action.parameters["ids"] = Selection.parameter(chosen.map(\.id))
                action.confirmation?.message = CachesPage.quitNote(chosen) ?? ""
                return row.selectingCleanup(action, bytes: chosen.reduce(0) { $0 + $1.bytes }, defaultSelected: true)
            }
            guard let action = row.actions.first(where: { operations.contains($0.id) }) else { return row }
            let bytes = sizes[row.id] ?? snapshot.cloudSources.first { $0.path == action.parameters["path"] }?.bytes
                ?? snapshot.report.items.first { $0.id == action.parameters["id"] }?.bytes ?? 0
            row = row.selectingCleanup(action, bytes: bytes, defaultSelected: ["cleanReports", "purgeAssets"].contains(action.id))
            return row
        }
    }
}
