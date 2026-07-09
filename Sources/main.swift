// Siriously — Services agent that presents the real (private) Writing Tools UI
// over the host app's selection and writes the result back in place.
//
// Flow per invocation:
//   1. AX: read the focused element, its selected text, and selection screen rect.
//   2. Seed an in-process NSTextView "client" with that text and present the private
//      WTWritingToolsViewController in an NSPopover anchored over the host selection
//      (a transparent overlay window is the anchor; the WT client view is separate).
//   3. When the user accepts (hooked via replaceSelectionWithText:), write the
//      client's full text back into the host element via AX — or, for apps AX can't
//      write to (Electron), offer it via a Copy alert. Then return focus to the host.
//
// Private interfaces: ../WritingToolsPrivate.h (bridging header).

import AppKit
import ApplicationServices
import ObjectiveC

// MARK: - Accessibility context

// The host app's pid = owner of the frontmost on-screen *normal* window that
// isn't us. `frontmostApplication` is unreliable here because the Services launch
// brings our agent forward before the service method runs. (Owner pid / layer
// don't require Screen Recording permission.)
func frontmostHostPid() -> pid_t? {
    let mypid = ProcessInfo.processInfo.processIdentifier
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
    for w in list {  // front-to-back order
        guard (w[kCGWindowLayer as String] as? Int) == 0,                 // normal window layer
              let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != mypid else { continue }
        return pid
    }
    return nil
}

struct AXContext {
    let element: AXUIElement
    let selectedText: String
    let cocoaRect: CGRect?         // selection bounds in Cocoa (bottom-left) screen coords
    let selectionRange: AXValue?   // original selected range, restored before write-back

    static func focusedElement(_ root: AXUIElement) -> AXUIElement? {
        var f: CFTypeRef?
        if AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &f) == .success,
           let f { return (f as! AXUIElement) }
        return nil
    }

    static func capture(pid: pid_t?) -> AXContext? {
        guard AXIsProcessTrusted() else { NSLog("WT: AX not trusted"); return nil }
        // Try the host app's focused element by pid first, then system-wide.
        var element = pid.flatMap { focusedElement(AXUIElementCreateApplication($0)) }
        if element == nil { element = focusedElement(AXUIElementCreateSystemWide()) }
        guard let element else { NSLog("WT: no focused element"); return nil }

        var t: CFTypeRef?
        let sel = (AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &t) == .success)
            ? (t as? String) : nil

        // Selection range (kept to restore before write-back) + its bounds.
        var rect: CGRect? = nil
        var range: AXValue? = nil
        var r: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &r) == .success,
           let rangeVal = r {
            range = (rangeVal as! AXValue)
            var b: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                          rangeVal, &b) == .success, let bv = b {
                var q = CGRect.zero
                // Chromium/Electron return a zero rect here — treat as "no rect"
                // so we fall back to anchoring at the host window center.
                if AXValueGetValue(bv as! AXValue, .cgRect, &q), q.width > 1, q.height > 1 {
                    rect = AXContext.toCocoa(q)
                }
            }
        }
        guard let text = sel, !text.isEmpty else { NSLog("WT: no AX selected text"); return nil }
        if let range, let cf = CFRangeFromAXValue(range) {
            NSLog("WT: captured selection loc=%ld len=%ld", cf.location, cf.length)
        }
        return AXContext(element: element, selectedText: text, cocoaRect: rect, selectionRange: range)
    }

    // Quartz global (top-left origin) → Cocoa (bottom-left origin) using the primary display.
    static func toCocoa(_ r: CGRect) -> CGRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.origin.x, y: primaryH - r.origin.y - r.height, width: r.width, height: r.height)
    }

    func writeBack(_ text: String) -> Bool {
        // Restore the original selection first — activating our agent/popover can
        // collapse the host selection, which would turn a replace into an append.
        if let selectionRange {
            let rr = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, selectionRange)
            NSLog("WT: restore selection range -> %d", rr.rawValue)
        }
        let ok = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        NSLog("WT: AX writeBack -> %d", ok.rawValue)
        guard ok == .success else { return false }

        // Chromium/Electron (e.g. Dia) return success but silently ignore the set.
        // Verify by re-reading the selection: if it's still the original text, the
        // write didn't take → report failure so we fall back to the Copy alert.
        if text != selectedText {
            var after: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &after) == .success,
               let a = after as? String, a == selectedText {
                NSLog("WT: AX writeBack was a no-op (host ignored it) — treating as failure")
                return false
            }
        }
        return true
    }
}

private func CFRangeFromAXValue(_ v: AXValue) -> CFRange? {
    var r = CFRange()
    return AXValueGetValue(v, .cfRange, &r) ? r : nil
}

