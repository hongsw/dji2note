import AppKit

/// 직접 실행(아이콘 클릭)과 자동 실행(로그인·DJI 연결)을 구분하고, 응용 프로그램의 Baryon 폴더를 꾸민다.
enum LaunchSupport {
    /// 로그인 항목으로 자동 실행됐는지 (그때는 창을 띄우지 않고 메뉴바에만)
    static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    /// 사용자가 Finder·Launchpad·Spotlight에서 직접 연 경우 (URL로 깨어난 경우 제외)
    static func launchedByUser() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return true }
        return event.eventID == AEEventID(kAEOpenApplication) && !launchedAsLoginItem()
    }

    /// 창이 열려 있으면 Dock에 보이고, 다 닫히면 메뉴바 전용으로
    static func updateDockIcon() {
        let hasWindow = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
        let policy: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            if hasWindow { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    // MARK: 응용 프로그램/Baryon 폴더 아이콘

    /// 앱이 'Baryon' 폴더 안에 있으면 폴더에 바리온 아이콘을 한 번 붙인다
    static func decorateBaryonFolder() {
        let folder = Bundle.main.bundleURL.deletingLastPathComponent()
        guard folder.lastPathComponent == "Baryon" else { return }
        // 이미 사용자 지정 아이콘이 있으면 건드리지 않음 (Icon\r 파일)
        if FileManager.default.fileExists(atPath: folder.appending(path: "Icon\r").path) { return }
        NSWorkspace.shared.setIcon(folderIcon(), forFile: folder.path, options: [])
    }

    /// macOS 기본 폴더 그림 위에 바리온(쿼크 3개가 궤도를 도는) 문양
    static func folderIcon() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        let base = NSWorkspace.shared.icon(for: .folder)
        let image = NSImage(size: size)
        image.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))

        let center = NSPoint(x: size.width / 2, y: size.height * 0.43)
        let r: CGFloat = 92
        // 궤도 세 개 (60°씩 기울인 타원)
        NSColor(white: 1, alpha: 0.92).setStroke()
        for k in 0..<3 {
            let t = NSAffineTransform()
            t.translateX(by: center.x, yBy: center.y)
            t.rotate(byDegrees: CGFloat(k) * 60)
            let oval = NSBezierPath(ovalIn: NSRect(x: -r, y: -r * 0.38, width: r * 2, height: r * 0.76))
            oval.lineWidth = 9
            oval.transform(using: t as AffineTransform)
            oval.stroke()
        }
        // 가운데 핵 + 쿼크 세 개 (빨강·초록·파랑 = 색전하)
        NSColor(white: 1, alpha: 0.95).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 20, y: center.y - 20, width: 40, height: 40)).fill()
        let quarks: [(NSColor, CGFloat)] = [(.systemRed, 90), (.systemGreen, 210), (.systemBlue, 330)]
        for (color, deg) in quarks {
            let a = deg * .pi / 180
            let p = NSPoint(x: center.x + cos(a) * r * 0.98, y: center.y + sin(a) * r * 0.98)
            color.setFill()
            let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 22, y: p.y - 22, width: 44, height: 44))
            dot.fill()
            NSColor.white.setStroke()
            dot.lineWidth = 6
            dot.stroke()
        }
        image.unlockFocus()
        return image
    }
}
