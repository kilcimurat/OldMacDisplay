#!/bin/bash
#
# Verifies that a built Receiver binary can actually run on macOS Catalina
# 10.15 on the 2013 Intel iMac.
#
# This exists because the compiler will happily let you link a framework that
# only exists on a newer macOS: the build succeeds on the M2 Max and then the
# app dies at launch on the iMac with a dyld error. Checking the Mach-O is the
# only way to catch that without owning the old machine.
#
# Usage: ./Scripts/verify-catalina.sh <path-to-binary>
set -euo pipefail

BINARY="${1:?usage: verify-catalina.sh <binary>}"
[[ -f "$BINARY" ]] || { echo "error: no such file: $BINARY" >&2; exit 1; }

# The app is universal. Only the x86_64 slice ever runs on the iMac, so every
# check below inspects that slice specifically - the arm64 slice legitimately
# has a 11.0 minimum, since Apple Silicon never shipped earlier.
ARCH_FLAG=(-arch x86_64)

fail=0
pass() { printf '  \033[1;32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; fail=1; }

echo "Verifying $(basename "$BINARY") for macOS 10.15 / x86_64"

# 1. Architecture must include x86_64; the 2013 iMac is Intel.
if lipo -archs "$BINARY" | tr ' ' '\n' | grep -qx 'x86_64'; then
    pass "architecture includes x86_64 ($(lipo -archs "$BINARY"))"
else
    bad "architecture is $(lipo -archs "$BINARY"), needs x86_64"
fi

# 2. Deployment target must be <= 10.15, or dyld refuses to load it.
minos="$(vtool "${ARCH_FLAG[@]}" -show-build "$BINARY" 2>/dev/null | awk '/minos/ {print $2; exit}')"
if [[ -z "$minos" ]]; then
    bad "could not read minimum OS version"
elif [[ "$(printf '%s\n10.15\n' "$minos" | sort -V | head -1)" == "$minos" ]]; then
    pass "minimum macOS is $minos"
else
    bad "minimum macOS is $minos, must be <= 10.15"
fi

# 3. No Swift Concurrency runtime dependency.
#    async/await back-deploys to 10.15 only if libswift_Concurrency.dylib is
#    embedded in the bundle; Shared and Receiver avoid concurrency entirely so
#    this must stay absent.
if otool "${ARCH_FLAG[@]}" -L "$BINARY" | grep -q 'libswift_Concurrency'; then
    bad "links libswift_Concurrency.dylib (Shared/Receiver must stay concurrency-free)"
else
    pass "no Swift Concurrency runtime dependency"
fi

# 4. Every NON-weak dependency must exist on Catalina. Weak ones are fine:
#    dyld tolerates them being missing. Anything strongly linked that shipped
#    after 10.15 is a launch-time crash on the iMac.
#
#    This allowlist is the set of system dylibs and Swift overlays present in
#    macOS 10.15. Add to it only after confirming the library shipped in 10.15.
CATALINA_SAFE='^/System/Library/Frameworks/(AVFoundation|AppKit|Foundation|CoreGraphics|CoreFoundation|CoreServices|CoreMedia|CoreVideo|CoreAudio|AudioToolbox|VideoToolbox|Metal|MetalKit|QuartzCore|IOKit|IOSurface|Security|SystemConfiguration|Network|Carbon|ApplicationServices|OpenGL|Accelerate)\.framework/|^/usr/lib/(libSystem\.B|libc\+\+\.1|libobjc\.A|libz\.1)\.dylib$|^/usr/lib/swift/libswift(AVFoundation|Core|CoreAudio|CoreFoundation|CoreGraphics|CoreImage|CoreMedia|CoreVideo|Darwin|Dispatch|Foundation|IOKit|Metal|MetalKit|Network|ObjectiveC|QuartzCore|XPC|AppKit|os|simd)\.dylib$'

strong_deps="$(otool "${ARCH_FLAG[@]}" -l "$BINARY" \
    | awk '/^ *cmd LC_LOAD_DYLIB$/ {want=1} /^ *cmd LC_LOAD_WEAK_DYLIB$/ {want=0} /^ *name / {if (want) print $2; want=0}')"

unknown=""
while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    if ! printf '%s' "$dep" | grep -Eq "$CATALINA_SAFE"; then
        unknown="$unknown$dep"$'\n'
    fi
done <<< "$strong_deps"

if [[ -z "$unknown" ]]; then
    pass "all $(printf '%s' "$strong_deps" | grep -c . ) strongly-linked dylibs exist on 10.15"
else
    bad "strongly links libraries not known to exist on Catalina:"
    printf '       %s\n' $unknown
    echo "       (if one of these did ship in 10.15, add it to CATALINA_SAFE)"
fi

# 5. Report the weakly-linked post-Catalina overlays for visibility. These are
#    pulled in automatically by the Swift SDK overlays and are safe.
weak_new="$(otool "${ARCH_FLAG[@]}" -l "$BINARY" \
    | awk '/^ *cmd LC_LOAD_WEAK_DYLIB$/ {want=1} /^ *name / {if (want) print $2; want=0}' \
    | grep -E 'UniformTypeIdentifiers|OSLog|Concurrency|Observation|_StringProcessing|ScreenCaptureKit' || true)"
if [[ -n "$weak_new" ]]; then
    printf '  \033[1;33minfo\033[0m weak (safe if absent on 10.15):\n'
    printf '       %s\n' $weak_new
fi

if [[ "$fail" -eq 0 ]]; then
    printf '\033[1;32mReceiver binary is Catalina-compatible.\033[0m\n'
else
    printf '\033[1;31mReceiver binary would NOT run on Catalina.\033[0m\n' >&2
    exit 1
fi
