#!/usr/bin/env bash
set -euo pipefail

PA_ENVIRONMENTS="${PA_ENVIRONMENTS:-Default-$PA_TENANT_ID}"

m365 login --authType secret --appId "$PA_APPLICATION_ID" --tenant "$PA_TENANT_ID" --secret "$PA_CLIENT_SECRET" --output none

rm -rf flows # full mirror each run; deleted flows show up as deletions in git

for env in $PA_ENVIRONMENTS; do
  dir="flows/$env"
  mkdir -p "$dir"

  m365 flow list --environmentName "$env" --asAdmin --output json |
    jq -r '.[] | "\(.name) \((.properties.displayName // .name) | gsub("[^A-Za-z0-9_-]"; "_"))"' |
  while read -r id label; do
    m365 flow get --environmentName "$env" --name "$id" --asAdmin --output json |
      jq -e '{displayName: .properties.displayName,
              connectionReferences: .properties.connectionReferences,
              definition: .properties.definition}
             | select(.definition != null)' > "$dir/${label}__${id}.json"
  done
done
