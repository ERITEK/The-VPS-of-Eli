# --> ПРОВЕРКА АРТЕФАКТА <--
# - собирает монолит из src/ во временный файл и сверяет с отгруженным: -
# - расхождение значит, что отгруженный файл правили руками, а не через модули -
# - строка сборки (метка времени) при сверке игнорируется -
# -Usage: bash tools/verify.sh -
# -rc: 0 - артефакт воспроизводится из модулей, 1 - расхождение -
set -o pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SHIPPED="${DIR}/the_vps_of_eli.sh"
TMP="$(mktemp)"

cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

if ! ELI_BUILD_OUT="$TMP" bash "${DIR}/build.sh" >/dev/null 2>&1; then
    echo "проверка артефакта: сборка не прошла, смотри bash build.sh"
    exit 1
fi

if diff <(grep -v '^# Собран:' "$SHIPPED") <(grep -v '^# Собран:' "$TMP") >/dev/null 2>&1; then
    echo "артефакт воспроизводится из модулей: правок монолита в обход src/ нет"
    exit 0
fi

echo "РАСХОЖДЕНИЕ: отгруженный монолит отличается от сборки из src/"
echo "--- строки, которые есть в собранном из src, но нет в отгруженном ---"
diff <(grep -v '^# Собран:' "$SHIPPED") <(grep -v '^# Собран:' "$TMP") | grep '^>' | head -20
echo "--- обратное ---"
diff <(grep -v '^# Собран:' "$SHIPPED") <(grep -v '^# Собран:' "$TMP") | grep '^<' | head -20
exit 1
