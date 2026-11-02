import Foundation
import MacSpaceDiskMapPrivileged

/// Intern evidence once; filesystem UID remains independent from application ownership.
enum DiskOwnership {
    private final class Branch {
        var children: [String: Branch] = [:]
        var claims: Set<DiskOwnershipClaim> = []
        var reference: UInt32?
    }
    struct Attribution {
        var claims: [UInt32: DiskOwnershipClaim]
        var directories: [String: UInt32]
        var files: [String: UInt32]
    }
    @discardableResult
    static func assign(to index: inout DiskIndex, catalog: DiskApplications, paths: Set<String>? = nil) -> [UInt32: DiskOwnershipClaim] {
        let result = attribution(index: index, catalog: catalog, paths: paths)
        for path in paths ?? Set(index.directories.keys) {
            index.directories[path]?.ownershipID = result.directories[path]
            if let files = index.directories[path]?.files, !files.isEmpty {
                index.directories[path]?.files = files.map { file in
                    var file = file; file.ownershipID = result.files[file.path]; return file
                }
            }
        }
        for id in index.hardlinks.keys {
            index.hardlinks[id] = index.hardlinks[id]?.map { file in
                guard paths == nil || paths!.contains(parent(file.path)) else { return file }
                var file = file; file.ownershipID = result.files[file.path]; return file
            }
        }
        return result.claims
    }
    private static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }
    private static func name(_ path: String) -> String { String(path[(path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex)...]) }

    static func attribution(index: DiskIndex, catalog: DiskApplications, paths: Set<String>? = nil) -> Attribution {
        let root = Branch()
        for claim in Set(catalog.apps.flatMap(\.ownership)) {
            for path in claim.paths {
                var node = root
                for component in DiskApplications.measuredPath(path, index: index).split(separator: "/") {
                    let component = String(component)
                    if node.children[component] == nil { node.children[component] = Branch() }
                    node = node.children[component]!
                }
                node.claims.insert(claim)
            }
        }
        var result = Attribution(claims: paths == nil ? [:] : index.ownershipClaims ?? [:], directories: [:], files: [:])
        var interned = Dictionary(result.claims.map { ($0.value, $0.key) }, uniquingKeysWith: { min($0, $1) })
        var nextID = result.claims.keys.max() ?? 0
        func intern(_ matching: Set<DiskOwnershipClaim>) -> UInt32? {
            guard !matching.isEmpty else { return nil }
            let owners = Set(matching.flatMap(\.ownerPaths))
            let confidence: OwnershipConfidence
            if owners.count > 1 || matching.contains(where: { $0.confidence == .shared }) { confidence = .shared }
            else if matching.contains(where: { $0.confidence == .unknown }) { confidence = .unknown }
            else if matching.contains(where: { $0.confidence == .inferred }) { confidence = .inferred }
            else { confidence = .verifiedExclusive }
            let evidence: DiskOwnershipClaim
            if matching.count == 1 { evidence = matching.first! }
            else {
                evidence = DiskOwnershipClaim(paths: Array(Set(matching.flatMap(\.paths))), ownerPaths: Array(owners), confidence: confidence,
                    source: "combined:" + Set(matching.map(\.source)).sorted().joined(separator: "+"),
                    reason: "Overlapping evidence; least certain classification preserved. " + Set(matching.map(\.reason)).sorted().joined(separator: " "))
            }
            if let id = interned[evidence] { return id }
            guard nextID < UInt32.max else { return nil }
            nextID += 1
            interned[evidence] = nextID; result.claims[nextID] = evidence
            return nextID
        }
        // Resolve inherited evidence once per evidence branch, rather than hashing it at every measured descendant.
        func prepare(_ node: Branch, inherited: Set<DiskOwnershipClaim>) {
            let matching = inherited.union(node.claims)
            node.reference = intern(matching)
            for child in node.children.values { prepare(child, inherited: matching) }
        }
        prepare(root, inherited: [])
        func branch(_ path: String) -> (Branch?, UInt32?) {
            var node = root, reference = root.reference
            for component in path.split(separator: "/") {
                guard let next = node.children[String(component)] else { return (nil, reference) }
                node = next; reference = node.reference
            }
            return (node, reference)
        }
        func record(_ node: DiskDirectory, branch: Branch?, reference: UInt32?) {
            if let reference { result.directories[node.path] = reference }
            for file in node.files {
                if let id = branch?.children[name(file.path)]?.reference ?? reference { result.files[file.path] = id }
            }
        }
        if paths == nil, index.directories[index.root] != nil {
            let start = branch(index.root)
            var pending = [(index.root, start.0, start.1)]
            while let (path, evidence, inherited) = pending.popLast() {
                guard let node = index.directories[path] else { continue }
                record(node, branch: evidence, reference: inherited)
                for child in node.folders {
                    let next = evidence?.children[name(child)]
                    pending.append((child, next, next?.reference ?? inherited))
                }
            }
        } else {
            for path in paths ?? Set(index.directories.keys) {
                guard let node = index.directories[path] else { continue }
                let matching = branch(path)
                record(node, branch: matching.0, reference: matching.1)
            }
        }
        for files in index.hardlinks.values {
            for file in files where paths == nil || paths!.contains(parent(file.path)) {
                if let id = branch(file.path).1 { result.files[file.path] = id }
            }
        }
        if paths == nil {
            let used = Set(result.directories.values).union(result.files.values)
            result.claims = result.claims.filter { used.contains($0.key) }
        }
        return result
    }
}
