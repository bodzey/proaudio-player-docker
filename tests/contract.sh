#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
    echo "contract test failed: $*" >&2
    exit 1
}

assert_contains() {
    local file="$1" needle="$2"
    grep -Fq -- "$needle" "$file" || fail "$file does not contain: $needle"
}

assert_not_contains() {
    local file="$1" needle="$2"
    if grep -Fiq -- "$needle" "$file"; then
        fail "$file unexpectedly contains: $needle"
    fi
}

assert_regex_absent() {
    local pattern="$1"
    shift
    if grep -RniE -- "$pattern" "$@" >/dev/null; then
        grep -RniE -- "$pattern" "$@" >&2 || true
        fail "forbidden pattern found: $pattern"
    fi
}

test_submodules() {
    assert_contains .gitmodules 'path = sources/proaudio-player-native'
    assert_contains .gitmodules 'url = ../proaudio-player-native.git'
    assert_contains .gitmodules 'path = sources/proaudio-player-webui'
    assert_contains .gitmodules 'url = ../proaudio-player-webui.git'

    [[ "$(grep -Fc $'\tbranch = dev' .gitmodules)" -eq 2 ]]         || fail "both source submodules must track dev"
    [[ "$(grep -Fc $'\tignore = all' .gitmodules)" -eq 2 ]]         || fail "both source submodules must ignore gitlink drift"

    for path in sources/proaudio-player-native sources/proaudio-player-webui; do
        git ls-files --stage "$path" | grep -q '^160000 '             || fail "$path is not recorded as a git submodule"
    done

    assert_contains docker/proaudio-player-dockerctl 'git submodule update --remote --checkout'
    assert_contains docker/proaudio-player-dockerctl 'bootstrap snapshot'
}

test_compose() {
    docker compose config --quiet
    docker compose -f compose.yaml -f compose.hardware.yaml config --quiet

    mapfile -t services < <(docker compose config --services)
    [[ "${#services[@]}" -eq 1 && "${services[0]}" == "proaudio-player" ]]         || fail "compose.yaml must define exactly one runtime service"

    assert_contains compose.yaml 'network_mode: host'
    assert_contains compose.yaml 'restart: unless-stopped'
    assert_not_contains compose.yaml 'rtprio:'
    assert_not_contains compose.yaml 'SYS_NICE'
    assert_not_contains compose.yaml 'privileged:'
    assert_contains compose.yaml 'AUDIO_MODE: "${AUDIO_MODE:-null}"'
    assert_contains compose.yaml 'PROAUDIO_DLNA_INTERFACE: "${PROAUDIO_DLNA_INTERFACE:-}"'
    assert_contains compose.yaml 'PROAUDIO_DEVICE_ID: "${PROAUDIO_DEVICE_ID:-}"'
    assert_contains compose.yaml 'PROAUDIO_DEVICE_NAME: "${PROAUDIO_DEVICE_NAME:-ProAudio Player}"'
    assert_contains compose.yaml 'PROAUDIO_API_MAJOR: "${PROAUDIO_API_MAJOR:-1}"'
    assert_not_contains compose.yaml 'PROAUDIO_LAN_INTERFACE'
    assert_not_contains compose.yaml 'platform:'
    assert_not_contains compose.yaml 'ports:'

    assert_contains compose.hardware.yaml 'AUDIO_MODE: hardware'
    assert_contains compose.hardware.yaml 'SYS_NICE'
    assert_contains compose.hardware.yaml 'rtprio:'
    assert_contains compose.hardware.yaml 'soft: 88'
    assert_contains compose.hardware.yaml 'hard: 88'
    assert_not_contains compose.yaml 'SYS_NICE'
    assert_not_contains compose.yaml 'privileged:'
    assert_not_contains compose.hardware.yaml 'privileged:'
    assert_contains compose.hardware.yaml 'c 116:* rwm'
    assert_contains compose.hardware.yaml '/dev/snd:/dev/snd'
    assert_contains compose.hardware.yaml '/run/udev:/run/udev:ro'
}

test_hardware_neutrality() {
    assert_regex_absent         'platform:[[:space:]].*amd64|--interface-name=eth0|PROAUDIO_LAN_INTERFACE|raspberry|bcm(27|28|43)|mmcblk|vc4'         Dockerfile compose.yaml compose.hardware.yaml docker

    assert_not_contains docker/run-dlna.sh '--interface-name=lo'
    assert_not_contains docker/run-dlna.sh 'eth0'
    assert_contains docker/docker-entrypoint.sh 'route get 239.255.255.250'
    assert_contains docker/docker-entrypoint.sh 'interface_is_usable_for_dlna'
}

