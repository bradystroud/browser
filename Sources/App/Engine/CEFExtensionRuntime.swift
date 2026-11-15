import AppKit

/// Chromium's own extension system in CEF tabs, running the install list
/// WebKit's manager owns (see CombinedExtensionManager).
///
/// Chromium loads extensions only from the `load-extension` switch, which it
/// reads once at launch, and every profile context reads the switch's
/// folders when it is created. So:
///
/// - Before the engine starts, each profile's list is turned into prepared
///   copies (`CEFExtensionPreparer`: the store key, the shim) in
///   `<profile>/WebExtensions/cef/<id>/<versioned folder>` (`copiesPath`),
///   and the switch names one link per extension id,
///   `<root>/.cef-extension-links/<id>`, all absent. Chromium's own root
///   profile, created inside CefInitialize, finds none.
/// - Contexts are created one at a time (`whenProfileReady`): the links are
///   pointed at that profile's copies, the context is created, and nothing
///   changes the links or creates another context until it reports itself
///   initialized. That is how each profile gets exactly its own list. A
///   context that never reports retires the links for the session: a later
///   one could still read them as its own.
/// - Chromium keeps serving a loaded copy from its real path, so a copy is
///   never changed while a session may use it: anything new goes into a new
///   folder at the next launch, and old folders go then, before the engine
///   starts. Only the process holding the profiles root's lock does any of
///   this, so a second launch on the same root changes nothing.
/// - Install, removal, enabling and updating therefore reach CEF tabs only
///   after a relaunch; `status` says when one is due.
final class CEFExtensionRuntime: NSObject, FollowerExtensionRuntime, BRWExtensionRuntimeDelegate {
    static let shared = CEFExtensionRuntime()

    let engine: EngineChoice = .cef

    /// A copy a profile runs in this session.
    struct Copy {
        let build: CEFExtensionBuild
        let folder: URL
        /// The prepared manifest, for its pages and name.
        let manifest: [String: Any]
        /// What the copy's shim sends with every request.
        let token: String?
    }

    /// The install list exists only where WebKit's extension system does.
    var isSupported: Bool {
        if #available(macOS 15.4, *) { return true }
        return false
    }

    /// Whether CEF tabs run extensions in this session: supported, turned on
    /// at launch (`setTurnedOn`), and set up without a problem.
    var isAvailable: Bool { isSupported && isTurnedOn && sessionUnavailableReason == nil }

    private var isTurnedOn = true
    private var turnedOnIsFixed = false
    private var nextLaunchSetting: (() -> Bool)?
    /// Why this session runs no extension in CEF tabs although it should.
    private var sessionUnavailableReason: String?

    /// Before the engine starts, once. Later calls are ignored.
    func setTurnedOn(_ on: Bool) {
        guard !turnedOnIsFixed else { return }
        turnedOnIsFixed = true
        isTurnedOn = on
    }

    func setNextLaunchSetting(_ isOn: @escaping () -> Bool) {
        nextLaunchSetting = isOn
    }

    /// Where this runtime's own files live in a profile folder. Never under
    /// `Extensions/`: that is Chromium's install directory, and its garbage
    /// collector deletes what it does not know there.
    static let copiesPath = "WebExtensions/cef"

    private var profilesRoot: URL?
    private var storageDirectory: ((String) -> URL?)?
    private var linksDirectory: URL?
    /// Held for the life of the process: the one process that may change the
    /// files under this profiles root.
    private var lockDescriptor: Int32 = -1
    /// What each profile's context loads when it is created in this session.
    private var launchPlan: [String: [String: Copy]] = [:]
    /// What each profile's context loaded, once it has initialized.
    private var loaded: [String: [String: Copy]] = [:]
    /// Extension ids that have a link on the switch.
    private var linkedIds: Set<String> = []
    /// Set when a context never reported itself initialized: no link is
    /// pointed again this session, and profiles created afterwards load
    /// nothing (`retiredProfiles`).
    private var linksRetired = false
    private var retiredProfiles: Set<String> = []
    private static let retiredReason = "Chromium did not start a profile in time, so no extension runs in Chromium tabs of profiles opened after it. They run after a relaunch."
    /// Copies that could not be made at launch: profile, id, fingerprint
    /// and why.
    private var prepareFailures: [String: [String: (fingerprint: String, message: String)]] = [:]
    private var reloadRequested: [String: Set<String>] = [:]

    /// This app launch, for `onStartup` (CEFExtensionLifecycle).
    private let session = UUID().uuidString
    /// Each profile's state file as written at launch, kept current as the
    /// shim confirms lifecycle events and the user approves grants.
    private var profileStates: [String: CEFExtensionProfileState] = [:]
    /// The store version each extension runs at in this session.
    private var storeVersions: [String: [String: String]] = [:]
    /// Extensions with a worker whose copy changed at this launch: Chromium
    /// drops the events queued before the new worker activates, so the
    /// profile's first pages wait for `worker.activated`.
    private var changedWorkers: [String: Set<String>] = [:]
    private var activatedWorkers: [String: Set<String>] = [:]
    private var holding: Set<String> = []
    private static let activationHold: TimeInterval = 5

    /// The decisions for the list as it is now. Recomputed off the main
    /// thread after the list changes; an unpacked folder's tree stamp only
    /// on an explicit refresh (`refreshRuntimeStatus`, a reload).
    private var decisions: [String: [String: CEFExtensionDecision]] = [:]
    private var treeStamps: [String: [String: String]] = [:]
    private var listBytes: [String: Data] = [:]
    private var refreshScheduled: Set<String> = []
    /// A refresh asked for while one runs: run again (restamping when any
    /// caller asked to) once it ends.
    private var refreshAgain: [String: Bool] = [:]
    /// Each profile's approvals (`approvals.json`), and the profiles whose
    /// file could not be read, which are never written.
    private var approvals: [String: [String: [String]]] = [:]
    private var approvalsUnreadable: Set<String> = []
    private let work = DispatchQueue(label: "Browser.CEFExtensionRuntime", qos: .utility)
    private var notifyScheduled: Set<String> = []

    private var queue: [String] = []
    private var waiting: [String: [() -> Void]] = [:]
    private var creating: String?

    private weak var host: ExtensionHost?
    private weak var installList: EngineExtensionInstallList?
    private var keyFetchesTried: Set<String> = []

    /// Tabs and windows an extension opened recently, per profile and id:
    /// a runaway extension stops being obeyed instead of flooding the app.
    private var recentOpens: [String: [Date]] = [:]
    private static let openLimit = 10
    private static let openWindow: TimeInterval = 10

    private static let contextTimeout: TimeInterval = 20

    /// Gating starts only when some profile runs something: with no link on
    /// the switch, contexts are created as they always were.
    private var isGating: Bool { !linkedIds.isEmpty }

    // MARK: - Before the engine starts

    func setStorageDirectory(_ directory: @escaping (String) -> URL?) {
        storageDirectory = directory
    }

