import Darwin
import Foundation

/// A read-only inventory of ordinary local Codex runtimes in the current user
/// account. It does not acquire flock locks or launch a helper process.
///
/// This covers non-ephemeral LocalThreadStore sessions. Ephemeral/in-memory
/// sessions do not promise a writer lock and are outside this monitor's scope.
nonisolated struct MacCodexWriterInventory: Sendable {
    var threadIDs: Set<String>
    var isComplete: Bool
    var runtimeCount: Int

    static func capture(codexHome: URL) -> Self {
        let lockRoot = codexHome.resolvingSymlinksInPath()
            .appendingPathComponent("thread-writer-locks").path + "/"
        var complete = true
        var threadIDs = Set<String>()
        var runtimeCount = 0
        guard let pids = currentUserProcesses() else {
            return Self(threadIDs: [], isComplete: false, runtimeCount: 0)
        }
        for pid in pids where pid > 0 {
            switch runtimeIdentity(pid) {
            case .unrelated:
                continue
            case .unavailable:
                complete = false
                continue
            case .codex:
                runtimeCount += 1
            }
            guard let descriptors = fileDescriptors(pid) else {
                if !hasExited(pid) { complete = false }
                continue
            }
            for descriptor in descriptors where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var information = vnode_fdinfowithpath()
                errno = 0
                let bytes = proc_pidfdinfo(
                    pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO,
                    &information, Int32(MemoryLayout.size(ofValue: information))
                )
                guard bytes == MemoryLayout.size(ofValue: information) else {
                    // Closing a descriptor or exiting during the snapshot is normal.
                    if errno != EBADF && errno != ESRCH { complete = false }
                    continue
                }
                let path = withUnsafeBytes(of: &information.pvip.vip_path) {
                    String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                guard path.hasPrefix(lockRoot), path.hasSuffix(".lock") else { continue }
                let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                guard UUID(uuidString: name) != nil else {
                    complete = false
                    continue
                }
                threadIDs.insert(name.lowercased())
            }
        }
        return Self(threadIDs: threadIDs, isComplete: complete, runtimeCount: runtimeCount)
    }

    private enum RuntimeIdentity {
        case codex
        case unrelated
        case unavailable
    }

    private static func runtimeIdentity(_ pid: pid_t) -> RuntimeIdentity {
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro (4 * MAXPATHLEN).
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        errno = 0
        let pathBytes = path.withUnsafeMutableBytes {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        if pathBytes > 0 {
            return isRuntimeName(URL(fileURLWithPath: decodeCString(path)).lastPathComponent)
                ? .codex : .unrelated
        }
        if errno == ESRCH { return .unrelated }
        // Protected non-Codex processes can still expose their comm. Do not
        // inspect their descriptors or treat their protected files as Codex data.
        var name = [CChar](repeating: 0, count: 256)
        errno = 0
        let nameBytes = name.withUnsafeMutableBytes {
            proc_name(pid, $0.baseAddress, UInt32($0.count))
        }
        if nameBytes > 0 { return isRuntimeName(decodeCString(name)) ? .codex : .unrelated }
        return hasExited(pid) ? .unrelated : .unavailable
    }

    private static func isRuntimeName(_ name: String) -> Bool {
        let name = name.lowercased()
        return name == "codex" || name == "codex-cli"
            || (name.contains("codex") && (name.contains("server") || name.contains("daemon")))
    }

    private static func decodeCString(_ value: [CChar]) -> String {
        String(decoding: value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func currentUserProcesses() -> [pid_t]? {
        let expected = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(getuid()), nil, 0)
        guard expected > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(expected) / MemoryLayout<pid_t>.stride + 128)
        let capacity = pids.count * MemoryLayout<pid_t>.stride
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), UInt32(getuid()), $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0, bytes < capacity, Int(bytes) % MemoryLayout<pid_t>.stride == 0 else { return nil }
        return Array(pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride))
    }

    private static func fileDescriptors(_ pid: pid_t) -> [proc_fdinfo]? {
        errno = 0
        let expected = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard expected > 0 else { return hasExited(pid) ? [] : nil }
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: Int(expected) / MemoryLayout<proc_fdinfo>.stride + 64
        )
        let capacity = descriptors.count * MemoryLayout<proc_fdinfo>.stride
        let bytes = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0, bytes < capacity, Int(bytes) % MemoryLayout<proc_fdinfo>.stride == 0 else { return nil }
        return Array(descriptors.prefix(Int(bytes) / MemoryLayout<proc_fdinfo>.stride))
    }

    private static func hasExited(_ pid: pid_t) -> Bool {
        errno = 0
        return kill(pid, 0) != 0 && errno == ESRCH
    }
}
