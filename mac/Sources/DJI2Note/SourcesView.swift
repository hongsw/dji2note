import AVFoundation
import SwiftUI

/// 회의록의 출처 (회의록 목록 아이콘·가져오기 탭 건수에 사용)
enum NoteSource: String, CaseIterable {
    case dji, app, zoom, memo, file
    var title: String { ["DJI 무선 마이크", "앱에서 녹음", "Zoom", "음성 메모", "파일"][index] }
    var icon: String { ["mic.fill", "record.circle", "video.fill", "waveform", "doc"][index] }
    private var index: Int { Self.allCases.firstIndex(of: self)! }

    /// meta.json 의 원본 파일 이름(없으면 폴더 이름)으로 출처 판별
    static func of(files: [String], folder: String) -> NoteSource {
        let name = files.first ?? folder
        if name.range(of: #"^(TX|RX)\d*_MIC"#, options: .regularExpression) != nil || folder.contains("_MIC") { return .dji }
        if name.hasPrefix("REC_") || name.hasPrefix("MEET_") || folder.hasSuffix("_녹음") || folder.hasSuffix("_온라인회의") { return .app }
        if name.hasPrefix("ZOOM_") || folder.hasSuffix("_Zoom") { return .zoom }
        if [".m4a", ".qta"].contains(where: name.lowercased().hasSuffix) { return .memo }
        return .file
    }
}

/// 상태 배지: 켜짐 / 연결됨 / 권한 필요 / 꺼짐
struct SourceBadge: View {
    enum Kind { case on, connected, needsPermission, off, info(String) }
    let kind: Kind

    var body: some View {
        let (text, color): (String, Color) = switch kind {
        case .on: ("켜짐", .green)
        case .connected: ("연결됨", .green)
        case .needsPermission: ("권한 필요", .orange)
        case .off: ("꺼짐", .secondary)
        case .info(let t): (t, .blue)
        }
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
        .foregroundStyle(color == .secondary ? Color.secondary : color)
    }
}

/// 출처 카드 한 장: 아이콘·이름·설명·배지·스위치 + 펼치는 세부 설정
struct SourceCard<Detail: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let badge: SourceBadge.Kind
    var count: Int = 0
    var isOn: Binding<Bool>?
    @ViewBuilder var detail: () -> Detail
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.headline)
                        SourceBadge(kind: badge)
                        if count > 0 {
                            Text("회의록 \(count)건").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let isOn { Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch) }
                Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                    Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .buttonStyle(.borderless)
                .help(expanded ? "접기" : "자세히")
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) { detail() }
                    .padding(.leading, 48)
                    .font(.callout)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
    }
}

