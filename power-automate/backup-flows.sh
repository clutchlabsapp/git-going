#!/usr/bin/env bash
set -euo pipefail

PA_ENVIRONMENTS="${PA_ENVIRONMENTS:-Default-$PA_TENANT_ID}"
API="https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple/scopes/admin/environments"

# App-only token for the Flow API
# Run curl; on an HTTP error, print the URL and Microsoft's error message to the log
call() {
  local out status body
  out=$(curl -sS -w '\n%{http_code}' "$@")
  status=${out##*$'\n'}
  body=${out%$'\n'*}
  if [ "$status" -ge 400 ]; then
    echo "HTTP $status from: ${*: -1}" >&2
    echo "$body" >&2
    return 1
  fi
  printf '%s' "$body"
}

# App-only token for the Flow API
TOKEN=$(call -X POST \
  -d grant_type=client_credentials \
  -d client_id="$PA_APPLICATION_ID" \
  --data-urlencode client_secret="$PA_CLIENT_SECRET" \
  -d scope="https://service.flow.microsoft.com//.default" \
  "https://login.microsoftonline.com/$PA_TENANT_ID/oauth2/v2.0/token" | jq -r .access_token)

get() {
  call -H "Authorization: Bearer $TOKEN" -H "Accept: application/json" "$1"
}

rm -rf flows   # full mirror each run; deleted flows show up as deletions in git

for env in $PA_ENVIRONMENTS; do
  dir="flows/$env"
  mkdir -p "$dir"

  # List all flow IDs in the environment (follows paging)
  ids=()
  url="$API/$env/v2/flows?api-version=2016-11-01"
  while [ -n "$url" ]; do
    page=$(get "$url")
    mapfile -t -O "${#ids[@]}" ids < <(jq -r '.value[].name' <<<"$page")
    url=$(jq -r '.nextLink // empty' <<<"$page")
  done

  # Fetch each flow with its definition
  for id in "${ids[@]}"; do
    flow=$(get "$API/$env/flows/$id?api-version=2016-11-01&includeFlowDefinition=true&\$expand=properties.connectionreferences.apidefinition")
    label=$(jq -r '(.properties.displayName // .name) | gsub("[^A-Za-z0-9_-]"; "_")' <<<"$flow")

    if ! jq -e '{displayName: .properties.displayName,
                 connectionReferences: .properties.connectionReferences,
                 definition: .properties.definition}
                | select(.definition != null)' <<<"$flow" > "$dir/${label}__${id}.json"; then
      echo "No definition returned for $label ($id). Fields that came back:" >&2
      jq -r '.properties | keys | join(", ")' <<<"$flow" >&2
      exit 1
    fi
  done
done
