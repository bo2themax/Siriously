// dump3.mm — map the WTWritingToolsConfiguration requestedTool enum by probing
// computed getters for each candidate value.
// build: clang++ -fobjc-arc -framework AppKit dump3.mm -o dump3 && ./dump3
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

@interface WTWritingToolsConfiguration : NSObject
- (instancetype)initWithRequestedTool:(NSInteger)t positioningRect:(CGRect)r positioningView:(NSView *)v;
- (NSInteger)requestedTool;
- (NSInteger)panelType;
- (NSInteger)writingToolsBehavior;
- (BOOL)isRequestingRewrite;
- (BOOL)hasOpenEndedAdjust;
- (BOOL)hasNSTextViewWithOpenPlaceholder;
- (id)supportedActions;
@end

int main(){ @autoreleasepool {
    [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/WritingTools.framework"] load];
    [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/WritingToolsUI.framework"] load];

    Class C = objc_getClass("WTWritingToolsConfiguration");
    if ([C respondsToSelector:@selector(allDefinedWTActions)]) {
        id actions = [C performSelector:@selector(allDefinedWTActions)];
        NSLog(@"allDefinedWTActions (%lu): %@", (unsigned long)[actions count], actions);
    }

    NSLog(@"tool | panelType | rewrite | openEndedAdjust | supportedActions");
    for (NSInteger t = 0; t <= 40; t++) {
        WTWritingToolsConfiguration *c =
            [[WTWritingToolsConfiguration alloc] initWithRequestedTool:t positioningRect:CGRectZero positioningView:nil];
        NSInteger panel = -1, behav = -1; BOOL rw = NO, adj = NO; id acts = nil;
        @try { panel = [c panelType]; } @catch(...){}
        @try { behav = [c writingToolsBehavior]; } @catch(...){}
        @try { rw = [c isRequestingRewrite]; } @catch(...){}
        @try { adj = [c hasOpenEndedAdjust]; } @catch(...){}
        @try { acts = [c supportedActions]; } @catch(...){}
        NSLog(@"%3ld  |   %3ld    |   %d    |     %d         | %@",
              (long)t, (long)panel, rw, adj,
              [acts respondsToSelector:@selector(count)] ? [NSString stringWithFormat:@"%lu", (unsigned long)[acts count]] : @"-");
    }
} return 0; }
