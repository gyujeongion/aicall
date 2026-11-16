#!/bin/zsh
# Builds the "AICall Mic" / "AICall Speaker" virtual audio pair from unmodified BlackHole source (GPL-3.0).
# Audio written to "AICall Speaker" comes out of "AICall Mic"; the phone app uses "AICall Mic" as its microphone.
# BlackHole is not vendored here — this script clones it and only changes build-time settings.
set -e
cd "$(dirname "$0")"
REV=6008d29                                   # BlackHole commit this was tested with
[ -d src ] || git clone https://github.com/ExistentialAudio/BlackHole.git src
git -C src checkout -q $REV
BID="${AICALL_BUNDLE_ID:-io.github.gyujeongion.aicall}.vmic"
DEFS='$GCC_PREPROCESSOR_DEFINITIONS kDriver_Name=\"AICall\" kPlugIn_BundleID=\"'$BID'\" kPlugIn_Icon=\"BlackHole.icns\" kHas_Driver_Name_Format=false kNumber_Of_Channels=1 kDevice_Name=\"AICall\ Mic\" kDevice_HasInput=true kDevice_HasOutput=false kDevice2_Name=\"AICall\ Speaker\" kDevice2_IsHidden=false kDevice2_HasInput=false kDevice2_HasOutput=true kManufacturer_Name=\"AICall\"'
xcodebuild -project src/BlackHole.xcodeproj -configuration Release -target BlackHole \
  CONFIGURATION_BUILD_DIR="$PWD/build/Release" PRODUCT_BUNDLE_IDENTIFIER="$BID" CODE_SIGN_IDENTITY=- \
  "GCC_PREPROCESSOR_DEFINITIONS=$DEFS" >/dev/null
rm -rf AICall.driver && cp -R build/Release/BlackHole.driver AICall.driver
echo "built vmic/AICall.driver — install with:"
echo "  sudo cp -R vmic/AICall.driver /Library/Audio/Plug-Ins/HAL/ && sudo killall coreaudiod"
