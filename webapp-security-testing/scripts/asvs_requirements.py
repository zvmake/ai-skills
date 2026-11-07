#!/usr/bin/env python3
"""Формирует и обновляет рабочий чек-лист OWASP ASVS для заданного уровня и глав.

Источник требований (по приоритету):
1. CSV последнего стабильного релиза из https://github.com/OWASP/ASVS/tags
   (теги вида vX.Y.Z или vX.Y.Z_release; тег `latest` — bleeding edge, он игнорируется);
2. если скачать или разобрать CSV не удалось — локальный файл `references/owasp-asvs.csv`
   (или путь, переданный через `--csv`).

Только стандартная библиотека Python 3.8+. Кроссплатформенно (Linux, macOS, Windows).

Примеры создания чек-листа:
    python scripts/asvs_requirements.py --level 2 --out ./asvs-checklist-L2.md
    python scripts/asvs_requirements.py --level 1 --chapters V6-V8 --out ./asvs-L1.md
    python scripts/asvs_requirements.py --level 3 --offline --force --out ./asvs-L3.md

Пример пакетного обновления статусов в существующем чек-листе (без переписывания файла вручную):
    python scripts/asvs_requirements.py --update ./asvs-checklist-L2.md \\
        --set "V6.2.1|SAST + DAST|Pass|src/auth/dto.ts:18 — minLength(12)" \\
        --set "V6.2.4|SAST|Fail|См. карточку [MEDIUM] Отсутствует проверка по словарю утечек"
"""

import argparse
import csv
import datetime
import io
import json
import os
import re
import sys
import urllib.parse
import urllib.request

REPO_API = "https://api.github.com/repos/OWASP/ASVS"
ALLOWED_HOSTS = {
    "api.github.com",
    "github.com",
    "objects.githubusercontent.com",
    "release-assets.githubusercontent.com",
    "raw.githubusercontent.com",
}
TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)(?:[_-]release)?$", re.IGNORECASE)
CHAPTER_TOKEN_RE = re.compile(r"^[vV]?(\d+)(?:\s*[-–—]\s*[vV]?(\d+))?$")
CODE_TOKEN_RE = re.compile(r"'([A-Za-z0-9_./:\\-]+_[A-Za-z0-9_./:\\-]*)'")
REQUIRED_COLUMNS = {
    "chapter_id",
    "chapter_name",
    "section_id",
    "section_name",
    "req_id",
    "req_description",
    "L",
}
VALID_STATUSES = {"—", "Pass", "Fail", "N/A", "Not verified"}
SKILL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUNDLED_CSV = os.path.join(SKILL_DIR, "references", "owasp-asvs.csv")
TIMEOUT = 20
MAX_BYTES = 10 * 1024 * 1024


def configure_stdio():
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")


def validate_github_url(url):
    parsed = urllib.parse.urlparse(url)
    host = (parsed.hostname or "").lower()
    if parsed.scheme != "https" or host not in ALLOWED_HOSTS:
        raise ValueError(f"недопустимый URL (разрешены только https на доменах GitHub): {url}")


class SafeGitHubRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        validate_github_url(newurl)
        new_req = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new_req is not None and urllib.parse.urlparse(newurl).hostname != "api.github.com":
            new_req.headers.pop("Authorization", None)
            new_req.unredirected_hdrs.pop("Authorization", None)
        return new_req


def http_get(url, accept="application/vnd.github+json"):
    validate_github_url(url)
    headers = {"Accept": accept, "User-Agent": "webapp-security-testing-skill"}
    token = os.environ.get("GITHUB_TOKEN")
    if token and urllib.parse.urlparse(url).hostname == "api.github.com":
        headers["Authorization"] = f"Bearer {token}"
    opener = urllib.request.build_opener(SafeGitHubRedirectHandler)
    req = urllib.request.Request(url, headers=headers)
    with opener.open(req, timeout=TIMEOUT) as resp:
        data = resp.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise RuntimeError("размер ответа превышает допустимый предел 10 МБ")
        return data


