import Cocoa
import ServiceManagement

// MARK: - 可调参数

let kHoldDuration: TimeInterval = 2.0     // fn + esc 需要按住多久才切换锁定
let kTripleWindow: TimeInterval = 1.5     // 连按 3 次必须在这个时间窗内完成
let kTripleCount = 3
let kHoldHUDDelay: TimeInterval = 0.25    // 按下多久后才显示进度浮层（避免连按时闪烁）
let kEscKeyCode: Int64 = 53
let kSystemDefinedEventType: UInt32 = 14  // 亮度 / 音量 / 播放等媒体键
let kAuxControlButtonsSubtype: Int16 = 8

// MARK: - 事件拦截回调（C 函数指针）

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                         refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let delegate = AppDelegate.shared else { return Unmanaged.passUnretained(event) }
    return delegate.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}

// MARK: - 应用主体

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate?

    let hud = HUDController()
    let pill = PillController()
    private var statusItem: NSStatusItem!

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var watchdog: Timer?

    private(set) var locked = false
    private var comboDown = false            // fn + esc 这次按下是否由我们接管
    private var holdTimer: Timer?
    private var holdHUDWork: DispatchWorkItem?
    private var pressTimes: [TimeInterval] = []

    var muteSounds = false                   // 自测时静音

    private var soundEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "soundEnabled") }
    }

    // MARK: 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.contains("--selftest") { runSelfTest(); return }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            runSnapshots(to: args[i + 1]); return
        }

        // 只允许一个实例
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshStatusIcon()

        // 第一次运行会弹出系统的「辅助功能」授权提示
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) {
            ensureTap()
        } else {
            hud.showMessage(symbol: "hand.raised.fill", tint: .systemYellow,
                            title: "需要辅助功能权限",
                            subtitle: "系统设置 → 隐私与安全性 → 辅助功能\n打开「键盘锁」的开关",
                            linger: 6)
        }

        // 看门狗：等待授权、授权被撤销、拦截器被系统停用时自动处理
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.watchdogTick() }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    // MARK: 事件拦截器

    private func ensureTap() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask: CGEventMask =
            (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.keyUp.rawValue) |
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue) |
            (CGEventMask(1) << kSystemDefinedEventType)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: mask,
                                           callback: tapCallback,
                                           userInfo: nil) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        tapSource = source
        refreshStatusIcon()
        hud.showMessage(symbol: "keyboard", tint: .white,
                        title: "键盘锁已就绪",
                        subtitle: "按住 fn + esc 2 秒即可锁定键盘",
                        linger: 2.5)
    }

    private func teardownTap() {
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        tapSource = nil
        cancelHold()
        comboDown = false
        locked = false
        pill.setVisible(false)
        refreshStatusIcon()
    }

    private func watchdogTick() {
        guard let tap else { ensureTap(); return }
        if !AXIsProcessTrusted() {
            teardownTap()                      // 权限被撤销：立刻撤掉拦截，避免卡住输入
        } else if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// 处理一个键盘事件。返回 true 表示吞掉（不让它到达任何应用）。
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false

        case .flagsChanged:
            // fn 松开 → 取消正在进行的长按
            if !event.flags.contains(.maskSecondaryFn) { cancelHold() }
            return locked

        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == kEscKeyCode {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if isRepeat { return comboDown || locked }
                // 一次全新的 esc 按下。如果上一次的抬起事件丢了，这里顺便复位。
                comboDown = false
                cancelHold()
                if event.flags.contains(.maskSecondaryFn) {
                    comboDown = true
                    comboPressed()
                    return true                // fn + esc 永远不传给其他应用
                }
            }
            return locked

        case .keyUp:
            if event.getIntegerValueField(.keyboardEventKeycode) == kEscKeyCode, comboDown {
                comboDown = false
                cancelHold()
                return true
            }
            return locked

        default:
            // 媒体键（亮度、音量、播放…）以「系统定义事件」的形式出现
            if locked, type.rawValue == kSystemDefinedEventType,
               let ns = NSEvent(cgEvent: event),
               ns.subtype.rawValue == kAuxControlButtonsSubtype {
                return true
            }
            return false
        }
    }

    // MARK: fn + esc 逻辑

    private func comboPressed() {
        let now = ProcessInfo.processInfo.systemUptime
        pressTimes = pressTimes.filter { now - $0 <= kTripleWindow } + [now]
        if pressTimes.count >= kTripleCount {
            // 连按 3 次：无条件回到「未锁定」
            pressTimes.removeAll()
            setLocked(false, forced: true)
            return
        }
        startHold()
    }

    private func startHold() {
        let timer = Timer(timeInterval: kHoldDuration, repeats: false) { [weak self] _ in
            self?.holdCompleted()
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.holdTimer != nil else { return }
            self.hud.showHolding(willLock: !self.locked,
                                 duration: kHoldDuration - kHoldHUDDelay,
                                 startFraction: CGFloat(kHoldHUDDelay / kHoldDuration))
        }
        holdHUDWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + kHoldHUDDelay, execute: work)
    }

    private func cancelHold() {
        guard holdTimer != nil || holdHUDWork != nil else { return }
        holdTimer?.invalidate()
        holdTimer = nil
        holdHUDWork?.cancel()
        holdHUDWork = nil
        hud.cancelHolding()
    }

    private func holdCompleted() {
        holdTimer = nil
        holdHUDWork = nil
        pressTimes.removeAll()
        guard comboDown else { hud.cancelHolding(); return }
        setLocked(!locked, forced: false)
    }

    func setLocked(_ newValue: Bool, forced: Bool) {
        cancelHold()
        locked = newValue
        refreshStatusIcon()
        pill.setVisible(newValue)
        if newValue {
            hud.showMessage(symbol: "lock.fill", tint: .systemOrange,
                            title: "键盘已锁定",
                            subtitle: "按住 fn + esc 2 秒解锁\n或连按 fn + esc 3 次强制解锁",
                            linger: 2.4)
        } else {
            hud.showMessage(symbol: "lock.open.fill", tint: .systemGreen,
                            title: forced ? "已强制解锁键盘" : "键盘已解锁",
                            subtitle: "按住 fn + esc 2 秒可再次锁定")
        }
        if soundEnabled && !muteSounds {
            NSSound(named: newValue ? "Bottle" : "Pop")?.play()
        }
    }

    // MARK: 菜单栏

    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        let name = tap == nil ? "exclamationmark.triangle" : (locked ? "lock.fill" : "keyboard")
        let img = symbolImage(name, size: 14, weight: .regular)
        img.isTemplate = true
        button.image = img
        button.contentTintColor = locked ? .systemOrange : nil
        button.toolTip = tap == nil ? "键盘锁：等待辅助功能权限"
                                    : (locked ? "键盘已锁定" : "键盘锁：未锁定")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector?, checked: Bool = false) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = checked ? .on : .off
            menu.addItem(item)
        }

        if tap == nil {
            add("⚠️ 尚未获得辅助功能权限", nil)
            add("打开「辅助功能」设置…", #selector(openAccessibilitySettings))
        } else {
            add(locked ? "🔒 键盘已锁定" : "键盘未锁定", nil)
            add(locked ? "解锁键盘" : "锁定键盘", #selector(toggleFromMenu))
        }
        menu.addItem(.separator())
        add("按住 fn + esc 2 秒：锁定 / 解锁", nil)
        add("连按 fn + esc 3 次：强制解锁", nil)
        menu.addItem(.separator())
        add("提示音", #selector(toggleSound), checked: soundEnabled)
        add("开机自动启动", #selector(toggleLoginItem),
            checked: SMAppService.mainApp.status == .enabled)
        menu.addItem(.separator())
        add("退出键盘锁", #selector(quit))
    }

    @objc private func toggleFromMenu() {
        guard tap != nil else { return }
        setLocked(!locked, forced: false)
    }

    @objc private func toggleSound() { soundEnabled.toggle() }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            hud.showMessage(symbol: "exclamationmark.triangle.fill", tint: .systemYellow,
                            title: "设置开机启动失败",
                            subtitle: error.localizedDescription, linger: 4)
        }
    }

    @objc private func openAccessibilitySettings() {
        let s = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
AppDelegate.shared = delegate
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
