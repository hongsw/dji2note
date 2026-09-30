"""dji2note 명령행 도구."""
import argparse
import json
from datetime import datetime
import platform
import shutil
import subprocess
import sys
from pathlib import Path

from . import __version__, config, llm, pipeline, service, tools, upload
from .config import Config

OK, NG, WARN = "✅", "❌", "⚠️ "


def ask(question: str, default: str = "") -> str:
    suffix = f" [{default}]" if default else ""
    ans = input(f"{question}{suffix}: ").strip()
    return ans or default


def yes(question: str, default: bool = True) -> bool:
    ans = input(f"{question} [{'Y/n' if default else 'y/N'}]: ").strip().lower()
    return default if not ans else ans in ("y", "yes", "ㅇ", "네", "예")


def choose(question: str, options: list[tuple[str, str]], default: str) -> str:
    print(question)
    for i, (key, desc) in enumerate(options, 1):
        print(f"  {i}) {desc}{'  (기본)' if key == default else ''}")
    ans = input("번호 선택: ").strip()
    if ans.isdigit() and 1 <= int(ans) <= len(options):
        return options[int(ans) - 1][0]
    return default


# ── init ──────────────────────────────────────────────────────────────
def cmd_init(_args):
    cfg = config.load()
    print(f"\n🎙  dji2note {__version__} 설정을 시작합니다.\n")

    if not tools.ffmpeg():
        sys.exit(f"{NG} ffmpeg를 준비하지 못했습니다. brew install ffmpeg 후 다시 실행하세요.")

    # 1. 저장 위치
    cfg.output_dir = ask("\n① 결과를 저장할 폴더", cfg.output_dir)
    Path(cfg.output_dir).expanduser().mkdir(parents=True, exist_ok=True)

    # 2. 언어
    cfg.language = ask("② 대화 언어 (ko, en, ja, auto …)", cfg.language)

    # 3. 화자 분리·요약 엔진
    detected = llm.detect_backend()
    default = cfg.llm_backend if cfg.llm_backend != "none" else detected
    cfg.llm_backend = choose("\n③ 화자 분리·교정·요약에 쓸 AI", [
        ("claude-cli", "Claude Code CLI (claude 로그인 필요, 구독 사용량 사용)"
                       + (" — 감지됨" if llm.claude_cli_path() else " — 미설치")),
        ("anthropic-api", "Anthropic API 키 (사용량만큼 과금)"),
        ("none", "사용 안 함 — 받아쓰기 + 음량 기준 화자 분리만 (요약 없음)"),
    ], default)
    if cfg.llm_backend == "anthropic-api":
        key = ask("   Anthropic API 키 (sk-ant-…, 비우면 ANTHROPIC_API_KEY 환경변수 사용)",
                  "(저장된 키 유지)" if cfg.anthropic_api_key else "")
        if key and not key.startswith("("):
            cfg.anthropic_api_key = key
    if cfg.llm_backend != "none":
        cfg.llm_model = ask("   모델", cfg.llm_model)

    # 4. Google Drive 업로드
    print()
    if yes("④ 결과를 Google Drive에 Google Docs로 올릴까요?", True):
        setup_drive(cfg)
    else:
        cfg.upload = "none"

    config.save(cfg)
    print(f"\n{OK} 설정 저장: {config.CONFIG_FILE}")

    # 5. 받아쓰기 모델 미리 받기
    if yes("\n⑤ 받아쓰기 모델(약 1.6GB)을 지금 내려받을까요? (첫 녹음 처리 시간을 줄여 줌)"):
        from huggingface_hub import snapshot_download
        snapshot_download(cfg.whisper_model)
        print(f"{OK} 모델 준비 완료")

    # 6. 이미 DJI에 있는 녹음 처리 여부
    recs = pipeline.find_dji_recordings()
    state = config.load_state()
    new = [r for r in recs if r["name"] not in state]
    if new:
        print(f"\n지금 연결된 DJI에 녹음 {len(new)}개가 있습니다.")
        if not yes("⑥ 기존 녹음도 모두 처리할까요? (아니오 → 앞으로 새로 녹음한 것만 처리)", False):
            pipeline.mark_seen([r["name"] for r in new])
            print(f"{OK} 기존 녹음 {len(new)}개는 건너뜁니다. 개별 처리는 `dji2note process <파일>`")

    # 7. 자동 실행
    if yes("\n⑦ DJI를 연결하면 자동으로 처리하도록 설정할까요?"):
        service.install()
        print(f"{OK} 자동 실행 등록 완료. 처음 실행될 때 macOS가 '이동식 볼륨 접근' 권한을 물으면 허용하세요.")

    print("\n설정 끝! 점검: dji2note doctor   /   수동 실행: dji2note run\n")


