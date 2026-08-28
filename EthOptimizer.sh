#!/bin/bash

# Стили и цвета
BOLD='\033[1m'
B_CYAN='\033[1;36m'
B_GREEN='\033[1;32m'
B_YELLOW='\033[1;33m'
B_RED='\033[1;31m'
NC='\033[0m'

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo -e "${B_RED}Ошибка: Запустите от имени root.${NC}"
    exit 1
fi

echo -e "${B_CYAN}=== EthOptimizer: оптимизатор сетевого интерфейса ===${NC}\n"

# 1. Установка ethtool, если отсутствует (только Ubuntu/Fedora)
if ! command -v ethtool >/dev/null 2>&1; then
    echo -e "${B_YELLOW}[*] ethtool не найден, устанавливаю...${NC}"
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq && apt-get install -y -qq ethtool
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y ethtool
    else
        echo -e "${B_RED}Ошибка: Поддерживаются только Ubuntu (apt) и Fedora (dnf). Установите ethtool вручную.${NC}"
        exit 1
    fi
fi

if ! command -v ethtool >/dev/null 2>&1; then
    echo -e "${B_RED}Ошибка: Установка ethtool не удалась.${NC}"
    exit 1
fi
echo -e "${B_GREEN}[✓] ethtool готов к работе.${NC}\n"

# 2. Автоматическое определение активного сетевого интерфейса
IFACE=$(ip route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1)

if [ -z "$IFACE" ]; then
    echo -e "${B_RED}[!] Не удалось автоматически определить активный интерфейс. Используем eth0 по умолчанию.${NC}"
    IFACE="eth0"
else
    echo -e "${B_GREEN}[✓] Определен активный сетевой интерфейс: $IFACE${NC}"
fi

# 3. Определение драйвера сетевой карты
DRIVER=$(ethtool -i "$IFACE" 2>/dev/null | awk -F': ' '/^driver:/ {print $2}')
echo -e "${B_CYAN}[*] Драйвер интерфейса $IFACE: ${DRIVER:-неизвестен}${NC}\n"

# Число доступных vCPU — нужно, чтобы не плодить очередей больше, чем есть
# ядер (лишние combined-очереди на слабых VPS дают только оверхед
# планировщика без прироста производительности).
NCPU=$(nproc 2>/dev/null || echo 1)

# 4. Определяем, какие конкретно команды применимы на этом железе.
# На этом этапе мы только собираем кандидатов в CMDS — реальное
# применение и проверка успеха происходят позже, в шаге 5. Список CMDS
# после шага 5 перезаписывается только успешно применёнными командами.
CMDS=()

supports_feature() {
    local feature="$1"
    local long_name="$feature"
    case "$feature" in
        tso) long_name="tcp-segmentation-offload" ;;
        gso) long_name="generic-segmentation-offload" ;;
        gro) long_name="generic-receive-offload" ;;
        lro) long_name="large-receive-offload" ;;
        rx)  long_name="rx-checksumming" ;;
        tx)  long_name="tx-checksumming" ;;
        sg)  long_name="scatter-gather" ;;
        ufo) long_name="udp-fragmentation-offload" ;;
    esac

    ethtool -k "$IFACE" 2>/dev/null | grep -q "^${long_name}:.*\[fixed\]" && return 1
    ethtool -k "$IFACE" 2>/dev/null | grep -q "^${long_name}:" && return 0
    return 1
}

add_feature_cmd() {
    local feature="$1" value="$2"
    if supports_feature "$feature"; then
        CMDS+=("ethtool -K \"$IFACE\" $feature $value")
        echo -e "${B_GREEN}[✓]   кандидат: $feature=$value${NC}"
    else
        echo -e "${B_YELLOW}[!]   $feature не поддерживается драйвером — пропускаю${NC}"
    fi
}

