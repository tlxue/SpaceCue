import CoreGraphics
import Darwin
import Foundation

final class PrivateSpacesAPI {
    private typealias ConnectionFn = @convention(c) () -> UInt32
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (UInt32) -> Unmanaged<CFArray>?
    private typealias SetCurrentSpaceFn = @convention(c) (UInt32, CFString, UInt64) -> Int32

    private let handle: UnsafeMutableRawPointer?
    private let defaultConnection: ConnectionFn?
    private let mainConnection: ConnectionFn?
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn?
    private let setCurrentSpace: SetCurrentSpaceFn?

    init() {
        handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) ?? dlopen(nil, RTLD_LAZY)
        defaultConnection = PrivateSpacesAPI.resolve("_CGSDefaultConnection", in: handle, as: ConnectionFn.self)
        mainConnection = PrivateSpacesAPI.resolve("CGSMainConnectionID", in: handle, as: ConnectionFn.self)
        copyManagedDisplaySpaces = PrivateSpacesAPI.resolve("CGSCopyManagedDisplaySpaces", in: handle, as: CopyManagedDisplaySpacesFn.self)
        setCurrentSpace = PrivateSpacesAPI.resolve("CGSManagedDisplaySetCurrentSpace", in: handle, as: SetCurrentSpaceFn.self)
    }

    var canListSpaces: Bool {
        copyManagedDisplaySpaces != nil
    }

    var canSwitchSpaces: Bool {
        setCurrentSpace != nil
    }

    func managedDisplaySpaces() -> [[String: Any]] {
        guard let copyManagedDisplaySpaces else {
            return []
        }

        guard let spaces = copyManagedDisplaySpaces(connectionID())?.takeRetainedValue() else {
            return []
        }

        return PrivateSpacesAPI.arrayOfDictionaries(spaces)
    }

    func switchTo(displayID: String, spaceID: UInt64) -> Bool {
        guard let setCurrentSpace else {
            return false
        }

        let result = setCurrentSpace(connectionID(), displayID as CFString, spaceID)
        return result == 0
    }

    private func connectionID() -> UInt32 {
        let defaultID = defaultConnection?() ?? 0
        if defaultID != 0 {
            return defaultID
        }
        return mainConnection?() ?? 0
    }

    private static func resolve<T>(_ name: String, in handle: UnsafeMutableRawPointer?, as type: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else {
            return nil
        }
        return unsafeBitCast(symbol, to: T.self)
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }

        guard let nsDictionary = value as? NSDictionary else {
            return nil
        }

        var result: [String: Any] = [:]
        for (key, value) in nsDictionary {
            guard let stringKey = key as? String else {
                continue
            }
            result[stringKey] = value
        }
        return result
    }

    static func arrayOfDictionaries(_ value: Any?) -> [[String: Any]] {
        if let array = value as? [[String: Any]] {
            return array
        }

        let rawArray: [Any]
        if let array = value as? [Any] {
            rawArray = array
        } else if let array = value as? NSArray {
            rawArray = array.compactMap { $0 }
        } else {
            return []
        }

        return rawArray.compactMap { dictionary($0) }
    }

    static func uint64(_ value: Any?) -> UInt64? {
        switch value {
        case let number as NSNumber:
            return number.uint64Value
        case let value as UInt64:
            return value
        case let value as UInt:
            return UInt64(value)
        case let value as Int:
            return value >= 0 ? UInt64(value) : nil
        case let value as String:
            return UInt64(value)
        default:
            return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let value as Int:
            return value
        case let value as UInt64:
            return Int(value)
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }
}