def setup_drive(cfg: Config):
    rc = upload.rclone_path()
    if not rc:
        print("   Google Drive 업로드 도구(rclone)를 내려받습니다…")
        try:
            rc = tools.install_rclone()
        except Exception as e:
            print(f"   {WARN}rclone 설치 실패({e}) — 업로드를 끕니다.")
            cfg.upload = "none"
            return
    remotes = upload.drive_remotes()
    if remotes:
        default = cfg.rclone_remote if cfg.rclone_remote in remotes else remotes[0]
        opts = [(r, f"기존 Google Drive 연결 '{r}' 사용") for r in remotes] + [("__new__", "새로 연결")]
        pick = choose("   어느 Google Drive에 올릴까요?", opts, default)
    else:
        pick = "__new__"
    if pick == "__new__":
        name = ask("   연결 이름", "gdrive")
        print("   브라우저가 열리면 Google 계정으로 로그인하고 권한을 허용하세요…")
        r = subprocess.run([rc, "config", "create", name, "drive", "scope=drive"])
        if r.returncode != 0:
            print(f"   {NG} Google Drive 연결 실패. 업로드를 끕니다.")
            cfg.upload = "none"
            return
        pick = name
    cfg.rclone_remote = pick
    cfg.drive_folder = ask("   Drive 안의 폴더 이름", cfg.drive_folder)
    cfg.upload = "rclone"


# ── doctor ────────────────────────────────────────────────────────────
def run_checks(cfg: Config, live: bool = True) -> list[dict]:
    """점검 항목 목록. GUI도 `doctor --json`으로 같은 결과를 쓴다."""
    checks = []

    def add(key, ok, label, hint=""):
        checks.append({"key": key, "ok": bool(ok), "label": label, "hint": "" if ok else hint})

    add("platform", platform.system() == "Darwin" and platform.machine() == "arm64", "Apple Silicon Mac",
        "mlx-whisper는 Apple Silicon(M1 이상) Mac 전용입니다")
    add("config", config.CONFIG_FILE.exists(), "설정 파일", "dji2note init")
    add("ffmpeg", tools.ffmpeg(), "ffmpeg", "dji2note setup-tools")

    if cfg.llm_backend != "none":
        label = llm.PROVIDERS.get(cfg.llm_backend, {"title": cfg.llm_backend})["title"]
        if cfg.llm_backend == "claude-cli" and not tools.claude():
            add("llm", False, label, "Claude Code 설치 후 터미널에서 claude 로 로그인하세요")
        elif live:
            try:
                add("llm", "ok" in llm.ask(cfg, "reply with just: ok").lower(), f"{label} 응답")
            except Exception as e:
                add("llm", False, f"{label} 응답", str(e)[:200])

    if cfg.upload == "rclone":
        rc = tools.rclone()
        ok = False
        if rc and live:
            r = subprocess.run([rc, "lsd", f"{cfg.rclone_remote}:", "--max-depth", "1"],
                               capture_output=True, text=True, timeout=120)
            ok = r.returncode == 0
        add("drive", ok if live else bool(rc), f"Google Drive 연결 '{cfg.rclone_remote}'",
            f"rclone config reconnect {cfg.rclone_remote}:" if rc else "dji2note setup-tools")
    return checks


def cmd_doctor(args):
    cfg = config.load()
    checks = run_checks(cfg)
    if args.json:
        print(json.dumps({"checks": checks, "service": service.status(), "log": str(config.LOG_FILE)},
                         ensure_ascii=False))
        return 0 if all(c["ok"] for c in checks) else 1
    for c in checks:
        print(f"{OK if c['ok'] else NG} {c['label']}" + (f"\n    → {c['hint']}" if c["hint"] else ""))
    if cfg.llm_backend == "none":
        print(f"{WARN}AI 미사용 — 요약 없이 받아쓰기만 합니다 (dji2note init 으로 변경)")
    if cfg.upload != "rclone":
        print(f"{WARN}Drive 업로드 꺼짐 — 결과는 {cfg.notes_dir} 에만 저장")
    print(f"ℹ️  자동 실행: {service.status()}")
    print(f"ℹ️  로그: {config.LOG_FILE}")
    bad = sum(not c["ok"] for c in checks)
    print("\n모두 정상입니다." if not bad else f"\n문제 {bad}건을 확인하세요.")
    return 1 if bad else 0


# ── 나머지 명령 ───────────────────────────────────────────────────────
def cmd_run(args):
    pipeline.run(config.load(), dry_run=args.dry_run, include_seen=args.all, names=args.names)


