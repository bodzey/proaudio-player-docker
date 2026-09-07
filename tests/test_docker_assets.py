import configparser
from pathlib import Path
import subprocess

import yaml


ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "sources/proaudio-player"


def service_from(path: str):
    compose = yaml.safe_load((ROOT / path).read_text(encoding="utf-8"))
    return compose["services"]["proaudio-player"]


def test_core_is_git_submodule_not_copied_source():
    modules = (ROOT / ".gitmodules").read_text(encoding="utf-8")
    assert "path = sources/proaudio-player" in modules
    assert "git@github.com:bodzey/proaudio_player.git" in modules
    assert not (ROOT / "src").exists()
    assert not (ROOT / "config").exists()

    stage = subprocess.check_output(
        ["git", "ls-files", "--stage", "sources/proaudio-player"],
        cwd=ROOT,
        text=True,
    )
    assert stage.startswith("160000 ")


def test_default_compose_uses_headless_null_audio():
    service = service_from("compose.yaml")

    assert service["network_mode"] == "host"
    assert service["environment"]["AUDIO_MODE"] == "null"
    assert "devices" not in service
    assert service["restart"] == "unless-stopped"


def test_hardware_override_exposes_only_sound_device():
    service = service_from("compose.hardware.yaml")

    assert service["environment"]["AUDIO_MODE"] == "hardware"
    assert service["environment"]["PHYSICAL_SINK"] == "${PROAUDIO_PHYSICAL_SINK:-AUTO}"
    assert service["environment"]["OUTPUT_VOLUME_PERCENT"] == "${PROAUDIO_OUTPUT_VOLUME_PERCENT:-100}"
    assert service["devices"] == ["/dev/snd:/dev/snd"]
    assert service["group_add"] == ["audio"]
    assert service["volumes"] == ["/run/udev:/run/udev:ro"]


def test_dockerfile_consumes_shared_core_assets():
    dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")

    for required in (
        "COPY sources/proaudio-player/pyproject.toml",
        "COPY sources/proaudio-player/src",
        "COPY sources/proaudio-player/config",
        "COPY sources/proaudio-player/scripts/audio-buses.sh",
        "COPY sources/proaudio-player/config/wireplumber/51-proaudio-soft-mixer.conf",
    ):
        assert required in dockerfile


def test_wireplumber_soft_mixer_is_baked_into_image():
    dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
    rule = (
        CORE / "config/wireplumber/51-proaudio-soft-mixer.conf"
    ).read_text(encoding="utf-8")

    assert "api.alsa.soft-mixer = true" in rule
    assert "sources/proaudio-player/config/wireplumber/51-proaudio-soft-mixer.conf" in dockerfile
    assert "docker-data/wireplumber" not in (
        ROOT / "compose.hardware.yaml"
    ).read_text(encoding="utf-8")


def test_runtime_image_contains_only_runtime_audio_dependencies():
    dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
    runtime = dockerfile.split("FROM debian:trixie-slim AS runtime", maxsplit=1)[1]

    for required in (
        "avahi-daemon",
        "ca-certificates",
        "gmediarender",
        "gstreamer1.0-pulseaudio",
        "mpc",
        "mpd",
        "mpv",
        "pipewire-pulse",
        "pulseaudio-utils",
        "shairport-sync",
        "wireplumber",
    ):
        assert required in runtime

    for build_or_unused in (
        "alsa-utils",
        "dbus-user-session",
        "espeak-ng",
        "ffmpeg",
        "pipewire-alsa",
        "python3-pip",
        "python3-venv",
    ):
        assert build_or_unused not in runtime


def test_build_only_tools_do_not_leak_into_runtime_image():
    dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
    entrypoint = (ROOT / "docker/docker-entrypoint.sh").read_text(encoding="utf-8")

    assert "FROM debian:trixie-slim AS python-builder" in dockerfile
    assert "FROM debian:trixie-slim AS announcements-builder" in dockerfile
    assert "COPY --from=python-builder" in dockerfile
    assert "COPY --from=announcements-builder" in dockerfile
    assert "/opt/proaudio-player/default-media" in entrypoint
    assert "generate-default-announcements.sh" not in entrypoint


def test_spotifyd_build_enables_only_required_backend():
    dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
    spotify_builder = dockerfile.split(
        "FROM rust:bookworm AS spotifyd-builder", maxsplit=1
    )[1].split("FROM debian:trixie-slim AS python-builder", maxsplit=1)[0]

    assert "--no-default-features --features pulseaudio_backend" in spotify_builder
    assert "dbus_mpris" not in spotify_builder
    assert "libasound2-dev" not in spotify_builder


def test_audio_discovery_and_safe_auto_selection_are_present():
    dockerctl = (ROOT / "docker/proaudio-player-dockerctl").read_text(encoding="utf-8")
    buses = (CORE / "scripts/audio-buses.sh").read_text(encoding="utf-8")

    assert "select-audio" in dockerctl
    assert "discover-audio.sh" in dockerctl
    assert "PROAUDIO_PHYSICAL_SINK=AUTO" in dockerctl
    assert '$2 != "auto_null"' in buses
    assert "OUTPUT_VOLUME_PERCENT" in buses


def test_supervisor_contains_required_headless_services():
    config = configparser.RawConfigParser()
    loaded = config.read(ROOT / "docker/supervisord.conf", encoding="utf-8")

    assert loaded
    assert {
        "program:pipewire",
        "program:pipewire-pulse",
        "program:wireplumber",
        "program:audio-buses",
        "program:alert-controller",
        "program:web",
        "program:mpd",
        "program:airplay",
        "program:dlna",
        "program:spotify",
    }.issubset(config.sections())

    assert config["program:web"]["user"] == "proaudio-player"
    assert "proaudio-player-web" in config["program:web"]["command"]
