# DJI2Note Windows 버전 — 개발 계획과 환경

> 작성: 2026-09-30 · 대상: Windows 10 22H2 / 11 (x64) · 상태: 계획

## 1. 목표
Mac과 같은 경험을 Windows에서 제공한다.
**DJI를 USB로 꽂으면 → 받아쓰기 → 화자 분리 → 요약 → Google Drive**, 그리고 트레이 앱에서 요약·대본을 보고 복사한다.
설치는 **관리자 권한 없이** 한 번에 끝나야 한다.

## 2. 핵심 결정 (권장안)

| 항목 | 권장 | 이유 | 대안 |
|---|---|---|---|
| 엔진 | **기존 Python 엔진을 크로스플랫폼화** (코드베이스 1개) | CLI `--json` 계약을 Mac·Windows 앱이 그대로 공유 | Windows 전용 재작성 ✗ |
| 받아쓰기 | **faster-whisper** (CTranslate2, CPU int8 / NVIDIA GPU) | mlx는 Apple 전용. Windows 휠 제공, 같은 turbo 모델 사용 | whisper.cpp (Vulkan) |
| GUI 언어·프레임워크 | **C# · WinUI 3 (Windows App SDK)** — 권장, 확정 대기 | 공식 권장 네이티브 UI, Windows 11 Fluent, 새 기능(Windows ML·AI API) 우선. 상세: [windows-ui-comparison.md](windows-ui-comparison.md) | C# · WPF (.NET 10) — 빠르고 안정적, Mac에서 컴파일 가능 |
| 트레이 아이콘 | H.NotifyIcon.Wpf | 메뉴바 패널에 대응 | — |
| 요약·대본 보기 | WebView2 + 엔진 `render` | Mac 보기 창과 같은 HTML | — |
| DJI 연결 감지 | `WM_DEVICECHANGE`(DBT_DEVICEARRIVAL) → 드라이브 문자 스캔 | 이벤트 방식, 폴링 없음 | WMI `Win32_VolumeChangeEvent` |
| 자동 시작 | `HKCU\...\Run` 등록 | 관리자 권한 불필요 | 작업 스케줄러 |
| 설치·업데이트 | **Velopack** → `DJI2NoteSetup.exe` + GitHub Releases 자동 업데이트 | 사용자 단위 설치, 증분 업데이트 | Inno Setup, MSIX |
| 한 줄 설치 | `irm https://…/install.ps1 \| iex` | PowerShell로 받은 파일엔 인터넷 표시(MOTW)가 없어 **SmartScreen 경고 회피** (Mac `curl` 방식과 동일) | winget (2단계) |
| 코드 서명 | 1차: 미서명 + 안내 / 2차: **Azure Trusted Signing**(월 약 $10) | 미서명 Setup.exe는 "Windows의 PC 보호" 경고 → "추가 정보 → 실행" | EV 인증서(고가) |

## 3. 엔진 크로스플랫폼화 — 해야 할 일

현재 Mac 전용 지점(코드 조사 결과):

| 파일 | Mac 전용 코드 | Windows 대응 |
|---|---|---|
| `transcribe.py` | `mlx_whisper` | ASR 백엔드 추상화: `mlx`(Apple Silicon) / `faster-whisper`(그 외). 설정 `asr_backend = "auto"` |
| `pyproject.toml` | `mlx-whisper` 무조건 설치 | 플랫폼 마커: `mlx-whisper; sys_platform=='darwin' and platform_machine=='arm64'`, `faster-whisper; …else` |
| `pipeline.py` | `fcntl` 락 | `msvcrt.locking` 또는 `filelock` 패키지 |
| `pipeline.py` | `/Volumes` 스캔 | 이동식 드라이브 문자 스캔(`GetDriveTypeW == DRIVE_REMOVABLE`) → `E:\TX_MIC…\*.wav` |
| `pipeline.py` | `osascript` 알림 | 알림은 **앱이 담당**(두 OS 공통). CLI 단독 실행 시 Windows는 생략 또는 토스트 |
| `config.py` / `tools.py` | `~/Library/...` 경로 | `%APPDATA%\dji2note`(설정), `%LOCALAPPDATA%\DJI2Note\bin`(도구), `%LOCALAPPDATA%\DJI2Note\logs` |
| `tools.py` | rclone `osx-arm64` zip, ffmpeg 심링크 | `rclone-current-windows-amd64.zip`→`rclone.exe`, ffmpeg는 심링크 대신 **경로를 직접 사용** |
| `service.py` | launchd | Windows에선 앱이 담당 → CLI `service`는 "앱에서 설정하세요" 안내 |
| `cli.py doctor` | Apple Silicon 검사 | 플랫폼별 검사(Windows: x64, 여유 RAM, GPU 유무) |
| 공통 | — | 콘솔 **UTF-8 강제**(`PYTHONUTF8=1`, `sys.stdout.reconfigure`) — cp949에서 한글·이모지 깨짐 방지 |

