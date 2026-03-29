#!/bin/bash
# =============================================================
# 00-base-deps.sh — базовые зависимости для всего стека
# Запускать ПЕРВЫМ, на свежем Debian 12
# =============================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()  { echo -e "${GREEN}[OK]${NC}  $1"; }
hdr() { echo -e "\n${YELLOW}>>> $1${NC}"; }
err() { echo -e "${RED}[ERR]${NC} $1"; exit 1; }
warn() { echo -e "${YELLOW}[!!]${NC}  $1"; }

[[ $EUID -ne 0 ]] && err "Только от root"

hdr "Обновление списков пакетов"
apt-get update -q
apt-get upgrade -y -q
ok "apt update/upgrade готово"

hdr "Системные утилиты"
apt-get install -y \
  curl wget git unzip nano htop \
  net-tools iproute2 lsof \
  ca-certificates gnupg2 \
  software-properties-common \
  sudo
ok "Системные утилиты установлены"

hdr "Диагностика DNS"
apt-get install -y dnsutils     # dig, nslookup, host
ok "dnsutils (dig/nslookup) установлен"

hdr "WireGuard + QR"
apt-get install -y \
  wireguard-tools \
  qrencode \
  iptables
ok "WG-стек установлен"

hdr "DKMS + linux-headers (для AmneziaWG)"
# Фиксируем ядро ДО установки — это то, что сейчас запущено
RUNNING_KERNEL=$(uname -r)

apt-get install -y dkms linux-headers-amd64 linux-image-amd64
ok "dkms, linux-headers-amd64, linux-image-amd64 установлены"

# Что dpkg считает последним установленным ядром
# Glob [0-9]* — только версионные ядра, исключает linux-image-cloud-amd64 и т.п.
INSTALLED_KERNEL=$(dpkg -l 'linux-image-[0-9]*-amd64' 2>/dev/null \
  | awk '/^ii/{print $2}' | sort -V | tail -1 | sed 's/linux-image-//') || true

if [[ -z "$INSTALLED_KERNEL" ]]; then
  warn "Не удалось определить версию установленного ядра через dpkg"
  warn "Проверить вручную: dpkg -l 'linux-image-*'"
  INSTALLED_KERNEL="$RUNNING_KERNEL"   # принять как «без изменений»
fi

hdr "Проверка xt_TPROXY"
# Проверяем ТЕКУЩЕЕ ядро; если будет reboot — повторить: modprobe xt_TPROXY
if modprobe xt_TPROXY 2>/dev/null; then
  ok "Модуль xt_TPROXY загружен (ядро: $(uname -r))"
else
  warn "xt_TPROXY не загрузился — TPROXY-конфиг WireGuard может не работать"
  warn "Проверить после reboot: modprobe xt_TPROXY && lsmod | grep TPROXY"
fi

hdr "Python3 (для WGDashboard)"
apt-get install -y python3 python3-pip python3-venv
ok "Python3 $(python3 --version) установлен"

hdr "Безопасность (install без enable)"
apt-get install -y fail2ban ufw
# UFW и fail2ban НЕ запускаем — настроим позже отдельным скриптом
systemctl disable --now ufw       2>/dev/null || true
systemctl disable --now fail2ban  2>/dev/null || true
ok "fail2ban, ufw установлены (не запущены — настройка позже)"

hdr "Что НАМЕРЕННО НЕ установлено"
echo "  bind9, dnsmasq  — заняли бы порт 53 (нужен AGH)"
echo "  nginx           — установится в фазе WGDashboard"
echo "  certbot         — 3x-ui использует встроенный ACME"
echo "  openresolv перенесён в отдельный скрипт настройки WG"
echo "  resolvconf (старый Debian-пакет) — конфликтует с openresolv"

hdr "✅ Итог"
echo "  wireguard-tools:  $(dpkg-query -W -f='${Version}' wireguard-tools 2>/dev/null || echo 'неизвестно')"
echo "  ok "$(python3 --version) установлен"
echo "  DKMS:             $(dkms --version)"
echo "  Ядро запущено:    $RUNNING_KERNEL"
echo "  Ядро установлено: $INSTALLED_KERNEL"

# =============================================================
# ФИНАЛ: проверить нужна ли перезагрузка
# =============================================================
hdr "Проверка необходимости перезагрузки"

if [[ "$RUNNING_KERNEL" != "$INSTALLED_KERNEL" ]]; then
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ПЕРЕЗАГРУЗКА ОБЯЗАТЕЛЬНА перед следующим шагом  ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    warn "Запущено ядро : $RUNNING_KERNEL"
    warn "Установлено   : $INSTALLED_KERNEL"
    warn "DKMS и AWG будут собираться под новое ядро после reboot"
    echo ""
    echo "  Команда: reboot"
    echo "  После перезагрузки: bash /root/scripts/install-wg.sh"
else
    ok "Ядро актуальное: $RUNNING_KERNEL. Перезагрузка не требуется"
    echo ""
    ok "Можно сразу запускать: bash /root/scripts/install-wg.sh"
fi
