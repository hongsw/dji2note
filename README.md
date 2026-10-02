# dji2note 🎙→📝

**DJI 무선 마이크를 Mac에 꽂기만 하면**, 새 녹음을 받아쓰고 화자를 나눠 회의록 요약을 만든 뒤 Google Drive에 Google Docs로 올려 줍니다.

```
DJI Mic 연결 → 새 녹음 복사 → Whisper 받아쓰기 → 화자 분리(A/B)·오타 교정 → 요약·할 일 정리 → Google Drive
```

- 모든 받아쓰기는 **내 Mac에서** 처리합니다 (mlx-whisper, 인터넷으로 음성을 보내지 않음)
- 30분 단위로 나뉜 긴 녹음은 자동으로 이어 붙여 한 회의로 정리합니다
- 소리가 없는 구간에서 생기는 Whisper 환각 문장은 걸러냅니다
- 처리가 끝나면 Mac 알림으로 알려 줍니다

## 이런 상황에 씁니다
| 상황 | 요약 형식 |
|---|---|
| 자동 판별 (기본) | AI가 녹음을 보고 아래 중 하나를 골라 그 형식으로 |
| 대면 회의 · 온라인 회의 | 결정 사항, 할 일(담당·기한) |
| 강의·수업 | 핵심 개념, 용어 정리, 예시·실습, 질의응답, 과제 |
| 인터뷰·면접 | 대상자 정보, Q&A, 평가 포인트, 처우 논의 |
| 상담·고객 미팅 | 요구·문제, 제안, 합의, 할 일 |
| 브레인스토밍 | 아이디어 묶음, 유망안, 리스크, 다음 실험 |
| 발표·세미나 | 핵심 메시지, 인상적인 말, 질의응답 |
| 통화 · 개인 메모 | 요점·약속 / 생각 정리·할 일 |

녹음 경로: **DJI 무선 마이크**(꽂으면 자동) · **앱에서 바로 녹음**(내장·USB·iPhone 마이크, DJI 수신기) · **온라인 회의**(내 마이크 + Mac 소리를 채널로 나눠 '나/상대방') · **Mac 음성 메모**(iPhone 메모 iCloud 동기화 포함)

회의록 목록에는 **주제 · 길이(시간·분·초) · 화자 수 · 상황**이 보이고, 오른쪽 클릭으로 **상황을 바꿔 다시 요약**할 수 있습니다.

