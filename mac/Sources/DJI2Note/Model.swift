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
    @Published var autoProcess = UserDefaults.standard.object(forKey: "autoProcess") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoProcess, forKey: "autoProcess") }
    }

    private var mountObserver: NSObjectProtocol?

    init() {
        startMountWatcher()
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
        statusText = "\(title) 시작"
        Task {
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
    private func handle(_ line: String) {
        if let m = line.firstMatch(of: /(\d{1,3})%\|/), let pct = Double(m.1) {
            progress = pct / 100
            statusText = pct >= 100 ? "AI가 화자 분리·요약하는 중…" : "받아쓰는 중… \(Int(pct))%"
            return
        }
        appendLog(line)
        if let r = line.range(of: "처리 시작: ") {
            statusText = "받아쓰는 중: " + line[r.upperBound...].split(separator: " ").first.map(String.init)!
            progress = 0
        } else if line.contains("저장: ") {
            statusText = config.upload == "rclone" ? "Google Drive에 올리는 중…" : "저장 완료"
            progress = nil
        } else if line.contains("업로드: ") {
            statusText = "완료 — Google Drive에 올렸습니다"
        } else if line.contains("대화 없음") {
            statusText = "대화가 없는 녹음이라 건너뜀"
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
        Task {
            await refresh()
            if autoProcess && setupDone {
                // 마운트 직후 파일시스템이 안정될 때까지 잠깐 대기
                try? await Task.sleep(for: .seconds(2))
                processConnected()
            }
        }
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