// MARK: - Replace hook (instant write-back)

// WT calls -[WTWritingToolsRemoteViewController replaceSelectionWithText:] the
// moment the user accepts (Replace), carrying the replacement text. That's the
// precise, immediate signal — endWritingTools only fires on dismiss/cancel, so
// relying on it (or on the close-poll) added a ~2s lag before write-back.
var gOnReplace: ((String) -> Void)?
var gOnCopy: (() -> Void)?

func installReplaceHook() {
    guard let cls = NSClassFromString("WTWritingToolsRemoteViewController") else { NSLog("WT: replace hook: no class"); return }
    typealias Fn = @convention(c) (AnyObject, Selector, AnyObject) -> Void

    // Replace → write the result back to the host.
    let rSel = NSSelectorFromString("replaceSelectionWithText:")
    if let m = class_getInstanceMethod(cls, rSel) {
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject, AnyObject) -> Void = { obj, arg in
            orig(obj, rSel, arg)
            let s = (arg as? String) ?? (arg as? NSAttributedString)?.string
            if let s { NSLog("WT: replaceSelectionWithText (%d chars) -> write back", s.count); gOnReplace?(s) }
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    } else { NSLog("WT: replace hook: no method") }

    // Copy → the user wants the clipboard, not a replace; just return focus fast.
    let cSel = NSSelectorFromString("copyText:")
    if let m = class_getInstanceMethod(cls, cSel) {
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject, AnyObject) -> Void = { obj, arg in
            orig(obj, cSel, arg)
            NSLog("WT: copyText -> return focus")
            gOnCopy?()
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    } else { NSLog("WT: copy hook: no method") }

    NSLog("WT: replace/copy hooks installed")
}

// MARK: - Presenter

// Subclass so we learn the *exact* moment the session ends. WT calls
// endWritingTools on the real end (Replace/cancel) but NOT on the transient
// close used to switch tools — so this is a precise, immediate end signal
// (no polling delay before write-back).
final class HookedVC: WTWritingToolsViewController {
    var onEnd: (() -> Void)?
    override func endWritingTools() {
        super.endWritingTools()
        onEnd?()
    }
}

final class Presenter: NSObject, NSPopoverDelegate {
    var vc: WTWritingToolsViewController?
    var popover: NSPopover?
    var onDismiss: (() -> Void)?

    /// client: the in-process text view WT reads/edits.
    /// anchorView/anchorRect: where the popover is shown (over the host selection).
    func present(client: NSTextView, anchorView: NSView, anchorRect: CGRect, tool: Int, onDismiss: (() -> Void)?) {
        self.onDismiss = onDismiss

        let cfg = WTWritingToolsConfiguration(requestedTool: tool,
                                              positioningRect: anchorRect,
                                              positioningView: anchorView)
        cfg.textView = client                 // WT operates on this
        cfg.positioningView = anchorView       // popover anchors here (over host)
        cfg.positioningRect = anchorRect
        cfg.preferredEdge = .maxY

        let controller = HookedVC(configuration: cfg)
        controller.onEnd = { [weak self] in
            // Defer one tick so a just-accepted replacement has landed in `client`.
            DispatchQueue.main.async { self?.finishOnce() }
        }
        let pop = NSPopover()
        pop.behavior = .applicationDefined
        // The VC must be the popover delegate: when a tool is picked in the menu,
        // WT does a *transient* close (closePopoverTransientlyToShowTool:) and the
        // VC's own popoverDidClose: reopens it showing that tool. If we intercept
        // the delegate, that reopen never happens and the popover just dismisses.
        pop.delegate = controller
        pop.contentViewController = controller
        controller.popover = pop
        self.vc = controller
        self.popover = pop

        controller.setupRemoteViewIfNeeded {
            NSLog("WT: presenting tool %d anchored at %@", tool, NSStringFromRect(anchorRect))
            controller.show(in: pop, with: cfg)
            controller.activateRemoteView()
            self.startEndPolling()
        }
    }

    // Detect the *real* end of the session: the popover staying closed (a transient
    // close→reopen briefly flips isShown, which we ignore via the grace window).
    private var poll: Timer?
    private var finished = false
    private var closedAt: Date?

    private func startEndPolling() {
        poll?.invalidate(); closedAt = nil
        poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
            guard let self, let pop = self.popover else { t.invalidate(); return }
            if pop.isShown {
                self.closedAt = nil
            } else if let since = self.closedAt {
                // Grace must exceed the transient close→reopen gap (~0.6s) so a
                // tool pick in the menu isn't mistaken for a real dismissal.
                if Date().timeIntervalSince(since) > 1.5 { t.invalidate(); self.finishOnce() }
            } else {
                self.closedAt = Date()
            }
        }
    }

    private func finishOnce() {
        guard !finished else { return }
        finished = true
        poll?.invalidate(); poll = nil
        NSLog("WT: finishOnce -> write-back")
        // endWritingTools already fired (that's our primary trigger); don't recurse.
        let cb = onDismiss; onDismiss = nil
        cb?()
    }
}

