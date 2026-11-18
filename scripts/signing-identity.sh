#!/bin/zsh
set -eu
# LUMA_SIGNING_IDENTITY can pin a certificate in automated builds.
if [[ "${LUMA_ADHOC_SIGNING:-0}" == "1" ]]; then
    if [[ "${LUMA_DISTRIBUTION_SIGNING:-0}" == "1" || -n "${LUMA_SIGNING_IDENTITY:-}" ]]; then
        print -u2 "Choose either LUMA_ADHOC_SIGNING or a certificate signing mode."
        exit 1
    fi
    print -r -- "-"
    exit 0
fi
if [[ "${LUMA_DISTRIBUTION_SIGNING:-0}" == "1" ]]; then
    IDENTITIES="$(security find-identity -v -p codesigning)"
    REQUESTED_IDENTITY="${LUMA_SIGNING_IDENTITY:-}"
    CERTIFICATES=()
    while IFS= read -r line; do
        if [[ "$line" =~ '^[[:space:]]*[0-9]+\) ([A-F0-9]{40}) "(Developer ID Application: .*)"$' ]]; then
            if [[ -z "$REQUESTED_IDENTITY" || "$REQUESTED_IDENTITY" == "${match[1]}" || "$REQUESTED_IDENTITY" == "${match[2]}" ]]; then
                CERTIFICATES+=("${match[1]}")
            fi
        fi
    done <<< "$IDENTITIES"
    if [[ "${#CERTIFICATES[@]}" != "1" ]]; then
        print -u2 "Distribution signing needs one valid Developer ID Application identity. Set LUMA_SIGNING_IDENTITY to its certificate name or SHA-1 fingerprint when several are installed."
        exit 1
    fi
    print -r -- "${CERTIFICATES[1]}"
    exit 0
fi
if [[ -n "${LUMA_SIGNING_IDENTITY:-}" ]]; then
    if [[ "$LUMA_SIGNING_IDENTITY" == "-" ]]; then
        print -u2 "Use LUMA_ADHOC_SIGNING=1 to explicitly select the certificate-free preview build."
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
