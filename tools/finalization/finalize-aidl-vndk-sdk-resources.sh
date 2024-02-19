#!/bin/bash

set -ex

function apply_droidstubs_hack() {
    if ! grep -q 'STOPSHIP: RESTORE THIS LOGIC WHEN DECLARING "REL" BUILD' "$top/build/soong/java/droidstubs.go" ; then
        git -C "$top/build/soong" apply --allow-empty ../../build/make/tools/finalization/build_soong_java_droidstubs.go.apply_hack.diff
    fi
}

function apply_resources_sdk_int_fix() {
    if ! grep -q 'public static final int RESOURCES_SDK_INT = SDK_INT;' "$top/frameworks/base/core/java/android/os/Build.java" ; then
        git -C "$top/frameworks/base" apply --allow-empty ../../build/make/tools/finalization/frameworks_base.apply_resource_sdk_int.diff
    fi
}

function finalize_bionic_ndk() {
    # Adding __ANDROID_API_<>__.
    # If this hasn't done then it's not used and not really needed. Still, let's check and add this.
    local api_level="$top/bionic/libc/include/android/api-level.h"
    if ! grep -q "\__.*$((${FINAL_PLATFORM_SDK_VERSION}))" $api_level ; then
        local tmpfile=$(mktemp /tmp/finalization.XXXXXX)
        echo "
/** Names the \"${FINAL_PLATFORM_CODENAME:0:1}\" API level ($FINAL_PLATFORM_SDK_VERSION), for comparison against \`__ANDROID_API__\`. */
#define __ANDROID_API_${FINAL_PLATFORM_CODENAME:0:1}__ $FINAL_PLATFORM_SDK_VERSION" > "$tmpfile"

        local api_level="$top/bionic/libc/include/android/api-level.h"
        sed -i -e "/__.*$((${FINAL_PLATFORM_SDK_VERSION}-1))/r""$tmpfile" $api_level

        rm "$tmpfile"
    fi
}

function finalize_modules_utils() {
    local shortCodename="${FINAL_PLATFORM_CODENAME:0:1}"
    local methodPlaceholder="INSERT_NEW_AT_LEAST_${shortCodename}_METHOD_HERE"

    local tmpfile=$(mktemp /tmp/finalization.XXXXXX)
    echo "    /** Checks if the device is running on a release version of Android $FINAL_PLATFORM_CODENAME or newer */
    @ChecksSdkIntAtLeast(api = $FINAL_PLATFORM_SDK_VERSION /* BUILD_VERSION_CODES.$FINAL_PLATFORM_CODENAME */)
    public static boolean isAtLeast${FINAL_PLATFORM_CODENAME:0:1}() {
        return SDK_INT >= $FINAL_PLATFORM_SDK_VERSION;
    }" > "$tmpfile"

    local javaFuncRegex='\/\*\*[^{]*isAtLeast'"${shortCodename}"'() {[^{}]*}'
    local javaFuncReplace="N;N;N;N;N;N;N;N; s/$javaFuncRegex/$methodPlaceholder/; /$javaFuncRegex/!{P;D};"

    local javaSdkLevel="$top/frameworks/libs/modules-utils/java/com/android/modules/utils/build/SdkLevel.java"
    sed -i "$javaFuncReplace" $javaSdkLevel

    sed -i "/${methodPlaceholder}"'/{
           r '"$tmpfile"'
           d}' $javaSdkLevel

    echo "// Checks if the device is running on release version of Android ${FINAL_PLATFORM_CODENAME:0:1} or newer.
inline bool IsAtLeast${FINAL_PLATFORM_CODENAME:0:1}() { return android_get_device_api_level() >= $FINAL_PLATFORM_SDK_VERSION; }" > "$tmpfile"

    local cppFuncRegex='\/\/[^{]*IsAtLeast'"${shortCodename}"'() {[^{}]*}'
    local cppFuncReplace="N;N;N;N;N;N; s/$cppFuncRegex/$methodPlaceholder/; /$cppFuncRegex/!{P;D};"

    local cppSdkLevel="$top/frameworks/libs/modules-utils/build/include/android-modules-utils/sdk_level.h"
    sed -i "$cppFuncReplace" $cppSdkLevel
    sed -i "/${methodPlaceholder}"'/{
           r '"$tmpfile"'
           d}' $cppSdkLevel

    rm "$tmpfile"
}

