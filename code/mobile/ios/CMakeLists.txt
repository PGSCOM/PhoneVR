cmake_minimum_required(VERSION 3.16)
project(PhoneVR LANGUAGES C CXX Swift VERSION 2.0.0)

# ── Target platform ───────────────────────────────────────────────────────────
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0")
set(CMAKE_SWIFT_LANGUAGE_VERSION 5)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_EXTENSIONS OFF)

# ── Paths ─────────────────────────────────────────────────────────────────────
set(IOS_SRC_DIR    ${CMAKE_CURRENT_SOURCE_DIR}/PhoneVR)
set(ALVR_DIR       ${CMAKE_CURRENT_SOURCE_DIR}/../android/PhoneVR/ALVR)
# Rust produces libalvr_client_core.a here after:
#   cargo build --target aarch64-apple-ios --release -p alvr_client_core
set(ALVR_STATIC_LIB ${ALVR_DIR}/target/aarch64-apple-ios/release/libalvr_client_core.a)

# ── ObjC++ bridge (calls into the Rust ALVR C API) ────────────────────────────
add_library(pvr_bridge STATIC
    ${IOS_SRC_DIR}/AlvrBridge.mm
)
target_include_directories(pvr_bridge PUBLIC ${IOS_SRC_DIR})
set_target_properties(pvr_bridge PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
)

# ── Main application bundle ───────────────────────────────────────────────────
add_executable(PhoneVR MACOSX_BUNDLE
    ${IOS_SRC_DIR}/AppDelegate.swift
    ${IOS_SRC_DIR}/ALVRViewController.swift
    ${IOS_SRC_DIR}/HeadTracker.swift
    ${IOS_SRC_DIR}/VideoDecoder.swift
    ${IOS_SRC_DIR}/VRRenderer.swift
)

# Asset catalog and launch screen are copied by CMake as bundle resources.
target_sources(PhoneVR PRIVATE
    ${IOS_SRC_DIR}/Assets.xcassets
    ${IOS_SRC_DIR}/LaunchScreen.storyboard
)
set_source_files_properties(
    ${IOS_SRC_DIR}/Assets.xcassets
    ${IOS_SRC_DIR}/LaunchScreen.storyboard
    PROPERTIES MACOSX_PACKAGE_LOCATION Resources
)

set_target_properties(PhoneVR PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${IOS_SRC_DIR}/Info.plist"

    # ── Xcode build settings ──────────────────────────────────────────────────
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER    "com.phonevr.ios"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY       "1,2"
    XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET   "13.0"
    XCODE_ATTRIBUTE_SWIFT_VERSION                "5.0"
    XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER   "${IOS_SRC_DIR}/PhoneVR-Bridging-Header.h"
    XCODE_ATTRIBUTE_ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES YES

    # ── No code signing (unsigned .ipa) ───────────────────────────────────────
    XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY          ""
    XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED       "NO"
    XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED        "NO"
    XCODE_ATTRIBUTE_ENABLE_BITCODE              "NO"
)

# Ensure the Swift target can resolve #import "AlvrBridge.h" in the bridging header.
target_include_directories(PhoneVR PRIVATE ${IOS_SRC_DIR})

target_link_libraries(PhoneVR PRIVATE
    pvr_bridge
    ${ALVR_STATIC_LIB}

    # iOS system frameworks
    "-framework Foundation"
    "-framework UIKit"
    "-framework CoreMotion"
    "-framework Metal"
    "-framework MetalKit"
    "-framework VideoToolbox"
    "-framework CoreMedia"
    "-framework CoreVideo"
    "-framework AVFoundation"
    "-framework AudioToolbox"
    "-framework Network"
    "-framework SystemConfiguration"
    "-framework Security"

    # Rust standard library deps
    c++
    resolv
)
