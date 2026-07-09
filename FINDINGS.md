# Writing Tools internals — reverse-engineering notes

Knowledge base from reviving the Writing Tools popover on **macOS 27.0 (build
26A5368g, arm64)** with the new Siri / Apple Intelligence assistant ("NewSiri")
enabled. Everything here was recovered by runtime introspection (`dump*.mm`) and
behavioural tracing (NSPopover swizzles + private-method hooks); it is OS-version
bound — re-derive after major updates.

## Frameworks

| path                                                                 | role                                                                                                                                                |
| -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/System/Library/PrivateFrameworks/WritingTools.framework`           | `WTSession` (session model)                                                                                                                         |
| `/System/Library/PrivateFrameworks/WritingToolsUI.framework`         | the UI: `WTWritingToolsViewController`, `WTWritingToolsConfiguration`, `WTWritingToolsRemoteViewController`, `WTWritingToolsPanel`, `WTAffordance*` |
| `…/WritingToolsUI.framework/XPCServices/WritingToolsViewService.xpc` | the **out-of-process** view service; holds the entitled `com.apple.generativeexperiences.*` keys and talks to the AI backend                        |

Binaries are dyld-shared-cache resident (on-disk files are stubs). Dump classes by
**runtime introspection** (`dlopen` + `objc_copyMethodList`, see `dump.mm`/`dump2.mm`),
not `nm`/`class-dump`. `dyld_info -objc` refuses cache-resident images.

## The NewSiri gate is client-side

- `+[WTWritingToolsViewController isAvailable]`, `+isEnabled`, `+isEnhancedSiriAvailable`
  all return **1** with NewSiri on — the engine still serves requests.
- What NewSiri changed are the **entry points**:
  - `-[NSResponder showWritingTools:]` (public, macOS 15.2+) is **hijacked → opens Siri**.
  - The `NSWritingToolsCoordinator` affordance/menu is suppressed.
- ⇒ Bypass the public entry: instantiate the private VC directly. It still connects to
  the entitled `WritingToolsViewService.xpc`, so results come back.

## Presentation recipe

```
cfg = [[WTWritingToolsConfiguration alloc] initWithRequestedTool:tool
          positioningRect:rect positioningView:anchorView]
