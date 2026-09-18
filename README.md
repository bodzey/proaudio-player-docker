# ProAudio Player Docker

Docker/Compose adapter для запуску актуальних гілок `dev` **ProAudio Player Native** і **Web UI** на Linux amd64.

Цей репозиторій не містить копій коду плеєра або інтерфейсу. Обидва проєкти підключені як окремі Git submodule, а Docker відповідає тільки за build/runtime integration.

## Підключені джерела

```text
sources/proaudio-player-native
  -> bodzey/proaudio-player-native
  -> dev

sources/proaudio-player-webui
  -> bodzey/proaudio-player-webui
  -> dev
```

Gitlink-и залишаються лише bootstrap snapshot, потрібним формату Git submodule. Для `dev` вони не є версією збірки: `sync-sources` явно оновлює checkout-и до гілок із `.gitmodules`, а Docker завжди збирає фактичні HEAD цих checkout-ів. Різниця між gitlink і поточним HEAD навмисно ігнорується superproject-ом, тому після оновлення source-коду не потрібно комітити Docker-репозиторій.

Docker не залежить від внутрішньої структури `src/` Web UI: frontend збирається його власним контрактом `npm ci` + `npm run build`, а в runtime переноситься тільки результат `dist/`. Native аналогічно збирається як повний Rust checkout через `cargo build --locked --release`.

## Архітектура runtime

Основний контейнер містить:

- `proaudio-player-native`;
- зібраний Web UI;
- PipeWire + pipewire-pulse + WirePlumber;
- MPD, Shairport Sync і spotifyd;
- системний/session D-Bus та Avahi;
- native `audio-buses.sh` і `proaudio-player-output-watch` без Docker-копій їхньої логіки.

DLNA decoder worker (`gmediarender`) винесений у мінімальний допоміжний контейнер. Він не має host networking і не рекламується у LAN. Worker живе в приватній Docker-мережі на `169.254.253.1:49494` — це endpoint, який очікує поточний native backend. Аудіо worker передає через спільний Unix socket `pipewire-pulse` без доступу до `/dev/snd`.

## Клонування

```bash
git clone --branch dev --recurse-submodules \
  git@github.com:bodzey/proaudio-player-docker.git
cd proaudio-player-docker
chmod +x docker/proaudio-player-dockerctl
```

Для вже існуючого clone:

```bash
git fetch origin
git switch dev
git pull --ff-only

git submodule sync --recursive
git submodule update --init --recursive
./docker/proaudio-player-dockerctl sync-sources
```

Перевірити зафіксовані ревізії:

```bash
./docker/proaudio-player-dockerctl revisions
```

Оновити submodule до поточного стану гілок, записаних у `.gitmodules`:

```bash
./docker/proaudio-player-dockerctl sync-sources
```

Після `sync-sources` нічого в Docker-репозиторії комітити не потрібно. Для перевірки конкретного складу image використовуйте `revisions`; SHA фактичних checkout-ів також записуються в OCI labels під час build.

## Перший запуск без фізичного аудіопристрою

```bash
./docker/proaudio-player-dockerctl init
./docker/proaudio-player-dockerctl up-test
./docker/proaudio-player-dockerctl status
```

`up-test` не потребує `/dev/snd`. Native audio graph використовує штатний `PARKING_SINK`, тому тестовий режим не має окремої Docker-реалізації аудіотракту.

Web UI та API:

```text
http://IP_СЕРВЕРА:5371/
http://IP_СЕРВЕРА:5371/api/v1/health
```

Основний контейнер працює з `network_mode: host`, тому класичне Docker mapping `5371:8080` тут не використовується. Docker adapter передає `PROAUDIO_HTTP_PORT=5371` і перед стартом native застосовує цей порт до `api.port` у runtime-конфігурації. Порт можна змінити через змінну `PROAUDIO_HTTP_PORT`.

## Запуск із фізичним ALSA-пристроєм

На хості має існувати `/dev/snd`.

```bash
./docker/proaudio-player-dockerctl up-hardware
```

Контейнер отримує тільки `/dev/snd` і read-only `/run/udev`. Вибір, PARKING fallback, hot-plug reconciliation та unity-policy виконує той самий `proaudio-player-output-watch`, що постачається native-проєктом.

За потреби вибрати вихід вручну:

```bash
./docker/proaudio-player-dockerctl select-audio
./docker/proaudio-player-dockerctl up-hardware
```

Вибір зберігається у:

```text
docker-data/data/audio-output.env
```

## Дані

```text
docker-data/config/   config.yaml, alerts-token, optional audio.env.override
docker-data/data/     native state, settings, MPD state, machine-id, selected audio output
docker-data/music/    локальна музична бібліотека
```

`audio.env`, `mpd.conf`, `shairport-sync.conf` і `spotifyd.conf` не є Docker-owned persistent copies. Контейнер бере їх із `config/` саме того native submodule, який був зібраний. Для точкових локальних змін audio policy використовується лише `docker-data/config/audio.env.override`; відсутні там ключі автоматично беруться з актуального native default.

`machine-id` зберігається в persistent data, тому device identity не змінюється після rebuild контейнера.

Окремий named volume `proaudio-runtime` використовується тільки для runtime Unix sockets між основним контейнером та DLNA worker; його вміст очищається при старті основного runtime і не є persistent state.

## Корисні команди

```bash
./docker/proaudio-player-dockerctl sync-sources
./docker/proaudio-player-dockerctl revisions
./docker/proaudio-player-dockerctl build
./docker/proaudio-player-dockerctl status
./docker/proaudio-player-dockerctl logs
./docker/proaudio-player-dockerctl sinks
./docker/proaudio-player-dockerctl state
./docker/proaudio-player-dockerctl test-cycle 5
./docker/proaudio-player-dockerctl test-silence
./docker/proaudio-player-dockerctl mpd-update
./docker/proaudio-player-dockerctl shell
./docker/proaudio-player-dockerctl down
```

## Мережа

Основний контейнер використовує `network_mode: host`, оскільки Spotify Connect, AirPlay/Avahi, native DLNA/UPnP, SSDP та LinkPlay/4STREAM discovery потребують коректної multicast/LAN поведінки.

`gmediarender` не використовує host network. Його єдина мережа — Docker bridge `dlna-private`; адреса `169.254.253.1` доступна основному host-network runtime через Linux route до Docker bridge, але worker не стає окремим renderer у фізичній LAN.

## Тести Docker-адаптера

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements-test.txt
git submodule update --init --recursive
pytest -q
```

Повна acceptance-перевірка:

```bash
./docker/proaudio-player-dockerctl up-test
curl -fsS http://127.0.0.1:5371/api/v1/health
./docker/proaudio-player-dockerctl status
```

Докладніша схема runtime: [docs/DOCKER.md](docs/DOCKER.md).
