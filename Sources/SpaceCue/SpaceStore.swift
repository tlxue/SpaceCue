import Foundation

final class SpaceStore {
    private let customKey = "labels.custom.v1"
    private let learnedKey = "labels.learned.v2"
    private let appBundleKey = "icons.bundle.v1"

    func label(for spaceKey: String) -> String? {
        customLabels()[spaceKey] ?? learnedLabels()[spaceKey]
    }

    func customLabel(for spaceKey: String) -> String? {
        customLabels()[spaceKey]
    }

    func hasLabel(for spaceKey: String) -> Bool {
        label(for: spaceKey) != nil
    }

    func appBundleIdentifier(for spaceKey: String) -> String? {
        appBundleIdentifiers()[spaceKey]
    }

    func learn(_ label: String, for spaceKey: String) {
        let cleaned = clean(label)
        guard !cleaned.isEmpty,
              customLabels()[spaceKey] == nil,
              learnedLabels()[spaceKey] == nil else {
            return
        }

        var labels = learnedLabels()
        labels[spaceKey] = cleaned
        save(labels, key: learnedKey)
    }

    func learnAppBundleIdentifier(_ bundleIdentifier: String, for spaceKey: String) {
        let cleaned = clean(bundleIdentifier)
        guard !cleaned.isEmpty else {
            return
        }

        var bundleIdentifiers = appBundleIdentifiers()
        guard bundleIdentifiers[spaceKey] != cleaned else {
            return
        }

        bundleIdentifiers[spaceKey] = cleaned
        save(bundleIdentifiers, key: appBundleKey)
    }

    func setCustomLabel(_ label: String, for spaceKey: String) {
        let cleaned = clean(label)
        var labels = customLabels()
        if cleaned.isEmpty {
            labels.removeValue(forKey: spaceKey)
        } else {
            labels[spaceKey] = cleaned
        }
        save(labels, key: customKey)
    }

    func clearLabels(for spaceKey: String) {
        var custom = customLabels()
        var learned = learnedLabels()
        custom.removeValue(forKey: spaceKey)
        learned.removeValue(forKey: spaceKey)
        save(custom, key: customKey)
        save(learned, key: learnedKey)

        var bundleIdentifiers = appBundleIdentifiers()
        bundleIdentifiers.removeValue(forKey: spaceKey)
        save(bundleIdentifiers, key: appBundleKey)
    }

    func clearLearnedLabels() {
        save([:], key: learnedKey)
        save([:], key: appBundleKey)
    }

    private func customLabels() -> [String: String] {
        load(customKey)
    }

    private func learnedLabels() -> [String: String] {
        load(learnedKey)
    }

    private func appBundleIdentifiers() -> [String: String] {
        load(appBundleKey)
    }

    private func load(_ key: String) -> [String: String] {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) else {
            return [:]
        }

        var result: [String: String] = [:]
        for (key, value) in raw {
            guard let string = value as? String else {
                continue
            }
            result[key] = string
        }
        return result
    }

    private func save(_ labels: [String: String], key: String) {
        UserDefaults.standard.set(labels, forKey: key)
    }

    private func clean(_ label: String) -> String {
        label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
