// dump2.mm — dump WTWritingToolsConfiguration + the delegate protocols.
// build: clang++ -fobjc-arc -framework Foundation dump2.mm -o dump2 && ./dump2
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static void loadFW(const char *p){ [[NSBundle bundleWithPath:[NSString stringWithUTF8String:p]] load]; }

static void dumpClass(const char *name) {
    Class c = objc_getClass(name);
    printf("\n================ CLASS %s ================\n", name);
    if (!c) { printf("  (not found)\n"); return; }
    printf("// superclass: ");
    for (Class s = class_getSuperclass(c); s; s = class_getSuperclass(s)) printf("%s ", class_getName(s));
    printf("\n");
    unsigned int ic=0; Ivar *iv=class_copyIvarList(c,&ic);
    for(unsigned i=0;i<ic;i++) printf("  ivar  %-32s %s\n", ivar_getName(iv[i]), ivar_getTypeEncoding(iv[i])?:"?");
    free(iv);
    unsigned int cc=0; Method *cm=class_copyMethodList(object_getClass(c),&cc);
    for(unsigned i=0;i<cc;i++) printf("  +     %-46s %s\n", sel_getName(method_getName(cm[i])), method_getTypeEncoding(cm[i])?:"");
    free(cm);
    unsigned int mc=0; Method *m=class_copyMethodList(c,&mc);
    for(unsigned i=0;i<mc;i++) printf("  -     %-46s %s\n", sel_getName(method_getName(m[i])), method_getTypeEncoding(m[i])?:"");
    free(m);
}

static void dumpProto(const char *name) {
    Protocol *p = objc_getProtocol(name);
    printf("\n================ PROTOCOL %s ================\n", name);
    if (!p) { printf("  (not found)\n"); return; }
    struct objc_method_description *d; unsigned int n;
    for (int req=1; req>=0; req--) for (int inst=1; inst>=0; inst--) {
        d = protocol_copyMethodDescriptionList(p, req, inst, &n);
        for (unsigned i=0;i<n;i++)
            printf("  %c%c %-46s %s\n", inst?'-':'+', req?'!':'?',
                   sel_getName(d[i].name), d[i].types?:"");
        free(d);
    }
}

int main(){ @autoreleasepool{
    loadFW("/System/Library/PrivateFrameworks/WritingTools.framework");
    loadFW("/System/Library/PrivateFrameworks/WritingToolsUI.framework");
    dumpClass("WTWritingToolsConfiguration");
    dumpClass("WTWritingToolsController");   // had no own methods; check category/runtime
    dumpProto("WTTextViewDelegate_Proposed_v1");
    dumpProto("WTTextViewDelegate");
    dumpProto("WTWritingToolsDelegate");
    dumpProto("WTWritingToolsDelegate_Internal");
} return 0; }