## 준비물
- **Apple Silicon Mac** (M1 이상)
- DJI Mic / Mic 2 / Mic Mini 송신기(TX) — USB로 연결하면 저장소로 인식되는 모델
- (선택) 화자 분리·요약용 AI: [Claude Code](https://claude.com/claude-code) 로그인 **또는** Anthropic API 키
- (선택) Google 계정 — Drive 업로드용

## 설치 ① Mac 앱 (권장)
메뉴바에 상주하는 네이티브 앱입니다. 설치·설정을 화면에서 안내하고, DJI를 꽂으면 진행 상황을 보여 줍니다.

**방법 A — 터미널 한 줄** (경고 없이 바로 열림)
```sh
curl -fsSL https://raw.githubusercontent.com/hongsw/dji2note/main/install-app.sh | bash
```

**방법 B — DMG**: [최신 릴리스](https://github.com/hongsw/dji2note/releases/latest)에서 `DJI2Note.dmg`를 받아 앱을 `응용 프로그램`으로 끌어 옵니다.
> 아직 Apple 공증을 받지 않은 앱이라 처음 열 때 "확인할 수 없음" 경고가 뜹니다.
> **시스템 설정 → 개인정보 보호 및 보안 → 맨 아래 "그래도 열기"**를 누르면 됩니다(한 번만).

앱을 열면 설정 마법사가 이어집니다: **엔진 설치 → 요약 AI(Claude 로그인 / API 키) → Google 계정 연결 → 마무리**.
관리자 암호나 Homebrew는 필요 없고, 모든 파일은 `~/Library/Application Support/DJI2Note`에 설치됩니다.

## 설치 ② 터미널(CLI)만
터미널을 열고 붙여 넣으세요.

```sh
curl -fsSL https://raw.githubusercontent.com/hongsw/dji2note/main/install.sh | bash
```

dji2note와 필요한 도구(ffmpeg·rclone)를 설치한 뒤 **설정 마법사**가 이어서 실행됩니다. Homebrew나 관리자 권한은 필요 없습니다.

| 단계 | 묻는 내용 |
|---|---|
| ① | 결과 저장 폴더 (기본 `~/dji2note`) |
| ② | 대화 언어 (기본 `ko`) |
| ③ | 요약에 쓸 AI — Claude Code / API 키 / 사용 안 함 |
| ④ | Google Drive 업로드 — 브라우저에서 Google 로그인 한 번 |
| ⑤ | 받아쓰기 모델 미리 받기 (약 1.6GB) |
| ⑥ | DJI에 이미 있는 녹음도 처리할지 |
| ⑦ | DJI 연결 시 자동 실행 |

> 처음 자동 실행될 때 macOS가 **"이동식 볼륨에 접근"** 권한을 물으면 **허용**을 누르세요.

직접 설치하려면: `uv tool install https://github.com/hongsw/dji2note/archive/refs/heads/main.zip && dji2note setup-tools && dji2note init`

## 사용법
평소에는 **DJI를 꽂기만 하면 됩니다.** 그 밖의 명령:

```sh
dji2note doctor                 # 설치·설정 점검
dji2note run --dry-run          # 연결된 DJI에서 처리할 녹음 미리 보기
dji2note run                    # 지금 바로 처리
dji2note process 회의.m4a        # 아무 오디오 파일이나 처리 (여러 개는 --join 으로 이어 붙이기)
dji2note list                   # 처리 기록
dji2note forget <파일명>         # 다시 처리되게 기록 삭제
dji2note service uninstall      # 자동 실행 끄기
dji2note init                   # 설정 다시 하기
```

## 결과물
`~/dji2note/notes/2026-09-28_1127_MIC025/`

| 파일 | 내용 | Drive |
|---|---|---|
| `summary.md` | 요약 · 주요 내용 · 결정 사항 · 할 일 표 | `요약` (Google Docs) |
| `transcript.md` | 화자 분리(A/B)·교정한 대화 스크립트 | `스크립트(화자분리)` |
| `raw_whisper.txt` | 원본 받아쓰기 + 구간별 음량(dB) | — |

원본 녹음 복사본은 `~/dji2note/recordings/`에 남습니다.

## 화자 분리 방식과 한계
송신기 1개로 녹음하면 **마이크를 단 사람(A)은 크게, 상대방(B)은 작게** 녹음됩니다. 이 음량 차이를 1차 기준으로 쓰고, AI가 대화 흐름(질문-대답, 말투)으로 보정합니다.
- 두 사람이 마이크에서 비슷한 거리에 있으면 정확도가 떨어집니다. 불확실한 줄은 `(?)`로 표시됩니다.
- AI를 쓰지 않으면 음량만으로 나누므로 더 부정확하고 요약은 만들지 않습니다.

## Mac 앱 개발
```sh
cd mac && ./scripts/build.sh      # → mac/build/DJI2Note.app, DJI2Note.dmg, DJI2Note.zip
open build/DJI2Note.app --args -debugStep 2          # 마법사 특정 단계 바로 보기
open build/DJI2Note.app --args -setupDone YES -debugTab ai
```
SwiftUI(macOS 14+) 메뉴바 앱이 Python 엔진(`dji2note` CLI)을 설치·호출합니다. 앱은 `NSWorkspace` 마운트 알림으로 DJI 연결을 감지합니다.

## 설정 파일
`~/.config/dji2note/config.toml` — `dji2note init`으로 바꾸거나 직접 수정합니다.

```toml
output_dir = "/Users/me/dji2note"
language = "ko"                 # auto 가능
llm_backend = "claude-cli"      # claude-cli | anthropic-api | none
llm_model = "claude-sonnet-5"
upload = "rclone"               # rclone | none
rclone_remote = "gdrive"
drive_folder = "dji2note"
notify = true
```

로그: `~/Library/Logs/dji2note.log`

## 개인정보
- 음성은 Mac 안에서만 받아써집니다.
- AI를 켜면 **받아쓴 텍스트**가 Claude(Anthropic)로 전송됩니다.
- Drive 업로드를 켜면 요약·스크립트가 내 Google Drive에 저장됩니다. rclone 인증 정보는 `~/.config/rclone/rclone.conf`에 있습니다.

## 라이선스
MIT