add_ring_cmds() {
    local max_rx max_tx
    max_rx=$(ethtool -g "$IFACE" 2>/dev/null | awk '/Pre-set maximums:/{f=1;next} f&&/RX:/{print $2; exit}')
    max_tx=$(ethtool -g "$IFACE" 2>/dev/null | awk '/Pre-set maximums:/{f=1;next} f&&/TX:/{print $2; exit}')

    if [[ -n "$max_rx" && "$max_rx" -gt 0 ]] 2>/dev/null; then
        CMDS+=("ethtool -G \"$IFACE\" rx $max_rx")
        echo -e "${B_GREEN}[✓]   кандидат: ring rx=$max_rx${NC}"
    else
        echo -e "${B_YELLOW}[!]   ring buffer (RX) не настраивается на этом драйвере — пропускаю${NC}"
    fi

    if [[ -n "$max_tx" && "$max_tx" -gt 0 ]] 2>/dev/null; then
        CMDS+=("ethtool -G \"$IFACE\" tx $max_tx")
        echo -e "${B_GREEN}[✓]   кандидат: ring tx=$max_tx${NC}"
    else
        echo -e "${B_YELLOW}[!]   ring buffer (TX) не настраивается на этом драйвере — пропускаю${NC}"
    fi
}

add_coalesce_cmd() {
    local rx_usecs="$1" tx_usecs="$2"
    if ethtool -c "$IFACE" >/dev/null 2>&1; then
        CMDS+=("ethtool -C \"$IFACE\" rx-usecs $rx_usecs tx-usecs $tx_usecs")
        echo -e "${B_GREEN}[✓]   кандидат: coalescing rx-usecs=$rx_usecs tx-usecs=$tx_usecs${NC}"
    else
        echo -e "${B_YELLOW}[!]   interrupt coalescing не поддерживается на этом драйвере — пропускаю${NC}"
    fi
}

add_queues_cmd() {
    local max_combined target
    max_combined=$(ethtool -l "$IFACE" 2>/dev/null | awk '/Pre-set maximums:/{f=1;next} f&&/Combined:/{print $2; exit}')

    if [[ -n "$max_combined" && "$max_combined" -gt 1 ]] 2>/dev/null; then
        # Не выставляем очередей больше, чем есть vCPU — лишние очереди
        # без ядер для их обслуживания только добавляют оверхед.
        target=$max_combined
        if [[ "$NCPU" -gt 0 && "$max_combined" -gt "$NCPU" ]]; then
            target=$NCPU
            echo -e "${B_CYAN}[i]   аппаратный максимум очередей ($max_combined) больше числа vCPU ($NCPU) — ограничиваю до $NCPU${NC}"
        fi
        CMDS+=("ethtool -L \"$IFACE\" combined $target")
        echo -e "${B_GREEN}[✓]   кандидат: multi-queue combined=$target${NC}"
    else
        echo -e "${B_YELLOW}[!]   multi-queue (RSS) не поддерживается или единственная очередь — пропускаю${NC}"
    fi
}

echo -e "${B_YELLOW}[*] Определение твиков под драйвер $DRIVER...${NC}"
case "$DRIVER" in
    virtio_net)
        echo -e "${B_CYAN}    virtio_net (типичный KVM/QEMU/OpenStack VPS)${NC}"
        echo -e "${B_YELLOW}    [i] TSO/GSO/GRO/tx-checksumming не отключаются по умолчанию.${NC}"
        echo -e "${B_YELLOW}        На virtio эти offload'ы реализует гипервизор эффективно;${NC}"
        echo -e "${B_YELLOW}        их отключение перекладывает сегментацию и подсчёт checksum${NC}"
        echo -e "${B_YELLOW}        на CPU гостя в software-режиме, что на слабых VPS (1-2 vCPU)${NC}"
        echo -e "${B_YELLOW}        под сетевой нагрузкой (прокси/туннели) может создавать${NC}"
        echo -e "${B_YELLOW}        избыточную нагрузку на CPU вплоть до деградации сети.${NC}"
        add_ring_cmds
        add_queues_cmd
        ;;
    xen_netfront)
        echo -e "${B_CYAN}    xen_netfront (Xen VPS)${NC}"
        add_ring_cmds
        ;;
    ena)
        echo -e "${B_CYAN}    ena (AWS Nitro)${NC}"
        add_ring_cmds
        add_coalesce_cmd 20 20
        add_queues_cmd
        ;;
    ixgbe|i40e|ice)
        echo -e "${B_CYAN}    $DRIVER (физическая Intel NIC)${NC}"
        add_ring_cmds
        add_coalesce_cmd 20 20
        add_queues_cmd
        ;;
    mlx4_en|mlx5_core)
        echo -e "${B_CYAN}    $DRIVER (физическая Mellanox NIC)${NC}"
        add_ring_cmds
        add_coalesce_cmd 20 20
        add_queues_cmd
        ;;
    r8169|e1000|e1000e|igb)
        echo -e "${B_CYAN}    $DRIVER (потребительская/офисная физическая NIC)${NC}"
        add_ring_cmds
        add_coalesce_cmd 30 30
        ;;
    *)
        echo -e "${B_YELLOW}    неизвестный/неучтённый драйвер — применяю только безопасные общие проверки${NC}"
        add_ring_cmds
        ;;
