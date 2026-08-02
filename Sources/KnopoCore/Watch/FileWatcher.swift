import Foundation
import CoreServices

/// FSEvents-based watcher for external edits to the graph directory
/// (SPEC §4.2, §15). Events are debounced; the callback fires on the main queue.
public final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let debounce: TimeInterval
    /// Nil means FSEvents dropped/coalesced information and the receiver must
    /// perform a full scan. Otherwise these are the changed file paths.
    private let onChange: (Set<String>?) -> Void
    private var pending: DispatchWorkItem?
    private var pendingPaths: Set<String> = []
    private var pendingFullScan = false

    public init(
        paths: [String], debounce: TimeInterval = 0.3,
        onChange: @escaping (Set<String>?) -> Void
    ) {
        self.paths = paths
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = {
            _, info, eventCount, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            var paths: Set<String> = []
            let rawPaths = eventPaths.assumingMemoryBound(
                to: UnsafePointer<CChar>?.self)
            for index in 0..<eventCount {
                if let path = rawPaths[index] {
                    let value = String(cString: path)
                    paths.insert(value)
                }
            }
            let incompleteMask = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped
                    | kFSEventStreamEventFlagRootChanged)
            var fullScan = paths.isEmpty
            for index in 0..<eventCount where eventFlags[index] & incompleteMask != 0 {
                fullScan = true
            }
            watcher.scheduleFire(paths: paths, fullScan: fullScan)
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            )
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        pending?.cancel()
        pending = nil
    }

    private func scheduleFire(paths: Set<String>, fullScan: Bool) {
        pendingPaths.formUnion(paths)
        pendingFullScan = pendingFullScan || fullScan
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let changes = self.pendingFullScan ? nil : self.pendingPaths
            self.pendingPaths = []
            self.pendingFullScan = false
            self.onChange(changes)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
