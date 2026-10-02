import AppKit
import SwiftUI

@main
struct DJI2NoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("DJI2Note", id: "main") {
            Group {
                if model.setupDone {
                    SettingsView()
                } else {
                    OnboardingView()
                }
            }
            .environmentObject(model)
            .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: ["show"])

        WindowGroup("회의록", id: "viewer", for: NoteRef.self) { $ref in
            if let ref { NoteViewer(ref: ref) }
        }
        .defaultSize(width: 760, height: 720)
        .handlesExternalEvents(matching: [])

        MenuBarExtra {
            MenuPanel()
                .environmentObject(model)
        } label: {
            // 처리 중이면 메뉴바에 진행률(%)도 표시
            if model.isBusy, let p = model.progress, !model.recorder.isRecording {
                Text("\(Image(systemName: "waveform.circle.fill")) \(Int(p * 100))%")
            } else {
                Image(systemName: model.recorder.isRecording ? "record.circle.fill"
                                  : (model.isBusy ? "waveform.circle.fill" : "waveform.circle"))
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let launchedAt = Date()
    private var openedByUser = false
    private var loginLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchSupport.decorateBaryonFolder()
        // 창이 열리고 닫힐 때 Dock 아이콘 표시 전환
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { LaunchSupport.updateDockIcon() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if self.openedByUser {
                // 응용 프로그램·Launchpad·Spotlight에서 직접 열면 창을 바로 보여 줌
                NSWorkspace.shared.open(URL(string: "dji2note://show")!)
            } else if self.loginLaunch {
                // 로그인 시 자동 실행은 메뉴바에만 조용히
                NSApp.windows.filter { $0.styleMask.contains(.titled) }.forEach { $0.close() }
            }
            LaunchSupport.updateDockIcon()
        }
    }

    /// 이미 실행 중일 때 아이콘을 다시 누르면 창을 연다
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSWorkspace.shared.open(URL(string: "dji2note://show")!)
        return false
    }

    /// dji2note://mounted — 볼륨 마운트 때 launchd 에이전트가 보냄
    func application(_ application: NSApplication, open urls: [URL]) {
        NSLog("DJI2Note openURLs: %@", urls.map(\.absoluteString).joined(separator: ","))
        // 단축어·자동화용: dji2note://record-start?mode=meeting|inPerson, dji2note://record-stop
        if let url = urls.first(where: { $0.host == "record-start" }) {
            let mode = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "mode" }?.value
            Task { @MainActor in
                let m = AppModel.shared
                if let mode, let r = Recorder.Mode(rawValue: mode) { m.recorder.mode = r }
                await m.recorder.start(in: m.recordingsDir)
            }
            return
        }
        if urls.contains(where: { $0.host == "record-stop" }) {
            Task { @MainActor in await AppModel.shared.recorder.stop() }
            return
        }
        if urls.contains(where: { $0.host == "process-all" }) {
            Task { @MainActor in AppModel.shared.processAll() }  // 자동화·스크립트용
            return
        }
        guard urls.contains(where: { $0.host == "mounted" }) else { return }
        let justNow = Date().timeIntervalSince(launchedAt) < 10
        Task { @MainActor in AppModel.shared.checkMountedVolumes(launchedJustNow: justNow) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillFinishLaunching(_ notification: Notification) {
        openedByUser = LaunchSupport.launchedByUser()
        loginLaunch = LaunchSupport.launchedAsLoginItem()
        // 화면 없이 엔진만 설치: DJI2Note.app/Contents/MacOS/DJI2Note --install-engine [--with-model]
        let args = CommandLine.arguments
        guard args.contains("--install-engine") else { return }
        Task {
            let ok = await Engine.install(withModel: args.contains("--with-model")) { print($0); fflush(stdout) }
            exit(ok ? 0 : 1)
        }
    }
}

/// 메뉴바 아이콘을 누르면 나오는 패널
struct MenuPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform.circle.fill").font(.title2).foregroundStyle(.tint)
                Text("DJI2Note").font(.headline)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
            }

            DeviceCard(compact: true)
            if model.setupDone { RecordCard(recorder: model.recorder, compact: true) }

            if model.isBusy {
                ActivityCard(compact: true)
            } else {
                Text(model.statusText).font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }

            if !model.setupDone {
                Button("설정 시작하기…") { show() }
                    .buttonStyle(.borderedProminent)
            } else {
                Picker(selection: $model.connectAction) {
                    ForEach(AppModel.ConnectAction.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("DJI 연결 시", systemImage: "cable.connector")
                }
                .font(.callout)
                let newCount = model.connected.filter { $0.status == "new" }.count
                if newCount > 0 {
                    Label("연결된 DJI에 새 녹음 \(newCount)개", systemImage: "mic.badge.plus")
                        .font(.callout)
                }
                if model.pendingCount > 0 {
                    Button {
                        model.processAll()
                    } label: {
                        Label("남은 녹음 \(model.pendingCount)개 모두 처리", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                }
                HStack {
                    Button {
                        model.processConnected()
                    } label: { Label("새 녹음 처리", systemImage: "arrow.clockwise") }
                    Button {
                        model.chooseAndProcessFiles()
                    } label: { Label("파일 처리…", systemImage: "doc.badge.plus") }
                }
                .disabled(model.isBusy)

                if !model.history.isEmpty {
                    Divider()
                    Text("최근 회의록").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.history.prefix(5)) { item in
                        HistoryRow(item: item, compact: true)
                    }
                }
            }

            Divider()
            HStack {
                Button("설정…") { show() }
                Button("회의록 폴더") { model.openNotesFolder() }
                Spacer()
                Button("종료") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 340)
        .task { await model.refresh() }
    }

    private func show() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
