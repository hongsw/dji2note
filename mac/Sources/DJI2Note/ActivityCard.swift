import SwiftUI

/// 처리 중일 때: 단계 · 진행률 · 경과/남은 시간 · CPU·메모리 · 중지
struct ActivityCard: View {
    @EnvironmentObject var model: AppModel
    var compact = false
    @State private var confirmCancel = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: compact ? 6 : 10) {
                header
                if !compact { steps }
                progressRow
                usageRow
            }
        }
        .padding(compact ? 10 : 14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.3)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.statusText).font(compact ? .callout.weight(.semibold) : .headline).lineLimit(1)
                if !model.currentItem.isEmpty {
                    Text((model.meetingTotal > 1 ? "회의 \(model.meetingIndex)/\(model.meetingTotal) · " : "") + model.currentItem)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if confirmCancel {
                Button("정말 중지") { model.cancelRun(); confirmCancel = false }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
                Button("계속") { confirmCancel = false }.controlSize(.small)
            } else {
                Button { confirmCancel = true } label: { Label("중지", systemImage: "stop.circle") }
                    .controlSize(.small)
                    .help("지금까지 한 받아쓰기·AI 정리는 저장돼 다음에 이어서 처리합니다")
            }
        }
    }

    /// 복사 → 받아쓰기 → AI 정리 → 요약 → 올리기
    private var steps: some View {
        HStack(spacing: 4) {
            ForEach(AppModel.Stage.allCases, id: \.rawValue) { s in
                let cur = model.stage
                let done = cur.map { s.rawValue < $0.rawValue } ?? false
                let active = cur == s
                HStack(spacing: 3) {
                    Image(systemName: done ? "checkmark.circle.fill" : s.icon)
                    Text(s.title)
                }
                .font(.caption.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? Color.accentColor : (done ? Color.green : Color.secondary))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(active ? Color.accentColor.opacity(0.15) : .clear))
                if s != AppModel.Stage.allCases.last {
                    Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var progressRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let p = model.progress {
                ProgressView(value: p)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                if let start = model.runStartedAt {
                    Text("경과 \(Self.format(Date().timeIntervalSince(start)))")
                }
                if let eta {
                    Text("· 이 단계 약 \(Self.format(eta)) 남음")
                }
                Spacer()
                if let p = model.progress { Text("\(Int(p * 100))%").monospacedDigit() }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var usageRow: some View {
        if let u = model.usage {
            let level = u.cpu < 150 ? Color.green : (u.cpu < 400 ? Color.orange : Color.red)
            HStack(spacing: 10) {
                Label("CPU \(Int(u.cpu))%", systemImage: "cpu").foregroundStyle(level)
                Label(u.memoryMB >= 1024 ? String(format: "%.1fGB", Double(u.memoryMB) / 1024) : "\(u.memoryMB)MB",
                      systemImage: "memorychip")
                if u.aiProcesses > 0 { Label("AI \(u.aiProcesses)개 동시", systemImage: "sparkles") }
                if model.stage == .transcribe { Label("GPU 사용", systemImage: "bolt.fill") }
                Spacer()
                if u.cpu >= 400 && !compact {
                    Text("CPU 사용 높음 — 설정 → 일반 → 저전력 모드").foregroundStyle(.orange)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    /// 단계 진행률과 경과 시간으로 남은 시간 추정
    private var eta: TimeInterval? {
        guard let p = model.progress, p > 0.05, p < 1, let s = model.stageStartedAt else { return nil }
        let t = Date().timeIntervalSince(s)
        return t * (1 - p) / p
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s >= 3600 { return "\(s / 3600)시간 \(s / 60 % 60)분" }
        if s >= 60 { return "\(s / 60)분 \(s % 60)초" }
        return "\(s)초"
    }
}