    /// Prepares every profile's copies and gives Chromium the switch. Must
    /// run before `BRWEngine.initialize`. Reads only the disk: nothing here
    /// waits on the network, and one extension's failure leaves the others
    /// and the launch alone.
    func prepareBeforeEngineStart(profilesRootPath: String) {
        BRWExtensionRuntime.delegate = self
        turnedOnIsFixed = true
        let root = URL(fileURLWithPath: profilesRootPath, isDirectory: true)
        profilesRoot = root
        guard isSupported else {
            NSLog("Browser: Chromium tabs run no extensions: this macOS has no extension install list")
            return
        }
        // Before any change on disk, also when off in this session: whoever
        // holds it may write later (an approval), and another process on
        // this root is about to hand its launch to the running one; it must
        // not move the files that one is serving from.
        let lockPath = root.appendingPathComponent(".cef-extension-lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            return turnOffForSession("another copy of Browser is using these profiles")
        }
        lockDescriptor = descriptor
        guard isTurnedOn else {
            NSLog("Browser: Chromium tabs run no extensions: turned off in Settings")
            return
        }
        guard storageDirectory != nil else {
            return turnOffForSession("no extension storage directory was given")
        }
        let links = root.appendingPathComponent(".cef-extension-links", isDirectory: true)
        guard !links.path.contains(",") else {
            return turnOffForSession("the profiles folder's path contains a comma")
        }

        var union = Set<String>()
        for profileId in profileIds(in: root) {
            let plan = prepareProfile(profileId)
            launchPlan[profileId] = plan
            union.formUnion(plan.keys)
        }
        // With nothing on the switch no profile can load a switch extension:
        // no links folder, and no profile's Preferences is touched.
        guard !union.isEmpty else { return }
        linksDirectory = links
        try? FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        removeAllLinks()
        for (profileId, plan) in launchPlan {
            applyCommandLineBlocklist(blocked: plan.isEmpty, profileId: profileId)
        }
        let paths = union.sorted().map { links.appendingPathComponent($0).path }
        guard BRWExtensionRuntime.setLoadExtensionPaths(paths) else {
            launchPlan = [:]
            return turnOffForSession("the engine had already read its switches")
        }
        linkedIds = union
        for (profileId, plan) in launchPlan where !plan.isEmpty {
            NSLog("Browser: profile %@ runs %@ in Chromium tabs", profileId, plan.keys.sorted().joined(separator: ", "))
        }
    }

    private func turnOffForSession(_ why: String) {
        sessionUnavailableReason = "Chromium tabs run no extensions in this session: \(why)."
        NSLog("Browser: Chromium tabs run no extensions: %@", why)
    }

    /// Folders under the root that hold a profile's extension state. Only
    /// app profiles (UUID-named) count, never Chromium's own `Default`.
    private func profileIds(in root: URL) -> [String] {
        let files = FileManager.default
        guard let names = try? files.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { name in
            guard UUID(uuidString: name) != nil else { return false }
            let folder = root.appendingPathComponent(name, isDirectory: true)
            return listURL(name).map { files.fileExists(atPath: $0.path) } == true
                || files.fileExists(atPath: folder.appendingPathComponent(Self.copiesPath).path)
                || files.fileExists(atPath: folder.appendingPathComponent("Preferences").path)
        }.sorted()
    }

    private func profileFolder(_ profileId: String) -> URL? {
        profilesRoot?.appendingPathComponent(profileId, isDirectory: true)
    }

    private func copiesFolder(_ profileId: String) -> URL? {
        profileFolder(profileId)?.appendingPathComponent(Self.copiesPath, isDirectory: true)
    }

    private func stateURL(_ profileId: String) -> URL? {
        copiesFolder(profileId)?.appendingPathComponent("state.json")
    }

    /// The profile's state file, or, when it cannot be read, what the copy
    /// folders on disk still tell (CEFExtensionProfileState.rebuilt).
    private func readState(_ profileId: String, copies: URL, onDisk: [String: Set<String>]) -> CEFExtensionProfileState {
        switch CEFExtensionProfileState.read(from: copies.appendingPathComponent("state.json")) {
        case .state(let state):
            return state
        case .absent where onDisk.isEmpty:
            return CEFExtensionProfileState()
        case .absent, .unreadable:
            NSLog("Browser: Chromium extension state of profile %@ is missing or unreadable; rebuilt from its copies", profileId)
            var workers: [String: [String]] = [:]
            for (id, names) in onDisk {
                for name in names {
                    let manifest = copies.appendingPathComponent(id).appendingPathComponent(name).appendingPathComponent("manifest.json")
                    if let data = try? Data(contentsOf: manifest), let parsed = try? CEFExtensionPolicy.parseManifest(data),
                       let worker = (parsed["background"] as? [String: Any])?["service_worker"] as? String {
                        workers[id, default: []].append((worker as NSString).lastPathComponent)
                    }
                }
            }
            return CEFExtensionProfileState.rebuilt(foldersOnDisk: onDisk, workerFiles: workers)
        }
    }

