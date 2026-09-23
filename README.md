# Slip

가벼운 macOS 메뉴바 아이콘 숨김 도구. 숨기기 / 보이기만 합니다.  
**웹사이트: <https://hamzziii.github.io/slipbar/>**  
[Hidden Bar](https://github.com/dwarvesf/hidden)와 같은 **spacer 확장** 방식.

- macOS 26 이상 (macOS 27에서 테스트)
- Apple Silicon / Intel 유니버설
- 단일 Swift 파일, 외부 의존성 없음, 권한 요청 없음

## 설치

1. [Releases](../../releases)에서 `Slip-x.y.z.zip`을 받아 압축을 풀고 `Slip.app`을 `/Applications`로 옮깁니다.
2. 처음 열 때 "확인되지 않은 개발자" 경고가 뜨면:  
   **시스템 설정 → 개인정보 보호 및 보안 → "그래도 열기"** (한 번만)

> 공증(notarization)되지 않은 ad-hoc 서명 빌드라서 뜨는 경고입니다.

## 사용법

1. 숨길 아이콘을 **●›** 왼쪽으로 ⌘-드래그
2. **●›** 클릭 → 숨김 (**‹●** 로 바뀜)
3. **‹●** 클릭 → 다시 보임
4. 우클릭(또는 Control-클릭) → Slip Away/Back · Preferences… · Quit

메뉴바 아이콘을 꺼 둔 상태라면 Finder에서 Slip을 다시 열면 설정 창이 뜹니다.

### 설정

| 항목 | 설명 |
|------|------|
| 메뉴바 아이콘 | ●› 표시 여부 |
| Slip Away | 지금 숨김 / 보임 |
| 로그인 시 실행 | 로그인 항목 등록 |
| 자동 숨김 | 펼친 뒤 5초·10초·30초·1분 후 자동으로 숨김, 또는 끔 |

## 빌드

Xcode 필요 (`/Applications/Xcode.app`의 `swiftc`와 SDK 사용).

```bash
make run
```

| 명령 | 설명 |
|------|------|
| `make` | `build/Slip.app` 생성 (유니버설, ad-hoc 서명) |
| `make run` | 빌드 후 실행 |
| `make dist` | `build/Slip-<버전>.zip` 생성 (Releases 업로드용) |
| `make kill` | 종료 |
| `make clean` | 빌드 삭제 |

버전은 `Info.plist`의 `CFBundleShortVersionString`.

## 동작 원리

다른 앱의 메뉴바 아이콘을 숨기는 **공개 API는 없습니다.**  
Slip은 ●› 바로 왼쪽에 자기 `NSStatusItem`(spacer)을 하나 두고, 숨길 때 그 `length`를 키워 왼쪽 아이콘들을 화면 밖으로 **밀어냅니다.** 비공개 API·SIP 해제·화면 녹화 권한 모두 쓰지 않습니다.

### macOS 27에서 알아둘 점

새 "아이콘 숨김 API"가 생긴 건 아니고, 메뉴바 레이아웃이 MenuBarAgent 쪽으로 옮겨지면서 예전 가정이 몇 개 깨졌습니다.

| 현상 | Slip의 대응 |
|------|-------------|
| spacer가 화면 너비의 **약 50% 이상**이면 밀어내지 않고 spacer 자체가 버려짐 | 숨김 폭을 가장 좁은 디스플레이의 **45%**로 제한 (예전 구현들의 "10000pt로 밀기"는 안 통함) |
| status item을 `isVisible = false` → `true` 하면 **맨 왼쪽에 다시 삽입**되어 더 이상 밀지 못함 | spacer를 절대 빼지 않고 `length`만 `0` ↔ 45% 로 바꿈 |
| `length = 0`이어도 패딩 때문에 약 8pt 공간이 남음 | 위 이유로 감수 (●› 왼쪽의 작은 틈) |
| NSWindow / CGWindowList 좌표는 status item 실제 위치와 다름 | 디버깅은 Accessibility의 `AXExtrasMenuBar`로 확인 |

## 한계

- Control Center 아이콘(Wi‑Fi, 배터리 등)은 ⌘-드래그로 경계를 넘기기 어려운 경우가 있습니다.
- 새로 실행한 앱의 아이콘이 맨 왼쪽(숨김 구역)에 나타날 수 있습니다.
- 화면이 아주 넓거나 앞에 있는 앱의 메뉴가 짧으면 45% 폭으로 다 밀리지 않을 수 있습니다.
- 노치가 있고 메뉴바가 꽉 찬 경우, macOS가 Slip 아이콘 자체를 노치 뒤로 보낼 수 있습니다. 이때는 다른 아이콘을 줄이거나 Finder에서 Slip을 다시 열어 설정을 쓰세요.

## 배포 메모

- 다운로드 호스팅은 **GitHub Releases**(무료)로 충분하고, 소개 페이지가 필요하면 **GitHub Pages**(무료).
- 경고 없이 바로 열리게 하려면 Developer ID 서명 + 공증이 필요하고, 이것만 Apple Developer Program(연 $99) 비용이 듭니다.

## 크레딧

spacer 확장 아이디어는 [Hidden Bar](https://github.com/dwarvesf/hidden) (MIT)에서 왔습니다. 코드는 새로 작성했습니다.

## 라이선스

MIT — [LICENSE](LICENSE)
