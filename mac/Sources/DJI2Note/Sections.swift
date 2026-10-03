import AppKit
import SwiftUI

// 설정 마법사와 설정 창이 함께 쓰는 화면 조각들

let languages: [(String, String)] = [("ko", "한국어"), ("en", "English"), ("ja", "日本語"), ("zh", "中文"), ("auto", "자동 감지")]

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
            Picker("자동으로 들어온 녹음의 상황", selection: Binding(
                get: { model.config.default_situation ?? "auto" },
                set: { v in Task { await model.set(["default_situation": v]) } })) {
                ForEach(model.situations) { s in Label(s.title, systemImage: s.icon).tag(s.key) }
            }
            .help("DJI·음성 메모·Zoom 녹음에 적용. 자동 판별이면 AI가 강의·면접·회의 등을 고릅니다")
            Toggle("저전력 모드 — 처리 중에도 다른 작업이 덜 느려지게(대신 처리는 느려짐)", isOn: Binding(
                get: { model.config.low_power ?? false },
                set: { v in Task { await model.set(["low_power": v ? "true" : "false"]) } }))
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

/// 화자 분리·요약 AI — 구독형(CLI 로그인)과 API 키형 공급자
struct AISection: View {
    @EnvironmentObject var model: AppModel
    @State private var key = ""
    @State private var baryonURL = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var auth: Engine.ClaudeAuth?
    @State private var authChecked = false

    private let subscription: [(String, String)] = [("claude-cli", "Claude Code — Anthropic 구독"),
                                                    ("codex-cli", "Codex — ChatGPT 구독")]
    private let apiKeys: [(String, String)] = [("anthropic-api", "Anthropic API (Claude)"),
                                               ("openai-api", "OpenAI API (GPT)"),
                                               ("gemini-api", "Google Gemini API"),
                                               ("baryon", "Baryon AI")]

    private var backend: String { model.config.llm_backend }

