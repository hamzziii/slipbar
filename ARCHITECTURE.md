# SlipBar 구조와 흐름

SlipBar가 어떤 부품으로 이루어져 있고, 무슨 일이 어떤 순서로 일어나는지 그림으로 정리한 문서입니다.
코드는 [`Sources/main.swift`](Sources/main.swift) 한 파일이며, 아래 이름들은 모두 그 파일의 실제 타입·함수 이름입니다.

- [1. 한눈에 보기: 구성도](#1-한눈에-보기-구성도)
- [2. 메뉴바에서 일어나는 일](#2-메뉴바에서-일어나는-일)
- [3. 상태](#3-상태)
- [4. 시간 흐름](#4-시간-흐름)
- [5. 배포 흐름](#5-배포-흐름)
- [6. 코드 지도](#6-코드-지도)

## 1. 한눈에 보기: 구성도

SlipBar는 권한 없이 동작하는 작은 백그라운드 앱입니다. 모든 입력은 `AppDelegate`로 모이고, `AppDelegate`는 메뉴바에 둔 두 개의 `NSStatusItem`(버튼과 투명 칸)만 바꿉니다. 다른 앱의 아이콘을 직접 건드리지 않습니다.

```mermaid
flowchart TB
    User(["사용자"])

    subgraph Input["입력 (권한 불필요)"]
        direction LR
        Click["› / ‹ 버튼<br/>클릭 · 우클릭"]
        Swipe["두 손가락 스와이프<br/>scroll 이벤트 모니터"]
        Key["⌥⌘\ 단축키<br/>HotKey (Carbon)"]
        Prefs["설정 창<br/>PreferencesController"]
        Timer["자동 숨김 타이머"]
    end

    App{{"AppDelegate<br/>상태 하나: isCollapsed<br/>setCollapsed(_:)"}}

    subgraph Output["SlipBar가 바꾸는 것"]
        direction LR
        Spacer["투명 칸 spacerItem<br/>length: 0 ↔ hideLength"]
        Glyph["버튼 모양<br/>› ↔ ‹ 회전"]
        Onb["첫 실행 안내<br/>OnboardingController"]
        Store[("UserDefaults<br/>설정값")]
        Login["로그인 항목<br/>SMAppService"]
    end

    subgraph Mac["macOS 메뉴바"]
        direction LR
        Bar["MenuBarAgent가<br/>아이콘 배치"]
        Others["다른 앱의 아이콘<br/>밀려나서 숨음"]
        Bar --> Others
    end

    User --> Click & Swipe & Key & Prefs
    Click & Swipe & Key & Prefs & Timer --> App
    App --> Spacer & Glyph & Onb & Store & Login
    Spacer -- "폭이 바뀌면" --> Bar
```

## 2. 메뉴바에서 일어나는 일

다른 앱의 아이콘을 숨기는 공개 API는 없습니다. 그래서 SlipBar는 버튼 바로 왼쪽에 **투명 칸(spacer)** 을 두고, 숨길 때 그 폭을 넓혀 왼쪽 아이콘들을 밀어냅니다.

**보일 때:** 투명 칸의 폭은 0입니다.

```mermaid
flowchart LR
    M["앱 메뉴<br/>File Edit View…"] ~~~ A["숨길 아이콘들"] ~~~ S["투명 칸<br/>폭 0"] ~~~ T["› 버튼"] ~~~ C["시스템 아이콘<br/>Wi‑Fi · 배터리 · 시계"]
    style S stroke-dasharray: 4 4
```

**숨길 때:** 투명 칸이 넓어지면, 공간이 모자란 왼쪽 아이콘들을 macOS가 메뉴바에서 빼냅니다. 빠진 아이콘은 앱 메뉴 뒤로 조용히 사라지고, 메뉴바에는 ‹ 버튼만 남습니다.

```mermaid
flowchart LR
    M["앱 메뉴<br/>File Edit View…"] ~~~ S["투명 칸<br/>폭 hideLength"] ~~~ T["‹ 버튼"] ~~~ C["시스템 아이콘<br/>Wi‑Fi · 배터리 · 시계"]
    A["숨긴 아이콘들"] -. "앱 메뉴 뒤로" .-> M
    style S stroke-dasharray: 4 4
```

숨길 아이콘은 사용자가 직접 ⌘-드래그로 **› 왼쪽**에 둡니다. 어떤 아이콘을 숨길지는 순서로만 정해지고, SlipBar가 따로 기억하지 않습니다.

## 3. 상태

SlipBar의 핵심 상태는 `isCollapsed` 하나입니다. 어떤 입력이든 결국 `setCollapsed(_:)`를 부릅니다.

```mermaid
stateDiagram-v2
    direction LR
    [*] --> 보임: 실행
    보임 --> 숨김: 숨기기
    숨김 --> 보임: 보이기
    보임 --> 아이콘꺼짐: 메뉴바 아이콘 끔
    숨김 --> 아이콘꺼짐: 메뉴바 아이콘 끔
    아이콘꺼짐 --> 보임: 다시 켬
```

| 상태 | 투명 칸 | 버튼 | 자동 숨김 타이머 |
|------|---------|------|------------------|
| 보임 | 폭 0 | `›` | 켜져 있고 설정 창이 닫혀 있으면 돎 |
| 숨김 | 폭 `hideLength` | `‹` | 멈춤 |
| 아이콘꺼짐 | 메뉴바에서 뺌 | 메뉴바에서 뺌 | 멈춤 (단축키·스와이프도 꺼짐) |

- **숨기기:** 버튼 클릭, `⌥⌘\` 단축키, 메뉴바에서 왼쪽 스와이프, 설정의 Slip Away 스위치, 자동 숨김 타이머
- **보이기:** 버튼 클릭, `⌥⌘\` 단축키, 메뉴바에서 오른쪽 스와이프, 설정의 Slip Away 스위치
- **다시 켬:** 설정 창에서 메뉴바 아이콘을 켭니다. 아이콘이 꺼져 있을 때는 Finder에서 SlipBar를 다시 열면 설정 창이 뜹니다.

## 4. 시간 흐름

### 4-1. 앱 시작

```mermaid
sequenceDiagram
    autonumber
    participant OS as macOS
    participant App as AppDelegate
    participant D as UserDefaults
    participant Bar as 메뉴바
    participant Onb as 첫 실행 안내

    OS->>App: applicationDidFinishLaunching
    App->>D: 기본값 등록 (단축키·스와이프 켬)
    App->>D: 자동 숨김 초 읽기
    App->>Bar: toggleItem 생성 (먼저 만들어서 더 오른쪽)
    App->>Bar: spacerItem 생성 (폭 0, 절대 빼지 않음)
    App->>App: applyCollapsedState() → 보임
    App->>App: 자동 숨김 타이머 · 단축키 · 스와이프 모니터 준비
    alt 처음 실행 (onboardingShown 없음)
        Note over App,Onb: 0.8초 기다린 뒤 (버튼 위치가 자리 잡도록)
        App->>Onb: 버튼 아래에 팝오버 표시
        App->>D: onboardingShown = true
    end
```

### 4-2. 숨기기

클릭, 단축키, 스와이프, 설정 스위치, 자동 숨김 타이머가 모두 같은 길을 탑니다.

```mermaid
sequenceDiagram
    autonumber
    actor U as 사용자
    participant In as 입력<br/>(버튼·단축키·스와이프)
    participant App as AppDelegate
    participant S as 투명 칸
    participant T as › 버튼
    participant Bar as macOS 메뉴바
    participant O as 다른 앱 아이콘

    U->>In: 클릭 / ⌥⌘\ / 왼쪽 스와이프
    alt 우클릭 또는 Control-클릭
        In->>App: handleToggleClick
        App-->>U: 메뉴 (Slip Away · 설정 · 사용법 · 종료)
    else 그 외
        In->>App: setCollapsed(true)
        App->>S: length = hideLength
        S->>Bar: 폭이 넓어짐
        Bar->>O: 공간 밖으로 밀어냄 (보이지 않음)
        par 동시에
            App->>T: › → ‹ 회전 (0.28초, 아이콘이 밀리는 시간과 같음)
        and
            App->>App: 자동 숨김 타이머 취소
            App->>App: 설정 창 표시 갱신
        end
    end
```

### 4-3. 보이기와 자동 숨김

```mermaid
sequenceDiagram
    autonumber
    actor U as 사용자
    participant App as AppDelegate
    participant S as 투명 칸
    participant Bar as macOS 메뉴바
    participant Tm as 자동 숨김 타이머

    U->>App: 클릭 / ⌥⌘\ / 오른쪽 스와이프
    App->>S: length = 0
    S->>Bar: 폭이 0으로
    Bar-->>U: 아이콘이 제자리로 돌아옴
    App->>App: ‹ → › 회전
    opt 자동 숨김 5초·10초·30초·1분, 설정 창은 닫힘
        App->>Tm: 타이머 시작
        Note over Tm: 설정한 시간이 지나면
        Tm->>App: setCollapsed(true)
        App->>S: length = hideLength (4-2와 같음)
    end
```

### 4-4. 스와이프 판정

트랙패드 스크롤 이벤트 중 "메뉴바 위에서 옆으로 쓸기"만 골라냅니다. 권한이 필요 없는 이벤트 모니터를 씁니다.

```mermaid
flowchart TD
    E["스크롤 이벤트"] --> P{"트랙패드 정밀 스크롤이고<br/>관성 스크롤이 아닌가?"}
    P -- 아니오 --> X["무시"]
    P -- 예 --> B{"손가락을 새로 댔나?"}
    B -- 예 --> R["누적 거리 0으로"] --> H
    B -- 아니오 --> H{"가로 이동이 세로보다 크고<br/>포인터가 메뉴바 위인가?"}
    H -- 아니오 --> X
    H -- 예 --> A["손가락 방향 기준으로 누적<br/>(자연스러운 스크롤 설정과 무관)"]
    A --> D{"36pt 넘었나?"}
    D -- 아니오 --> X
    D -- 예 --> Dir{"방향"}
    Dir -- 왼쪽 --> C["setCollapsed(true)<br/>+ 햅틱"]
    Dir -- 오른쪽 --> O["setCollapsed(false)<br/>+ 햅틱"]
```

### 4-5. 디스플레이가 바뀔 때

모니터를 연결하거나 해상도를 바꾸면 버튼이 있는 화면의 폭이 달라질 수 있으므로, 숨긴 상태라면 길이를 다시 계산합니다.

```mermaid
sequenceDiagram
    participant OS as macOS
    participant App as AppDelegate
    participant S as 투명 칸
    OS->>App: didChangeScreenParameters
    Note over App: 0.5초 기다림 (메뉴바 재배치가 끝나도록)
    alt 숨김 상태
        App->>S: length = hideLength (새 화면 기준)
    end
```

## 5. 배포 흐름

만드는 사람과 쓰는 사람 사이의 흐름입니다. 서버 없이 GitHub만 씁니다.

```mermaid
sequenceDiagram
    autonumber
    actor Dev as 개발자
    participant Repo as GitHub 저장소<br/>(dev 브랜치)
    participant Rel as GitHub Releases
    participant Pages as GitHub Pages<br/>(docs/ 폴더)
    actor User as 사용자

    Dev->>Dev: make dist<br/>유니버설 빌드 · ad-hoc 서명 · zip
    Dev->>Repo: 커밋 · 태그 푸시
    Dev->>Rel: gh release create<br/>SlipBar-x.y.z.zip 첨부
    Repo->>Pages: docs/ 자동 게시
    User->>Pages: 사이트 방문
    Pages->>Rel: 다운로드 버튼 → 최신 릴리스
    Rel-->>User: zip
    User->>User: 압축 풀기 → /Applications
    User->>User: 첫 실행: "그래도 열기" (공증 전이라 한 번)
    User->>User: 첫 실행 안내 → ⌘-드래그로 배치 → 사용
```

## 6. 코드 지도

`Sources/main.swift`의 구역(`// MARK:`)과 역할입니다.

| 구역 | 타입 · 함수 | 역할 |
|------|-------------|------|
| 진입점 | `enum Slip` · `main()` | Dock 없는 백그라운드 앱(`.accessory`)으로 실행 |
| App | `AppDelegate` | 상태(`isCollapsed`)와 모든 동작의 중심 |
| Menu bar | `installMenuBar()` · `applyCollapsedState()` · `hideLength` | 버튼·투명 칸 생성, 숨김 길이 계산과 적용 |
| Hot key & swipe | `updateHotKey()` · `updateSwipeMonitor()` · `handleScroll(_:)` | 단축키, 스와이프 판정 |
| Actions | `setCollapsed(_:)` · `handleToggleClick(_:)` · `presentMenu` | 숨김/보임, 클릭과 우클릭 메뉴 |
| Auto-collapse | `scheduleAutoCollapseIfNeeded()` | 자동 숨김 타이머 |
| Preferences | `PreferencesController` | 설정 창, `sync(from:)`로 상태 반영 |
| Onboarding | `OnboardingController` · `DemoBarView` | 첫 실행 팝오버와 움직이는 미니 메뉴바 |
| Hot key | `HotKey` | Carbon `RegisterEventHotKey` 래퍼 (권한 불필요) |
| Icons | `Icons.glyph(progress:)` | 흐린 막대와 꺾쇠를 그리고, 꺾쇠만 돌려 › ↔ ‹ 애니메이션 |

macOS 27에서 이 방식이 부딪친 문제와 대응은 [README의 "macOS 27에서 알아둘 점"](README.md#macos-27에서-알아둘-점)에 있습니다.
