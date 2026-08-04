#!/usr/bin/env bash
#
# Build a KOReader OTA package and publish it to a self-hosted update server,
# so that "Check for updates" on the device picks it up. See doc/OTA_server.md
# for what the server has to look like.
#
# The two files a device needs end up side by side in the destination directory:
#
#   koreader-<model>-latest-<channel>.kotasync   the manifest it polls
#   koreader-<target>-<version>.tar.xz           the payload
#
# The payload is uploaded before the manifest, and the manifest is moved into
# place in one step, so a device checking mid-publish never sees a manifest
# pointing at a package that is not there yet.
#
# The destination is either HOST:DIR, reached over ssh, or a local directory,
# for when the machine that builds is also the one that serves. kotasync and the
# e-ink toolchains are Linux-only, so that is usually the server itself.

# Every ssh command below is assembled from local variables on purpose, so
# expanding them on this side is exactly what is wanted.
# shellcheck disable=SC2029

set -eo pipefail

declare -r SELF="${0##*/}"
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
declare -r REPO_DIR

# Overridable from the environment, and by the flags below.
TARGET="${OTA_TARGET:-kindlehf}"
MODEL="${OTA_MODEL:-}"
CHANNEL="${OTA_CHANNEL:-stable}"
DEST="${OTA_DEST:-}"
URL="${OTA_URL:-}"
KOTASYNC="${KOTASYNC:-}"
KEEP="${OTA_KEEP:-0}"

do_build=1
dry_run=0
kodev_opts=()

usage() {
    cat <<EOF
Build a KOReader OTA package and publish it to your own update server.

USAGE: ${SELF} --dest [USER@HOST:]/srv/koreader-ota [OPTIONS]

OPTIONS:

    -d, --dest DIR            where to publish: the directory your web server
                              serves. Required. (\$OTA_DEST)
                              HOST:DIR copies over ssh; a plain absolute path
                              publishes on this machine, which is what you want
                              when you build on the server itself. DIR after a
                              host may be relative (~/koreader-ota).
    -t, --target TARGET       build target, e.g. kindlehf, kindlepw2, kobo.
                              Default: ${TARGET}. (\$OTA_TARGET)
    -m, --model MODEL         model name in the manifest filename, i.e. what
                              Device:otaModel() reports. Defaults to the target,
                              which is right for kindle*/kobo/cervantes.
                              (\$OTA_MODEL)
    -c, --channel CHANNEL     stable or nightly. Default: ${CHANNEL}.
                              (\$OTA_CHANNEL)
    -u, --url URL             base URL of the server, e.g. http://nas:8080/. If
                              given, the published files are checked over HTTP
                              afterwards. (\$OTA_URL)
    -k, --keep N              after publishing, delete all but the N newest
                              payloads for this model. Default: 0, keep
                              everything. (\$OTA_KEEP)
    -n, --no-build            publish an already built package
    -i, --ignore-translation  passed through to kodev release
        --dry-run             build and generate the manifest, but only print
                              what would be uploaded or deleted
    -h, --help                this message

ENVIRONMENT:

    KOTASYNC   path to the kotasync binary. Otherwise it is looked up on \$PATH
               and under base/kotasync/. Build it with:
               make -C base/kotasync
               It is a Linux AppImage, and cross-compiling for an e-ink target
               needs a Linux toolchain too, so run this on Linux.

EXAMPLES:

    ${SELF} -d nas:/srv/koreader-ota -u http://nas:8080/ -k 3
    ${SELF} -d /srv/koreader-ota -u http://localhost:8080/ -k 3
EOF
}

info() {
    printf '\033[32;1m==> %s\033[0m\n' "$*"
}

warn() {
    printf '\033[33;1m%s\033[0m\n' "$*" >&2
}

err() {
    printf '\033[31;1mERROR: %s\033[0m\n' "$*" >&2
    exit 1
}

require_cmd() {
    local cmd
    for cmd in "$@"; do
        command -v "${cmd}" >/dev/null || err "${cmd} is not installed."
    done
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d | --dest)
            DEST="$2"
            shift 2
            ;;
        -t | --target)
            TARGET="$2"
            shift 2
            ;;
        -m | --model)
            MODEL="$2"
            shift 2
            ;;
        -c | --channel)
            CHANNEL="$2"
            shift 2
            ;;
        -u | --url)
            URL="$2"
            shift 2
            ;;
        -k | --keep)
            KEEP="$2"
            shift 2
            ;;
        -n | --no-build)
            do_build=0
            shift
            ;;
        -i | --ignore-translation)
            kodev_opts+=(--ignore-translation)
            shift
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            err "unrecognized argument: $1"
            ;;
    esac
done