esac

# txqueuelen идёт в общий список команд отдельно
CMDS+=("ip link set dev \"$IFACE\" txqueuelen 10000")
echo ""

# 5. Применяем команды-кандидаты и проверяем каждую по факту.
# В финальный (в т.ч. автозагрузочный) список попадают только те команды,
# которые реально отработали без ошибки — неудачные не засоряют ни текущее
# состояние интерфейса, ни воркер-скрипт для systemd.
echo -e "${B_YELLOW}[*] Применение твиков на $IFACE...${NC}"

APPLIED_CMDS=()
FAILED_COUNT=0

for cmd in "${CMDS[@]}"; do
    err_output=$(eval "$cmd" 2>&1 >/dev/null)
    if [ $? -eq 0 ]; then
        APPLIED_CMDS+=("$cmd")
        echo -e "${B_GREEN}[✓] применено: $cmd${NC}"
    else
        FAILED_COUNT=$((FAILED_COUNT + 1))
        echo -e "${B_RED}[✗] не применилось: $cmd${NC}"
        [ -n "$err_output" ] && echo -e "${B_RED}    причина: $err_output${NC}"
    fi
done

CMDS=("${APPLIED_CMDS[@]}")

echo "SUBSYSTEM==\"net\", ACTION==\"add\", KERNEL==\"$IFACE\", ATTR{txqueuelen}=\"10000\"" | tee /etc/udev/rules.d/99-network-txqueuelen.rules >/dev/null

echo
if [ "$FAILED_COUNT" -gt 0 ]; then
    echo -e "${B_YELLOW}[i] Применено успешно: ${#CMDS[@]}, не применилось: ${FAILED_COUNT}${NC}\n"
else
    echo -e "${B_GREEN}[✓] Все твики применены без ошибок.${NC}\n"
fi

# 6. Формируем воркер-скрипт для автозапуска — пересоздаётся заново при
# каждом запуске главного скрипта. Воркер содержит только команды,
# успешно применённые на шаге 5 — никакой логики или повторного детекта
# в нём нет, и никаких заведомо нерабочих команд он не унаследует.
S="/usr/local/bin/eth-optimizer.sh"

{
    echo '#!/bin/bash'
    echo ''
    for cmd in "${CMDS[@]}"; do
        echo "$cmd"
    done
} > "$S"

chmod +x "$S"
echo -e "${B_GREEN}[✓] Воркер-скрипт для автозапуска сформирован: $S (${#CMDS[@]} команд)${NC}\n"

# 7. Опциональное создание systemd-службы (только единожды — если уже есть,
# повторно не спрашиваем и не пересоздаём юнит)
if [ -f /etc/systemd/system/eth-optimizer.service ]; then
    echo -e "${B_YELLOW}[*] Служба systemd уже настроена ранее, пропускаю вопрос.${NC}"
else
    read -p "$(echo -e "${B_YELLOW}${BOLD}Создать службу systemd для применения настроек при старте системы? [y/N]: ${NC}")" SYSTEMD_CHOICE

    if [[ "$SYSTEMD_CHOICE" =~ ^[Yy]$ ]]; then
        cat << EOF > /etc/systemd/system/eth-optimizer.service
[Unit]
Description=Apply NIC tweaks on boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$S
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable eth-optimizer.service
        echo -e "${B_YELLOW}Служба systemd создана и включена.${NC}"
    fi
fi

echo -e "${B_GREEN}${BOLD}EthOptimizer успешно настроил интерфейс $IFACE (драйвер: ${DRIVER:-неизвестен})!${NC}"
