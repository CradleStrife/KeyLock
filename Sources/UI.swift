import Cocoa

// MARK: - 小工具

func symbolImage(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg)
    return img ?? NSImage(size: NSSize(width: size, height: size))
}

/// 给 NSVisualEffectView 用的圆角蒙版（这样窗口阴影也会跟着圆角走）
func roundedMask(radius: CGFloat) -> NSImage {
    let d = radius * 2 + 1
    let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    img.resizingMode = .stretch
    return img
}

func makeOverlayPanel(size: NSSize, level: NSWindow.Level) -> NSPanel {
    let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = level
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.appearance = NSAppearance(named: .vibrantDark)
    return panel
}

func activeScreen() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
}

// MARK: - 长按进度条

final class HoldBar: NSView {
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [track, fill] {
            l.fillColor = nil
            l.lineWidth = 5
            l.lineCap = .round
            layer?.addSublayer(l)
        }
        track.strokeColor = NSColor.white.withAlphaComponent(0.2).cgColor
        fill.strokeColor = NSColor.white.cgColor
        fill.strokeEnd = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 3, y: bounds.midY))
        p.addLine(to: CGPoint(x: bounds.maxX - 3, y: bounds.midY))
        for l in [track, fill] {
            l.frame = bounds
            l.path = p
        }
    }

    func animate(from: CGFloat, duration: CFTimeInterval) {
        fill.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.strokeEnd = 1
        CATransaction.commit()
        let a = CABasicAnimation(keyPath: "strokeEnd")
        a.fromValue = from
        a.toValue = 1
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        fill.add(a, forKey: "progress")
    }

    func setStatic(_ value: CGFloat) {
        fill.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.strokeEnd = value
        CATransaction.commit()
    }
}

// MARK: - 屏幕中央的提示浮层

final class HUDController {
    private enum Mode { case hidden, holding, message }

    private let size = NSSize(width: 300, height: 196)
    private let panel: NSPanel
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let bar = HoldBar(frame: .zero)
    private var mode: Mode = .hidden
    private var generation = 0
    private var hideWork: DispatchWorkItem?

    init() {
        panel = makeOverlayPanel(size: size, level: .screenSaver)

        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        fx.material = .hudWindow
        fx.state = .active
        fx.blendingMode = .behindWindow
        fx.maskImage = roundedMask(radius: 26)
        panel.contentView = fx

        icon.imageScaling = .scaleNone

        titleLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center

        subLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        subLabel.alignment = .center
        subLabel.lineBreakMode = .byWordWrapping
        subLabel.maximumNumberOfLines = 2
        subLabel.preferredMaxLayoutWidth = size.width - 44

        let stack = NSStackView(views: [icon, titleLabel, subLabel, bar])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(14, after: subLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: fx.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: fx.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: size.width - 40),
            icon.heightAnchor.constraint(equalToConstant: 62),
            bar.widthAnchor.constraint(equalToConstant: 190),
            bar.heightAnchor.constraint(equalToConstant: 7),
        ])
    }

    /// 长按进行中：显示进度条
    func showHolding(willLock: Bool, duration: TimeInterval, startFraction: CGFloat) {
        configure(symbol: willLock ? "lock.fill" : "lock.open.fill",
                  tint: NSColor.white.withAlphaComponent(0.9),
                  title: willLock ? "继续按住以锁定键盘" : "继续按住以解锁键盘",
                  subtitle: "松开即取消")
        bar.alphaValue = 1
        present()
        bar.animate(from: startFraction, duration: duration)
        mode = .holding
    }

    /// 结果 / 通知：停留一会儿后自动淡出
    func showMessage(symbol: String, tint: NSColor, title: String, subtitle: String,
                     linger: TimeInterval = 1.9) {
        configure(symbol: symbol, tint: tint, title: title, subtitle: subtitle)
        bar.alphaValue = 0
        bar.setStatic(0)
        present()
        mode = .message
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + linger, execute: work)
    }

    func cancelHolding() {
        if mode == .holding { hide() }
    }

    private func configure(symbol: String, tint: NSColor, title: String, subtitle: String) {
        icon.image = symbolImage(symbol, size: 50, weight: .medium)
        icon.contentTintColor = tint
        titleLabel.stringValue = title
        subLabel.stringValue = subtitle
    }

    private func present() {
        generation += 1
        hideWork?.cancel()
        hideWork = nil
        if let screen = activeScreen() {
            let f = screen.frame
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2,
                                         y: f.midY - size.height / 2 - f.height * 0.08))
        }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        generation += 1
        let g = generation
        mode = .hidden
        hideWork?.cancel()
        hideWork = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == g else { return }
            self.panel.orderOut(nil)
        })
    }

    /// 仅用于调试：把当前浮层内容渲染成 PNG（毛玻璃背景用深色代替）
    func snapshot(to url: URL, barFraction: CGFloat? = nil) {
        guard let v = panel.contentView else { return }
        if let barFraction { bar.setStatic(barFraction) }
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        let img = NSImage(size: v.bounds.size)
        img.lockFocus()
        NSColor(white: 0.14, alpha: 1).setFill()
        NSBezierPath(roundedRect: v.bounds, xRadius: 26, yRadius: 26).fill()
        rep.draw(in: v.bounds)
        img.unlockFocus()
        if let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }
}

// MARK: - 锁定期间常驻在屏幕顶部的小胶囊

final class PillController {
    private let panel: NSPanel
    private let size: NSSize

    init() {
        let icon = NSImageView(image: symbolImage("lock.fill", size: 11, weight: .semibold))
        icon.contentTintColor = .systemOrange
        let label = NSTextField(labelWithString: "键盘已锁定 · 按住 fn + esc 2 秒解锁")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 14, bottom: 7, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        size = stack.fittingSize

        panel = makeOverlayPanel(size: size, level: .statusBar)
        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        fx.material = .hudWindow
        fx.state = .active
        fx.blendingMode = .behindWindow
        fx.maskImage = roundedMask(radius: size.height / 2)
        panel.contentView = fx
        fx.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: fx.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: fx.centerYAnchor),
        ])
    }

    func setVisible(_ visible: Bool) {
        if visible {
            if let screen = activeScreen() {
                let v = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: v.midX - size.width / 2,
                                             y: v.maxY - size.height - 8))
            }
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }
}
