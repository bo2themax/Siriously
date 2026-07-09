// explore.swift — tool-mapping helper. A window with a text view and buttons
// T0…T24; click one to present that requestedTool's Writing Tools UI on the
// selection, so you can see which value maps to which tool.
import AppKit

final class Explorer: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var window: NSWindow!
    var tv: NSTextView!
    var vc: WTWritingToolsViewController?
    var pop: NSPopover?
    let warm = WTWritingToolsViewController(requestedTool: 0)

    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Writing Tools — Tool Explorer"
        window.center()

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 180, width: 720, height: 340))
        scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true
        tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = true; tv.isRichText = false; tv.writingToolsBehavior = .complete
        tv.font = .systemFont(ofSize: 15)
        tv.string = "Me and him is going too the store yesterday, and they could of bought more then enough apples for the big party we is planning next weekend. Select text, then click a Tn button to see which tool that number maps to."
        tv.autoresizingMask = [.width, .height]
        scroll.documentView = tv
        window.contentView?.addSubview(scroll)

        // Buttons T0…T39 in rows of 13.
        for i in 0...39 {
            let b = NSButton(title: "T\(i)", target: self, action: #selector(tap(_:)))
            b.tag = i; b.bezelStyle = .rounded
            let col = i % 13, row = i / 13
            b.frame = NSRect(x: 20 + col * 56, y: 132 - row * 36, width: 52, height: 30)
            window.contentView?.addSubview(b)
        }

        window.makeKeyAndOrderFront(nil)
        tv.setSelectedRange(NSRange(location: 0, length: 60))
        NSApp.activate(ignoringOtherApps: true)
        warm.setupRemoteViewIfNeeded { NSLog("EXPLORE: warmed") }
    }

    @objc func tap(_ sender: NSButton) {
        let tool = sender.tag
        pop?.performClose(nil)
        let lm = tv.layoutManager!, tc = tv.textContainer!
        let gr = lm.glyphRange(forCharacterRange: tv.selectedRange(), actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: gr, in: tc)
        rect.origin.x += tv.textContainerOrigin.x; rect.origin.y += tv.textContainerOrigin.y

        let cfg = WTWritingToolsConfiguration(requestedTool: tool, positioningRect: rect, positioningView: tv)
        cfg.textView = tv; cfg.positioningView = tv; cfg.positioningRect = rect; cfg.preferredEdge = .maxY
        let controller = WTWritingToolsViewController(configuration: cfg)
        let p = NSPopover(); p.behavior = .applicationDefined; p.delegate = self
        p.contentViewController = controller; controller.popover = p
        self.vc = controller; self.pop = p
        NSLog("EXPLORE: requestedTool = %d", tool)
        controller.setupRemoteViewIfNeeded { controller.show(in: p, with: cfg); controller.activateRemoteView() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let d = Explorer()
app.delegate = d
app.setActivationPolicy(.regular)
app.run()
