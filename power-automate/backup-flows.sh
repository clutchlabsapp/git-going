#!/usr/bin/env bash
# Backs up every Power Automate cloud flow definition using an app (service principal) login.
set -euo pipefail

PA_ENVIRONMENTS="${PA_ENVIRONMENTS:-Default-$PA_TENANT_ID}"
FLOW="https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple"
FLOW_SCOPE="https://service.flow.microsoft.com//.default"
OUT=$(mktemp -d)          # new backup is built here, swapped in at the end
unreadable=()

# curl with retries on throttling (429) and server errors (5xx).
# Prints the body; on a real error prints the URL and Microsoft's message to the log.
call() {
  local attempt out status="" body=""
  for attempt in 1 2 3 4 5; do
    if ! out=$(curl -sS -w '\n%{http_code}' "$@"); then sleep $((attempt * 5)); continue; fi
    status=${out##*$'\n'}
    body=${out%$'\n'*}
    if [ "$status" = 429 ] || [ "$status" -ge 500 ]; then sleep $((attempt * 10)); continue; fi
    if [ "$status" -ge 400 ]; then
      echo "HTTP $status from: ${*: -1}" >&2
      echo "$body" >&2
      return 1
    fi
    printf '%s' "$body"
    return 0
  done
  echo "Gave up after retries (last HTTP ${status:-none}): ${*: -1}" >&2
  return 1
}

# new_token <scope> <VAR>: gets an app token into $VAR and its renew time into ${VAR}_EXP
new_token() {
  local resp
  resp=$(call -X POST \
    -d grant_type=client_credentials \
    -d client_id="$PA_APPLICATION_ID" \
    --data-urlencode client_secret="$PA_CLIENT_SECRET" \
    -d scope="$1" \
    "https://login.microsoftonline.com/$PA_TENANT_ID/oauth2/v2.0/token") || return 1
  printf -v "$2" '%s' "$(jq -r .access_token <<<"$resp")"
  printf -v "${2}_EXP" '%s' "$(( $(date +%s) + $(jq -r .expires_in <<<"$resp") - 300 ))"
}

# fresh <scope> <VAR>: renews the token if missing or within 5 minutes of expiring
fresh() {
  local exp_var="${2}_EXP"
  if [ -z "${!2:-}" ] || [ "$(date +%s)" -ge "${!exp_var:-0}" ]; then
    new_token "$1" "$2"
  fi
}

# get <token> <url>
get() {
  call -H "Authorization: Bearer $1" -H "Accept: application/json" "$2"
}

# Reads Dataverse JSON (one row or a list of rows) from stdin and prints the first
# {connectionReferences, definition} found in a clientdata column, or nothing.
from_dataverse() {
  jq -c '[ (.value // [.])[]
           | .clientdata | select(type == "string") | fromjson?
           | .properties? // empty
           | select(.definition != null)
           | {connectionReferences, definition} ] | first // empty' 2>/dev/null || true
}

