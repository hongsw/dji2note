import SwiftUI

/// 첫 실행 설정 마법사: 환영 → 엔진 설치 → AI → Drive → 기본·자동 실행 → 완료
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @State private var step = UserDefaults.standard.integer(forKey: "debugStep")  // 개발용: --args -debugStep N
    @State private var installing = false
    @State private var installFailed = false
    @State private var withModel = true

    private let titles = ["환영합니다", "엔진 설치", "요약 AI", "Google Drive", "마무리"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case 0: welcome
                case 1: install
                case 2: Form { AISection() }.formStyle(.grouped)
                case 3: Form { DriveSection() }.formStyle(.grouped)
                default: finish
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
        }
        .frame(width: 640, height: 560)
    }

    private var header: some View {
        HStack(spacing: 6) {
            ForEach(titles.indices, id: \.self) { i in
                HStack(spacing: 4) {
                    Image(systemName: i < step ? "checkmark.circle.fill" : (i == step ? "circle.inset.filled" : "circle"))
                        .foregroundStyle(i <= step ? Color.accentColor : .secondary)
                    Text(titles[i]).font(.caption).foregroundStyle(i == step ? .primary : .secondary)
                }
                if i < titles.count - 1 { Rectangle().fill(.quaternary).frame(height: 1) }
            }
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            if step > 0 && step != 1 { Button("이전") { step -= 1 } }
            Spacer()
            switch step {
            case 1:
                Button("다음") { step += 1 }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.engineInstalled || installing)
            case titles.count - 1:
                Button("완료") { complete() }.keyboardShortcut(.defaultAction)
            default:
                Button(step == 3 && model.config.upload != "rclone" ? "건너뛰기" : "다음") { step += 1 }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    // MARK: 단계별 화면

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.and.mic").font(.system(size: 56)).foregroundStyle(.tint).padding(.top, 30)
            Text("DJI2Note").font(.largeTitle.bold())
            Text("DJI 무선 마이크를 Mac에 꽂기만 하면\n받아쓰기 · 화자 구분 · 회의록 요약을 만들고 Google Drive에 올려 드립니다.")
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 8) {
                Label("받아쓰기는 이 Mac 안에서 처리합니다 (Whisper)", systemImage: "lock.shield")
                Label("30분마다 나뉜 긴 녹음도 한 회의로 묶어 정리합니다", systemImage: "rectangle.stack")
                Label("요약·할 일 정리는 Claude AI가 맡습니다 (선택)", systemImage: "sparkles")
            }
            .font(.callout)
            .padding()
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            if !isAppleSilicon {
                Label("이 Mac은 Apple Silicon이 아니라서 받아쓰기 엔진이 동작하지 않습니다.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .padding()
    }

    private var install: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("받아쓰기 엔진과 필요한 도구를 설치합니다. 관리자 암호는 필요 없고, 모든 파일은 이 사용자 폴더에만 설치됩니다.")
                .font(.callout)
            Toggle("받아쓰기 모델(약 1.6GB)도 지금 내려받기 — 첫 회의 처리 시간이 줄어듭니다", isOn: $withModel)
                .disabled(installing || model.engineInstalled)
            HStack {
                Button(installing ? "설치 중…" : (model.engineInstalled ? "다시 설치" : "설치 시작")) {
                    installing = true
                    installFailed = false
                    Task {
                        installFailed = !(await model.installEngine(withModel: withModel))
                        installing = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(installing)
                if installing { ProgressView().controlSize(.small) }
                if model.engineInstalled && !installing {
                    Label("설치됨", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                if installFailed {
                    Label("설치 실패 — 인터넷 연결을 확인하고 다시 시도하세요", systemImage: "xmark.octagon").foregroundStyle(.red)
                }
            }
            LogView().clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding()
    }

    private var finish: some View {
        Form {
            GeneralSection()
            AutomationSection()
            let newOnes = model.connected.filter { $0.status == "new" }
            if !newOnes.isEmpty {
                Section("지금 연결된 DJI의 기존 녹음 \(newOnes.count)개") {
                    Text("완료를 누르면 기존 녹음은 건너뛰고 앞으로 새로 녹음한 것만 처리합니다. 필요하면 설정 창에서 개별로 처리할 수 있습니다.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.refresh() }
    }

    private func complete() {
        Task {
            if model.connected.contains(where: { $0.status == "new" }) { await model.skipAllNew() }
            if !model.launchAtLogin { model.launchAtLogin = true }
            model.setupDone = true
        }
    }

    private var isAppleSilicon: Bool {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafeBytes(of: &sysinfo.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } == "arm64"
    }
}
