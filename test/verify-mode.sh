#!/usr/bin/env bash
# Runs the action's "Verify vault" step (mode: verify) the way a fresh CI
# runner would on a pull request: on the merge of the pull request branch into
# the base branch, as GitHub's refs/pull/N/merge checkout gives it, with no
# murk key, as on a pull request from a fork.
#
# Cases:
#   - only the branch changed the vault: the signature verifies, the step passes;
#   - both branches changed the vault and a merge without the murk merge
#     driver combined them: the step fails with the merge hint, because the
#     signature check fails (not because of some other error).
#
# Needs murk 0.15.2 or later on PATH, git, and ruby (to read the step from
# action.yml). Keys are generated per run in a temporary directory.
set -euo pipefail

ACTION_YML="$(cd "$(dirname "$0")/.." && pwd)/action.yml"
WORK=$(mktemp -d "${RUNNER_TEMP:-/tmp}/murk-action-verify.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

FAILED=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=1; }

MURK_VERSION=$(murk --version | sed -n 's/^murk \([0-9][0-9.]*\).*/\1/p')
echo "murk $MURK_VERSION"

# The step's script, exactly as the action runs it, and its MERGE_FAILURE env.
ruby -ryaml -e '
  step = YAML.load_file(ARGV[0])["runs"]["steps"].find { |s| s["id"] == "verify" }
  print step["run"]
