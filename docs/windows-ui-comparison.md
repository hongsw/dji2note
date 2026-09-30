# Windows GUI 기술 선택 — WinUI 3 vs WPF

> 작성: 2026-09-30 · 관련: [windows-plan.md](windows-plan.md)
> 기준 정보는 2026년 중반까지. 착수 전 Windows App SDK·.NET 최신 버전과 로드맵을 다시 확인할 것.

## 1. 후보 전체 순위
기준: ① Windows 기능을 모두 쓸 수 있는가 ② 보편적인가 ③ 미래지향적인가

| 순위 | 방법 | 기능 | 보편성 | 미래 | 한 줄 평 |
|---|---|---|---|---|---|
| 1 | **C# + WinUI 3 (Windows App SDK)** | ◎ | ○ | ◎ | Microsoft 공식 권장 네이티브 UI. 새 기능이 가장 먼저 옴 |
| 2 | **C# + WPF (.NET 10) + Windows App SDK** | ○~◎ | ◎ | ○ | 가장 성숙·안전. SDK 연동으로 API 대부분 사용 가능 |
| 3 | Tauri 2 (Rust + WebView2) + windows-rs | ◎ | ○ | ◎ | Mac·Windows를 UI 코드 하나로. 네이티브 느낌은 약함 |
| 4 | React Native for Windows | ○ | ○ | ○ | 네이티브로 렌더링. Windows 고유 기능은 네이티브 모듈 필요 |
| 5 | .NET MAUI | △ | ○ | △ | 크로스플랫폼 추상화로 Windows 고유 기능이 불편 |
| 6 | C++/WinRT · Win32 C++ | ◎ | △ | △ | 할 수 있는 일은 최대, 생산성·인력이 낮음 |
| 7 | Electron | △ | ◎ | △ | 가장 보편적이지만 무겁고 네이티브와 거리 멂 |

## 2. 1위·2위 집중 비교

**핵심: Windows API 접근 폭은 사실상 같다.** WPF도 Windows App SDK를 참조하면 알림·앱 ID·Windows AI API까지 부를 수 있다.
실제 차이는 **UI 네이티브감 · 개발 마찰 · 미래 방향**이다.

| 항목 | WinUI 3 | WPF (.NET 10) + WinAppSDK | 우세 |
|---|---|---|---|
| Windows API 접근 | WinRT·Win32 바로 호출 | SDK 참조로 거의 전부 호출 | ≈ |
| 최신 UI·디자인 | Windows 11 Fluent 기본(Mica, 둥근 모서리, 최신 컨트롤) | .NET 9+ Fluent 테마 / WPF-UI로 "비슷하게" | **WinUI** |
| 새 기능 도착 순서 | 주력 무대, 먼저 | 나중에 또는 연동으로 | **WinUI** |
| Microsoft 로드맵 | 공식 권장, OS 기본 앱이 이전 중 | 유지·개선되지만 주력 아님 | **WinUI** |
| 안정성·완성도 | 버그·공백 있음(기본 DataGrid 없음, 창 관리는 AppWindow) | 거의 모든 문제의 해법 존재 | **WPF** |
| 자료·라이브러리·인력 | 적음 | 가장 많음 | **WPF** |
| AI 코드 생성 정확도 | UWP 시절 API와 섞이기 쉬움 | 학습 데이터 많아 정확 | **WPF** |
| 빌드 환경 | **Windows에서만**, XAML 디자이너 없음(Hot Reload) | **Mac에서도 컴파일 가능**(`EnableWindowsTargeting`), VS 디자이너 | **WPF** |
| 배포 | WinAppSDK 런타임 동봉/설치 필요 | single-file exe 간편 | **WPF** |
| 트레이 아이콘 | H.NotifyIcon 필요 | H.NotifyIcon 필요(더 오래 검증됨) | 약간 WPF |
| WebView2 | 내장 | NuGet | ≈ |
| 지원 OS | Windows 10 1809+ | Windows 10+ | ≈ |
| 이행 경로 | — | XAML Islands로 WinUI 화면을 점진 도입 가능 | WPF에 퇴로 |

한 문장 요약
- **WinUI 3** — "Windows 11다운 앱 + 앞으로의 표준". 덜 다듬어진 부분을 직접 우회해야 함.
- **WPF** — "가장 안전하고 빠른 개발". 모양은 Windows 11을 흉내 내는 수준, 새 기능은 한 박자 늦음.

## 3. DJI2Note에 대입
필요 기능(트레이·알림·자동 시작·USB 감지·WebView2 보기 창·설정 마법사)은 **둘 다 동일하게 구현 가능** → 결정은 우선순위 문제.

| 우선순위 | 선택 |
|---|---|
| Windows 11 네이티브감, 장기 표준, Windows ML/NPU 등 새 기능과의 궁합 | **WinUI 3** |
| 빠르고 안정적인 출시, Mac에서 컴파일 확인, AI 코드 정확도 | **WPF** |

**권장: WinUI 3.**
- 기준이 "모든 기능 + 미래지향"이다.
- 이 앱은 화면이 작아서 WinUI의 약점(DataGrid·복잡한 창 관리)을 거의 쓰지 않는다.
- 나중에 Windows ML로 받아쓰기를 NPU·GPU에서 돌리면, 가장 큰 위험(CPU 전용 PC의 속도)을 줄일 길이 생긴다.
- Windows 전용 빌드는 GitHub Actions `windows-latest`와 NucBoxG3로 메운다.

**예외:** NucBoxG3 등 실기기 확보가 어렵고 빠른 1차 출시가 더 중요하면 WPF.

## 4. 결정 상태
- [ ] WinUI 3 / WPF 확정 (사용자 결정 대기)