추가 작업:
- **테스트 신설**: 지금은 자동 테스트가 없음. `pytest`로 세션 묶기·Whisper 줄 파싱·음량 화자 분리·render·config 왕복을 검증하고 Mac/Windows CI에서 모두 실행
- **CLI 계약 문서화**: `docs/engine-cli.md` — 앱이 부르는 명령(`config/scan/list/doctor --json`, `run`, `process`, `render`, `drive`, `skip`, `setup-tools`)과 출력 형식을 고정해 두 앱이 깨지지 않게 함
- **진행률 통일**: faster-whisper는 tqdm을 쓰지 않으므로, 엔진이 `PROGRESS 42` 같은 줄을 직접 출력하게 바꾸고 두 앱이 이 줄을 파싱

### 받아쓰기 성능 (가장 큰 위험)
- NVIDIA GPU가 있으면 빠르지만, **CPU만 있는 노트북에서는 large-v3-turbo가 녹음 길이보다 오래 걸릴 수 있음**
- 대응: 1단계에서 실측 → 기기 사양에 따라 기본 모델 자동 추천(turbo / medium / small), 설정에서 변경 가능
- 기준 기기: NucBoxG3(저전력 CPU, 최악 조건) + GitHub 러너(4코어) + GPU 노트북(있다면)

## 4. Windows 앱 (C# / WinUI 3) 구성

> WPF로 확정되면 폴더 구조는 같고 `*.xaml`만 WPF 문법으로 바뀐다.

Mac 앱과 화면·동작을 1:1로 맞춘다.

```
windows/
  DJI2Note.sln
  src/DJI2Note/
    App.xaml(.cs)            트레이 상주, 단일 인스턴스, 자동 시작
    Engine/EngineClient.cs   uv·dji2note 설치, 명령 실행·줄 단위 출력 스트리밍 (Mac Engine.swift 대응)
    Engine/Models.cs         config/doctor/list/scan JSON 모델
    Services/DriveWatcher.cs WM_DEVICECHANGE → DJI 파일 패턴 확인 → run
    Services/Clipboard.cs    CF_HTML(헤더 포함) + 일반 텍스트 동시 복사
    Views/TrayPanel.xaml     상태·진행률·지금 처리·파일 처리·최근 회의록(요약/대본 보기·복사)
    Views/Onboarding.xaml    환영 → 엔진 설치 → 요약 AI → Google Drive → 마무리
    Views/Settings.xaml      회의록·일반·AI·Google Drive·점검
    Views/NoteViewer.xaml    WebView2, 요약↔대본 전환, 복사
  installer/install.ps1      한 줄 설치
```

Windows 고유 주의점:
- **Claude Code CLI**: Windows 네이티브 설치(`irm https://claude.ai/install.ps1 | iex`)와 `claude -p` 비대화형 호출·구독 인증이 되는지 **1단계에서 확인**. 안 되면 Windows 기본값은 **API 키**로
- **클립보드 HTML**: Windows는 `CF_HTML` 형식(바이트 오프셋 헤더)이 필요 — 직접 구현
- **경로**: 한글 사용자명, 공백, 260자 제한 → 모든 경로 따옴표·긴 경로 대비
- **Defender/SmartScreen**: 미서명 exe가 Python·rclone을 내려받는 동작이 오탐될 수 있어 실기기에서 확인

## 5. 개발 환경

현재 상태(2026-09-30 확인):
- 이 Mac: .NET SDK 없음, 가상머신 없음
- NucBoxG3: Tailscale **오프라인 47일**
- GitHub 저장소 공개 → **Windows 러너 무료**

