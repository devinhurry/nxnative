#include <metal_stdlib>
using namespace metal;

kernel void native30_idle(device uint *result [[buffer(0)]],
                          constant uint &steps [[buffer(1)]],
                          uint lane [[thread_position_in_grid]]) {
    uint value = lane + 1;
    for (uint i = 0; i < steps; i++) {
        value = value * 1664525u + 1013904223u;
        value ^= value >> 13;
    }
    result[lane] = value;
}