def find_csv_asset(release):
    for asset in release.get("assets") or []:
        name = asset.get("name", "")
        if re.search(r"[_-]en\.csv$", name, re.IGNORECASE) and "legacy" not in name.lower():
            return asset
    return None


def iter_stable_releases():
    releases = json.loads(http_get(f"{REPO_API}/releases?per_page=100"))
    candidates = []
    for rel in releases:
        if rel.get("draft") or rel.get("prerelease"):
            continue
        tag = rel.get("tag_name", "")
        m = TAG_RE.match(tag)
        if m:
            ver = tuple(int(x) for x in m.group(1, 2, 3))
            candidates.append((ver, tag, rel))
    candidates.sort(key=lambda item: item[0], reverse=True)
    return candidates


def download_latest():
    errors = []
    for ver, tag, rel in iter_stable_releases():
        asset = find_csv_asset(rel)
        if not asset:
            errors.append(f"{tag}: нет *_en.csv")
            continue
        url = asset.get("browser_download_url", "")
        try:
            raw = http_get(url, accept="application/octet-stream")
            text = raw.decode("utf-8-sig")
            rows = parse(text)
            version_str = ".".join(map(str, ver))
            return rows, version_str, f"скачан последний стабильный релиз ({version_str}, тег {tag}): {url}"
        except Exception as exc:
            errors.append(f"{tag}: {exc}")
    detail = "; ".join(errors) if errors else "стабильные релизы с CSV не найдены"
    raise RuntimeError(detail)


def parse(text):
    reader = csv.DictReader(io.StringIO(text))
    fieldnames = {name.strip() for name in (reader.fieldnames or []) if name}
    missing = REQUIRED_COLUMNS - fieldnames
    if missing:
        raise RuntimeError(f"неожиданный формат CSV, нет колонок: {', '.join(sorted(missing))}")
    rows = []
    for idx, raw_row in enumerate(reader, start=2):
        row = {(k.strip() if k else ""): (v.strip() if isinstance(v, str) else "") for k, v in raw_row.items()}
        if not any(row.values()):
            continue
        if row.get("L") not in {"1", "2", "3"}:
            raise RuntimeError(
                f"строка {idx}: неожиданный уровень L='{row.get('L')}' у требования '{row.get('req_id')}'"
            )
        if not row.get("chapter_id") or not row.get("req_id") or not row.get("req_description"):
            raise RuntimeError(f"строка {idx}: пустые обязательные поля")
        rows.append(row)
    if not rows:
        raise RuntimeError("CSV не содержит требований")
    return rows


def load(offline, csv_path):
    if csv_path:
        if not os.path.isfile(csv_path):
            raise RuntimeError(f"файл не найден: {csv_path}")
        with open(csv_path, encoding="utf-8-sig") as f:
            rows = parse(f.read())
        return rows, "пользовательский CSV", f"локальный файл {csv_path} (указан --csv)"

    reason = "указан --offline"
    if not offline:
        try:
            return download_latest()
        except Exception as exc:
            reason = f"не удалось скачать последний релиз ({exc})"
            print(f"Предупреждение: {reason}. Переключаюсь на приложенный CSV.", file=sys.stderr)

    if not os.path.isfile(BUNDLED_CSV):
        raise RuntimeError(f"не найден резервный файл {BUNDLED_CSV}")
    with open(BUNDLED_CSV, encoding="utf-8-sig") as f:
        rows = parse(f.read())
    return rows, "приложенный CSV", f"приложенный CSV references/owasp-asvs.csv; причина: {reason}"


