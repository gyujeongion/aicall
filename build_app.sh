#!/bin/zsh
# AI 통화 앱 빌드: dist/AICall.app (Developer ID 서명 — 권한을 한 번만 주면 재빌드해도 유지)
set -e
cd "$(dirname "$0")"
[ -f .build.env ] && source .build.env       # 내 서명 정보(공개 레포에 넣지 않음): AICALL_SIGN_ID, AICALL_BUNDLE_ID
ID="${AICALL_SIGN_ID:--}"                    # 없으면 임시 서명(-). 권한을 재빌드 후에도 유지하려면 Developer ID 인증서 해시
BID="${AICALL_BUNDLE_ID:-io.github.gyujeongion.aicall}"
APP=dist/AICall.app
rm -rf $APP; mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
swiftc -O -target arm64-apple-macos14.4 app/AICall.swift -o $APP/Contents/MacOS/AICall
for b in arsear phonectl; do swiftc -O -target arm64-apple-macos14.4 $b.swift -o $APP/Contents/Resources/$b; done
cp agent.py phone.py live.py aicall app/assets/AICall.icns $APP/Contents/Resources/   # aicall: 첫 설정 화면이 doctor·setup으로 쓴다
cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>ko</string>
<key>CFBundleAllowMixedLocalizations</key><true/>
<key>CFBundleIdentifier</key><string>$BID</string>
<key>CFBundleName</key><string>AI 통화</string>
<key>CFBundleDisplayName</key><string>AI 통화</string>
<key>CFBundleExecutable</key><string>AICall</string>
<key>CFBundleIconFile</key><string>AICall</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.4</string>
<key>NSContactsUsageDescription</key><string>연락처 이름으로 전화를 걸고, 통화 상대 이름을 보여 주기 위해 연락처를 읽습니다. 연락처는 이 맥 밖으로 보내지 않습니다.</string>
<key>NSAudioCaptureUsageDescription</key><string>통화 소리(전화 중계 데몬 출력)를 듣고 받아쓰기 위해 시스템 오디오를 녹음합니다.</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>통화 소리를 듣고 받아쓰기 위해 가상 오디오 장치(BlackHole) 입력을 읽습니다.</string>
</dict></plist>
PL
for b in arsear phonectl; do codesign -f -s "$ID" -i $BID.$b $APP/Contents/Resources/$b; done
codesign -f -s "$ID" $APP
codesign -dv $APP 2>&1 | grep -E "Authority=Developer|Identifier"
