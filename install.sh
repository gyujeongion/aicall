#!/bin/zsh
# AICall one-line installer:
#   curl -fsSL https://raw.githubusercontent.com/gyujeongion/aicall/main/install.sh | zsh
# Installs: sox, ffmpeg (Homebrew) · Python venv with websockets · AICall Mic/Speaker audio device · AICall.app · `aicall` CLI.
# Re-running updates everything in place. After install the app opens and asks for your OpenAI key, name and number.
set -e
REPO="https://github.com/gyujeongion/aicall"
SRC="$HOME/.local/share/aicall"
CONF="$HOME/.config/aicall"
DRIVER="/Library/Audio/Plug-Ins/HAL/AICall.driver"

step() { print -P "\n%F{green}==>%f %B$1%b"; }
die()  { print -P "%F{red}✗%f $1"; exit 1; }

[[ "$(uname -m)" == arm64 ]] || die "Apple Silicon Mac only."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 27 )) || print -P "%F{yellow}!%f macOS $major detected — calling uses the macOS 27 Phone app. Installing anyway."

step "Developer tools"
xcode-select -p >/dev/null 2>&1 || { xcode-select --install; die "Finish the Command Line Tools install window, then run this command again."; }

step "Homebrew packages (sox, ffmpeg)"
command -v brew >/dev/null || die "Homebrew is required: https://brew.sh — install it, then run this command again."
for p in sox ffmpeg; do brew list --formula $p >/dev/null 2>&1 || brew install $p; done

step "Source → $SRC"
if [[ -d "$SRC/.git" ]]; then git -C "$SRC" pull -q --ff-only; else git clone -q --depth 1 "$REPO" "$SRC"; fi
cd "$SRC"

step "Python environment"
mkdir -p "$CONF"
[[ -x "$CONF/venv/bin/python3" ]] || python3 -m venv "$CONF/venv"
"$CONF/venv/bin/pip" install -q --upgrade websockets

step "AICall Mic / Speaker audio device"
if [[ -d "$DRIVER" ]]; then
  echo "already installed"
else
  if xcodebuild -version >/dev/null 2>&1; then
    vmic/build_driver.sh                                     # builds from BlackHole source (needs full Xcode)
  else
    echo "Xcode not found — downloading the prebuilt device (BlackHole, GPL-3.0, build settings in vmic/build_driver.sh)"
    curl -fsSL -o /tmp/AICall.driver.zip "$REPO/releases/latest/download/AICall.driver.zip"
    rm -rf vmic/AICall.driver && ditto -x -k /tmp/AICall.driver.zip vmic/
  fi
  echo "Installing the audio device needs your Mac password:"
  sudo cp -R vmic/AICall.driver /Library/Audio/Plug-Ins/HAL/ && sudo killall coreaudiod
fi

step "AICall.app"
./build_app.sh >/dev/null
osascript -e 'quit app "AICall"' >/dev/null 2>&1 || true
rm -rf /Applications/AICall.app && ditto dist/AICall.app /Applications/AICall.app

step "aicall CLI"
ln -sf "$SRC/aicall" "$(brew --prefix)/bin/aicall"

step "Done"
echo "The app is opening and will walk you through the rest (OpenAI key, your name and number, permissions)."
echo "Terminal alternative:  aicall setup   ·   check anytime:  aicall doctor"
open /Applications/AICall.app