function finalize_aidl_vndk_sdk_resources() {
    local top="$(dirname "$0")"/../../../..
    source $top/build/make/tools/finalization/environment.sh

    local SDK_CODENAME="public static final int $FINAL_PLATFORM_CODENAME_JAVA = CUR_DEVELOPMENT;"
    local SDK_VERSION="public static final int $FINAL_PLATFORM_CODENAME_JAVA = $FINAL_PLATFORM_SDK_VERSION;"

    # default target to modify tree and build SDK
    local m="$top/build/soong/soong_ui.bash --make-mode TARGET_PRODUCT=aosp_arm64 TARGET_BUILD_VARIANT=userdebug DIST_DIR=out/dist"

    # The full process can be found at (INTERNAL) go/android-sdk-finalization.

    # apply droidstubs hack to prevent tools from incrementing an API version
    apply_droidstubs_hack

    # bionic/NDK
    finalize_bionic_ndk

    # VNDK definitions for new SDK version
    cp "$top/development/vndk/tools/definition-tool/datasets/vndk-lib-extra-list-current.txt" \
       "$top/development/vndk/tools/definition-tool/datasets/vndk-lib-extra-list-$FINAL_PLATFORM_SDK_VERSION.txt"

    AIDL_TRANSITIVE_FREEZE=true $m aidl-freeze-api create_reference_dumps

    # Generate ABI dumps
    ANDROID_BUILD_TOP="$top" \
        out/host/linux-x86/bin/create_reference_dumps \
        -p aosp_arm64 --build-variant user

    echo "NOTE: THIS INTENTIONALLY MAY FAIL AND REPAIR ITSELF (until 'DONE')"
    # Update new versions of files. See update-vndk-list.sh (which requires envsetup.sh)
    $m check-vndk-list || \
        { cp $top/out/soong/vndk/vndk.libraries.txt $top/build/make/target/product/gsi/current.txt; }
    echo "DONE: THIS INTENTIONALLY MAY FAIL AND REPAIR ITSELF"

    # Finalize SDK

    # frameworks/libs/modules-utils
    finalize_modules_utils

    # build/make
    local version_defaults="$top/build/make/core/version_defaults.mk"
    sed -i -e "s/PLATFORM_SDK_VERSION := .*/PLATFORM_SDK_VERSION := ${FINAL_PLATFORM_SDK_VERSION}/g" $version_defaults
    sed -i -e "s/PLATFORM_VERSION_LAST_STABLE := .*/PLATFORM_VERSION_LAST_STABLE := ${FINAL_PLATFORM_VERSION}/g" $version_defaults
    sed -i -e "s/sepolicy_major_vers := .*/sepolicy_major_vers := ${FINAL_PLATFORM_SDK_VERSION}/g" "$top/build/make/core/config.mk"
    cp "$top/build/make/target/product/gsi/current.txt" "$top/build/make/target/product/gsi/$FINAL_PLATFORM_SDK_VERSION.txt"

    # build/soong
    local codename_version="\"${FINAL_PLATFORM_CODENAME}\":     ${FINAL_PLATFORM_SDK_VERSION}"
    if ! grep -q "$codename_version" "$top/build/soong/android/api_levels.go" ; then
        sed -i -e "/:.*$((${FINAL_PLATFORM_SDK_VERSION}-1)),/a \\\t\t$codename_version," "$top/build/soong/android/api_levels.go"
    fi

    # cts
    echo ${FINAL_PLATFORM_VERSION} > "$top/cts/tests/tests/os/assets/platform_releases.txt"
    sed -i -e "s/EXPECTED_SDK = $((${FINAL_PLATFORM_SDK_VERSION}-1))/EXPECTED_SDK = ${FINAL_PLATFORM_SDK_VERSION}/g" "$top/cts/tests/tests/os/src/android/os/cts/BuildVersionTest.java"

    # libcore
    sed -i "s%$SDK_CODENAME%$SDK_VERSION%g" "$top/libcore/dalvik/src/main/java/dalvik/annotation/compat/VersionCodes.java"

    # platform_testing
    local version_codes="$top/platform_testing/libraries/compatibility-common-util/src/com/android/compatibility/common/util/VersionCodes.java"
    sed -i -e "/=.*$((${FINAL_PLATFORM_SDK_VERSION}-1));/a \\    ${SDK_VERSION}" $version_codes

    # Finalize resources
    "$top/frameworks/base/tools/aapt2/tools/finalize_res.py" \
           "$top/frameworks/base/core/res/res/values/public-staging.xml" \
           "$top/frameworks/base/core/res/res/values/public-final.xml"

    # frameworks/base
    sed -i "s%$SDK_CODENAME%$SDK_VERSION%g" "$top/frameworks/base/core/java/android/os/Build.java"
    apply_resources_sdk_int_fix
    sed -i -e "/=.*$((${FINAL_PLATFORM_SDK_VERSION}-1)),/a \\    SDK_${FINAL_PLATFORM_CODENAME_JAVA} = ${FINAL_PLATFORM_SDK_VERSION}," "$top/frameworks/base/tools/aapt/SdkConstants.h"
    sed -i -e "/=.*$((${FINAL_PLATFORM_SDK_VERSION}-1)),/a \\  SDK_${FINAL_PLATFORM_CODENAME_JAVA} = ${FINAL_PLATFORM_SDK_VERSION}," "$top/frameworks/base/tools/aapt2/SdkConstants.h"

    # Bump Mainline SDK extension version.
    local SDKEXT="packages/modules/SdkExtensions/"
    "$top/packages/modules/SdkExtensions/gen_sdk/bump_sdk.sh" ${FINAL_MAINLINE_EXTENSION}
    # Leave the last commit as a set of modified files.
    # The code to create a finalization topic will pick it up later.
    git -C ${SDKEXT} reset HEAD~1

    local version_defaults="$top/build/make/core/version_defaults.mk"
    sed -i -e "s/PLATFORM_SDK_EXTENSION_VERSION := .*/PLATFORM_SDK_EXTENSION_VERSION := ${FINAL_MAINLINE_EXTENSION}/g" $version_defaults

    # Force update current.txt
    $m clobber
    $m update-api
}

finalize_aidl_vndk_sdk_resources

