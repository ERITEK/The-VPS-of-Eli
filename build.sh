#!/usr/bin/env bash
# --> BUILD <--
# - собирает модули из src/ в один файл the_vps_of_eli.sh -
# - порядок файлов важен: header первый, entry последний -

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"
OUT_FILE="${SCRIPT_DIR}/the_vps_of_eli.sh"

# - порядок сборки: header -> модули -> меню -> entry -
FILES=(
    "00_header.sh"
    "01_boot.sh"
    "02a_awg.sh"
    "02b_3xui.sh"
    "02c_outline.sh"
    "03a_teamspeak.sh"
    "03b_mumble.sh"
    "04a_unbound.sh"
    "04b_diag.sh"
    "04c_prayer.sh"
    "04d_ssh.sh"
    "04e_ufw.sh"
    "04f_update.sh"
    "04g_routine.sh"
    "main.sh"
    "99_entry.sh"
)

echo "Сборка The VPS of Eli..."
echo ""

# - начинаем с shebang -
echo '#!/usr/bin/env bash' > "$OUT_FILE"
echo '# =============================================================================' >> "$OUT_FILE"
echo '# The VPS of Eli v3.141' >> "$OUT_FILE"
echo '# Мега-менеджер VPS стека: VPN, связь, обслуживание' >> "$OUT_FILE"
echo '# scrp by ERITEK & Loo1, Claude (Anthropic)' >> "$OUT_FILE"
echo "# Собран: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$OUT_FILE"
echo '# =============================================================================' >> "$OUT_FILE"
echo '' >> "$OUT_FILE"

TOTAL_LINES=0
MISSING=0

for f in "${FILES[@]}"; do
    src="${SRC_DIR}/${f}"
    if [[ ! -f "$src" ]]; then
        echo "  ПРОПУЩЕН: ${f} (файл не найден)"
        MISSING=$((MISSING + 1))
        continue
    fi

    lines=$(wc -l < "$src")
    TOTAL_LINES=$((TOTAL_LINES + lines))

    echo "" >> "$OUT_FILE"
    echo "# === ${f} ===" >> "$OUT_FILE"

    # - пропускаем shebang из модулей, он уже есть в начале -
    if head -1 "$src" | grep -q '^#!/'; then
        tail -n +2 "$src" >> "$OUT_FILE"
    else
        cat "$src" >> "$OUT_FILE"
    fi

    echo "  ✓ ${f} (${lines} строк)"
done

chmod +x "$OUT_FILE"

echo ""
echo "Готово: ${OUT_FILE}"
echo "Строк: ${TOTAL_LINES}"
echo "Модулей: ${#FILES[@]} (пропущено: ${MISSING})"
echo "Размер: $(du -h "$OUT_FILE" | awk '{print $1}')"