// MARK: - Services provider

final class ServicesProvider: NSObject {
    private let warm = WTWritingToolsViewController(requestedTool: 0)
    private var sessions: [Session] = []
    private var warmReady = false
    private var pending: [() -> Void] = []

    override init() {
        super.init()
        warm.setupRemoteViewIfNeeded { [weak self] in
            NSLog("WT: view service pre-warmed")
            guard let self else { return }
            self.warmReady = true
            let q = self.pending; self.pending.removeAll()
            q.forEach { $0() }
        }
    }

    /// Run `block` once the view service is warm (so the popover isn't empty).
    private func whenWarm(_ block: @escaping () -> Void) {
        if warmReady { block() } else { pending.append(block) }
    }

    @objc func proofread(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) { run(pb, tool: 1) }
    @objc func rewrite(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>)   { run(pb, tool: 2) }
    @objc func friendly(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>)  { run(pb, tool: 11) }
    @objc func professional(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) { run(pb, tool: 12) }
    @objc func concise(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>)   { run(pb, tool: 13) }
    @objc func summary(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>)   { run(pb, tool: 21) }
    @objc func list(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>)      { run(pb, tool: 22) }
    @objc func table(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>)     { run(pb, tool: 23) }
    @objc func writingTools(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) { run(pb, tool: 0) }

    private func run(_ pb: NSPasteboard, tool: Int) {
        // Identify the host app via the window list (frontmostApplication is us by
        // the time the Services method runs), then capture its AX selection.
        let hostPid = frontmostHostPid()
        let hostApp = hostPid.flatMap { NSRunningApplication(processIdentifier: $0) }
            ?? NSWorkspace.shared.frontmostApplication
        NSLog("WT: host=%@", hostApp?.bundleIdentifier ?? "?")
        let ax = AXContext.capture(pid: hostPid ?? hostApp?.processIdentifier)
        let text = ax?.selectedText ?? pb.string(forType: .string)
        guard let text, !text.isEmpty else { NSLog("WT: no text"); return }

        let s = Session(text: text, ax: ax, tool: tool, hostApp: hostApp) { [weak self] s in
            self?.sessions.removeAll { $0 === s }
        }
        sessions.append(s)
        // Present only once the view service is ready.
        whenWarm { s.start() }
    }
}

/// One presentation: hosts the WT client text view over the host selection and
/// writes the result back via AX on dismissal.
final class Session {
    let text: String
    let ax: AXContext?
    let tool: Int
    let hostApp: NSRunningApplication?
    let cleanup: (Session) -> Void
    let presenter = Presenter()

    var clientWindow: NSWindow!
    var anchorWindow: NSWindow!
    var client: NSTextView!
    var replaced = false
    var writebackTimer: Timer?

    init(text: String, ax: AXContext?, tool: Int, hostApp: NSRunningApplication?, cleanup: @escaping (Session) -> Void) {
        self.text = text; self.ax = ax; self.tool = tool; self.hostApp = hostApp; self.cleanup = cleanup
    }

