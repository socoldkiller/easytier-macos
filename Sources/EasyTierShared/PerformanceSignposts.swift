import os

package enum EasyTierPerformanceSignposts {
    private static let subsystem = "com.kkrainbow.easytier.mac"
    private static let renderingLog = OSLog(subsystem: subsystem, category: "Rendering")
    private static let runtimeLog = OSLog(subsystem: subsystem, category: "Runtime")
    private static let workspaceLog = OSLog(subsystem: subsystem, category: "Workspace")

    package static func glassConfigurationChanged() {
        os_signpost(.event, log: renderingLog, name: "glass-configuration")
    }

    package static func beginRuntimeRefresh() -> OSSignpostID {
        let id = OSSignpostID(log: runtimeLog)
        os_signpost(.begin, log: runtimeLog, name: "runtime-refresh", signpostID: id)
        return id
    }

    package static func endRuntimeRefresh(_ id: OSSignpostID) {
        os_signpost(.end, log: runtimeLog, name: "runtime-refresh", signpostID: id)
    }

    package static func beginRuntimePublish() -> OSSignpostID {
        let id = OSSignpostID(log: runtimeLog)
        os_signpost(.begin, log: runtimeLog, name: "runtime-publish", signpostID: id)
        return id
    }

    package static func endRuntimePublish(_ id: OSSignpostID) {
        os_signpost(.end, log: runtimeLog, name: "runtime-publish", signpostID: id)
    }

    package static func workspaceTransition() {
        os_signpost(.event, log: workspaceLog, name: "workspace-transition")
    }
}
