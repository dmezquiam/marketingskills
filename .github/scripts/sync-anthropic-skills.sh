#!/usr/bin/env bash
# Sube cada skill de anthropic-skills.json a la API de Anthropic.
# Requiere: curl, jq, ANTHROPIC_API_KEY.
set -euo pipefail

API="https://api.anthropic.com/v1/skills"
MAP="anthropic-skills.json"
HDR=(-H "x-api-key: ${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY secret is missing}"
     -H "anthropic-version: 2023-06-01"
     -H "anthropic-beta: skills-2025-10-02")

if [[ ! -f "$MAP" ]]; then echo "::error::$MAP not found"; exit 1; fi

changed_in_push() {
  # True if the skill folder changed in the pushed commit(s).
  local dir="$1"
  if [[ "${FORCE_ALL:-false}" == "true" ]]; then return 0; fi
  if ! git rev-parse HEAD~1 >/dev/null 2>&1; then return 0; fi
  ! git diff --quiet HEAD~1 HEAD -- "$dir" "$MAP"
}

upload() {
  # $1 = url, $2 = skill dir name (relative to skills/)
  local url="$1" name="$2" args=()
  pushd skills >/dev/null
  while IFS= read -r f; do
    args+=(-F "files[]=@${f};filename=${f}")
  done < <(find "$name" -type f | sort)
  local resp
  resp=$(curl -sS -X POST "$url" "${HDR[@]}" "${args[@]}")
  popd >/dev/null
  echo "$resp"
}

summary=""
for name in $(jq -r 'keys[]' "$MAP"); do
  dir="skills/$name"
  if [[ ! -f "$dir/SKILL.md" ]]; then
    echo "::warning::$dir/SKILL.md not found, skipping"
    continue
  fi
  id=$(jq -r --arg k "$name" '.[$k] // ""' "$MAP")

  if [[ -z "$id" ]]; then
    echo "Creating skill '$name'..."
    resp=$(upload "$API" "$name")
    id=$(echo "$resp" | jq -r '.id // empty')
    if [[ -z "$id" ]]; then echo "::error::Create failed for $name: $resp"; exit 1; fi
    tmp=$(mktemp); jq --arg k "$name" --arg v "$id" '.[$k]=$v' "$MAP" > "$tmp" && mv "$tmp" "$MAP"
    summary+="- $name: CREATED -> $id"$'\n'
  elif changed_in_push "$dir"; then
    echo "Uploading new version of '$name' ($id)..."
    resp=$(upload "$API/$id/versions" "$name")
    ver=$(echo "$resp" | jq -r '.version // empty')
    if [[ -z "$ver" ]]; then echo "::error::Version upload failed for $name: $resp"; exit 1; fi
    summary+="- $name: new version $ver ($id)"$'\n'
  else
    summary+="- $name: unchanged, skipped ($id)"$'\n'
  fi
done

echo "## Anthropic skills sync" >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
echo "$summary" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
echo
echo "Skill ids for /admin/agent -> Skill ids:"
jq -r 'to_entries[] | select(.value != "") | "\(.key): \(.value)"' "$MAP"
