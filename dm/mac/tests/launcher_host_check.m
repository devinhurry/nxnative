// Shared production launcher, followed by its in-process game settings sheet.
// Synthetic resources and runtime setters only; no game or GPU host is run.
#import <AppKit/AppKit.h>
#import <objc/message.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int dm_mac_launcher(void);
int dm_mac_show_game_settings(void *, void (*)(void));
static int applied, failed, timed_out;

int dm_launcher_setting_is_live(const char *key) { return !strcmp(key, "DM_RUMBLE"); }
int dm_launcher_setting_apply(const char *key, const char *value) {
    if (!dm_launcher_setting_is_live(key)) return 0;
    applied++;
    return setenv(key, value, 1) ? -1 : 1;
}

static void check(BOOL ok, const char *message) {
    printf("%s: %s\n", ok ? "PASS" : "FAIL", message);
    if (!ok) failed++;
}

static id axValue(id node, SEL selector) {
    if (!node || ![node respondsToSelector:selector]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(node, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static NSArray *axChildren(id node) {
    id children = axValue(node, @selector(accessibilityChildren));
    if (![children isKindOfClass:NSArray.class]) return @[];
    @try { return NSAccessibilityUnignoredChildren(children) ?: @[]; }
    @catch (__unused NSException *exception) { return children; }
}

static BOOL pressAX(id node, NSString *identifier, NSString *label, NSString *role,
                    NSHashTable *visited, NSUInteger depth) {
    if (!node || depth > 128 || [visited containsObject:node]) return NO;
    [visited addObject:node];
    NSString *nodeID = axValue(node, @selector(accessibilityIdentifier));
    NSString *nodeLabel = axValue(node, @selector(accessibilityLabel));
    if (![nodeLabel isKindOfClass:NSString.class] || !nodeLabel.length)
        nodeLabel = axValue(node, @selector(accessibilityTitle));
    NSString *nodeRole = axValue(node, @selector(accessibilityRole));
    BOOL matches = (!identifier || [nodeID isEqual:identifier]) &&
        (!label || ([nodeLabel isKindOfClass:NSString.class] && [nodeLabel hasPrefix:label])) &&
        (!role || [nodeRole isEqual:role]);
    if (matches && [node respondsToSelector:@selector(accessibilityPerformPress)]) {
        @try { if ([node accessibilityPerformPress]) return YES; }
        @catch (__unused NSException *exception) { }
    }
    for (id child in axChildren(node))
        if (pressAX(child, identifier, label, role, visited, depth + 1)) return YES;
    return NO;
}

static BOOL press(id root, NSString *identifier, NSString *label, NSString *role) {
    NSHashTable *visited = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
    return pressAX(root, identifier, label, role, visited, 0);
}

static NSOutlineView *findOutline(NSView *view) {
    if ([view isKindOfClass:NSOutlineView.class]) return (NSOutlineView *)view;
    for (NSView *child in view.subviews) {
        NSOutlineView *found = findOutline(child);
        if (found) return found;
    }
    return nil;
}

static BOOL selectControlsNativeRow(NSWindow *window) {
    NSOutlineView *outline = findOutline(window.contentView);
    if (!outline || outline.numberOfRows < 2 || !outline.window) return NO;
    // The launcher's first section is Game and its second is Controls. Select the live native AX outline row;
    // the following heading check verifies that List(selection:) updated the SwiftUI state.
    [outline selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
    return outline.selectedRow == 1;
}

static BOOL hasAXLabel(id node, NSString *label, NSString *role, NSHashTable *visited, NSUInteger depth) {
    if (!node || depth > 128 || [visited containsObject:node]) return NO;
    [visited addObject:node];
    NSString *nodeLabel = axValue(node, @selector(accessibilityLabel));
    NSString *nodeRole = axValue(node, @selector(accessibilityRole));
    if ((!label || ([nodeLabel isKindOfClass:NSString.class] && [nodeLabel isEqual:label])) &&
        (!role || [nodeRole isEqual:role])) return YES;
    for (id child in axChildren(node))
        if (hasAXLabel(child, label, role, visited, depth + 1)) return YES;
    return NO;
}

static BOOL controlsHeadingVisible(NSWindow *sheet) {
    NSHashTable *visited = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
    return hasAXLabel(sheet, @"Controls", NSAccessibilityHeadingRole, visited, 0);
}

static void dumpAX(id node, int depth, NSHashTable *visited) {
    if (!node || depth > 256 || [visited containsObject:node]) return;
    [visited addObject:node];
    NSString *identifier = axValue(node, @selector(accessibilityIdentifier));
    NSString *label = axValue(node, @selector(accessibilityLabel));
    NSString *title = axValue(node, @selector(accessibilityTitle));
    NSString *role = axValue(node, @selector(accessibilityRole));
    NSArray *actions = axValue(node, @selector(accessibilityActionNames));
    fprintf(stderr, "AX %d <%s> %s id=%s label=%s title=%s actions=%s\n", depth,
            NSStringFromClass([node class]).UTF8String ?: "?",
            role.UTF8String ?: "(null)", identifier.UTF8String ?: "(null)",
            label.UTF8String ?: "(null)", title.UTF8String ?: "(null)", actions.description.UTF8String ?: "(null)");
    for (id child in axChildren(node)) dumpAX(child, depth + 1, visited);
}

static void dumpHierarchy(id root) {
    NSHashTable *visited = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
    dumpAX(root, 0, visited);
}

static void stopRunLoop(void) {
    [NSApp stop:nil];
    [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint
        modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO];
}

static void waitFailed(NSWindow *root, NSString *what) {
    fprintf(stderr, "FAIL: timed out waiting for %s; accessibility hierarchy follows\n", what.UTF8String);
    dumpHierarchy(root);
    check(NO, what.UTF8String);
    timed_out = 1;
    stopRunLoop();
}

static void waitForPress(NSWindow *root, NSString *identifier, NSString *label, NSString *role,
                         const char *message, void (^next)(void)) {
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 4.0;
    NSString *description = [NSString stringWithUTF8String:message];
    __block void (^poll)(void);
    poll = ^{
        if (press(root, identifier, label, role)) {
            void (^continuation)(void) = next;
            poll = nil;
            check(YES, message);
            continuation();
        } else if (CFAbsoluteTimeGetCurrent() >= deadline) {
            poll = nil;
            waitFailed(root, description);
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), poll);
        }
    };
    dispatch_async(dispatch_get_main_queue(), poll);
}

static void waitForCondition(NSWindow *root, NSString *description, BOOL (^condition)(void),
                             void (^next)(void)) {
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 4.0;
    __block void (^poll)(void);
    poll = ^{
        if (condition()) {
            void (^continuation)(void) = next;
            poll = nil;
            continuation();
        } else if (CFAbsoluteTimeGetCurrent() >= deadline) {
            poll = nil;
            waitFailed(root, description);
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), poll);
        }
    };
    dispatch_async(dispatch_get_main_queue(), poll);
}

