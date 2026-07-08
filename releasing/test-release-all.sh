#!/usr/bin/env bash
# Copyright 2026 The Kubernetes Authors.
# SPDX-License-Identifier: Apache-2.0
#
# E2E test wrapper for release-all.sh. Runs a full release against a fork by:
# - rewriting github.com/kubernetes-sigs/kustomize URLs to the fork via a
#   sandboxed GIT_CONFIG_GLOBAL (the user's real ~/.gitconfig is untouched);
# - setting GOPROXY=direct and GOSUMDB=off so go mod resolves via git directly;
# - removing the upstream remote for the duration so gorepomod picks the fork;
# - deleting any tags/branches/PRs the release created on the fork afterwards.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

module_bump="patch"
kustomize_bump="patch"
base_branch="master"
fork_remote="origin"
upstream_remote="upstream"
log_dir=""
keep_artifacts=0
run_tests=0

usage() {
  cat <<'EOF'
Usage: releasing/test-release-all.sh [options]

Options:
  --module-bump {patch|minor}      (default: patch)
  --kustomize-bump {patch|minor}   (default: patch)
  --base BRANCH                    (default: master)
  --fork-remote NAME               (default: origin)
  --upstream-remote NAME           (default: upstream)
  --log-dir DIR                    (default: /tmp/kustomize-release-test-<ts>)
  --run-tests                      run verify-kustomize-repo during the release
  --keep-artifacts                 skip cleanup of fork tags/branches/PR
  -h, --help
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "[test-release-all] $*"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --module-bump) module_bump="${2:-}"; shift 2 ;;
    --kustomize-bump) kustomize_bump="${2:-}"; shift 2 ;;
    --base) base_branch="${2:-}"; shift 2 ;;
    --fork-remote) fork_remote="${2:-}"; shift 2 ;;
    --upstream-remote) upstream_remote="${2:-}"; shift 2 ;;
    --log-dir) log_dir="${2:-}"; shift 2 ;;
    --run-tests) run_tests=1; shift ;;
    --keep-artifacts) keep_artifacts=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown arg: $1" ;;
  esac
done

cd "${repo_root}"

fork_url="$(git remote get-url "${fork_remote}")"
if [[ "${fork_url}" == *kubernetes-sigs/kustomize* ]]; then
  fail "'${fork_remote}' points to kubernetes-sigs; refusing to run test against upstream"