    /// Makes, keeps and deletes one profile's copies, deletes the data of
    /// extensions that left its list, and returns what it runs.
    private func prepareProfile(_ profileId: String) -> [String: Copy] {
        guard let profile = profileFolder(profileId), let copies = copiesFolder(profileId) else { return [:] }
        let files = FileManager.default
        let onDisk = Self.foldersOnDisk(copies)
        let state = readState(profileId, copies: copies, onDisk: onDisk)
        let read = readList(profileId)
        let list = read.list
        switch read {
        case .absent: NSLog("Browser: profile %@ has no extension list; nothing of its extension data is deleted", profileId)
        case .unreadable(let why): NSLog("Browser: the extension list of profile %@ could not be read (%@); nothing of its extension data is deleted", profileId, why)
        case .list: break
        }
        let declined: [String: [String]]
        if case .list(_, let found) = read { declined = found } else { declined = [:] }
        var approved = loadApprovals(profileId)
        if let list, !approvalsUnreadable.contains(profileId) {
            let ids = Set(list.extensions.map(\.id))
            let pruned = approved.filter { ids.contains($0.key) }
            if pruned != approved, let url = approvalsURL(profileId) {
                try? CEFExtensionApprovals.save(pruned, to: url)
                approved = pruned
                approvals[profileId] = pruned
            }
        }
        let current = Self.decide(list: list ?? InstalledWebExtensionList(), packages: storageDirectory?(profileId),
                                  approved: approved, declined: declined, stamps: [:])
        decisions[profileId] = current.decisions
        treeStamps[profileId] = current.stamps
        for (id, decision) in current.decisions.sorted(by: { $0.key < $1.key }) {
            switch decision {
            case .needsApproval: NSLog("Browser: extension %@ in profile %@ needs approval before it runs in Chromium tabs", id, profileId)
            case .unavailable(let why): NSLog("Browser: extension %@ in profile %@ does not run in Chromium tabs: %@", id, profileId, why)
            default: break
            }
        }
        let builds = current.decisions.values.compactMap(\.build).sorted { $0.id < $1.id }
        guard !builds.isEmpty || !state.known.isEmpty || !state.pendingDeletion.isEmpty || !onDisk.isEmpty else { return [:] }

        // A copy from before request tokens is never reused.
        var planState = state
        planState.current = state.current.filter { $0.value.requestToken != nil }
        if list == nil { NSLog("Browser: profile %@ runs no extension in Chromium tabs this session: no readable extension list", profileId) }
        let plan = CEFExtensionFolderPlan.make(
            state: planState, builds: builds, installed: list.map { Set($0.extensions.map(\.id)) }, foldersOnDisk: onDisk,
            newName: { build in
                let version = list?.extensions.first { $0.id == build.id }?.version ?? "0"
                return CEFExtensionFolderPlan.folderName(version: version, unique: String(UUID().uuidString.prefix(8)).lowercased())
            })

        var kept = plan.reuse
        var revisions = state.revisions
        var tokens: [String: String] = [:]
        for (id, _) in plan.reuse { tokens[id] = state.current[id]?.requestToken }
        for build in builds {
            guard let name = plan.prepare[build.id] else { continue }
            let destination = copies.appendingPathComponent(build.id, isDirectory: true).appendingPathComponent(name, isDirectory: true)
            let revision: Int?
            switch CEFExtensionFolderPlan.nextRevision(for: build, state: state) {
            case .none: revision = nil
            case .use(let next): revision = next
            case .exhausted:
                prepareFailures[profileId, default: [:]][build.id] = (build.fingerprint, CEFExtensionFolderPlan.revisionsExhausted)
                NSLog("Browser: not preparing extension %@ in profile %@: its content revisions are used up", build.id, profileId)
                continue
            }
            do {
                let prepared = try CEFExtensionPreparer.prepare(
                    source: URL(fileURLWithPath: build.sourceFolder, isDirectory: true), extensionID: build.id,
                    publicKey: build.publicKey, destination: destination, contentRevision: revision,
                    previous: previousCopy(state.current[build.id], id: build.id, copies: copies))
                kept[build.id] = name
                tokens[build.id] = prepared.token
                if let revision { revisions[build.id] = revision }
                NSLog("Browser: prepared extension %@ for Chromium tabs of profile %@ (%@)", build.id, profileId, name)
            } catch {
                // A revision is spent even when the copy failed, so it is
                // never used again for other content.
                if let revision { revisions[build.id] = revision }
                prepareFailures[profileId, default: [:]][build.id] = (build.fingerprint, error.localizedDescription)
                NSLog("Browser: couldn't prepare extension %@ for Chromium tabs of profile %@: %@", build.id, profileId, error.localizedDescription)
            }
        }

        var copiesById: [String: Copy] = [:]
        // With no list read, the record of the copies stays as it was.
        var newState = CEFExtensionProfileState(current: list == nil ? state.current : [:], known: [])
        for build in builds {
            guard let name = kept[build.id] else { continue }
            let folder = copies.appendingPathComponent(build.id, isDirectory: true).appendingPathComponent(name, isDirectory: true)
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
                  let manifest = try? CEFExtensionPolicy.parseManifest(data) else {
                kept[build.id] = nil
                prepareFailures[profileId, default: [:]][build.id] = (build.fingerprint, "Its prepared copy has no readable manifest.")
                continue
            }
            copiesById[build.id] = Copy(build: build, folder: folder, manifest: manifest, token: tokens[build.id])
            newState.current[build.id] = .init(folder: name, fingerprint: build.fingerprint, revision: revisions[build.id],
                                               requestToken: tokens[build.id])
        }
        newState.known = Set(state.known).union(copiesById.keys).subtracting(plan.deleteData).sorted()
        // With no list read nothing is deleted, and what was still to be
        // deleted stays to be deleted.
        newState.pendingDeletion = list == nil ? state.pendingDeletion : plan.deleteData
        // Never dropped (see CEFExtensionProfileState.revisions).
        newState.revisions = revisions
        var lifecycle = state.lifecycle ?? [:]
        if state.lifecycle == nil, list != nil {
            // No records (an older file, or one rebuilt): what ran before
            // counts as installed, so it gets onStartup, never install.
            for id in state.known where lifecycle[id] == nil {
                lifecycle[id] = CEFExtensionLifecycle.Record(installedVersion: list?.extensions.first { $0.id == id }?.version)
            }
        }
        for id in plan.deleteData { lifecycle[id] = nil }
        // No records and no list to take versions from: stay without
        // records, so the next launch with a list takes the path above.
        newState.lifecycle = state.lifecycle == nil && list == nil ? nil : lifecycle
        storeVersions[profileId] = Dictionary((list?.extensions ?? []).map { ($0.id, $0.version) }, uniquingKeysWith: { first, _ in first })
        changedWorkers[profileId] = Set(plan.prepare.keys.filter { id in
            ((copiesById[id]?.manifest["background"] as? [String: Any])?["service_worker"] as? String) != nil
        })
        do {
            try files.createDirectory(at: copies, withIntermediateDirectories: true)
            try newState.save(to: copies.appendingPathComponent("state.json"))
        } catch {
            // Without the new state written, the old copies stay: the next
            // launch would still name them current.
            NSLog("Browser: couldn't save the Chromium extension state of profile %@: %@", profileId, error.localizedDescription)
            profileStates[profileId] = newState
            return copiesById
        }

        var stillPending: [String] = []
        for id in plan.deleteData {
            for relative in CEFExtensionData.profileRelativePaths(for: id) {
                let target = profile.appendingPathComponent(relative)
                guard files.fileExists(atPath: target.path) else { continue }
                do {
                    try files.removeItem(at: target)
                    NSLog("Browser: deleted Chromium data of removed extension %@ in profile %@: %@", id, profileId, relative)
                } catch {
                    stillPending.append(id)
                    NSLog("Browser: couldn't delete %@ of removed extension %@: %@", relative, id, error.localizedDescription)
                }
            }
        }
        if list != nil { newState.pendingDeletion = Array(Set(stillPending)).sorted() }
        if list != nil, newState.pendingDeletion != plan.deleteData { try? newState.save(to: copies.appendingPathComponent("state.json")) }
        profileStates[profileId] = newState

        // With no list read, only folders of a copy that was just replaced
        // go; the rest may belong to an extension the list still holds.
        let keepFolders: [String: String] = list == nil
            ? onDisk.reduce(into: kept) { result, entry in
                if result[entry.key] == nil, let current = state.current[entry.key]?.folder { result[entry.key] = current }
            }
            : kept
        for (id, names) in CEFExtensionFolderPlan.foldersToDelete(onDisk: onDisk, keep: keepFolders) {
            if list == nil, keepFolders[id] == nil { continue }
            let parent = copies.appendingPathComponent(id, isDirectory: true)
            for name in names { try? files.removeItem(at: parent.appendingPathComponent(name)) }
            if (try? files.contentsOfDirectory(atPath: parent.path))?.isEmpty == true { try? files.removeItem(at: parent) }
        }
        return copiesById
    }

