#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_PROPERTIES="$PROJECT_DIR/android/local.properties"
DEFAULT_SDK_DIR="$HOME/Library/Android/sdk"

red() { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
info() { printf "\n%s\n" "$*"; }

pass_count=0
fail_count=0
warn_count=0

pass() { green "PASS: $*"; ((pass_count+=1)); }
fail() { red "FAIL: $*"; ((fail_count+=1)); }
warn() { yellow "WARN: $*"; ((warn_count+=1)); }

extract_sdk_dir() {
  if [[ -f "$LOCAL_PROPERTIES" ]]; then
    awk -F= '/^sdk\.dir=/{print $2}' "$LOCAL_PROPERTIES" | tail -n1
  fi
}

normalize_path() {
  local p="$1"
  p="${p//\\:/:}"
  p="${p//\\/}"
  printf "%s" "$p"
}

info "Project: $PROJECT_DIR"

sdk_dir="$(extract_sdk_dir || true)"
sdk_dir="$(normalize_path "$sdk_dir")"
if [[ -z "$sdk_dir" ]]; then
  warn "android/local.properties has no sdk.dir."
  sdk_dir="$DEFAULT_SDK_DIR"
  warn "Using fallback check path: $sdk_dir"
else
  info "sdk.dir from local.properties: $sdk_dir"
fi

info "1) Java runtime"
if command -v java >/dev/null 2>&1; then
  java_out="$(java -version 2>&1 || true)"
  if [[ "$java_out" == *"Unable to locate a Java Runtime"* ]]; then
    fail "java exists but no runtime is configured."
  else
    major="$(printf "%s" "$java_out" | awk -F '[\".]' '/version/ {print $2; exit}')"
    if [[ -z "$major" ]]; then
      warn "Could not parse Java version. Output: $java_out"
    elif (( major < 17 || major > 21 )); then
      fail "Java major version $major is unsupported for typical Flutter Android builds. Use 17 or 21."
    else
      pass "Java version looks good ($major)."
    fi
  fi
else
  fail "java command not found."
fi

info "2) Android Studio"
if [[ -d "/Applications/Android Studio.app" ]]; then
  pass "Android Studio found at /Applications/Android Studio.app"
else
  fail "Android Studio not found in /Applications."
fi

info "3) Android SDK"
if [[ -d "$sdk_dir" ]]; then
  pass "SDK directory exists: $sdk_dir"
else
  fail "SDK directory does not exist: $sdk_dir"
fi

for d in platform-tools build-tools platforms cmdline-tools; do
  if [[ -d "$sdk_dir/$d" ]]; then
    pass "SDK component folder exists: $d"
  else
    fail "Missing SDK component folder: $sdk_dir/$d"
  fi
done

if [[ -x "$sdk_dir/cmdline-tools/latest/bin/sdkmanager" ]]; then
  pass "sdkmanager found"
else
  warn "sdkmanager not found at $sdk_dir/cmdline-tools/latest/bin/sdkmanager"
fi

info "4) Flutter binary"
if [[ -x "$HOME/Development/flutter/bin/flutter" ]]; then
  pass "Flutter binary exists at ~/Development/flutter/bin/flutter"
else
  warn "Flutter binary not found at ~/Development/flutter/bin/flutter"
fi

info "5) local.properties sanity"
if [[ -f "$LOCAL_PROPERTIES" ]]; then
  if grep -q '^flutter\.sdk=' "$LOCAL_PROPERTIES"; then
    pass "flutter.sdk is set in local.properties"
  else
    fail "flutter.sdk missing from local.properties"
  fi

  if grep -q '^sdk\.dir=' "$LOCAL_PROPERTIES"; then
    pass "sdk.dir is set in local.properties"
  else
    fail "sdk.dir missing from local.properties"
  fi
else
  fail "Missing file: $LOCAL_PROPERTIES"
fi

info "Summary"
printf "PASS=%d  WARN=%d  FAIL=%d\n" "$pass_count" "$warn_count" "$fail_count"

if (( fail_count > 0 )); then
  cat <<'FIXES'

Recommended next steps:
1) Install Android Studio and open it once.
2) In Android Studio SDK Manager, install:
   - Android SDK Platform (latest)
   - Android SDK Build-Tools (latest)
   - Android SDK Platform-Tools
   - Android SDK Command-line Tools (latest)
3) Ensure java is 17 or 21 (not 25).
4) Update android/local.properties sdk.dir to your SDK path.
   Example:
     sdk.dir=/Users/jeff/Library/Android/sdk
5) Run:
   flutter doctor --android-licenses
   flutter clean
   flutter pub get
   flutter run
FIXES
  exit 1
fi

exit 0