static void waitForControlsSection(NSWindow *sheet, const char *message, void (^next)(void)) {
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 4.0;
    NSString *description = [NSString stringWithUTF8String:message];
    __block BOOL attempted = NO;
    __block void (^poll)(void);
    poll = ^{
        if (controlsHeadingVisible(sheet)) {
            void (^continuation)(void) = next;
            poll = nil;
            check(YES, message);
            continuation();
        } else if (CFAbsoluteTimeGetCurrent() >= deadline) {
            poll = nil;
            waitFailed(sheet, description);
        } else {
            if (!attempted) {
                attempted = YES;
                if (!press(sheet, @"settings.section.Controls", nil, nil)) selectControlsNativeRow(sheet);
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), poll);
        }
    };
    dispatch_async(dispatch_get_main_queue(), poll);
}

static void settingsClosed(void) {
    NSWindow *game = NSApp.mainWindow;
    waitForCondition(game, @"in-game settings sheet to detach", ^{
        return (BOOL)(game.attachedSheet == nil);
    }, ^{
        check(YES, "Done detaches the settings sheet");
        stopRunLoop();
    });
}

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    NSString *domain = NSBundle.mainBundle.bundleIdentifier;
    [NSUserDefaults.standardUserDefaults removePersistentDomainForName:domain];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        waitFailed(NSApp.mainWindow ?: NSApp.windows.firstObject, @"launcher component check completion");
        exit(2);
    });

    dispatch_async(dispatch_get_main_queue(), ^{
        waitForCondition(nil, @"startup dashboard", ^{
            return (BOOL)(NSApp.mainWindow != nil || NSApp.windows.firstObject != nil);
        }, ^{
            NSWindow *window = NSApp.mainWindow ?: NSApp.windows.firstObject;
            [window makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
            check(YES, "startup presents the shared dashboard");
            waitForPress(window, @"launcher.settings", nil, nil, "startup Settings button opens the editor", ^{
            waitForCondition(window, @"startup settings sheet", ^{ return (BOOL)(window.attachedSheet != nil); }, ^{
                NSWindow *sheet = window.attachedSheet;
                check(YES, "startup editor is a separate sheet");
                waitForCondition(sheet, @"frame-rate segments", ^{
                    NSHashTable *nodes = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
                    return hasAXLabel(sheet, @"30 fps", NSAccessibilityRadioButtonRole, nodes, 0);
                }, ^{
                    NSHashTable *nodes = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
                    check(hasAXLabel(sheet, @"60 fps", NSAccessibilityRadioButtonRole, nodes, 0),
                          "frame rate offers 30 and 60 as segments");
                    nodes = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
                    BOOL interpolationSwitch = hasAXLabel(sheet, @"Frame generation", NSAccessibilityCheckBoxRole, nodes, 0);
                    if (!interpolationSwitch) dumpHierarchy(sheet);
                    check(interpolationSwitch,
                          "interpolation is a separate switch beside frame rate");
                waitForControlsSection(sheet, "startup Controls navigation responds", ^{
                    {
                        NSHashTable *nodes = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
                        check(hasAXLabel(sheet, nil, NSAccessibilityCheckBoxRole, nodes, 0), "startup controls include the native rumble toggle");
                        check(applied == 0, "startup does not invoke running-game setters");
                        waitForPress(sheet, nil, @"Done", NSAccessibilityButtonRole, "startup editor Done responds", ^{
                            waitForPress(window, nil, @"Play", NSAccessibilityButtonRole,
                                         "Play leaves the launcher", ^{});
                        });
                    }
                });
                });
            });
            });
        });
    });

    int result = dm_mac_launcher();
    if (timed_out) {
        [NSUserDefaults.standardUserDefaults removePersistentDomainForName:domain];
        printf("Mac launcher component: %d failed\n", failed);
        return 1;
    }
    check(result == 1 && getenv("DM_RUMBLE") && !strcmp(getenv("DM_RUMBLE"), "1"),
          "Play applies startup values before game initialization");
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSWindow *game = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1100, 700)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    game.title = @"Component host (no game)";
    [game makeKeyAndOrderFront:nil];
    check(dm_mac_show_game_settings((__bridge void *)game, settingsClosed) == 1,
          "the same process opens in-game settings after startup");
    waitForCondition(game, @"in-game settings sheet", ^{ return (BOOL)(game.attachedSheet != nil); }, ^{
        NSWindow *sheet = game.attachedSheet;
        waitForControlsSection(sheet, "in-game Controls navigation responds", ^{
            NSHashTable *nodes = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
            check(hasAXLabel(sheet, nil, NSAccessibilityCheckBoxRole, nodes, 0), "in-game controls include the native rumble toggle");
            waitForPress(sheet, nil, @"Done", NSAccessibilityButtonRole, "in-game Done responds", ^{});
        });
    });
    [NSApp run];
    [game orderOut:nil];
    [NSUserDefaults.standardUserDefaults removePersistentDomainForName:domain];
    printf("Mac launcher component: %d failed\n", failed);
    return failed ? 1 : 0;
} }
