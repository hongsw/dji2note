import AppKit
import SwiftUI

@main
struct DJI2NoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

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

        MenuBarExtra {
            MenuPanel()
                .environmentObject(model)
        } label: {
            Image(systemName: model.isBusy ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillFinishLaunching(_ notification: Notification) {
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

            VStack(alignment: .leading, spacing: 6) {
                Text(model.statusText).font(.callout)
                if let p = model.progress {
                    ProgressView(value: p)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            if !model.setupDone {
                Button("설정 시작하기…") { show() }
                    .buttonStyle(.borderedProminent)
            } else {
                let newCount = model.connected.filter { $0.status == "new" }.count
                if newCount > 0 {
                    Label("연결된 DJI에 새 녹음 \(newCount)개", systemImage: "mic.badge.plus")
                        .font(.callout)
                }
                HStack {
                    Button {
                        model.processConnected()
                    } label: { Label("지금 처리", systemImage: "play.fill") }
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

/// 처리 기록 한 줄: 폴더명 + [폴더] [Drive] 버튼
struct HistoryRow: View {
    let item: HistoryItem
    var compact = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(compact ? .callout : .body).lineLimit(1)
                if !compact, let at = item.entry.at {
                    Text("처리: " + at.replacingOccurrences(of: "T", with: " ").prefix(16)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let notes = item.entry.notes {
                Button { NSWorkspace.shared.open(URL(filePath: notes)) } label: { Image(systemName: "folder") }
                    .help("Mac의 회의록 폴더 열기")
            }
            if let url = item.entry.drive_url, let u = URL(string: url), !url.isEmpty {
                Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "globe") }
                    .help("Google Drive에서 열기")
            }
        }
        .buttonStyle(.borderless)
    }

    private var title: String {
        if let notes = item.entry.notes { return URL(filePath: notes).lastPathComponent }
        return item.name
    }
}
