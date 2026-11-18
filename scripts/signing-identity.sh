#!/bin/zsh
set -eu
# LUMA_SIGNING_IDENTITY can pin a certificate in automated builds.
if [[ -n "${LUMA_SIGNING_IDENTITY:-}" ]]; then
    if [[ "$LUMA_SIGNING_IDENTITY" == "-" ]]; then
        print -u2 "Luma requires a certificate signature; ad-hoc signing breaks saved Keychain access."
        exit 1
    fi
    print -r -- "$LUMA_SIGNING_IDENTITY"
    exit 0
fi
IDENTITIES="$(security find-identity -v -p codesigning)"
CERTIFICATES="$(print -r -- "$IDENTITIES" | sed -nE 's/^[[:space:]]*[0-9]+\) ([A-F0-9]{40}) ".*$/\1/p')"
COUNT="$(print -r -- "$CERTIFICATES" | awk 'NF { n++ } END { print n+0 }')"
if [[ "$COUNT" != "1" ]]; then
    print -u2 "Set LUMA_SIGNING_IDENTITY to a valid Apple signing certificate (found $COUNT identities)."
    print -u2 "The build stops instead of silently switching Keychain identity."
    exit 1
fi
print -r -- "$CERTIFICATES"
