import SwiftUI

/// 첫 화면·메뉴바 맨 위: DJI 연결 상태를 한눈에
struct DeviceCard: View {
    @EnvironmentObject var model: AppModel
    var compact = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill(connected ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
                Image(systemName: connected ? "mic.fill" : "mic.slash")
                    .font(.system(size: compact ? 16 : 20, weight: .semibold))
                    .foregroundStyle(connected ? .green : .secondary)
            }
            .frame(width: compact ? 36 : 46, height: compact ? 36 : 46)
            .overlay(alignment: .bottomTrailing) {
                Circle().fill(connected ? .green : .gray)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
            }

            VStack(alignment: .leading, spacing: 4) {
                if let d = model.device {
                    HStack(spacing: 6) {
                        Text("DJI 마이크 연결됨").font(compact ? .callout.weight(.semibold) : .headline)
                        Text(d.name).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                    if !compact {
                        ProgressView(value: Double(d.used), total: Double(max(d.total, 1)))
                            .tint(Double(d.free) / Double(max(d.total, 1)) < 0.1 ? .orange : .accentColor)
                        Text("저장 공간 \(bytes(d.used)) / \(bytes(d.total)) 사용 · \(bytes(d.free)) 남음")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text("DJI 마이크 연결 안 됨").font(compact ? .callout.weight(.semibold) : .headline)
                    Text("송신기를 USB로 연결하면 \(model.connectAction.short.replacingOccurrences(of: "연결 시 ", with: ""))합니다")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if model.device != nil {
                Button { model.ejectDevice() } label: {
                    Label("꺼내기", systemImage: "eject")
                }
                .controlSize(compact ? .small : .regular)
                .disabled(isCopying)
                .help(isCopying ? "복사가 끝나면 꺼낼 수 있습니다" : "안전하게 꺼낸 뒤 USB를 분리하세요")
            }
        }
        .padding(compact ? 10 : 14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(connected ? Color.green.opacity(0.06) : Color.secondary.opacity(0.06))
        )
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(connected ? Color.green.opacity(0.35) : Color.secondary.opacity(0.2)))
        .animation(.easeInOut(duration: 0.2), value: model.device)
    }

    private var connected: Bool { model.device != nil }

    /// "녹음 25개 · 새 녹음 2 · 처리 완료 3"
    private var summary: String {
        let all = model.connected.count
        let new = model.connected.filter { $0.status == "new" }.count
        let pending = model.pendingCount
        let done = model.connected.filter { $0.status == "done" }.count
        var parts = ["녹음 \(all)개"]
        if new > 0 { parts.append("새 녹음 \(new)개") }
        if pending > new { parts.append("남은 녹음 \(pending)개") }
        if done > 0 { parts.append("완료 \(done)개") }
        return parts.joined(separator: " · ")
    }

    private var isCopying: Bool { model.isBusy && model.statusText.contains("복사 중") }

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
