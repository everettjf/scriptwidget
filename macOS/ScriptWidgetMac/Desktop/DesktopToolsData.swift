import AppKit
import Darwin
import UniformTypeIdentifiers

struct DesktopLaunchItem: Codable, Identifiable {
    let id: UUID
    let name: String
    let bookmark: Data

    init(url: URL) throws {
        id = UUID()
        name = FileManager.default.displayName(atPath: url.path)
        bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolve() throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale, url.isFileURL else { throw CocoaError(.fileReadNoSuchFile) }
        return url
    }
}

struct DesktopCPUReading {
    let busy: UInt64
    let idle: UInt64

    func fraction(since earlier: Self) -> Double? {
        guard busy >= earlier.busy, idle >= earlier.idle else { return nil }
        let busyDelta = Double(busy - earlier.busy)
        let total = busyDelta + Double(idle - earlier.idle)
        return total > 0 ? busyDelta / total : nil
    }
}

struct DesktopProcessReading: Identifiable {
    let id: pid_t
    let name: String
    let startedAt: UInt64
    let cpuTicks: UInt64
    let residentBytes: UInt64

    func cpuPercent(since earlier: Self?, elapsedTicks: UInt64) -> Double? {
        guard let earlier, id == earlier.id, startedAt == earlier.startedAt,
              elapsedTicks > 0, cpuTicks >= earlier.cpuTicks else { return nil }
        return Double(cpuTicks - earlier.cpuTicks) / Double(elapsedTicks) * 100
    }
}

enum DesktopSystemSampler {
    static func cpu() -> DesktopCPUReading? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let (user, system, idle, nice) = load.cpu_ticks
        return DesktopCPUReading(busy: UInt64(user) + UInt64(system) + UInt64(nice), idle: UInt64(idle))
    }

    static func memory() -> (used: UInt64, total: UInt64)? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let residentPages = UInt64(info.internal_page_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        let usedPages = residentPages - min(residentPages, UInt64(info.purgeable_count))
        let total = ProcessInfo.processInfo.physicalMemory
        return (min(total, usedPages * UInt64(vm_kernel_page_size)), total)
    }

    static func process(id: pid_t, name: String) -> DesktopProcessReading? {
        var info = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        guard proc_pidinfo(id, PROC_PIDTASKALLINFO, 0, &info, size) == size else { return nil }
        let start = info.pbsd.pbi_start_tvsec * 1_000_000 + info.pbsd.pbi_start_tvusec
        // libproc task times and mach_absolute_time use the same Mach tick units.
        return DesktopProcessReading(id: id, name: name, startedAt: start,
                                     cpuTicks: info.ptinfo.pti_total_user + info.ptinfo.pti_total_system,
                                     residentBytes: info.ptinfo.pti_resident_size)
    }
}

enum DesktopMediaCommand: String, CaseIterable, Identifiable {
    case previous = "Previous"
    case playPause = "Play / Pause"
    case next = "Next"

    var id: Self { self }

    static func shortcutURL(name: String) -> URL? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 200,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}
