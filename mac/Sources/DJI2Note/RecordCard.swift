import SwiftUI

/// 앱에서 바로 녹음 — 대면 / 온라인 회의
struct RecordCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var recorder: Recorder
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if recorder.isRecording { recording } else { idle }
            if let e = recorder.error {
                Text(e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(compact ? 10 : 14)
        .background(RoundedRectangle(cornerRadius: 10).fill((recorder.isRecording ? Color.red : Color.secondary).opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke((recorder.isRecording ? Color.red : Color.secondary).opacity(0.3)))
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: Binding(
                    get: { recorder.situation },
                    set: { key in
                        recorder.situation = key
                        // 온라인 회의·통화는 Mac 소리(상대방)도 함께
                        let capture = model.situations.first { $0.key == key }?.capture ?? "mic"
                        recorder.mode = capture == "mic+system" ? .meeting : .inPerson
                    })) {
                    ForEach(model.situations) { s in Label(s.title, systemImage: s.icon).tag(s.key) }
                }
                .labelsHidden().fixedSize()
                .help("녹음 상황 — 요약 형식과 화자 이름이 상황에 맞게 바뀝니다")
                Toggle("Mac 소리도", isOn: Binding(
                    get: { recorder.mode == .meeting },
                    set: { recorder.mode = $0 ? .meeting : .inPerson }))
                    .toggleStyle(.checkbox)
                    .help("온라인 회의·통화 상대방 목소리(Mac에서 나는 소리)를 따로 녹음해 '나/상대방'으로 정확히 나눕니다")
                Spacer()
                Button {
                    Task { await recorder.start(in: model.recordingsDir) }
                } label: {
                    Label("녹음 시작", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent).tint(.red)
            }
            HStack {
                Text(recorder.mode == .meeting ? "내 마이크" : "마이크").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $recorder.deviceID) {
                    ForEach(recorder.devices) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .controlSize(.small)
            }
            if !compact {
                Text(recorder.mode.hint).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 10, height: 10)
                    .opacity(pulse ? 1 : 0.3)
                Text("\(model.situationTitle(recorder.situation).isEmpty ? recorder.mode.title : model.situationTitle(recorder.situation)) 녹음 중")
                    .font(.callout.weight(.semibold))
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(elapsed).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await recorder.stop() }
                } label: {
                    Label("정지하고 정리", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent).tint(.red)
            }
            meter(recorder.mode == .meeting ? "나" : recorder.deviceName, recorder.micLevel)
            if recorder.mode == .meeting {
                meter("상대방(Mac 소리)", recorder.systemLevel)
            }
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { pulse = true } }
    }

    @State private var pulse = false

    private func meter(_ label: String, _ level: Float) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: compact ? 70 : 110, alignment: .leading).lineLimit(1)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(level > 0.85 ? Color.orange : Color.green)
                        .frame(width: g.size.width * CGFloat(level))
                        .animation(.linear(duration: 0.1), value: level)
                }
            }
            .frame(height: 6)
        }
    }

    private var elapsed: String {
        guard let s = recorder.startedAt else { return "00:00" }
        let t = Int(Date().timeIntervalSince(s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%02d:%02d", t / 60, t % 60)
    }
}

/// 일반 설정: Mac 음성 메모 자동 처리
struct VoiceMemosSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section {
            Toggle("Mac 음성 메모에 새 녹음이 생기면 자동 처리", isOn: Binding(
                get: { model.memosEnabled },
                set: { v in
                    if v { Task { await model.enableMemos() } } else { model.memosEnabled = false }
                }))
            if model.memosAccess == false {
                VStack(alignment: .leading, spacing: 6) {
                    Label("음성 메모 폴더를 읽으려면 '전체 디스크 접근' 권한이 필요합니다", systemImage: "lock")
                        .foregroundStyle(.orange)
                    Text("시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근 → DJI2Note 켜기 (목록에 없으면 + 로 /Applications/DJI2Note.app 추가)")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("시스템 설정 열기") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                        Button("다시 확인") { model.checkMemosAccess() }
                    }
                }
            } else if model.memosAccess == true {
                LabeledContent("음성 메모") {
                    Text("\(model.memosCount)개 보임").foregroundStyle(.secondary)
                }
                if model.memosEnabled {
                    Button("건너뛴 기존 음성 메모도 모두 처리") { model.processAllMemos() }
                        .disabled(model.isBusy)
                }
            }
        } header: {
            Text("음성 메모")
        } footer: {
            Text("iPhone 음성 메모도 iCloud로 Mac에 동기화되면 함께 처리됩니다. 켤 때 이미 있던 메모는 건너뜁니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { model.checkMemosAccess() }
    }
}

/// 일반 설정: Zoom 로컬 녹화 자동 처리
struct ZoomSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section {
            Toggle("Zoom 녹화가 끝나면 자동으로 가져와 정리", isOn: Binding(
                get: { model.zoomEnabled },
                set: { v in
                    if v { Task { await model.enableZoom() } } else { model.zoomEnabled = false }
                }))
            LabeledContent("녹화 폴더") {
                HStack {
                    Text(model.zoomDir.path.replacingOccurrences(of: Paths.home.path, with: "~"))
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("변경…") { pick() }
                }
            }
            if let s = model.zoomStatus {
                if s.ok {
                    LabeledContent("녹화") {
                        Text("\(s.count ?? 0)개" + ((s.per_person ?? 0) > 0 ? " · 참가자별 오디오 \(s.per_person ?? 0)개" : ""))
                            .foregroundStyle(.secondary)
                    }
                } else if s.error == "permission" {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("녹화 폴더(문서 폴더)를 읽을 권한이 필요합니다", systemImage: "lock").foregroundStyle(.orange)
                        Text("권한 창이 뜨면 '허용'을 누르세요. 이미 거부했다면 시스템 설정 → 개인정보 보호 및 보안 → 파일 및 폴더 → DJI2Note → 문서 폴더를 켜세요.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("시스템 설정 열기") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
                            }
                            Button("다시 확인") { Task { await model.checkZoom() } }
                        }
                    }
                } else {
                    Label("녹화 폴더가 없습니다 — Zoom 설정 → 녹화 → 로컬 녹화 저장 위치를 확인하세요", systemImage: "folder.badge.questionmark")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if model.zoomEnabled {
                Button("건너뛴 기존 Zoom 녹화도 모두 처리") { model.processAllZoom() }
                    .disabled(model.isBusy)
            }
        } header: {
            Text("Zoom")
        } footer: {
            Text("Zoom 설정 → 녹화 → '참가자별로 별도의 오디오 파일 녹음'을 켜면 화자를 실제 참가자 이름으로 정확히 나눕니다. 회의 중 채팅도 요약에 반영됩니다. (로컬 녹화만 해당)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await model.checkZoom() }
    }

    private func pick() {
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
