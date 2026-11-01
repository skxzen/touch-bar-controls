#import <AppKit/AppKit.h>
BOOL STBPresent(NSTouchBar *bar);
void STBDismiss(NSTouchBar *bar);

BOOL STBBrightnessConnect(void);
NSInteger STBBrightnessDisplayState(void);
double STBBrightnessCurrent(void);
BOOL STBBrightnessSet(double level);
double STBMainDisplayBrightness(void);
