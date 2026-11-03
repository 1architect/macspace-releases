import Foundation
import MacSpaceDiskMapPrivileged

/// Shared combination rule for folder projections and file pages; preserve the least certain evidence.
enum DiskOwnership {
    static func combined(_ claims: [DiskOwnershipClaim], paths: [String]) -> DiskOwnershipClaim {
        if claims.count == 1 { return claims[0] }
        let owners = Set(claims.flatMap(\.ownerPaths))
        let confidence: OwnershipConfidence = owners.count > 1 || claims.contains { $0.confidence == .shared } ? .shared
            : claims.contains { $0.confidence == .unknown } ? .unknown
            : claims.contains { $0.confidence == .inferred } ? .inferred : .verifiedExclusive
        return DiskOwnershipClaim(paths: paths, ownerPaths: owners.sorted(), confidence: confidence,
            source: "combined:" + Set(claims.map(\.source)).sorted().joined(separator: "+"),
            reason: Set(claims.map(\.reason)).sorted().joined(separator: "\n"))
    }
}
