import AVFoundation
import Foundation
import ScreenCaptureKit

/// 앱 안에서 바로 녹음: 대면(마이크 하나) / 온라인 회의(내 마이크 + Mac 소리를 따로 녹음 → 2채널로 합쳐 처리)
@MainActor
final class Recorder: NSObject, ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case inPerson, meeting
        var id: String { rawValue }
        var title: String { self == .inPerson ? "대면 회의" : "온라인 회의" }
        var hint: String {
            self == .inPerson ? "고른 마이크로 녹음합니다. DJI 수신기를 스테레오(분리) 모드로 쓰면 채널로 화자를 나눕니다."
                              : "내 마이크와 Mac에서 나는 소리(Zoom·Meet·Teams 상대방)를 따로 녹음해 '나/상대방'을 정확히 나눕니다."
        }
    }

    struct Device: Identifiable, Hashable {
        let id: String
        let name: String
    }

    @Published var devices: [Device] = []
    @Published var deviceID: String = UserDefaults.standard.string(forKey: "recDevice") ?? "" {
        didSet { UserDefaults.standard.set(deviceID, forKey: "recDevice") }
    }
    @Published var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "recMode") ?? "") ?? .inPerson {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "recMode") }
    }
    @Published private(set) var isRecording = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var micLevel: Float = 0     // 0…1
    @Published private(set) var systemLevel: Float = 0
    @Published var error: String?

    /// 녹음이 끝나면 (파일들, 모드) 를 넘겨 처리
    var onFinished: (([URL], Mode) -> Void)?

    private var session: AVCaptureSession?
    private var fileOutput: AVCaptureAudioFileOutput?
    private var scStream: SCStream?
    private var sysWriter: SystemAudioWriter?
    private var meterTimer: Timer?
    private var activity: NSObjectProtocol?
    private var files: [URL] = []

    override init() {
        super.init()
        refreshDevices()
        NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices(preferDJI: true) }
        }
        NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices() }
        }
    }

    // MARK: 장치

    func refreshDevices(preferDJI: Bool = false) {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                     mediaType: .audio, position: .unspecified).devices
        devices = found.map { Device(id: $0.uniqueID, name: $0.localizedName) }
        // DJI 수신기가 새로 연결되면 자동으로 선택
        if preferDJI, let dji = devices.first(where: { $0.name.localizedCaseInsensitiveContains("DJI") }) {
            deviceID = dji.id
        }
        if !devices.contains(where: { $0.id == deviceID }) {
            deviceID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? devices.first?.id ?? ""
        }
    }

    var deviceName: String { devices.first { $0.id == deviceID }?.name ?? "기본 마이크" }

    // MARK: 녹음

    func start(in dir: URL) async {
        guard !isRecording else { return }
        error = nil
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            error = "마이크 권한이 필요합니다 — 시스템 설정 → 개인정보 보호 및 보안 → 마이크에서 DJI2Note를 허용하세요"
            return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Self.stamp()
        files = []
        do {
            switch mode {
            case .inPerson:
                let url = dir.appending(path: "REC_\(stamp).wav")
                try startMic(to: url)
                files = [url]
            case .meeting:
                let mic = dir.appending(path: "MEET_\(stamp)_mic.wav")
                let sys = dir.appending(path: "MEET_\(stamp)_sys.wav")
                try startMic(to: mic)
                try await startSystemAudio(to: sys)
                files = [mic, sys]
            }
        } catch {
            self.error = error.localizedDescription
            await stop(process: false)
            return
        }
        isRecording = true
        startedAt = Date()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "DJI2Note 녹음")
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMeter() }
        }
    }

    func stop(process: Bool = true) async {
        meterTimer?.invalidate()
        meterTimer = nil
        fileOutput?.stopRecording()
        session?.stopRunning()
        if let s = scStream { try? await s.stopCapture() }
        await sysWriter?.finish()
        // 파일 기록이 끝날 때까지 잠깐 대기
        try? await Task.sleep(for: .milliseconds(600))
        session = nil
        fileOutput = nil
        scStream = nil
        sysWriter = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        activity = nil
        let wasRecording = isRecording
        isRecording = false
        startedAt = nil
        micLevel = 0
        systemLevel = 0
        let done = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        if process && wasRecording && !done.isEmpty { onFinished?(done, mode) }
    }

    private func startMic(to url: URL) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID) ?? AVCaptureDevice.default(for: .audio) else {
            throw NSError(domain: "DJI2Note", code: 1, userInfo: [NSLocalizedDescriptionKey: "사용할 마이크가 없습니다"])
        }
        let s = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard s.canAddInput(input) else { throw NSError(domain: "DJI2Note", code: 2, userInfo: [NSLocalizedDescriptionKey: "마이크를 열 수 없습니다"]) }
        s.addInput(input)
        let out = AVCaptureAudioFileOutput()
        guard s.canAddOutput(out) else { throw NSError(domain: "DJI2Note", code: 3, userInfo: [NSLocalizedDescriptionKey: "녹음 출력을 만들 수 없습니다"]) }
        s.addOutput(out)
        // 장치 채널 수 유지(DJI 수신기 스테레오면 2채널), 48kHz 16bit WAV
        let channels = max(1, min(2, Int(device.activeFormat.formatDescription.audioStreamBasicDescription?.mChannelsPerFrame ?? 1)))
        out.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
                             AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
                             AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        s.startRunning()
        out.startRecording(to: url, outputFileType: .wav, recordingDelegate: self)
        session = s
        fileOutput = out
    }

    private func startSystemAudio(to url: URL) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw NSError(domain: "DJI2Note", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "Mac 소리 녹음 권한이 필요합니다 — 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음에서 DJI2Note를 허용한 뒤 다시 시도하세요"])
        }
        guard let display = content.displays.first else {
            throw NSError(domain: "DJI2Note", code: 5, userInfo: [NSLocalizedDescriptionKey: "화면 정보를 가져올 수 없습니다"])
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        // 화면은 쓰지 않으므로 최소 크기·최저 빈도
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let writer = try SystemAudioWriter(url: url) { [weak self] level in
            Task { @MainActor in self?.systemLevel = level }
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
        try await stream.startCapture()
        scStream = stream
        sysWriter = writer
    }

    private func updateMeter() {
        guard let conn = fileOutput?.connections.first else { return }
        let db = conn.audioChannels.map(\.averagePowerLevel).max() ?? -160
        micLevel = max(0, min(1, (db + 60) / 60))  // -60dB…0dB → 0…1
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }
}