    /// The copy a new one replaces, for the preparer's check that the
    /// version and worker name never repeat with other code.
    private func previousCopy(_ entry: CEFExtensionProfileState.Copy?, id: String, copies: URL) -> PreviousCEFCopy? {
        guard let entry else { return nil }
        let manifestURL = copies.appendingPathComponent(id).appendingPathComponent(entry.folder).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL), let manifest = try? CEFExtensionPolicy.parseManifest(data),
              let version = manifest["version"] as? String else { return nil }
        return PreviousCEFCopy(version: version, workerFile: (manifest["background"] as? [String: Any])?["service_worker"] as? String)
    }

    /// Copy folders by extension id, after clearing what an interrupted
    /// prepare left behind.
    private static func foldersOnDisk(_ copies: URL) -> [String: Set<String>] {
        let files = FileManager.default
        var out: [String: Set<String>] = [:]
        guard let ids = try? files.contentsOfDirectory(atPath: copies.path) else { return out }
        for id in ids where ChromeExtensionID.isValid(id) {
            let parent = copies.appendingPathComponent(id, isDirectory: true)
            CEFExtensionPreparer.removeLeftovers(in: parent)
            let names = (try? files.contentsOfDirectory(atPath: parent.path)) ?? []
            out[id] = Set(names.filter { !$0.hasPrefix(".") })
        }
        return out
    }

    /// A profile that runs nothing also gets Chromium's own switch-off, as a
    /// second guard. Only an existing `Preferences` is touched: a profile
    /// Chromium has never opened finds every link absent anyway.
    private func applyCommandLineBlocklist(blocked: Bool, profileId: String) {
        guard let folder = profileFolder(profileId),
              FileManager.default.fileExists(atPath: ChromiumProfilePreferences.fileURL(inProfileFolder: folder).path) else { return }
        do {
            let outcome = try ChromiumProfilePreferences.apply([ChromiumProfilePreferences.commandLineExtensionsBlocked(blocked)],
                                                               toProfileFolder: folder)
            if case .leftAlone(let reason) = outcome {
                NSLog("Browser: left Chromium's Preferences of profile %@ alone: %@", profileId, reason)
            }
        } catch {
            NSLog("Browser: couldn't update Chromium's Preferences of profile %@: %@", profileId, error.localizedDescription)
        }
    }

    // MARK: - Decisions

    private func listURL(_ profileId: String) -> URL? {
        storageDirectory?(profileId)?.appendingPathComponent("installed.json")
    }

    private func readList(_ profileId: String) -> CEFExtensionInstallList.Read {
        guard let url = listURL(profileId) else { return .absent }
        listBytes[profileId] = (try? Data(contentsOf: url)) ?? Data()
        return CEFExtensionInstallList.read(url)
    }

    /// File work only: safe off the main thread. `stamps` are the unpacked
    /// tree stamps to reuse; a missing one is taken.
    private static func decide(list: InstalledWebExtensionList, packages: URL?, approved: [String: [String]],
                               declined: [String: [String]], stamps: [String: String])
        -> (decisions: [String: CEFExtensionDecision], stamps: [String: String]) {
        guard let packages else { return ([:], [:]) }
        var out: [String: CEFExtensionDecision] = [:]
        var newStamps: [String: String] = [:]
        for record in list.extensions {
            let facts = Self.facts(for: record, packages: packages, stamp: stamps[record.id])
            if let stamp = facts.treeStamp { newStamps[record.id] = stamp }
            out[record.id] = CEFExtensionPlanner.decide(record, facts: facts, approved: approved[record.id] ?? [],
                                                        declined: declined[record.id] ?? [])
        }
        return (out, newStamps)
    }

    /// `packages` is the owner's storage directory: a store install's package
    /// is `<packages>/<id>/`, as unpacked or with WebKit's layer in it (the
    /// preparer takes either).
    private static func facts(for record: InstalledWebExtension, packages: URL, stamp: String?) -> CEFExtensionSourceFacts {
        let folder: URL
        switch record.source {
        case .webStore: folder = packages.appendingPathComponent(record.id, isDirectory: true)
        case .unpacked: folder = URL(fileURLWithPath: record.unpackedPath ?? "/nonexistent", isDirectory: true)
        }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")) else {
            return CEFExtensionSourceFacts(folder: folder.path, folderExists: false)
        }
        let unpacked = record.source == .unpacked
        let verdict = CEFExtensionPolicy.evaluate(manifestData: data)
        let sourceVersion = (try? CEFExtensionPolicy.parseManifest(data))?["version"] as? String
        return CEFExtensionSourceFacts(
            folder: folder.path, folderExists: true,
            manifestKey: unpacked ? CEFExtensionPreparer.pinnedPublicKey(inManifestAt: folder) : nil,
            refusal: verdict.refusal,
            treeStamp: unpacked ? (stamp ?? CEFExtensionTreeStamp.stamp(of: folder)) : nil,
            chromiumGrants: verdict.grants, sourceVersion: sourceVersion)
    }

    /// Recomputes a profile's decisions off the main thread and says so when
    /// they changed. `restamp` re-reads unpacked folder trees.
    private func refreshDecisions(_ profileId: String, restamp: Bool) {
        guard isSupported, isTurnedOn, let url = listURL(profileId) else { return }
        guard refreshScheduled.insert(profileId).inserted else {
            refreshAgain[profileId] = (refreshAgain[profileId] ?? false) || restamp
            return
        }
        let packages = storageDirectory?(profileId)
        let approved = loadApprovals(profileId)
        let stamps = restamp ? [:] : (treeStamps[profileId] ?? [:])
        let previousBytes = listBytes[profileId]
        let known = decisions[profileId] != nil
        work.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            let bytes = (try? Data(contentsOf: url)) ?? Data()
            var result: (decisions: [String: CEFExtensionDecision], stamps: [String: String])?
            if restamp || !known || bytes != previousBytes {
                let read = CEFExtensionInstallList.parse(bytes)
                let declined: [String: [String]]
                if case .list(_, let found) = read { declined = found } else { declined = [:] }
                result = Self.decide(list: read.list ?? InstalledWebExtensionList(), packages: packages, approved: approved,
                                     declined: declined, stamps: stamps)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshScheduled.remove(profileId)
                // One more run with what changed meanwhile (an approval, a
                // restamp): never lost.
                if let again = self.refreshAgain.removeValue(forKey: profileId) {
                    DispatchQueue.main.async { self.refreshDecisions(profileId, restamp: again) }
                }
                guard let result else { return }
                self.listBytes[profileId] = bytes
                self.treeStamps[profileId] = result.stamps
                guard self.decisions[profileId] != result.decisions else { return }
                self.decisions[profileId] = result.decisions
                self.notifyChanged(profileId)
            }
        }
    }

    /// One change notice per profile per run-loop turn, however many causes.
    private func notifyChanged(_ profileId: String) {
        guard notifyScheduled.insert(profileId).inserted else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notifyScheduled.remove(profileId)
            self.host?.extensionsDidChange(profileId: profileId)
        }
    }

    /// What the profile runs in this session: what it loaded, or what it
    /// will load when its first CEF tab opens.
    private func sessionCopies(_ profileId: String) -> [String: Copy] {
        loaded[profileId] ?? launchPlan[profileId] ?? [:]
    }

    // MARK: - One context at a time

    /// Runs `body` once the profile's context exists with its own
    /// extensions loaded: at once when it already does, or when nothing runs
    /// in CEF tabs at all; otherwise after every profile queued before it.
    /// A CEF tab of a profile creates its browser from here.
    func whenProfileReady(_ profileId: String, _ body: @escaping () -> Void) {
        guard isGating else { return body() }
        if BRWExtensionRuntime.isProfileContextInitialized(profileId), creating != profileId {
            if holding.contains(profileId) {
                waiting[profileId, default: []].append(body)
                return
            }
            if loaded[profileId] == nil {
                NSLog("Browser: profile %@'s context was created outside the extension queue", profileId)
                loaded[profileId] = [:]
            }
            return body()
        }
        waiting[profileId, default: []].append(body)
        if creating != profileId, !queue.contains(profileId) { queue.append(profileId) }
        startNextContext()
    }

    private func startNextContext() {
        guard creating == nil else { return }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if BRWExtensionRuntime.isProfileContextInitialized(next) {
                if loaded[next] == nil { loaded[next] = [:] }
                if !holding.contains(next) { runWaiting(next) }
                continue
            }
            creating = next
            if linksRetired {
                retiredProfiles.insert(next)
                NSLog("Browser: profile %@ runs no extensions in Chromium tabs: the links are retired for this session", next)
            } else {
                pointLinks(at: launchPlan[next] ?? [:])
            }
            BRWExtensionRuntime.initializeProfileContext(id: next) { [weak self] in
                self?.contextDidInitialize(next, timedOut: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.contextTimeout) { [weak self] in
                guard let self, self.creating == next else { return }
                NSLog("Browser: profile %@'s context did not report itself ready in %.0f s; no extension link is set again this session", next, Self.contextTimeout)
                self.contextDidInitialize(next, timedOut: true)
            }
            return
        }
    }

    private func contextDidInitialize(_ profileId: String, timedOut: Bool) {
        guard creating == profileId else { return }
        creating = nil
        removeAllLinks()
        if timedOut {
            // Not confirmed is not done: the context may still read the
            // links, so none is pointed again for any profile.
            linksRetired = true
        }
        let plan = retiredProfiles.contains(profileId) ? [:] : (launchPlan[profileId] ?? [:])
        loaded[profileId] = plan
        if !plan.isEmpty {
            NSLog("Browser: profile %@ loaded %@ in Chromium tabs%@", profileId, plan.keys.sorted().joined(separator: ", "),
                  timedOut ? " (unconfirmed: the context timed out)" : "")
        }
        holdUntilWorkersActivate(profileId)
        notifyChanged(profileId)
        startNextContext()
    }

    /// The profile's waiting tabs open once every changed extension's new
    /// worker has activated, or after `activationHold`; at once when no copy
    /// changed. The next profile's context is not held up.
    private func holdUntilWorkersActivate(_ profileId: String) {
        let pending = (loaded[profileId]?.isEmpty == false ? (changedWorkers[profileId] ?? []) : [])
            .subtracting(activatedWorkers[profileId] ?? [])
        guard !pending.isEmpty else { return runWaiting(profileId) }
        holding.insert(profileId)
        NSLog("Browser: holding profile %@'s first pages until %@ activate", profileId, pending.sorted().joined(separator: ", "))
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.activationHold) { [weak self] in
            guard let self, self.holding.contains(profileId) else { return }
            NSLog("Browser: profile %@'s new extension workers did not all activate in %.0f s; opening its pages", profileId, Self.activationHold)
            self.releaseHold(profileId)
        }
    }

    private func releaseHold(_ profileId: String) {
        guard holding.remove(profileId) != nil else { return }
        runWaiting(profileId)
    }

    private func workerDidActivate(_ id: String, profileId: String) {
        activatedWorkers[profileId, default: []].insert(id)
        guard holding.contains(profileId),
              (changedWorkers[profileId] ?? []).isSubset(of: activatedWorkers[profileId] ?? []) else { return }
        NSLog("Browser: profile %@'s new extension workers are active; opening its pages", profileId)
        releaseHold(profileId)
    }

    private func runWaiting(_ profileId: String) {
        let bodies = waiting.removeValue(forKey: profileId) ?? []
        bodies.forEach { $0() }
    }

    private func pointLinks(at plan: [String: Copy]) {
        removeAllLinks()
        guard !linksRetired, let links = linksDirectory else { return }
        for (id, copy) in plan where linkedIds.contains(id) {
            do {
                try FileManager.default.createSymbolicLink(at: links.appendingPathComponent(id), withDestinationURL: copy.folder)
            } catch {
                NSLog("Browser: couldn't link extension %@ for Chromium: %@", id, error.localizedDescription)
            }
        }
    }

    private func removeAllLinks() {
        guard let links = linksDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: links.path) else { return }
        for name in names { try? FileManager.default.removeItem(at: links.appendingPathComponent(name)) }
    }

    // MARK: - FollowerExtensionRuntime

    var runsThisSession: Bool { isAvailable }

    func attach(host: ExtensionHost, installList: EngineExtensionInstallList?) {
        self.host = host
        self.installList = installList
        guard isAvailable else { return }
        runTestHooks()
        let profiles = Array(decisions.keys)
        Task { @MainActor in
            // After launch, never in its way.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            for profileId in profiles { await self.refreshFromStore(profileId: profileId) }
        }
    }

    /// Scratch launches only (`--profiles-root` that is not the real data,
    /// `--test-extension-hooks`): logs each installed extension's consent
    /// note, and approves `--test-approve-extension <id>` as the approval
    /// sheet would, for checks that cannot drive the UI.
    private func runTestHooks() {
        let arguments = CommandLine.arguments
        guard arguments.contains("--test-extension-hooks"), CommandLineArgs.allowsAgentExtensionsRoot else { return }
        var approve: [String] = []
        for (index, argument) in arguments.enumerated() where argument == "--test-approve-extension" && index + 1 < arguments.count {
            approve.append(arguments[index + 1])
        }
        for (profileId, current) in decisions {
            guard let packages = storageDirectory?(profileId), let url = listURL(profileId),
                  let list = CEFExtensionInstallList.read(url).list else { continue }
            for record in list.extensions {
                let folder = record.source == .webStore ? packages.appendingPathComponent(record.id) : URL(fileURLWithPath: record.unpackedPath ?? "/")
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
                      let manifest = try? CEFExtensionPolicy.parseManifest(data) else { continue }
                NSLog("Browser: test hook: consent note for %@: %@", record.id, consentNote(manifest: manifest) ?? "none")
            }
            for id in approve where current[id] != nil {
                guard case .needsApproval(let shown) = current[id] else { continue }
                let recorded = approveGrants(shown, extensionId: id, profileId: profileId)
                NSLog("Browser: test hook: approval of %@ in profile %@ recorded: %@; status needsApproval=%@ needsRelaunch=%@", id, profileId,
                      recorded ? "yes" : "no", status(extensionId: id, profileId: profileId)?.needsApproval == true ? "yes" : "no",
                      status(extensionId: id, profileId: profileId)?.needsRelaunch == true ? "yes" : "no")
            }
        }
    }

    func installListDidChange(profileId: String) {
        refreshDecisions(profileId, restamp: false)
    }

    func refreshRuntimeStatus(profileId: String) {
        refreshDecisions(profileId, restamp: true)
    }

    func status(extensionId id: String, profileId: String) -> EngineExtensionRuntimeStatus? {
        guard isSupported, isTurnedOn else { return nil }
        guard let decision = decisions[profileId]?[id] else {
            refreshDecisions(profileId, restamp: false)
            return nil
        }
        let running = sessionCopies(profileId)[id]
        var status = EngineExtensionRuntimeStatus(
            isRunning: running != nil, needsRelaunch: reloadRequested[profileId]?.contains(id) == true,
            unavailableReason: nil, isWaitingForKey: false)
        if let reason = sessionUnavailableReason {
            status.needsRelaunch = false
            status.unavailableReason = reason
            return status
        }
        switch decision {
        case .run(let build):
            if let failure = prepareFailures[profileId]?[id], failure.fingerprint == build.fingerprint, running == nil {
                status.unavailableReason = "It could not be prepared for Chromium tabs: \(failure.message)"
            } else if running?.build.fingerprint != build.fingerprint {
                status.needsRelaunch = true
            }
        case .disabled:
            if running != nil { status.needsRelaunch = true }
        case .waitingForKey:
            status.isWaitingForKey = true
            if running != nil { status.needsRelaunch = true }
        case .unavailable(let reason):
            status.unavailableReason = reason
            if running != nil { status.needsRelaunch = true }
        case .needsApproval(let grants):
            status.needsApproval = true
            status.approvalGrants = grants
            if running != nil { status.needsRelaunch = true }
        }
        if retiredProfiles.contains(profileId), running == nil, status.unavailableReason == nil, case .run = decision {
            status.needsRelaunch = true
            status.unavailableReason = Self.retiredReason
        }
        return status
    }

    func extensionsStillRunningAfterRemoval(profileId: String) -> [EngineExtensionStillRunning] {
        guard isAvailable, let current = decisions[profileId] else { return [] }
        return sessionCopies(profileId).filter { current[$0.key] == nil }.map { id, copy in
            EngineExtensionStillRunning(id: id, name: copy.manifest["name"] as? String ?? id, engine: .cef)
        }.sorted { $0.id < $1.id }
    }

    /// The user approved, through the approval sheet, everything Chromium
    /// would grant the extension now.
    /// Records exactly `shown`, the list the sheet showed; true only when
    /// that covers what Chromium would grant the extension now.
    @discardableResult
    func approveGrants(_ shown: [String], extensionId id: String, profileId: String) -> Bool {
        guard case .needsApproval(let wanted) = decisions[profileId]?[id], !shown.isEmpty else { return false }
        guard Set(wanted).isSubset(of: Set(shown)) else {
            NSLog("Browser: not recording approval of extension %@: Chromium would now grant more than the sheet showed", id)
            return false
        }
        recordApproval(shown, extensionId: id, profileId: profileId)
        return true
    }

    /// An install or reload consent that carried this runtime's note was
    /// accepted for one extension: it approves exactly what that sheet
    /// listed, when that covers what Chromium would grant the extension.
    func consentWasAccepted(manifests: [[String: Any]], extensionId id: String, profileId: String) {
        let shown = manifests.map { CEFExtensionPolicy.evaluate(manifest: $0) }.filter(\.canRun).flatMap(\.grants)
        guard !shown.isEmpty,
              let url = listURL(profileId), case .list(let list, let declined) = CEFExtensionInstallList.read(url),
              let record = list.extensions.first(where: { $0.id == id }) else { return }
        let single = InstalledWebExtensionList(extensions: [record])
        let decided = Self.decide(list: single, packages: storageDirectory?(profileId), approved: loadApprovals(profileId),
                                  declined: declined, stamps: treeStamps[profileId] ?? [:]).decisions[id]
        guard case .needsApproval(let wanted) = decided, !wanted.isEmpty, Set(wanted).isSubset(of: Set(shown)) else { return }
        recordApproval(wanted, extensionId: id, profileId: profileId)
    }

    private func approvalsURL(_ profileId: String) -> URL? {
        copiesFolder(profileId)?.appendingPathComponent("approvals.json")
    }

    /// From disk the first time; an unreadable file counts as no approvals
    /// and is never overwritten.
    private func loadApprovals(_ profileId: String) -> [String: [String]] {
        if let known = approvals[profileId] { return known }
        guard let url = approvalsURL(profileId) else { return [:] }
        switch CEFExtensionApprovals.read(url) {
        case .approvals(let found):
            approvals[profileId] = found
            return found
        case .absent:
            approvals[profileId] = [:]
            return [:]
        case .unreadable:
            approvalsUnreadable.insert(profileId)
            NSLog("Browser: the Chromium approvals of profile %@ could not be read; none is recorded until it is fixed", profileId)
            approvals[profileId] = [:]
            return [:]
        }
    }

    /// Writes only `approvals.json`, never the launch state, and only in the
    /// process that holds the profiles root's lock.
    private func recordApproval(_ grants: [String], extensionId id: String, profileId: String) {
        var current = loadApprovals(profileId)
        guard lockDescriptor >= 0, !approvalsUnreadable.contains(profileId),
              let copies = copiesFolder(profileId), let url = approvalsURL(profileId) else {
            NSLog("Browser: did not record approval of extension %@: this session may not write the profile's files", id)
            return
        }
        current[id] = Array(Set(current[id] ?? []).union(grants)).sorted()
        do {
            try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
            try CEFExtensionApprovals.save(current, to: url)
            approvals[profileId] = current
            NSLog("Browser: recorded approval of extension %@ for Chromium tabs of profile %@", id, profileId)
        } catch {
            NSLog("Browser: couldn't save the approval of extension %@: %@", id, error.localizedDescription)
        }
        refreshDecisions(profileId, restamp: false)
    }

    /// The extension ids and store versions on the profile's list now, read
    /// directly; for telling which extensions an operation changed.
    func listedVersions(profileId: String) -> [String: String] {
        guard let url = listURL(profileId), let list = CEFExtensionInstallList.read(url).list else { return [:] }
        return Dictionary(list.extensions.map { ($0.id, $0.version) }, uniquingKeysWith: { first, _ in first })
    }

    func action(extensionId id: String, profileId: String, base: EngineExtensionAction?) -> EngineExtensionAction? {
        let copy = sessionCopies(profileId)[id]
        guard base != nil || copy != nil else { return nil }
        let name = copy?.manifest["name"] as? String
        let hasPopup = copy.flatMap { CEFExtensionRequest.popupPage(manifest: $0.manifest, extensionId: id) } != nil
        let reason: String?
        if copy == nil {
            reason = notRunningReason(extensionId: id, profileId: profileId)
        } else if !hasPopup {
            reason = "It has no popup, and Chromium tabs do not tell an extension that its button was clicked."
        } else {
            reason = nil
        }
        return EngineExtensionAction(
            label: base?.label ?? name ?? id,
            icon: base?.icon,
            badgeText: "",
            isEnabled: hasPopup,
            disabledReason: reason)
    }

    /// Why an extension on the list does not run in this session's CEF tabs.
    private func notRunningReason(extensionId id: String, profileId: String) -> String {
        let status = status(extensionId: id, profileId: profileId)
        if let reason = status?.unavailableReason { return "It does not run in Chromium tabs. \(reason)" }
        if status?.needsApproval == true {
            return "It runs in Chromium tabs after you approve what Chromium gives it, in Window > Extensions, and Browser relaunches."
        }
        if status?.isWaitingForKey == true {
            return "It runs in Chromium tabs after Browser gets its Chrome Web Store key and relaunches."
        }
        return "It runs in Chromium tabs after Browser relaunches."
    }

    /// True whenever this runtime runs the extension: the owner's popup
    /// would show the other engine's state, not this tab's.
    func performAction(extensionId id: String, window: ExtensionHostWindow) -> Bool {
        let profileId = window.extensionProfileId
        guard let copy = sessionCopies(profileId)[id] else { return false }
        guard let page = CEFExtensionRequest.popupPage(manifest: copy.manifest, extensionId: id) else {
            NSLog("Browser: extension %@ has no popup; a press is not reported to it in Chromium tabs", id)
            return true
        }
        let request = EngineExtensionPopupRequest(extensionId: id, profileId: profileId, engine: .cef, url: page,
                                                  window: window, requestedByExtension: false)
        if host?.extensionPresentPopup(request) != true {
            NSLog("Browser: the popup of extension %@ was not shown", id)
        }
        return true
    }

    /// What the user must hear before agreeing to an extension that will
    /// also run here: Chromium grants an unpacked extension everything its
    /// manifest names, at load, with no prompt of its own. Follows the
    /// setting the next launch will use, since that is when it applies.
    func consentNote(manifest: [String: Any]) -> String? {
        guard isSupported, nextLaunchSetting?() ?? isTurnedOn else { return nil }
        let verdict = CEFExtensionPolicy.evaluate(manifest: manifest)
        if let reason = verdict.reason { return "It will not run in Chromium tabs. \(reason)" }
        var lines: [String] = []
        if #available(macOS 15.4, *) { lines = WebKitExtensionManager.describe(verdict.grants) }
        lines += verdict.consentNotes.keys.sorted().compactMap { verdict.consentNotes[$0] }
        let intro = "It will also run in Chromium tabs, from the next time Browser starts. "
            + "There, Chromium gives it everything its manifest asks for, without asking again"
        return lines.isEmpty ? intro + "; it asks for no special access." : intro + ":\n• " + lines.joined(separator: "\n• ")
    }

    func owns(_ tab: EngineTab) -> Bool { CEFEngine.owns(tab) }

    func extensionsReachEveryTab(profileId: String) -> Bool {
        isGating && !sessionCopies(profileId).isEmpty
    }

    /// Downloads the store package of each enabled store install that has no
    /// key yet, keeps the key it proves, and drops the package. Once per
    /// extension per session.
    @MainActor
    func refreshFromStore(profileId: String) async {
        guard isAvailable, let installList else { return }
        for (id, decision) in decisions[profileId] ?? [:] where decision == .waitingForKey {
            guard keyFetchesTried.insert(profileId + "|" + id).inserted else { continue }
            do {
                let crx = try await WebKitExtensionInstaller.fetchPackage(id: id)
                let key = try await Task.detached(priority: .utility) { try Crx3.verifiedPackage(crx, expectedID: id).publicKey }.value
                if installList.storePublicKey(key, extensionId: id, profileId: profileId) {
                    NSLog("Browser: kept the store key of extension %@; it runs in Chromium tabs after a relaunch", id)
                    notifyChanged(profileId)
                }
            } catch {
                NSLog("Browser: couldn't get the store key of extension %@: %@", id, error.localizedDescription)
            }
        }
    }

    // MARK: - BRWExtensionRuntimeDelegate

    func extensionRuntimeDidReceiveRequest(kind: String, extensionId: String, profileId: String, payloadJSON: String,
                                           reply: @escaping BRWExtensionBridgeReply) {
        guard !CEFEngine.isTerminating else { return reply(false, Self.errorJSON("Browser is quitting")) }
        // A worker starts while its context is still being created, before
        // the initialized signal: it counts as loaded from that moment.
        guard let copy = (loaded[profileId] ?? (creating == profileId ? launchPlan[profileId] : nil))?[extensionId] else {
            NSLog("Browser: refused %@ from extension %@: not running in profile %@", kind, extensionId, profileId)
            return reply(false, Self.errorJSON("extension not running in this profile"))
        }
        // The token is only in the copy's own shim: a request without it
        // did not come from this copy's code (a redirect, another origin).
        guard let token = copy.token, CEFExtensionRequest.token(in: payloadJSON) == token else {
            NSLog("Browser: refused %@ from extension %@: wrong request token", kind, extensionId)
            return reply(false, Self.errorJSON("forbidden"))
        }
        switch CEFExtensionRequest.parse(kind: kind, payloadJSON: payloadJSON, extensionId: extensionId) {
        case .failure(let refusal):
            NSLog("Browser: refused %@ from extension %@: %@", kind, extensionId, refusal.message)
            reply(false, Self.errorJSON(refusal.message))
        case .success(let request):
            handle(request, kind: kind, copy: copy, profileId: profileId, reply: reply)
        }
    }

    private func handle(_ request: CEFExtensionRequest, kind: String, copy: Copy, profileId: String, reply: @escaping BRWExtensionBridgeReply) {
        let id = copy.build.id
        NSLog("Browser: extension %@ in profile %@ asked for %@", id, profileId, kind)
        switch request {
        case .openTab(let url, let active, let pinned):
            guard allowOpen(id, profileId: profileId) else { return reply(false, Self.errorJSON("too many tabs")) }
            guard let tab = openTab(url, profileId: profileId, active: active) else { return reply(false, Self.errorJSON("no window")) }
            if pinned { tab.extensionSetPinned(true) }
            let index = tab.extensionWindow?.extensionTabs.firstIndex { $0 === tab } ?? -1
            var info: [String: Any] = ["index": index, "active": active, "pinned": pinned, "incognito": false]
            if let url { info["url"] = url.absoluteString; info["pendingUrl"] = url.absoluteString }
            reply(true, Self.json(["tab": info]))
        case .openWindow(let urls, let focused):
            // One request is one open; its size is capped by the parser.
            guard allowOpen(id, profileId: profileId) else { return reply(false, Self.errorJSON("too many tabs")) }
            guard host?.extensionOpenWindow(profileId: profileId, urls: urls, focused: focused,
                                            engine: Self.engine(for: urls.first)) != nil else {
                return reply(false, Self.errorJSON("no window"))
            }
            reply(true, Self.json(["window": ["focused": focused, "incognito": false, "type": "normal", "state": "normal"]]))
        case .openOptionsPage:
            guard let page = CEFExtensionRequest.optionsPage(manifest: copy.manifest, extensionId: id) else {
                return reply(false, Self.errorJSON("no options page"))
            }
            guard allowOpen(id, profileId: profileId) else { return reply(false, Self.errorJSON("too many tabs")) }
            reply(openTab(page, profileId: profileId, active: true) != nil, nil)
        case .openClientWindow(let url):
            guard allowOpen(id, profileId: profileId) else { return reply(false, Self.errorJSON("too many tabs")) }
            reply(openTab(url, profileId: profileId, active: true) != nil, nil)
        case .reload:
            // Once per extension per session: a loop is not a reason to
            // ask the user to relaunch again and again.
            if reloadRequested[profileId, default: []].insert(id).inserted { notifyChanged(profileId) }
            reply(true, nil)
        case .webAuthFlow:
            reply(false, Self.errorJSON("identity.launchWebAuthFlow is not available in Chromium tabs"))
        case .workerStarted:
            var due: [String: Any] = [:]
            for event in dueEvents(id, profileId: profileId) {
                switch event {
                case .installed: due["onInstalled"] = ["reason": "install"]
                case .updated(let previous): due["onInstalled"] = ["reason": "update", "previousVersion": previous]
                case .startup: due["onStartup"] = true
                }
            }
            reply(true, Self.json(due))
        case .workerActivated:
            workerDidActivate(id, profileId: profileId)
            reply(true, nil)
        case .lifecycleDelivered(let events):
            confirmLifecycle(events, extensionId: id, profileId: profileId)
            reply(true, nil)
        case .openPopup:
            guard let page = CEFExtensionRequest.popupPage(manifest: copy.manifest, extensionId: id) else {
                return reply(false, Self.errorJSON("no popup"))
            }
            let window = host?.extensionWindows(profileId: profileId).first
            let request = EngineExtensionPopupRequest(extensionId: id, profileId: profileId, engine: .cef, url: page,
                                                      window: window, requestedByExtension: true)
            let shown = host?.extensionPresentPopup(request) ?? false
            reply(shown, shown ? nil : Self.errorJSON("popup not shown"))
        }
    }

    /// At most `openLimit` tabs per `openWindow` seconds per extension.
    private func allowOpen(_ id: String, profileId: String, count: Int = 1) -> Bool {
        let key = profileId + "|" + id
        let now = Date()
        var recent = (recentOpens[key] ?? []).filter { now.timeIntervalSince($0) < Self.openWindow }
        guard recent.count + count <= Self.openLimit else {
            NSLog("Browser: extension %@ in profile %@ opened too many tabs; refused", id, profileId)
            recentOpens[key] = recent
            return false
        }
        recent.append(contentsOf: Array(repeating: now, count: count))
        recentOpens[key] = recent
        return true
    }

    /// An extension's page called `window.open` on one of its own pages, or
    /// followed a link to one in a new tab (the only such request the
    /// bridge lets through). A window request -- an action popup's fallback
    /// when `action.openPopup` fails -- is shown like the action popup;
    /// anything else, or a popup the app refuses, opens as a CEF tab. Both
    /// are the app's, and the page may close them with `window.close()`.
    func extensionPageRequestedOpen(_ url: URL, profileId: String, asWindow: Bool) {
        guard !CEFEngine.isTerminating else { return }
        guard let id = url.host?.lowercased(), loaded[profileId]?[id] != nil else {
            NSLog("Browser: refused to open %@: its extension does not run in profile %@", url.absoluteString, profileId)
            return
        }
        if asWindow {
            let request = EngineExtensionPopupRequest(extensionId: id, profileId: profileId, engine: .cef, url: url,
                                                      window: host?.extensionWindows(profileId: profileId).first,
                                                      requestedByExtension: true)
            if host?.extensionPresentPopup(request) == true { return }
        }
        guard allowOpen(id, profileId: profileId) else { return }
        NSLog("Browser: extension %@ opened its page %@ in a tab", id, url.absoluteString)
        openTab(url, profileId: profileId, active: true)
    }

    func extensionRuntimeDidCloseUnmanagedBrowser(url: String?, profileId: String?) {
        NSLog("Browser: closed a window Chromium opened on its own (profile %@): %@", profileId ?? "none", url ?? "blank")
        guard !CEFEngine.isTerminating else { return }
        guard let url, let profileId, let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased() else { return }
        let allowed: Bool
        if scheme == "chrome-extension" {
            allowed = parsed.host.map { loaded[profileId]?[$0] != nil } ?? false
        } else {
            allowed = scheme == "http" || scheme == "https" ? !(parsed.host ?? "").isEmpty : false
        }
        guard allowed, allowOpen("unmanaged", profileId: profileId) else { return }
        openTab(parsed, profileId: profileId, active: true)
    }

    func extensionRuntimeProfileContextDidInitialize(profileId: String) {
        NSLog("Browser: Chromium context of profile %@ initialized", profileId)
    }

    // MARK: - Lifecycle events

    private func dueEvents(_ id: String, profileId: String) -> [CEFExtensionLifecycle.Event] {
        guard let version = storeVersions[profileId]?[id] else { return [] }
        let record = profileStates[profileId]?.lifecycle?[id]
        return CEFExtensionLifecycle.due(record: record, ranBefore: false, version: version, session: session)
    }

    /// Records what the shim dispatched, so it is never offered again, also
    /// after a relaunch.
    private func confirmLifecycle(_ events: [CEFExtensionLifecycle.Event], extensionId id: String, profileId: String) {
        guard var state = profileStates[profileId], let version = storeVersions[profileId]?[id],
              let stateURL = stateURL(profileId) else { return }
        var lifecycle = state.lifecycle ?? [:]
        let before = lifecycle[id]
        // The token is the app's own record of what the event was decided
        // for: a delivery the app never offered confirms nothing.
        let tokens = events.map { $0.token(version: version, session: session) }
        for token in tokens {
            lifecycle[id] = CEFExtensionLifecycle.confirming(token, record: lifecycle[id], ranBefore: false, version: version, session: session)
        }
        guard lifecycle[id] != before else { return }
        state.lifecycle = lifecycle
        profileStates[profileId] = state
        do {
            try state.save(to: stateURL)
            NSLog("Browser: extension %@ in profile %@ dispatched %@", id, profileId, tokens.joined(separator: ", "))
        } catch {
            NSLog("Browser: couldn't save lifecycle state of profile %@: %@", profileId, error.localizedDescription)
        }
    }

    // MARK: - Opening

    /// An extension's own page opens in a CEF tab, where this runtime has
    /// it; anything else goes where the engine rules send it.
    private static func engine(for url: URL?) -> EngineChoice? {
        url?.scheme?.lowercased() == "chrome-extension" ? .cef : nil
    }

    /// Never activates the app: an extension acts in the background, and
    /// the user may be typing in another app.
    @discardableResult
    private func openTab(_ url: URL?, profileId: String, active: Bool) -> ExtensionHostTab? {
        guard let host, !CEFEngine.isTerminating else { return nil }
        let engine = Self.engine(for: url)
        if let window = host.extensionWindows(profileId: profileId).first {
            return window.extensionOpenTab(url: url, active: active, engine: engine)
        }
        return host.extensionOpenWindow(profileId: profileId, urls: url.map { [$0] } ?? [], focused: active, engine: engine)?
            .extensionActiveTab
    }

    private static func json(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func errorJSON(_ message: String) -> String? { json(["error": message]) }
}
