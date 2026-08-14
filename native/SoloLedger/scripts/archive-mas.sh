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
#   native/SoloLedger/scripts/archive-mas.sh --install-profile        # once per machine
#   SOLOLEDGER_TEAM_ID=XXXXXXXXXX native/SoloLedger/scripts/archive-mas.sh [--dry-run]
#
#   --dry-run         validate inputs, render the export options, print the commands, build nothing
#   --install-profile install build/embedded.provisionprofile into Xcode's profile directory
#   --output DIR      where the .xcarchive and the exported package go (default: a fresh temp dir)
#
# The profile must be INSTALLED, not merely present at build/embedded.provisionprofile: that path
# is what electron-builder reads, while xcodebuild resolves the profile by NAME out of Xcode's own
# directories. The script checks and refuses rather than failing later inside xcodebuild.
#
# The Team ID is never printed, not even in --dry-run: the rendered options file is written
# with 600 permissions into a temporary directory and removed on exit.

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PACKAGE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT="$(cd -- "${PACKAGE_DIR}/../.." && pwd)"
readonly PROJECT="${PACKAGE_DIR}/App/SoloLedger.xcodeproj"
readonly EXPORT_TEMPLATE="${PACKAGE_DIR}/App/ExportOptions.plist"
readonly SCHEME="SoloLedger"
readonly TEAM_ID_PLACEHOLDER="__TEAM_ID__"
readonly PROFILE_NAME="SoloLedger MAS 1.0.1"
readonly REPO_PROFILE="${REPO_ROOT}/build/embedded.provisionprofile"

# Where Xcode looks for manually-installed profiles. `PROVISIONING_PROFILE_SPECIFIER` resolves
# by NAME against these directories — never against a path inside the repository, which is the
# one place the project's own prerequisites tell you to put the file.
# `SOLOLEDGER_PROFILE_DIR` overrides the install destination; it exists so the install path can
# be exercised without writing into a real Xcode data directory.
readonly INSTALL_DIR="${SOLOLEDGER_PROFILE_DIR:-${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles}"
# The install destination is also the first place searched, so the override moves BOTH halves —
# a seam that redirected only the write would leave the check looking at the real directory and
# report "not installed" right after installing.
readonly PROFILE_DIRS=(
  "${INSTALL_DIR}"
  "${HOME}/Library/MobileDevice/Provisioning Profiles"
)

DRY_RUN=0
INSTALL_PROFILE=0
OUTPUT_DIR=""

