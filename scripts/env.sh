# Sourced by the other scripts. Prefers Xcode's toolchain when Xcode is installed
# but xcode-select still points at the Command Line Tools.
# Xcode is not needed to build, test or release MacUtil: the Command Line Tools carry the
# Swift toolchain, and scripts/build-app.sh joins the two architectures itself. Xcode is only
# used when it happens to be installed, and for getting a free signing certificate in the
# first place.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* \
      && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