# keep_old <env> <flow id>: carries the previous backup of a flow into the new one
keep_old() {
  local f
  for f in flows/"$1"/*__"$2".json; do
    if [ -e "$f" ]; then cp "$f" "$OUT/$1/"; fi
  done
}

fresh "$FLOW_SCOPE" FLOW_TOKEN

for env in $PA_ENVIRONMENTS; do
  mkdir -p "$OUT/$env"

  # --- This environment's Dataverse address, if it has one ---
  dv_api=""; dv_scope=""; DV_TOKEN=""; DV_TOKEN_EXP=0
  envinfo=$(get "$FLOW_TOKEN" "$FLOW/environments/$env?api-version=2016-11-01" 2>/dev/null) ||
    envinfo=$(get "$FLOW_TOKEN" "$FLOW/scopes/admin/environments/$env?api-version=2016-11-01" 2>/dev/null) ||
    envinfo='{}'
  dv_api=$(jq -r '.properties.linkedEnvironmentMetadata.instanceApiUrl // empty' <<<"$envinfo" | sed 's#/$##')
  dv_aud=$(jq -r '.properties.linkedEnvironmentMetadata.instanceUrl // empty' <<<"$envinfo" | sed 's#/$##')
  if [ -n "$dv_api" ] && [ -n "$dv_aud" ]; then
    dv_scope="$dv_aud/.default"
    if ! fresh "$dv_scope" DV_TOKEN; then
      echo "Note: couldn't get a Dataverse token for $env; Dataverse lookups skipped." >&2
      dv_scope=""
    fi
  fi

  # --- List every flow in the environment (follows paging) ---
  ids=()
  listed=1
  url="$FLOW/scopes/admin/environments/$env/v2/flows?api-version=2016-11-01"
  while [ -n "$url" ]; do
    fresh "$FLOW_SCOPE" FLOW_TOKEN
    if ! page=$(get "$FLOW_TOKEN" "$url"); then listed=0; break; fi
    mapfile -t -O "${#ids[@]}" ids < <(jq -r '.value[]?.name' <<<"$page")
    url=$(jq -r '.nextLink // empty' <<<"$page")
  done
  if [ "$listed" = 0 ]; then
    unreadable+=("$env | (whole environment) | couldn't list flows; previous backup kept")
    if [ -d "flows/$env" ]; then cp -r "flows/$env/." "$OUT/$env/"; fi
    continue
  fi

  # --- Each flow ---
  for id in "${ids[@]}"; do
    fresh "$FLOW_SCOPE" FLOW_TOKEN
    if ! flow=$(get "$FLOW_TOKEN" "$FLOW/scopes/admin/environments/$env/flows/$id?api-version=2016-11-01&includeFlowDefinition=true"); then
      unreadable+=("$env | $id | couldn't fetch flow; previous backup kept")
      keep_old "$env" "$id"
      continue
    fi
    name=$(jq -r '.properties.displayName // .name' <<<"$flow")
    label=$(jq -rn --arg n "$name" '$n | gsub("[^A-Za-z0-9_-]"; "_")')
    wid=$(jq -r '.properties.workflowEntityId // empty' <<<"$flow")
    wuid=$(jq -r '.properties.workflowUniqueId // empty' <<<"$flow")

    # 1) Definition straight from the Flow API
    def=$(jq -c '.properties | select(.definition != null) | {connectionReferences, definition}' <<<"$flow")

    # 2) Dataverse: by row ID, then by unique ID, then by flow ID
    if [ -z "$def" ] && [ -n "$dv_scope" ]; then
      fresh "$dv_scope" DV_TOKEN
      for q in ${wid:+"workflows($wid)?\$select=clientdata"} \
               ${wuid:+"workflows?\$select=clientdata&\$filter=workflowidunique%20eq%20$wuid"} \
               "workflows($id)?\$select=clientdata"; do
        def=$(get "$DV_TOKEN" "$dv_api/api/data/v9.2/$q" 2>/dev/null | from_dataverse) || def=""
        if [ -n "$def" ]; then break; fi
      done
    fi

    # 3) Save, or record why not and keep the last good copy
    if [ -n "$def" ]; then
      jq --arg n "$name" '{displayName: $n} + .' <<<"$def" > "$OUT/$env/${label}__${id}.json"
    else
      if [ -z "$wid" ] && [ -z "$wuid" ]; then
        reason="stored only in the Flow service; Microsoft doesn't return its definition to an app login"
      elif [ -z "$dv_scope" ]; then
        reason="stored in Dataverse, but this environment's Dataverse couldn't be reached"
      else
        reason="stored in Dataverse, but no row with a definition was found"
      fi
      unreadable+=("$env | $name ($id) | $reason")
      keep_old "$env" "$id"
    fi
  done
done

# --- Swap in the new backup and write the report ---
rm -rf flows
mv "$OUT" flows
if [ ${#unreadable[@]} -gt 0 ]; then
  printf '%s\n' "${unreadable[@]}" > flows/_unreadable.txt
  printf 'NOT BACKED UP: %s\n' "${unreadable[@]}" >&2
fi
