import SwiftUI

/// 첫 화면·메뉴바 맨 위: DJI 연결 상태와 "Mac으로 복사 → 분리해도 됨" 진행 상황
struct DeviceCard: View {
    @EnvironmentObject var model: AppModel
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack(alignment: .center, spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    if let d = model.device {
                        HStack(spacing: 6) {
                            Text("DJI 마이크 연결됨").font(compact ? .callout.weight(.semibold) : .headline)
                            Text(d.name).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("DJI 마이크 연결 안 됨").font(compact ? .callout.weight(.semibold) : .headline)
                        if model.isBusy {
                            Label("Mac에 복사해 둔 녹음으로 처리 계속 중 — 다시 연결하지 않아도 됩니다",
                                  systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                        } else {
                            Text("송신기를 USB로 연결하면 \(model.connectAction.short.replacingOccurrences(of: "연결 시 ", with: ""))합니다")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                if model.device != nil {
                    Button { model.ejectDevice() } label: { Label("꺼내기", systemImage: "eject") }
                        .controlSize(compact ? .small : .regular)
                        .buttonStyle(.bordered)
                        .tint(state == .safe ? .green : nil)
                        .disabled(state == .copying)
                        .help(state == .copying ? "복사가 끝나면 꺼낼 수 있습니다" : "안전하게 꺼낸 뒤 USB를 분리하세요")
                }
            }
            if model.device != nil { backupRow }
        }
        .padding(compact ? 10 : 14)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.4)))
        .animation(.easeInOut(duration: 0.25), value: model.backup)
        .animation(.easeInOut(duration: 0.25), value: model.device)
    }

    // MARK: 복사 상태

    private enum CopyState { case none, copying, safe, notCopied }

    private var state: CopyState {
        guard model.device != nil else { return .none }
        let b = model.backup
        if b.filesTotal == 0 || b.safeToRemove { return .safe }
        return model.statusText.contains("복사 중") ? .copying : .notCopied
    }

    private var tint: Color {
        switch state {
        case .none: .secondary
        case .copying: .orange
        case .safe: .green
        case .notCopied: .blue
        }
    }

    @ViewBuilder private var backupRow: some View {
        let b = model.backup
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: rowIcon).foregroundStyle(tint)
                Text(rowTitle).font(compact ? .caption.weight(.semibold) : .callout.weight(.semibold))
                    .foregroundStyle(state == .copying ? .orange : .primary)
                Spacer(minLength: 0)
                if b.filesTotal > 0 {
                    Text("\(Int(b.fraction * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if b.filesTotal > 0 {
                ProgressView(value: b.fraction).tint(tint)
                Text("파일 \(b.filesCopied)/\(b.filesTotal) · \(bytes(b.bytesCopied)) / \(bytes(b.bytesTotal))"
                     + (compact ? "" : "  ·  장치 저장 공간 \(bytes(model.device?.free ?? 0)) 남음"))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var rowIcon: String {
        switch state {
        case .copying: "arrow.down.doc"
        case .safe: "checkmark.circle.fill"
        default: "externaldrive"
        }
    }

    private var rowTitle: String {
        let b = model.backup
        switch state {
        case .copying: return "Mac으로 복사 중 — 분리하지 마세요"
        case .safe: return b.filesTotal == 0 ? "처리할 녹음 없음 — 분리해도 됩니다"
                                             : "녹음 \(b.filesTotal)개 모두 Mac에 복사됨 — 분리해도 됩니다"
        case .notCopied: return "Mac에 아직 복사하지 않은 녹음 \(b.filesTotal - b.filesCopied)개"
        case .none: return ""
        }
    }

    private var icon: some View {
        let connected = model.device != nil
        return ZStack {
            Circle().fill(connected ? tint.opacity(0.15) : Color.secondary.opacity(0.12))
            Image(systemName: connected ? "mic.fill" : "mic.slash")
                .font(.system(size: compact ? 16 : 20, weight: .semibold))
                .foregroundStyle(connected ? tint : .secondary)
        }
        .frame(width: compact ? 36 : 46, height: compact ? 36 : 46)
        .overlay(alignment: .bottomTrailing) {
            Circle().fill(connected ? Color.green : Color.gray)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
        }
    }

    /// "녹음 25개 · 남은 녹음 14개 · 완료 6개"
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

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
