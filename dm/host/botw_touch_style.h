// BOTW touch artwork only; ordinary gamepads keep their own style.
#pragma once
#import <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <stdlib.h>

#define DM_BOTW_BUTTON_GRAY .26
#define DM_BOTW_BUTTON_ALPHA .20
#define DM_BOTW_STROKE_GRAY .25
#define DM_BOTW_STROKE_ALPHA .40
#define DM_BOTW_STROKE_WIDTH_SCALE 1.2
#define DM_BOTW_STICK_RING_WIDTH (1.5 * DM_BOTW_STROKE_WIDTH_SCALE)
#define DM_BOTW_STICK_GRAPH_ALPHA .15

// Menu glyphs sit over a translucent circular button fill.
static inline CGPathRef dm_botw_menu_key_path(CGPoint center, CGFloat size, CGFloat circleSize, int plus) {
    CGMutablePathRef path = CGPathCreateMutable();
    CGFloat stroke = circleSize * .12;
    CGPathAddRect(path, NULL, CGRectMake(center.x-size/2, center.y-stroke/2, size, stroke));
    if (plus) CGPathAddRect(path, NULL, CGRectMake(center.x-stroke/2, center.y-size/2, stroke, size));
    return path;
}

// Core Graphics centers strokes on the path. Keep only the outside half of a
// double-width stroke so its inner edge meets the fill without covering it.
static inline CGPathRef dm_botw_outer_border_path(CGPathRef fill, CGFloat width) {
    if (!fill || width <= 0) return NULL;
    CGPathRef stroke = CGPathCreateCopyByStrokingPath(fill, NULL, 2 * width,
        kCGLineCapButt, kCGLineJoinRound, 10);
    CGPathRef border = CGPathCreateCopyBySubtractingPath(stroke, fill, false);
    CGPathRelease(stroke);
    return border;
}

static inline NSString *dm_botw_touch_y_icon_path(void) {
    const char *map = getenv("DM_NVN_SHMAP");
    NSString *folder = map && *map ? [[NSString stringWithUTF8String:map] stringByDeletingLastPathComponent] :
        [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"dm"];
    return [folder stringByAppendingPathComponent:@"touch_y.png"];
}

