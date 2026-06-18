# Bear Source of Truth

SRE301 강의와 공개 정답의 정본은 이 repo가 아니라 Bear note입니다. main의 Markdown은 배포와 실습을 위한 mirror이며, 직접 편집하지 않고 Bear에서 다시 생성합니다. `slides/`와 `answers/`는 main에서 제외하고 필요할 때 명시 옵션으로 생성합니다.

| Source | Bear note ID | Bear title | Generated files |
|---|---|---|---|
| Lecture | `2A434F79-0C81-44DD-A958-A54B18A6889E` | `[복제] [멘토 특강] [유호균] SRE301: Grafana, Prometheus로 배우는 장애 모니터링 및 모의 대응 훈련` | `LECTURE.md` |
| Lecture slides source | `2A434F79-0C81-44DD-A958-A54B18A6889E` | `[복제] [멘토 특강] [유호균] SRE301: Grafana, Prometheus로 배우는 장애 모니터링 및 모의 대응 훈련` | `slides/sre301/_src/lecture-full.md` with `--include-slides` |
| Incident answers | `FFB1B76A-0657-4BB2-94A4-A2A7647BD9BE` | `[정답] SRE301 Incident 1~4` | `answers/incident-drill.md` with `--include-answers` |

## Sync Rule

Primary access path for agents is Bear MCP:

```text
mcp__bear.get_note
mcp__bear.read_note_content
```

CLI verification and local regeneration use:

```sh
/Applications/Bear.app/Contents/MacOS/bearcli
```

Regenerate repo mirrors:

```sh
python3 scripts/sync-bear-sources.py
```

Generate ignored slides source or answers when working on those branches/artifacts:

```sh
python3 scripts/sync-bear-sources.py --include-slides
python3 scripts/sync-bear-sources.py --include-answers
```

Check for stale generated files:

```sh
python3 scripts/sync-bear-sources.py --check
```

Check ignored slides source or answers explicitly:

```sh
python3 scripts/sync-bear-sources.py --check --include-slides
python3 scripts/sync-bear-sources.py --check --include-answers
```

The sync fails explicitly when Bear is unavailable, the note ID or title does not match, content is empty, Bear metadata length does not match the UTF-8 bytes read by `bearcli cat`, or a generated file is stale.

## Editing Policy

- Edit the Bear notes first.
- Run `python3 scripts/sync-bear-sources.py`.
- Do not edit generated mirrors by hand.
- `slides/` and `answers/` are ignored on main. Commit answers later on the answer branch.
- Do not overwrite Bear from repo content unless that destructive direction is explicitly requested.
