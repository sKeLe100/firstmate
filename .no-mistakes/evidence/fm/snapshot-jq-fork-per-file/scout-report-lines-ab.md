# Evidence: scout_report_lines batched jq — byte-identical output, ~16x faster

Base script: 8e7b0f4 (fork-per-file jq loop)  |  New: fa65274 (single jq -Rs)

## A/B on a fixture home with 9 report.md dirs (names include spaces, '+', '.', '[]', and a regex-metachar home path)
$ diff <(base --json) <(new --json)   # only the clock differs
3c3
<   "generated": "2026-08-26T11:59:26Z",
---
>   "generated": "2026-08-26T11:59:27Z",
119c119
<         "observed_at": "2026-08-26T11:59:26Z"
---
>         "observed_at": "2026-08-26T11:59:27Z"

$ cmp <(base --json | jq -S .scout_reports) <(new --json | jq -S .scout_reports)
  -> identical (exit 0, no output)

new --json | jq .scout_reports:
[
  {
    "id": "001-first",
    "kind": "scout",
    "path": "/tmp/tmp.iVOAzCBtKL/regex+meta [home]/data/001-first/report.md"
  },
  {
    "id": "alpha-scout",
    "kind": "scout",
    "path": "/tmp/tmp.iVOAzCBtKL/regex+meta [home]/data/alpha-scout/report.md"
  },
  {
    "id": "beta-scout",
    "kind": "scout",
    "path": "/tmp/tmp.iVOAzCBtKL/regex+meta [home]/data/beta-scout/report.md"
  },
  {
    "id": "brack[et]",
    "kind": "scout",
    "path": "/tmp/tmp.iVOAzCBtKL/regex+meta [home]/data/brack[et]/report.md"
  },
  {
    "id": "dot.name",
    "kind": "scout",
    "path": "/tmp/tmp.iVOAzCBtKL/regex+meta [home]/data/dot.name/report.md"
  },
  {
    "id": "gamma-scout",
    "kind": "scout",
    "path": "/tmp/tmp.iVOAzCBtKL/regex+meta [home]/data/gamma-scout/report.md"
  },
  {
    "id": "plus+name",
    "kind": "scout",
    "path": "/tmp/tmp.iVOAzCBtKL/regex+meta [home]/data/plus+name/report.md"
  },
  {
    "id": "weird name",
    "kind": "scout",
    "path": "/tmp/tmp.iVOAzCBtKL/regex+meta [home]/data/weird name/report.md"
  },
  {
    "id": "zz-last",
    "kind": "scout",
    "path": "/tmp/tmp.iVOAzCBtKL/regex+meta [home]/data/zz-last/report.md"
  }
]

## Empty / missing data dir parity
  no data dir  : base=[]  new=[]
  empty data   : base=[]  new=[]

## Scale: 300 report.md files
$ cmp base.scout_reports new.scout_reports
  -> byte-identical
  base (300 jq forks): 2.53s
  new  (1 jq call)   : 0.15s

## Targeted suite
$ bash tests/fm-fleet-snapshot-view.test.sh  -> 21/21 ok
