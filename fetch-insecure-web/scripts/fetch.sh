#!/usr/bin/env bash
# fetch.sh — получить URL через доверие к нестандартному УЦ (национальному,
# корпоративному, тестовому) без -k. Сертификаты в скилле НЕ хранятся:
# якорь доверия добывается на лету и подтверждается криптографически.
#
# Порядок добычи якоря (универсальный):
#   1) CA_PEM (переменная окружения) — готовый PEM, если задан;
#   2) кэш ранее проверенных CA (подкаталог opencode-ca-cache в системном temp; переопределяется CA_CACHE_DIR);
#   3) CA_URL (если задан), иначе адрес издателя из AIA листа (CA Issuers):
#      кандидат скачивается и подтверждается: openssl verify -partial_chain;
#   4) сертификат издателя из TLS-цепочки сервера (TOFU), либо сам лист,
#      если он самоподписан (TOFU);
#   5) иначе — ошибка с инструкцией (перебор кандидатов из каталога УЦ).
#
# Использование: bash fetch.sh <URL> [выходной-файл]
# Переменные: CA_PEM — готовый PEM; CA_URL — адрес для загрузки кандидата;
#             CA_CACHE_DIR — каталог кэша якорей (по умолчанию — temp/opencode-ca-cache);
#             UA — User-Agent (по умолчанию браузерный; версию периодически обновляйте).
# HTTP-ответы >= 400 считаются ошибкой (exit != 0).
# Прим.: используется пустой массив под set -u — нужен bash >= 4.4 (в Windows git-bash 5.x).
set -euo pipefail

URL="${1:?Укажите URL: bash fetch.sh <URL> [файл-вывода]}"
OUT="${2:-}"

# Разбор хоста/порта (userinfo отбрасывается; IPv6-литералы не поддержаны)
HOST="$(printf '%s' "$URL" | sed -E 's#^https?://([^/@]*@)?##; s#/.*$##; s#:.*$##')"
PORT="$(printf '%s' "$URL" | sed -nE 's#^https?://([^/@]*@)?[^:/]+:([0-9]+).*#\2#p')"
PORT="${PORT:-443}"

UA="${UA:-Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36}"
# Temp-каталог: TMPDIR → TEMP → TMP → /tmp (Windows-пути нормализуются в прямые слэши); кэш переопределяется CA_CACHE_DIR
TMP_BASE="${TMPDIR:-${TEMP:-${TMP:-/tmp}}}"
TMP_BASE="$(printf '%s' "$TMP_BASE" | tr '\\' '/')"
TMP_BASE="${TMP_BASE%/}"
CACHE_DIR="${CA_CACHE_DIR:-$TMP_BASE/opencode-ca-cache}"
mkdir -p "$CACHE_DIR" 2>/dev/null || true
WORK="$TMP_BASE/opencode-fetch-$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

fp_of() { openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//' | tr -d ':' | tr 'a-f' 'A-F'; }

is_selfsigned() {  # 0 — самоподписан: subject == issuer И подпись сходится с собственным ключом
  local s i
  s="$(openssl x509 -in "$1" -noout -subject 2>/dev/null | sed 's/^subject=//')"
  i="$(openssl x509 -in "$1" -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
  [ -n "$s" ] && [ "$s" = "$i" ] || return 1
  openssl verify -CAfile "$1" "$1" >/dev/null 2>&1
}

# 0) лист и цепочка сервера
SNI_OPT=()
case "$HOST" in *[!0-9.]*) SNI_OPT=(-servername "$HOST") ;; esac
echo | openssl s_client -connect "$HOST:$PORT" "${SNI_OPT[@]}" -showcerts 2>/dev/null > "$WORK/schain.txt" || true
awk -v d="$WORK" '
  /BEGIN CERTIFICATE/ {n++}
  /BEGIN CERTIFICATE/,/END CERTIFICATE/ {print > (d "/cert-" n ".pem")}
