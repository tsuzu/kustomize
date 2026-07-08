#!/usr/bin/env bash
# Copyright 2026 The Kubernetes Authors.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

do_it=0
run_tests=1
push_changes=1
base_branch="master"
push_remote=""
sync_remote=""
release_branch=""
module_bump=""
kustomize_bump=""
module_version=""
kustomize_version=""
gorepomod_bin=""
github_repo=""
final_pr_url=""

usage() {
  cat <<'EOF'
Usage:
  releasing/release-one-branch.sh \
    --module-bump patch|minor|major \
    --kustomize-bump patch|minor|major \
    [--branch release-vX.Y.Z] \
    [--base master] \
    [--remote upstream|origin] \
    [--no-test] \
    [--no-push] \
    [--do-it]

This script automates the multi-module release flow using one release branch.

It will:
  1. compute the target module versions from the requested bumps
  2. verify kyaml, cmd/config, and api would land on the same version
  3. use gorepomod release with --release-branch for tagging
  4. add the pin commits needed before the downstream releases
  5. add unpin commits and update LATEST_RELEASE on the same release branch
  6. open one PR from the release branch to main

Without --branch, the script uses release-$KUSTOMIZE_VERSION.
Without --do-it, it prints the commands it would run.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "[$(basename "$0")] $*"
}

