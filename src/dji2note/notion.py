"""회의록을 Notion 페이지로 올린다 (내부 통합 토큰 사용, 서버 불필요).

설정: Notion에서 통합을 만들어 토큰을 받고, 회의록을 모을 페이지나 데이터베이스에
그 통합을 연결(••• → 연결 → 통합 추가)한 뒤 notion_token / notion_parent 에 넣는다.
"""
import json
import re
import time
import urllib.error
import urllib.request
from pathlib import Path

from .config import Config

API = "https://api.notion.com/v1"
VERSION = "2022-06-28"      # database_id 부모를 그대로 쓸 수 있는 안정 버전
TEXT_LIMIT = 2000           # rich_text 한 조각 최대 길이
BATCH = 100                 # 한 번에 추가할 수 있는 블록 수


class NotionError(RuntimeError):
    pass


def parse_id(value: str) -> str:
    """페이지·데이터베이스 링크나 ID에서 32자리 ID를 뽑아 하이픈 형식으로."""
    # 링크의 마지막 경로 조각 끝 32자리가 ID ("제목-<ID>" 또는 하이픈 UUID)
    seg = value.split("?")[0].split("#")[0].rstrip("/").split("/")[-1]
    m = re.search(r"([0-9a-f]{32})$", seg.replace("-", "").lower())
    if not m:
        raise NotionError("Notion 페이지 링크(또는 ID)를 알아볼 수 없습니다")
    h = m.group(1)
    return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:]}"


def _request(cfg: Config, method: str, path: str, body: dict | None = None) -> dict:
    if not cfg.notion_token:
        raise NotionError("Notion 토큰이 설정되지 않았습니다")
    req = urllib.request.Request(
        API + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {cfg.notion_token}", "Notion-Version": VERSION,
                 "Content-Type": "application/json"})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            if e.code == 429 and attempt < 3:  # 요청 제한 → 잠시 후 재시도
                time.sleep(float(e.headers.get("Retry-After", 1)) + 0.5)
                continue
            try:
                msg = json.loads(detail).get("message", detail)
            except ValueError:
                msg = detail
            if e.code == 404:
                msg += " — 회의록 페이지에서 ••• → 연결 → 이 통합을 추가했는지 확인하세요"
            if e.code == 401:
                msg = "토큰이 올바르지 않습니다"
            raise NotionError(f"Notion {e.code}: {msg[:300]}") from None
    raise NotionError("Notion 요청 제한으로 실패했습니다")


def resolve_parent(cfg: Config) -> dict:
    """부모가 페이지인지 데이터베이스인지 알아낸다. {'type','id','title','title_prop','date_prop'}"""
    pid = parse_id(cfg.notion_parent)
    try:
        db = _request(cfg, "GET", f"/databases/{pid}")
        props = db.get("properties", {})
        title_prop = next((k for k, v in props.items() if v["type"] == "title"), "Name")
        date_prop = next((k for k, v in props.items() if v["type"] == "date"), None)
        title = "".join(t.get("plain_text", "") for t in db.get("title", []))
        return {"type": "database", "id": pid, "title": title, "title_prop": title_prop, "date_prop": date_prop}
    except NotionError as e:
        if "404" not in str(e) and "400" not in str(e):
            raise
    page = _request(cfg, "GET", f"/pages/{pid}")
    title = ""
    for v in page.get("properties", {}).values():
        if v.get("type") == "title":
            title = "".join(t.get("plain_text", "") for t in v["title"])
    return {"type": "page", "id": pid, "title": title}


# ── Markdown → Notion 블록 ─────────────────────────────────────────────

def rich_text(text: str) -> list[dict]:
    """**굵게**, `코드`, [링크](url) 를 annotation으로 바꾸고 2000자 단위로 나눈다."""
    out = []
    pattern = re.compile(r"\*\*(.+?)\*\*|`([^`]+)`|\[([^\]]+)\]\((https?://[^)]+)\)")
    pos = 0

    def add(s: str, bold=False, code=False, url=None):
        for i in range(0, len(s), TEXT_LIMIT):
            piece = s[i:i + TEXT_LIMIT]
            if piece:
                item = {"type": "text", "text": {"content": piece}}
                if url:
                    item["text"]["link"] = {"url": url}
                if bold or code:
                    item["annotations"] = {"bold": bold, "code": code}
                out.append(item)

    for m in pattern.finditer(text):
        add(text[pos:m.start()])
        if m.group(1) is not None:
            add(m.group(1), bold=True)
        elif m.group(2) is not None:
            add(m.group(2), code=True)
        else:
            add(m.group(3), url=m.group(4))
        pos = m.end()
    add(text[pos:])
    return out[:100] or [{"type": "text", "text": {"content": ""}}]