' "$WORK/schain.txt"
if [ ! -f "$WORK/cert-1.pem" ]; then
  echo "ОШИБКА: не удалось получить TLS-сертификат $HOST:$PORT" >&2
  exit 1
fi
LEAF="$WORK/cert-1.pem"
LEAF_FP="$(fp_of "$LEAF")"

verify_candidate() {  # 0 — подписывает лист; 2 — кандидат совпадает с самим листом (не издатель)
  [ "$(fp_of "$1")" = "$LEAF_FP" ] && return 2
  openssl verify -partial_chain -CAfile "$1" "$LEAF" >/dev/null 2>&1
}

CA=""; SRC=""
use_ca() {  # $1 — подтверждённый кандидат; $2 — как он добыт
  CA_CACHE="$CACHE_DIR/$(fp_of "$1").pem"
  [ -f "$CA_CACHE" ] || cp "$1" "$CA_CACHE"
  CA="$CA_CACHE"
  SRC="$2"
}

try_url_candidate() {  # $1 — URL; $2 — ярлык источника; 0/1
  local u="$1" label="$2" cand="$WORK/candidate.pem" rc_local
  if curl -fsSL --max-time 30 -o "$cand" "$u"; then
    rc_local=0
    verify_candidate "$cand" || rc_local=$?
    if [ "$rc_local" -eq 0 ]; then
      use_ca "$cand" "$label"
      echo "Якорь добыт по $label: $u" >&2
      return 0
    fi
    if [ "$rc_local" -eq 2 ]; then
      echo "Кандидат из $label совпадает с самим листом — это не издатель: $u" >&2
    else
      echo "Кандидат из $label не подтверждает подпись листа: $u" >&2
    fi
  else
    echo "Не удалось скачать кандидата из $label: $u" >&2
  fi
  return 1
}

# 1) явный PEM
if [ -n "${CA_PEM:-}" ]; then
  rc=0
  verify_candidate "$CA_PEM" || rc=$?
  if [ "$rc" -eq 2 ]; then
    if ! is_selfsigned "$LEAF"; then
      echo "ОШИБКА: CA_PEM совпадает с самим листом, а лист не самоподписан — это не издатель." >&2
      exit 1
    fi
  elif [ "$rc" -ne 0 ]; then
    echo "ОШИБКА: $CA_PEM не подтверждается как издатель листа $HOST" >&2
    exit 1
  fi
  use_ca "$CA_PEM" "CA_PEM"
fi

