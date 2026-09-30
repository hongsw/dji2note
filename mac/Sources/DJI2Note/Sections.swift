import AppKit
import SwiftUI

// 설정 마법사와 설정 창이 함께 쓰는 화면 조각들

let languages: [(String, String)] = [("ko", "한국어"), ("en", "English"), ("ja", "日本語"), ("zh", "中文"), ("auto", "자동 감지")]
let models: [(String, String)] = [("claude-sonnet-5", "Claude Sonnet 5 (권장·균형)"),
                                  ("claude-opus-5-5", "Claude Opus 5.5 (최고 품질)"),
                                  ("claude-haiku-4-5-20251001", "Claude Haiku 4.5 (빠르고 저렴)")]

/// 저장 폴더·언어·알림
struct GeneralSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section("기본") {
            LabeledContent("회의록 저장 폴더") {
                HStack {
                    Text(model.config.output_dir).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("변경…") { pickFolder() }
                }
            }
            Picker("대화 언어", selection: binding(\.language, key: "language")) {
                ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
            }
            Toggle("처리가 끝나면 알림", isOn: Binding(
                get: { model.config.notify },
                set: { v in Task { await model.set(["notify": v ? "true" : "false"]) } }))
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.set(["output_dir": url.path]) }
        }
    }

    private func binding(_ path: WritableKeyPath<EngineConfig, String>, key: String) -> Binding<String> {
        Binding(get: { model.config[keyPath: path] },
                set: { v in Task { await model.set([key: v]) } })
    }
}

/// 화자 분리·요약 AI
struct AISection: View {
    @EnvironmentObject var model: AppModel
    @State private var apiKey = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var auth: Engine.ClaudeAuth?
    @State private var authChecked = false

