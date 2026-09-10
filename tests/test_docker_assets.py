import configparser
from pathlib import Path
import subprocess

import yaml


ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / "sources/proaudio-player-native"
WEBUI = ROOT / "sources/proaudio-player-webui"


def service_from(path: str):
    compose = yaml.safe_load((ROOT / path).read_text(encoding="utf-8"))
    return compose["services"]["proaudio-player"]


def test_dev_sources_are_separate_git_submodules():
    modules = (ROOT / ".gitmodules").read_text(encoding="utf-8")

    assert "path = sources/proaudio-player-native" in modules
    assert "url = ../proaudio-player-native.git" in modules
    assert "path = sources/proaudio-player-webui" in modules
    assert "url = ../proaudio-player-webui.git" in modules
    assert modules.count("branch = dev") == 2
    assert "sources/proaudio-player]" not in modules

    for path in ("sources/proaudio-player-native", "sources/proaudio-player-webui"):
        stage = subprocess.check_output(
            ["git", "ls-files", "--stage", path],
            cwd=ROOT,
            text=True,
        )
        assert stage.startswith("160000 ")


def test_default_compose_is_amd64_headless_test_runtime():
    service = service_from("compose.yaml")

    assert service["platform"] == "${DOCKER_PLATFORM:-linux/amd64}"
    assert service["network_mode"] == "host"
    assert service["environment"]["AUDIO_MODE"] == "${AUDIO_MODE:-null}"
    assert service["restart"] == "unless-stopped"
    assert "devices" not in service


def test_hardware_override_exposes_sound_and_udev_only():
    service = service_from("compose.hardware.yaml")

    assert service["environment"]["AUDIO_MODE"] == "hardware"
    assert service["devices"] == ["/dev/snd:/dev/snd"]
    assert service["group_add"] == ["audio"]
    assert service["volumes"] == ["/run/udev:/run/udev:ro"]


def test_dockerfile_builds_native_and_packages_external_webui():
    dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")

    assert "FROM rust:1.88-bookworm AS native-builder" in dockerfile
    assert "cargo build --locked --release" in dockerfile
    assert "sources/proaudio-player-native/src" in dockerfile
    assert "sources/proaudio-player-webui/index.html" in dockerfile
    assert "/usr/share/proaudio-player/webui" in dockerfile

    assert "python-builder" not in dockerfile
    assert "python3-venv" not in dockerfile
    assert "/venv/bin/proaudio-player" not in dockerfile


def test_spotifyd_matches_native_mpris_contract():
    dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")

    assert "libdbus-1-dev" in dockerfile
    assert "--features pulseaudio_backend,dbus_mpris" in dockerfile
    assert "proaudio-player-mpris.conf" in dockerfile


def test_runtime_contains_native_external_command_contract():
    dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
    runtime = dockerfile.split("FROM debian:trixie-slim AS runtime", maxsplit=1)[1]

    for required in (
        "alsa-utils",
        "avahi-daemon",
        "gmediarender",
        "gstreamer1.0-libav",
        "gstreamer1.0-plugins-good",
        "gstreamer1.0-pulseaudio",
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


def test_supervisor_runs_one_native_control_plane():
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
        "program:dlna",
        "program:spotify",
        "program:native",
    }
    assert required.issubset(config.sections())

    assert "proaudio-player-native" in config["program:native"]["command"]
    assert "PROAUDIO_WEBUI_DIR" in config["program:native"]["environment"]
    assert "program:web" not in config.sections()
    assert "program:alert-controller" not in config.sections()


def test_runtime_audio_output_selection_matches_native_contract():
    buses = (ROOT / "docker/run-audio-buses.sh").read_text(encoding="utf-8")
    watcher = (ROOT / "docker/watch-audio-output.sh").read_text(encoding="utf-8")
    dockerctl = (ROOT / "docker/proaudio-player-dockerctl").read_text(encoding="utf-8")

    assert "/var/lib/proaudio-player-alert/audio-output.env" in buses
    assert "/var/lib/proaudio-player-alert/audio-output.env" in watcher
    assert "audio-buses.sh switch" in watcher
    assert "docker-data/data/audio-output.env" in dockerctl


def test_healthcheck_uses_versioned_native_health_endpoint():
    healthcheck = (ROOT / "docker/container-healthcheck.sh").read_text(encoding="utf-8")

    assert "/api/v1/health" in healthcheck
    assert 'for service in system-dbus pipewire pipewire-pulse wireplumber audio-buses native' in healthcheck


def test_shell_scripts_parse_with_bash():
    for path in sorted((ROOT / "docker").glob("*.sh")):
        subprocess.run(["bash", "-n", str(path)], check=True)
    subprocess.run(
        ["bash", "-n", str(ROOT / "docker/proaudio-player-dockerctl")],
        check=True,
    )


def test_expected_dev_source_assets_exist():
    assert (NATIVE / "Cargo.toml").is_file()
    assert (NATIVE / "config/config.yaml.example").is_file()
    assert (NATIVE / "assets/announcements/alarm_start.mp3").is_file()
    assert (WEBUI / "index.html").is_file()
    assert (WEBUI / "static/app.js").is_file()