def cmd_process(args):
    """DJI가 아닌 파일도 처리. 여러 파일을 주면 한 세션으로 이어 붙인다."""
    cfg = config.load()
    paths = [Path(p).expanduser().resolve() for p in args.files]
    for p in paths:
        if not p.exists():
            sys.exit(f"파일 없음: {p}")
    recs = [pipeline.recording_info(p) | {"duration": pipeline.duration(p)} for p in paths]
    recs.sort(key=lambda r: r["start"])
    groups = [recs] if args.join else [[r] for r in recs]
    state = config.load_state()
    for i, g in enumerate(groups, 1):
        res = pipeline.process_session(cfg, g, copy=False, index=(i, len(groups)) if len(groups) > 1 else None)
        for r in g:  # 처리 기록에 남겨 목록에서 '완료'로 보이게
            state[r["name"]] = {**res, "at": datetime.now().isoformat(timespec="seconds")}
        config.save_state(state)
        print(json.dumps(res, ensure_ascii=False))


def cmd_upload(args):
    cfg = config.load()
    folder = Path(args.folder).expanduser()
    if not folder.exists():
        folder = cfg.notes_dir / args.folder
    print(upload.upload(cfg, folder))


def cmd_service(args):
    if args.action == "install":
        service.install()
        print(f"{OK} 자동 실행 등록 완료")
    elif args.action == "uninstall":
        service.uninstall()
        print(f"{OK} 자동 실행 해제")
    print(service.status())


def cmd_list(args):
    state = config.load_state()
    if args.json:
        print(json.dumps(state, ensure_ascii=False))
        return
    if not state:
        print("처리 기록이 없습니다.")
    for name, info in sorted(state.items()):
        print(f"{info.get('status', '?'):10} {name}  {info.get('drive') or info.get('notes') or ''}")


def cmd_forget(args):
    state = config.load_state()
    for n in args.names:
        state.pop(Path(n).name, None)
    config.save_state(state)
    print(f"{OK} {len(args.names)}개를 처리 기록에서 지웠습니다. 다음 실행 때 다시 처리합니다.")


def cmd_config(args):
    cfg = config.load()
    if args.action == "set":
        fields = Config.__dataclass_fields__
        for pair in args.pairs:
            key, _, value = pair.partition("=")
            if key not in fields or key == "extra":
                sys.exit(f"알 수 없는 설정: {key}")
            typ = fields[key].type
            if typ in (bool, "bool"):
                setattr(cfg, key, value.lower() in ("1", "true", "yes"))
            elif typ in (int, "int"):
                setattr(cfg, key, int(value))
            else:
                setattr(cfg, key, value)
        keys = {p.partition("=")[0] for p in args.pairs}
        if "llm_backend" in keys and not keys & {"llm_model", "llm_fast_model"}:
            cfg.llm_model, cfg.llm_fast_model = llm.PROVIDERS.get(cfg.llm_backend, {"models": ("", "")})["models"]
        config.save(cfg)
    data = {k: v for k, v in cfg.__dict__.items() if k != "extra"}
    for k in ("anthropic_api_key", "openai_api_key", "gemini_api_key", "baryon_api_key"):
        data[k] = "***" if getattr(cfg, k) else ""  # 키는 화면에 노출하지 않음
    data["config_file"] = str(config.CONFIG_FILE)
    data["providers"] = {k: {"title": v["title"], "models": list(v["models"])} for k, v in llm.PROVIDERS.items()}
    data["codex_installed"] = bool(llm.codex_cli_path())
    data["notes_dir"] = str(cfg.notes_dir)
    print(json.dumps(data, ensure_ascii=False, indent=None if args.json else 1))


def cmd_scan(args):
    """연결된 DJI의 녹음과 처리 상태."""
    state = config.load_state()
    recs = pipeline.find_dji_recordings()
    rows = [{"name": r["name"], "path": str(r["src"]), "start": r["start"].isoformat(),
             "status": state.get(r["name"], {}).get("status", "new")} for r in recs]
    if args.json:
        print(json.dumps(rows, ensure_ascii=False))
    else:
        for r in rows:
            print(f"{r['status']:10} {r['start'][:16]}  {r['name']}")


def cmd_skip(args):
    names = args.names
    if args.all_new:
        state = config.load_state()
        names = [r["name"] for r in pipeline.find_dji_recordings() if r["name"] not in state]
    pipeline.mark_seen(names)
    print(f"{OK} {len(names)}개를 건너뛰기로 표시했습니다.")


