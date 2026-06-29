import AppKit
import Foundation

final class SpaceProvider {
    private let api: PrivateSpacesAPI

    init(api: PrivateSpacesAPI) {
        self.api = api
    }

    var apiStatus: String {
        if api.canListSpaces && api.canSwitchSpaces {
            return "Spaces API ready"
        }
        if api.canListSpaces {
            return "Spaces API can list only"
        }
        return "Spaces API unavailable"
    }

    func loadSpaces() -> [SpaceInfo] {
        let displayDictionaries = api.managedDisplaySpaces()
        var spaces: [SpaceInfo] = []

        for (displayOrdinal, display) in displayDictionaries.enumerated() {
            let displayID = display["Display Identifier"] as? String
                ?? display["DisplayIdentifier"] as? String
                ?? "display-\(displayOrdinal + 1)"

            let current = PrivateSpacesAPI.dictionary(display["Current Space"])
            let currentID = PrivateSpacesAPI.uint64(current?["id64"])
                ?? PrivateSpacesAPI.uint64(current?["ManagedSpaceID"])
            let currentUUID = Self.nonEmptyString(current?["uuid"])

            for rawSpace in PrivateSpacesAPI.arrayOfDictionaries(display["Spaces"]) {
                guard let id64 = PrivateSpacesAPI.uint64(rawSpace["id64"])
                    ?? PrivateSpacesAPI.uint64(rawSpace["ManagedSpaceID"]) else {
                    continue
                }

                let managedID = PrivateSpacesAPI.uint64(rawSpace["ManagedSpaceID"])
                let rawUUID = Self.nonEmptyString(rawSpace["uuid"])
                let uuid = rawUUID ?? "space-\(managedID ?? id64)"
                let type = PrivateSpacesAPI.int(rawSpace["type"]) ?? 0
                let isCurrent = (currentUUID != nil && currentUUID == rawUUID)
                    || currentID == id64
                    || (managedID != nil && currentID == managedID)
                let key = "\(displayID)|\(uuid)"
                let app = Self.appMetadata(from: rawSpace)

                spaces.append(
                    SpaceInfo(
                        ordinal: spaces.count + 1,
                        key: key,
                        displayID: displayID,
                        displayOrdinal: displayOrdinal + 1,
                        uuid: uuid,
                        id64: id64,
                        managedID: managedID,
                        type: type,
                        isCurrent: isCurrent,
                        appBundleIdentifier: app.bundleIdentifier,
                        appName: app.name,
                        label: ""
                    )
                )
            }
        }

        if spaces.isEmpty {
            return [
                SpaceInfo(
                    ordinal: 1,
                    key: "fallback|current",
                    displayID: "fallback",
                    displayOrdinal: 1,
                    uuid: "current",
                    id64: 1,
                    managedID: nil,
                    type: 0,
                    isCurrent: true,
                    appBundleIdentifier: nil,
                    appName: nil,
                    label: "Desktop 1"
                )
            ]
        }

        return spaces.enumerated().map { offset, space in
            var copy = space
            copy.ordinal = offset + 1
            return copy
        }
    }

    func switchTo(_ space: SpaceInfo) -> Bool {
        api.switchTo(displayID: space.displayID, spaceID: space.id64)
    }

    private static func appMetadata(from rawSpace: [String: Any]) -> (bundleIdentifier: String?, name: String?) {
        let tile = primaryTile(in: rawSpace)
        let pid = PrivateSpacesAPI.int(rawSpace["pid"]) ?? PrivateSpacesAPI.int(tile?["pid"])
        let runningApp = pid.flatMap { NSRunningApplication(processIdentifier: pid_t($0)) }
        let name = runningApp?.localizedName
            ?? rawSpace["appName"] as? String
            ?? tile?["appName"] as? String
            ?? tile?["name"] as? String

        return (runningApp?.bundleIdentifier, name)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func primaryTile(in rawSpace: [String: Any]) -> [String: Any]? {
        guard let layout = PrivateSpacesAPI.dictionary(rawSpace["TileLayoutManager"]) else {
            return nil
        }

        let tiles = PrivateSpacesAPI.arrayOfDictionaries(layout["TileSpaces"])
        return tiles.first { ($0["TileType"] as? String) == "Primary" } ?? tiles.first
    }
}
