// Bundle metadata is stamped by the build tools; only its display hash is shortened.
#pragma once
#import <Foundation/Foundation.h>

static inline NSString *dm_build_about_message(NSBundle *bundle) {
    NSString *commit = [bundle objectForInfoDictionaryKey:@"DMCommit"];
    NSString *shortCommit = @"unknown";
    if ([commit isKindOfClass:NSString.class] &&
        [commit rangeOfString:@"^[0-9a-fA-F]{6}" options:NSRegularExpressionSearch].location != NSNotFound) {
        shortCommit = [commit substringToIndex:6];
        if ([commit hasSuffix:@"+dirty"]) shortCommit = [shortCommit stringByAppendingString:@"+dirty"];
    }
    return [NSString stringWithFormat:@"Repository: %@\nCommit: %@\nBuilt (UTC): %@",
            [bundle objectForInfoDictionaryKey:@"DMRepository"] ?: @"unknown", shortCommit,
            [bundle objectForInfoDictionaryKey:@"DMBuildTime"] ?: @"unknown"];
}
