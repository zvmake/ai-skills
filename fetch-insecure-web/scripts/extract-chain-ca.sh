#!/usr/bin/env bash
# extract-chain-ca.sh — извлечь из TLS-цепочки сервера сертификат УЦ, которым
# КРИПТОГРАФИЧЕСКИ подписан листовой сертификат (кандидат для --cacert).
# Кандидат принимается только после проверки verify -partial_chain, не по имени.
#
# Внимание: это доверие «первому предъявленному» (TOFU) — допустимо для внутренних
# и тестовых ресурсов; для важных публичных сервисов предпочитай официальный источник CA.
#
# Использование: bash extract-chain-ca.sh <хост> [порт] [выходной-файл]
# Прим.: используется пустой массив под set -u — нужен bash >= 4.4 (в Windows git-bash 5.x).
set -euo pipefail

HOST="${1:?Укажите хост: bash extract-chain-ca.sh <хост> [порт] [файл]}"
PORT="${2:-443}"
OUT="${3:-chain-ca.pem}"

# Temp-каталог: TMPDIR → TEMP → TMP → /tmp (Windows-пути нормализуются в прямые слэши)
TMP_BASE="${TMPDIR:-${TEMP:-${TMP:-/tmp}}}"
TMP_BASE="$(printf '%s' "$TMP_BASE" | tr '\\' '/')"
TMP_BASE="${TMP_BASE%/}"
WORK="$TMP_BASE/opencode-extract-$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

# SNI отправляем только для имён (для IP-адреса это некорректно)
SNI_OPT=()
case "$HOST" in *[!0-9.]*) SNI_OPT=(-servername "$HOST") ;; esac

# Выходной код s_client не фатален: сервер может закрыть соединение без close_notify
# («unexpected eof while reading») при корректном рукопожатии — проверяем по содержимому
echo | openssl s_client -connect "$HOST:$PORT" "${SNI_OPT[@]}" -showcerts 2>/dev/null > "$WORK/sclient.txt" || true

# Разбить вывод на отдельные PEM (cert-1 = лист, далее промежуточные/корневой)
awk -v d="$WORK" '
  /BEGIN CERTIFICATE/ {n++}
  /BEGIN CERTIFICATE/,/END CERTIFICATE/ {print > (d "/cert-" n ".pem")}
' "$WORK/sclient.txt"

if [ ! -f "$WORK/cert-1.pem" ]; then
  echo "ОШИБКА: сервер не отвечает или не отдал сертификаты (проверьте хост/порт)" >&2
  exit 1
fi
LEAF="$WORK/cert-1.pem"

cert_fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//' | tr -d ':' | tr 'a-f' 'A-F'; }
LEAF_FP="$(cert_fp "$LEAF")"

for f in "$WORK"/cert-*.pem; do
  [ "$(basename "$f")" = "cert-1.pem" ] && continue
  [ "$(cert_fp "$f")" = "$LEAF_FP" ] && continue
  if openssl verify -partial_chain -CAfile "$f" "$LEAF" >/dev/null 2>&1; then
    cp "$f" "$OUT"
    echo "CA извлечён из цепочки сервера (подпись листа подтверждена): $OUT"
    echo "Внимание: доверие TOFU (первому предъявленному) — для внутренних/тестовых ресурсов." >&2
    openssl x509 -in "$OUT" -noout -subject -fingerprint -sha256
    exit 0
  fi
done

# Случай самоподписанного листа (subject == issuer): якорь — сам лист (TOFU-пиннинг сертификата)
LEAF_SUBJ="$(openssl x509 -in "$LEAF" -noout -subject | sed 's/^subject=//')"
LEAF_ISSR="$(openssl x509 -in "$LEAF" -noout -issuer | sed 's/^issuer=//')"
if [ -n "$LEAF_SUBJ" ] && [ "$LEAF_SUBJ" = "$LEAF_ISSR" ] && openssl verify -CAfile "$LEAF" "$LEAF" >/dev/null 2>&1; then
  cp "$LEAF" "$OUT"
  echo "Лист самоподписан — якорь: сам лист (TOFU-пиннинг сертификата): $OUT"
  echo "Внимание: доверие TOFU (первому предъявленному) — для внутренних/тестовых ресурсов." >&2
  openssl x509 -in "$OUT" -noout -subject -fingerprint -sha256
  exit 0
fi

echo "ОШИБКА: в цепочке сервера нет сертификата, криптографически подтверждающего подпись листа." >&2
echo "Нужен внешний PEM: официальный источник оператора УЦ (адрес — в AIA/CDP листа) или машина, где сертификату доверяют." >&2
exit 1
