// librashader-bridge.h - Swift bridging header for librashader's Metal runtime.
// The header only declares the Metal entry points when compiled as Objective-C
// with LIBRA_RUNTIME_METAL defined, which is what this file arranges.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#define LIBRA_RUNTIME_METAL 1
#include "librashader.h"