die() { printf 'archive-mas: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '3,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)         DRY_RUN=1; shift ;;
    --install-profile) INSTALL_PROFILE=1; shift ;;
    --output)  [ $# -ge 2 ] || die "--output needs a directory"; OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

# ── The provisioning profile has to be INSTALLED, not merely present in the repo ──────────────
#
# `build/embedded.provisionprofile` is where every prerequisite list in this repository tells you
# to put the profile — because that is the path electron-builder reads. `xcodebuild` does not:
# manual signing resolves `PROVISIONING_PROFILE_SPECIFIER` by name against Xcode's own profile
# directories. Following the documented prerequisite and then archiving therefore used to fail
# deep inside xcodebuild with an unhelpful message. Detect it up front instead.

profile_name_of() {  # $1 = path to a .provisionprofile
  security cms -D -i "$1" 2>/dev/null | plutil -extract Name raw - 2>/dev/null
}

installed_profile_path() {
  local dir file
  for dir in "${PROFILE_DIRS[@]}"; do
    [ -d "${dir}" ] || continue
    for file in "${dir}"/*.provisionprofile "${dir}"/*.mobileprovision; do
      [ -f "${file}" ] || continue
      if [ "$(profile_name_of "${file}")" = "${PROFILE_NAME}" ]; then printf '%s' "${file}"; return 0; fi
    done
  done
  return 1
}

if [ "${INSTALL_PROFILE}" -eq 1 ]; then
  [ -f "${REPO_PROFILE}" ] || die "--install-profile needs ${REPO_PROFILE}, which is not there.
  Download the Mac App Store provisioning profile for com.alotie418.sololedger from the developer
  portal and save it to that path (it is gitignored and must never be committed)."
  uuid="$(security cms -D -i "${REPO_PROFILE}" 2>/dev/null | plutil -extract UUID raw - 2>/dev/null)" \
    || die "cannot decode ${REPO_PROFILE}"
  [ -n "${uuid}" ] || die "cannot read a UUID out of ${REPO_PROFILE}"
  name="$(profile_name_of "${REPO_PROFILE}")"
  [ "${name}" = "${PROFILE_NAME}" ] \
    || die "${REPO_PROFILE} is named \"${name}\", but the project asks for \"${PROFILE_NAME}\".
  Either install the right profile or update PROVISIONING_PROFILE_SPECIFIER in project.pbxproj
  (a guard test pins that name, so it fails until both agree)."
  if [ "${DRY_RUN}" -eq 1 ]; then
    printf 'archive-mas: DRY RUN — would install %s into %s/%s.provisionprofile\n' \
      "${REPO_PROFILE}" "${INSTALL_DIR}" "${uuid}"
  else
    mkdir -p "${INSTALL_DIR}"
    cp "${REPO_PROFILE}" "${INSTALL_DIR}/${uuid}.provisionprofile"
    printf 'archive-mas: installed "%s" into %s\n' "${PROFILE_NAME}" "${INSTALL_DIR}"
  fi
fi

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

if ! INSTALLED_PROFILE="$(installed_profile_path)"; then
  die "no installed provisioning profile is named \"${PROFILE_NAME}\".
  The project signs manually and resolves the profile BY NAME from Xcode's profile directories:
      ${PROFILE_DIRS[0]}
      ${PROFILE_DIRS[1]}
  Putting the file at build/embedded.provisionprofile is not enough — that path is where
  electron-builder reads it, not xcodebuild. Install it once with:
      $0 --install-profile
  (or double-click the .provisionprofile in Finder), then re-run."
fi
readonly INSTALLED_PROFILE
printf 'archive-mas: profile      "%s" (installed)\n' "${PROFILE_NAME}"

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

# The Team ID goes in through an xcconfig, NOT `DEVELOPMENT_TEAM=…` on the command line.
# xcodebuild echoes command-line build settings back in its "Build settings from command line:"
# preamble, which would put the value into every build log — the exact thing
# docs/MAS_SUBMISSION.md forbids, and something --dry-run redaction cannot help with because it
# happens during the real run. `XCODE_XCCONFIG_FILE` is applied as a global xcconfig and its
# contents are not reproduced in normal output.
#
# NOT YET OBSERVED against a real archive — no archive has been run. If a future log does show
# the value, this is the line to revisit.
readonly TEAM_XCCONFIG="${RENDERED_DIR}/team.xcconfig"
(umask 077; printf 'DEVELOPMENT_TEAM = %s\n' "${SOLOLEDGER_TEAM_ID}" > "${TEAM_XCCONFIG}")

archive_cmd=(
  xcodebuild archive
  -project "${PROJECT}"
  -scheme "${SCHEME}"
  -destination 'generic/platform=macOS'
  -archivePath "${ARCHIVE_PATH}"
)
export_cmd=(
  xcodebuild -exportArchive
  -archivePath "${ARCHIVE_PATH}"
  -exportOptionsPlist "${RENDERED_OPTIONS}"
  -exportPath "${EXPORT_PATH}"
)

case "${archive_cmd[*]} ${export_cmd[*]}" in
  *"${SOLOLEDGER_TEAM_ID}"*) die "internal error: the Team ID reached a command line — refusing to run." ;;
esac

if [ "${DRY_RUN}" -eq 1 ]; then
  printf 'archive-mas: DRY RUN — nothing is built. Commands that would run:\n'
  printf '  XCODE_XCCONFIG_FILE=%s \\\n    %s\n' "${TEAM_XCCONFIG}" "${archive_cmd[*]}"
  printf '  %s\n' "${export_cmd[*]}"
  exit 0
fi

XCODE_XCCONFIG_FILE="${TEAM_XCCONFIG}" "${archive_cmd[@]}"
"${export_cmd[@]}"

printf 'archive-mas: done. Package is under %s\n' "${EXPORT_PATH}"
printf 'archive-mas: upload with Transporter.app; this script never uploads.\n'
