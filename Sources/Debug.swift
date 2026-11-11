import Cocoa

// 调试入口：
//   KeyLock --selftest          用合成事件验证锁定 / 解锁逻辑（不需要任何权限）
//   KeyLock --snapshot <目录>    把各状态的提示浮层渲染成 PNG

extension AppDelegate {
    func runSelfTest() {
        muteSounds = true
        var failures = 0

        func check(_ name: String, _ ok: Bool) {
            print((ok ? "PASS  " : "FAIL  ") + name)
            if !ok { failures += 1 }
        }
        func wait(_ t: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(t))
        }
        @discardableResult
        func key(_ code: CGKeyCode, down: Bool, fn: Bool = false, rep: Bool = false) -> Bool {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
            e.flags = fn ? .maskSecondaryFn : []
            if rep { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            return handle(type: down ? .keyDown : .keyUp, event: e)
        }
        @discardableResult
        func fnKey(_ down: Bool) -> Bool {
            let e = CGEvent(source: nil)!
            e.type = .flagsChanged
            e.flags = down ? .maskSecondaryFn : []
            return handle(type: .flagsChanged, event: e)
        }
        func tapCombo() {                       // 短按一次 fn + esc
            fnKey(true)
            key(53, down: true, fn: true)
            wait(0.05)
            key(53, down: false, fn: true)
            fnKey(false)
            wait(0.1)
        }
        func holdCombo(_ t: TimeInterval) {     // 按住 fn + esc 一段时间后松开
            fnKey(true)
            key(53, down: true, fn: true)
            wait(t)
            key(53, down: false, fn: true)
            fnKey(false)
        }

        let A: CGKeyCode = 0, ESC: CGKeyCode = 53

        check("未锁定：普通按键放行", !key(A, down: true) && !key(A, down: false))
        check("未锁定：单独 esc 放行", !key(ESC, down: true) && !key(ESC, down: false))
        check("未锁定：修饰键放行", !fnKey(true) && !fnKey(false))

        fnKey(true)
        check("fn + esc 按下被接管", key(ESC, down: true, fn: true))
        wait(1.0)
        check("按住 1 秒：尚未锁定", !locked)
        wait(1.3)
        check("按住 2 秒：已锁定", locked)
        check("锁定后长按中的 esc 重复事件被吞掉", key(ESC, down: true, fn: true, rep: true))
        check("esc 抬起被吞掉", key(ESC, down: false, fn: true))
        check("锁定：fn 抬起被吞掉", fnKey(false))

        check("锁定：普通按键被吞掉", key(A, down: true) && key(A, down: false))
        check("锁定：单独 esc 被吞掉", key(ESC, down: true) && key(ESC, down: false))
        check("锁定：单独 esc 不会解锁", locked)

        wait(kTripleWindow + 0.2)
        tapCombo()
        check("锁定：短按 1 次不解锁", locked)
        tapCombo()
        check("锁定：短按 2 次不解锁", locked)
        tapCombo()
        check("锁定：连按 3 次强制解锁", !locked)
        check("解锁后普通按键恢复", !key(A, down: true) && !key(A, down: false))

        wait(kTripleWindow + 0.2)
        tapCombo(); wait(1.0); tapCombo(); wait(1.0); tapCombo()
        check("间隔过长的 3 次短按不算连按（仍未锁定也不报错）", !locked)

        wait(kTripleWindow + 0.2)
        holdCombo(2.3)
        check("再次长按 2 秒：锁定", locked)
        wait(0.3)
        holdCombo(2.3)
        check("锁定后长按 2 秒：解锁", !locked)

        wait(kTripleWindow + 0.2)
        holdCombo(1.2)
        wait(1.5)
        check("提前松开 esc：不锁定", !locked)

        wait(kTripleWindow + 0.2)
        fnKey(true)
        key(ESC, down: true, fn: true)
        wait(1.0)
        fnKey(false)                            // 中途松开 fn
        wait(1.5)
        check("提前松开 fn：不锁定", !locked)
        check("松开 fn 后残留的 esc 重复事件不泄漏", key(ESC, down: true, rep: true))
        check("对应的 esc 抬起不泄漏", key(ESC, down: false))
        check("之后单独 esc 恢复正常", !key(ESC, down: true) && !key(ESC, down: false))

        wait(kTripleWindow + 0.2)
        fnKey(true)
        key(ESC, down: true, fn: true)          // 故意不发抬起事件（模拟事件丢失）
        fnKey(false)
        check("抬起事件丢失后，新的单独 esc 仍能放行", !key(ESC, down: true) && !key(ESC, down: false))

        print(failures == 0 ? "\n全部通过" : "\n失败 \(failures) 项")
        exit(failures == 0 ? 0 : 1)
    }

    func runSnapshots(to dir: String) {
        let base = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        muteSounds = true

        hud.showHolding(willLock: true, duration: 60, startFraction: 0.55)
        hud.snapshot(to: base.appendingPathComponent("1-holding.png"), barFraction: 0.55)
        setLocked(true, forced: false)
        hud.snapshot(to: base.appendingPathComponent("2-locked.png"))
        setLocked(false, forced: false)
        hud.snapshot(to: base.appendingPathComponent("3-unlocked.png"))
        setLocked(false, forced: true)
        hud.snapshot(to: base.appendingPathComponent("4-forced.png"))
        hud.showMessage(symbol: "hand.raised.fill", tint: .systemYellow,
                        title: "需要辅助功能权限",
                        subtitle: "系统设置 → 隐私与安全性 → 辅助功能\n打开「键盘锁」的开关")
        hud.snapshot(to: base.appendingPathComponent("5-permission.png"))
        exit(0)
    }
}
