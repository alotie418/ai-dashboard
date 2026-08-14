#!/usr/bin/env bash
#
# Archive the native SoloLedger app and export a Mac App Store package (2c-5, decision D5).
#
# WHY A SCRIPT AND NOT XCODE'S ARCHIVE BUTTON
#
#   The Team ID is deliberately NOT in this repository. Manual signing needs it, so it is
#   injected here, at build time, from the environment. Product ▸ Archive in Xcode.app has no
#   way to supply it and will fail to resolve the provisioning profile — that is expected, not
#   a bug to work around by committing the value.
#
#   Everything else signing-related IS committed and is not secret: the identity name
#   ("Apple Distribution") and the profile name ("SoloLedger MAS 1.0.1") live in
#   project.pbxproj's Release configuration; the export template lives in App/ExportOptions.plist.
#
# WHAT THIS SCRIPT HAS AND HAS NOT BEEN THROUGH
#
#   It has never produced an archive. 2c-5 committed it; running it for real — which needs the
#   certificates, the provisioning profile and a Release build — is a separately authorised
#   round. `--dry-run` exercises everything up to the point of invoking xcodebuild and is what
#   the guard tests use.
#
# USAGE
#
#   SOLOLEDGER_TEAM_ID=XXXXXXXXXX native/SoloLedger/scripts/archive-mas.sh [--dry-run] [--output DIR]
#
#   --dry-run   validate inputs, render the export options, print the commands, run nothing
#   --output    where the .xcarchive and the exported package go (default: a fresh temp dir)
#
# The Team ID is never printed, not even in --dry-run: the rendered options file is written
# with 600 permissions into a temporary directory and removed on exit.

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PACKAGE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly PROJECT="${PACKAGE_DIR}/App/SoloLedger.xcodeproj"
readonly EXPORT_TEMPLATE="${PACKAGE_DIR}/App/ExportOptions.plist"
readonly SCHEME="SoloLedger"
readonly TEAM_ID_PLACEHOLDER="__TEAM_ID__"

DRY_RUN=0
OUTPUT_DIR=""

die() { printf 'archive-mas: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '3,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --output)  [ $# -ge 2 ] || die "--output needs a directory"; OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

# ── Fail closed on every prerequisite, with a message that says what to do ────────────────────

[ -n "${SOLOLEDGER_TEAM_ID:-}" ] || die "SOLOLEDGER_TEAM_ID is not set.
  Manual signing needs the Apple Developer Team ID, and this repository deliberately does not
  contain it. Find it on the Membership page of developer.apple.com, then:
      SOLOLEDGER_TEAM_ID=XXXXXXXXXX $0 [--dry-run]
  Do not commit it, and do not add it to project.pbxproj — a guard test fails if you do."

case "${SOLOLEDGER_TEAM_ID}" in
  *[!A-Z0-9]* | "") die "SOLOLEDGER_TEAM_ID is not a 10-character Apple Team ID (uppercase letters and digits)." ;;
esac
[ "${#SOLOLEDGER_TEAM_ID}" -eq 10 ] \
  || die "SOLOLEDGER_TEAM_ID must be exactly 10 characters; got ${#SOLOLEDGER_TEAM_ID}."

[ -d "${PROJECT}" ] || die "cannot find the Xcode project at ${PROJECT}"
[ -f "${EXPORT_TEMPLATE}" ] || die "cannot find the export template at ${EXPORT_TEMPLATE}"

grep -q -- "${TEAM_ID_PLACEHOLDER}" "${EXPORT_TEMPLATE}" \
  || die "${EXPORT_TEMPLATE} no longer contains ${TEAM_ID_PLACEHOLDER}.
  Either the placeholder was renamed, or a real Team ID was committed into it. The template must
  stay a template; the substitution happens here, at build time."

if [ -z "${DEVELOPER_DIR:-}" ] && ! xcode-select -p 2>/dev/null | grep -q 'Xcode.app'; then
  die "xcode-select points at the Command Line Tools, which cannot archive.
  Re-run with: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer $0"
