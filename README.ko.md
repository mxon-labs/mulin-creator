# MuLiN Creator — AI 클라이언트 붙이기

*English: [README.md](README.md)*

실행 중인 MuLiN Creator 를 AI 도구로 조작할 수 있게 하는 배포물이다. Creator 안에 MCP
(Model Context Protocol) 서버가 들어 있고, 이 폴더는 **거기에 붙는 쪽**을 담는다.

- 이 저장소가 곧 플러그인이다 — 도구 + 연결 진단 스킬 + 엔지니어링 스킬.
  Claude Code 와 Codex 가 모두 여기서 받아 설치한다.
- `scripts/Start-McpBridge.ps1` — 브리지. **클라이언트를 가리지 않는다** —
  그 밖의 MCP 클라이언트도 이 스크립트를 가리킨다.

Windows 전용이다. Creator 가 Windows 전용이기 때문이다.

**받는 곳은 GitHub 다** — `https://github.com/mxon-labs/mulin-creator`. Creator 설치본에는
들어 있지 않다. 따로 올라가므로 새 Creator 를 깔아도 이쪽이 새로워지지 않는다 — 이쪽은
이쪽 걸음으로 갱신된다.

## 먼저 — Creator 가 떠 있어야 한다

붙을 상대가 실행 중인 Creator 창이다. 켜져 있지 않으면 아무것도 붙지 않는다.

Creator 를 띄우면 MCP 서버가 자동으로 켜진다. 포트는 29500 부터 비어 있는 것을 골라
쓰고, 접속 정보는

```
%LOCALAPPDATA%\MXOn Corporation\MuLiN Creator\mcp\<포트>.lock
```

에 남는다. **이 파일을 직접 볼 일은 없다** — 브리지가 읽어 알아서 찾는다. 포트를 손으로
적을 필요도, 토큰을 복사할 필요도 없다.

**Creator 의 설치 경로는 어디에도 적지 않는다.** 브리지는 Creator 를 띄우지 않는다 —
사람이 켠 창을 찾아 붙을 뿐이다. 그래서 설정에 적을 경로는 브리지 스크립트 하나뿐이다.

잠금 디렉터리는 **PC 마다 하나**다(사용자 AppData 아래다). 그래서 Creator 를 여러 개
띄워도 잠금 파일은 한 곳에 모인다 — 붙는 상대를 가르는 것은 **지금 떠 있는 창**이다.
둘 이상 떠 있으면 아래 "Creator 창이 둘 이상일 때" 로 간다.

## Claude Code

마켓플레이스로 등록하고 플러그인을 설치한다. 두 줄이다.

```
/plugin marketplace add mxon-labs/mulin-creator
/plugin install mulin-creator@mxon
```

`mxon-labs/mulin-creator` 는 이 배포물의 GitHub 저장소다. 공개 저장소이므로 계정 없이
등록된다. Claude Code 가 저장소를 직접 받아 오니 **파일을 미리 내려받아 둘 필요는 없다.**

설치하면 얻는 것:

- **도구** — 프로젝트·POU·래더·변수·태스크·빌드·다운로드. 이름은
  `mcp__plugin_mulin-creator_mulin-creator__*` 로 읽힌다.
- **`/mulin-creator:engineering`** — 조작 절차. 래더가 그래프라는 것, 대화상자가 뜨면
  무엇을 하는지 등을 AI 가 알아서 참조한다.

붙었는지는 `/mcp` 로 본다. `mulin-creator` 가 `✔ Connected` 면 된 것이다 — 설치 id
`mulin-creator@mxon` 의 뒤쪽 `mxon` 은 **마켓플레이스**(만든 곳) 이름이고, `/mcp` 에
보이는 `mulin-creator` 는 이 플러그인이 켜는 **서버** 이름이다.

**도구 이름은 붙이는 방식에 따라 다르다.** Claude Code 플러그인으로 깔면
`mcp__plugin_mulin-creator_mulin-creator__*` 이고, 다른 클라이언트는 저마다의 표기를
쓰되 늘 서버 이름 `mulin-creator` 를 달고 나온다.

### 새 버전이 나왔을 때

[CHANGELOG.ko.md](CHANGELOG.ko.md) 에 버전마다 무엇이 달라졌고 어느 Creator 가 필요한지
적혀 있다. 올리기 전에 그 항목을 읽는다 — 둘은 따로 배포되므로 Creator 도 함께 올릴지는
사용자가 판단한다.

