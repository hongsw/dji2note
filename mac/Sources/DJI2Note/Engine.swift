import Foundation

/// 앱이 쓰는 폴더. Python CLI(tools.APP_BIN)와 같은 위치를 공유한다.
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appending(path: "Library/Application Support/DJI2Note")
    static let bin = support.appending(path: "bin")
    static let uv = bin.appending(path: "uv")
    static let cli = bin.appending(path: "dji2note")
    static let log = home.appending(path: "Library/Logs/dji2note.log")
}

struct CommandResult {
    let status: Int32
    let output: String
    var ok: Bool { status == 0 }
}

/// 한 줄씩 들어오는 출력을 스레드 안전하게 모은다.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var pending = ""
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        pending += String(decoding: chunk, as: UTF8.self)
        // tqdm 진행률은 \r 로 갱신되므로 \r 도 줄 구분으로 취급
        var lines: [String] = []
        while let r = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            lines.append(String(pending[..<r]))
            pending = String(pending[pending.index(after: r)...])
        }
        lock.unlock()
        for l in lines where !l.trimmingCharacters(in: .whitespaces).isEmpty { onLine?(l) }
    }

    func finish() -> String {
        lock.lock(); defer { lock.unlock() }
        if !pending.isEmpty { onLine?(pending); pending = "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Python 엔진(dji2note CLI) 설치와 실행.
enum Engine {
    static let packageURL = "https://github.com/hongsw/dji2note/archive/refs/heads/main.zip"
    static let uvURL = URL(string: "https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-apple-darwin.tar.gz")!

    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: Paths.cli.path) }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = [Paths.bin.path, Paths.home.appending(path: ".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        // uv가 앱 전용 폴더에 Python과 도구를 설치하도록 격리
        env["UV_TOOL_DIR"] = Paths.support.appending(path: "tools").path
        env["UV_TOOL_BIN_DIR"] = Paths.bin.path
        env["UV_PYTHON_INSTALL_DIR"] = Paths.support.appending(path: "python").path
        env["USER"] = env["USER"] ?? NSUserName()  // claude CLI 로그인 확인에 필요
        env["PYTHONUNBUFFERED"] = "1"
        env["NO_COLOR"] = "1"
        return env
    }

    @discardableResult
    static func run(_ exe: URL, _ args: [String], input: String? = nil,
                    onStart: (@Sendable (Int32) -> Void)? = nil,
                    onLine: (@Sendable (String) -> Void)? = nil) async -> CommandResult {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            p.environment = environment
            p.currentDirectoryURL = Paths.home
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let stdin = Pipe()
            p.standardInput = stdin
            let buffer = OutputBuffer(onLine: onLine)
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { buffer.append(d) }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                if !rest.isEmpty { buffer.append(rest) }
                cont.resume(returning: CommandResult(status: proc.terminationStatus, output: buffer.finish()))
            }
            do {
                try p.run()
                onStart?(p.processIdentifier)
                if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
                try? stdin.fileHandleForWriting.close()
            } catch {
                cont.resume(returning: CommandResult(status: -1, output: error.localizedDescription))
            }
        }
    }

    @discardableResult
    static func cli(_ args: [String], onStart: (@Sendable (Int32) -> Void)? = nil,
                    onLine: (@Sendable (String) -> Void)? = nil) async -> CommandResult {
        guard isInstalled else { return CommandResult(status: -1, output: "엔진이 설치되지 않았습니다") }
        return await run(Paths.cli, args, onStart: onStart, onLine: onLine)
    }

    static func json<T: Decodable>(_ args: [String], as type: T.Type) async -> T? {
        let r = await cli(args)
        // 경고 문구가 앞에 섞일 수 있어 마지막 JSON 줄만 사용
        guard let line = r.output.split(separator: "\n").last(where: { $0.hasPrefix("{") || $0.hasPrefix("[") })
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(line.utf8))
    }

    // MARK: 설치

    /// uv(파이썬 설치기) → dji2note → ffmpeg·rclone(→ 받아쓰기 모델)
    static func install(withModel: Bool, log: @escaping @Sendable (String) -> Void) async -> Bool {
        do {
            try FileManager.default.createDirectory(at: Paths.bin, withIntermediateDirectories: true)
            if !FileManager.default.isExecutableFile(atPath: Paths.uv.path) {
                log("① Python 설치기(uv) 내려받는 중…")
                try await installUV()
            }
            log("② DJI2Note 엔진 설치 중… (처음엔 Python과 라이브러리를 받느라 몇 분 걸립니다)")
            let r = await run(Paths.uv, ["tool", "install", "--force", "--refresh-package", "dji2note", "--python", "3.12", packageURL], onLine: log)
            guard r.ok, isInstalled else { log("엔진 설치 실패"); return false }
            log("③ ffmpeg·rclone 준비 중…")
            var args = ["setup-tools"]
            if withModel { args.append("--model"); log("   받아쓰기 모델(약 1.6GB)도 함께 내려받습니다") }
            let t = await cli(args, onLine: log)
            guard t.ok else { log("도구 준비 실패"); return false }
            // 앱이 DJI 연결을 직접 감지하므로 CLI용 launchd 자동 실행은 끈다(중복 방지)
            await cli(["service", "uninstall"])
            log("✅ 설치 완료")
            return true
        } catch {
            log("설치 실패: \(error.localizedDescription)")
            return false
        }
    }

    static func installUV() async throws {
        let (tmp, _) = try await URLSession.shared.download(from: uvURL)
        let dir = FileManager.default.temporaryDirectory.appending(path: "uv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tar = await run(URL(filePath: "/usr/bin/tar"), ["-xzf", tmp.path, "-C", dir.path])
        guard tar.ok else { throw NSError(domain: "DJI2Note", code: 1, userInfo: [NSLocalizedDescriptionKey: tar.output]) }
        let src = dir.appending(path: "uv-aarch64-apple-darwin/uv")
        try? FileManager.default.removeItem(at: Paths.uv)
        try FileManager.default.moveItem(at: src, to: Paths.uv)
        try? FileManager.default.removeItem(at: dir)
    }

    struct ClaudeAuth: Decodable {
        let loggedIn: Bool
        let email: String?
    }

    /// `claude auth status` — 로그인 여부를 창을 띄우지 않고 확인
    static func claudeAuth() async -> ClaudeAuth? {
        guard let path = claudePath() else { return nil }
        let r = await run(URL(filePath: path), ["auth", "status", "--json"])
        guard let start = r.output.firstIndex(of: "{") else { return nil }
        return try? JSONDecoder().decode(ClaudeAuth.self, from: Data(r.output[start...].utf8))
    }

    static func claudePath() -> String? {
        let candidates = [Paths.home.appending(path: ".local/bin/claude").path,
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
