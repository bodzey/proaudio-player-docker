# Docker runtime

Цей репозиторій містить тільки Docker-specific integration. Логіка плеєра, Python package, web UI, shared configs та `audio-buses.sh` беруться з submodule `sources/proaudio-player`.

## Runtime stack

Контейнер містить:

- PipeWire;
- pipewire-pulse;
- WirePlumber;
- Pulse client tools (`pactl`);
- MPD + `mpc`;
- MPV;
- Shairport Sync;
- gmrender-resurrect + GStreamer Pulse plugin;
- spotifyd;
- Avahi;
- Python runtime із встановленим `proaudio_player`;
- Supervisor і Tini для контейнерного lifecycle.

Rust toolchain і Python venv builder використовуються лише у build stages та не потрапляють у runtime image. Стандартні announcement media беруться безпосередньо з pinned core, тому `espeak-ng` і FFmpeg не потрібні ні в build stage, ні в runtime.

## Режими

| Команда | Призначення |
| --- | --- |
| `up-test` | Віртуальний test sink, без `/dev/snd` |
| `up-hardware` | Фізичний ALSA/PipeWire output через `/dev/snd` |
| `select-audio` | Інтерактивний discovery фізичного sink |

## Основні команди

```bash
./docker/proaudio-player-dockerctl init
./docker/proaudio-player-dockerctl up-test
./docker/proaudio-player-dockerctl up-hardware
./docker/proaudio-player-dockerctl down
./docker/proaudio-player-dockerctl status
./docker/proaudio-player-dockerctl logs 200
./docker/proaudio-player-dockerctl sinks
./docker/proaudio-player-dockerctl state
./docker/proaudio-player-dockerctl test-cycle 5
./docker/proaudio-player-dockerctl test-silence
./docker/proaudio-player-dockerctl mpd-update
./docker/proaudio-player-dockerctl mpc status
./docker/proaudio-player-dockerctl shell
```

## Аудіо

Core script `sources/proaudio-player/scripts/audio-buses.sh` створює:

```text
proaudio_player_music
proaudio_player_alert
```

У `up-test` Docker wrapper спочатку створює `proaudio_player_test_output`, а потім передає його core script як фізичний sink.

У `up-hardware` WirePlumber бачить реальні ALSA-пристрої через `/dev/snd` і udev metadata. Обраний sink зберігається у:

```text
docker-data/config/audio-device.env
```

`api.alsa.soft-mixer=true` береться зі спільної конфігурації core. Це дозволяє керувати програмною PipeWire-гучністю без зміни апаратного ALSA mixer.

Стандартні MP3 також беруться зі спільного core. При першому запуску entrypoint копіює відсутні файли у persistent data, не перезаписуючи користувацькі повідомлення.

## Мережа

`network_mode: host` використовується навмисно для:

- AirPlay/mDNS;
- DLNA/UPnP discovery;
- Spotify Connect;
- MPD;
- web UI.

Web UI та MPD не слід експонувати в Інтернет; середовище розраховане на довірену LAN.

## Persistent data

```text
docker-data/config -> /etc/proaudio-player-alert
docker-data/data   -> /var/lib/proaudio-player-alert
docker-data/music  -> /srv/music
```

Тому rebuild контейнера не видаляє конфігурацію, API token, state, MPD database, alert media або локальну музику.

## Оновлення core

Docker adapter і firmware adapter повинні тестувати той самий core release/commit. Після зміни gitlink необхідно перебудувати image.

```bash
git submodule update --init --recursive
./docker/proaudio-player-dockerctl up-test
```
