# Sourced by the other scripts.
#
# Xcode is optional. Without it the Command Line Tools provide the toolchain, but their newest
# SDK declares SwiftUI's @State as a macro whose plugin only Xcode carries, so the build falls
# back to the macOS 26 SDK, which does not need it. Our deployment target is macOS 14 and the
# Liquid Glass parts are guarded by #available, so nothing is lost.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* \
      && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if [[ -z "${DEVELOPER_DIR:-}" && -z "${SDKROOT:-}" ]]; then
    for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk \
               /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk; do
        if [[ -d "$sdk" ]]; then
            export SDKROOT="$sdk"
            break
        fi
    done
fi