run() {
  log "+ $*"
  if [[ "${do_it}" -eq 1 ]]; then
    "$@"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

github_repo_from_remote() {
  local remote_url=$1
  local repo_path
  case "${remote_url}" in
    https://github.com/*)
      repo_path="${remote_url#https://github.com/}"
      ;;
    git@github.com:*)
      repo_path="${remote_url#git@github.com:}"
      ;;
    ssh://git@github.com/*)
      repo_path="${remote_url#ssh://git@github.com/}"
      ;;
    *)
      fail "unable to determine GitHub repository from remote URL: ${remote_url}"
      ;;
  esac
  repo_path="${repo_path%.git}"
  [[ "${repo_path}" == */* ]] || fail "unable to determine GitHub repository from remote URL: ${remote_url}"
  printf '%s' "${repo_path}"
}

tag_url_path() {
  local tag=$1
  printf '%s' "${tag//\//%2F}"
}

pick_default_remote() {
  if git remote get-url upstream >/dev/null 2>&1; then
    printf 'upstream'
    return
  fi
  if git remote get-url origin >/dev/null 2>&1; then
    printf 'origin'
    return
  fi
  fail "unable to find recognized remote; expected one of: upstream, origin"
}

validate_version() {
  local value=$1
  [[ "${value}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid version: ${value}"
}

validate_bump() {
  case "$1" in
    patch|minor|major) ;;
    *) fail "invalid bump: $1" ;;
  esac
}

bump_version() {
  local version=$1
  local bump=$2
  validate_version "${version}"
  local raw="${version#v}"
  local major minor patch
  IFS='.' read -r major minor patch <<<"${raw}"
  case "${bump}" in
    patch)
      patch=$((patch + 1))
      ;;
    minor)
      minor=$((minor + 1))
      patch=0
      ;;
    major)
      major=$((major + 1))
      minor=0
      patch=0
      ;;
  esac
  printf 'v%s.%s.%s' "${major}" "${minor}" "${patch}"
}

module_local_version() {
  local module=$1
  local value
  value="$("${gorepomod_bin}" list --local | awk -v module="${module}" '$1 == module { print $2; exit }')"
  [[ -n "${value}" ]] || fail "unable to determine local version for module: ${module}"
  printf '%s' "${value}"
}

ensure_clean_workspace() {
  local status
  status="$(git status --porcelain)"
  [[ -z "${status}" ]] || fail "workspace must be clean before running the release automation"
}

restore_go_work_sum_if_needed() {
  if git diff --quiet -- go.work.sum; then
    return
  fi
  log "+ git restore --worktree go.work.sum"
  git restore --worktree go.work.sum
}

build_gorepomod_binary() {
  gorepomod_bin="$(mktemp "${TMPDIR:-/tmp}/gorepomod.XXXXXX")"
  log "+ go build -o ${gorepomod_bin} ./cmd/gorepomod"
  go build -o "${gorepomod_bin}" ./cmd/gorepomod
  restore_go_work_sum_if_needed
}

ensure_branch_absent_on_remote() {
  local branch=$1
  if git ls-remote --exit-code --heads "${push_remote}" "${branch}" >/dev/null 2>&1; then
    fail "remote branch already exists: ${push_remote}/${branch}"
  fi
}

gorepomod_release() {
  local module=$1
  local bump=$2
  if [[ "${do_it}" -eq 1 ]]; then
    "${gorepomod_bin}" release "${module}" "${bump}" --release-branch "${release_branch}" --doIt --local
  else
    log "+ ${gorepomod_bin:-<gorepomod>} release ${module} ${bump} --release-branch ${release_branch} --doIt --local"
  fi
}

gorepomod_pin() {
  local module=$1
  local version=$2
  if [[ "${do_it}" -eq 1 ]]; then
    "${gorepomod_bin}" pin "${module}" "${version}" --doIt --local
  else
    log "+ ${gorepomod_bin:-<gorepomod>} pin ${module} ${version} --doIt --local"
  fi
}

gorepomod_unpin() {
  local module=$1
  if [[ "${do_it}" -eq 1 ]]; then
    "${gorepomod_bin}" unpin "${module}" --doIt --local
  else
    log "+ ${gorepomod_bin:-<gorepomod>} unpin ${module} --doIt --local"
  fi
}

commit_if_needed() {
  local message=$1
  if git diff --quiet --exit-code; then
    log "no changes to commit for: ${message}"
    return
  fi
  run git commit -am "${message}"
}

maybe_run_tests() {
  if [[ "${run_tests}" -eq 1 ]]; then
    run make IS_LOCAL=true verify-kustomize-repo
  else
    log "skipping repository verification"
  fi
}

update_latest_release() {
  if [[ "${do_it}" -eq 1 ]]; then
    python3 - "${kustomize_version}" <<'PY'
from pathlib import Path
import re
import sys

version = sys.argv[1]
path = Path("Makefile")
text = path.read_text()
updated, count = re.subn(r"^LATEST_RELEASE=.*$", f"LATEST_RELEASE={version}", text, count=1, flags=re.MULTILINE)
if count != 1:
    raise SystemExit("error: failed to update LATEST_RELEASE in Makefile")
path.write_text(updated)
PY
  else
    log "+ python3 - '${kustomize_version}' <update Makefile LATEST_RELEASE>"
  fi
}

create_final_pr() {
  local title="Back to development mode after ${kustomize_version}"
  local body
  body=$(cat <<EOF
Restore in-repo module replacements after releasing \`${kustomize_version}\`.

Also update \`LATEST_RELEASE\` to \`${kustomize_version}\`.
EOF
)
  if [[ "${do_it}" -eq 1 ]]; then
    require_cmd gh
    final_pr_url="$(gh pr create \
      --repo "${github_repo}" \
      --base "${base_branch}" \
      --head "${release_branch}" \
      --title "${title}" \
      --body "${body}")"
    printf '%s\n' "${final_pr_url}"
    return
  fi
  run gh pr create \
    --repo "${github_repo:-OWNER/REPO}" \
    --base "${base_branch}" \
    --head "${release_branch}" \
    --title "${title}" \
    --body "${body}"
}

release_action_url() {
  local tag=$1
  local url=""
  if [[ "${do_it}" -ne 1 ]]; then
    printf 'would wait for release workflow run for %s' "${tag}"
    return
  fi

  log "waiting for release workflow run for ${tag}"
  for _ in {1..30}; do
    url="$(gh run list \
      --repo "${github_repo}" \
      --workflow release.yaml \
      --event push \
      --branch "${tag}" \
      --limit 1 \
      --json url \
      --jq '.[0].url // ""')"
    if [[ -n "${url}" ]]; then
      printf '%s' "${url}"
      return
    fi
    sleep 5
  done

  fail "release workflow run was not found for tag: ${tag}"
}

print_postflight_summary() {
  local repo_url="https://github.com/${github_repo}"
  local kyaml_tag="kyaml/${module_version}"
  local cmd_config_tag="cmd/config/${module_version}"
  local api_tag="api/${module_version}"
  local kustomize_tag="kustomize/${kustomize_version}"

  log "release branch automation completed"
  cat <<EOF

Next steps:
  PR: ${final_pr_url:-${repo_url}/pulls}

  Watch release workflows:
    ${kyaml_tag}: $(release_action_url "${kyaml_tag}")
    ${cmd_config_tag}: $(release_action_url "${cmd_config_tag}")
    ${api_tag}: $(release_action_url "${api_tag}")
    ${kustomize_tag}: $(release_action_url "${kustomize_tag}")

  Review and undraft GitHub Releases after the workflows finish:
    ${kyaml_tag}: ${repo_url}/releases/tag/$(tag_url_path "${kyaml_tag}")
    ${cmd_config_tag}: ${repo_url}/releases/tag/$(tag_url_path "${cmd_config_tag}")
    ${api_tag}: ${repo_url}/releases/tag/$(tag_url_path "${api_tag}")
    ${kustomize_tag}: ${repo_url}/releases/tag/$(tag_url_path "${kustomize_tag}")
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      release_branch="${2:-}"
      shift 2
      ;;
    --module-bump)
      module_bump="${2:-}"
      shift 2
      ;;
    --kustomize-bump)
      kustomize_bump="${2:-}"
      shift 2
      ;;
    --base)
      base_branch="${2:-}"
      shift 2
      ;;
    --remote|--push-remote|--sync-remote)
      push_remote="${2:-}"
      sync_remote="${2:-}"
      shift 2
      ;;
    --no-test)
      run_tests=0
      shift
      ;;
    --no-push)
      push_changes=0
      shift
      ;;
    --do-it)
      do_it=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "${module_bump}" ]] || fail "--module-bump is required"
[[ -n "${kustomize_bump}" ]] || fail "--kustomize-bump is required"

validate_bump "${module_bump}"
validate_bump "${kustomize_bump}"

require_cmd git
require_cmd go

cd "${repo_root}"

if [[ -z "${push_remote}" && -z "${sync_remote}" ]]; then
  push_remote="$(pick_default_remote)"
  sync_remote="${push_remote}"
elif [[ -z "${push_remote}" ]]; then
  push_remote="${sync_remote}"
elif [[ -z "${sync_remote}" ]]; then
  sync_remote="${push_remote}"
fi

if [[ "${push_changes}" -ne 1 && "${do_it}" -eq 1 ]]; then
  fail "--no-push is only supported in dry-run mode because gorepomod release always pushes"
fi

git remote get-url "${push_remote}" >/dev/null 2>&1 || fail "remote not found: ${push_remote}"
git remote get-url "${sync_remote}" >/dev/null 2>&1 || fail "remote not found: ${sync_remote}"
github_repo="$(github_repo_from_remote "$(git remote get-url "${push_remote}")")"

ensure_clean_workspace
build_gorepomod_binary
ensure_clean_workspace

local_kyaml_version="$(module_local_version kyaml)"
local_cmd_config_version="$(module_local_version cmd/config)"
local_api_version="$(module_local_version api)"
local_kustomize_version="$(module_local_version kustomize)"

target_kyaml_version="$(bump_version "${local_kyaml_version}" "${module_bump}")"
target_cmd_config_version="$(bump_version "${local_cmd_config_version}" "${module_bump}")"
target_api_version="$(bump_version "${local_api_version}" "${module_bump}")"
kustomize_version="$(bump_version "${local_kustomize_version}" "${kustomize_bump}")"
restore_go_work_sum_if_needed

if [[ "${target_kyaml_version}" != "${target_cmd_config_version}" || "${target_kyaml_version}" != "${target_api_version}" ]]; then
  fail "requested module bump does not produce a shared version: kyaml=${target_kyaml_version}, cmd/config=${target_cmd_config_version}, api=${target_api_version}"
fi
module_version="${target_kyaml_version}"

if [[ -z "${release_branch}" ]]; then
  release_branch="release-${kustomize_version}"
fi
if [[ "${do_it}" -eq 1 ]]; then
  ensure_branch_absent_on_remote "${release_branch}"
fi

log "base branch: ${base_branch}"
log "release branch: ${release_branch}"
log "sync remote: ${sync_remote}"
log "push remote: ${push_remote}"
log "GitHub repo: ${github_repo}"
log "module bump: ${module_bump} -> ${module_version}"
log "kustomize bump: ${kustomize_bump} -> ${kustomize_version}"

run git checkout "${base_branch}"
run git fetch "${sync_remote}" "${base_branch}"
run git merge --ff-only "${sync_remote}/${base_branch}"

maybe_run_tests

gorepomod_release kyaml "${module_bump}"

run git checkout "${release_branch}"
gorepomod_pin kyaml "${module_version}"
commit_if_needed "Pin kyaml to ${module_version} for ${kustomize_version}"
if [[ "${push_changes}" -eq 1 ]]; then
  run git push "${push_remote}" "${release_branch}"
fi

gorepomod_release cmd/config "${module_bump}"
run git checkout "${release_branch}"
gorepomod_release api "${module_bump}"

run git checkout "${release_branch}"
gorepomod_pin cmd/config "${module_version}"
gorepomod_pin api "${module_version}"
commit_if_needed "Pin cmd/config and api to ${module_version} for ${kustomize_version}"
if [[ "${push_changes}" -eq 1 ]]; then
  run git push "${push_remote}" "${release_branch}"
fi

gorepomod_release kustomize "${kustomize_bump}"

run git checkout "${release_branch}"
gorepomod_unpin api
gorepomod_unpin cmd/config
gorepomod_unpin kyaml
update_latest_release
commit_if_needed "Back to development mode after ${kustomize_version}"

if [[ "${push_changes}" -eq 1 ]]; then
  run git push "${push_remote}" "${release_branch}"
fi

create_final_pr

print_postflight_summary
