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
                Picker("", selection: $recorder.mode) {
                    ForEach(Recorder.Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Button {
                    Task { await recorder.start(in: model.recordingsDir) }
                } label: {
                    Label("녹음 시작", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .disabled(model.isBusy && !compact)
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
                Text("\(recorder.mode.title) 녹음 중").font(.callout.weight(.semibold))
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