/// "가져오기" 탭: 녹음이 들어오는 길을 한곳에서 켜고 끄고 상태를 본다
struct SourcesTab: View {
    @EnvironmentObject var model: AppModel
    @State private var downloadsAccess: Bool?
    @State private var showAdvanced = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("녹음이 들어오는 길").font(.title3.bold())
                Text("켜 둔 곳에 새 녹음이 생기면 받아쓰기 → 화자 분리 → 요약 → 연동까지 자동으로 진행합니다.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                djiCard
                appRecordCard
                zoomLocalCard
                zoomDownloadsCard
                memosCard

                DisclosureGroup(isExpanded: $showAdvanced) {
                    Form { ZoomCloudSection() }.formStyle(.grouped).frame(minHeight: 420)
                } label: {
                    Label("고급 — Zoom 클라우드 API 연동 (계정 관리자 필요)", systemImage: "gearshape.2")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
        .task {
            if model.zoomEnabled { await model.checkZoom() }
            if model.zoomDownloadsEnabled { checkDownloads() }
            model.checkMemosAccess()
        }
    }

    private func count(_ s: NoteSource) -> Int {
        model.history.filter { NoteSource.of(files: $0.meta?.files ?? [], folder: $0.name) == s }.count
    }

    // MARK: 카드들

    private var djiCard: some View {
        SourceCard(icon: "mic.fill", title: "DJI 무선 마이크",
                   subtitle: "송신기를 USB로 연결하면 녹음을 Mac에 복사해 정리합니다. 앱이 꺼져 있어도 연결하면 실행됩니다.",
                   badge: model.device != nil ? .connected : .on, count: count(.dji)) {
            Picker("연결하면", selection: $model.connectAction) {
                ForEach(AppModel.ConnectAction.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            Picker("녹음 상황", selection: Binding(
                get: { model.config.default_situation ?? "auto" },
                set: { v in Task { await model.set(["default_situation": v]) } })) {
                ForEach(model.situations) { s in Label(s.title, systemImage: s.icon).tag(s.key) }
            }
            .fixedSize()
        }
    }

    private var appRecordCard: some View {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        return SourceCard(icon: "record.circle", title: "앱에서 녹음",
                          subtitle: "회의록 탭의 '녹음 시작'으로 대면·온라인 회의·강의 등을 바로 녹음합니다. 온라인 회의는 내 마이크와 Mac 소리를 나눠 '나/상대방'을 정확히 구분합니다.",
                          badge: mic == .denied ? .needsPermission : (mic == .authorized ? .on : .info("처음 녹음 때 허용")),
                          count: count(.app)) {
            if mic == .denied {
                permissionRow("마이크 권한이 꺼져 있습니다", pane: "Privacy_Microphone")
            }
            Text("녹음 중에는 Mac이 잠들지 않고, 정지하면 자동으로 정리합니다. 단축어: dji2note://record-start?mode=meeting")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var zoomLocalCard: some View {
        let s = model.zoomStatus
        let badge: SourceBadge.Kind = !model.zoomEnabled ? .off : (s?.error == "permission" ? .needsPermission : .on)
        return SourceCard(icon: "video.fill", title: "Zoom 로컬 녹화",
                          subtitle: "Zoom에서 '이 컴퓨터에 녹화'한 회의가 끝나고 변환되면 자동으로 가져옵니다.",
                          badge: badge, count: count(.zoom),
                          isOn: Binding(get: { model.zoomEnabled },
                                        set: { v in if v { Task { await model.enableZoom() } } else { model.zoomEnabled = false } })) {
            HStack {
                Text("녹화 폴더").foregroundStyle(.secondary)
                Text(model.zoomDir.path.replacingOccurrences(of: Paths.home.path, with: "~")).lineLimit(1).truncationMode(.middle)
                Button("변경…") { pickZoomDir() }
            }
            if let s {
                if s.ok {
                    Text("녹화 \(s.count ?? 0)개" + ((s.per_person ?? 0) > 0 ? " · 참가자별 오디오 \(s.per_person ?? 0)개" : ""))
                        .foregroundStyle(.secondary)
                } else if s.error == "permission" {
                    permissionRow("문서 폴더를 읽을 권한이 필요합니다", pane: "Privacy_FilesAndFolders")
                } else {
                    Label("녹화 폴더가 없습니다 — Zoom 설정의 로컬 녹화 위치를 확인하세요", systemImage: "folder.badge.questionmark")
                        .foregroundStyle(.orange)
                }
            }
            Text("Zoom 설정 → 녹화 → '참가자별로 별도의 오디오 파일 녹음'을 켜면 화자가 실제 참가자 이름으로 나옵니다. 회의 중 채팅도 반영됩니다.")
                .font(.caption).foregroundStyle(.secondary)
            if model.zoomEnabled {
                Button("건너뛴 기존 녹화도 모두 정리") { model.processAllZoom() }.disabled(model.isBusy)
            }
        }
    }

    private var zoomDownloadsCard: some View {
        let badge: SourceBadge.Kind = !model.zoomDownloadsEnabled ? .off : (downloadsAccess == false ? .needsPermission : .on)
        return SourceCard(icon: "icloud.and.arrow.down", title: "Zoom 클라우드 녹화 (내려받기)",
                          subtitle: "웹 '내 녹화'에서 클라우드 녹화를 다운로드하면 다운로드 폴더에서 찾아 정리합니다. 학교·회사 계정처럼 관리자 권한이 없을 때 쓰는 방법입니다.",
                          badge: badge,
                          isOn: Binding(get: { model.zoomDownloadsEnabled },
                                        set: { v in
                                            if v { Task { await model.enableZoomDownloads(); checkDownloads() } }
                                            else { model.zoomDownloadsEnabled = false }
                                        })) {
            if downloadsAccess == false {
                permissionRow("다운로드 폴더를 읽을 권한이 필요합니다", pane: "Privacy_FilesAndFolders")
            }
            Text("GMT20261003-053000_Recording.m4a 같은 Zoom 다운로드 파일을 회의별로 묶고, 채팅 파일도 함께 반영합니다. 켤 때 이미 있던 파일은 건너뜁니다.")
                .font(.caption).foregroundStyle(.secondary)
            Button("다운로드 폴더의 기존 Zoom 녹화도 모두 정리") { model.processAllZoomDownloads() }
                .disabled(model.isBusy)
        }
    }

    private var memosCard: some View {
        let badge: SourceBadge.Kind = !model.memosEnabled ? .off : (model.memosAccess == false ? .needsPermission : .on)
        return SourceCard(icon: "waveform", title: "Mac 음성 메모",
                          subtitle: "음성 메모 앱에 새 녹음이 생기면 정리합니다. iPhone 음성 메모도 iCloud로 동기화되면 함께 처리됩니다.",
                          badge: badge, count: count(.memo),
                          isOn: Binding(get: { model.memosEnabled },
                                        set: { v in if v { Task { await model.enableMemos() } } else { model.memosEnabled = false } })) {
            if model.memosAccess == false {
                permissionRow("음성 메모 폴더를 읽으려면 '전체 디스크 접근'이 필요합니다", pane: "Privacy_AllFiles")
            } else if model.memosAccess == true {
                Text("음성 메모 \(model.memosCount)개 보임").foregroundStyle(.secondary)
            }
            if model.memosEnabled {
                Button("건너뛴 기존 메모도 모두 정리") { model.processAllMemos() }.disabled(model.isBusy)
            }
        }
    }

    // MARK: 보조

    private func permissionRow(_ text: String, pane: String) -> some View {
        HStack {
            Label(text, systemImage: "lock.fill").foregroundStyle(.orange)
            Spacer()
            Button("허용하기") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
            }
            .buttonStyle(.borderedProminent).tint(.orange).controlSize(.small)
        }
    }

    private func checkDownloads() {
        let dir = Paths.home.appending(path: "Downloads")
        downloadsAccess = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) != nil
    }

    private func pickZoomDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = model.zoomDir
        panel.message = "Zoom 로컬 녹화가 저장되는 폴더를 고르세요"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.setZoomDir(url) }
        }
    }
}