[[ -n "${DEST}" ]] || {
    usage >&2
    err "--dest is required."
}
[[ "${CHANNEL}" == 'stable' || "${CHANNEL}" == 'nightly' ]] ||
    err "--channel must be stable or nightly, got: ${CHANNEL}"
[[ "${KEEP}" =~ ^[0-9]+$ ]] || err "--keep must be a number, got: ${KEEP}"

# A destination with a host part goes over ssh; a plain path is published on this
# machine, which is what you want when you build on the server itself.
if [[ "${DEST}" == *:* ]]; then
    is_remote=1
    remote_host="${DEST%%:*}"
    remote_dir="${DEST#*:}"
    [[ -n "${remote_host}" ]] || err "--dest has no host part: ${DEST}"
    [[ -n "${remote_dir}" ]] || err "--dest has no directory part: ${DEST}"
    # A quoted ~ is not expanded by the remote shell, and would create a
    # directory actually called "~". Paths without a leading / are already
    # relative to the remote home, so just drop the tilde.
    # The tilde is quoted throughout because it is a literal here: this is the
    # remote side's home, not ours.
    # shellcheck disable=SC2088
    case "${remote_dir}" in
        '~') remote_dir='.' ;;
        '~/'*) remote_dir="${remote_dir#'~/'}" ;;
        '~'*) err "--dest cannot use ~user paths, spell the directory out: ${remote_dir}" ;;
    esac
    require_cmd ssh scp