fi
fork_owner_repo="$(echo "${fork_url}" | sed -E 's|.*github.com[/:]||; s|\.git$||')"
[[ "${fork_owner_repo}" == */* ]] || fail "cannot parse fork remote URL: ${fork_url}"

upstream_url=""
if git remote get-url "${upstream_remote}" >/dev/null 2>&1; then
  upstream_url="$(git remote get-url "${upstream_remote}")"
fi

log_dir="${log_dir:-/tmp/kustomize-release-test-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "${log_dir}"
log "log dir: ${log_dir}"

before_refs="${log_dir}/refs-before.txt"
git ls-remote "${fork_remote}" > "${before_refs}"

before_prs="${log_dir}/prs-before.txt"
if command -v gh >/dev/null 2>&1; then
  gh pr list --repo "${fork_owner_repo}" --state open --json number --jq '.[].number' \
    > "${before_prs}" 2>/dev/null || : > "${before_prs}"
else
  : > "${before_prs}"
fi

tmp_gitconfig="${log_dir}/gitconfig-sandbox"
if [[ -f "${HOME}/.gitconfig" ]]; then
  cp "${HOME}/.gitconfig" "${tmp_gitconfig}"
else
  : > "${tmp_gitconfig}"
fi
GIT_CONFIG_GLOBAL="${tmp_gitconfig}" git config --file "${tmp_gitconfig}" \
  "url.https://github.com/${fork_owner_repo}.insteadOf" \
  "https://github.com/kubernetes-sigs/kustomize"
log "sandbox gitconfig with insteadOf rewrite: kubernetes-sigs -> ${fork_owner_repo}"

if [[ -n "${upstream_url}" ]]; then
  log "removing '${upstream_remote}' remote for the duration of the test"
  git remote remove "${upstream_remote}"
fi

start_branch="$(git rev-parse --abbrev-ref HEAD)"

cleanup() {
  local rc=$?
  trap - EXIT
  set +e
  log "cleanup starting (release exit=${rc})"

  # Get back off any release branch gorepomod may have checked out.
  local cur_branch
  cur_branch="$(git rev-parse --abbrev-ref HEAD)"
  if [[ "${cur_branch}" != "${start_branch}" ]]; then
    git checkout "${start_branch}" >/dev/null 2>&1 || log "  could not switch back to ${start_branch}"
  fi

  # Revert any uncommitted go.mod / go.work.sum changes made during the run.
  git ls-files '*/go.mod' go.mod go.work go.work.sum 2>/dev/null \
    | xargs -r git checkout -- 2>/dev/null || true

  # Restore upstream remote.
  if [[ -n "${upstream_url}" ]] && ! git remote get-url "${upstream_remote}" >/dev/null 2>&1; then
    git remote add "${upstream_remote}" "${upstream_url}"
    log "restored '${upstream_remote}' remote"
  fi

  if [[ "${keep_artifacts}" -eq 1 ]]; then
    log "skipping artifact cleanup (--keep-artifacts). Sandbox gitconfig at ${tmp_gitconfig}."
    exit "${rc}"
  fi

  local after_refs="${log_dir}/refs-after.txt"
  git ls-remote "${fork_remote}" > "${after_refs}" 2>/dev/null || true
  # ^{} suffixes are peeled-tag rows; the underlying ref is deletable without them.
  local new_refs
  new_refs="$(comm -13 <(sort "${before_refs}") <(sort "${after_refs}") \
              | awk '{print $2}' | grep -v '\^{}$' || true)"

  local new_release_tags=""
  if [[ -n "${new_refs}" ]]; then
    log "new refs created on fork; deleting:"
    while IFS= read -r ref; do
      [[ -z "${ref}" ]] && continue
      echo "  ${ref}"
      case "${ref}" in
        refs/tags/*)
          local tag="${ref#refs/tags/}"
          new_release_tags="${new_release_tags}${tag}\n"
          git push "${fork_remote}" --delete "${tag}" >/dev/null 2>&1 \
            || log "  failed to delete tag ${ref}"
          ;;
        refs/heads/*)
          git push "${fork_remote}" --delete "${ref#refs/heads/}" >/dev/null 2>&1 \
            || log "  failed to delete branch ${ref}"
          ;;
      esac
    done <<<"${new_refs}"
  else
    log "no new refs on fork"
  fi

  # Delete local tags/branches that the test just created (i.e., not in
  # refs-before), so the next test starts fresh.
  local new_local_tags
  new_local_tags="$(comm -13 \
    <(cut -f2- "${before_refs}" | sed -n 's|^refs/tags/||p' | grep -v '\^{}$' | sort) \
    <(git for-each-ref --format='%(refname:short)' refs/tags/ | sort))"
  if [[ -n "${new_local_tags}" ]]; then
    while IFS= read -r t; do
      [[ -z "${t}" ]] && continue
      git tag -d "${t}" >/dev/null 2>&1 || true
    done <<<"${new_local_tags}"
  fi
  local new_local_branches
  new_local_branches="$(git for-each-ref --format='%(refname:short)' refs/heads/ \
    | grep -E '^release-v' || true)"
  if [[ -n "${new_local_branches}" ]]; then
    while IFS= read -r b; do
      [[ -z "${b}" ]] && continue
      git branch -D "${b}" >/dev/null 2>&1 || true
    done <<<"${new_local_branches}"
  fi

  if command -v gh >/dev/null 2>&1; then
    # Close only PRs that were opened during the test (before/after diff).
    local after_prs="${log_dir}/prs-after.txt"
    gh pr list --repo "${fork_owner_repo}" --state open --json number --jq '.[].number' \
      > "${after_prs}" 2>/dev/null || : > "${after_prs}"
    local new_prs
    new_prs="$(comm -13 <(sort "${before_prs}") <(sort "${after_prs}") || true)"
    if [[ -n "${new_prs}" ]]; then
      while IFS= read -r pr; do
        [[ -z "${pr}" ]] && continue
        log "closing test PR #${pr}"
        gh pr close --repo "${fork_owner_repo}" "${pr}" >/dev/null 2>&1 \
          || log "  failed to close PR #${pr}"
      done <<<"${new_prs}"
    fi

    # Delete draft GitHub Releases created by release.yaml for the new tags.
    if [[ -n "${new_release_tags}" ]]; then
      while IFS= read -r tag; do
        [[ -z "${tag}" ]] && continue
        if gh release view "${tag}" --repo "${fork_owner_repo}" >/dev/null 2>&1; then
          log "deleting draft release ${tag}"
          gh release delete "${tag}" --repo "${fork_owner_repo}" --yes \
            >/dev/null 2>&1 || log "  failed to delete release ${tag}"
        fi
      done < <(printf '%b' "${new_release_tags}")
    fi
  fi

  rm -f "${tmp_gitconfig}"
  log "cleanup done"
  exit "${rc}"
}
trap cleanup EXIT

log "invoking release-all.sh --do-it"
release_args=(
  --module-bump "${module_bump}"
  --kustomize-bump "${kustomize_bump}"
  --base "${base_branch}"
  --remote "${fork_remote}"
  --do-it
)
if [[ "${run_tests}" -ne 1 ]]; then
  release_args+=(--no-test)
fi

log_file="${log_dir}/release.log"
{
  echo "=== START $(date -Iseconds) ==="
  echo "=== fork: ${fork_owner_repo} ==="
  echo "=== base: ${base_branch} ==="
  echo "=== bumps: module=${module_bump} kustomize=${kustomize_bump} ==="
  echo
  GIT_CONFIG_GLOBAL="${tmp_gitconfig}" GOPROXY=direct GOSUMDB=off \
    bash "${script_dir}/release-all.sh" "${release_args[@]}"
  echo
  echo "=== END $(date -Iseconds) rc=$? ==="
} 2>&1 | tee "${log_file}"
rc=${PIPESTATUS[0]}

log "release-all.sh exit=${rc}"
log "full log: ${log_file}"
exit "${rc}"
