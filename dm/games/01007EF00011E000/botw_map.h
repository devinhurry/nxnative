// BOTW 1.9.0 map projection, build cd57b23f (native update main+DC1D70).
#pragma once
#include <stdint.h>
enum {
    BOTW_MAP_ROTATE = 0xe83520,
    BOTW_MAP_OFFSET = 0x860, BOTW_MAP_PAN_SCALED = 0x868,
    BOTW_MAP_TRANSLATION = 0x870, BOTW_MAP_SCALE = 0x878, BOTW_MAP_ANGLE = 0x87c,
};
static const uint32_t BOTW_MAP_ROTATE_WORDS[] = {
    0xb4000260, 0xd100c3ff, 0xa9017bfd, 0xf90013f3,
    0x910043fd, 0x2d400801, 0xd00040e8,
};