test_build_contract() {
    assert_contains Dockerfile 'FROM rust:1.88-bookworm AS native-builder'
    assert_contains Dockerfile 'cargo build --locked --release'
    assert_contains Dockerfile 'FROM node:22-bookworm-slim AS webui-builder'
    assert_contains Dockerfile 'npm ci --no-audit --no-fund'
    assert_contains Dockerfile 'npm run build'
    assert_contains Dockerfile 'COPY --from=webui-builder /build/proaudio-player-webui/dist/'
    assert_contains Dockerfile 'scripts/audio-buses.sh'
    assert_contains Dockerfile 'scripts/proaudio-player-output-watch'
    assert_contains Dockerfile 'gmediarender'
    assert_contains Dockerfile 'gstreamer1.0-libav'
    assert_contains Dockerfile 'gstreamer1.0-plugins-good'
    assert_contains Dockerfile 'gstreamer1.0-pulseaudio'
    assert_contains Dockerfile '/usr/share/proaudio-player/announcements/'
    assert_contains docker/docker-entrypoint.sh 'DEFAULT_MEDIA_DIR=/usr/share/proaudio-player/announcements'
    assert_contains docker/docker-entrypoint.sh 'alarm_start.mp3 alarm_end.mp3 minute_silence.mp3'
    assert_contains docker/docker-entrypoint.sh '/usr/local/bin/configure-discovery.sh'
    assert_contains Dockerfile 'docker/configure-discovery.sh'
    assert_contains docker/configure-discovery.sh '_proaudio-player._tcp'
    assert_contains docker/configure-discovery.sh 'allow-interfaces=$DISCOVERY_INTERFACE'
    assert_contains docker/configure-discovery.sh 'disallow-other-stacks=no'
    assert_contains docker/docker-entrypoint.sh 'external-mdns-stack'
    assert_contains docker/docker-entrypoint.sh "ss -H -lun 'sport = :5353'"
    assert_contains docker/proaudio-player-dockerctl 'Host UDP/5353 sockets:'
    assert_contains docker/configure-discovery.sh '<txt-record>id=$device_id</txt-record>'
    assert_contains docker/configure-discovery.sh '<txt-record>api=$API_MAJOR</txt-record>'
    assert_contains docker/configure-discovery.sh '<txt-record>name=$escaped_display</txt-record>'
    assert_contains docker/configure-discovery.sh 'device-id'
    assert_contains docker/docker-entrypoint.sh 'if [[ ! -f "$MEDIA_DIR/$media_file" ]]'
}

test_python_free_runtime() {
    assert_contains Dockerfile 's6'
    assert_contains Dockerfile "grep -Eq '^(python([0-9.]|$|-)|libpython)'"
    assert_not_contains Dockerfile 'supervisor'
    assert_not_contains docker/docker-entrypoint.sh 'supervisor'
    assert_not_contains docker/container-healthcheck.sh 'supervisor'
    assert_not_contains docker/preflight.sh 'supervisor'
    assert_not_contains docker/proaudio-player-dockerctl 'supervisor'

    [[ ! -e docker/supervisord.conf ]] || fail "legacy supervisord.conf still exists"
    [[ ! -e requirements-test.txt ]] || fail "Python test requirements still exist"
    [[ ! -e tests/test_docker_assets.py ]] || fail "pytest contract tests still exist"

    if find docker tests -type f -name '*.py' -print -quit | grep -q .; then
        fail "Docker-owned Python source still exists"
    fi
}

