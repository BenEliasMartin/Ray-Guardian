#!/bin/sh
set -eu
source_plist="${SRCROOT}/RayGuardian/Info.plist"
output_plist="${DERIVED_FILE_DIR}/GuardianInfo.plist"
cp "$source_plist" "$output_plist"
# DAT treats partially supplied attestation as a configuration failure. Developer Mode
# uses no attestation dictionary keys, including when Xcode has an Apple signing team.
case "${META_APP_ID:-0}" in
  ''|0)
    /usr/libexec/PlistBuddy -c 'Delete :MWDAT:MetaAppID' "$output_plist"
    /usr/libexec/PlistBuddy -c 'Delete :MWDAT:ClientToken' "$output_plist"
    /usr/libexec/PlistBuddy -c 'Delete :MWDAT:TeamID' "$output_plist"
    ;;
  *)
    if [ -z "${META_CLIENT_TOKEN:-}" ] || [ -z "${DEVELOPMENT_TEAM:-}" ]; then
      echo 'error: Registered Meta apps need META_CLIENT_TOKEN and DEVELOPMENT_TEAM; use META_APP_ID=0 for Developer Mode.' >&2
      exit 1
    fi
    ;;
esac
