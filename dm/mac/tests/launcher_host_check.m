// Shared production launcher, followed by its in-process game settings sheet.
// Synthetic resources and runtime setters only; no game or GPU host is run.
#import <AppKit/AppKit.h>

#import <objc/message.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../host/botw_rune_icon.h"

// This component fixture has no game frame or native rune pixels.
int dm_botw_rune_icon_snapshot(dm_botw_rune_icon_state *out) { if (out) memset(out,0,sizeof *out); return 0; }
void dm_launcher_grab_game_frame(void (^callback)(CGImageRef)) { if (callback) callback(NULL); }
// The fixture has no renderer, as in launcher_storage_check.swift.
void dm_launcher_grab_filter_frame(void (^callback)(CGImageRef)) { if (callback) callback(NULL); }
CGImageRef dm_launcher_filter_preview(CGImageRef image, const char *mode, float strength, int width) { return NULL; }
CGImageRef dm_launcher_lut_preview(CGImageRef image, const char *path, float strength, int width) { return NULL; }
int dm_launcher_lut_apply(const char *path) { return 0; }

int dm_mac_launcher(void);
int dm_mac_show_game_settings(void *, void (*)(void));
static int applied, failed, timed_out;
static int settings_paused, pause_opens, pause_closes;
void dm_launcher_settings_pause(int on) { settings_paused = !!on; if (on) pause_opens++; else pause_closes++; }

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
    // AppKit's accessibility segment objects expose the informal AXPress action.
    if (matches && [axValue(node,@selector(accessibilityActionNames)) containsObject:NSAccessibilityPressAction] &&
        [node respondsToSelector:@selector(accessibilityPerformAction:)]) {
        @try { [node accessibilityPerformAction:NSAccessibilityPressAction]; return YES; }
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

static BOOL selectNativeRow(NSWindow *window, NSInteger index) {
    NSOutlineView *outline = findOutline(window.contentView);
    if (!outline || outline.numberOfRows <= index || !outline.window) return NO;
    // The launcher's first section is Game and its second is Controls. Select the live native AX outline row;
    // the following heading check verifies that List(selection:) updated the SwiftUI state.
    [outline selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
    return outline.selectedRow == index;
}

static BOOL hasAXLabel(id node, NSString *label, NSString *role, NSHashTable *visited, NSUInteger depth) {
    if (!node || depth > 128 || [visited containsObject:node]) return NO;
    [visited addObject:node];
    NSString *nodeLabel = axValue(node, @selector(accessibilityLabel));
    if (![nodeLabel isKindOfClass:NSString.class] || !nodeLabel.length) {
        id value = axValue(node, @selector(accessibilityValue));
        if ([value isKindOfClass:NSString.class]) nodeLabel = value;
    }
    NSString *nodeRole = axValue(node, @selector(accessibilityRole));
    if ((!label || ([nodeLabel isKindOfClass:NSString.class] && [nodeLabel isEqual:label])) &&
        (!role || [nodeRole isEqual:role])) return YES;
    for (id child in axChildren(node))
        if (hasAXLabel(child, label, role, visited, depth + 1)) return YES;
    return NO;
}

static BOOL disabledAX(id node, NSString *identifier, NSHashTable *visited, NSUInteger depth) {
    if (!node || depth > 128 || [visited containsObject:node]) return NO;
    [visited addObject:node];
    if ([axValue(node,@selector(accessibilityIdentifier)) isEqual:identifier] && [node respondsToSelector:@selector(isAccessibilityEnabled)])
        return ![node isAccessibilityEnabled];
    for (id child in axChildren(node)) if (disabledAX(child,identifier,visited,depth+1)) return YES;
    return NO;
}

static BOOL sectionHeadingVisible(NSWindow *sheet, NSString *section) {
    NSHashTable *visited = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
    NSString *title = [section isEqual:@"Touch"] ? @"BOTW touch settings" : [section isEqual:@"Saves"] ? @"Save settings" : section;
    return hasAXLabel(sheet, title, NSAccessibilityHeadingRole, visited, 0);
}

static void captureWindow(NSWindow *window, NSString *filename) {
    if (!getenv("DM_TEST_SCREENSHOT")) return;
    NSBitmapImageRep *image = [window.contentView bitmapImageRepForCachingDisplayInRect:window.contentView.bounds];
    [window.contentView cacheDisplayInRect:window.contentView.bounds toBitmapImageRep:image];
    NSString *path = @(getenv("DM_TEST_SCREENSHOT"));
    if (filename) path = [path.stringByDeletingLastPathComponent stringByAppendingPathComponent:filename];
    [[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
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
    captureWindow(root,@"failure.png");
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

static void waitForSection(NSWindow *sheet, NSString *section, NSInteger index, const char *message, void (^next)(void)) {
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 4.0;
    NSString *description = [NSString stringWithUTF8String:message];
    __block BOOL attempted = NO;
    __block void (^poll)(void);
    poll = ^{
        if (sectionHeadingVisible(sheet, section)) {
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
                if (!press(sheet, [@"settings.section." stringByAppendingString:section], nil, nil)) selectNativeRow(sheet,index);
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), poll);
        }
    };
    dispatch_async(dispatch_get_main_queue(), poll);
}

static void checkExportCount(NSWindow *selection, int count, void (^next)(void)) {
    NSString *label = [NSString stringWithFormat:@"Selected: %d",count];
    waitForCondition(selection,label,^{
        NSHashTable *nodes = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
        return hasAXLabel(selection,label,nil,nodes,0);
    },^{ check(YES,label.UTF8String); next(); });
}

static void checkExportToggles(NSWindow *selection, NSUInteger step, void (^next)(void)) {
    static const int counts[] = {2,1,2,0,1};
    NSArray *labels = @[@"Test campaign",@"Select all saves",@"Select all saves",@"Default"];
    checkExportCount(selection,counts[step],^{
        if (step == 3) {
            NSHashTable *nodes = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
            check(disabledAX(selection,@"saves.export.confirm",nodes,0),"export is disabled with no saves selected");
        }
        if (step == 4) { next(); return; }
        waitForPress(selection,nil,labels[step],NSAccessibilityCheckBoxRole,"export checkbox updates the selection",^{
            checkExportToggles(selection,step+1,next);
        });
    });
}

static void checkFreshExportSelection(NSWindow *sheet, void (^next)(void)) {
    waitForPress(sheet,@"saves.export-many",nil,nil,"batch export can be reopened",^{
        waitForCondition(sheet,@"fresh export selection",^{ return (BOOL)(sheet.attachedSheet != nil); },^{
            NSWindow *selection = sheet.attachedSheet;
            checkExportCount(selection,2,^{
                waitForPress(selection,nil,@"Cancel",NSAccessibilityButtonRole,"batch export can be cancelled",^{
                    waitForCondition(sheet,@"export selection to close",^{ return (BOOL)(sheet.attachedSheet == nil); },next);
                });
            });
        });
    });
}

static void checkExportSelection(NSWindow *sheet, void (^next)(void)) {
    waitForPress(sheet,@"saves.export-many",nil,nil,"batch export opens from Saves",^{
        waitForCondition(sheet,@"export selection sheet",^{ return (BOOL)(sheet.attachedSheet != nil); },^{
            NSWindow *selection = sheet.attachedSheet;
            waitForCondition(selection,@"export selection controls",^{
                NSHashTable *nodes = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
                return hasAXLabel(selection,@"Select all saves",NSAccessibilityCheckBoxRole,nodes,0);
            },^{
                check(YES,"batch export includes the select-all control");
                captureWindow(selection,@"export.png");
                checkExportToggles(selection,0,^{
                    waitForPress(selection,@"saves.export.confirm",nil,NSAccessibilityButtonRole,"a selected subset can be exported",^{
                        waitForCondition(sheet,@"native save panel",^{ return [NSApp.modalWindow isKindOfClass:NSSavePanel.class]; },^{
                            check(YES,"the export selection reaches the native save panel");
                            [(NSSavePanel *)NSApp.modalWindow cancel:nil];
                            waitForCondition(sheet,@"save panel to close",^{
                                return (BOOL)(![NSApp.modalWindow isKindOfClass:NSSavePanel.class] && sheet.attachedSheet == nil);
                            },^{ checkFreshExportSelection(sheet,next); });
                        });
                    });
                });
            });
        });
    });
}

static void saveRowFrames(id node, NSMutableDictionary *frames, NSHashTable *visited, NSUInteger depth) {
    if (!node || depth > 128 || [visited containsObject:node]) return;
    [visited addObject:node];
    NSString *identifier = axValue(node,@selector(accessibilityIdentifier));
    if ([identifier hasPrefix:@"saves.select."] || [identifier hasPrefix:@"saves.actions."])
        frames[identifier] = [NSValue valueWithRect:[node accessibilityFrame]];
    for (id child in axChildren(node)) saveRowFrames(child,frames,visited,depth+1);
}

static NSDictionary *saveFrames(NSWindow *sheet) {
    NSMutableDictionary *frames = [NSMutableDictionary dictionary];
    saveRowFrames(sheet,frames,[NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality],0);
    return frames;
}

static id findAXIdentifier(id node, NSString *identifier, NSHashTable *visited, NSUInteger depth) {
    if (!node || depth > 128 || [visited containsObject:node]) return nil;
    [visited addObject:node];
    if ([axValue(node,@selector(accessibilityIdentifier)) isEqual:identifier]) return node;
    for (id child in axChildren(node)) {
        id found = findAXIdentifier(child,identifier,visited,depth+1);
        if (found) return found;
    }
    return nil;
}

static void checkSaveSwitches(NSWindow *sheet, NSUInteger step, NSDictionary *frames, void (^next)(void)) {
    NSArray *ids = @[@"Test campaign",@"default",@"Test campaign",@"default",@"Test campaign"];
    if (step == ids.count) { next(); return; }
    NSString *slot = ids[step], *identifier = [@"saves.select." stringByAppendingString:slot];
    waitForPress(sheet,identifier,nil,nil,"an existing save can be selected",^{
        waitForCondition(sheet,@"save selection to settle",^{
            NSData *data = [NSData dataWithContentsOfFile:[@(getenv("DM_SAVES_ROOT")) stringByAppendingPathComponent:@"saves/current.json"]];
            NSDictionary *selection = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSHashTable *nodes = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
            id row = findAXIdentifier(sheet,identifier,nodes,0);
            NSString *label = axValue(row,@selector(accessibilityLabel));
            return (BOOL)([selection[@"slot_id"] isEqual:slot] &&
                [label containsString:@"Current save"]);
        },^{
            NSDictionary *after = saveFrames(sheet);
            check(frames.count >= 4 && [frames isEqualToDictionary:after],"switching keeps every save row and menu in place");
            NSHashTable *nodes = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
            check(!disabledAX(sheet,@"saves.select.default",nodes,0),"switching leaves save rows enabled without dimming");
            nodes = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
            check(!findAXIdentifier(sheet,@"saves.busy",nodes,0),"switching adds no loading row");
            checkSaveSwitches(sheet,step+1,frames,next);
        });
    });
}

static NSWindow *explanationWindow(void) {
    for (NSWindow *window in NSApp.windows) {
        if (!window.visible) continue;
        NSHashTable *nodes = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
        if (findAXIdentifier(window,@"DM_PRESENT_UPSCALE.help.text",nodes,0)) return window;
    }
    return nil;
}

static BOOL segmentSelected(NSView *view, NSString *label) {
    if ([view isKindOfClass:NSSegmentedControl.class]) {
        NSSegmentedControl *control = (NSSegmentedControl *)view;
        if (control.selectedSegment >= 0 && [[control labelForSegment:control.selectedSegment] isEqual:label]) return YES;
    }
    for (NSView *child in view.subviews) if (segmentSelected(child,label)) return YES;
    return NO;
}

static void checkSettingsChoices(NSWindow *sheet, NSUInteger step, void (^next)(void)) {
    NSArray *options = @[@"Handheld",@"Docked",@"Scene MetalFX",@"Standard"];
    if (step < options.count) {
        waitForPress(sheet,nil,options[step],nil,"a short option list is selectable inline",^{
            waitForCondition(sheet,@"selected segment",^{ return segmentSelected(sheet.contentView,options[step]); },^{
                check(YES,"the native segmented control updates its selected value");
                checkSettingsChoices(sheet,step+1,next);
            });
        });
        return;
    }
    waitForPress(sheet,@"DM_PRESENT_UPSCALE.help",nil,nil,"the info button opens the setting explanation",^{
        waitForCondition(sheet,@"setting explanation popover",^{ return (BOOL)(explanationWindow() != nil); },^{
            check(YES,"long setting text appears in a popover");
            captureWindow(explanationWindow(),@"explanation.png");
            waitForPress(sheet,@"DM_PRESENT_UPSCALE.help",nil,nil,"the info button closes its explanation",^{
                waitForCondition(sheet,@"setting explanation to close",^{ return (BOOL)(explanationWindow() == nil); },next);
            });
        });
    });
}

static void settingsClosed(void) {
    check(!settings_paused && pause_opens == 1 && pause_closes == 1, "closing settings releases its pause exactly once");
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
    const char *appearance = getenv("DM_TEST_APPEARANCE");
    [NSApplication sharedApplication].appearance = [NSAppearance appearanceNamed:
        appearance && !strcmp(appearance,"light") ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua];
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
                waitForCondition(sheet, @"frame-rate shortcuts", ^{
                    NSHashTable *nodes = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
                    return hasAXLabel(sheet, @"30 fps", NSAccessibilityButtonRole, nodes, 0);
                }, ^{
                    NSHashTable *nodes = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
                    check(hasAXLabel(sheet, @"60 fps", NSAccessibilityButtonRole, nodes, 0),
                          "frame rate offers 30 and 60 shortcuts");
                waitForPress(sheet, @"DM_FPS_TARGET.more", nil, NSAccessibilityButtonRole, "More frame rates responds", ^{
                waitForCondition(sheet, @"expanded frame-rate slider", ^{
                    NSHashTable *sliderNodes = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
                    return hasAXLabel(sheet, @"Frame rate", NSAccessibilitySliderRole, sliderNodes, 0);
                }, ^{
                    check(YES, "More frame rates expands the FPS slider below the shortcuts");
                    NSHashTable *switchNodes = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
                    BOOL interpolationSwitch = hasAXLabel(sheet, @"Frame generation", NSAccessibilityCheckBoxRole, switchNodes, 0);
                    if (!interpolationSwitch) dumpHierarchy(sheet);
                    check(interpolationSwitch,
                          "interpolation is a separate switch beside frame rate");
                checkSettingsChoices(sheet,0,^{
                    captureWindow(sheet,@"graphics.png");
                waitForSection(sheet, @"Controls", 1, "startup Controls navigation responds", ^{
                    {
                        NSHashTable *nodes = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
                        check(hasAXLabel(sheet, nil, NSAccessibilityCheckBoxRole, nodes, 0), "startup controls include the native rumble toggle");
                        check(applied == 0, "startup does not invoke running-game setters");
                        waitForSection(sheet, @"Saves", 3, "Saves replaces the cloud-only settings section", ^{
                        checkExportSelection(sheet, ^{
                        checkSaveSwitches(sheet,0,saveFrames(sheet),^{
                        check(YES, "the save switch persists before Play");
                        captureWindow(sheet,nil);
                        waitForPress(sheet, nil, @"Done", NSAccessibilityButtonRole, "startup editor Done responds", ^{
                            waitForPress(window, nil, @"Play", NSAccessibilityButtonRole,
                                         "Play leaves the launcher", ^{});
                        });
                        });
                        });
                        });
                    }
                });
                });
                });
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
    check(!settings_paused && !pause_opens && !pause_closes, "startup settings do not pause a game that has not started");
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSWindow *game = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1100, 700)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    game.title = @"Component host (no game)";
    [game makeKeyAndOrderFront:nil];
    check(dm_mac_show_game_settings((__bridge void *)game, settingsClosed) == 1,
          "the same process opens in-game settings after startup");
    waitForCondition(game, @"in-game settings sheet", ^{ return (BOOL)(game.attachedSheet != nil); }, ^{
        NSWindow *sheet = game.attachedSheet;
        check(settings_paused && pause_opens == 1, "in-game settings acquire the game pause before presentation");
        check(dm_mac_show_game_settings((__bridge void *)game, settingsClosed) == 1 && pause_opens == 1,
              "reopening the existing settings sheet does not acquire another pause");
        if (getenv("DM_SAVE_UI_ONLY")) {
            waitForSection(sheet,@"Saves",3,"in-game Saves navigation responds",^{
                waitForCondition(sheet,@"read-only save library",^{
                    NSHashTable *nodes = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
                    return disabledAX(sheet,@"saves.new",nodes,0);
                },^{
                    NSHashTable *nodes = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
                    check(disabledAX(sheet,@"saves.new",nodes,0),"new saves are disabled during gameplay");
                    nodes = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
                    check(disabledAX(sheet,@"saves.select.default",nodes,0),"switching saves is disabled during gameplay");
                    waitForPress(sheet,nil,@"Done",NSAccessibilityButtonRole,"read-only save library closes normally",^{});
                });
            });
            return;
        }
        waitForSection(sheet, @"Controls", 1, "in-game Controls navigation responds", ^{
            NSHashTable *nodes = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
            check(hasAXLabel(sheet, nil, NSAccessibilityCheckBoxRole, nodes, 0), "in-game controls include the native rumble toggle");
            waitForSection(sheet, @"Touch", 2, "Touch opens the menu rather than an embedded editor", ^{
                waitForPress(sheet, @"settings.touch.normal", nil, nil, "normal layout opens its editor", ^{
                    waitForCondition(sheet, @"full-width normal layout", ^{ return (BOOL)(findOutline(sheet.contentView)==nil); }, ^{
                        check(YES,"layout editor replaces the section sidebar");
                        waitForPress(sheet, nil, @"Back", NSAccessibilityButtonRole, "Back restores the touch menu", ^{
                            waitForPress(sheet, @"settings.touch.compact", nil, nil, "compact layout opens its own editor", ^{
                                waitForPress(sheet, nil, @"Back", NSAccessibilityButtonRole, "compact layout returns to the menu", ^{
                                    waitForPress(sheet, @"settings.touch.stick", nil, nil, "stick parameters open a separate page", ^{
                                        waitForPress(sheet, nil, @"Done", NSAccessibilityButtonRole, "in-game Done responds", ^{});
                                    });
                                });
                            });
                        });
                    });
                });
            });
        });
    });
    [NSApp run];
    [game orderOut:nil];
    [NSUserDefaults.standardUserDefaults removePersistentDomainForName:domain];
    printf("Mac launcher component: %d failed\n", failed);
    return failed ? 1 : 0;
} }
