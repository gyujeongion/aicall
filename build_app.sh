#!/bin/zsh
# AI 통화 앱 빌드: dist/AICall.app — 같은 서명으로 계속 빌드해야 권한(기기 제어·오디오·마이크)이 재빌드 후에도 유지된다
set -e
cd "$(dirname "$0")"
[ -f .build.env ] && source .build.env       # 내 서명 정보(공개 레포에 넣지 않음): AICALL_SIGN_ID, AICALL_BUNDLE_ID
ID="${AICALL_SIGN_ID:-}"                     # 개발자 인증서가 있으면 그 해시. 없으면 아래 '이 맥 전용 서명'
KC=()
if [ -z "$ID" ]; then
  # 이 맥 전용 자체 서명 인증서를 한 번 만들어 전용 키체인에 둔다. 임시 서명(-)은 빌드마다 앱이 달라져 권한이 풀린다
  SD="$HOME/.config/aicall/signing"; KCF="$SD/aicall.keychain-db"; CN="AICall Local Signing"
  mkdir -p "$SD"; chmod 700 "$SD"
  if [ ! -f "$KCF" ]; then
    /usr/bin/openssl rand -hex 16 > "$SD/pass"; chmod 600 "$SD/pass"
    T=$(mktemp -d)
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -subj "/CN=$CN" -keyout "$T/k.pem" -out "$T/c.pem" \
      -addext "extendedKeyUsage=codeSigning" -addext "keyUsage=critical,digitalSignature" -addext "basicConstraints=critical,CA:false" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$T/k.pem" -in "$T/c.pem" -out "$T/c.p12" -passout pass:aicall
    security create-keychain -p "$(cat "$SD/pass")" "$KCF"
    security set-keychain-settings "$KCF"      # 자동 잠금 없음
    security unlock-keychain -p "$(cat "$SD/pass")" "$KCF"
    security import "$T/c.p12" -k "$KCF" -P aicall -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$(cat "$SD/pass")" "$KCF" >/dev/null
    rm -rf "$T"
  fi
  security unlock-keychain -p "$(cat "$SD/pass")" "$KCF"
  ID="$CN"; KC=(--keychain "$KCF")
fi
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
for b in arsear phonectl; do codesign -f -s "$ID" "${KC[@]}" -i $BID.$b $APP/Contents/Resources/$b; done
codesign -f -s "$ID" "${KC[@]}" $APP
codesign -dv $APP 2>&1 | grep -E "Authority=|Identifier"