extension Recorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        if let error { Task { @MainActor in self.error = error.localizedDescription } }
    }
}

/// ScreenCaptureKit의 시스템 오디오 샘플을 WAV로 기록
final class SystemAudioWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "dji2note.sysaudio")
    private let writer: AVAssetWriter
    private var input: AVAssetWriterInput?
    private var started = false
    private let onLevel: (Float) -> Void

    init(url: URL, onLevel: @escaping (Float) -> Void) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .wav)
        self.onLevel = onLevel
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, buffer.isValid else { return }
        if input == nil {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
                                           AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                                           AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                           AVLinearPCMIsNonInterleaved: false]
            let inp = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            inp.expectsMediaDataInRealTime = true
            guard writer.canAdd(inp) else { return }
            writer.add(inp)
            input = inp
        }
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            started = true
        }
        if let input, input.isReadyForMoreMediaData { input.append(buffer) }
        onLevel(Self.level(of: buffer))
    }

    func finish() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                guard self.started else { cont.resume(); return }
                self.input?.markAsFinished()
                self.writer.finishWriting { cont.resume() }
            }
        }
    }

    /// 버퍼의 대략적인 음량(0…1)
    private static func level(of buffer: CMSampleBuffer) -> Float {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return 0 }
        var length = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &ptr) == noErr, let ptr else { return 0 }
        // SCK 오디오는 32bit float
        let count = length / MemoryLayout<Float>.size
        let floats = UnsafeRawPointer(ptr).bindMemory(to: Float.self, capacity: count)
        var sum: Float = 0
        let step = max(1, count / 512)
        var n = 0
        for i in stride(from: 0, to: count, by: step) { sum += floats[i] * floats[i]; n += 1 }
        let rms = sqrt(sum / Float(max(n, 1)))
        let db = 20 * log10(max(rms, 1e-6))
        return max(0, min(1, (db + 60) / 60))
    }
}
