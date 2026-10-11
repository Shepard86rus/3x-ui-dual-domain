#!/usr/bin/env bash
echo "=== TEST A: приватное репо -> мягкий отказ ==="
bash /root/lucx-dual-domain-v0_4_7.sh upgrade
echo "A_EXIT=$?"
echo
echo "=== TEST B: симуляция старой (0.4.6-sim) -> обновление до 0.4.7 ==="
sed -e 's|VERSION="0.4.7"|VERSION="0.4.6-sim"|' \
    -e 's|https://raw.githubusercontent.com/Shepard86rus/3x-ui-dual-domain/main/lucx-dual-domain.sh|file:///root/lucx-dual-domain-v0_4_7.sh|' \
    /root/lucx-dual-domain-v0_4_7.sh > /root/lucx-sim.sh
bash /root/lucx-sim.sh upgrade
echo "B_EXIT=$?"
grep -m1 '^VERSION=' /root/lucx-sim.sh
echo
echo "=== TEST C: локальная новее (0.4.8-loc) -> ожидаем ОТКАЗ даунгрейда ==="
sed -e 's|VERSION="0.4.7"|VERSION="0.4.8-loc"|' \
    -e 's|https://raw.githubusercontent.com/Shepard86rus/3x-ui-dual-domain/main/lucx-dual-domain.sh|file:///root/lucx-dual-domain-v0_4_7.sh|' \
    /root/lucx-dual-domain-v0_4_7.sh > /root/lucx-sim2.sh
bash /root/lucx-sim2.sh upgrade
echo "C_EXIT=$?"
grep -m1 '^VERSION=' /root/lucx-sim2.sh
