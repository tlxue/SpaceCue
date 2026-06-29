import Foundation

struct SpaceInfo: Equatable {
    var ordinal: Int
    let key: String
    let displayID: String
    let displayOrdinal: Int
    let uuid: String
    let id64: UInt64
    let managedID: UInt64?
    let type: Int
    let isCurrent: Bool
    var appBundleIdentifier: String?
    var appName: String?
    var label: String

    var defaultLabel: String {
        switch type {
        case 4:
            return "Full screen \(ordinal)"
        default:
            return "Desktop \(ordinal)"
        }
    }
}
