#import "BrightnessBridge.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <IOKit/hidsystem/IOHIDServiceClient.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>
#import <CoreGraphics/CoreGraphics.h>

static id dfrClient = nil;
static id coreClient = nil;
static int displayID = -1;

double STBMainDisplayBrightness(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY);
    if (!handle) return -1;
    typedef int (*GetBrightness)(uint32_t, float *);
    GetBrightness get = (GetBrightness)dlsym(handle, "DisplayServicesGetBrightness");
    if (!get) return -1;
    float level = -1;
    int result = get(CGMainDisplayID(), &level);
    return result == 0 && isfinite(level) && level >= 0 && level <= 1 ? level : -1;
}

static id coreBrightnessClient(void) {
    if (coreClient) return coreClient;
    if (!dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)) return nil;
    Class cls = objc_getClass("BrightnessSystemClient");
    if (!cls) return nil;
    coreClient = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(new));
    return coreClient;
}

BOOL STBBrightnessConnect(void) {
    dfrClient = nil; coreClient = nil; displayID = -1;
    if (!dlopen("/System/Library/PrivateFrameworks/DFRBrightness.framework/DFRBrightness", RTLD_LAZY)) return NO;
    Class cls = objc_getClass("DFRBrightnessClient");
    if (!cls) return NO;
    IOHIDEventSystemClientRef system = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
    CFArrayRef services = system ? IOHIDEventSystemClientCopyServices(system) : NULL;
    if (!services) { if (system) CFRelease(system); return NO; }
    id client = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(new));
    BOOL ready = NO;
    if (client && [client respondsToSelector:sel_registerName("initializeHID")] &&
        [client respondsToSelector:sel_registerName("addDFRService:")] &&
        [client respondsToSelector:sel_registerName("getDFRDisplayID")] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(client, sel_registerName("initializeHID"))) {
        for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
            IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
            CFTypeRef product = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
            BOOL isTouchBar = product && [(__bridge id)product isKindOfClass:[NSString class]] && [(__bridge NSString *)product isEqualToString:@"TouchBarUserDevice"];
            if (product) CFRelease(product);
            if (!isTouchBar) continue;
            BOOL added = ((BOOL (*)(id, SEL, IOHIDServiceClientRef))objc_msgSend)(client, sel_registerName("addDFRService:"), service);
            int identifier = ((int (*)(id, SEL))objc_msgSend)(client, sel_registerName("getDFRDisplayID"));
            if (added && identifier >= 0) { dfrClient = client; displayID = identifier; ready = YES; }
            break;
        }
    }
    CFRelease(services); CFRelease(system);
    return ready && coreBrightnessClient() != nil;
}

NSInteger STBBrightnessDisplayState(void) {
    SEL get = sel_registerName("copyPropertyForKey:");
    if (!dfrClient || ![dfrClient respondsToSelector:get]) return -1;
    id value = ((id (*)(id, SEL, id))objc_msgSend)(dfrClient, get, @"DFRDisplayState");
    return [value isKindOfClass:[NSNumber class]] ? [value integerValue] : -1;
}

double STBBrightnessCurrent(void) {
    SEL get = sel_registerName("copyPropertyForKey:andDisplay:");
    id client = coreBrightnessClient();
    if (!client || displayID < 0 || ![client respondsToSelector:get]) return -1;
    id props = ((id (*)(id, SEL, id, uint64_t))objc_msgSend)(client, get, @"DisplayBrightness", (uint64_t)displayID);
    id value = [props isKindOfClass:[NSDictionary class]] ? props[@"Brightness"] : nil;
    double level = [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : -1;
    return isfinite(level) && level >= 0 && level <= 1 ? level : -1;
}

BOOL STBBrightnessSet(double level) {
    if (!isfinite(level) || level < 0 || level > 1) return NO;
    SEL set = sel_registerName("setProperty:withKey:andDisplay:");
    id client = coreBrightnessClient();
    if (!client || displayID < 0 || ![client respondsToSelector:set]) return NO;
    NSDictionary *properties = @{@"Brightness": @(level), @"Commit": @NO, @"CommitType": @0};
    return ((BOOL (*)(id, SEL, id, id, uint64_t))objc_msgSend)(client, set, properties, @"DisplayBrightness", (uint64_t)displayID);
}
