# Siriously — bring back Writing Tools on macOS 27 after enabling the new Siri

**Did Apple Intelligence Writing Tools disappear after you turned on the new Siri?**
When you enable the new Siri / Apple Intelligence assistant ("NewSiri") on macOS 27, the
**Writing Tools** popover — Proofread, Rewrite, Summarize, and the tone tools — vanishes:
the menu item is gone, and `Edit → Writing Tools` / right-click **just opens Siri**
instead. **Siriously restores the classic Writing Tools popover** and lets you keep using
Proofread and Rewrite on selected text — **without disabling the new Siri**.

Keywords: _Writing Tools missing / gone / not showing / greyed out on macOS 26–27,
Apple Intelligence Writing Tools disappeared after enabling Siri, how to get Writing Tools
back, restore Proofread and Rewrite, NewSiri, macOS Tahoe._

It works as a per-tool macOS **Services** agent: select text in any app →
**right-click → Services → Proofread / Rewrite / Siriously** → the real Writing Tools UI
runs on your selection and the result is written back in place.

---

## Requirements

Siriously only works on a Mac that **supports Apple Intelligence and has the new Siri /
Apple Intelligence assistant ("NewSiri") enabled**:

- **Apple Intelligence supported + set up** — Apple silicon, a supported region/language,
  and the on-device models downloaded. Writing Tools _is_ Apple Intelligence; without it
  the engine behind `WritingToolsViewService.xpc` won't serve requests and Siriously
  can't produce anything.
- **NewSiri enabled** — this is the whole point: enabling NewSiri is what removes/hijacks
  the built-in Writing Tools entry points, and Siriously brings the popover back. On a Mac
  _without_ NewSiri the system's own Writing Tools still work, so you don't need this.
- **macOS 27** (built and verified on 27.0, build 26A5368g, arm64) — it relies on
  private-framework details an OS update can change.
- **Accessibility permission** (to read the selection and write the result back in place).

If Apple Intelligence isn't available/enabled on the device, Siriously will just present
an empty/non-functional popover — there's no engine for it to talk to.

## Why Writing Tools disappears with the new Siri (macOS 27.0, build 26A5368g, arm64)

- The Writing Tools frameworks are fully present and functional with NewSiri on:
  `/System/Library/PrivateFrameworks/WritingTools.framework` (`WTSession`) and
  `WritingToolsUI.framework` (`WTWritingToolsViewController`, `WTWritingToolsConfiguration`,
  `WTWritingToolsPanel`, the out-of-process `WritingToolsViewService.xpc`, …).
- `+[WTWritingToolsViewController isAvailable] == isEnabled == 1` and
  `isEnhancedSiriAvailable == 1` — i.e. the engine still serves requests; NewSiri only
  changed the **client entry points**:
  - The public `-[NSResponder showWritingTools:]` action is **hijacked → opens Siri**.
  - The affordance/menu surfaced by `NSWritingToolsCoordinator` is suppressed.
- So we drive the **private** `WTWritingToolsViewController` directly, which still talks
  to the entitled `WritingToolsViewService.xpc` and returns real results.

## How it works

1. **Trigger** — a macOS _Service_ (`NSApp.servicesProvider`), one item per tool.
2. **Capture** — on invoke, read the host's focused element, selected text, and the
   selection's on-screen rect via the **Accessibility API** (`AXContext`).
3. **Present** — seed an in-process `NSTextView` (the WT _client_, kept transparent/
   off-screen) with the text and present `WTWritingToolsViewController` in an
   `NSPopover` whose anchor is a transparent overlay window placed **over the host
   selection** (the popover anchor view and the WT client view are separate config
   fields, so the popover floats over the host while WT operates on our view).
4. **Write back** — the instant the user accepts (hooked via
   `-[WTWritingToolsRemoteViewController replaceSelectionWithText:]`), restore the
   original selection range and set the host element's selected text via AX
   (`AXUIElementSetAttributeValue`), then promptly reactivate the host app so the user
   can keep typing. For apps AX can't write to (Electron/Qt such as VSCode — no AX
   focused element), show an alert with the result and a **Copy** button instead.

Reliability details handled: the view service is **pre-warmed** and presentation is
**gated on warm-up** (no empty popover); the original selection **range is restored**
before write-back (fixes append-instead-of-replace); the popover uses
`.applicationDefined` (the out-of-process view would dismiss a `.transient` popover on
first click); the **`WTWritingToolsViewController` is set as the popover delegate** so
that picking a tool in the menu (which triggers a _transient_
`closePopoverTransientlyToShowTool:` close) lets the VC **reopen** the popover showing
that tool instead of tearing down — the session end is detected by polling (popover
stays closed past a grace window that exceeds the transient close→reopen gap).

## Install

```sh
./install.sh              # build → /Applications, register Services
./install.sh --resident   # also install a login LaunchAgent (keeps the WT service warm)
```

Then:

1. **System Settings → Privacy & Security → Accessibility** → enable _Siriously_
   (needed to read the selection and write the result back).
2. **System Settings → Keyboard → Keyboard Shortcuts → Services → Text** → tick the
   Siriously items you want. All the tools ship as separate items, so pick the few you
   actually use — e.g. **Proofread** and **Siriously** (the full menu):

   <img src="docs/screenshots/services-settings.png" alt="Enabling Siriously items under System Settings → Keyboard Shortcuts → Services → Text" width="420">

Use: select text → **right-click → Services → Proofread / Rewrite / Siriously**, or use
the app menu's **Services** submenu:

<p>
  <img src="docs/screenshots/services-context-menu.png" alt="Siriously items in the right-click Services menu on selected text" width="300">
  &nbsp;
  <img src="docs/screenshots/services-menu.png" alt="Siriously items in an app's Services submenu" width="270">
</p>

