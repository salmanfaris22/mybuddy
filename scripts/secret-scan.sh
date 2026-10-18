#!/usr/bin/env bash
# Fails when likely credentials appear in files that would be committed (tracked, or untracked and
# not ignored). Reports only file:line and the kind of match — never the matched text — so running
# it cannot leak what it finds. Test vectors use raw hex/base64 test keys, which these patterns
# intentionally do not match.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

kinds=(
  "Anthropic API key|sk-ant-[A-Za-z0-9_-]{20,}"
  "OpenAI API key|sk-(proj|svcacct|admin)-[A-Za-z0-9_-]{20,}"
  "Legacy sk- key|sk-[A-Za-z0-9]{40,}"
  "AWS access key|(AKIA|ASIA)[0-9A-Z]{16}"
  "Google API key|AIza[0-9A-Za-z_-]{35}"
  "GitHub token|(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,})"
  "GitLab token|glpat-[A-Za-z0-9_-]{20,}"
  "Slack token|xox[abposr]-[A-Za-z0-9-]{10,}"
  "Private key block|-----BEGIN ([A-Z]+ )?PRIVATE KEY-----"
  "Service-account JSON|\"type\": *\"service_account\""
)

files=()
while IFS= read -r -d '' f; do
  [[ -f "$f" && "$f" != "scripts/secret-scan.sh" ]] && files+=("$f")
done < <(git ls-files -z --cached --others --exclude-standard)

found=0
for entry in "${kinds[@]}"; do
  kind="${entry%%|*}"
  pattern="${entry#*|}"
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    echo "possible ${kind}: ${hit}"
    found=1
  done < <(grep -nIE -e "$pattern" -- "${files[@]}" 2>/dev/null | cut -d: -f1,2 || true)
done

# Secret-bearing files must stay ignored.
while IFS= read -r f; do
  echo "secret-bearing file would be committed: $f"
  found=1
done < <(printf '%s\n' "${files[@]}" | grep -E '(^|/)\.env(\.(local|production|development))?$|(^|/)secrets/|(^|/)local\.properties$|\.(jks|keystore|p12|p8|pem|key)$' || true)

if [[ $found -ne 0 ]]; then
  echo "secret-scan: FAILED — remove the values above (rotate any real credential) before committing." >&2
  exit 1
fi
echo "secret-scan: OK (${#files[@]} files checked)"
