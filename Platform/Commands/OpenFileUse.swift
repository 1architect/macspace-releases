import Darwin
import Foundation

/// Positive evidence of descriptors currently held by this account. Absence is never evidence of nonuse.
public enum OpenFileUse {
    public struct Reader: Equatable, Sendable { public var process: String; public var canRead: Bool }
    public static func inspect(_ paths: Set<String>, includesDescendants: Bool = false) -> [String: [Reader]] {
        guard !paths.isEmpty else { return [:] }
        func canonical(_ path: String) -> String {
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }; return String(cString: resolved)
        }
        let originals = Dictionary(grouping: paths, by: canonical)
        var result: [String: [Reader]] = [:]
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard needed > 0 else { return result }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 64)
        let filled = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return result }
        for pid in pids.prefix(Int(filled) / MemoryLayout<pid_t>.size) where pid > 0 {
            var name = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { continue }
            let label = String(cString: name)
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size + 32)
            let read = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * MemoryLayout<proc_fdinfo>.size))
            guard read > 0 else { continue }
            for fd in descriptors.prefix(Int(read) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else { continue }
                let path = withUnsafePointer(to: info.pvip.vip_path) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
                let actual = canonical(path)
                let matches = originals[actual] ?? (includesDescendants ? originals.filter { actual.hasPrefix($0.key + "/") }.flatMap(\.value) : [])
                guard !matches.isEmpty else { continue }
                let reader = Reader(process: label, canRead: info.pfi.fi_openflags & UInt32(FREAD) != 0)
                for original in matches where result[original]?.contains(reader) != true { result[original, default: []].append(reader) }
            }
        }
        return result
    }
}