cfg.textView = clientTextView        // WT reads/edits this in-process NSTextView
cfg.positioningView = anchorView     // popover anchors here (can be a separate view!)
cfg.positioningRect = rect
cfg.preferredEdge = NSMaxYEdge
vc  = [[WTWritingToolsViewController alloc] initWithConfiguration:cfg]
pop = NSPopover(); pop.behavior = .applicationDefined; pop.contentViewController = vc
vc.popover = pop
[vc setupRemoteViewIfNeeded:^{ [vc showInPopover:pop withConfiguration:cfg]; [vc activateRemoteView]; }]
```

Key facts:

- **`cfg.textView` and `cfg.positioningView` are independent** — WT operates on the
  text view while the popover floats wherever the anchor view is. That's how we run WT
  on a hidden client view but show the popover over the host app's selection.
- **`showInPanelWithConfiguration:`** uses the system `WTWritingToolsPanel` (free-floating);
  **`showInPopover:withConfiguration:`** uses a popover you supply (must have
  `contentViewController = vc`, or it throws "contentViewController is nil").
- Present **only after `setupRemoteViewIfNeeded`'s completion** AND after the view
  service is warm, or the popover is empty (cold-start race).

## requestedTool enum (confirmed)

`0` = Menu (full tool list), `1` = Proofread, `2` = Rewrite, `3` = Proofread variant,
`4` = invalid/error, `5–9` fall through to the Menu. Summary/Key Points/List/Table/
Compose live at other values — but **the Menu (0) reaches all of them**, so they don't
need mapping. (Tools don't auto-apply, so they can't be mapped headlessly.)

## Interaction flow (who calls what)

The popover delegate **must be the `WTWritingToolsViewController`** — it manages the
lifecycle. Hooked callbacks on `WTWritingToolsRemoteViewController` (the host-side
remote VC, owned by the VC):

- **Pick a tool in the Menu** → `closePopoverTransientlyToShowTool:(NSInteger)` → the
  popover does a _transient_ `-[NSPopover close]` (reason `Standard`), then the VC's own
  `popoverDidClose:` **reopens** it via `showWritingTool:`. If you steal the popover
  delegate, the reopen never happens and the popover just dies. ← the menu-dispatch bug.
- **Replace** → `replaceSelectionWithText:(id)` — fires the instant the user accepts.
  The argument is a _context-relative fragment_, not the full text; read the client text
  view's full `string` instead. This is the precise, immediate write-back trigger.
- **Copy** → `copyText:(id)` — user wants the clipboard; no write-back.
- **Dismiss/cancel** → `endWritingTools` (on both the VC and the remote VC). Does **not**
  fire on Replace, and does **not** fire on the transient tool-switch close.

End-of-session detection: hook `endWritingTools` (primary, immediate) + poll the
popover's `isShown` as a safety net with a grace window > the transient close→reopen gap
(~0.6s; we use 1.5s).

## Accessibility (host I/O)

- **Read:** system-wide `AXUIElementCreateSystemWide()` → `kAXFocusedUIElementAttribute`
  → `kAXSelectedTextAttribute` (text), `kAXSelectedTextRangeAttribute` (range, kept to
  restore), `kAXBoundsForRangeParameterizedAttribute` (selection screen rect).
- **Write:** restore the original `kAXSelectedTextRange` first (activating our agent can
  collapse the host selection → otherwise the set _appends_), then set
  `kAXSelectedTextAttribute`.
- **Coordinate flip:** AX/Quartz are top-left-origin global; Cocoa is bottom-left.
  `cocoaY = primaryScreenHeight − axY − height`.
- **Electron/Qt (VSCode):** no AX focused element and AX text isn't writable → fall back
  to a Copy alert; anchor at the focused **window** rect (`AXUIElementCreateApplication(pid)`
  → `kAXFocusedWindow` → position/size), which is available even when the element isn't.

## Reliability gotchas

- **Empty popover** = presenting before the view service is warm → pre-warm a throwaway
  VC at launch and gate presentation on warm.
- **Transient popover dismisses on first click** into the out-of-process view → use
  `.applicationDefined`.
- **Hidden client window**: a _titled_ off-screen window gets repositioned on-screen by
  the window manager → use a borderless, `alphaValue = 0` window.
- **Focus**: reactivate the captured `hostApp` right after Replace/Copy so focus returns
  promptly (noticeable on long replacements).

## Services nuances

- macOS launches a Services provider **on demand as a transient process** (handles one
  request, then exits). `LSMultipleInstancesProhibited` does **not** make it reuse a
  resident instance for the Services path. Hence the per-invocation cold-start (mitigated
  by warm-gate); a login LaunchAgent keeps the shared service warm.
- We write back via **AX, not the Services return pasteboard** — so drop `NSReturnTypes`
  (it only _restricts_ where the item appears) and broaden `NSSendTypes`; the items then
  show for any text selection, editable or not.

## Signing / TCC

Ad-hoc signatures change cdhash every build → the Accessibility grant resets each
rebuild. Sign with a **stable self-signed identity** (`WTReviveDev`, created in the login
keychain; codesign accepts it even though it's untrusted) → the grant persists.

## Re-deriving after an OS update

1. `dump.mm` / `dump2.mm` — class/ivar/method + protocol dumps (runtime introspection).
2. `dump3.mm` — probe `requestedTool` groupings.
3. Behavioural tracing: swizzle `-[NSPopover close]`/`performClose:` and hook the private
   `WTWritingToolsRemoteViewController` callbacks to watch the click→close→reopen flow.
   (This scaffolding was removed from `main.swift` after the flow was understood — see
   git history for the `WT_DIAG` version.)