    var body: some View {
        Section {
            Picker("사용할 AI", selection: Binding(
                get: { backend },
                set: { v in testResult = nil; Task { await model.set(["llm_backend": v]) } })) {
                Section("구독 (로그인만 하면 됨)") {
                    ForEach(subscription, id: \.0) { Text($0.1).tag($0.0) }
                }
                Section("API 키") {
                    ForEach(apiKeys, id: \.0) { Text($0.1).tag($0.0) }
                }
                Divider()
                Text("사용 안 함 — 받아쓰기만").tag("none")
            }

            credentials

            if backend != "none" {
                modelField("요약 모델", key: "llm_model", value: model.config.llm_model, slot: 0)
                modelField("대본 정리 모델", key: "llm_fast_model", value: model.config.llm_fast_model ?? "", slot: 1)
                HStack {
                    Button(testing ? "확인 중…" : "연결 테스트") { test() }.disabled(testing)
                    if let testResult { Text(testResult).font(.callout).lineLimit(2) }
                }
            }
        } header: {
            Text("화자 분리·요약 AI")
                .task { await checkAuth() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await checkAuth() }  // 터미널에서 로그인하고 돌아오면 자동 갱신
                }
        } footer: {
            Text("음성은 Mac 안에서만 받아씁니다. AI를 켜면 받아쓴 텍스트가 선택한 AI 회사로 전송됩니다. "
                 + "대본 정리는 글이 길어 빠른 모델, 요약은 가장 좋은 모델을 권장합니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: 공급자별 인증 입력

    @ViewBuilder private var credentials: some View {
        switch backend {
        case "claude-cli":
            LabeledContent("Claude Code") {
                if !authChecked {
                    ProgressView().controlSize(.small)
                } else if let auth, auth.loggedIn {
                    Label("로그인됨" + (auth.email.map { " (\($0))" } ?? ""), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label(Engine.claudePath() == nil ? "설치 안 됨" : "로그인 필요", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
            }
            if authChecked && auth?.loggedIn != true {
                HStack {
                    Button(Engine.claudePath() == nil ? "Claude Code 설치·로그인…" : "Claude 로그인…") { model.openClaudeLogin() }
                    Button("다시 확인") { Task { await checkAuth() } }
                }
            }
        case "codex-cli":
            LabeledContent("Codex") {
                if model.config.codex_installed == true {
                    Label("설치됨", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("설치 안 됨", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                }
            }
            Text("터미널에서 `npm i -g @openai/codex` 설치 후 `codex login`으로 ChatGPT 계정 로그인. 모델을 비우면 codex 기본 모델을 씁니다.")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        case "anthropic-api":
            keyField(configKey: "anthropic_api_key", saved: !model.config.anthropic_api_key.isEmpty,
                     placeholder: "sk-ant-…", link: "https://console.anthropic.com/settings/keys")
        case "openai-api":
            keyField(configKey: "openai_api_key", saved: !(model.config.openai_api_key ?? "").isEmpty,
                     placeholder: "sk-…", link: "https://platform.openai.com/api-keys")
        case "gemini-api":
            keyField(configKey: "gemini_api_key", saved: !(model.config.gemini_api_key ?? "").isEmpty,
                     placeholder: "AIza…", link: "https://aistudio.google.com/apikey")
        case "baryon":
            LabeledContent("API 주소") {
                HStack {
                    TextField("https://…", text: $baryonURL).textFieldStyle(.roundedBorder).labelsHidden()
                    Button("저장") { let u = baryonURL; Task { await model.set(["baryon_api_url": u]) } }
                        .disabled(baryonURL.isEmpty || baryonURL == (model.config.baryon_api_url ?? ""))
                }
            }
            .onAppear { baryonURL = model.config.baryon_api_url ?? "" }
            keyField(configKey: "baryon_api_key", saved: !(model.config.baryon_api_key ?? "").isEmpty,
                     placeholder: "Baryon AI 키", link: nil)
            Text("Anthropic 호환 Messages API(`/v1/messages`)를 씁니다.").font(.caption).foregroundStyle(.secondary)
        default:
            Text("받아쓰기와 음량 기준의 간단한 화자 구분만 합니다. 요약은 만들지 않습니다.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func keyField(configKey: String, saved: Bool, placeholder: String, link: String?) -> some View {
        Group {
            LabeledContent("API 키") {
                HStack {
                    SecureField(saved ? "저장됨 (바꾸려면 입력)" : placeholder, text: $key)
                        .textFieldStyle(.roundedBorder).labelsHidden()
                    Button("저장") { let k = key; Task { await model.set([configKey: k]); key = "" } }
                        .disabled(key.isEmpty)
                }
            }
            if let link, let url = URL(string: link) {
                Link("API 키 발급받기", destination: url).font(.caption)
            }
        }
    }

    /// 모델: 공급자 권장값 메뉴 + 직접 입력
    private func modelField(_ label: String, key: String, value: String, slot: Int) -> some View {
        let presets = presetModels
        return LabeledContent(label) {
            HStack {
                TextField(backend == "codex-cli" ? "비우면 기본 모델" : "모델 이름", text: Binding(
                    get: { value },
                    set: { v in Task { await model.set([key: v]) } }))
                    .textFieldStyle(.roundedBorder).labelsHidden()
                if !presets.isEmpty {
                    Menu {
                        ForEach(presets, id: \.self) { m in Button(m) { Task { await model.set([key: m]) } } }
                    } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
    }

    /// 엔진이 알려 주는 공급자 기본 모델 + 잘 알려진 대안
    private var presetModels: [String] {
        var list = model.config.providers?[backend]?.models.filter { !$0.isEmpty } ?? []
        let extra: [String: [String]] = [
            "claude-cli": ["claude-opus-5-5", "claude-sonnet-5", "claude-haiku-4-5-20251001"],
            "anthropic-api": ["claude-opus-5-5", "claude-sonnet-5", "claude-haiku-4-5-20251001"],
            "baryon": ["claude-opus-5-5", "claude-sonnet-5", "claude-haiku-4-5-20251001"],
            "openai-api": ["gpt-5", "gpt-5-mini"],
            "gemini-api": ["gemini-2.5-pro", "gemini-2.5-flash"],
        ]
        for m in extra[backend] ?? [] where !list.contains(m) { list.append(m) }
        return list
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
                            .textFieldStyle(.roundedBorder).labelsHidden()
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

/// Notion 연동 — 내부 통합 토큰 + 회의록을 모을 페이지(또는 데이터베이스)
struct NotionSection: View {
    @EnvironmentObject var model: AppModel
    @State private var token = ""
    @State private var parent = ""
    @State private var testing = false
    @State private var result: AppModel.NotionTest?

    var body: some View {
        Section {
            Toggle("회의록을 Notion 페이지로도 올리기", isOn: Binding(
                get: { model.config.notion_enabled ?? false },
                set: { v in Task { await model.set(["notion_enabled": v ? "true" : "false"]) } }))
                .disabled(!(result?.ok ?? false) && !(model.config.notion_enabled ?? false))

            VStack(alignment: .leading, spacing: 4) {
                Text("처음 한 번만 설정하면 됩니다").font(.callout.weight(.semibold))
                Text("① [Notion 통합 만들기](https://www.notion.so/profile/integrations) → 새 통합(내부) → 토큰 복사")
                Text("② 회의록을 모을 Notion 페이지(또는 데이터베이스)에서 ••• → 연결 → 방금 만든 통합 추가")
                Text("③ 그 페이지의 링크를 복사해 아래에 붙여 넣기")
            }
            .font(.caption).foregroundStyle(.secondary)

            LabeledContent("통합 토큰") {
                HStack {
                    SecureField("통합 토큰", text: $token,
                                prompt: Text((model.config.notion_token ?? "").isEmpty ? "ntn_… 붙여 넣기" : "저장됨 (바꾸려면 입력)"))
                        .textFieldStyle(.roundedBorder).labelsHidden()
                    Button("저장") { let t = token; Task { await model.set(["notion_token": t]); token = ""; await test() } }
                        .disabled(token.isEmpty)
                }
            }
            LabeledContent("회의록 페이지") {
                HStack {
                    TextField("회의록 페이지", text: $parent, prompt: Text("https://www.notion.so/… 페이지 링크")).textFieldStyle(.roundedBorder).labelsHidden()
                    Button("저장") { let p = parent; Task { await model.set(["notion_parent": p]); await test() } }
                        .disabled(parent.isEmpty || parent == (model.config.notion_parent ?? ""))
                }
            }
            HStack {
                Button(testing ? "확인 중…" : "연결 테스트") { Task { await test() } }
                    .disabled(testing || (model.config.notion_token ?? "").isEmpty || (model.config.notion_parent ?? "").isEmpty)
                if let r = result {
                    if r.ok {
                        Label("\(r.type == "database" ? "데이터베이스" : "페이지") '\(r.title ?? "")'에 연결됨",
                              systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                    } else {
                        Text("❌ \(r.error ?? "실패")").font(.callout).foregroundStyle(.red).lineLimit(3)
                    }
                }
            }
            if model.config.notion_enabled ?? false {
                Button("이미 만든 회의록도 모두 Notion에 올리기") { model.publishAllToNotion() }
                    .disabled(model.isBusy)
            }
        } header: {
            Text("Notion")
        } footer: {
            Text("회의마다 Notion 페이지가 하나 생기고(요약), 대본은 하위 페이지로 들어갑니다. 데이터베이스를 고르면 제목·날짜 속성을 채웁니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { parent = model.config.notion_parent ?? "" }
    }

    private func test() async {
        testing = true
        result = await model.testNotion()
        testing = false
    }
}
