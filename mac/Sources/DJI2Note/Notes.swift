import AppKit
import SwiftUI
import WebKit

/// 회의록 폴더 안의 문서 종류
enum NoteDoc: String, Codable, Hashable, CaseIterable, Identifiable {
    case summary, transcript
    var id: String { rawValue }
    var file: String { self == .summary ? "summary.md" : "transcript.md" }
    var title: String { self == .summary ? "요약" : "대본" }
}

/// 보기 창에 넘기는 값 (WindowGroup(for:)용)
struct NoteRef: Codable, Hashable {
    let folder: String
    var doc: NoteDoc
    var url: URL { URL(filePath: folder).appending(path: doc.file) }
}

enum Notes {
    static func exists(_ folder: String, _ doc: NoteDoc) -> Bool {
        FileManager.default.fileExists(atPath: NoteRef(folder: folder, doc: doc).url.path)
    }

    static func markdown(_ ref: NoteRef) -> String {
        (try? String(contentsOf: ref.url, encoding: .utf8)) ?? ""
    }

    /// 요약의 "**주제:** …" 줄 — 목록에 폴더명 대신 보여 줄 제목
    static func topic(folder: String) -> String? {
        let md = markdown(NoteRef(folder: folder, doc: .summary))
        guard let line = md.split(separator: "\n").first(where: { $0.contains("주제:") }) else { return nil }
        let t = line.replacingOccurrences(of: "**", with: "")
            .components(separatedBy: "주제:").last?.trimmingCharacters(in: .whitespaces) ?? ""
        return t.isEmpty ? nil : t
    }

    static func html(_ ref: NoteRef) async -> String {
        let r = await Engine.cli(["render", ref.url.path, "--fragment"])
        if r.ok { return r.output }
        // 엔진이 없으면 원문을 그대로 보여 준다
        let escaped = markdown(ref).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return "<pre>\(escaped)</pre>"
    }

    /// 서식(HTML)과 일반 텍스트를 함께 복사 → 문서·메신저 어디에 붙여도 자연스럽게
    static func copy(_ ref: NoteRef) async {
        let md = markdown(ref)
        let html = await html(ref)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(html, forType: .html)
        pb.setString(md, forType: .string)
    }
}

/// 목록의 한 회의록: 제목(주제) + 요약·대본 보기/복사 + 폴더·Drive
struct HistoryRow: View {
    let item: HistoryItem
    var compact = false
    @Environment(\.openWindow) private var openWindow
    @State private var copied: NoteDoc?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(topic ?? folderName).font(compact ? .callout.weight(.medium) : .body.weight(.medium))
                        .lineLimit(compact ? 1 : 2)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let folder = item.entry.notes {
                    Button { NSWorkspace.shared.open(URL(filePath: folder)) } label: { Image(systemName: "folder") }
                        .help("Mac의 회의록 폴더 열기")
                }
                if let url = item.entry.drive_url, let u = URL(string: url), !url.isEmpty {
                    Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "globe") }
                        .help("Google Drive에서 열기")
                }
            }
            if let folder = item.entry.notes {
                HStack(spacing: 8) {
                    ForEach(NoteDoc.allCases) { doc in
                        if Notes.exists(folder, doc) { docButtons(folder: folder, doc: doc) }
                    }
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 2)
    }

    /// [요약 보기 | 복사] 한 묶음
    private func docButtons(folder: String, doc: NoteDoc) -> some View {
        HStack(spacing: 0) {
            Button {
                openWindow(id: "viewer", value: NoteRef(folder: folder, doc: doc))
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label(doc.title, systemImage: doc == .summary ? "list.bullet.rectangle" : "text.bubble")
                    .padding(.horizontal, 8).padding(.vertical, 3)
            }
            .help("\(doc.title) 보기")
            Divider().frame(height: 14)
            Button {
                Task {
                    await Notes.copy(NoteRef(folder: folder, doc: doc))
                    copied = doc
                    try? await Task.sleep(for: .seconds(1.5))
                    if copied == doc { copied = nil }
                }
            } label: {
                Image(systemName: copied == doc ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied == doc ? .green : .primary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
            }
            .help("\(doc.title) 복사 (서식 유지)")
        }
        .font(.caption)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }

    private var folderName: String {
        item.entry.notes.map { URL(filePath: $0).lastPathComponent } ?? item.name
    }

    private var topic: String? { item.entry.notes.flatMap(Notes.topic(folder:)) }

    /// "2026-09-28 11:27 · MIC025"
    private var subtitle: String {
        let parts = folderName.split(separator: "_")
        guard parts.count >= 3, parts[1].count == 4 else { return folderName }
        let t = parts[1]
        return "\(parts[0]) \(t.prefix(2)):\(t.suffix(2)) · " + parts[2...].joined(separator: "_")
    }
}

/// 요약·대본 보기 창
struct NoteViewer: View {
    @State var ref: NoteRef
    @State private var html = ""
    @State private var copied = false

    var body: some View {
        WebView(html: html)
            .frame(minWidth: 560, minHeight: 480)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $ref.doc) {
                        ForEach(NoteDoc.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
                ToolbarItemGroup {
                    Button {
                        Task {
                            await Notes.copy(ref)
                            copied = true
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "복사됨" : "복사", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .help("서식을 유지한 채 클립보드로 복사")
                    Button { NSWorkspace.shared.activateFileViewerSelecting([ref.url]) } label: {
                        Label("Finder에서 보기", systemImage: "folder")
                    }
                }
            }
            .navigationTitle(URL(filePath: ref.folder).lastPathComponent)
            .task(id: ref) { html = await Notes.html(ref) }
    }
}

/// HTML 표시 (다크 모드 대응 스타일 포함)
struct WebView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let v = WKWebView()
        v.setValue(false, forKey: "drawsBackground")
        return v
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        view.loadHTMLString(Self.page(html), baseURL: nil)
    }

    static func page(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; }
        body { font: 14px/1.65 -apple-system, "Apple SD Gothic Neo", sans-serif; margin: 28px 36px; max-width: 820px; }
        h1 { font-size: 22px; margin-top: 0; } h2 { font-size: 17px; margin-top: 28px; border-bottom: 1px solid #8884; padding-bottom: 4px; }
        h3 { font-size: 15px; margin-top: 20px; } p { margin: 8px 0; } li { margin: 3px 0; }
        table { border-collapse: collapse; margin: 10px 0; } th, td { border: 1px solid #8886; padding: 5px 10px; text-align: left; }
        th { background: #8882; } code { font: 12px ui-monospace, monospace; background: #8882; padding: 1px 4px; border-radius: 4px; }
        hr { border: none; border-top: 1px solid #8884; margin: 18px 0; }
        </style></head><body>\(body)</body></html>
        """
    }
}