def cmd_render(args):
    """Markdown 회의록을 HTML로 (Mac 앱의 보기·서식 복사용)."""
    path = Path(args.file).expanduser()
    html = upload.md_to_html(path.read_text(), path.stem)
    if args.fragment:
        import re
        html = re.search(r"<body>(.*)</body>", html, re.S).group(1)
    sys.stdout.write(html)


def cmd_setup_tools(args):
    print(f"ffmpeg: {tools.ffmpeg()}", flush=True)
    rc = tools.rclone() or tools.install_rclone()
    print(f"rclone: {rc}", flush=True)
    if args.model:
        from huggingface_hub import snapshot_download
        print("받아쓰기 모델 내려받는 중…", flush=True)
        print(f"model: {snapshot_download(config.load().whisper_model)}")


def cmd_drive(args):
    if args.action == "remotes":
        print(json.dumps(upload.drive_remotes()))
    elif args.action == "connect":
        rc = tools.rclone() or tools.install_rclone()
        # 브라우저가 열려 Google 로그인 → 권한 허용
        r = subprocess.run([rc, "config", "create", args.name, "drive", "scope=drive"])
        if r.returncode == 0:
            cfg = config.load()
            cfg.upload, cfg.rclone_remote = "rclone", args.name
            config.save(cfg)
            print(f"{OK} Google Drive 연결 완료: {args.name}")
        return r.returncode


def main():
    ap = argparse.ArgumentParser(prog="dji2note",
                                 description="DJI Mic 녹음 → 받아쓰기 → 화자 분리 → 요약 → Google Drive")
    ap.add_argument("--version", action="version", version=f"dji2note {__version__}")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("init", help="설정 마법사").set_defaults(fn=cmd_init)
    p = sub.add_parser("doctor", help="설치·설정 점검")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_doctor)
    p = sub.add_parser("run", help="연결된 DJI의 새 녹음 처리")
    p.add_argument("--dry-run", action="store_true", help="처리할 대상만 보여 줌")
    p.add_argument("--all", action="store_true", help="건너뛰기로 표시한 기존 녹음도 처리")
    p.add_argument("--names", nargs="+", help="이 파일들만 처리 (상태 무관)")
    p.set_defaults(fn=cmd_run)
    p = sub.add_parser("process", help="오디오 파일을 직접 처리")
    p.add_argument("files", nargs="+")
    p.add_argument("--join", action="store_true", help="여러 파일을 한 대화로 이어 붙임")
    p.set_defaults(fn=cmd_process)
    p = sub.add_parser("upload", help="결과 폴더를 Drive에 다시 올림")
    p.add_argument("folder")
    p.set_defaults(fn=cmd_upload)
    p = sub.add_parser("service", help="자동 실행 관리")
    p.add_argument("action", choices=["install", "uninstall", "status"])
    p.set_defaults(fn=cmd_service)
    p = sub.add_parser("list", help="처리 기록 보기")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_list)
    p = sub.add_parser("config", help="설정 보기·바꾸기 (config set key=value …)")
    p.add_argument("action", choices=["show", "set"], nargs="?", default="show")
    p.add_argument("pairs", nargs="*")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_config)
    p = sub.add_parser("scan", help="연결된 DJI의 녹음과 처리 상태")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_scan)
    p = sub.add_parser("skip", help="녹음을 처리하지 않고 건너뛰기로 표시")
    p.add_argument("names", nargs="*")
    p.add_argument("--all-new", action="store_true", help="연결된 DJI의 새 녹음 전부")
    p.set_defaults(fn=cmd_skip)
    p = sub.add_parser("render", help="Markdown 회의록을 HTML로 출력")
    p.add_argument("file")
    p.add_argument("--fragment", action="store_true", help="<body> 안쪽만")
    p.set_defaults(fn=cmd_render)
    p = sub.add_parser("setup-tools", help="ffmpeg·rclone 준비 (Homebrew 불필요)")
    p.add_argument("--model", action="store_true", help="받아쓰기 모델도 미리 내려받기")
    p.set_defaults(fn=cmd_setup_tools)
    p = sub.add_parser("drive", help="Google Drive 연결")
    p.add_argument("action", choices=["remotes", "connect"])
    p.add_argument("name", nargs="?", default="gdrive")
    p.set_defaults(fn=cmd_drive)
    p = sub.add_parser("forget", help="처리 기록에서 지워 다시 처리되게 함")
    p.add_argument("names", nargs="+")
    p.set_defaults(fn=cmd_forget)

    tools.setup_path()
    args = ap.parse_args()
    try:
        return args.fn(args)
    except KeyboardInterrupt:
        print("\n중단했습니다.")
        return 130


if __name__ == "__main__":
    sys.exit(main())
