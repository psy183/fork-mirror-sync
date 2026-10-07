#!/usr/bin/env bash
set -euo pipefail

target_owner="${TARGET_OWNER:-}"
dry_run="${DRY_RUN:-false}"
parallelism="${MAX_PARALLEL:-4}"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required" >&2
  exit 2
fi

mirror_repo="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
if [[ -z "${GH_TOKEN:-}" ]]; then
  GH_TOKEN=$(gh auth token)
  export GH_TOKEN
fi

if [[ "$parallelism" -lt 1 || "$parallelism" -gt 8 ]]; then
  echo "MAX_PARALLEL must be between 1 and 8" >&2
  exit 2
fi

if [[ -n "$target_owner" ]]; then
  repo_list=$(gh repo list "$target_owner" --fork --limit 1000 \
    --json nameWithOwner --jq '.[].nameWithOwner')
else
  repo_list=""
  while IFS= read -r owner; do
    [[ -z "$owner" ]] && continue
    owner_repos=$(gh repo list "$owner" --fork --limit 1000 \
      --json nameWithOwner --jq '.[].nameWithOwner')
    repo_list+=$'\n'"$owner_repos"
  done < <(jq -r '.[]' .github/mirror-organizations.json)
fi

mapfile -t repositories < <(printf '%s\n' "$repo_list" | sed '/^$/d' | sort -u)
if [[ ${#repositories[@]} -eq 0 || -z "${repositories[0]}" ]]; then
  echo "No accessible forks found${target_owner:+ for $target_owner}."
  exit 0
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

git_askpass="$work_dir/askpass.sh"
cat >"$git_askpass" <<'ASKPASS'
#!/usr/bin/env bash
case "$1" in
  *Username*) printf '%s\n' 'x-access-token' ;;
  *Password*) printf '%s\n' "${GH_TOKEN:?GH_TOKEN is required for pushing mirror updates}" ;;
  *) printf '\n' ;;
esac
ASKPASS
chmod 700 "$git_askpass"

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

process_repository() {
  local repository="$1"
  local results_dir="$2"
  local mode="$3"
  local detail fork archived base_branch parent upstream_branch
  local base_ref source_ref current_sha upstream_sha status message source_url git_dir
  local result_file

  result_file="$results_dir/${repository//\//--}.tsv"

  if ! detail=$(gh api "repos/$repository" \
    --jq '[.fork, .archived, .default_branch, .parent.full_name, .parent.default_branch] | @tsv' 2>&1); then
    printf 'error\t%s\t%s\n' "$repository" "$detail" >"$result_file"
    return 0
  fi

  IFS=$'\t' read -r fork archived base_branch parent upstream_branch <<<"$detail"
  if [[ "$fork" != "true" || "$archived" == "true" || -z "$parent" ]]; then
    printf 'skipped\t%s\tnot an active fork\n' "$repository" >"$result_file"
    return 0
  fi

  if [[ -n "$target_owner" && "$repository" != "$target_owner/"* ]]; then
    printf 'skipped\t%s\toutside target owner\n' "$repository" >"$result_file"
    return 0
  fi

  if [[ "$repository" == "$mirror_repo" ]]; then
    printf 'skipped\t%s\tworkflow repository is excluded\n' "$repository" >"$result_file"
    return 0
  fi

  if [[ -z "$base_branch" || -z "$upstream_branch" ]]; then
    printf 'error\t%s\tmissing default branch\n' "$repository" >"$result_file"
    return 0
  fi

  base_ref=$(urlencode "heads/$base_branch")
  source_ref=$(urlencode "$upstream_branch")

  if ! upstream_sha=$(gh api "repos/$parent/commits/$source_ref" --jq '.sha' 2>/dev/null); then
    source_url="https://github.com/$parent.git"
    upstream_sha=$(git -c credential.helper= ls-remote "$source_url" "refs/heads/$upstream_branch" | awk 'NR == 1 { print $1 }')
    if [[ -z "$upstream_sha" ]]; then
      printf 'error\t%s\tunable to read upstream branch %s\n' "$repository" "$upstream_branch" >"$result_file"
      return 0
    fi
  fi

  if ! current_sha=$(gh api "repos/$repository/git/ref/$base_ref" --jq '.object.sha' 2>&1); then
    printf 'error\t%s\tbranch: %s\n' "$repository" "$current_sha" >"$result_file"
    return 0
  fi

  if [[ "$current_sha" == "$upstream_sha" ]]; then
    printf 'current\t%s\t%s\n' "$repository" "$base_branch" >"$result_file"
    return 0
  fi

  if [[ "$mode" == "true" ]]; then
    printf 'would_reset\t%s\t%s\t%s\n' "$repository" "$base_branch" "$upstream_sha" >"$result_file"
    return 0
  fi

  if message=$(gh api --method PATCH "repos/$repository/git/refs/$base_ref" \
    -f "sha=$upstream_sha" -F force=true 2>&1); then
    printf 'reset\t%s\t%s\t%s\n' "$repository" "$base_branch" "$upstream_sha" >"$result_file"
  else
    git_dir="$work_dir/git-${repository//\//--}"
    if mkdir -p "$git_dir" && git -C "$git_dir" init -q 2>/dev/null; then
      git -C "$git_dir" remote add upstream "https://github.com/$parent.git" 2>/dev/null || true
      git -C "$git_dir" remote add origin "https://github.com/$repository.git" 2>/dev/null || true
      if git -C "$git_dir" -c credential.helper= fetch --depth=1 upstream \
          "refs/heads/$upstream_branch:refs/remotes/upstream/mirror-sync" >/dev/null 2>&1 &&
        GIT_ASKPASS="$git_askpass" GIT_TERMINAL_PROMPT=0 \
          git -C "$git_dir" -c credential.helper= push --force origin \
            "refs/remotes/upstream/mirror-sync:refs/heads/$base_branch" >/dev/null 2>&1; then
        printf 'reset\t%s\t%s\t%s\tgit-fallback\n' "$repository" "$base_branch" "$upstream_sha" >"$result_file"
      else
        printf 'error\t%s\treset API: %s; git fallback also failed\n' "$repository" "$message" >"$result_file"
      fi
    else
      printf 'error\t%s\treset API: %s; cannot initialize git fallback\n' "$repository" "$message" >"$result_file"
    fi
  fi
}

export -f urlencode process_repository

printf '%s\n' "${repositories[@]}" | xargs -r -P "$parallelism" -I '{}' \
  bash -c 'process_repository "$1" "$2" "$3"' _ '{}' "$work_dir" "$dry_run"

cat "$work_dir"/*.tsv | sort -k1,1 -k2,2

summary=$(awk -F '\t' '{count[$1]++} END {for (key in count) printf "%s=%d ", key, count[key]}' "$work_dir"/*.tsv)
echo "Summary: ${summary:-no repositories processed}"

if awk -F '\t' '$1 == "error" { found = 1 } END { exit !found }' "$work_dir"/*.tsv; then
  exit 1
fi
