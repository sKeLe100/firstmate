#!/usr/bin/env bash
# Stand-in for the GitHub API boundary: answers /user and the billing usage endpoint.
printf 'gh %s\n' "$*" >> "${GH_CALL_LOG:-/dev/null}"
if [ "$1" = api ] && [ "$2" = /user ]; then echo labuser; exit 0; fi
if [ "$1" = api ] && [ "${2%%\?*}" = ~/settings/billing/usage ]; then
  q=${2#*\?}; y=$(sed 's/.*year=\([0-9]*\).*/\1/' <<<"$q"); m=$(sed 's/.*month=\([0-9]*\).*/\1/' <<<"$q"); d=$(sed 's/.*[&]day=\([0-9]*\).*/\1/' <<<"$q")
  day=$(printf '%04d-%02d-%02d' "$y" "$m" "$d")
  mb=${FAKE_MB:-450}; unit=${FAKE_UNIT:-gigabyte-hours}
  if [ "${FAKE_IGNORE_DAY:-0}" = 1 ]; then
    # Endpoint ignored the day parameter: year-to-date rows of 150 MB each.
    python3 -c 'import json,datetime
rows=[]
d=datetime.date(2026,1,1)
while d<datetime.date(2026,11,18):
  rows.append({"date":d.isoformat()+"T00:00:00Z","product":"actions","sku":"actions_storage","quantity":150/1024*24,"unitType":"gigabyte-hours"}); d+=datetime.timedelta(1)
print(json.dumps({"usageItems":rows}))'
    exit 0
  fi
  # Two repos split the pool, one packages row, plus a minutes row that must be ignored.
  python3 -c 'import json,sys
day,mb,unit=sys.argv[1],float(sys.argv[2]),sys.argv[3]
gbh=mb/1024*24
print(json.dumps({"usageItems":[
 {"date":day+"T00:00:00Z","product":"actions","sku":"actions_storage","quantity":gbh*0.6,"unitType":unit,"repositoryName":"labuser/a"},
 {"date":day+"T00:00:00Z","product":"actions","sku":"actions_storage","quantity":gbh*0.3,"unitType":unit,"repositoryName":"labuser/b"},
 {"date":day+"T00:00:00Z","product":"packages","sku":"packages_storage","quantity":gbh*0.1,"unitType":unit,"repositoryName":"labuser/a"},
 {"date":day+"T00:00:00Z","product":"actions","sku":"actions_linux","quantity":900,"unitType":"Minutes","repositoryName":"labuser/a"}]}))' "$day" "$mb" "$unit"
  exit 0
fi
exit 1
