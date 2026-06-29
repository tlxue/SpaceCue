import AppKit

enum AppIconResolver {
    static func icon(bundleIdentifier: String?, appName: String?, label: String) -> NSImage? {
        if let bundleIdentifier,
           let icon = icon(forBundleIdentifier: bundleIdentifier) {
            return icon
        }

        if let bundleIdentifier = Self.bundleIdentifier(forAppName: appName ?? label),
           let icon = icon(forBundleIdentifier: bundleIdentifier) {
            return icon
        }

        if let app = runningApplication(named: appName ?? label),
           let url = app.bundleURL {
            return icon(forApplicationURL: url)
        }

        return nil
    }

    static func bundleIdentifier(forAppName name: String?) -> String? {
        runningApplication(named: name)?.bundleIdentifier
    }

    private static func icon(forBundleIdentifier bundleIdentifier: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return icon(forApplicationURL: url)
    }

    private static func icon(forApplicationURL url: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 22, height: 22)
        image.isTemplate = false
        return image
    }

    private static func runningApplication(named name: String?) -> NSRunningApplication? {
        guard let name else {
            return nil
        }

        let target = normalized(name)
        guard !target.isEmpty,
              !target.hasPrefix("desktop"),
              !target.hasPrefix("full screen") else {
            return nil
        }

        return NSWorkspace.shared.runningApplications.first { app in
            guard let appName = app.localizedName else {
                return false
            }

            let normalizedName = normalized(appName)
            let normalizedBundle = normalized(app.bundleIdentifier ?? "")
            return normalizedName == target
                || normalizedName.contains(target)
                || target.contains(normalizedName)
                || normalizedBundle.contains(target)
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(of: ".app", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
