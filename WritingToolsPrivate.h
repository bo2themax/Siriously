// WritingToolsPrivate.h — bridging header declaring the private Writing Tools
// interfaces we drive from Swift. Interface-only: the implementations live in
// /System/Library/PrivateFrameworks/WritingTools{,UI}.framework, which we link
// against (or dlopen) at runtime. Signatures recovered by runtime introspection
// (see dump.mm / dump2.mm) on macOS 27.0 (26A5368g), arm64.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// ---- WritingTools.framework ------------------------------------------------

// Represents a Writing Tools session bound to a text-view delegate.
// initWithType: the WTSessionType (0 == default/compose+proofread session).
@interface WTSession : NSObject
- (instancetype)initWithType:(NSInteger)type textViewDelegate:(nullable id)delegate;
@property (nonatomic, readonly) NSInteger type;
@property (nonatomic, readonly) NSUUID *uuid;
@property (nonatomic) NSInteger requestedTool;
@end

// ---- WritingToolsUI.framework ----------------------------------------------

// The configuration object that fully describes a presentation request.
// requestedTool == 0 shows the full tool panel (Proofread/Rewrite/Summarize/…).
@interface WTWritingToolsConfiguration : NSObject
- (instancetype)initWithRequestedTool:(NSInteger)tool
                      positioningRect:(CGRect)positioningRect
                      positioningView:(nullable NSView *)positioningView;
- (instancetype)initWithRequestedTool:(NSInteger)tool
                               prompt:(nullable NSString *)prompt
                      positioningRect:(CGRect)positioningRect
                      positioningView:(nullable NSView *)positioningView;

// The source text surface. Set to a real NSTextView so AppKit's text
// integration provides the context and applies replacements.
@property (nonatomic, weak, nullable) NSView *textView;
@property (nonatomic, weak, nullable) NSView *positioningView;
@property (nonatomic) CGRect positioningRect;
@property (nonatomic) NSInteger requestedTool;
@property (nonatomic) NSRectEdge preferredEdge;
@property (nonatomic, strong, nullable) NSString *prompt;
@property (nonatomic, weak, nullable) id writingToolsDelegate;
@end

// The view controller that hosts the (out-of-process) Writing Tools UI.
// It is the NSPopover's delegate: its popoverDidClose: handles the transient
// close→reopen when a tool is picked in the menu.
@interface WTWritingToolsViewController : NSViewController <NSPopoverDelegate>
+ (BOOL)isAvailable;
+ (BOOL)isEnabled;
+ (BOOL)isEnhancedSiriAvailable;   // YES when "NewSiri" is the active assistant

- (instancetype)initWithConfiguration:(WTWritingToolsConfiguration *)configuration;
- (instancetype)initWithRequestedTool:(NSInteger)requestedTool;

// Present the panel. showInPopover: hosts the remote view in the given popover;
// showInPanelWithConfiguration: uses the system WTWritingToolsPanel instead.
- (void)showInPopover:(NSPopover *)popover withConfiguration:(WTWritingToolsConfiguration *)configuration;
- (void)showInPanelWithConfiguration:(WTWritingToolsConfiguration *)configuration;
- (void)showWritingTool:(NSInteger)tool;
- (void)updatePositioningRect:(CGRect)rect;

- (void)setupRemoteViewIfNeededWithCompletionHandler:(void (^)(void))handler;
- (void)activateRemoteView;
- (BOOL)performRequestedToolOnCurrentSession:(WTSession *)session;

@property (nonatomic, readonly) BOOL usesPanel;
@property (nonatomic, readonly) BOOL isActive;
@property (nonatomic, readonly, nullable) WTSession *currentSession;
@property (nonatomic, readonly, nullable) NSAttributedString *selectedText;
@property (nonatomic, strong, nullable) NSPopover *popover;

- (void)endWritingTools;
- (void)deactivate;
@end

NS_ASSUME_NONNULL_END
