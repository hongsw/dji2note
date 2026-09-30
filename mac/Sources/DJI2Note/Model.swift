import AppKit
import Foundation
import ServiceManagement
import UserNotifications

struct EngineConfig: Codable, Equatable {
    var output_dir = "~/dji2note"
    var language = "ko"
    var whisper_model = "mlx-community/whisper-large-v3-turbo"
    var llm_backend = "none"
    var llm_model = "claude-sonnet-5"
    var anthropic_api_key = ""
    var upload = "none"
    var rclone_remote = "gdrive"
    var drive_folder = "dji2note"
    var notify = true
    var notes_dir: String?
}

struct Check: Codable, Identifiable {
    let key: String
    let ok: Bool
    let label: String
    let hint: String
    var id: String { key }
}

struct DoctorReport: Codable {
    let checks: [Check]
    let service: String
    let log: String
}

struct HistoryEntry: Codable {
    let status: String
    let notes: String?
    let drive: String?
    let drive_url: String?
    let at: String?
}

struct HistoryItem: Identifiable {
    let name: String
    let entry: HistoryEntry
    var id: String { name }
}

struct DJIRecording: Codable, Identifiable {
    let name: String
    let path: String
    let start: String
    let status: String
    var id: String { name }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var engineInstalled = Engine.isInstalled
    @Published var config = EngineConfig()
    @Published var report: DoctorReport?
    @Published var history: [HistoryItem] = []
    @Published var connected: [DJIRecording] = []
    @Published var driveRemotes: [String] = []

    @Published var isBusy = false
    @Published var statusText = "대기 중"
    @Published var progress: Double?
    @Published var logLines: [String] = []

    @Published var setupDone = UserDefaults.standard.bool(forKey: "setupDone") {
        didSet { UserDefaults.standard.set(setupDone, forKey: "setupDone") }
    }
    /// DJI를 연결했을 때 할 일
    enum ConnectAction: String, CaseIterable, Identifiable {
        case showAndProcess, showOnly, silentProcess
        var id: String { rawValue }
        var title: String {
            switch self {
            case .showAndProcess: "창 띄우고 바로 자동 처리"
            case .showOnly: "창만 띄우기 (처리는 직접)"
            case .silentProcess: "창 없이 바로 자동 처리 (끝나면 알림)"
            }
        }
        var short: String {
            switch self {
            case .showAndProcess: "연결 시 자동 처리"
            case .showOnly: "연결 시 창만"
            case .silentProcess: "연결 시 조용히 처리"
            }
        }
    }

    @Published var connectAction: ConnectAction = {
        if let raw = UserDefaults.standard.string(forKey: "connectAction"), let a = ConnectAction(rawValue: raw) { return a }
        // 이전 버전의 "자동 처리" 스위치를 이어받음
        return (UserDefaults.standard.object(forKey: "autoProcess") as? Bool ?? true) ? .showAndProcess : .showOnly
    }() {
        didSet { UserDefaults.standard.set(connectAction.rawValue, forKey: "connectAction") }
    }

    private var mountObserver: NSObjectProtocol?

    static let shared = AppModel()

    init() {
        startMountWatcher()
        registerMountAgent()
        Task { await refresh() }
    }

    // MARK: 상태 새로고침

    func refresh() async {
        engineInstalled = Engine.isInstalled
        guard engineInstalled else { return }
        if let c = await Engine.json(["config", "show", "--json"], as: EngineConfig.self) { config = c }
        await refreshHistory()
        driveRemotes = await Engine.json(["drive", "remotes"], as: [String].self) ?? []
        connected = await Engine.json(["scan", "--json"], as: [DJIRecording].self) ?? []
    }

    func refreshHistory() async {
        let dict = await Engine.json(["list", "--json"], as: [String: HistoryEntry].self) ?? [:]
        history = dict.map { HistoryItem(name: $0.key, entry: $0.value) }
            .filter { $0.entry.status == "done" }
            .sorted { ($0.entry.at ?? "") > ($1.entry.at ?? "") }
    }

    func runDoctor() async {
        report = await Engine.json(["doctor", "--json"], as: DoctorReport.self)
    }

    func set(_ pairs: [String: String]) async {
        let args = ["config", "set"] + pairs.map { "\($0.key)=\($0.value)" }
        await Engine.cli(args)
        if let c = await Engine.json(["config", "show", "--json"], as: EngineConfig.self) { config = c }
    }

    // MARK: 설치

    func installEngine(withModel: Bool) async -> Bool {
        isBusy = true
        statusText = "엔진 설치 중"
        let ok = await Engine.install(withModel: withModel) { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }
        isBusy = false
        statusText = ok ? "대기 중" : "설치 실패"
        await refresh()
        return ok
    }

