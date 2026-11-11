import Darwin
import Foundation

/// An errno with its system message, as in "errno 13 Permission denied".
public struct POSIXErrorCode: Error, CustomStringConvertible, Sendable, Hashable {
    public let code: Int32

    public init(_ code: Int32 = errno) { self.code = code }

    public var description: String { "errno \(code) \(String(cString: strerror(code)))" }
}

/// lstat(2). Never follows a symbolic link.
func lstatInfo(_ path: String) -> stat? {
    var info = stat()
    return lstat(path, &info) == 0 ? info : nil
}

func fileType(_ info: stat) -> mode_t { info.st_mode & S_IFMT }

extension stat {
    /// SF_DATALESS: the kernel's own record that the item has no local data.
    var isDataless: Bool { st_flags & UInt32(SF_DATALESS) != 0 }
    /// UF_COMPRESSED: data lives in a decmpfs attribute, so allocated size can be 0.
    var isCompressed: Bool { st_flags & UInt32(UF_COMPRESSED) != 0 }
}

/// realpath(3), so /tmp and /private/tmp resolve to the paths the enumerator returns.
/// Falls back to the standardized path when the item does not exist.
func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else {
        return (path as NSString).standardizingPath
    }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Domain and code, the underlying errno when there is one, and a hint for the failures a
/// scan most needs to recognize.
func describe(error: Error) -> String {
    let ns = error as NSError
    var text = "\(ns.domain) \(ns.code)"
    var posix: Int32?
    if ns.domain == NSPOSIXErrorDomain {
        posix = Int32(ns.code)
    } else if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
        if underlying.domain == NSPOSIXErrorDomain {
            posix = Int32(underlying.code)
        } else {
            text += ", underlying \(underlying.domain) \(underlying.code)"
        }
    }
    if let posix { text += ", \(POSIXErrorCode(posix))" }
    if let posix { text += errnoHint(posix) }
    if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadInvalidFileNameError && posix != ENAMETOOLONG {
        text += pathMaxHint
    }
    return text
}

/// The errno behind an error, directly or as its underlying error.
func posixCode(of error: Error) -> Int32? {
    if let posix = error as? POSIXError { return posix.code.rawValue }
    let ns = error as NSError
    if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
        return Int32(underlying.code)
    }
    return nil
}

/// An errno from a direct system call, with the same hints as describe(error:).
func describeErrno(_ code: POSIXErrorCode) -> String {
    code.description + errnoHint(code.code)
}

private let pathMaxHint = " (path may exceed PATH_MAX, \(PATH_MAX) bytes; nothing below this item was walked)"

private func errnoHint(_ code: Int32) -> String {
    switch code {
    // Measured in the M0 spike: listing a folder the provider has not listed on this Mac,
    // with materialization off, fails with errno 11.
    case EDEADLK: return " (blocked materialization of a dataless item)"
    case ENAMETOOLONG: return pathMaxHint
    default: return ""
    }
}

/// Turns off dataless-file materialization, so a read that would make a provider fetch
/// content fails instead of downloading. Cloudpane never reads file contents during a scan;
/// this is the second line of defense.
public enum MaterializationPolicy {
    /// For the calling thread only. The scanner calls this on its own walk thread.
    @discardableResult
    public static func disableForCurrentThread() -> Result<Void, POSIXErrorCode> {
        apply(scope: IOPOL_SCOPE_THREAD)
    }

    /// For the whole process. Suitable for a command-line tool; an app that later offers
    /// opt-in hashing of dataless files would need to re-enable it on the hashing thread.
    @discardableResult
    public static func disableForProcess() -> Result<Void, POSIXErrorCode> {
        apply(scope: IOPOL_SCOPE_PROCESS)
    }

    /// Turns materialization on for the calling thread only. Used solely by the hashing
    /// worker, for folders the user opted in to hashing.
    @discardableResult
    public static func enableForCurrentThread() -> Result<Void, POSIXErrorCode> {
        let result = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                                    IOPOL_MATERIALIZE_DATALESS_FILES_ON)
        return result == 0 ? .success(()) : .failure(POSIXErrorCode())
    }

    /// The calling thread's materialization policy as getiopolicy_np reports it.
    public static var currentThreadPolicy: Int32 {
        getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
    }

    /// True when materialization is on for the calling thread.
    public static var isEnabledForCurrentThread: Bool {
        currentThreadPolicy == IOPOL_MATERIALIZE_DATALESS_FILES_ON
    }

    /// True when materialization is off for the calling thread.
    public static var isDisabledForCurrentThread: Bool {
        getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            == IOPOL_MATERIALIZE_DATALESS_FILES_OFF
    }

    private static func apply(scope: Int32) -> Result<Void, POSIXErrorCode> {
        let result = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, scope,
                                    IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        return result == 0 ? .success(()) : .failure(POSIXErrorCode())
    }
}