# 2) кэш
if [ -z "$CA" ] && [ -d "$CACHE_DIR" ]; then
  for f in "$CACHE_DIR"/*.pem; do
    [ -e "$f" ] || continue
    if verify_candidate "$f"; then use_ca "$f" "кэш"; break; fi
  done
fi

# 3) CA_URL, иначе AIA листа (адрес официальной публикации издателя)
if [ -z "$CA" ] && [ -n "${CA_URL:-}" ]; then
  try_url_candidate "$CA_URL" "CA_URL" || true
fi
if [ -z "$CA" ]; then
  AIA_URL="$(openssl x509 -in "$LEAF" -noout -text 2>/dev/null | grep -A1 -i "CA Issuers" | grep -oE 'https?://[^ ]+' | head -1 || true)"
  if [ -z "$AIA_URL" ]; then
    echo "В листе нет http(s)-адреса AIA (CA Issuers)." >&2
  else
    try_url_candidate "$AIA_URL" "AIA листа" || true
  fi
fi

# 4) TLS-цепочка сервера (TOFU), либо сам лист при самоподписи (TOFU)
if [ -z "$CA" ]; then
  for f in "$WORK"/cert-*.pem; do
    [ "$(basename "$f")" = "cert-1.pem" ] && continue
    [ "$(fp_of "$f")" = "$LEAF_FP" ] && continue
    if verify_candidate "$f"; then
      use_ca "$f" "TLS-цепочка (TOFU)"
      echo "Якорь взят из TLS-цепочки сервера (TOFU)" >&2
      break
    fi
  done
fi
if [ -z "$CA" ] && is_selfsigned "$LEAF"; then
  use_ca "$LEAF" "самоподписанный лист (TOFU)"
  echo "Лист самоподписан — якорь: сам лист (TOFU-пиннинг сертификата)" >&2
fi

if [ -z "$CA" ]; then
  {
    echo "ОШИБКА: не удалось добыть сертификат издателя для $HOST."
    echo "Действуйте по скиллу: каталог оператора УЦ → скачать кандидатов → выявить перебором:"
    echo '  for c in candidates/*.pem; do openssl verify -partial_chain -CAfile "$c" leaf.pem >/dev/null 2>&1 && echo "издатель: $c"; done'
    echo "Либо передайте готовый PEM: CA_PEM=/путь/ca.pem bash fetch.sh ..."
    echo "Адрес каталога оператора часто указан в AIA/CDP самого листа."
  } >&2
  exit 1
fi

echo "Якорь ($SRC): $(openssl x509 -in "$CA" -noout -subject 2>/dev/null | sed 's/subject=//') [$CA]" >&2
echo "SHA-256: $(fp_of "$CA")" >&2
if [ "$SRC" != "CA_PEM" ]; then
  echo "Если отпечаток не сверен с известным эталоном — это TOFU: для важных операций подтвердите у пользователя." >&2
fi

# Запрос с пер-запросным доверием (проверка TLS включена).
# Тело всегда пишется в файл, статус — в stdout через -w (проверяется на < 400).
errf1="$WORK/curl1.err"
errf2="$WORK/curl2.err"
BODY="$WORK/body.out"
do_fetch() {  # $1 — дополнительные флаги curl; намеренное разбиение слов (флаги без пробелов)
  local extra="$1"
  curl -sSL --cacert "$CA" $extra -A "$UA" -H "Accept-Language: ru-RU,ru;q=0.9" \
    -o "$BODY" -w "HTTP %{http_code} (%{size_download} байт)\n" "$URL"
}

check_success() {  # $1 — вывод do_fetch: 0, если 100 <= HTTP < 400
  local res="$1" code
  code="$(printf '%s' "$res" | sed -nE 's/^HTTP ([0-9]{3}).*/\1/p')"
  [ -n "$code" ] && [ "$code" -lt 400 ]
}

print_out() {  # $1 — статусная строка; выводит результат: в файл либо в stdout
  if [ -n "$OUT" ]; then
    mv "$BODY" "$OUT"
    printf '%s -> %s\n' "$1" "$OUT"
  else
    cat "$BODY"
  fi
}

res=""; rc=0
res="$(do_fetch "" 2>"$errf1")" || rc=$?
if [ "$rc" -eq 0 ]; then
  if check_success "$res"; then
    print_out "$res"
    exit 0
  fi
  [ -n "$res" ] && printf '%s\n' "$res" >&2
  echo "ОШИБКА: ответ не является успешным (ожидался HTTP < 400)." >&2
  exit 1
fi

if grep -qi "revocation status is unknown" "$errf1"; then
  echo "Примечание: недоступна проверка отзыва (CRL/OCSP) приватного УЦ — повтор с --ssl-no-revoke." >&2
  rc=0
  res="$(do_fetch "--ssl-no-revoke" 2>"$errf2")" || rc=$?
  if [ "$rc" -eq 0 ]; then
    if check_success "$res"; then
      print_out "$res"
      exit 0
    fi
    [ -n "$res" ] && printf '%s\n' "$res" >&2
    echo "ОШИБКА: повтор вернул не-успешный ответ (ожидался HTTP < 400)." >&2
    echo "--- Первая ошибка (снята повтором --ssl-no-revoke):" >&2
    cat "$errf1" >&2
    exit 1
  fi
fi

echo "--- Первая ошибка:" >&2
cat "$errf1" >&2
if [ -s "$errf2" ]; then
  echo "--- Ошибка повтора (--ssl-no-revoke):" >&2
  cat "$errf2" >&2
fi
exit 1
