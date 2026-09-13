import configparser
from pathlib import Path
import subprocess

import yaml


ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / "sources/proaudio-player-native"
WEBUI = ROOT / "sources/proaudio-player-webui"
FEATURE = "feature/universal-audio-backend"


def service_from(path: str, name: str = "proaudio-player"):
    compose = yaml.safe_load((ROOT / path).read_text(encoding="utf-8"))
    return compose["services"][name]


def test_sources_are_separate_feature_submodules():
    modules = (ROOT / ".gitmodules").read_text(encoding="utf-8")

    assert "path = sources/proaudio-player-native" in modules
    assert "url = ../proaudio-player-native.git" in modules
    assert "path = sources/proaudio-player-webui" in modules
    assert "url = ../proaudio-player-webui.git" in modules
    assert modules.count(f"branch = {FEATURE}") == 2
    assert "sources/proaudio-player]" not in modules

    for path in ("sources/proaudio-player-native", "sources/proaudio-player-webui"):
        stage = subprocess.check_output(
            ["git", "ls-files", "--stage", path],
            cwd=ROOT,
            text=True,
        )
        assert stage.startswith("160000 ")


def test_default_compose_keeps_player_on_host_network():
    service = service_from("compose.yaml")

    assert service["platform"] == "${DOCKER_PLATFORM:-linux/amd64}"
    assert service["build"]["target"] == "runtime"
    assert service["network_mode"] == "host"
    assert service["environment"]["AUDIO_MODE"] == "${AUDIO_MODE:-null}"
    assert service["restart"] == "unless-stopped"
    assert "devices" not in service
    assert "proaudio-runtime:/run/proaudio-player" in service["volumes"]


def test_dlna_worker_is_private_and_matches_native_endpoint():
    compose = yaml.safe_load((ROOT / "compose.yaml").read_text(encoding="utf-8"))
    worker = compose["services"]["dlna-worker"]

    assert worker["build"]["target"] == "dlna-worker"
    assert "network_mode" not in worker
    assert "ports" not in worker
    assert worker["networks"]["dlna-private"]["ipv4_address"] == "169.254.253.1"
    assert "proaudio-runtime:/run/proaudio-player" in worker["volumes"]
    assert worker["environment"]["PULSE_SINK"] == "proaudio_player_music"

    network = compose["networks"]["dlna-private"]
    assert network["driver"] == "bridge"
    assert network["ipam"]["config"][0]["subnet"] == "169.254.253.0/29"

    script = (ROOT / "docker/run-dlna-worker.sh").read_text(encoding="utf-8")
    assert "--interface-name=eth0" in script
    assert "--port=49494" in script
    assert "--gstout-initial-volume-db=0.0" in script

    native_dlna = (NATIVE / "src/dlna.rs").read_text(encoding="utf-8")
    assert "http://169.254.253.1:49494/upnp/control/rendertransport1" in native_dlna


def test_hardware_override_exposes_sound_and_udev_only():
    service = service_from("compose.hardware.yaml")

    assert service["environment"]["AUDIO_MODE"] == "hardware"
    assert service["devices"] == ["/dev/snd:/dev/snd"]
    assert service["group_add"] == ["audio"]
    assert service["volumes"] == ["/run/udev:/run/udev:ro"]


def test_dockerfile_builds_projects_through_their_own_build_contracts():
    dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")

    assert "FROM rust:1.88-bookworm AS native-builder" in dockerfile
    assert "libpulse-dev" in dockerfile
    assert "pkg-config" in dockerfile
    assert "COPY sources/proaudio-player-native/ ./" in dockerfile
    assert "cargo build --locked --release" in dockerfile

    assert "FROM node:22-bookworm-slim AS webui-builder" in dockerfile
    assert "package-lock.json" in dockerfile
    assert "npm ci --no-audit --no-fund" in dockerfile
    assert "npm run build" in dockerfile
    assert "COPY --from=webui-builder /build/proaudio-player-webui/dist/" in dockerfile
    assert "sources/proaudio-player-webui/static" not in dockerfile


