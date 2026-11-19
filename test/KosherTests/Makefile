# Objective-C Unit Tests for Facebook Kosher Policy Engine
#
# Run on macOS with Xcode Command Line Tools installed:
#   make test-sim
# Or build an iOS arm64 binary with the iPhoneOS SDK:
#   make build-ios

ROOT = ../..
BUILD_DIR = .build

CORE_SRCS = \
	$(ROOT)/src/Core/FBPlus.m \
	$(ROOT)/src/Core/FBPPrefs.m \
	$(ROOT)/src/Core/FBPResources.m \
	$(ROOT)/src/Core/FBPTrace.m

KOSHER_SRCS = \
	$(ROOT)/src/Kosher/FBPKosherTypes.m \
	$(ROOT)/src/Kosher/FBPKosherDiagnostics.m \
	$(ROOT)/src/Kosher/FBPKosherCompatibilityMonitor.m \
	$(ROOT)/src/Kosher/FBPKosherPolicyStore.m \
	$(ROOT)/src/Kosher/FBPKosherModeration.m \
	$(ROOT)/src/Kosher/FBPKosherPolicyEngine.m \
	$(ROOT)/src/Kosher/FBPKosherContentFilter.m \
	$(ROOT)/src/Kosher/FBPKosherMarketplaceGuard.m

TEST_SRCS = \
	FBPKosherPolicyTests.m

ALL_SRCS = $(CORE_SRCS) $(KOSHER_SRCS) $(TEST_SRCS)

INCLUDES = \
	-I$(ROOT)/src/Core \
	-I$(ROOT)/src/Kosher

COMMON_CFLAGS = -fobjc-arc -Wall -Werror -std=gnu11 -DFBP_VERSION='@"1.0.8-kosher"' $(INCLUDES)
FRAMEWORKS = -framework Foundation -framework UIKit -framework Security -framework CoreText

SIM_BIN = $(BUILD_DIR)/FBPKosherPolicyTests-sim
IOS_BIN = $(BUILD_DIR)/FBPKosherPolicyTests-ios

.PHONY: all check-env build-sim test-sim build-ios clean

all: build-sim

check-env:
	@command -v xcrun >/dev/null 2>&1 || { \
		echo "ERROR: xcrun/Xcode Command Line Tools are required to compile Objective-C iOS tests." >&2; \
		exit 1; \
	}

build-sim: check-env
	@mkdir -p $(BUILD_DIR)
	xcrun --sdk iphonesimulator clang \
		-target arm64-apple-ios14.0-simulator \
		$(COMMON_CFLAGS) $(ALL_SRCS) $(FRAMEWORKS) -o $(SIM_BIN)

test-sim: build-sim
	xcrun simctl list devices available | head -n 20
	$(SIM_BIN)

build-ios: check-env
	@mkdir -p $(BUILD_DIR)
	xcrun --sdk iphoneos clang \
		-arch arm64 -miphoneos-version-min=14.0 \
		$(COMMON_CFLAGS) $(ALL_SRCS) $(FRAMEWORKS) -o $(IOS_BIN)

clean:
	rm -rf $(BUILD_DIR)
