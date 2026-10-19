#!/usr/bin/env bash
set -euo pipefail

PA_ENVIRONMENTS="${PA_ENVIRONMENTS:-Default-$PA_TENANT_ID}"
FLOW="https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple"

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

# token <scope>  -> app-only access token
token() {
  call -X POST \
    -d grant_type=client_credentials \
    -d client_id="$PA_APPLICATION_ID" \
    --data-urlencode client_secret="$PA_CLIENT_SECRET" \
    -d scope="$1" \
    "https://login.microsoftonline.com/$PA_TENANT_ID/oauth2/v2.0/token" | jq -r .access_token
}

# get <token> <url>
get() {
  call -H "Authorization: Bearer $1" -H "Accept: application/json" "$2"
}

FLOW_TOKEN=$(token "https://service.flow.microsoft.com//.default")

rm -rf flows   # full mirror each run; deleted flows show up as deletions in git

for env in $PA_ENVIRONMENTS; do
  dir="flows/$env"
  mkdir -p "$dir"

  # Find this environment's Dataverse address (if it has one) and get a token for it
  envinfo=$(get "$FLOW_TOKEN" "$FLOW/environments/$env?api-version=2016-11-01")
  dv_api=$(jq -r '.properties.linkedEnvironmentMetadata.instanceApiUrl // empty' <<<"$envinfo" | sed 's#/$##')
  dv_aud=$(jq -r '.properties.linkedEnvironmentMetadata.instanceUrl // empty' <<<"$envinfo" | sed 's#/$##')
  DV_TOKEN=""
  if [ -n "$dv_aud" ]; then DV_TOKEN=$(token "$dv_aud/.default"); fi

  # List all flow IDs in the environment (follows paging)
  ids=()
  url="$FLOW/scopes/admin/environments/$env/v2/flows?api-version=2016-11-01"
  while [ -n "$url" ]; do
    page=$(get "$FLOW_TOKEN" "$url")
    mapfile -t -O "${#ids[@]}" ids < <(jq -r '.value[].name' <<<"$page")
    url=$(jq -r '.nextLink // empty' <<<"$page")
  done

  for id in "${ids[@]}"; do
    flow=$(get "$FLOW_TOKEN" "$FLOW/scopes/admin/environments/$env/flows/$id?api-version=2016-11-01&includeFlowDefinition=true")
    name=$(jq -r '.properties.displayName // .name' <<<"$flow")
    label=$(gsub_name() { jq -rn --arg n "$1" '$n | gsub("[^A-Za-z0-9_-]"; "_")'; }; gsub_name "$name")

    # 1) Definition straight from the Flow API, if it came back
    def=$(jq -c '.properties | select(.definition != null) | {connectionReferences, definition}' <<<"$flow")

    # 2) Otherwise read it from Dataverse
    if [ -z "$def" ]; then
      wid=$(jq -r '.properties.workflowEntityId // empty' <<<"$flow")
      if [ -n "$wid" ] && [ -n "$DV_TOKEN" ]; then
        row=$(get "$DV_TOKEN" "$dv_api/api/data/v9.2/workflows($wid)?\$select=clientdata")
        def=$(jq -c '(.clientdata // "{}") | fromjson | .properties // {}
                     | select(.definition != null) | {connectionReferences, definition}' <<<"$row")
      fi
    fi

    if [ -z "$def" ]; then
      echo "No definition found for $name ($id) in the Flow API or Dataverse." >&2
      exit 1
    fi

    jq --arg n "$name" '{displayName: $n} + .' <<<"$def" > "$dir/${label}__${id}.json"
  done
done
