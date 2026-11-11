import Darwin
import Foundation

/// Lists folders under the folder-listing rule: dataless materialization is on for the
/// calling thread for exactly one directory read, and back to what the thread had before
/// (off, on a scan thread) for everything else. A folder the provider has not listed on this
/// Mac yet then gets its list fetched, as Finder does when the folder is opened, while every
/// lstat, resource-value read and extended-attribute read runs with materialization off, so
/// Cloudpane never reads or downloads a file's contents. Once a provider knows about the
/// items, it may still download some by its own policy (in the real-provider run, OneDrive
/// downloaded a 168-byte OneNote notebook shortcut from its background scheduler), as it
/// would after the folder is opened in Finder.
///
/// While the policy is on, the listing asks for no resource values
/// (`includingPropertiesForKeys: []`) and passes no options (`.skipsHiddenFiles` would read
/// each child's hidden flag), so nothing about the children is read. Names starting with a
/// dot are dropped after the policy is restored; items with the hidden flag (UF_HIDDEN) are
/// dropped by the caller, which reads each item's flags with lstat anyway.
///
/// The closures are the test seam: tests replace the listing, the dataless check and the
/// policy switch to stand in for a provider without one.
struct FolderLister: Sendable {
    enum Failure: Error, CustomStringConvertible {
        /// The listing call failed. The policy was restored.
        case listing(Error)
        /// Materialization could not be turned back off after a listing. The caller must stop
        /// reading at once: any further read on this thread could download.
        case couldNotRestore(POSIXErrorCode)

        var description: String {
            switch self {
            case .listing(let error): return describe(error: error)
            case .couldNotRestore(let code): return "could not turn materialization back off: \(code)"
            }
        }
    }

    /// Reads a folder's children, hidden ones included, reading nothing about them.
    var list: @Sendable (_ folder: URL) throws -> [URL]
    /// Whether the folder at a path is dataless (SF_DATALESS) right now.
    var isDataless: @Sendable (_ path: String) -> Bool
    /// Sets the calling thread's materialization policy. Returns false on failure.
    var setPolicy: @Sendable (_ policy: Int32) -> Bool
    /// Reads the calling thread's materialization policy.
    var readPolicy: @Sendable () -> Int32

    static let live = FolderLister(
        list: { folder in
            try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [], options: [])
        },
        isDataless: { lstatInfo($0)?.isDataless == true },
        setPolicy: { policy in
            setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, policy) == 0
        },
        readPolicy: { MaterializationPolicy.currentThreadPolicy })

    /// Lists without ever changing the thread's policy, for code that runs on a shared
    /// Swift concurrency thread, where a policy left on by a failure could reach unrelated
    /// work. A dataless folder then fails to list, as before the folder-listing rule.
    static let withoutMaterialization = FolderLister(
        list: live.list, isDataless: live.isDataless, setPolicy: { _ in false }, readPolicy: live.readPolicy)

    /// Lists one folder with materialization on for this call only, then restores the
    /// thread's previous policy and checks that it took. If the policy cannot be turned on,
    /// the folder is listed with the policy unchanged, which fails for a folder the provider
    /// has not listed (errno 11) and works for every other folder, as before this rule.
    func contents(of folder: URL, includeHidden: Bool) throws -> [URL] {
        let previous = readPolicy()
        // getiopolicy_np failing is not expected; restore to off rather than to an unknown.
        let restoreTo = previous < 0 ? IOPOL_MATERIALIZE_DATALESS_FILES_OFF : previous
        let enabled = setPolicy(IOPOL_MATERIALIZE_DATALESS_FILES_ON)
        let result = Result { try list(folder) }
        if enabled {
            guard setPolicy(restoreTo), readPolicy() == restoreTo else {
                throw Failure.couldNotRestore(POSIXErrorCode())
            }
        }
        switch result {
        case .success(let children):
            // With the policy restored. Only the name is looked at here.
            return includeHidden ? children : children.filter { !$0.lastPathComponent.hasPrefix(".") }
        case .failure(let error): throw Failure.listing(error)
        }
    }
}
