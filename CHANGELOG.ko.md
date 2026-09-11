# 변경 이력

*English: [CHANGELOG.md](CHANGELOG.md)*

플러그인과 MuLiN Creator 는 배포 경로가 다르다 — Creator 는 제품 릴리스로 오고 이 플러그인은
이 저장소에서 받는다. 그래서 한쪽을 올려도 다른 쪽은 그대로다. 아래 항목마다 필요한 Creator
를 적어 둔다.

지금 쓰고 있는 짝을 확인하려면 `mulin-creator:check-mcp` 스킬을 부른다. 첫 줄이 이 플러그인의
버전이고, 2 번 항목이 붙을 수 있는 Creator 창마다의 버전이다. Creator 가 항목이 요구하는
것보다 낡았으면 두 갈래다 — Creator 를 올리거나, 그 Creator 에 맞는 플러그인 버전을 받는다
(`git checkout v0.1.0`).

## 0.1.0 — 2026-09-11

**필요한 Creator — `instance` 필드를 내는 1.0.2 빌드.** 버전 번호만으로는 가릴 수 없다.
이 필드가 들어가기 전의 1.0.2 빌드에는 없다.

### 새 기능

- 첫 배포. AI 클라이언트가 프로젝트를 열어 POU·래더 네트워크·변수·태스크를 다루고,
  빌드해서 장치에 내린다.
- Claude Code 와 Codex 가 모두 이 저장소에서 설치한다. 마켓플레이스를 등록하고 플러그인을
  받으면 도구와 스킬 둘이 함께 온다.
- 브리지는 Creator 창이 뜰 때까지 최대 30 분 기다렸다가 처음 찾은 창에 붙는다. 무엇을 먼저
  켜든 상관없다. 세션 도중 Creator 를 다시 켜도 할 일이 없다 — 다음 도구 호출이 스스로
  다시 붙는다.
- `list_creator_instances` 와 `use_creator_instance` 로 브리지가 감지하는 Creator 창을 모두
  보고, 다시 시작하지 않고 대화 상대를 바꾼다. 다이얼로그에 막혀 있는 창도 포함이다.
- 모든 도구 응답이 어느 Creator 인스턴스(포트, pid)가 답했는지 싣는다. 대화하던 창이 닫히고
  다른 창이 대신 답하기 시작하면, 엉뚱한 창에 쓰는 대신 `creator.instance_changed` 로
  실패한다.
- `mulin-creator:check-mcp` 는 플러그인 버전과 Creator 버전을 나란히 알려 준다. 둘이 맞는
  짝인지 한눈에 본다.
- `mulin-creator:engineering` 은 조작 순서를 담는다 — 래더가 실제로 무엇인지, 다이얼로그가
  호출을 막을 때 무엇을 하는지, 이 도구 묶음이 어디서 막히는지.
