#import "TouchBarBridge.h"
#import <objc/message.h>
#import <dlfcn.h>
BOOL STBPresent(NSTouchBar *bar) {
    SEL selector = NSSelectorFromString(@"presentSystemModalTouchBar:systemTrayItemIdentifier:");
    if (![NSTouchBar respondsToSelector:selector]) return NO;
    void *handle = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY);
    if (handle) {
        void (*closeBox)(BOOL) = dlsym(handle, "DFRSystemModalShowsCloseBoxWhenFrontMost");
        if (closeBox) closeBox(YES);
    }
    ((void (*)(id, SEL, id, id))objc_msgSend)(NSTouchBar.class, selector, bar, nil);
    return YES;
}
void STBDismiss(NSTouchBar *bar) {
    SEL selector = NSSelectorFromString(@"dismissSystemModalTouchBar:");
    if ([NSTouchBar respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(NSTouchBar.class, selector, bar);
}