def parse_chapters(spec):
    if not spec or not spec.strip():
        return set()
    result = set()
    for part in spec.split(","):
        token = part.strip()
        if not token:
            continue
        m = CHAPTER_TOKEN_RE.match(token)
        if not m:
            raise RuntimeError(
                f"некорректный формат главы '{token}' (ожидается например V6, V6,V7,V8 или V6-V8)"
            )
        start = int(m.group(1))
        end = int(m.group(2)) if m.group(2) else start
        if start < 1 or end < start or end > 99:
            raise RuntimeError(f"некорректный диапазон глав '{token}'")
        for num in range(start, end + 1):
            result.add(f"V{num}")
    return result


def chapter_sort_key(ch_id):
    num = ch_id[1:] if ch_id.upper().startswith("V") else ch_id
    return (0, int(num), ch_id) if num.isdigit() else (1, 0, ch_id)


def cell(text):
    cleaned = " ".join(str(text).split()).replace("|", "\\|")
    return CODE_TOKEN_RE.sub(r"`\1`", cleaned)


def render(rows, version_label, source, level, chapters):
    chapter_filtered = [r for r in rows if not chapters or r["chapter_id"] in chapters]
    selected = [r for r in chapter_filtered if int(r["L"]) <= level]
    by_level = {lvl: sum(1 for r in selected if int(r["L"]) == lvl) for lvl in (1, 2, 3)}
    chapters_str = (
        ", ".join(sorted(chapters, key=chapter_sort_key)) if chapters else "все"
    )
    out = [
        f"# Рабочий чек-лист OWASP ASVS ({version_label}) — уровень L{level}",
        "",
        f"- Источник требований: {source}",
        f"- Дата формирования: {datetime.date.today().isoformat()}",
        f"- Главы: {chapters_str}",
        f"- Требований: {len(selected)} (L1: {by_level[1]}, L2: {by_level[2]}, L3: {by_level[3]})",
        "- Статусы: `—` (ещё не проверено) → `Pass` / `Fail` / `N/A` / `Not verified`. Метод: `SAST` / `DAST` / `CFG` / `DOC` (см. references/owasp-asvs.md).",
        "- Лицензия текста требований: CC BY-SA 4.0, © OWASP Foundation (https://owasp.org/www-project-application-security-verification-standard/).",
        "",
    ]

    if not selected:
        higher = len(chapter_filtered)
        out.append(
            f"> В выбранных главах ({chapters_str}) нет требований уровня L{level} "
            f"(требований более высоких уровней в этих главах: {higher})."
        )
        out.append("")
        return "\n".join(out), 0, by_level

    chapters_order = []
    by_chapter = {}
    for r in selected:
        cid = r["chapter_id"]
        if cid not in by_chapter:
            chapters_order.append((cid, r["chapter_name"]))
            by_chapter[cid] = []
        by_chapter[cid].append(r)

    for cid, cname in chapters_order:
        out += [
            f"## {cid} {cell(cname)}",
            "",
            "| ID | Раздел | L | Требование | Метод | Статус | Доказательство / причина |",
            "|---|---|---|---|---|---|---|",
        ]
        for r in by_chapter[cid]:
            section_label = f"{cell(r['section_id'])} {cell(r['section_name'])}"
            out.append(
                f"| {cell(r['req_id'])} | {section_label} | {r['L']} | {cell(r['req_description'])} | | — | |"
            )
        out.append("")
    return "\n".join(out), len(selected), by_level


