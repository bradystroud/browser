import AppKit
import Darwin

/// Structured diagnostics for how hidden tabs use memory, to choose a
/// sensible BackgroundTabPolicy default for a given amount of RAM.
///
/// Records, as an array of event objects in a local `.json` file (AGENTS.md's
/// "Debugging tricky UI bugs" shape):
/// - `session`: the machine (RAM, model, OS) and settings at launch.
/// - `sample`, every few minutes: system memory (free, compressed, swap,
///   pressure level), the app's own footprint, and every loaded tab's page
///   process footprint and how long it has been hidden.
/// - `pressure`: each system memory-pressure change.
/// - `processEnded`: a tab's page process ended, and whether it was hidden.
/// - `tabShown`: a hidden tab was shown again, how long it was hidden, and
///   whether its process ended or tab sleep unloaded it meanwhile -- the
///   reload the user notices.
/// - `tabSlept`: tab sleep (TabSleepCoordinator) unloaded a hidden tab, and
///   why: `idle`, `pressure` (a memory warning shortened the wait) or
///   `manual` (a menu command).
/// - `policy`: the Background tabs setting changed.
///
/// No URLs, titles or hosts are recorded: tabs are identified by a number
/// that is only stable for one run. "Hidden" means not the selected tab of
/// its window; a selected tab in a covered window is still counted as shown.
///
/// Off unless the marker file exists, re-checked while the app runs (same
/// switch as TabDragDiagnostics), and scoped by `--profiles-root`.
final class TabMemoryDiagnostics: TabLifecycleObserver {
    static let shared = TabMemoryDiagnostics()

    private static let markerName = "tab-memory-diagnostics.on"
    private static let logName = "tab-memory-diagnostics.json"
    /// About three weeks of samples at sampleInterval, plus events.
    private static let maxRecords = 12_000
    private static let sampleInterval: TimeInterval = 180
    private static let markerRecheckInterval: TimeInterval = 10

