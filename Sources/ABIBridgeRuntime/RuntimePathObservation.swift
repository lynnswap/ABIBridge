import Darwin
import Dispatch
import Foundation
import Synchronization

/// Invalidates a path acquisition when an observed file-system object changes.
/// Explicit cache clearing remains available when a path cannot be observed.
final class RuntimePathObservation: Sendable {
    private struct Node: Sendable {
        let path: String
        let identity: Identity
    }

    private struct Identity: Hashable, Sendable {
        let device: dev_t
        let inode: ino_t

        init(_ status: stat) {
            device = status.st_dev
            inode = status.st_ino
        }
    }

    private struct Capture {
        let watch: Watch
        let revision: UInt64
    }

    private struct WeakObservation {
        weak var value: RuntimePathObservation?
    }

    private final class Events: Sendable {
        private struct State {
            var revision: UInt64 = 0
            var observers: [WeakObservation] = []
        }
        let identity: Identity
        let isDirectory: Bool
        private let state = Mutex(State())

        init(identity: Identity, isDirectory: Bool) {
            self.identity = identity
            self.isDirectory = isDirectory
        }

        var revision: UInt64 { state.withLock { $0.revision } }

        func add(_ observer: RuntimePathObservation, since revision: UInt64) {
            let changed = state.withLock { state in
                state.observers.removeAll { $0.value == nil }
                state.observers.append(WeakObservation(value: observer))
                return state.revision != revision
            }
            if changed { observer.changed(self) }
        }

        func notify() {
            let observers = state.withLock { state in
                state.revision &+= 1
                return state.observers.compactMap(\.value)
            }
            for observer in observers { observer.changed(self) }
        }
    }

    private final class Watch: Sendable {
        private static let queue = DispatchQueue(
            label: "ABIBridge.path-observation",
            qos: .userInitiated
        )
        let events: Events
        private let source: any DispatchSourceFileSystemObject

        init(descriptor: Int32, identity: Identity, isDirectory: Bool) {
            let events = Events(identity: identity, isDirectory: isDirectory)
            self.events = events
            source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.delete, .write, .extend, .attrib, .link, .rename, .revoke],
                queue: Self.queue
            )
            let registered = DispatchSemaphore(value: 0)
            source.setRegistrationHandler { registered.signal() }
            source.setEventHandler { events.notify() }
            source.setCancelHandler { close(descriptor) }
            source.activate()
            // Creation happens on lookup threads, never on the private event
            // queue. Register before taking the path's final identity snapshot.
            registered.wait()
        }

        deinit { source.cancel() }
    }

    final class Pool: Sendable {
        private struct WeakWatch {
            weak var value: Watch?
        }
        private let watches = Mutex<[Identity: WeakWatch]>([:])

        private func capture(path: String, status: stat) -> Capture? {
            let identity = Identity(status)
            if let existing = watches.withLock({ $0[identity]?.value }) {
                return Capture(watch: existing, revision: existing.events.revision)
            }
            let descriptor = path.withCString { open($0, O_EVTONLY | O_SYMLINK | O_CLOEXEC) }
            guard descriptor >= 0 else { return nil }
            var actual = stat()
            guard fstat(descriptor, &actual) == 0, Identity(actual) == identity else {
                close(descriptor)
                return nil
            }
            let watch = Watch(
                descriptor: descriptor,
                identity: identity,
                isDirectory: status.st_mode & S_IFMT == S_IFDIR
            )
            let selected = watches.withLock { watches in
                if let existing = watches[identity]?.value { return existing }
                watches = watches.filter { $0.value.value != nil }
                watches[identity] = WeakWatch(value: watch)
                return watch
            }
            return withExtendedLifetime(watch) {
                Capture(
                    watch: selected,
                    revision: selected === watch ? 0 : selected.events.revision
                )
            }
        }

        func observe(_ path: String) -> RuntimePathObservation? {
            var pending = path.components(separatedBy: "/").filter { !$0.isEmpty }
            var directory: [String] = []
            var nodes: [Node] = []
            var captures: [Identity: Capture] = [:]
            var links = 0

            func record(_ path: String) -> stat? {
                var status = stat()
                guard path.withCString({ lstat($0, &status) }) == 0 else { return nil }
                let identity = Identity(status)
                nodes.append(Node(path: path, identity: identity))
                if captures[identity] == nil {
                    captures[identity] = capture(path: path, status: status)
                }
                return status
            }

            _ = record("/")
            while !pending.isEmpty {
                let component = pending.removeFirst()
                if component == "." { continue }
                if component == ".." {
                    if !directory.isEmpty { directory.removeLast() }
                    continue
                }
                let current = "/" + (directory + [component]).joined(separator: "/")
                guard let status = record(current) else { break }
                if status.st_mode & S_IFMT == S_IFLNK {
                    links += 1
                    guard links <= Int(MAXSYMLINKS),
                        let destination = try? FileManager.default.destinationOfSymbolicLink(
                            atPath: current
                        )
                    else { break }
                    if destination.hasPrefix("/") { directory = [] }
                    pending =
                        destination.components(separatedBy: "/").filter { !$0.isEmpty }
                        + pending
                } else {
                    directory.append(component)
                }
            }
            guard !captures.isEmpty else { return nil }
            return RuntimePathObservation(nodes: nodes, captures: Array(captures.values))
        }
    }

    private let nodes: [Node]
    private let watches: [Watch]
    private let invalidated = Mutex(false)

    private init(nodes: [Node], captures: [Capture]) {
        self.nodes = nodes
        watches = captures.map(\.watch)
        for capture in captures { capture.watch.events.add(self, since: capture.revision) }
    }

    var isCurrent: Bool { invalidated.withLock { !$0 } }

    private func changed(_ events: Events) {
        if !events.isDirectory {
            invalidated.withLock { $0 = true }
            return
        }
        // Directory writes may concern unrelated entries. Check the recorded
        // path components on notification, rather than on every cache hit.
        for node in nodes {
            var status = stat()
            if node.path.withCString({ lstat($0, &status) }) != 0
                || Identity(status) != node.identity
            {
                invalidated.withLock { $0 = true }
                return
            }
        }
    }
}
