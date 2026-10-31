// Use the system Files picker and a background, coordinated copy; large images never block the startup screen.
#import "GameFiles.h"
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdio.h>

int front_ios_prepare_game(void);

@interface DmGameFilesController : UIViewController <UIDocumentPickerDelegate>
@property (nonatomic, copy) void (^ready)(void);
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UIButton *choose;
@property (nonatomic, strong) UIButton *check;
@property (nonatomic, strong) UIActivityIndicatorView *activity;
@end

static UILabel *game_files_label(NSString *text, UIFontTextStyle style) {
    UILabel *label = [UILabel new]; label.text = text; label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:style]; label.adjustsFontForContentSizeCategory = YES;
    return label;
}

@implementation DmGameFilesController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    UIStackView *stack = [UIStackView new]; stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO; [scroll addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor], [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [scroll.contentLayoutGuide.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
        [stack.centerXAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.centerXAnchor],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:620],
        [stack.widthAnchor constraintLessThanOrEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24]
    ]];
    NSLayoutConstraint *width = [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48];
    width.priority = UILayoutPriorityDefaultHigh; width.active = YES;
    [stack addArrangedSubview:game_files_label(NSLocalizedString(@"Game files", nil), UIFontTextStyleLargeTitle)];
    NSString *name = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: NSBundle.mainBundle.bundleIdentifier ?: @"nxnative";
    [stack addArrangedSubview:game_files_label(name, UIFontTextStyleHeadline)];
    NSString *instructions = [NSString stringWithFormat:NSLocalizedString(@"Import RomFS.img, or copy it to Files > On My iPhone/iPad > %@ and tap Check files.", nil), name];
    [stack addArrangedSubview:game_files_label(instructions, UIFontTextStyleBody)];
    self.choose = [UIButton buttonWithType:UIButtonTypeSystem];
    self.choose.configuration = [UIButtonConfiguration filledButtonConfiguration];
    [self.choose setTitle:NSLocalizedString(@"Import .img", nil) forState:UIControlStateNormal];
    self.choose.accessibilityIdentifier = @"game-files.import";
    [self.choose addTarget:self action:@selector(chooseImage) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.choose];
    self.check = [UIButton buttonWithType:UIButtonTypeSystem];
    self.check.configuration = [UIButtonConfiguration borderedButtonConfiguration];
    [self.check setTitle:NSLocalizedString(@"Check files", nil) forState:UIControlStateNormal];
    self.check.accessibilityIdentifier = @"game-files.check";
    [self.check addTarget:self action:@selector(checkFiles) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.check];
    self.activity = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.activity.hidesWhenStopped = YES; [stack addArrangedSubview:self.activity];
    self.status = game_files_label(NSLocalizedString(@"No usable game files found.", nil), UIFontTextStyleFootnote);
    self.status.textColor = UIColor.secondaryLabelColor; self.status.accessibilityIdentifier = @"game-files.status";
    [stack addArrangedSubview:self.status];
}
- (void)checkFiles {
    if (!front_ios_prepare_game()) { self.status.text = NSLocalizedString(@"No usable game files found. Check the file location and try again.", nil); return; }
    self.choose.enabled = NO; self.check.enabled = NO;
    [self dismissViewControllerAnimated:NO completion:self.ready];   // continue into the normal launcher without an app restart
}
- (void)chooseImage {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:NO];
    picker.delegate = self; picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *source = urls.firstObject; if (!source) return;
    [controller dismissViewControllerAnimated:YES completion:^{ [self importImage:source]; }];
}
- (void)importImage:(NSURL *)source {
    self.choose.enabled = NO; self.check.enabled = NO; [self.activity startAnimating];
    self.status.text = NSLocalizedString(@"Importing…", nil);
    BOOL idle = UIApplication.sharedApplication.idleTimerDisabled; UIApplication.sharedApplication.idleTimerDisabled = YES;
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask][0];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
        NSError *error = nil; BOOL copied = dm_import_game_image(source, documents, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            UIApplication.sharedApplication.idleTimerDisabled = idle;
            self.choose.enabled = YES; self.check.enabled = YES; [self.activity stopAnimating];
            if (copied) [self checkFiles];
            else { self.status.text = error.localizedDescription; fprintf(stderr, "[RED] game image import: %s\n", error.localizedDescription.UTF8String); }
        });
    }});
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end

void dm_show_game_files(void *view_controller, void (*done)(void)) {
    UIViewController *parent = (__bridge UIViewController *)view_controller;
    DmGameFilesController *screen = [DmGameFilesController new];
    screen.ready = ^{ done(); }; screen.modalPresentationStyle = UIModalPresentationFullScreen; screen.modalInPresentation = YES;
    [parent presentViewController:screen animated:NO completion:nil];
}