    // Called the instant the user clicks Replace (via the replaceSelectionWithText:
    // hook). The hook's argument is a context-relative fragment, NOT the full
    // replacement — so write back the *client's full text* instead, debounced so a
    // burst of replace calls collapses to one write-back of the final text.
    func applyReplacement(_ ignored: String) {
        replaced = true
        writebackTimer?.invalidate()
        writebackTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            guard let self else { return }
            let result = self.client.string
            NSLog("WT: write-back client text (%d chars)", (result as NSString).length)
            // Primary: AX (TextEdit/Notes/Safari/native). Fallback for apps AX
            // can't write to (Electron/Qt like VSCode): offer the result via alert.
            if let ax = self.ax, ax.writeBack(result) {
                self.returnFocusToHost()
            } else {
                NSLog("WT: AX unavailable — offering result via alert")
                self.showResultAlert(result)
            }
        }
    }

    // Promptly hand focus back to the host app so the user can keep typing.
    func returnFocusToHost() {
        anchorWindow?.orderOut(nil)
        clientWindow?.orderOut(nil)
        hostApp?.activate()
    }

    // Fallback for apps AX can't set text on (e.g. VSCode/Electron): show the
    // result and let the user choose to copy it (then paste manually).
    func showResultAlert(_ text: String) {
        anchorWindow?.orderOut(nil); clientWindow?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Writing Tools result"
        alert.informativeText = "This app doesn't let Writing Tools replace the text directly. Copy the result to the clipboard?"
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Cancel")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 150))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false; tv.isSelectable = true
        tv.string = text; tv.font = .systemFont(ofSize: 12)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.autoresizingMask = [.width, .height]
        scroll.documentView = tv
        alert.accessoryView = scroll

        if alert.runModal() == .alertFirstButtonReturn {
            let pb = NSPasteboard.general; pb.clearContents(); pb.setString(text, forType: .string)
            NSLog("WT: result copied to clipboard")
        }
        hostApp?.activate()
    }

    // Frame of the host's focused window (Cocoa coords) — available from the
    // app-level AX element even for apps that don't expose a focused *element*.
    func hostWindowRect() -> CGRect? {
        guard let pid = hostApp?.processIdentifier else { return nil }
        let appEl = AXUIElementCreateApplication(pid)
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &w) == .success,
              let win = w else { return nil }
        let winEl = win as! AXUIElement
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(winEl, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(winEl, kAXSizeAttribute as CFString, &s) == .success else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return AXContext.toCocoa(CGRect(origin: pt, size: sz))
    }

    func start() {
        NSApp.activate(ignoringOtherApps: true)
        gOnReplace = { [weak self] t in self?.applyReplacement(t) }
        gOnCopy = { [weak self] in self?.returnFocusToHost() }   // Copy → focus back fast

        // Anchor priority: the selection rect → host window center → mouse.
        let anchorRect: CGRect
        if let r = ax?.cocoaRect {
            anchorRect = r
        } else if let w = hostWindowRect() {
            anchorRect = CGRect(x: w.midX - 1, y: w.midY, width: 2, height: 16)
        } else {
            let m = NSEvent.mouseLocation
            anchorRect = CGRect(x: m.x, y: m.y - 16, width: 2, height: 16)
        }
        anchorWindow = NSWindow(contentRect: anchorRect, styleMask: .borderless, backing: .buffered, defer: false)
        anchorWindow.isOpaque = false
        anchorWindow.backgroundColor = .clear
        anchorWindow.ignoresMouseEvents = true
        anchorWindow.level = .popUpMenu
        let anchorView = NSView(frame: NSRect(origin: .zero, size: anchorRect.size))
        anchorWindow.contentView = anchorView
        anchorWindow.orderFrontRegardless()

        // In-process client text view WT reads/edits. Fully transparent and
        // off-screen — the popover is the only visible UI; the result is written
        // back to the host via AX. (A titled window gets repositioned on-screen by
        // the window manager, so use a borderless, alpha-0 window.)
        clientWindow = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 300),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        clientWindow.isOpaque = false
        clientWindow.alphaValue = 0.0
        clientWindow.hasShadow = false
        clientWindow.ignoresMouseEvents = true
        client = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        client.isEditable = true
        client.isRichText = false
        client.writingToolsBehavior = .complete
        client.string = text
        clientWindow.contentView = client
        clientWindow.orderFrontRegardless()
        client.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))

        presenter.present(client: client, anchorView: anchorView, anchorRect: anchorView.bounds, tool: tool) { [weak self] in
            self?.finish()
        }
    }

    func finish() {
        gOnReplace = nil; gOnCopy = nil
        // Write-back normally already happened via the replaceSelectionWithText:
        // hook. Fall back to the client text only if no Replace was observed (e.g.
        // a tool that applied differently).
        if !replaced {
            let result = client.string
            if result != text {
                if let ax, ax.writeBack(result) {} else {
                    let pb = NSPasteboard.general; pb.clearContents(); pb.setString(result, forType: .string)
                    NSLog("WT: fallback result left on clipboard")
                }
            }
        }
        anchorWindow?.close(); clientWindow?.close()
        if !replaced { hostApp?.activate() }   // return focus on plain dismiss too
        cleanup(self)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let provider = ServicesProvider()

    func applicationDidFinishLaunching(_ note: Notification) {
        // Prompt for Accessibility permission (needed to read selection + write back).
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        NSLog("WT: AX trusted = %d", trusted)

        installReplaceHook()
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()
        NSLog("WT: Services registered. Select text in any app → Services → Writing Tools.")
        // No status item: Services launches us as a transient background process,
        // and a status item would flash in/out per invocation. (A resident
        // LaunchAgent build can add one.)
    }
}

// Redirect NSLog/stderr to a log file so the background agent is debuggable
// regardless of how it was launched.
setbuf(stderr, nil)
freopen("\(NSHomeDirectory())/Library/Logs/Siriously.log", "a", stderr)
NSLog("WT: ==== agent starting ====")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
