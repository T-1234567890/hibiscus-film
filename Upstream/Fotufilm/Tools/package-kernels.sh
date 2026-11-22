#!/bin/bash
# Package the same generated kernels and host shim used by Fotufilm's Apple hosts.
# Usage: package-kernels.sh MATCHED_ENGINE_CHECKOUT DEVICE_KERNELS SIM_KERNELS NEW_OUTPUT.xcframework
set -euo pipefail
engine="$(cd "${1:?provide the upstream checkout}" && pwd)"
revision=d534fc99c7eee10a839d3bc4ae26501c286b32a0
[[ "$(git -C "$engine" rev-parse HEAD)" == "$revision" ]] || { echo "Expected Fotufilm $revision" >&2; exit 1; }
device="$(cd "${2:?provide device kernels}" && pwd)"
simulator="$(cd "${3:?provide simulator kernels}" && pwd)"
output="${4:?provide a new output path}"
native="$engine/Sources/FotufilmHalide"
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
inputs=()
for sdk in iphoneos iphonesimulator; do
    kernels="$device"
    target=arm64-apple-ios18.0
    if [[ "$sdk" == iphonesimulator ]]; then kernels="$simulator"; target=arm64-apple-ios18.0-simulator; fi
    mkdir "$temp/$sdk"
    xcrun --sdk "$sdk" clang++ -std=c++17 -O2 -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
        -target "$target" -DFOTUFILM_HALIDE_IOS_AOT=1 -I"$kernels" -I"$native/include" \
        -ffile-prefix-map="$engine"=Fotufilm -c "$native/FotufilmHalideIOS.cpp" -o "$temp/$sdk/shim.o"
    xcrun libtool -static -o "$temp/$sdk/libFotufilmHalide.a" "$temp/$sdk/shim.o" "$kernels"/*.a
    inputs+=(-library "$temp/$sdk/libFotufilmHalide.a" -headers "$native/include")
done
xcodebuild -create-xcframework "${inputs[@]}" -output "$output"
