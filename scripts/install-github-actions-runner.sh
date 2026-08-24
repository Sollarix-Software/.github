#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

# Быстрая установка выделенного GitHub Actions runner для Sollarix Software.
#
# Запуск:
#   sudo bash install-github-actions-runner.sh
#
# Необязательные переменные:
#   RUNNER_SCOPE_URL=https://github.com/Sollarix-Software
#   RUNNER_NAME=GA-Runner-2
#   RUNNER_LABELS=GAR-1
#   RUNNER_GROUP=Default
#   RUNNER_USER=github-runner
#   RUNNER_DIR=/opt/actions-runner
#   RUNNER_WORK_DIR=_work
#   RUNNER_VERSION=2.336.0
#   RUNNER_SHA256=<контрольная сумма из официального релиза>
#   SWAP_SIZE_GB=2
#
# RUNNER_TOKEN можно передать через окружение для автоматизации. Если он не
# задан, скрипт запросит его скрыто. Используйте только короткоживущий токен со
# страницы Settings -> Actions -> Runners -> New self-hosted runner.

log() {
  printf '\n[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

fail() {
  printf 'Ошибка: %s\n' "$*" >&2
  exit 1
}

[[ "$(id -u)" -eq 0 ]] || fail "запустите скрипт через sudo или от root"

source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || fail "поддерживается только Ubuntu"
command -v systemctl >/dev/null 2>&1 || fail "нужен systemd"

RUNNER_SCOPE_URL="${RUNNER_SCOPE_URL:-https://github.com/Sollarix-Software}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname -s)}"
RUNNER_LABELS="${RUNNER_LABELS:-GAR-1}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
RUNNER_USER="${RUNNER_USER:-github-runner}"
RUNNER_DIR="${RUNNER_DIR:-/opt/actions-runner}"
RUNNER_WORK_DIR="${RUNNER_WORK_DIR:-_work}"
SWAP_SIZE_GB="${SWAP_SIZE_GB:-2}"

[[ "$RUNNER_SCOPE_URL" == https://github.com/* ]] || fail "RUNNER_SCOPE_URL должен начинаться с https://github.com/"
[[ "$RUNNER_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || fail "недопустимое имя runner"
[[ "$RUNNER_LABELS" =~ ^[A-Za-z0-9._,-]+$ ]] || fail "недопустимые метки"
[[ "$RUNNER_GROUP" != *$'\n'* ]] || fail "недопустимое имя группы"
[[ "$RUNNER_DIR" == /* ]] || fail "RUNNER_DIR должен быть абсолютным путём"
[[ "$RUNNER_DIR" != "/" && "$RUNNER_DIR" != "/home" && "$RUNNER_DIR" != "/opt" ]] ||
  fail "RUNNER_DIR слишком широкий"
[[ "$RUNNER_WORK_DIR" =~ ^[A-Za-z0-9._-]+$ ]] || fail "недопустимый рабочий каталог"
[[ "$SWAP_SIZE_GB" =~ ^[0-9]+$ ]] || fail "SWAP_SIZE_GB должен быть целым числом"

case "$(uname -m)" in
  x86_64) RUNNER_ARCH=x64 ;;
  aarch64 | arm64) RUNNER_ARCH=arm64 ;;
  armv7l) RUNNER_ARCH=arm ;;
  *) fail "неподдерживаемая архитектура: $(uname -m)" ;;
esac

log "Установка системных зависимостей"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  build-essential \
  ca-certificates \
  cmake \
  curl \
  docker.io \
  git \
  gzip \
  jq \
  libssl-dev \
  ninja-build \
  openssl \
  pkg-config \
  postgresql-client \
  protobuf-compiler \
  redis-tools \
  tar \
  unzip \
  zlib1g-dev

systemctl enable --now docker

log "Настройка памяти для Redis и контейнерных проверок"
install -d -m 0755 /etc/sysctl.d
printf 'vm.overcommit_memory = 1\n' > /etc/sysctl.d/99-sollarix-runner.conf
sysctl -w vm.overcommit_memory=1 >/dev/null

if ! id "$RUNNER_USER" >/dev/null 2>&1; then
  log "Создание пользователя $RUNNER_USER"
  adduser --disabled-password --gecos "" "$RUNNER_USER"
fi
usermod -aG docker "$RUNNER_USER"

if (( SWAP_SIZE_GB > 0 )) && [[ -z "$(swapon --show=NAME --noheadings)" ]]; then
  if [[ -e /swapfile ]]; then
    log "/swapfile уже существует; автоматическое изменение пропущено"
  else
    required_bytes=$(( (SWAP_SIZE_GB + 5) * 1024 * 1024 * 1024 ))
    available_bytes="$(df --output=avail -B1 / | tail -n 1 | tr -d ' ')"
    (( available_bytes >= required_bytes )) ||
      fail "недостаточно места для swap и безопасного остатка на диске"

    log "Создание swap объёмом ${SWAP_SIZE_GB} ГБ"
    fallocate -l "${SWAP_SIZE_GB}G" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    if ! grep -qE '^/swapfile[[:space:]]' /etc/fstab; then
      printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
    fi
  fi
fi

install -d -o "$RUNNER_USER" -g "$RUNNER_USER" -m 0750 "$RUNNER_DIR"
[[ ! -e "$RUNNER_DIR/.runner" ]] ||
  fail "$RUNNER_DIR уже содержит настроенный runner; удалите его штатно перед повторной установкой"

log "Получение сведений об официальном релизе runner"
if [[ -n "${RUNNER_VERSION:-}" ]]; then
  version="${RUNNER_VERSION#v}"
  release_api="https://api.github.com/repos/actions/runner/releases/tags/v${version}"
else
  release_api="https://api.github.com/repos/actions/runner/releases/latest"
fi

release_json="$(curl -fsSL \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "$release_api")"
version="$(jq -er '.tag_name | ltrimstr("v")' <<<"$release_json")"
archive="actions-runner-linux-${RUNNER_ARCH}-${version}.tar.gz"
download_url="https://github.com/actions/runner/releases/download/v${version}/${archive}"

checksum="${RUNNER_SHA256:-}"
if [[ -z "$checksum" ]]; then
  checksum="$(
    jq -r '.body' <<<"$release_json" |
      grep -F "$archive" |
      grep -Eo '[A-Fa-f0-9]{64}' |
      head -n 1 || true
  )"
fi
[[ "$checksum" =~ ^[A-Fa-f0-9]{64}$ ]] ||
  fail "не удалось получить SHA-256; задайте RUNNER_SHA256 из официального релиза"

archive_path="$RUNNER_DIR/$archive"
log "Загрузка GitHub Actions runner v$version для $RUNNER_ARCH"
curl --fail --location --proto '=https' --tlsv1.2   --output "$archive_path" "$download_url"
printf '%s  %s\n' "$checksum" "$archive_path" | sha256sum --check --status ||
  fail "контрольная сумма runner не совпала"

tar -xzf "$archive_path" -C "$RUNNER_DIR"
rm -f "$archive_path"
chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"

if [[ -z "${RUNNER_TOKEN:-}" ]]; then
  read -r -s -p "Короткоживущий токен регистрации GitHub: " RUNNER_TOKEN
  printf '\n'
fi
[[ -n "$RUNNER_TOKEN" ]] || fail "токен регистрации не задан"

log "Регистрация $RUNNER_NAME в $RUNNER_SCOPE_URL"
sudo -u "$RUNNER_USER" "$RUNNER_DIR/config.sh" \
  --unattended \
  --replace \
  --url "$RUNNER_SCOPE_URL" \
  --token "$RUNNER_TOKEN" \
  --name "$RUNNER_NAME" \
  --runnergroup "$RUNNER_GROUP" \
  --labels "$RUNNER_LABELS" \
  --work "$RUNNER_WORK_DIR"
unset RUNNER_TOKEN

log "Установка и запуск systemd-службы"
cd "$RUNNER_DIR"
./svc.sh install "$RUNNER_USER"

service_name=""
for unit_file in /etc/systemd/system/actions.runner.*.service; do
  [[ -f "$unit_file" ]] || continue
  if grep -Fq "$RUNNER_DIR/runsvc.sh" "$unit_file"; then
    service_name="$(basename "$unit_file")"
    break
  fi
done
[[ -n "$service_name" ]] || fail "не удалось определить созданную systemd-службу runner"

install -d -m 0755 "/etc/systemd/system/${service_name}.d"
cat > "/etc/systemd/system/${service_name}.d/restart.conf" <<'SYSTEMD'
[Service]
Restart=always
RestartSec=5s
SYSTEMD
systemctl daemon-reload

install -d -m 0755 /etc/needrestart/conf.d
printf '%s\n' "\$nrconf{override_rc}{qr(^actions\\.runner\\..+\\.service\$)} = 0;" \
  > /etc/needrestart/conf.d/actions_runner_services.conf

./svc.sh start

log "Проверка Docker от имени runner"
sudo -u "$RUNNER_USER" docker info --format 'Docker {{.ServerVersion}}'
./svc.sh status

printf '\nГотово. Runner: %s; метки: self-hosted, Linux, %s, %s\n' \
  "$RUNNER_NAME" "$RUNNER_ARCH" "$RUNNER_LABELS"