def test_runtime_packages_native_policy_instead_of_docker_fork():
    dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
    runtime = dockerfile.split("FROM debian:trixie-slim AS runtime", maxsplit=1)[1]

    assert "scripts/audio-buses.sh" in runtime
    assert "scripts/proaudio-player-output-watch" in runtime
    assert "/usr/libexec/proaudio-player/audio-buses.sh" in runtime
    assert "/usr/libexec/proaudio-player/proaudio-player-output-watch" in runtime
    assert not (ROOT / "docker/watch-audio-output.sh").exists()


def test_runtime_contains_native_external_command_contract():
    dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
    runtime = dockerfile.split("FROM debian:trixie-slim AS runtime", maxsplit=1)[1]

    for required in (
        "alsa-utils",
        "avahi-daemon",
        "iproute2",
        "mpc",
        "mpd",
        "mpv",
        "pipewire-pulse",
        "procps",
        "pulseaudio-utils",
        "shairport-sync",
        "systemd",
        "wireplumber",
    ):
        assert required in runtime

    assert "gmediarender" not in runtime


def test_spotifyd_matches_native_mpris_contract():
    dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")

    assert "libdbus-1-dev" in dockerfile
    assert "--features pulseaudio_backend,dbus_mpris" in dockerfile
    assert "proaudio-player-mpris.conf" in dockerfile


def test_supervisor_runs_one_native_control_plane_without_dlna_duplicate():
    config = configparser.RawConfigParser()
    loaded = config.read(ROOT / "docker/supervisord.conf", encoding="utf-8")

    assert loaded
    required = {
        "program:system-dbus",
        "program:session-dbus",
        "program:pipewire",
        "program:pipewire-pulse",
        "program:wireplumber",
        "program:audio-buses",
        "program:audio-output-watch",
        "program:avahi",
        "program:mpd",
        "program:airplay",
        "program:spotify",
        "program:native",
    }
    assert required.issubset(config.sections())
    assert "program:dlna" not in config.sections()

    assert "proaudio-player-native" in config["program:native"]["command"]
    assert "PROAUDIO_WEBUI_DIR" in config["program:native"]["environment"]
    assert "PROAUDIO_AUDIO_ENV" in config["program:native"]["environment"]
    assert "proaudio-player-output-watch" in config["program:audio-output-watch"]["command"]


def test_test_mode_uses_native_parking_fallback_not_docker_test_sink():
    buses = (ROOT / "docker/run-audio-buses.sh").read_text(encoding="utf-8")

    assert "/usr/libexec/proaudio-player/audio-buses.sh" in buses
    assert "module-null-sink" not in buses
    assert "proaudio_player_test_output" not in buses


def test_healthcheck_validates_complete_native_audio_graph():
    healthcheck = (ROOT / "docker/container-healthcheck.sh").read_text(encoding="utf-8")

    assert "/api/v1/health" in healthcheck
    for sink in (
        "proaudio_player_music",
        "proaudio_player_alert",
        "proaudio_player_master",
        "proaudio_player_parking",
    ):
        assert sink in healthcheck
    assert "audio-output-watch" in healthcheck


def test_fresh_hardware_start_does_not_require_saved_sink_file():
    dockerctl = (ROOT / "docker/proaudio-player-dockerctl").read_text(encoding="utf-8")

    assert '[[ -f "$OUTPUT_ENV" ]] || return 0' in dockerctl
    assert 'current="$(saved_sink)"' in dockerctl


def test_shell_scripts_parse_with_bash():
    for path in sorted((ROOT / "docker").glob("*.sh")):
        subprocess.run(["bash", "-n", str(path)], check=True)
    subprocess.run(
        ["bash", "-n", str(ROOT / "docker/proaudio-player-dockerctl")],
        check=True,
    )


def test_expected_feature_source_assets_exist():
    assert (NATIVE / "Cargo.toml").is_file()
    assert (NATIVE / "config/config.yaml.example").is_file()
    assert (NATIVE / "config/audio.env.example").is_file()
    assert (NATIVE / "scripts/audio-buses.sh").is_file()
    assert (NATIVE / "scripts/proaudio-player-output-watch").is_file()
    assert (NATIVE / "src/dlna.rs").is_file()
    assert (WEBUI / "package.json").is_file()
    assert (WEBUI / "package-lock.json").is_file()
    assert (WEBUI / "src").is_dir()