    func connectDrive(name: String = "gdrive") async -> Bool {
        appendLog("브라우저에서 Google 계정으로 로그인하고 '허용'을 눌러 주세요…")
        let r = await Engine.cli(["drive", "connect", name]) { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }
        await refresh()
        return r.ok
    }

    // MARK: 처리

    /// 연결된 DJI에서 아직 처리 안 한 녹음(새 녹음 + 건너뛴 녹음)
    var pendingCount: Int { connected.filter { $0.status == "new" || $0.status == "seen" }.count }

    /// 건너뛴 것까지 전부 한 번에: 먼저 모두 복사 → 최신 회의부터 차례로 처리
    func processAll() {
        runPipeline(["run", "--all"], title: "모두 처리")
    }

    func processNames(_ names: [String]) {
        runPipeline(["run", "--names"] + names, title: "선택한 녹음 처리")
    }

    func processConnected() {
        runPipeline(["run"], title: "DJI 녹음 처리")
    }

    func processFiles(_ urls: [URL], join: Bool) {
        runPipeline(["process"] + (join ? ["--join"] : []) + urls.map(\.path), title: "파일 처리")
    }

    func chooseAndProcessFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .movie]
        panel.message = "처리할 녹음 파일을 고르세요. 여러 개를 고르면 각각 따로 처리합니다."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, !panel.urls.isEmpty { processFiles(panel.urls, join: false) }
    }

    func skipAllNew() async {
        await Engine.cli(["skip", "--all-new"])
        await refresh()
    }

    private func runPipeline(_ args: [String], title: String) {
        guard !isBusy, engineInstalled else { return }
        isBusy = true
        progress = nil
        position = ""
        statusText = "\(title) 시작"
        // 몇 시간짜리 일괄 처리 중에 Mac이 잠들지 않도록
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "DJI2Note 회의록 처리")
        Task {
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let r = await Engine.cli(args) { [weak self] line in
                Task { @MainActor in self?.handle(line) }
            }
            isBusy = false
            progress = nil
            if !r.ok { statusText = "실패 — 로그를 확인하세요" }
            else if statusText.hasSuffix("시작") { statusText = "새 녹음 없음" }
            await refresh()
        }
    }

    /// 파이썬 로그 한 줄을 사람이 읽을 상태로 바꾼다.
    /// 일괄 처리 중 현재 위치 "(2/5)"
    private var position = ""

    private func handle(_ line: String) {
        if let m = line.firstMatch(of: /(\d{1,3})%\|/), let pct = Double(m.1) {
            progress = pct / 100
            statusText = pct >= 100 ? "AI가 화자 분리·요약하는 중\(position)…" : "받아쓰는 중\(position) \(Int(pct))%"
            return
        }
        appendLog(line)
        if let m = line.firstMatch(of: /복사 \[(\d+)\/(\d+)\]/) {
            statusText = "DJI에서 복사 중 (\(m.1)/\(m.2))"
            progress = (Double(m.1) ?? 0) / max(Double(m.2) ?? 1, 1)
        } else if line.contains("복사 완료") {
            statusText = "복사 완료 — DJI를 분리해도 됩니다"
            progress = nil
        } else if let r = line.range(of: "처리 시작") {
            let rest = line[r.upperBound...]
            if let m = rest.firstMatch(of: /\[(\d+)\/(\d+)\]/) { position = " (\(m.1)/\(m.2))" } else { position = "" }
            let name = rest.split(separator: ":").dropFirst().first?.trimmingCharacters(in: .whitespaces)
                .split(separator: " ").first.map(String.init) ?? ""
            statusText = "받아쓰는 중\(position): \(name)"
            progress = 0
        } else if line.contains("저장: ") {
            statusText = (config.upload == "rclone" ? "Google Drive에 올리는 중" : "저장 완료") + position
            progress = nil
        } else if line.contains("업로드: ") {
            statusText = "올리기 완료\(position)"
        } else if line.contains("대화 없음") {
            statusText = "대화가 없는 녹음이라 건너뜀\(position)"
        } else if line.contains("전체 완료") {
            statusText = line.components(separatedBy: "전체 완료").last.map { "모두 끝났습니다" + $0 } ?? "모두 끝났습니다"
        } else if line.contains("실패") {
            statusText = "일부 실패 — 로그를 확인하세요"
        }
    }

    func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 800 { logLines.removeFirst(logLines.count - 800) }
    }

    // MARK: DJI 연결 감지

    private func startMountWatcher() {
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            Task { @MainActor in self?.volumeMounted(url) }
        }
    }

    private func volumeMounted(_ url: URL?) {
        guard let url, Self.looksLikeDJI(url) else { return }
        djiConnected(url)
    }

    /// launchd 에이전트가 `dji2note://mounted`로 앱을 깨웠을 때: DJI면 처리, 아니면(방금 켜진 경우) 조용히 종료
    func checkMountedVolumes(launchedJustNow: Bool) {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                            options: [.skipHiddenVolumes]) ?? []
        if let dji = volumes.first(where: { $0.path.hasPrefix("/Volumes/") && Self.looksLikeDJI($0) }) {
            djiConnected(dji)
        } else if launchedJustNow {
            NSApp.terminate(nil)
        }
    }

    private var lastHandled: [String: Date] = [:]

    /// DJI 연결 → 창을 띄워 상태를 보여 주고, 새 녹음이 있으면 자동 처리
    private func djiConnected(_ volume: URL) {
        // 앱 내부 감지와 launchd 에이전트가 같은 연결을 두 번 알릴 수 있어 1분 안의 중복은 무시
        if let t = lastHandled[volume.path], Date().timeIntervalSince(t) < 60 { return }
        lastHandled[volume.path] = Date()
        statusText = "DJI 연결됨 — 녹음 확인 중…"
        if connectAction != .silentProcess { showMainWindow() }
        Task {
            await refresh()
            let newCount = connected.filter { $0.status == "new" }.count
            if setupDone && connectAction != .showOnly && newCount > 0 && !isBusy {
                // 마운트 직후 파일시스템이 안정될 때까지 잠깐 대기
                try? await Task.sleep(for: .seconds(2))
                processConnected()
            } else if !isBusy {
                statusText = newCount == 0 ? "DJI 연결됨 — 새 녹음 없음 (모두 처리됨)"
                                           : "DJI 연결됨 — 새 녹음 \(newCount)개"
            }
        }
    }

    /// 메인 창 열기 (Window 장면이 `dji2note://show`를 받아 열린다)
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSWorkspace.shared.open(URL(string: "dji2note://show")!)
        // 창이 연결이 끊긴 모니터 등 화면 밖에 있으면 주 화면 가운데로
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) else { return }
            let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(win.frame) }
            if !visible { win.center() }
            win.makeKeyAndOrderFront(nil)
        }
    }

    /// 볼륨 마운트 때 앱을 깨우는 백그라운드 항목(앱이 꺼져 있어도 DJI 연결 시 실행되게)
    func registerMountAgent() {
        let agent = SMAppService.agent(plistName: "io.dji2note.mount.plist")
        guard agent.status != .enabled else { return }
        do { try agent.register() } catch { appendLog("마운트 감지 항목 등록 실패: \(error.localizedDescription)") }
    }

    nonisolated static func looksLikeDJI(_ volume: URL) -> Bool {
        let fm = FileManager.default
        let pattern = /^(TX|RX)\d*_MIC\d+_\d{8}_\d{6}.*\.wav$/.ignoresCase()
        let top = (try? fm.contentsOfDirectory(at: volume, includingPropertiesForKeys: nil)) ?? []
        for item in top {
            if item.lastPathComponent.firstMatch(of: pattern) != nil { return true }
            if let sub = try? fm.contentsOfDirectory(atPath: item.path),
               sub.contains(where: { $0.firstMatch(of: pattern) != nil }) { return true }
        }
        return false
    }

    // MARK: 로그인 시 실행

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                appendLog("로그인 항목 설정 실패: \(error.localizedDescription)")
            }
            objectWillChange.send()
        }
    }

    // MARK: 보조 동작

    func openClaudeLogin() {
        // 터미널을 열어 Claude Code 설치(없을 때) 후 로그인 화면을 띄운다
        let script = """
        #!/bin/bash
        export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
        if ! command -v claude >/dev/null 2>&1; then
          echo "Claude Code를 설치합니다…"
          curl -fsSL https://claude.ai/install.sh | bash
        fi
        echo
        echo "Claude 로그인 — 브라우저가 열리면 로그인하세요."
        claude auth login
        echo
        echo "✅ 끝났습니다. 이 창을 닫고 DJI2Note로 돌아가세요."
        """
        let url = FileManager.default.temporaryDirectory.appending(path: "dji2note-claude-login.command")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    func openNotesFolder() {
        let path = (config.notes_dir ?? config.output_dir as String).replacingOccurrences(of: "~", with: Paths.home.path)
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(filePath: path))
    }
}
