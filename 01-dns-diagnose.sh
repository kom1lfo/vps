#!/bin/bash
# dns-diagnose.sh — диагностика DNS на Debian 12 VPS
# Ничего не меняет. Только читает и рекомендует.
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}  $1"; }
warn() { echo -e "${YELLOW}[!!]${NC}  $1"; }
bad()  { echo -e "${RED}[NO]${NC}  $1"; }
hdr()  { echo -e "\n${YELLOW}=== $1 ===${NC}"; }

hdr "1. resolv.conf — тип и содержимое"
ls -la /etc/resolv.conf
echo "---"
cat /etc/resolv.conf

hdr "2. systemd-resolved"
if systemctl is-active --quiet systemd-resolved; then
    ok "systemd-resolved АКТИВЕН"
    RESOLVED_ACTIVE=true
else
    warn "systemd-resolved НЕ активен или не установлен"
    RESOLVED_ACTIVE=false
fi

hdr "3. Stub listener — конфликт с AGH на порту 53"
STUB=$(grep -i "^DNSStubListener" /etc/systemd/resolved.conf 2>/dev/null | awk -F= '{print $2}' | tr -d ' ' || echo "")
if [[ -z "$STUB" ]]; then
    warn "DNSStubListener не задан явно — DEFAULT=yes (stub слушает на 127.0.0.53:53)"
    STUB_ENABLED=true
elif [[ "${STUB,,}" == "yes" ]]; then
    warn "DNSStubListener=yes — stub слушает на 127.0.0.53:53"
    STUB_ENABLED=true
else
    ok "DNSStubListener=no — порт 53 свободен для AGH"
    STUB_ENABLED=false
fi

hdr "4. Кто слушает порт 53"
ss -ltnup | grep ':53' || echo "порт 53 не занят"

hdr "5. NetworkManager"
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    warn "NetworkManager АКТИВЕН — DNS управляется через NM"
    NM_ACTIVE=true
else
    ok "NetworkManager не используется (типично для Debian Server)"
    NM_ACTIVE=false
fi

hdr "6. Тест резолва через системный DNS"
if dig +short +time=3 example.com @127.0.0.1 > /dev/null 2>&1 || \
   dig +short +time=3 example.com > /dev/null 2>&1; then
    RESULT=$(dig +short example.com 2>/dev/null | head -1)
    ok "DNS работает → example.com = $RESULT"
    DNS_OK=true
else
    bad "DNS НЕ РАБОТАЕТ через системные настройки"
    DNS_OK=false
fi

hdr "7. Тест через публичные DNS (минуя систему)"
if dig +short +time=3 google.com @8.8.8.8 > /dev/null 2>&1; then
    ok "8.8.8.8 — доступен"
else
    bad "8.8.8.8 — НЕ доступен (проблема с сетью или firewall)"
fi
if dig +short +time=3 google.com @1.1.1.1 > /dev/null 2>&1; then
    ok "1.1.1.1 — доступен"
else
    bad "1.1.1.1 — НЕ доступен"
fi

hdr "8. ИТОГ И РЕКОМЕНДАЦИИ"

# Определяем вариант
if [[ "$RESOLVED_ACTIVE" == true ]]; then
    echo ""
    ok "ВАРИАНТ A: systemd-resolved активен"
    echo ""
    echo "  Необходимые действия для подготовки под AGH:"
    echo ""
    if [[ "$STUB_ENABLED" == true ]]; then
        warn "  ТРЕБУЕТСЯ: отключить stub listener (конфликт с AGH на :53)"
        echo ""
        echo "  Применить вручную после просмотра этого отчёта:"
        echo ""
        echo "    sudo sed -i 's/^#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf"
        echo "    grep -q 'DNSStubListener' /etc/systemd/resolved.conf || echo 'DNSStubListener=no' | sudo tee -a /etc/systemd/resolved.conf"
        echo "    sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf"
        echo "    sudo systemctl restart systemd-resolved"
        echo ""
        echo "  После этого AGH сможет занять порт 53."
        echo "  AGH настроить как upstream: 1.1.1.1, 8.8.8.8"
        echo "  В resolved.conf прописать: DNS=127.0.0.1"
    else
        ok "  Stub listener уже отключён — AGH можно ставить сразу"
    fi

elif [[ "$NM_ACTIVE" == true ]]; then
    echo ""
    warn "ВАРИАНТ B: NetworkManager управляет DNS"
    IFACE=$(ip -o -4 route show to default | awk '{print $5}')
    CON=$(nmcli -t -f NAME con show --active | head -1)
    echo ""
    echo "  Применить вручную:"
    echo "    nmcli con mod \"${CON}\" ipv4.dns \"1.1.1.1 8.8.8.8\""
    echo "    nmcli con mod \"${CON}\" ipv4.ignore-auto-dns yes"
    echo "    nmcli con up \"${CON}\""

else
    echo ""
    ok "ВАРИАНТ C: статический /etc/resolv.conf"
    echo ""
    if [[ "$DNS_OK" == true ]]; then
        ok "  DNS работает. Для AGH: убедиться что resolv.conf не перезапишется cloud-init"
        echo "  Проверить: cat /etc/cloud/cloud.cfg | grep -i dns (если cloud-init установлен)"
    else
        bad "  DNS не работает! Нужно прописать вручную:"
        echo ""
        echo "    sudo rm -f /etc/resolv.conf"
        echo "    sudo tee /etc/resolv.conf <<EOF"
        echo "nameserver 1.1.1.1"
        echo "nameserver 8.8.8.8"
        echo "options timeout:2 attempts:3"
        echo "EOF"
        echo "    sudo chattr +i /etc/resolv.conf"
    fi
fi

hdr "9. Итог для AGH (порт 53)"
if [[ "$STUB_ENABLED" == true && "$RESOLVED_ACTIVE" == true ]]; then
    bad "КОНФЛИКТ: stub listener занимает :53 — AGH не запустится без исправления"
else
    ok "Порт 53 свободен или будет свободен после рекомендованных правок"
fi
echo ""
