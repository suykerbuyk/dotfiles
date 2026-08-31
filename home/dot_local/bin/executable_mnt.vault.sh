#!/usr/bin/env bash

# Copyright (c) 2026 John Suykerbuyk and SykeTech LTD
# SPDX-License-Identifier: MIT OR Apache-2.0

# mnt.vault.sh — mount, unmount, or report vault01's /ark01 tree.
#
# ONE mount, not 139. vault01 serves NFSv4, and NFSv4 crosses server-side
# filesystem boundaries in the protocol: the client walks into each nested ZFS
# child dataset on demand. Datasets that come and go therefore need no discovery
# pass here — that is the kernel's job now, and it is always current. The v3
# predecessor ran `showmount -e` and mounted all 139 exports individually.
#
# Mounting is DELIBERATE, never automatic. vault01 may or may not be online, so
# this script is the interface (no fstab auto-entry, no automount unit) and every
# path through it fails fast rather than hanging: a short reachability probe up
# front, and mount options that do not retry.
#
# Portability: Debian, Arch, RHEL, FreeBSD. The traps that shaped this file —
#   - mountpoint(1) is util-linux and does NOT exist on FreeBSD
#   - the NFSv4 option spelling differs (vers=4.2 vs nfsv4,minorversion=2)
#   - the mount-retry knob differs (retry=0 vs retrycnt=0)
#   - FreeBSD umount has no lazy (-l); it has -f only
#   - ping is useless as a probe: Linux -W is SECONDS, FreeBSD -W is MILLISECONDS
#     and FreeBSD's ping has no -w at all

set -euo pipefail

server="vault01.syketech.arpa"
remote_path="/ark01"
mount_point="/ark01"
probe_port=2049
probe_timeout=3

# lib.sh carries df_have and df_is_freebsd. It is deployed to $HOME beside this
# script, so its absence means a broken deployment worth reporting rather than
# papering over with a local uname test (the idiom consolidated away in iter 58).
lib="${XDG_CONFIG_HOME:-${HOME}/.config}/shell/lib.sh"
if [ ! -r "${lib}" ]; then
    printf 'mnt.vault: cannot read %s -- is the dotfiles deployment complete?\n' "${lib}" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "${lib}"

die() { printf 'mnt.vault: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

usage() {
    cat <<EOF
usage: ${0##*/} [mount|umount|status]

  mount    mount ${server}:${remote_path} at ${mount_point} over NFSv4 (default)
  umount   unmount ${mount_point}, escalating to a forced unmount if it is wedged
  status   report whether ${mount_point} is mounted, and whether ${server} answers

Mounting is deliberate: nothing here runs at boot.
EOF
}

# priv <cmd...> — run as root, however this host lets us. FreeBSD base ships
# neither sudo nor doas, so neither may be assumed present.
priv() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif df_have sudo; then
        sudo "$@"
    elif df_have doas; then
        doas "$@"
    else
        die "need root for '$1': not root, and neither sudo nor doas is installed"
    fi
}

# is_mounted <path> — no mountpoint(1) on FreeBSD, so read mount(8) instead.
# Both userlands print "<device> on <path> ...", and the surrounding spaces keep
# /ark01 from matching a hypothetical /ark011.
is_mounted() {
    mount | grep -qF " on $1 "
}

# server_reachable — a bounded TCP probe. It matters more than retry=0 does: a
# host that is powered off drops packets rather than refusing them, so a single
# connect() sits for the kernel's ~130s timeout, and no mount-retry setting
# shortens one attempt.
#
# The awkward part is telling "server is down" apart from "this bash was built
# without net redirections", since both make the redirect fail. Bash reports the
# latter as a MISSING PATHNAME, which is not evidence about the server -- so only
# that message is distrusted, and nc arbitrates when it is present.
server_reachable() {
    local err rc
    df_have timeout || return 0   # no way to bound the probe; defer to the mount

    err=$(timeout "${probe_timeout}" bash -c \
        "exec 3<>/dev/tcp/${server}/${probe_port}" 2>&1) && return 0
    rc=$?

    case "${err}" in
        *"No such file or directory"*)
            # /dev/tcp unsupported. Says nothing about the server.
            df_have nc || return 0
            nc -z -w "${probe_timeout}" "${server}" "${probe_port}" >/dev/null 2>&1
            return $?
            ;;
    esac
    # Refused, no route, unresolved, or timeout(1)'s 124. All real answers.
    return "${rc}"
}

# mount_opts — hard mounts, because /ark01/bkup takes real backup writes and a
# soft mount trades silent corruption for convenience. The fast-fail belongs to
# the mount ATTEMPT (retry=0 / retrycnt=0), not to the mounted state.
mount_opts() {
    if df_is_freebsd; then
        printf 'nfsv4,minorversion=2,hard,retrycnt=0'
    else
        printf 'vers=4.2,hard,retry=0'
    fi
}

do_mount() {
    if is_mounted "${mount_point}"; then
        say "${mount_point} is already mounted"
        return 0
    fi
    if ! server_reachable; then
        die "${server}:${probe_port} did not answer within ${probe_timeout}s -- not mounting"
    fi
    [ -d "${mount_point}" ] || priv mkdir -p "${mount_point}"

    say "Mounting ${server}:${remote_path} at ${mount_point} (NFSv4)"
    if ! priv mount -t nfs -o "$(mount_opts)" "${server}:${remote_path}" "${mount_point}"; then
        die "mount failed"
    fi
    say "Mounted. Nested datasets are traversed on access; no further mounts needed."
}

do_umount() {
    if ! is_mounted "${mount_point}"; then
        say "${mount_point} is not mounted"
        return 0
    fi
    say "Unmounting ${mount_point}"
    if priv umount "${mount_point}" 2>/dev/null; then
        say "Unmounted."
        return 0
    fi

    say "Clean unmount failed (server gone, or the mount is busy); forcing."
    if priv umount -f "${mount_point}" 2>/dev/null; then
        say "Force-unmounted."
        return 0
    fi
    # Lazy detach is Linux-only; FreeBSD's umount has no -l.
    if ! df_is_freebsd && priv umount -l "${mount_point}" 2>/dev/null; then
        say "Lazily detached; it will clear once the last reference closes."
        return 0
    fi
    die "could not unmount ${mount_point}"
}

do_status() {
    if is_mounted "${mount_point}"; then
        say "mount:  ${mount_point} MOUNTED"
        mount | grep -F " on ${mount_point} " | sed 's/^/        /'
    else
        say "mount:  ${mount_point} not mounted"
    fi
    if server_reachable; then
        say "server: ${server}:${probe_port} answers"
    else
        say "server: ${server}:${probe_port} did NOT answer within ${probe_timeout}s"
    fi
}

case "${1:-mount}" in
    mount)            do_mount ;;
    umount|unmount|u) do_umount ;;
    status|s)         do_status ;;
    -h|--help|help)   usage ;;
    *)                usage >&2; exit 2 ;;
esac
