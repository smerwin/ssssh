#ifndef ssssh_BridgingHeader_h
#define ssssh_BridgingHeader_h

// Mosh's wire protocol always zlib-compresses each Instruction's serialized
// bytes (see `MoshCompression.swift`) using the C zlib library's own
// `compress`/`uncompress` (RFC 1950 "zlib format": a 2-byte header plus an
// Adler-32 trailer around a raw DEFLATE stream) -- not Apple's
// Compression.framework, whose "ZLIB" algorithm constant is actually raw
// DEFLATE without that wrapper and therefore isn't wire-compatible with a
// real mosh-server. Importing the system zlib.h directly here is what makes
// this the exact same library mosh itself links against.
#import <zlib.h>

#endif