def update_checklist(path, updates):
    if not os.path.isfile(path):
        raise RuntimeError(f"файл чек-листа не найден: {path}")
    parsed_updates = {}
    for item in updates:
        parts = item.split("|", 3)
        if len(parts) != 4:
            raise RuntimeError(
                f"неверный формат --set '{item}' (ожидается 'REQ_ID|МЕТОД|СТАТУС|ДОКАЗАТЕЛЬСТВО')"
            )
        req_id, method, status, evidence = (p.strip() for p in parts)
        if status not in VALID_STATUSES:
            raise RuntimeError(
                f"недопустимый статус '{status}' для {req_id} (допустимы: {', '.join(sorted(VALID_STATUSES))})"
            )
        parsed_updates[req_id.upper()] = (cell(method), status, cell(evidence))

    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()

    updated_ids = set()
    new_lines = []
    for line in lines:
        if line.startswith("| ") and not line.startswith("| ID |") and not line.startswith("|---"):
            cols = [c.strip() for c in re.split(r"(?<!\\)\|", line.strip()[1:-1])]
            if len(cols) == 7 and cols[0].upper() in parsed_updates:
                req_key = cols[0].upper()
                method, status, evidence = parsed_updates[req_key]
                cols[4] = method
                cols[5] = status
                cols[6] = evidence
                line = "| " + " | ".join(cols) + " |"
                updated_ids.add(req_key)
        new_lines.append(line)

    missing_ids = set(parsed_updates.keys()) - updated_ids
    if missing_ids:
        raise RuntimeError(f"в чек-листе не найдены ID: {', '.join(sorted(missing_ids))}")

    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(new_lines) + "\n")
    print(f"Обновлено записей в {os.path.abspath(path)}: {len(updated_ids)}")


def main():
    configure_stdio()
    parser = argparse.ArgumentParser(description="Чек-лист OWASP ASVS: генерация и обновление")
    parser.add_argument("--level", type=int, choices=(1, 2, 3), help="уровень ASVS (накопительный)")
    parser.add_argument(
        "--chapters",
        default="",
        help="ограничить главами: список или диапазон, например V6,V7,V8 или V6-V8",
    )
    parser.add_argument("--out", default="", help="путь к создаваемому файлу рабочего чек-листа (.md)")
    parser.add_argument("--offline", action="store_true", help="не скачивать, использовать приложенный CSV")
    parser.add_argument("--csv", default="", help="путь к пользовательскому CSV-файлу ASVS")
    parser.add_argument("--force", action="store_true", help="перезаписать существующий файл --out")
    parser.add_argument("--update", default="", help="путь к существующему чек-листу для пакетного обновления строк")
    parser.add_argument(
        "--set",
        action="append",
        default=[],
        help="обновить строку в режиме --update: 'REQ_ID|МЕТОД|СТАТУС|ДОКАЗАТЕЛЬСТВО' (можно указать несколько раз)",
    )
    args = parser.parse_args()

    try:
        if args.update:
            if not args.set:
                sys.exit("Ошибка: при использовании --update укажи хотя бы один аргумент --set")
            update_checklist(args.update, args.set)
            return

        if not args.level or not args.out:
            sys.exit("Ошибка: для создания чек-листа укажи --level {1,2,3} и --out <путь>")

        out_abs = os.path.abspath(args.out)
        if os.path.exists(out_abs) and not args.force:
            sys.exit(
                f"Ошибка: файл чек-листа уже существует: {out_abs}\n"
                "Используй --update для записи результатов в существующий файл или --force для перезаписи."
            )

        chapters = parse_chapters(args.chapters)
        rows, version_label, source = load(args.offline, args.csv)
        available_chapters = {r["chapter_id"] for r in rows}
        unknown = chapters - available_chapters
        if unknown:
            sys.exit(
                f"Ошибка: в выбранном наборе ASVS ({version_label}) нет глав: "
                f"{', '.join(sorted(unknown, key=chapter_sort_key))}"
            )

        text, total, by_level = render(rows, version_label, source, args.level, chapters)
        os.makedirs(os.path.dirname(out_abs) or ".", exist_ok=True)
        with open(out_abs, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)

        print(
            f"ASVS ({version_label}), уровень L{args.level}: {total} требований "
            f"(L1: {by_level[1]}, L2: {by_level[2]}, L3: {by_level[3]})"
        )
        print(f"Источник: {source}")
        print(f"Чек-лист: {out_abs}")
    except Exception as exc:
        sys.exit(f"Ошибка: {exc}")


if __name__ == "__main__":
    main()