    private let directory: String = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
        return ProfilesRootResolver.sessionAndProfilesMetadataDirectory(
            arguments: CommandLine.arguments, appSupportDirectory: appSupport
        )
    }()
    private var markerPath: String { (directory as NSString).appendingPathComponent(Self.markerName) }
    private var logPath: String { (directory as NSString).appendingPathComponent(Self.logName) }

    private var markerExists = false
    private var markerCheckedAt: TimeInterval?
    private var records: [[String: Any]]?
    private var flushScheduled = false
    private let writeQueue = DispatchQueue(label: "dev.stroud.browser.TabMemoryDiagnostics", qos: .utility)

    private var tabNumbers: [ObjectIdentifier: Int] = [:]
    private var nextTabNumber = 1
    private var selectedTabByWindow: [ObjectIdentifier: ObjectIdentifier] = [:]
    private var hiddenSince: [ObjectIdentifier: Date] = [:]
    private var endedWhileHidden: Set<ObjectIdentifier> = []
    private var sleptWhileHidden: Set<ObjectIdentifier> = []
    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var sessionRecorded = false

    private init() {}

    func start() {
        TabLifecycleCenter.shared.addObserver(self)
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentProcessEnded(_:)),
            name: .engineTabContentProcessDidTerminate, object: nil
        )

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let event = source?.data else { return }
            let level = event.contains(.critical) ? "critical" : event.contains(.warning) ? "warning" : "normal"
            self.record("pressure", ["level": level])
        }
        source.resume()
        pressureSource = source

        let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in self?.sample() }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()
    }

    func policyChanged(to policy: BackgroundTabPolicy) {
        record("policy", ["policy": policy.rawValue])
    }

    // MARK: - Events

    func tabLifecycleEvent(_ event: TabLifecycleEvent, tab: Tab, in controller: BrowserWindowController) {
        let tabKey = ObjectIdentifier(tab)
        let windowKey = ObjectIdentifier(controller)
        switch event {
        case .becameActive:
            if let previous = selectedTabByWindow[windowKey], previous != tabKey {
                hiddenSince[previous] = Date()
            }
            selectedTabByWindow[windowKey] = tabKey
            if let since = hiddenSince.removeValue(forKey: tabKey) {
                let ended = endedWhileHidden.remove(tabKey) != nil
                let slept = sleptWhileHidden.remove(tabKey) != nil
                record("tabShown", [
                    "tab": number(for: tabKey),
                    "hiddenSeconds": Int(Date().timeIntervalSince(since)),
                    "processEndedWhileHidden": ended,
                    "sleptWhileHidden": slept,
                ])
            }
        case .closed:
            hiddenSince[tabKey] = nil
            endedWhileHidden.remove(tabKey)
            sleptWhileHidden.remove(tabKey)
            tabNumbers[tabKey] = nil
            if selectedTabByWindow[windowKey] == tabKey { selectedTabByWindow[windowKey] = nil }
        case .opened, .navigated, .finishedLoading:
            break
        }
    }

    enum SleepReason: String {
        case idle, pressure, manual
    }

    func tabSlept(_ tab: Tab, reason: SleepReason) {
        let key = ObjectIdentifier(tab)
        let since = hiddenSince[key]
        sleptWhileHidden.insert(key)
        record("tabSlept", [
            "tab": number(for: key),
            "reason": reason.rawValue,
            "hiddenSeconds": since.map { Int(Date().timeIntervalSince($0)) } ?? 0,
            "pressureLevel": Self.pressureLevel(),
        ])
    }

    @objc private func contentProcessEnded(_ notification: Notification) {
        guard let engineTab = notification.object as AnyObject?,
              let (tab, _) = allTabs().first(where: { $0.tab.browser === engineTab }) else { return }
        let key = ObjectIdentifier(tab)
        let since = hiddenSince[key]
        if since != nil { endedWhileHidden.insert(key) }
        record("processEnded", [
            "tab": number(for: key),
            "hidden": since != nil,
            "hiddenSeconds": since.map { Int(Date().timeIntervalSince($0)) } ?? 0,
            "pressureLevel": Self.pressureLevel(),
        ])
    }

    // MARK: - Samples

    private func sample() {
        guard isEnabled else { return }
        if !sessionRecorded {
            sessionRecorded = true
            record("session", [
                "physicalMemoryGB": Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
                "model": Self.sysctlString("hw.model") ?? "",
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "cpuCount": ProcessInfo.processInfo.activeProcessorCount,
                "policy": BackgroundTabPolicyPreference.current.rawValue,
                "engine": ActiveEngine.capabilities.backgroundTabPolicy ? "webkit" : "other",
            ])
        }

        var tabs: [[String: Any]] = []
        var footprintByPid: [pid_t: UInt64] = [:]
        var hiddenPids: Set<pid_t> = []
        var shownPids: Set<pid_t> = []
        for (tab, controller) in allTabs() {
            guard let engineTab = tab.browser else { continue }
            let key = ObjectIdentifier(tab)
            let hidden = controller.activeTab !== tab
            var entry: [String: Any] = ["tab": number(for: key), "hidden": hidden]
            if hidden, let since = hiddenSince[key] {
                entry["hiddenSeconds"] = Int(Date().timeIntervalSince(since))
            }
            if let pid = engineTab.contentProcessIdentifier {
                let footprint = footprintByPid[pid] ?? Self.physicalFootprint(of: pid)
                footprintByPid[pid] = footprint
                entry["mb"] = Self.megabytes(footprint)
                if hidden { hiddenPids.insert(pid) } else { shownPids.insert(pid) }
            } else {
                entry["process"] = false
            }
            tabs.append(entry)
        }

        let vm = Self.vmStatistics()
        record("sample", [
            "policy": BackgroundTabPolicyPreference.current.rawValue,
            "pressureLevel": Self.pressureLevel(),
            "freeMB": vm.freeMB,
            "compressedMB": vm.compressedMB,
            "swapUsedMB": Self.swapUsedMB(),
            "appMB": Self.megabytes(Self.physicalFootprint(of: getpid())),
            "loadedTabs": tabs.count,
            "hiddenTabs": tabs.filter { $0["hidden"] as? Bool == true }.count,
            "pageProcesses": footprintByPid.count,
            "pageProcessesMB": Self.megabytes(footprintByPid.values.reduce(0, +)),
            "hiddenOnlyProcessesMB": Self.megabytes(hiddenPids.subtracting(shownPids).reduce(0) { $0 + (footprintByPid[$1] ?? 0) }),
            "tabs": tabs,
        ])
    }

    // MARK: - Recording

    private var isEnabled: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let checkedAt = markerCheckedAt, now - checkedAt < Self.markerRecheckInterval {
            return markerExists
        }
        markerCheckedAt = now
        markerExists = FileManager.default.fileExists(atPath: markerPath)
        return markerExists
    }

    private func record(_ event: String, _ fields: [String: Any]) {
        guard isEnabled else { return }
        if records == nil {
            // Keeps earlier runs: the point is weeks of data across relaunches.
            let existing = (try? Data(contentsOf: URL(fileURLWithPath: logPath)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
            records = existing ?? []
        }
        var entry = fields
        entry["event"] = event
        entry["time"] = Self.timestamp.string(from: Date())
        records?.append(entry)
        if let count = records?.count, count > Self.maxRecords {
            records?.removeFirst(count - Self.maxRecords)
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            let snapshot = self.records ?? []
            let path = self.logPath
            self.writeQueue.async {
                guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted]) else { return }
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
    }

    private func number(for key: ObjectIdentifier) -> Int {
        if let existing = tabNumbers[key] { return existing }
        let assigned = nextTabNumber
        nextTabNumber += 1
        tabNumbers[key] = assigned
        return assigned
    }

    private func allTabs() -> [(tab: Tab, controller: BrowserWindowController)] {
        WindowManager.shared.windowControllers.flatMap { controller in
            controller.tabs.map { (tab: $0, controller: controller) }
        }
    }

    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - System readings

    private static func megabytes(_ bytes: UInt64) -> Int { Int(bytes / 1_048_576) }

    /// The figure Activity Monitor shows as Memory. Zero when the process
    /// is gone or can't be read.
    private static func physicalFootprint(of pid: pid_t) -> UInt64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : 0
    }

    /// 1 normal, 2 warning, 4 critical -- the kernel's own levels.
    private static func pressureLevel() -> Int {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 ? Int(level) : 0
    }

    private static func vmStatistics() -> (freeMB: Int, compressedMB: Int) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let page = UInt64(vm_kernel_page_size)
        return (megabytes(UInt64(stats.free_count) * page), megabytes(UInt64(stats.compressor_page_count) * page))
    }

    private static func swapUsedMB() -> Int {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 ? megabytes(usage.xsu_used) : 0
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
