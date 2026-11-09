#!/bin/bash
set -euo pipefail

# Used by MSBuild for both the desktop dylib and the iOS static library.
platform="$1"
arch="$2"
output="$3"
source_dir="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$(dirname "$output")"
case "$platform" in
  macos) sdk=macosx; target="$arch-apple-macosx26.0"; kind=dynamic ;;
  ios) sdk=iphoneos; target="$arch-apple-ios18.0"; kind=static ;;
  simulator) sdk=iphonesimulator; target="$arch-apple-ios18.0-simulator"; kind=static ;;
  *) echo "Unsupported speech build platform: $platform" >&2; exit 1 ;;
esac
args=(-sdk "$(xcrun --sdk "$sdk" --show-sdk-path)" -target "$target"
      -swift-version 5 -O -parse-as-library -emit-library -module-name NovalistSpeech
      -framework Foundation -framework Speech -framework AVFoundation)
if [ "$kind" = static ]; then
  args+=(-static)
else
  args+=(-Xlinker -install_name -Xlinker @rpath/libNovalistSpeech.dylib)
fi
if [ "$platform" = macos ]; then
  sources=("$source_dir/NovalistSpeech.swift" "$source_dir/AppleMicrophone.swift")
else
  # The full SpeechAnalyzer bridge requires iOS 26+ and crashes on iOS 18.5.
  sources=("$source_dir/NovalistSpeech.iOS18.swift")
fi
xcrun --sdk "$sdk" swiftc "${args[@]}" "${sources[@]}" -o "$output"