else
    is_remote=0
    remote_host=''
    remote_dir="${DEST}"
    [[ "${remote_dir}" == /* ]] ||
        err "a local --dest must be an absolute path, got: ${remote_dir}"
    [[ -d "${remote_dir}" || ! -e "${remote_dir}" ]] ||
        err "--dest is not a directory: ${remote_dir}"
fi
declare -r is_remote remote_host remote_dir

: "${MODEL:="${TARGET}"}"
require_cmd git tar

# Everything that touches the destination goes through these, so that publishing
# locally and over ssh are the same sequence of steps.
dest_mkdir() {
    if ((is_remote)); then
        ssh "${remote_host}" "mkdir -p -- '${remote_dir}'"
    else
        mkdir -p -- "${remote_dir}"
    fi
}

dest_cat() {
    if ((is_remote)); then
        ssh "${remote_host}" "cat -- '${remote_dir}/$1'"
    else
        cat -- "${remote_dir}/$1"
    fi
}

dest_put() {
    if ((is_remote)); then
        scp -- "$1" "${remote_host}:${remote_dir}/$2"
    elif [[ "$1" -ef "${remote_dir}/$2" ]]; then
        printf '    %s is already in place\n' "$2"
    else
        cp -- "$1" "${remote_dir}/$2"
    fi
}

dest_mv() {
    if ((is_remote)); then
        ssh "${remote_host}" "mv -f -- '${remote_dir}/$1' '${remote_dir}/$2'"
    else
        mv -f -- "${remote_dir}/$1" "${remote_dir}/$2"
    fi
}

dest_list() {
    if ((is_remote)); then
        ssh "${remote_host}" "ls -1t -- '${remote_dir}'"
    else
        ls -1t -- "${remote_dir}"
    fi
}

dest_rm() {
    local f
    if ((is_remote)); then
        local quoted=()
        for f in "$@"; do
            quoted+=("'${remote_dir}/${f}'")
        done
        ssh "${remote_host}" "rm -f -- ${quoted[*]}"
    else
        for f in "$@"; do
            rm -f -- "${remote_dir}/${f}"
        done
    fi
}

cd -- "${REPO_DIR}" || err "cannot enter ${REPO_DIR}"

# The kotasync binary is a Linux AppImage built out of koreader-base; it is what
# turns a .tar.xz into the manifest the device polls.
if [[ -z "${KOTASYNC}" ]]; then
    if command -v kotasync >/dev/null; then
        KOTASYNC="$(command -v kotasync)"
    else
        for candidate in base/kotasync/kotasync-*.AppImage; do
            if [[ -x "${candidate}" ]]; then
                KOTASYNC="${candidate}"
                break
            fi
        done
    fi
fi
[[ -n "${KOTASYNC}" && -x "${KOTASYNC}" ]] ||
    err "no kotasync binary found. Build it with: make -C base/kotasync"

# An AppImage self-mounts through FUSE 2, which plenty of distributions no
# longer ship, so unpack it instead — the same way koreader-base runs
# mkappimage. The runtime eats this argument; kotasync never sees it.
kotasync=("${KOTASYNC}")
if [[ "${KOTASYNC}" == *.AppImage ]]; then
    kotasync+=(--appimage-extract-and-run)
fi

# Mirror how the Makefile names a release: git describe, plus the commit date
# when HEAD is not exactly a tag. The device parses this to decide whether the
# package is newer than what it is running, so it has to carry a vYYYY.MM token.
version="$(git describe HEAD)"
if [[ "${version}" == *-* ]]; then
    version="${version}_$(git show -s --format=format:'%cd' --date=short HEAD)"
fi
declare -r package="koreader-${TARGET}-${version}.tar.xz"
declare -r manifest="koreader-${MODEL}-latest-${CHANNEL}.kotasync"

info "publishing ${MODEL}/${CHANNEL} from ${version}"
printf '    package:  %s\n    manifest: %s\n    dest:     %s\n' \
    "${package}" "${manifest}" "${DEST}"

if ((do_build)); then
    info "building ${TARGET}"
    ./kodev release "${kodev_opts[@]}" "${TARGET}" txz
fi
[[ -f "${package}" ]] || err "${package} does not exist. Drop --no-build to build it."

# mkrelease.sh puts this in every package; without it the launcher would delete
# files listed in the previously installed index. Cheap insurance against a
# hand-rolled tarball being published by mistake.
info "checking ${package}"
if ! grep -Fqx 'koreader/ota/package.index' < <(tar -tJf "${package}"); then
    err "${package} has no koreader/ota/package.index — build it with ./kodev release, not tar."
fi

# Reordering the new archive against the currently published manifest keeps
# unchanged files in their old block order, which turns the device's download
# into fewer, larger range requests.
previous="$(mktemp -t koreader-ota-previous.XXXXXX)"
declare -r previous
# shellcheck disable=SC2064
trap "rm -f -- '${previous}'" EXIT

reorder_opts=()
info "looking for a published manifest to reorder against"
if dest_cat "${manifest}" >"${previous}" 2>/dev/null && [[ -s "${previous}" ]]; then
    reorder_opts=(--reorder "${previous}")
    printf '    reordering against the %s already published\n' "${manifest}"
else
    printf '    none there yet, packing fresh\n'
fi

info "generating ${manifest}"
"${kotasync[@]}" make --manifest koreader/ota/package.index "${reorder_opts[@]}" \
    "${package}" "${manifest}"

if ((dry_run)); then
    warn "dry run: not publishing. Would have copied into ${remote_dir}:"
    printf '    %s\n' "${package}"
    printf '    %s (via .%s.new, then moved into place)\n' "${manifest}" "${manifest}"
else
    info "publishing to ${DEST}"
    dest_mkdir
    # Payload first: a manifest is only ever visible once its package is there.
    dest_put "${package}" "${package}"
    dest_put "${manifest}" ".${manifest}.new"
    dest_mv ".${manifest}.new" "${manifest}"
fi

# Old payloads are only useful as reorder input, and the manifest on the server
# covers that, so they are safe to drop. Opt-in all the same: it is a deletion,
# and often on a machine that is not this one.
if [[ "${KEEP}" -gt 0 ]]; then
    info "pruning old payloads, keeping the ${KEEP} newest"
    stale=()
    while IFS= read -r old; do
        [[ "${old}" != "${package}" ]] || continue
        stale+=("${old}")
    done < <(dest_list 2>/dev/null |
        grep -E "^koreader-${TARGET}-.*\.tar\.xz$" | tail -n "+$((KEEP + 1))" || true)
    if [[ "${#stale[@]}" -eq 0 ]]; then
        printf '    nothing to prune\n'
    elif ((dry_run)); then
        warn "dry run: would delete ${#stale[@]} file(s):"
        printf '    %s\n' "${stale[@]}"
    else
        printf '    deleting %s\n' "${stale[@]}"
        dest_rm "${stale[@]}"
    fi
fi

# The client aborts unless the reply to its *ranged* request carries
# Accept-Ranges, which stock nginx does not send. Worth catching here rather
# than on the device.
if [[ -n "${URL}" ]] && ((!dry_run)); then
    require_cmd curl
    info "checking ${URL%/}/ over HTTP"
    headers="$(curl -fsS -r 0-99 -o /dev/null -D - "${URL%/}/${package}")" ||
        err "cannot range-fetch ${URL%/}/${package}"
    if ! grep -Fqi 'accept-ranges: bytes' <<<"${headers}"; then
        err "$(printf '%s\n%s' \
            "${URL%/}/${package} answered without Accept-Ranges on the 206." \
            'KOReader will refuse this server. See doc/OTA_server.md.')"
    fi
    grep -Ei '^(HTTP/|accept-ranges|content-range)' <<<"${headers}" | sed 's/^/    /'
    curl -fsS -o /dev/null "${URL%/}/${manifest}" ||
        err "cannot fetch ${URL%/}/${manifest}"
    printf '    manifest reachable\n'
fi

info "done"
printf 'Set the update server on the device to: %s\n' "${URL:-http://<host>:<port>/}"

# vim: sw=4
