# Harness-adapter routing check now fails when a routing target is unreadable

Reproduction: `chmod 000` one file named by the `harness-adapter-routing-v1` block
in .agents/skills/harness-adapters/SKILL.md, then run the check.

## BEFORE (tests/fm-harness-adapter-references.test.sh at ff99587^)
```
  not ok - harness adapter routing target is unreadable: references/harness/claude.md
  ok - harness adapter routing artifact is normalized and every target is readable
  exit=0
```

## AFTER (at 85ea153) - same broken target
```
  not ok - harness adapter routing target is unreadable: references/harness/claude.md
  exit=1
```

## AFTER - target restored
```
  ok - harness adapter routing artifact is normalized and every target is readable
  exit=0
```
