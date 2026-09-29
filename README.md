# dji2note 🎙→📝

**DJI 무선 마이크를 Mac에 꽂기만 하면**, 새 녹음을 받아쓰고 화자를 나눠 회의록 요약을 만든 뒤 Google Drive에 Google Docs로 올려 줍니다.

```
DJI Mic 연결 → 새 녹음 복사 → Whisper 받아쓰기 → 화자 분리(A/B)·오타 교정 → 요약·할 일 정리 → Google Drive
```

- 모든 받아쓰기는 **내 Mac에서** 처리합니다 (mlx-whisper, 인터넷으로 음성을 보내지 않음)
- 30분 단위로 나뉜 긴 녹음은 자동으로 이어 붙여 한 회의로 정리합니다
- 소리가 없는 구간에서 생기는 Whisper 환각 문장은 걸러냅니다
- 처리가 끝나면 Mac 알림으로 알려 줍니다

## 준비물
- **Apple Silicon Mac** (M1 이상)
- DJI Mic / Mic 2 / Mic Mini 송신기(TX) — USB로 연결하면 저장소로 인식되는 모델
- (선택) 화자 분리·요약용 AI: [Claude Code](https://claude.com/claude-code) 로그인 **또는** Anthropic API 키
- (선택) Google 계정 — Drive 업로드용

## 설치 (한 줄)
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

직접 설치하려면: `uv tool install git+https://github.com/hongsw/dji2note && dji2note setup-tools && dji2note init`

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
