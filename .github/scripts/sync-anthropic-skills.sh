#!/usr/bin/env bash
# Sube todas las skills de skills/*/SKILL.md a la API de Anthropic.
# anthropic-skills.json es solo el registro de ids (skill -> skill_id):
# - Skill sin id (nueva en el repo): se crea y se anota su skill_id.
# - Skill con id y cambios en el push: se sube una version nueva del mismo id.
# Requiere: curl, jq, ANTHROPIC_API_KEY.
set -euo pipefail

API="https://api.anthropic.com/v1/skills"
MAP="anthropic-skills.json"
HDR=(-H "x-api-key: ${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY secret is missing}"
     -H "anthropic-version: 2023-06-01"
     -H "anthropic-beta: skills-2025-10-02")

[[ -f "$MAP" ]] || echo '{}' > "$MAP"

changed_in_push() {
  # True if the skill folder changed in the pushed commit(s).
  local dir="$1"
  if [[ "${FORCE_ALL:-false}" == "true" ]]; then return 0; fi
  if ! git rev-parse HEAD~1 >/dev/null 2>&1; then return 0; fi
  ! git diff --quiet HEAD~1 HEAD -- "$dir"
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

created=0; updated=0; skipped=0; summary=""
# Discover every skill in the repo, not only the ones already in the json.
for skillmd in skills/*/SKILL.md; do
  name=$(basename "$(dirname "$skillmd")")
  dir="skills/$name"
  id=$(jq -r --arg k "$name" '.[$k] // ""' "$MAP")

  if [[ -z "$id" ]]; then
    echo "Creating skill '$name'..."
    resp=$(upload "$API" "$name")
    id=$(echo "$resp" | jq -r '.id // empty')
    if [[ -z "$id" ]]; then echo "::error::Create failed for $name: $resp"; exit 1; fi
    tmp=$(mktemp); jq --arg k "$name" --arg v "$id" '.[$k]=$v' "$MAP" > "$tmp" && mv "$tmp" "$MAP"
    summary+="- $name: CREATED -> $id"$'\n'; created=$((created+1))
  elif changed_in_push "$dir"; then
    echo "Uploading new version of '$name' ($id)..."
    resp=$(upload "$API/$id/versions" "$name")
    ver=$(echo "$resp" | jq -r '.version // empty')
    if [[ -z "$ver" ]]; then echo "::error::Version upload failed for $name: $resp"; exit 1; fi
    summary+="- $name: new version $ver ($id)"$'\n'; updated=$((updated+1))
  else
    skipped=$((skipped+1))
  fi
done

# Skills that disappeared from the repo keep their id in the json (nothing is deleted in the API).
for name in $(jq -r 'keys[]' "$MAP"); do
  [[ -f "skills/$name/SKILL.md" ]] || summary+="- $name: no longer in the repo (kept in the API)"$'\n'
done

{
  echo "## Anthropic skills sync"
  echo "Created: $created, updated: $updated, unchanged: $skipped"
  echo
  echo "$summary"
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
