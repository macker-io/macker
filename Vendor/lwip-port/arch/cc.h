#ifndef MACKER_LWIP_ARCH_CC_H
#define MACKER_LWIP_ARCH_CC_H

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LWIP_PLATFORM_ASSERT(message) assert(message)
#define LWIP_PLATFORM_DIAG(message) do { printf message; } while (0)
#define LWIP_RAND() ((u32_t)arc4random())
#define LWIP_NO_STDINT_H 0
#define LWIP_NO_INTTYPES_H 0
#define LWIP_NO_STDDEF_H 0

#endif