' "$ACTION_YML" > "$WORK/verify.sh"
MERGE_FAILURE=$(ruby -ryaml -e '
  print YAML.load_file(ARGV[0])["runs"]["steps"].find { |s| s["id"] == "verify" }["env"]["MERGE_FAILURE"]
' "$ACTION_YML")

unset MURK_KEY MURK_KEY_FILE MURK_AGENT MURK_TRUSTED_SIGNERS MURK_VAULT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

# Create a key in its own HOME. Prints its key; its trust entry goes to $2.
new_key() {
  local dir="$WORK/$1"
  mkdir -p "$dir/home"
  (cd "$dir" && echo "$1" | HOME="$dir/home" murk init --vault "$1.murk" >/dev/null 2>&1)
  cat "$(sed -n "s/^export MURK_KEY_FILE='\\(.*\\)'/\\1/p" "$dir/.env")"
}
entry_for() {
  (cd "$WORK" && HOME="$WORK/$1/home" MURK_KEY="$2" murk trust --print-key 2>/dev/null)
}

REPO="$WORK/repo"
mkdir -p "$REPO" "$WORK/init-home"
git -C "$REPO" init -q -b main
(cd "$REPO" && echo author | HOME="$WORK/init-home" murk init --vault .murk >/dev/null 2>&1)
AUTHOR_KEY=$(cat "$(sed -n "s/^export MURK_KEY_FILE='\\(.*\\)'/\\1/p" "$REPO/.env")")
rm -f "$REPO/.env"
SIGNER=$(cd "$REPO" && HOME="$WORK/init-home" MURK_KEY="$AUTHOR_KEY" murk trust --print-key 2>/dev/null)
OTHER_KEY=$(new_key other)
OTHER_ENTRY=$(entry_for other "$OTHER_KEY")

# The author writes the vault. Each write uses a fresh HOME: murk pins the last
# vault generation it accepted per HOME, and switching branches would trip it.
N=0
murk_write() {
  N=$((N + 1))
  (cd "$REPO" && HOME="$WORK/write-$N" MURK_KEY="$AUTHOR_KEY" MURK_TRUSTED_SIGNERS="$SIGNER" murk "$@" >/dev/null 2>&1)
}
commit() { git -C "$REPO" add .murk && git -C "$REPO" commit -qm "$1"; }

printf 'a' | murk_write add A
printf 'm' | murk_write add M
commit base

# "both" and main both change the vault after "base". "only-branch" starts
# from main's tip, so only the branch changes the vault.
git -C "$REPO" checkout -qb both
printf 'b' | murk_write add B
commit "add B"
git -C "$REPO" checkout -q main
printf 'z' | murk_write add Z
commit "add Z on main"
git -C "$REPO" checkout -qb only-branch
printf 'y' | murk_write add Y
commit "add Y"

# A plain text merge of two vault writes always conflicts: both rewrite the
# meta and signature lines. GitHub then runs no pull_request checks.
git -C "$REPO" checkout -q both
if git -C "$REPO" merge -q --no-edit main >/dev/null 2>&1; then
  fail "text merge of two vault writes: expected a conflict"
else
  pass "text merge of two vault writes conflicts"
fi
git -C "$REPO" merge --abort

# The branch resolves that conflict without the murk merge driver, the way
# GitHub's conflict editor does: one side per conflicting hunk, the other
# side's hunks that do not conflict. The result is valid JSON, not a valid
# vault. A union merge keeps both sides and is not valid JSON.
git -C "$REPO" checkout -q -b resolved-ours both
git -C "$REPO" merge -q -X ours --no-edit main >/dev/null 2>&1
git -C "$REPO" checkout -q -b resolved-theirs both
git -C "$REPO" merge -q -X theirs --no-edit main >/dev/null 2>&1
git -C "$REPO" checkout -q -b resolved-union both
echo '.murk merge=union' > "$REPO/.git/info/attributes"
git -C "$REPO" merge -q --no-edit main >/dev/null 2>&1
rm "$REPO/.git/info/attributes"

# A pull request whose vault holds workflow commands in a field that murk
# quotes in its error.
git -C "$REPO" checkout -q -b injected main
ruby -rjson -e '
  v = JSON.parse(File.read(ARGV[0]))
  v["version"] = "x\n::error::INJECTED\n::warning::INJECTED"
  File.write(ARGV[0], JSON.pretty_generate(v))
' "$REPO/.murk"
commit "inject workflow commands"

# Check out GitHub's test merge of a pull request branch into main
# (refs/pull/N/merge) and run the step there on a fresh runner with no key.
# Sets RC, OUT.
run_verify() {
  local name=$1 branch=$2 signers=${3-$SIGNER} version=${4-$MURK_VERSION} runner="$WORK/runner-$1"
  mkdir -p "$runner/home" "$runner/tmp"
  git -C "$REPO" checkout -q --detach main
  git -C "$REPO" merge -q --no-ff --no-edit "$branch" >/dev/null
  : > "$runner/github_env"
  : > "$runner/github_output"
  set +e
  # shellcheck disable=SC2086 # EXTRA_ENV holds NAME=value words on purpose
  OUT=$(cd "$REPO" && env HOME="$runner/home" RUNNER_TEMP="$runner/tmp" \
    GITHUB_ENV="$runner/github_env" GITHUB_OUTPUT="$runner/github_output" \
    MURK_VERSION="$version" INPUT_VAULT=.murk INPUT_TRUSTED_SIGNERS="$signers" \
    BASE_REF=main MERGE_FAILURE="$MERGE_FAILURE" ${EXTRA_ENV:-} \
    bash "$WORK/verify.sh" 2>&1)
  RC=$?
  set -e
  ENV_OUT="$(cat "$runner/github_env" "$runner/github_output")"
  echo "--- $name (exit $RC)"
  echo "$OUT"
}

HINT='^::error::\.murk did not pass the murk signature check\. Both this branch and main changed the vault\..*git merge origin/main'

run_verify only-branch only-branch
if [ "$RC" -eq 0 ] && grep -q '^::notice::' <<<"$OUT" && [ -z "$ENV_OUT" ]; then
  pass "only the branch changed the vault, no key: passes, exports nothing"
else
  fail "only the branch changed the vault, no key: expected a pass with no exports"
fi

# A key in the environment must not reach murk: an invalid one would fail it.
EXTRA_ENV="MURK_KEY=AGE-SECRET-KEY-1INVALID MURK_KEY_FILE=$WORK/missing-key" \
  run_verify stray-key only-branch
if [ "$RC" -eq 0 ]; then
  pass "a key in the environment is not passed to murk"
else
  fail "a key in the environment is not passed to murk: expected a pass"
fi

for side in ours theirs union; do
  run_verify "resolved-$side" "resolved-$side"
  if [ "$RC" -ne 0 ] && grep -qE "$HINT" <<<"$OUT" && [ -z "$ENV_OUT" ]; then
    pass "both changed, merged without the driver ($side): fails with the merge hint"
  else
    fail "both changed, merged without the driver ($side): expected a failure with the merge hint"
  fi
done

run_verify untrusted only-branch "$OTHER_ENTRY"
if [ "$RC" -ne 0 ] && grep -q '^::error::.*See the murk error above' <<<"$OUT" \
  && ! grep -qE "$HINT" <<<"$OUT"; then
  pass "signer not in trusted-signers: fails without the merge hint"
else
  fail "signer not in trusted-signers: expected a failure without the merge hint"
fi

run_verify no-signers only-branch ""
if [ "$RC" -ne 0 ] && grep -q '^::error::mode: verify needs the trusted-signers input' <<<"$OUT"; then
  pass "no trusted-signers: refused"
else
  fail "no trusted-signers: expected a refusal naming the input"
fi

run_verify old-murk only-branch "$SIGNER" 0.15.1
if [ "$RC" -ne 0 ] && grep -q '^::error::mode: verify needs murk 0.15.2 or later' <<<"$OUT"; then
  pass "murk older than 0.15.2: refused"
else
  fail "murk older than 0.15.2: expected a refusal"
fi

# Every line of the step's output that holds the injected text must sit inside
# a stop-commands block that the step opens and closes with the same token.
# The step's own annotations must come after the block. Prints nothing and
# returns 0 when that holds.
injection_contained() {
  awk '
    /^::stop-commands::/ { if (token != "") bad = 1; token = substr($0, 18); next }
    token != "" && $0 == "::" token "::" { token = ""; closed = 1; next }
    /INJECTED/ && token == "" { bad = 1 }
    END { exit (bad || !closed || token != "") }
  ' <<<"$OUT"
}

run_verify injected injected
if [ "$RC" -ne 0 ] && injection_contained \
  && grep -qE "$HINT" <<<"$OUT" \
  && [ "$(grep -c '^::error::' <<<"$OUT")" -eq 1 ] && ! grep -q '^::warning::' <<<"$OUT"; then
  pass "vault text with workflow commands: murk output inside stop-commands, one error"
else
  fail "vault text with workflow commands: expected contained murk output and one error"
fi

# murk escapes line breaks in vault text, so no real vault starts a line with
# a workflow command. Cover that case with a murk that prints one.
mkdir -p "$WORK/raw-murk"
cat > "$WORK/raw-murk/murk" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '✕ vault parse error: x' '::error::INJECTED' '::warning::INJECTED' '::add-mask::INJECTED' >&2
exit 1
EOF
chmod +x "$WORK/raw-murk/murk"
PATH="$WORK/raw-murk:$PATH" run_verify raw-lines only-branch
if [ "$RC" -ne 0 ] && injection_contained && grep -qE "$HINT" <<<"$OUT" \
  && [ "$(grep -c '^::error::' <<<"$OUT")" -eq 2 ] \
  && [ "$(sed -n '/^::stop-commands::/,/^::[0-9a-f]*::$/p' <<<"$OUT" | grep -c '^::error::INJECTED$')" -eq 1 ]; then
  pass "murk output lines that are workflow commands: inside stop-commands"
else
  fail "murk output lines that are workflow commands: expected them inside stop-commands"
fi

exit "$FAILED"
