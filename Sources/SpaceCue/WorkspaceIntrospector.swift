import AppKit
import CoreGraphics
import Foundation

struct WorkspaceAppContext {
    let phrase: String
    let bundleIdentifier: String?
}

enum WorkspaceIntrospector {
    static func currentPhrase(excludingBundleID: String?) -> String? {
        currentAppContext(excludingBundleID: excludingBundleID)?.phrase
    }

    static func currentAppContext(excludingBundleID: String?) -> WorkspaceAppContext? {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != excludingBundleID,
           let name = friendlyName(owner: app.localizedName, title: nil, bundleID: app.bundleIdentifier),
           !isIgnored(name) {
            return WorkspaceAppContext(phrase: name, bundleIdentifier: app.bundleIdentifier)
        }

        return primaryVisibleWindowCandidate(excludingBundleID: excludingBundleID)
    }

    static func visibleDesktopContext(excludingBundleID: String?) -> WorkspaceAppContext? {
        let contexts = visibleAppContexts(excludingBundleID: excludingBundleID)
        guard !contexts.isEmpty else {
            return nil
        }

        let names = contexts.map(\.phrase)
        let visibleNames = names.prefix(3)
        let suffix = names.count > 3 ? " + \(names.count - 3)" : ""
        return WorkspaceAppContext(
            phrase: visibleNames.joined(separator: " + ") + suffix,
            bundleIdentifier: contexts.first?.bundleIdentifier
        )
    }

    static func visibleAppContexts(excludingBundleID: String?) -> [WorkspaceAppContext] {
        visibleWindowCandidates(excludingBundleID: excludingBundleID)
    }

    private static func primaryVisibleWindowCandidate(excludingBundleID: String?) -> WorkspaceAppContext? {
        visibleWindowCandidates(excludingBundleID: excludingBundleID).first
    }

    private static func visibleWindowCandidates(excludingBundleID: String?) -> [WorkspaceAppContext] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var result: [WorkspaceAppContext] = []
        var seenNames = Set<String>()
        for window in windows {
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else {
                continue
            }

            let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.2 else {
                continue
            }

            let owner = window[kCGWindowOwnerName as String] as? String
            let title = window[kCGWindowName as String] as? String
            let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let app = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
            let bundleID = app?.bundleIdentifier

            guard bundleID != excludingBundleID else {
                continue
            }

            let bounds = rect(from: window[kCGWindowBounds as String])
            guard bounds.width * bounds.height > 30_000 else {
                continue
            }

            guard let name = friendlyName(owner: owner ?? app?.localizedName, title: title, bundleID: bundleID),
                  !isIgnored(name) else {
                continue
            }

            let key = name.lowercased()
            guard !seenNames.contains(key) else {
                continue
            }

            seenNames.insert(key)
            result.append(WorkspaceAppContext(phrase: name, bundleIdentifier: bundleID))
        }

        return result
    }

    private static func friendlyName(owner: String?, title: String?, bundleID: String?) -> String? {
        let pieces = [owner, title, bundleID].compactMap { $0 }
        let haystack = pieces.joined(separator: " ").lowercased()

        if haystack.contains("claude") {
            return haystack.contains("code") ? "Claude Code" : "Claude"
        }
        if haystack.contains("codex") {
            return "Codex"
        }
        if haystack.contains("thebrowsercompany.dia") || haystack.contains(" dia") || haystack == "dia" {
            return "Dia"
        }
        if haystack.contains("cursor") {
            return "Cursor"
        }
        if haystack.contains("visual studio code") {
            return "VS Code"
        }
        if haystack.contains("xcode") {
            return "Xcode"
        }
        if haystack.contains("terminal") {
            return "Terminal"
        }
        if haystack.contains("ghostty") {
            return "Ghostty"
        }
        if haystack.contains("arc") {
            return "Arc"
        }
        if haystack.contains("chrome") {
            return "Chrome"
        }
        if haystack.contains("safari") {
            return "Safari"
        }

        let fallback = (owner ?? title)?
            .replacingOccurrences(of: ".app", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let fallback, !fallback.isEmpty else {
            return nil
        }

        if fallback.count > 18 {
            return String(fallback.prefix(18)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return fallback
    }

    private static func isIgnored(_ name: String) -> Bool {
        let ignored = [
            "Dock",
            "WindowServer",
            "SystemUIServer",
            "Control Center",
            "Notification Center",
            "Spotlight",
            "SpaceCue"
        ]
        return ignored.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func rect(from value: Any?) -> CGRect {
        guard let nsDictionary = value as? NSDictionary else {
            return .zero
        }

        let dictionary = nsDictionary as CFDictionary
        guard let rect = CGRect(dictionaryRepresentation: dictionary) else {
            return .zero
        }
        return rect
    }
}