// Arrow and shield paths adapted from https://github.com/chaos-xxl/zelda-hyrule-ui.
/*
MIT License

Copyright (c) 2025 Chaos

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

// Paths use top-left coordinates on both frontends. The source arrow points right.
static inline CGPathRef dm_botw_hyrule_arrow_path(CGPoint center, CGFloat height, CGFloat angle) {
    CGMutablePathRef path = CGPathCreateMutable();
    CGAffineTransform transform = CGAffineTransformMakeTranslation(center.x, center.y);
    transform = CGAffineTransformRotate(transform, angle);
    transform = CGAffineTransformScale(transform, height / 18, height / 18);
    transform = CGAffineTransformTranslate(transform, -5, -9);
    CGPathMoveToPoint(path, &transform, 9.43536, 10.3304);
    CGPathAddLineToPoint(path, &transform, 0.651995, 17.9138);
    CGPathAddCurveToPoint(path, &transform, 0.275566, 18.1799, -0.100864, 17.7808, 0.0246125, 17.3817);
    CGPathAddLineToPoint(path, &transform, 2.00173, 12.7766);
    CGPathAddCurveToPoint(path, &transform, 3.12324, 10.1644, 3.07997, 7.19835, 1.88273, 4.61997);
    CGPathAddLineToPoint(path, &transform, 0.0246125, 0.618326);
    CGPathAddCurveToPoint(path, &transform, 0.0174314, 0.595483, 0.0118941, 0.572641, 0.00790677, 0.549923);
    CGPathAddCurveToPoint(path, &transform, -0.057777, 0.175692, 0.297109, -0.164701, 0.651995, 0.0861556);
    CGPathAddLineToPoint(path, &transform, 9.43536, 7.66958);
    CGPathAddCurveToPoint(path, &transform, 10.1882, 8.46783, 10.1882, 9.66521, 9.43536, 10.3304);
    CGPathCloseSubpath(path);
    return path;
}

static inline CGPathRef dm_botw_four_arrows_path(CGPoint center, CGFloat offset, CGFloat height) {
    CGMutablePathRef path = CGPathCreateMutable();
    for (int i = 0; i < 4; i++) {
        CGFloat angle = i * M_PI_2;
        CGPoint at = CGPointMake(center.x + offset * cos(angle), center.y + offset * sin(angle));
        CGPathRef arrow = dm_botw_hyrule_arrow_path(at, height, angle);
        CGPathAddPath(path, NULL, arrow); CGPathRelease(arrow);
    }
    return path;
}

static inline CGPathRef dm_botw_shield_graph_path(CGPoint center, CGFloat unit) {
    CGMutablePathRef path = CGPathCreateMutable();
    CGFloat scale = 24 * unit / 38.89;
    CGAffineTransform transform = CGAffineTransformMake(scale, 0, 0, scale,
        center.x - 33.33 * scale / 2, center.y - 24 * unit / 2);
    CGPathMoveToPoint(path, &transform, 31.8889, 0);
    CGPathAddLineToPoint(path, &transform, 1.44445, 0.0);
    CGPathAddCurveToPoint(path, &transform, 0.66667, 0, 0, 0.676328, 0, 1.46538);
    CGPathAddLineToPoint(path, &transform, 0.0, 17.19);
    CGPathAddCurveToPoint(path, &transform, 0, 22.4316, 1.83333, 27.5604, 5.22222, 31.562);
    CGPathAddCurveToPoint(path, &transform, 8.33333, 35.2254, 11.6667, 38.8889, 16.6667, 38.8889);
    CGPathAddCurveToPoint(path, &transform, 21.6667, 38.8889, 24.7778, 35.3945, 27.8889, 31.8438);
    CGPathAddCurveToPoint(path, &transform, 31.3889, 27.7858, 33.3333, 22.5443, 33.3333, 17.1337);
    CGPathAddLineToPoint(path, &transform, 33.3333, 1.46538);
    CGPathAddCurveToPoint(path, &transform, 33.3333, 0.676328, 32.7222, 0, 31.8889, 0);
    CGPathCloseSubpath(path);
    CGPathMoveToPoint(path, &transform, 28.3333, 17.19);
    CGPathAddCurveToPoint(path, &transform, 28.3333, 21.3607, 26.8333, 25.4187, 24.1111, 28.5185);
    CGPathAddCurveToPoint(path, &transform, 21, 32.1256, 19.2222, 33.8164, 16.6667, 33.8164);
    CGPathAddCurveToPoint(path, &transform, 14.1667, 33.8164, 12.2222, 32.0129, 9.00001, 28.2367);
    CGPathAddCurveToPoint(path, &transform, 6.44445, 25.2496, 5, 21.3043, 5, 17.19);
    CGPathAddLineToPoint(path, &transform, 5.0, 6.42512);
    CGPathAddCurveToPoint(path, &transform, 5, 5.69243, 5.55555, 5.12882, 6.27777, 5.12882);
    CGPathAddLineToPoint(path, &transform, 27, 5.12882);
    CGPathAddCurveToPoint(path, &transform, 27.7222, 5.12882, 28.2778, 5.74879, 28.2778, 6.42512);
    CGPathAddLineToPoint(path, &transform, 28.2778, 17.19);
    CGPathAddLineToPoint(path, &transform, 28.3333, 17.19);
    CGPathCloseSubpath(path);
    CGPathMoveToPoint(path, &transform, 24.3333, 8.45411);
    CGPathAddCurveToPoint(path, &transform, 24.7222, 8.45411, 25, 8.79227, 25, 9.13044);
    CGPathAddLineToPoint(path, &transform, 25.0, 17.1337);
    CGPathAddCurveToPoint(path, &transform, 25, 20.4589, 23.7778, 23.7279, 21.6111, 26.2077);
    CGPathAddCurveToPoint(path, &transform, 18.8333, 29.4203, 17.7222, 30.3784, 16.6667, 30.3784);
    CGPathAddCurveToPoint(path, &transform, 15.6667, 30.3784, 14.2778, 29.1948, 11.5, 25.9823);
    CGPathAddCurveToPoint(path, &transform, 9.44445, 23.5588, 8.33333, 20.4589, 8.33333, 17.1337);
    CGPathAddLineToPoint(path, &transform, 8.33333, 9.1868);
    CGPathAddCurveToPoint(path, &transform, 8.33333, 8.79227, 8.66667, 8.51047, 9.00001, 8.51047);
    CGPathAddLineToPoint(path, &transform, 24.3333, 8.51047);
    CGPathAddLineToPoint(path, &transform, 24.3333, 8.45411);
    CGPathCloseSubpath(path);
    CGPathRef arrows = dm_botw_four_arrows_path(center, 22 * unit, 12 * unit);
    CGPathAddPath(path, NULL, arrows); CGPathRelease(arrows);
    return path;
}

static inline CGPathRef dm_botw_stick_direction_path(CGPoint origin, CGPoint touch,
                                                     CGFloat radius, CGFloat unit) {
    CGFloat dx = touch.x - origin.x, dy = touch.y - origin.y, distance = hypot(dx, dy);
    if (!(distance > 0)) return NULL;
    // The arrow's inner edge meets the ring's outer edge, rather than
    // straddling the perimeter.
    CGFloat height = 22 * unit;
    radius += height * 5 / 18 + DM_BOTW_STICK_RING_WIDTH * .5;
    CGPoint at = CGPointMake(origin.x + radius * dx / distance, origin.y + radius * dy / distance);
    return dm_botw_hyrule_arrow_path(at, height, atan2(dy, dx));
}