test_s6_services() {
    assert_contains docker/docker-entrypoint.sh 'exec /usr/bin/s6-svscan /etc/proaudio-player/services'
    assert_contains docker/container-healthcheck.sh 's6-svstat -u'
    assert_contains docker/preflight.sh 's6-svscan'
    assert_contains docker/preflight.sh 's6-svstat'
    assert_contains docker/preflight.sh 'setpriv'
    assert_contains docker/proaudio-player-dockerctl 's6-svstat "$service"'

    for service in         system-dbus session-dbus pipewire pipewire-pulse wireplumber         audio-buses audio-output-watch avahi mpd airplay dlna spotify native; do
        assert_contains docker/s6-service-run "$service)"
        assert_contains Dockerfile "$service"
    done

    assert_contains docker/s6-service-run '/usr/local/bin/run-dlna.sh'
    assert_contains docker/s6-service-run 'ENABLE_DLNA audio'
    assert_contains docker/s6-service-run '/usr/local/bin/proaudio-player-native'
    assert_contains docker/s6-service-run 'PROAUDIO_AUDIO_ENV=/run/proaudio-player/audio.env'
    assert_contains docker/s6-service-run 'AUDIO_ENV=/run/proaudio-player/audio.env'
    assert_contains docker/s6-service-run 'wait_for_system_bus'
    assert_contains docker/s6-service-run 'wait_for_pipewire'
    assert_contains docker/s6-service-run 'run_as_realtime_player'
    assert_contains docker/s6-service-run '--inh-caps=+sys_nice'
    assert_contains docker/s6-service-run '--ambient-caps=+sys_nice'
    assert_contains docker/s6-service-run 'run_as_realtime_player /usr/bin/pipewire'
    assert_contains docker/s6-service-run 'run_as_realtime_player /usr/bin/pipewire-pulse'
    assert_contains docker/s6-service-run 'run_as_realtime_player /usr/bin/wireplumber --profile main-systemwide'
    assert_contains docker/s6-service-run 'wireplumber --profile main-systemwide'
    assert_contains Dockerfile 'timeout-kill'
    assert_contains Dockerfile 'flag-timeout-killpg'
    assert_contains docker/docker-entrypoint.sh 'set_optional_service_state'
    assert_contains docker/docker-entrypoint.sh 'service_dir/down'
    assert_not_contains Dockerfile 'DISABLE_RTKIT=1'
    assert_contains docker/50-proaudio-rt.conf 'rlimits.enabled = true'
    assert_contains docker/50-proaudio-rt.conf 'rtportal.enabled = false'
    assert_contains docker/50-proaudio-rt.conf 'rtkit.enabled = false'
    assert_contains Dockerfile '/etc/pipewire/pipewire.conf.d/50-proaudio-rt.conf'
    assert_contains Dockerfile '/etc/pipewire/pipewire-pulse.conf.d/50-proaudio-rt.conf'
}

test_runtime_policy() {
    assert_contains docker/run-audio-buses.sh '/usr/libexec/proaudio-player/audio-buses.sh'
    assert_contains docker/run-audio-buses.sh 'trap shutdown INT TERM'
    assert_contains docker/run-audio-buses.sh 'trap cleanup EXIT'
    assert_contains docker/run-audio-buses.sh 'cleaned_up=0'
    assert_not_contains docker/run-audio-buses.sh 'trap cleanup EXIT INT TERM'
    assert_not_contains docker/run-audio-buses.sh 'module-null-sink'
    assert_not_contains docker/run-audio-buses.sh 'proaudio_player_test_output'

    assert_contains docker/run-output-watch.sh 'proaudio-player-ready'
    assert_contains docker/run-output-watch.sh 'pactl info'
    assert_contains docker/run-output-watch.sh 'exec "$WATCHER"'

    assert_contains docker/container-healthcheck.sh '/api/v1/health'
    for sink in         proaudio_player_music proaudio_player_alert         proaudio_player_master proaudio_player_parking; do
        assert_contains docker/container-healthcheck.sh "$sink"
    done

    for command in         gmediarender mpd pipewire proaudio-player-native         shairport-sync spotifyd wireplumber; do
        assert_contains docker/preflight.sh "$command"
    done

    assert_contains docker/proaudio-player-mpris.conf 'own_prefix="org.mpris.MediaPlayer2.ShairportSync"'
    assert_contains docker/proaudio-player-mpris.conf 'own_prefix="org.gnome.ShairportSync"'
}

test_shell_syntax() {
    while IFS= read -r -d '' path; do
        bash -n "$path"
    done < <(find docker tests -type f \( -name '*.sh' -o -name 'proaudio-player-dockerctl' -o -name 's6-service-run' \) -print0)
}

test_obsolete_assets_absent() {
    [[ ! -e docker/run-dlna-worker.sh ]] || fail "obsolete DLNA sidecar launcher exists"
    assert_not_contains Dockerfile 'dlna-worker'
    assert_not_contains compose.yaml 'dlna-worker'
    assert_not_contains compose.yaml '169.254.253.'
    assert_not_contains compose.yaml 'proaudio-runtime'
}

test_submodules
test_compose
test_hardware_neutrality
test_build_contract
test_python_free_runtime
test_s6_services
test_runtime_policy
test_shell_syntax
test_obsolete_assets_absent

echo "Docker integration contract: OK"