설치하면 플러그인이 `~/.claude/plugins/cache/` 로 **복사된다.** 그래서 저장소에 새 버전이
올라와도 자동으로 따라오지 않는다. 두 줄이다 — 마켓플레이스를 다시 받고, 플러그인을 갱신한다.

```
/plugin marketplace update mxon
/plugin update mulin-creator@mxon
```

**첫 줄을 건너뛰면 새 버전이 있다는 것 자체를 모른다** — Claude Code 는 등록할 때 받아 둔
사본을 보기 때문이다.

**버전이 달라져 있어야 갱신된다.** 갱신을 걸었는데 *"already at the latest version"*
이라고 나오면 파일이 바뀌었어도 아무것도 옮겨지지 않은 것이다. 그 경우에는 지우고 다시
깔면 된다.

```
claude plugin uninstall mulin-creator@mxon
claude plugin install mulin-creator@mxon
```

**프로젝트 설정으로 등록해 쓴다면 스코프를 지정해야 한다** — 갱신의 기본 스코프는
`user` 라서, 프로젝트 설정으로 등록된 설치는 따로 걸어야 한다.

```
claude plugin update mulin-creator@mxon --scope project
```

## Codex

Codex 도 같은 저장소에서 받는다. Claude Code 와 같이 두 줄이다.

```
codex plugin marketplace add mxon-labs/mulin-creator
codex plugin add mulin-creator@mxon
```

도구와 스킬이 함께 온다. `codex mcp list` 에 `mulin-creator` 가 enabled 로 보이면 된다.

### 새 버전이 나왔을 때

설치는 플러그인을 `~/.codex/plugins/cache/` 로 **복사**하므로 저장소가 바뀌어도 사본은
따라오지 않는다. 마켓플레이스를 새로 받고 다시 설치한다.

```
codex plugin marketplace upgrade mxon
codex plugin add mulin-creator@mxon
```

그리고 **세션을 새로 연다** — 새 도구와 스킬은 거기서 잡힌다.

Codex 의 HTTP 방식(`url` + `bearer_token_env_var`)은 쓰지 않는다 — URL 이 정적이라
포트가 바뀌면 깨진다. 브리지가 그 문제를 없애는 물건이다.

## 그 외 MCP 클라이언트

저장소를 내려받아 브리지를 stdio 방식으로 띄운다. 내려받은 곳을 `<저장소 경로>` 라 한다.

```
git clone https://github.com/mxon-labs/mulin-creator.git
```

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<저장소 경로>\scripts\Start-McpBridge.ps1"
```

**클라이언트의 플러그인 캐시를 내려받은 곳 대신 쓰지 않는다** — 재설치할 때 갈리는
경로다. 새 버전은 `git pull` 로 받는다.

## Creator 창이 둘 이상일 때

도구 호출마다 그 시점에 Creator 창을 찾는다. 창이 여럿이면 프로젝트로 구별해 그
프로젝트가 열린 창에서 동작한다 — 같은 프로젝트를 다시 여는 재시작이면 조용히 이어진다.
어느 창인지 정할 수 없으면 AI 가 묻고, 답한 창으로 세션을 고정한다.

직접 못 박고 싶으면 세션을 시작하기 전에 그 창의 포트를 환경변수에 넣는다.

```powershell
$env:MULIN_MCP_PORT = 29501
```

포트는 `list_creator_instances`(AI 에게 물어보면 된다)나 잠금 파일 이름으로 알 수 있다.

## 붙어 있던 창이 세션 도중 사라지면

같은 프로젝트를 다시 열면 그대로 이어진다 — 따로 할 일이 없다. 다른 프로젝트가 열린
창만 남았으면 AI 가 어느 창을 쓸지 묻는다.

## 안 될 때

도구가 하나도 안 보이면 브리지 프로세스 자체가 못 뜬 것이다 — 실행 정책과 보안
소프트웨어를 확인하고 `-Doctor`로 본다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<저장소 경로>\scripts\Start-McpBridge.ps1" -Doctor
```

잠금 디렉터리·잠금 파일 목록·각 창이 답하는지·어느 창을 고를지와 그 이유를 낸다.