fi

TMP_ROOT="${TMPDIR:-/tmp}"
TMP_ROOT="${TMP_ROOT%/}"

if [ -z "${OUTPUT_DIR}" ]; then
  if [ "${DRY_RUN}" -eq 1 ]; then
    # A dry run must not litter: no output directory is created, and the path shown below is
    # what a real run would mint.
    OUTPUT_DIR="${TMP_ROOT}/sololedger-mas.<random>"
  else
    OUTPUT_DIR="$(mktemp -d "${TMP_ROOT}/sololedger-mas.XXXXXX")"
  fi
else
  mkdir -p "${OUTPUT_DIR}"
fi

readonly ARCHIVE_PATH="${OUTPUT_DIR}/SoloLedger.xcarchive"
readonly EXPORT_PATH="${OUTPUT_DIR}/export"

# ── Render the export options with the real Team ID, outside the repository ──────────────────
#
# A random DIRECTORY with a fixed filename inside it, not a random filename: BSD `mktemp` only
# substitutes an `XXXXXX` run at the END of the template, so `foo.XXXXXX.plist` yields a file
# literally called that — predictable, in a world-writable directory, and holding the Team ID.
# Measured while writing this script; the directory form avoids it and keeps the .plist suffix.

RENDERED_DIR="$(mktemp -d "${TMP_ROOT}/sololedger-export.XXXXXX")"
readonly RENDERED_DIR
chmod 700 "${RENDERED_DIR}"
readonly RENDERED_OPTIONS="${RENDERED_DIR}/ExportOptions.plist"
cleanup() { rm -rf "${RENDERED_DIR}"; }
trap cleanup EXIT
(umask 077; : > "${RENDERED_OPTIONS}")

# `sed` with the value in a variable, never on the command line of a logged command.
TEAM_ID="${SOLOLEDGER_TEAM_ID}" \
  perl -pe 's/\Q'"${TEAM_ID_PLACEHOLDER}"'\E/$ENV{TEAM_ID}/g' \
  < "${EXPORT_TEMPLATE}" > "${RENDERED_OPTIONS}"

grep -q -- "${TEAM_ID_PLACEHOLDER}" "${RENDERED_OPTIONS}" \
  && die "the placeholder survived substitution — refusing to export with a template value."

printf 'archive-mas: project      %s\n' "${PROJECT}"
printf 'archive-mas: scheme       %s (its ArchiveAction is Release; do not pass -configuration)\n' "${SCHEME}"
printf 'archive-mas: archive path %s\n' "${ARCHIVE_PATH}"
printf 'archive-mas: export path  %s\n' "${EXPORT_PATH}"
printf 'archive-mas: team id      <supplied from SOLOLEDGER_TEAM_ID, not printed>\n'

# ── The two commands ─────────────────────────────────────────────────────────────────────────

archive_cmd=(
  xcodebuild archive
  -project "${PROJECT}"
  -scheme "${SCHEME}"
  -destination 'generic/platform=macOS'
  -archivePath "${ARCHIVE_PATH}"
  "DEVELOPMENT_TEAM=${SOLOLEDGER_TEAM_ID}"
)
export_cmd=(
  xcodebuild -exportArchive
  -archivePath "${ARCHIVE_PATH}"
  -exportOptionsPlist "${RENDERED_OPTIONS}"
  -exportPath "${EXPORT_PATH}"
)

if [ "${DRY_RUN}" -eq 1 ]; then
  printf 'archive-mas: DRY RUN — nothing is built. Commands that would run:\n'
  printf '  %s\n' "${archive_cmd[*]//${SOLOLEDGER_TEAM_ID}/<TEAM_ID>}"
  printf '  %s\n' "${export_cmd[*]}"
  exit 0
fi

"${archive_cmd[@]}"
"${export_cmd[@]}"

printf 'archive-mas: done. Package is under %s\n' "${EXPORT_PATH}"
printf 'archive-mas: upload with Transporter.app; this script never uploads.\n'
