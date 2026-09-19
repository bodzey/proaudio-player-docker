import configparser
from pathlib import Path
import re
import subprocess

import yaml


ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / "sources/proaudio-player-native"
WEBUI = ROOT / "sources/proaudio-player-webui"
SOURCE_BRANCH = "dev"


def compose():
    return yaml.safe_load((ROOT / "compose.yaml").read_text(encoding="utf-8"))


def service_from(path: str, name: str = "proaudio-player"):
    data = yaml.safe_load((ROOT / path).read_text(encoding="utf-8"))
    return data["services"][name]


def test_sources_are_separate_dev_submodules():
    modules = (ROOT / ".gitmodules").read_text(encoding="utf-8")

    assert "path = sources/proaudio-player-native" in modules
    assert "url = ../proaudio-player-native.git" in modules
    assert "path = sources/proaudio-player-webui" in modules
    assert "url = ../proaudio-player-webui.git" in modules
    assert modules.count(f"branch = {SOURCE_BRANCH}") == 2
    assert modules.count("ignore = all") == 2

    for path in ("sources/proaudio-player-native", "sources/proaudio-player-webui"):
        stage = subprocess.check_output(
            ["git", "ls-files", "--stage", path],
            cwd=ROOT,
            text=True,
        )
        assert stage.startswith("160000 ")


def test_dev_source_updates_do_not_require_gitlink_commits():
    dockerctl = (ROOT / "docker/proaudio-player-dockerctl").read_text(encoding="utf-8")

    assert "git submodule update --remote --checkout" in dockerctl
    assert "bootstrap snapshot" in dockerctl
    assert "Зафіксуйте змінені gitlink-и" not in dockerctl


def test_compose_has_exactly_one_runtime_container():
    data = compose()

    assert set(data["services"]) == {"proaudio-player"}
    assert "networks" not in data
    assert "volumes" not in data

    service = data["services"]["proaudio-player"]
    assert service["build"]["target"] == "runtime"
    assert service["network_mode"] == "host"
    assert service["restart"] == "unless-stopped"
    assert "platform" not in service
    assert "devices" not in service
    assert "ports" not in service


def test_default_runtime_is_hardware_neutral_and_uses_parking_mode():
    service = service_from("compose.yaml")

    assert service["environment"]["AUDIO_MODE"] == "${AUDIO_MODE:-null}"
    assert service["environment"]["ENABLE_DLNA"] == "${ENABLE_DLNA:-true}"
    assert "PROAUDIO_UPNP_PUBLIC" not in service["environment"]
    assert "PROAUDIO_LAN_INTERFACE" not in service["environment"]

    volumes = service["volumes"]
    assert "./docker-data/config:/etc/proaudio-player-alert" in volumes
    assert "./docker-data/data:/var/lib/proaudio-player-alert" in volumes
    assert "./docker-data/music:/srv/music" in volumes
    assert all("/dev/" not in volume for volume in volumes)


def test_no_architecture_or_board_specific_runtime_assumptions():
    paths = [
        ROOT / "Dockerfile",
        ROOT / "compose.yaml",
        ROOT / "docker/docker-entrypoint.sh",
        ROOT / "docker/run-dlna.sh",
        ROOT / "docker/supervisord.conf",
        ROOT / "docker/preflight.sh",
    ]
    text = "\n".join(path.read_text(encoding="utf-8") for path in paths)

    forbidden = (
        r"platform:\s*[^\n]*amd64",
        r"--interface-name=eth0",
        r"\bras(pberry)?pi\b",
        r"\bbcm(?:27|28|43)",
        r"\bmmcblk",
        r"\bvc4\b",
    )
    for pattern in forbidden:
        assert re.search(pattern, text, flags=re.IGNORECASE) is None, pattern


def test_dockerfile_builds_projects_through_their_own_contracts():
    dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")

    assert "FROM rust:1.88-bookworm AS native-builder" in dockerfile
    assert "COPY sources/proaudio-player-native/ ./" in dockerfile
    assert "cargo build --locked --release" in dockerfile

    assert "FROM node:22-bookworm-slim AS webui-builder" in dockerfile
    assert "npm ci --no-audit --no-fund" in dockerfile
    assert "npm run build" in dockerfile
    assert "COPY --from=webui-builder /build/proaudio-player-webui/dist/" in dockerfile

    assert "AS dlna-worker" not in dockerfile
    assert "gmediarender" in dockerfile
    assert "gstreamer1.0-libav" in dockerfile
    assert "gstreamer1.0-plugins-good" in dockerfile
    assert "gstreamer1.0-pulseaudio" in dockerfile
    assert "docker/run-dlna.sh" in dockerfile
    assert "config/avahi" not in dockerfile
    assert "iproute2" not in dockerfile


def test_integrated_dlna_keeps_native_public_and_transport_private():
    entrypoint = (ROOT / "docker/docker-entrypoint.sh").read_text(encoding="utf-8")
    script = (ROOT / "docker/run-dlna.sh").read_text(encoding="utf-8")

    assert "PROAUDIO_LAN_INTERFACE" not in entrypoint
    assert 'PROAUDIO_DLNA_ENDPOINT="http://127.0.0.1:$DLNA_PORT/' in entrypoint
    assert "export PROAUDIO_UPNP_PUBLIC=true" in entrypoint
    assert "export PROAUDIO_UPNP_PUBLIC=false" in entrypoint

    assert "--interface-name=lo" in script
    assert '--port="$port"' in script
    assert '--friendly-name="ProAudio Player Transport"' in script
    assert "--gstout-audiosink=pulsesink" in script
    assert "--mime-filter=audio" in script
    assert "49152" in script
    assert "eth0" not in script