| 역할 | 환경 | 용도 |
|---|---|---|
| **① 주 개발** | Mac + .NET SDK + VS Code C# Dev Kit (코드 작성) | WinUI 3는 Mac에서 빌드 불가 → 빌드는 ②·③. (WPF를 고르면 `EnableWindowsTargeting`으로 Mac에서 컴파일 확인 가능) |
| **② 자동 빌드·검증 (핵심)** | GitHub Actions `windows-latest` | 엔진 pytest, 작은 모델로 받아쓰기 스모크, 앱 빌드, Velopack 패키징, 실행 스크린샷을 아티팩트로 저장, 태그 시 릴리스 |
| **③ 실기기 검증** | NucBoxG3 (전원·Tailscale·DureClaw builder 복구) | **DJI USB 실제 연결 테스트**, 저사양 성능 실측, SmartScreen·Defender 확인, 화면 캡처는 `CopyFromScreen` → Taildrop |
| ④ (선택) 로컬 VM | Parallels / UTM + Windows 11 ARM | 화면 확인 대화형 반복. ARM에서는 x64 에뮬레이션이라 성능 측정용은 아님 |

CI 워크플로(계획):
- `engine.yml` — macOS·Windows에서 pytest + `dji2note doctor` + tiny 모델 받아쓰기 스모크
- `windows-app.yml` — .NET 빌드 → 앱 실행 → 스크린샷 → Velopack `DJI2NoteSetup.exe` 아티팩트
- `release.yml` — `v*` 태그: Mac DMG/zip + Windows Setup.exe를 한 릴리스에

## 6. 단계와 일정 (추정)

| 단계 | 내용 | 완료 기준 | 기간 |
|---|---|---|---|
| **0. 환경** | .NET SDK 설치, CI 골격, NucBoxG3 복구 | CI에서 Windows 러너가 빈 WinUI 3 앱을 빌드, NucBoxG3 presence 온라인 | 0.5일 |
| **1. 엔진 크로스플랫폼** | 3장 전체 + pytest + 성능 실측 | Windows CI에서 `dji2note process 샘플.wav` 성공, Mac 회귀 없음, 기기별 속도표 | 2일 |
| **2. Windows 앱 MVP** | 트레이·마법사·설정·보기/복사·DJI 감지 | 새 Windows 계정에서 설치 → 마법사 → 파일 처리 → Drive 업로드까지 | 3~4일 |
| **3. 배포** | Velopack, install.ps1, 자동 업데이트, README | 릴리스의 Setup.exe와 한 줄 설치가 새 PC에서 동작 | 1~2일 |
| **4. 실기기 검증** | NucBoxG3 + DJI USB, 한글 사용자명, 표준 사용자 계정 | DJI를 꽂으면 자동 처리되고 알림이 뜸 | 1일 |

**합계 약 8~10일.** 서명(Azure Trusted Signing)과 winget 등록은 이후 단계.

## 7. 위험과 대응

| 위험 | 영향 | 대응 |
|---|---|---|
| CPU 전용 PC에서 받아쓰기가 느림 | 사용성 | 실측 후 모델 자동 추천, GPU 자동 사용, 처리 중 진행률·예상 시간 표시 |
| Windows에서 `claude -p` 구독 인증 불가 | 요약 불가 | API 키를 Windows 기본값으로, 설정 마법사에서 안내 |
| 미서명 → SmartScreen·Defender 경고 | 설치 이탈 | install.ps1 한 줄 설치를 기본 안내, 2차에 Azure Trusted Signing |
| DJI 볼륨 이름·폴더 구조 차이(Mic 2 / Mini / RX 수신기) | 감지 실패 | 파일명 패턴 기준으로 감지(볼륨 이름 무시), 실기기 여러 모델로 확인 |
| 두 앱이 엔진 출력에 의존 | 한쪽 수정이 다른 쪽을 깨뜨림 | CLI 계약 문서 + 계약 테스트(pytest가 `--json` 형식 검증) |

## 8. 바로 정할 것
1. GUI: **WinUI 3** (권장) / WPF — [비교 문서](windows-ui-comparison.md)
2. NucBoxG3를 다시 켜서 실기기 검증용으로 쓸 수 있는지, 또는 다른 Windows PC가 있는지
3. 서명 비용(Azure Trusted Signing 월 약 $10)을 1차부터 쓸지, 미서명으로 시작할지
4. Windows 요약 AI 기본값: Claude Code(구독) 우선 / API 키 우선
