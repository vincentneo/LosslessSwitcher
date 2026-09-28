#!/bin/zsh
# Build LSOutput.driver (ad-hoc signed) next to this script.
# Install (admin): sudo ditto LSOutput.driver /Library/Audio/Plug-Ins/HAL/LSOutput.driver && sudo killall coreaudiod
set -e
cd "${0:A:h}"
rm -rf LSOutput.driver
mkdir -p LSOutput.driver/Contents/MacOS
clang -bundle -O2 -Wall -Wno-unused-function -mmacosx-version-min=13.0 -arch arm64 -arch x86_64 \
  -framework CoreAudio -framework CoreFoundation \
  -o LSOutput.driver/Contents/MacOS/LSOutput LSOutput.c
cp Info.plist LSOutput.driver/Contents/Info.plist
plutil -lint LSOutput.driver/Contents/Info.plist >/dev/null
codesign --force --sign - --timestamp=none LSOutput.driver
chmod -R a+rX LSOutput.driver # coreaudiod (_coreaudiod) must read it; ditto keeps the modes
codesign -dv LSOutput.driver 2>&1 | egrep "Identifier|Signature"