def test_supervisor_runs_dlna_and_native_in_same_container():
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
    assert "run-dlna.sh" in config["program:dlna"]["command"]
    assert "ENABLE_DLNA" in config["program:dlna"]["command"]
    assert "proaudio-player-native" in config["program:native"]["command"]


def test_runtime_packages_native_audio_policy_instead_of_docker_fork():
    dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")

    assert "scripts/audio-buses.sh" in dockerfile
    assert "scripts/proaudio-player-output-watch" in dockerfile
    assert not (ROOT / "docker/watch-audio-output.sh").exists()


def test_runtime_uses_native_defaults_with_explicit_audio_overrides():
    entrypoint = (ROOT / "docker/docker-entrypoint.sh").read_text(encoding="utf-8")
    buses = (ROOT / "docker/run-audio-buses.sh").read_text(encoding="utf-8")
    supervisor = (ROOT / "docker/supervisord.conf").read_text(encoding="utf-8")

    assert "DEFAULTS_DIR=/opt/proaudio-player/defaults" in entrypoint
    assert "audio.env.override" in entrypoint
    assert '"$DEFAULTS_DIR/audio.env.example"' in entrypoint
    assert 'EFFECTIVE_AUDIO_ENV="$RUNTIME_DIR/audio.env"' in entrypoint
    assert "/run/proaudio-player/audio.env" in buses
    assert 'AUDIO_ENV="/run/proaudio-player/audio.env"' in supervisor


def test_hardware_override_is_optional_generic_linux_audio_adapter():
    service = service_from("compose.hardware.yaml")

    assert service["environment"]["AUDIO_MODE"] == "hardware"
    assert service["devices"] == ["/dev/snd:/dev/snd"]
    assert "group_add" not in service
    assert service["volumes"] == ["/run/udev:/run/udev:ro"]

    entrypoint = (ROOT / "docker/docker-entrypoint.sh").read_text(encoding="utf-8")
    assert "stat -c '%g'" in entrypoint
    assert 'getent group "$gid"' in entrypoint
    assert 'usermod -a -G "$group_name" proaudio-player' in entrypoint

    text = (ROOT / "compose.hardware.yaml").read_text(encoding="utf-8").lower()
    for marker in ("raspberry", "bcm", "usb:", "pci:"):
        assert marker not in text


def test_test_mode_uses_native_parking_fallback_not_docker_test_sink():
    buses = (ROOT / "docker/run-audio-buses.sh").read_text(encoding="utf-8")

    assert "/usr/libexec/proaudio-player/audio-buses.sh" in buses
    assert "module-null-sink" not in buses
    assert "proaudio_player_test_output" not in buses


def test_healthcheck_validates_single_container_runtime():
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
    assert "ENABLE_DLNA" in healthcheck
    assert "status dlna" in healthcheck


def test_preflight_contains_integrated_media_engines():
    preflight = (ROOT / "docker/preflight.sh").read_text(encoding="utf-8")

    for command in (
        "gmediarender",
        "mpd",
        "pipewire",
        "proaudio-player-native",
        "shairport-sync",
        "spotifyd",
        "wireplumber",
    ):
        assert command in preflight


def test_docker_runtime_applies_http_port_without_changing_native_source():
    entrypoint = (ROOT / "docker/docker-entrypoint.sh").read_text(encoding="utf-8")

    assert 'HTTP_PORT="${PROAUDIO_HTTP_PORT:-5371}"' in entrypoint
    assert "api|web" in entrypoint
    assert '"$CONFIG_DIR/config.yaml"' in entrypoint


def test_fresh_hardware_start_does_not_require_saved_sink_file():
    dockerctl = (ROOT / "docker/proaudio-player-dockerctl").read_text(encoding="utf-8")

    assert '[[ -f "$OUTPUT_ENV" ]] || return 0' in dockerctl
    assert 'current="$(saved_sink)"' in dockerctl
    assert "архітектури хоста" in dockerctl


def test_compose_lifecycle_removes_obsolete_sidecars():
    dockerctl = (ROOT / "docker/proaudio-player-dockerctl").read_text(encoding="utf-8")

    assert dockerctl.count("up -d --build --remove-orphans") == 2
    assert '"${base[@]}" down --remove-orphans' in dockerctl


def test_shell_scripts_parse_with_bash():
    for path in sorted((ROOT / "docker").glob("*.sh")):
        subprocess.run(["bash", "-n", str(path)], check=True)
    subprocess.run(
        ["bash", "-n", str(ROOT / "docker/proaudio-player-dockerctl")],
        check=True,
    )


def test_obsolete_dlna_sidecar_assets_are_absent():
    assert not (ROOT / "docker/run-dlna-worker.sh").exists()
    dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
    compose_text = (ROOT / "compose.yaml").read_text(encoding="utf-8")

    assert "dlna-worker" not in dockerfile
    assert "dlna-worker" not in compose_text
    assert "169.254.253." not in compose_text
    assert "proaudio-runtime" not in compose_text


def test_expected_dev_source_assets_exist():
    assert (NATIVE / "Cargo.toml").is_file()
    assert (NATIVE / "config/config.yaml.example").is_file()
    assert (NATIVE / "scripts/audio-buses.sh").is_file()
    assert (NATIVE / "scripts/proaudio-player-output-watch").is_file()
    assert (NATIVE / "src/dlna.rs").is_file()
    assert (WEBUI / "package.json").is_file()
    assert (WEBUI / "package-lock.json").is_file()
    assert (WEBUI / "src").is_dir()