Uninstall: `./uninstall.sh`

## Building & signing

`build-app.sh` picks a signing identity in this order:

1. **`WT_SIGN_IDENTITY`** env — an explicit identity (e.g. `Developer ID Application: …`)
   for distribution; the app is signed with the **hardened runtime** so it can be notarized.
2. **`WTReviveDev`** — a stable local self-signed identity (recommended for development):
   the Accessibility/TCC grant then **persists across rebuilds** instead of resetting each
   time. Create it once:
   ```sh
   openssl req -x509 -newkey rsa:2048 -keyout k.pem -out c.pem -days 3650 -nodes \
     -subj "/CN=WTReviveDev" -addext "extendedKeyUsage=critical,codeSigning" \
     -addext "basicConstraints=critical,CA:false"
   openssl pkcs12 -export -legacy -inkey k.pem -in c.pem -out id.p12 -passout pass:wt -name WTReviveDev
   security import id.p12 -k ~/Library/Keychains/login.keychain-db -P wt -T /usr/bin/codesign
   rm k.pem c.pem id.p12
   ```
3. **ad-hoc** — anything else (AX grant resets each rebuild).

### GitHub Actions (`.github/workflows/build.yml`)

Every push/PR builds the `.app` (**ad-hoc by default** — no secrets needed) and uploads it
as a workflow artifact; pushing a `v*` tag also attaches it to a Release. Custom signing and
notarization are opt-in via repo **secrets**:

| secret                                                        | purpose                                                                                   |
| ------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `MACOS_CERTIFICATE_P12_BASE64` / `MACOS_CERTIFICATE_PASSWORD` | Developer ID cert (base64 `.p12` + its export password) → signs with the hardened runtime |
| `MACOS_SIGN_IDENTITY`                                         | optional exact identity name (auto-detected from the cert otherwise)                      |
| `AC_API_KEY_P8_BASE64` / `AC_API_KEY_ID` / `AC_API_ISSUER_ID` | App Store Connect API key → notarize + staple                                             |

With no secrets set, the workflow still produces a working ad-hoc build. Note: the runner
must ship the Writing Tools private frameworks (macOS 15.1+); use a macOS 26/Xcode 26 runner
for the Icon Composer icon and the real macOS 27 SDK once available.

## Tools / the `requestedTool` enum

Confirmed by testing:

| value   | tool                                 |
| ------- | ------------------------------------ |
| 0       | **Menu** (full tool list)            |
| 1       | **Proofread**                        |
| 2       | **Rewrite**                          |
| 11      | **Friendly** (tone)                  |
| 12      | **Professional** (tone)              |
| 13      | **Concise** (tone)                   |
| 21      | **Summary**                          |
| 22      | **List**                             |
| 23      | **Table**                            |
| 3/4     | Proofread variant / invalid          |
| Compose | not yet mapped (~30s, still hunting) |

Exposed as Services items: **Proofread, Rewrite, Friendly, Professional, Concise,
Summary, List, Table** (direct), plus **Siriously** (0 — the full menu).

**The "Siriously" item is the complete solution** — it shows the full tool list and,
because the VC is the popover delegate, **picking any tool there works** (the transient
close→reopen dispatches it). The other items are quick-access shortcuts to specific tools.

### Adding more direct (quick-access) items

If you want another tool as its own Services item (instead of via the Menu): run
`./explore.sh` (a window with **T0…T39** buttons), click each to see which value maps to
which tool, then add a `@objc func` in `Sources/main.swift` calling `run(pb, tool: N)` plus
a matching `NSServices` entry in `build-app.sh`.

## Files

| file                                | purpose                                                              |
| ----------------------------------- | -------------------------------------------------------------------- |
| `Sources/main.swift`                | the Services agent (AX capture, presenter, write-back)               |
| `WritingToolsPrivate.h`             | bridging header — private WT interfaces (from runtime introspection) |
| `build-app.sh`                      | build + sign + register the `.app`                                   |
| `install.sh` / `uninstall.sh`       | install to /Applications (+ optional LaunchAgent)                    |
| `explore.sh` / `explore.swift`      | tool-mapping helper (T0…T39 buttons)                                 |
| `dump.mm` / `dump2.mm` / `dump3.mm` | research artifacts: runtime class/selector/enum dumps                |
| `Siriously.icon`                    | Icon Composer source (compiled by `actool` in `build-app.sh`)        |
| `FINDINGS.md`                       | reverse-engineering knowledge base (private API, flows, gotchas)     |

## Limitations

- **No inline rewrite animation in the host.** WT renders into _our_ in-process text
  view; we bridge the final result to the host via AX. The animation/preview happen in
  our (hidden) view, so the host just receives the final text.
- **Transient instances.** macOS launches a Services provider on demand and lets it
  exit after; `--resident` keeps one warm to avoid cold-start.
- **AX-dependent.** Native apps (TextEdit/Notes/Safari/…) replace in place via AX. Apps
  with no AX text support (VSCode/Electron) can't be written to — the result is offered
  via a Copy alert instead, and the popover anchors at the focused window's center
  (no selection rect is available). Services items register with broad send types and no
  return type, so they appear for any text selection (editable or not).
- **Private API / OS-version-bound.** Selectors were recovered on 26A5368g; an OS update
  could change them. Re-run `dump.mm`/`dump2.mm` to refresh.

## License

[MIT](LICENSE).

## Disclaimer

Siriously is an unofficial hack that drives **private** Apple frameworks. It is **not
affiliated with, endorsed by, or supported by Apple**, and "Apple Intelligence", "Siri"
and "Writing Tools" are trademarks of Apple Inc. Because it relies on private, undocumented
API, it can break with any macOS update and cannot be shipped on the Mac App Store. Use at
your own risk. Provided as-is, without warranty.
