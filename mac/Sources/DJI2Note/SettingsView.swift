import SwiftUI

/// 설정이 끝난 뒤의 메인 창
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = UserDefaults.standard.string(forKey: "debugTab") ?? "history"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TabView(selection: $tab) {
            HistoryTab().tabItem { Label("회의록", systemImage: "doc.text") }.tag("history")
            Form { GeneralSection(); AutomationSection(); VoiceMemosSection() }.formStyle(.grouped)
                .tabItem { Label("일반", systemImage: "gearshape") }.tag("general")
            Form { AISection() }.formStyle(.grouped)
                .tabItem { Label("AI", systemImage: "sparkles") }.tag("ai")
            Form { DriveSection(); NotionSection() }.formStyle(.grouped)
                .tabItem { Label("연동", systemImage: "link") }.tag("drive")
            DiagnosticsTab().tabItem { Label("점검", systemImage: "stethoscope") }.tag("doctor")
        }
        .padding()
        .frame(width: 680, height: 540)
        .task {
            await model.refresh()
            // 개발용: --args -debugOpenNote <회의록 폴더>
            if let folder = UserDefaults.standard.string(forKey: "debugOpenNote") {
                openWindow(id: "viewer", value: NoteRef(folder: folder, doc: .summary))
            }
        }
    }
}

struct HistoryTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DeviceCard()
            RecordCard(recorder: model.recorder)
            if model.isBusy { ActivityCard() }
            HStack {
                if !model.isBusy {  // 처리 중에는 위 작업 현황 카드가 대신 보여 줌
                    Text(model.statusText).font(.headline).lineLimit(1)
                }
                Spacer()
                Picker("", selection: $model.connectAction) {
                    ForEach(AppModel.ConnectAction.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("DJI를 연결했을 때 할 일")
                if model.pendingCount > 0 {
                    Button { model.processAll() } label: {
                        Label("모두 처리 (녹음 \(model.pendingCount)개)", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                    .help("새 녹음과 건너뛴 녹음을 전부: 먼저 Mac으로 복사한 뒤 최신 회의부터 차례로 처리")
                }
                Button { model.chooseAndProcessFiles() } label: { Label("파일 처리…", systemImage: "doc.badge.plus") }
                    .disabled(model.isBusy)
            }

            if !model.connected.isEmpty {
                GroupBox("연결된 DJI 녹음") {
                    List(Array(model.connected.reversed())) { rec in
                        HStack {
                            Text(rec.start.prefix(16).replacingOccurrences(of: "T", with: " "))
                                .monospacedDigit()
                            Text(rec.name).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            StatusBadge(status: rec.status)
                            if rec.status != "done" {
                                Button("처리") { model.processNames([rec.name]) }
                                    .disabled(model.isBusy)
                            }
                        }
                    }
                    .frame(minHeight: 90, maxHeight: 150)
                }
            }

            GroupBox("처리한 회의록") {
                if model.history.isEmpty {
                    Text("아직 없습니다. DJI를 연결하거나 파일을 처리해 보세요.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    List(model.history) { HistoryRow(item: $0) }
                }
            }
            HStack {
                Button("회의록 폴더 열기") { model.openNotesFolder() }
                Spacer()
                Button("새로고침") { Task { await model.refresh() } }
            }
        }
    }
}

struct StatusBadge: View {
    let status: String
    var body: some View {
        let (text, color): (String, Color) = switch status {
        case "done": ("완료", .green)
        case "seen": ("건너뜀", .secondary)
        case "no_speech": ("대화 없음", .secondary)
        default: ("새 녹음", .blue)
        }
        Text(text).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }
}

struct DiagnosticsTab: View {
    @EnvironmentObject var model: AppModel
    @State private var checking = false
    @State private var reinstalling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(checking ? "점검 중…" : "지금 점검") {
                    checking = true
                    Task { await model.runDoctor(); checking = false }
                }
                .disabled(checking)
                Button(reinstalling ? "업데이트 중…" : "엔진 업데이트") {
                    reinstalling = true
                    Task { _ = await model.installEngine(withModel: false); reinstalling = false }
                }
                .disabled(reinstalling || model.isBusy)
                Spacer()
                Button("로그 파일 열기") { NSWorkspace.shared.open(Paths.log) }
            }
            if let report = model.report {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(report.checks) { c in
                            HStack(alignment: .top) {
                                Image(systemName: c.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(c.ok ? .green : .red)
                                VStack(alignment: .leading) {
                                    Text(c.label)
                                    if !c.hint.isEmpty { Text(c.hint).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("실행 로그").font(.caption).foregroundStyle(.secondary)
            LogView().clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("설정 마법사 다시 실행") { model.setupDone = false }
            }
        }
    }
}