    var body: some View {
        Section {
            Picker("사용할 AI", selection: Binding(
                get: { model.config.llm_backend },
                set: { v in Task { await model.set(["llm_backend": v]) } })) {
                Text("Claude Code (구독)").tag("claude-cli")
                Text("Anthropic API 키").tag("anthropic-api")
                Text("사용 안 함").tag("none")
            }
            .pickerStyle(.segmented)

            switch model.config.llm_backend {
            case "claude-cli":
                LabeledContent("Claude Code") {
                    if !authChecked {
                        ProgressView().controlSize(.small)
                    } else if let auth, auth.loggedIn {
                        Label("로그인됨" + (auth.email.map { " (\($0))" } ?? ""), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if Engine.claudePath() == nil {
                        Label("설치 안 됨", systemImage: "xmark.circle").foregroundStyle(.orange)
                    } else {
                        Label("로그인 필요", systemImage: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange)
                    }
                }
                if authChecked && auth?.loggedIn != true {
                    HStack {
                        Button(Engine.claudePath() == nil ? "Claude Code 설치·로그인…" : "Claude 로그인…") {
                            model.openClaudeLogin()
                        }
                        Button("다시 확인") { Task { await checkAuth() } }
                        Text("터미널이 열리면 브라우저에서 로그인하세요.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            case "anthropic-api":
                LabeledContent("API 키") {
                    HStack {
                        SecureField(model.config.anthropic_api_key.isEmpty ? "sk-ant-…" : "저장됨 (바꾸려면 입력)",
                                    text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                        Button("저장") {
                            let key = apiKey
                            Task { await model.set(["anthropic_api_key": key]); apiKey = "" }
                        }
                        .disabled(apiKey.isEmpty)
                    }
                }
                Link("API 키 발급받기 (console.anthropic.com)", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.caption)
            default:
                Text("받아쓰기와 음량 기준의 간단한 화자 구분만 합니다. 요약은 만들지 않습니다.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if model.config.llm_backend != "none" {
                Picker("모델", selection: Binding(
                    get: { model.config.llm_model },
                    set: { v in Task { await model.set(["llm_model": v]) } })) {
                    ForEach(models, id: \.0) { Text($0.1).tag($0.0) }
                    if !models.contains(where: { $0.0 == model.config.llm_model }) {
                        Text(model.config.llm_model).tag(model.config.llm_model)
                    }
                }
                HStack {
                    Button(testing ? "확인 중…" : "연결 테스트") { test() }.disabled(testing)
                    if let testResult { Text(testResult).font(.callout) }
                }
            }
        } header: {
            Text("화자 분리·요약 AI")
                .task { await checkAuth() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await checkAuth() }  // 터미널에서 로그인하고 돌아오면 자동 갱신
                }
        } footer: {
            Text("음성은 Mac 안에서만 받아씁니다. AI를 켜면 받아쓴 텍스트가 Anthropic으로 전송됩니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func checkAuth() async {
        auth = await Engine.claudeAuth()
        authChecked = true
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            await model.runDoctor()
            let llm = model.report?.checks.first { $0.key == "llm" }
            testResult = llm.map { $0.ok ? "✅ 정상" : "❌ \($0.hint)" } ?? "❌ 확인 실패"
            testing = false
        }
    }
}

/// Google Drive 업로드
struct DriveSection: View {
    @EnvironmentObject var model: AppModel
    @State private var connecting = false
    @State private var folder = ""

    var body: some View {
        Section {
            Toggle("회의록을 Google Drive에 Google Docs로 올리기", isOn: Binding(
                get: { model.config.upload == "rclone" },
                set: { v in Task { await model.set(["upload": v ? "rclone" : "none"]) } }))
                .disabled(model.driveRemotes.isEmpty)

            if model.driveRemotes.isEmpty {
                HStack {
                    Button(connecting ? "브라우저에서 로그인 중…" : "Google 계정 연결…") { connect() }
                        .buttonStyle(.borderedProminent)
                        .disabled(connecting)
                    Text("브라우저가 열리면 로그인 후 '허용'을 누르세요.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Picker("연결된 계정", selection: Binding(
                    get: { model.config.rclone_remote },
                    set: { v in Task { await model.set(["rclone_remote": v]) } })) {
                    ForEach(model.driveRemotes, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Drive 폴더") {
                    HStack {
                        TextField("dji2note", text: $folder)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(saveFolder)
                        Button("저장", action: saveFolder).disabled(folder == model.config.drive_folder)
                    }
                }
                Button(connecting ? "브라우저에서 로그인 중…" : "다른 계정 추가…") { connect(name: "gdrive\(model.driveRemotes.count + 1)") }
                    .disabled(connecting)
            }
        } header: {
            Text("Google Drive")
        }
        .onAppear { folder = model.config.drive_folder }
        .onChange(of: model.config.drive_folder) { _, v in folder = v }
    }

    private func saveFolder() {
        let f = folder.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return }
        Task { await model.set(["drive_folder": f]) }
    }

    private func connect(name: String = "gdrive") {
        connecting = true
        Task {
            _ = await model.connectDrive(name: name)
            connecting = false
        }
    }
}

/// 자동 실행
struct AutomationSection: View {
    @EnvironmentObject var model: AppModel
    @State private var loginItem = false

    var body: some View {
        Section {
            Picker("DJI를 연결하면", selection: $model.connectAction) {
                ForEach(AppModel.ConnectAction.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Toggle("Mac에 로그인하면 DJI2Note 실행 (메뉴바에 상주)", isOn: $loginItem)
                .onChange(of: loginItem) { _, v in model.launchAtLogin = v }
        } header: {
            Text("자동 실행")
        } footer: {
            Text("처음 처리할 때 macOS가 '이동식 볼륨 접근'을 물으면 허용하세요.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { loginItem = model.launchAtLogin }
    }
}

/// 실행 로그
struct LogView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.logLines.enumerated()), id: \.offset) { i, line in
                        Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: model.logLines.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
        }
    }
}
