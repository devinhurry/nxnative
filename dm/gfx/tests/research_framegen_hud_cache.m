#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>

int main(void) { @autoreleasepool {
    NSData *input = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
    NSError *error = nil;
    NSArray *items = [NSJSONSerialization JSONObjectWithData:input options:0 error:&error];
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!items || !device) { fprintf(stderr, "input or Metal device unavailable\n"); return 1; }
    unsigned ok[2] = {0}, total[2] = {0};
    for (NSDictionary *item in items) { @autoreleasepool {
        int old = [item[@"mode"] isEqual:@"cached"];
        total[old]++;
        error = nil;
        id<MTLLibrary> lib = old ? [device newLibraryWithURL:[NSURL fileURLWithPath:item[@"path"]] error:&error]
                                 : [device newLibraryWithSource:item[@"source"] options:nil error:&error];
        if (!lib) { fprintf(stderr, "%s: library unavailable (%s %ld)\n", [item[@"key"] UTF8String],
                            error.domain.UTF8String, (long)error.code); continue; }
        NSString *entry = [lib.functionNames containsObject:@"main0_f"] ? @"main0_f" : @"main0";
        id<MTLFunction> raw = [lib newFunctionWithName:entry];
        NSArray *outputs = item[@"outputs"];
        int expected = 1;
        for (int j = 0; j < outputs.count; j++) for (int k = 0; k < 8; k++) {
            NSString *name = [NSString stringWithFormat:@"OM_%d_%d", j, k];
            MTLFunctionConstant *c = raw.functionConstantsDictionary[name];
            if (!c || c.index != 64 + 8*j + k || c.type != MTLDataTypeBool) expected = 0;
        }
        if (!expected) { fprintf(stderr, "%s: output mapping constants unavailable\n", [item[@"key"] UTF8String]); continue; }
        MTLFunctionConstantValues *values = [MTLFunctionConstantValues new];
        for (int i = 0; i < [item[@"calls"] intValue]; i++) { int v = -1; [values setConstantValue:&v type:MTLDataTypeInt atIndex:i]; }
        for (int i = 0; i < 8; i++) { bool v = false; [values setConstantValue:&v type:MTLDataTypeBool atIndex:32+i]; }
        for (int j = 0; j < outputs.count; j++) for (int k = 0; k < 8; k++) {
            bool v = k == [outputs[j] intValue] || (k == 7 && [outputs[j] intValue] == 0);
            [values setConstantValue:&v type:MTLDataTypeBool atIndex:64+8*j+k];
        }
        error = nil;
        id<MTLFunction> fn = [lib newFunctionWithName:entry constantValues:values error:&error];
        if (!fn) { fprintf(stderr, "%s: specialization unavailable (%s %ld)\n", [item[@"key"] UTF8String],
                           error.domain.UTF8String, (long)error.code); continue; }
        ok[old]++;
    } }
    printf("Metal device: %s\n", device.name.UTF8String);
    printf("current fold: %u/%u; cached variant: %u/%u\n", ok[0], total[0], ok[1], total[1]);
    return ok[0] == total[0] && ok[1] == total[1] ? 0 : 1;
} }