def _block(kind: str, text: str) -> dict:
    return {"object": "block", "type": kind, kind: {"rich_text": rich_text(text)}}


def md_to_blocks(md: str) -> list[dict]:
    blocks: list[dict] = []
    lines = md.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].rstrip()
        s = line.strip()
        if not s:
            i += 1
            continue
        if s.startswith("|"):  # 표
            rows = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
                if not all(re.fullmatch(r":?-{2,}:?", c) for c in cells if c):
                    rows.append(cells)
                i += 1
            width = max(len(r) for r in rows) if rows else 1
            blocks.append({"object": "block", "type": "table", "table": {
                "table_width": width, "has_column_header": True, "has_row_header": False,
                "children": [{"object": "block", "type": "table_row", "table_row": {
                    "cells": [rich_text(r[c]) if c < len(r) else [] for c in range(width)]}} for r in rows]}})
            continue
        if re.fullmatch(r"-{3,}|\*{3,}", s):
            blocks.append({"object": "block", "type": "divider", "divider": {}})
        elif m := re.match(r"(#{1,3})\s+(.*)", s):
            blocks.append(_block(f"heading_{len(m.group(1))}", m.group(2)))
        elif m := re.match(r"[-*]\s+(.*)", s):
            blocks.append(_block("bulleted_list_item", m.group(1)))
        elif m := re.match(r"\d+\.\s+(.*)", s):
            blocks.append(_block("numbered_list_item", m.group(1)))
        elif s.startswith(">"):
            blocks.append(_block("quote", s.lstrip("> ")))
        else:
            # 빈 줄 전까지 한 문단으로 (줄바꿈 유지)
            para = [s]
            while i + 1 < len(lines) and lines[i + 1].strip() and not re.match(
                    r"(#{1,3}\s|[-*]\s|\d+\.\s|\||>|-{3,})", lines[i + 1].strip()):
                i += 1
                para.append(lines[i].strip())
            blocks.append(_block("paragraph", "\n".join(para)))
        i += 1
    return blocks


def _append(cfg: Config, block_id: str, blocks: list[dict]):
    for k in range(0, len(blocks), BATCH):
        _request(cfg, "PATCH", f"/blocks/{block_id}/children", {"children": blocks[k:k + BATCH]})
        time.sleep(0.35)  # 초당 약 3회 제한


def _title_of(md: str, fallback: str) -> str:
    for line in md.splitlines():
        if "주제:" in line:
            t = line.replace("**", "").split("주제:", 1)[1].strip()
            if t:
                return t[:200]
    return fallback


def publish(cfg: Config, folder: Path, drive_url: str = "") -> str:
    """회의록 폴더를 Notion 페이지로 만든다. 만든 페이지 주소를 돌려준다."""
    summary = (folder / "summary.md").read_text() if (folder / "summary.md").exists() else ""
    transcript = (folder / "transcript.md").read_text() if (folder / "transcript.md").exists() else ""
    title = _title_of(summary, folder.name)
    parent = resolve_parent(cfg)

    # 폴더 이름 "2026-09-28_1127_..." → 날짜
    m = re.match(r"(\d{4}-\d{2}-\d{2})_(\d{2})(\d{2})", folder.name)
    when = f"{m.group(1)}T{m.group(2)}:{m.group(3)}:00" if m else None

    intro = [f"🎙 {folder.name}"]
    if drive_url:
        intro.append(f"[Google Drive에서 보기]({drive_url})")
    children = [_block("callout", " · ".join(intro))] + md_to_blocks(summary or "(요약 없음 — AI 미사용)")
    children[0]["callout"]["icon"] = {"type": "emoji", "emoji": "🎙"}

    if parent["type"] == "database":
        props = {parent["title_prop"]: {"title": rich_text(title)}}
        if parent.get("date_prop") and when:
            props[parent["date_prop"]] = {"date": {"start": when, "time_zone": "Asia/Seoul"}}
        body = {"parent": {"database_id": parent["id"]}, "properties": props}
    else:
        body = {"parent": {"page_id": parent["id"]},
                "properties": {"title": {"title": rich_text(title)}}}
    body["icon"] = {"type": "emoji", "emoji": "📝"}
    body["children"] = children[:BATCH]
    page = _request(cfg, "POST", "/pages", body)
    _append(cfg, page["id"], children[BATCH:])

    if transcript:
        sub = _request(cfg, "POST", "/pages", {
            "parent": {"page_id": page["id"]}, "icon": {"type": "emoji", "emoji": "💬"},
            "properties": {"title": {"title": rich_text("스크립트(화자분리)")}}})
        _append(cfg, sub["id"], md_to_blocks(transcript))
    return page.get("url", "")
