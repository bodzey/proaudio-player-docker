#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GIT_ALLOW_PROTOCOL=file
export GIT_AUTHOR_NAME='Source sync test'
export GIT_AUTHOR_EMAIL='source-sync@example.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

fail() {
    echo "source sync test failed: $*" >&2
    exit 1
}

for name in native webui; do
    git init -q -b dev "$TMP/$name"
    printf 'initial\n' >"$TMP/$name/tracked.txt"
    git -C "$TMP/$name" add tracked.txt
    git -C "$TMP/$name" commit -qm initial
done
printf '[package]\nname = "fixture"\n' >"$TMP/native/Cargo.toml"
printf '{}\n' >"$TMP/webui/package.json"
printf '{}\n' >"$TMP/webui/package-lock.json"
git -C "$TMP/native" add Cargo.toml
git -C "$TMP/native" commit -qm manifest
git -C "$TMP/webui" add package.json package-lock.json
git -C "$TMP/webui" commit -qm manifests

CHECKOUT="$TMP/adapter"
git init -q -b dev "$CHECKOUT"
mkdir -p "$CHECKOUT/docker"
cp "$ROOT/docker/proaudio-player-dockerctl" "$CHECKOUT/docker/"
for name in native webui; do
    git -C "$CHECKOUT" submodule add -q -b dev \
        "$TMP/$name" "sources/proaudio-player-$name"
done
git -C "$CHECKOUT" add .
git -C "$CHECKOUT" commit -qm adapter

NATIVE="$CHECKOUT/sources/proaudio-player-native"
WEBUI="$CHECKOUT/sources/proaudio-player-webui"
native_before="$(git -C "$NATIVE" rev-parse HEAD)"
webui_before="$(git -C "$WEBUI" rev-parse HEAD)"
for name in native webui; do
    printf 'remote update\n' >>"$TMP/$name/tracked.txt"
    git -C "$TMP/$name" commit -qam update
done

sync() {
    bash "$CHECKOUT/docker/proaudio-player-dockerctl" sync-sources \
        >"$TMP/sync.log" 2>&1
}

expect_rejection() {
    local reason="$1"
    if sync; then
        fail "sync accepted $reason"
    fi
    grep -Fq "$reason" "$TMP/sync.log" || {
        cat "$TMP/sync.log" >&2
        fail "sync did not report $reason"
    }
    [[ "$(git -C "$NATIVE" rev-parse HEAD)" == "$native_before" ]] ||
        fail 'native checkout changed before preflight completed'
    [[ "$(git -C "$WEBUI" rev-parse HEAD)" == "$webui_before" ]] ||
        fail 'webui checkout changed before preflight completed'
}

# Dirty second submodule must stop updates to the clean first one as well.
printf 'local edit\n' >>"$WEBUI/tracked.txt"
expect_rejection 'local changes'
grep -Fq 'local edit' "$WEBUI/tracked.txt" || fail 'local edit was lost'
git -C "$WEBUI" restore tracked.txt

printf 'staged edit\n' >>"$NATIVE/tracked.txt"
git -C "$NATIVE" add tracked.txt
expect_rejection 'local changes'
git -C "$NATIVE" restore --staged tracked.txt
git -C "$NATIVE" restore tracked.txt

printf 'untracked edit\n' >"$WEBUI/untracked.txt"
expect_rejection 'local changes'
[[ -f "$WEBUI/untracked.txt" ]] || fail 'untracked file was lost'
rm "$WEBUI/untracked.txt"

git -C "$WEBUI" commit -qm unpublished --allow-empty
webui_before="$(git -C "$WEBUI" rev-parse HEAD)"
expect_rejection 'commits outside origin/dev'
git -C "$WEBUI" checkout -q --detach HEAD^
webui_before="$(git -C "$WEBUI" rev-parse HEAD)"

git -C "$CHECKOUT" config -f .gitmodules \
    submodule.sources/proaudio-player-webui.branch main
expect_rejection 'must track dev'
git -C "$CHECKOUT" restore .gitmodules

sync || {
    cat "$TMP/sync.log" >&2
    fail 'clean sync failed'
}
for name in native webui; do
    [[ "$(git -C "$CHECKOUT/sources/proaudio-player-$name" rev-parse HEAD)" == "$(git -C "$TMP/$name" rev-parse HEAD)" ]] || fail "$name did not reach dev"
done
[[ -n "$(git -C "$CHECKOUT" status --porcelain)" ]] ||
    fail 'changed gitlinks are hidden from git status'

# An uninitialized submodule is not the parent repository, even when it is dirty.
git -C "$CHECKOUT" submodule deinit -q -f --all
printf 'parent edit\n' >"$CHECKOUT/untracked.txt"
sync || {
    cat "$TMP/sync.log" >&2
    fail 'initialization failed'
}
[[ -f "$NATIVE/Cargo.toml" && -f "$WEBUI/package.json" ]] ||
    fail 'source submodules were not initialized'

echo 'Source sync safety: OK'
