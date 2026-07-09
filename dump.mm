// dump.mm — runtime introspector for the private Writing Tools classes.
// Loads WritingTools.framework + WritingToolsUI.framework and prints method
// lists / ivars / protocols for the classes we need to drive the popover.
//
// build: clang++ -fobjc-arc -framework Foundation dump.mm -o dump && ./dump
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static void loadFW(const char *path) {
    NSBundle *b = [NSBundle bundleWithPath:[NSString stringWithUTF8String:path]];
    BOOL ok = [b load];
    fprintf(stderr, "load %s -> %s\n", path, ok ? "OK" : "FAIL");
}

static void dumpClass(const char *name) {
    Class c = objc_getClass(name);
    printf("\n================ %s ================\n", name);
    if (!c) { printf("  (class not found)\n"); return; }

    // superclass chain
    printf("// superclass: ");
    for (Class s = class_getSuperclass(c); s; s = class_getSuperclass(s))
        printf("%s%s", class_getName(s), class_getSuperclass(s) ? " : " : "");
    printf("\n");

    // adopted protocols
    unsigned int pc = 0;
    Protocol * __unsafe_unretained *protos = class_copyProtocolList(c, &pc);
    if (pc) { printf("// protocols:"); for (unsigned i=0;i<pc;i++) printf(" %s", protocol_getName(protos[i])); printf("\n"); }
    free(protos);

    // ivars
    unsigned int ic = 0;
    Ivar *ivars = class_copyIvarList(c, &ic);
    for (unsigned i=0;i<ic;i++)
        printf("  ivar  %-34s %s\n", ivar_getName(ivars[i]), ivar_getTypeEncoding(ivars[i]) ?: "?");
    free(ivars);

    // class (+) methods
    unsigned int mcc = 0;
    Method *cm = class_copyMethodList(object_getClass(c), &mcc);
    for (unsigned i=0;i<mcc;i++) {
        const char *t = method_getTypeEncoding(cm[i]);
        printf("  +     %-44s  %s\n", sel_getName(method_getName(cm[i])), t ?: "");
    }
    free(cm);

    // instance (-) methods
    unsigned int mc = 0;
    Method *m = class_copyMethodList(c, &mc);
    for (unsigned i=0;i<mc;i++) {
        const char *t = method_getTypeEncoding(m[i]);
        printf("  -     %-44s  %s\n", sel_getName(method_getName(m[i])), t ?: "");
    }
    free(m);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        loadFW("/System/Library/PrivateFrameworks/WritingTools.framework");
        loadFW("/System/Library/PrivateFrameworks/WritingToolsUI.framework");

        const char *classes[] = {
            "WTSession",
            "WTWritingToolsViewController",
            "WTWritingToolsController",
            "WTWritingToolsPanel",
            "WTWritingToolsRemoteViewController",
            "WTUIAttributedStringController",
            "WTAffordanceUIController",
        };
        for (auto n : classes) dumpClass(n);
    }
    return 0;
}
