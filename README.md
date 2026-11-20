# murk-action

[![GitHub Marketplace](https://img.shields.io/badge/GitHub%20Marketplace-murk--action-2ea44f?logo=github&logoColor=white)](https://github.com/marketplace/actions/murk-action)

Decrypt [murk](https://github.com/interrupted-sh/murk) secrets and inject them
into your GitHub Actions workflow.

## Usage

```yaml
- uses: interrupted-sh/murk-action@v1
  with:
    murk-key: ${{ secrets.MURK_KEY }}
    trusted-signers: ${{ vars.MURK_TRUSTED_SIGNERS }}
```

Workflows that still use `interrupted-inc/murk-action` must switch to `interrupted-sh/murk-action`, because GitHub does not redirect action references after an organization rename.

All decrypted values are written to `$GITHUB_ENV` and masked in logs.
Subsequent steps can use them as regular environment variables.

```yaml
steps:
  - uses: actions/checkout@v4

  - uses: interrupted-sh/murk-action@v1
    with:
      murk-key: ${{ secrets.MURK_KEY }}
      trusted-signers: ${{ vars.MURK_TRUSTED_SIGNERS }}

  - run: echo "connected to $DATABASE_URL"
    # DATABASE_URL is available and its value is masked in logs
```

## Inputs

| Input             | Required | Default  | Description                            |
|-------------------|----------|----------|----------------------------------------|
| `murk-key`        | export   |          | Age secret key (`AGE-SECRET-KEY-1...`), or a whole grant key file; see [Agent grant keys](#agent-grant-keys). Not used in verify mode |
| `version`         | no       | `latest` | murk version, 0.10.2 or newer (e.g. `0.14.0`). 0.14 and later need `trusted-signers` or a whole grant key file |
| `vault`           | no       | `.murk`  | Path to vault file                     |
| `tags`            | no       |          | Space-separated tags to filter secrets |
| `trusted-signers` | no       |          | Signers trusted to sign the vault, one per line or comma-separated. Required by murk 0.14 and later; see below |
| `mode`            | no       | `export` | `export` decrypts the vault and exports its secrets. `verify` checks the vault's signature without a key and exports nothing; see [Check pull requests](#check-pull-requests). `verify` needs murk 0.15.2 or later |

## murk 0.14 and later

murk 0.14 loads a vault only if a signer that the machine trusts signed it.
A CI runner is a new machine with no trust record, so you must tell murk which
signers to trust. Supply the `trusted-signers` input:

```yaml
- uses: interrupted-sh/murk-action@v1
  with:
    murk-key: ${{ secrets.MURK_KEY }}
    trusted-signers: ${{ vars.MURK_TRUSTED_SIGNERS }}
```

Store the entries in a repository variable, for example
`MURK_TRUSTED_SIGNERS` (Settings → Secrets and variables → Actions →
Variables). Use one line for each teammate whose writes to the vault must load
in CI. To get an entry, each teammate runs this command in the repository:

```sh
murk trust --print-key
```

The command writes the entry to stdout and the signing-key fingerprint to
stderr. An age key's entry has the form `age1…:<verifying key>`. An
ssh-ed25519 key's entry is its public key line. A bare `age1…` recipient is
not a valid entry. The entries contain only public keys, so you can use a
variable for them and the action does not mask them.

The action sets `MURK_TRUSTED_SIGNERS` only for the murk commands that it runs.
Later steps that run murk themselves need the same value, as in the
[murk exec example](#use-with-murk-exec). If `MURK_TRUSTED_SIGNERS` is already
in the job's environment, the action uses it when the input is empty.

Without `trusted-signers`, murk 0.14 does not load the vault and the step
fails. The error tells you to set `trusted-signers`. The step also fails if no
entry matches the vault's signer, or if an entry has the wrong verifying key.
An unsigned vault always fails when you set trusted signers.

murk 0.13 and earlier ignore `trusted-signers`, so you can add the input before
you upgrade.

**Upgrade note:** the whole team must upgrade to murk 0.14 together. murk 0.14
writes vault format 3.0, which murk 0.13 cannot read. murk 0.14 is the current
release, so the default `version: latest` installs it. Set `trusted-signers` or
use a whole grant key file as `murk-key`, or pin `version: '0.13.0'` until your
team upgrades.

### Agent grant keys

You can give CI a grant key that reads only the secrets it needs, instead of
a teammate's key. Mint it and write the key file to stdout:

```sh
murk agent grant --name ci --only DATABASE_URL --ttl 30d --out -
```

Paste the whole output into the secret that you supply as `murk-key`,
including the comment lines:

```
# murk-trusted-signer: age1…:<verifying key>
# murk-grant-id: ci
# murk-grant-expires: 2026-11-20T12:00:00Z
AGE-SECRET-KEY-1…
```

The action gives the key file to murk unchanged and masks the
`AGE-SECRET-KEY-1` line. The comment lines contain only public data. The
`# murk-trusted-signer:` lines name the signers that the grant trusts, so a
grant key file does not need `trusted-signers`. murk refuses the grant after
the earlier of the key file's expiry and the vault's grant record.

A bare `AGE-SECRET-KEY-1` grant line still works, but then you must set
`trusted-signers`, only the vault's record limits the grant, and murk shows a
warning.

`trusted-signers` adds signers to the signers in the key file. It cannot remove
one. When you revoke a teammate, mint the grant again so that its key file no
longer names them. Run the same `murk agent grant` command with `--renew`,
replace the secret, and remove their entry from `trusted-signers`. Renew the
grant the same way before it expires. To end CI's access, run
`murk agent revoke ci`.

## Check pull requests

When two branches change the vault, the murk merge driver merges the two
vaults into one valid vault. GitHub does not run custom merge drivers. Its
merge button, merge queue and conflict editor merge the vault as text.

Two independent changes to a vault always conflict as text, because each
change rewrites the vault's MAC and signature lines. If someone resolves that
conflict without the merge driver, for example in the GitHub conflict editor,
the result is valid JSON but not a valid vault. murk refuses to load it, but
you find out only after the merge, on the base branch.

`mode: verify` finds that vault in the pull request. It needs no key, so it
also runs on pull requests from forks. Run it on the pull request's merge:

```yaml
name: Vault

on:
  pull_request:
  merge_group: # only if you use a merge queue

jobs:
  verify-vault:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: interrupted-sh/murk-action@v1
        with:
          mode: verify
          trusted-signers: ${{ vars.MURK_TRUSTED_SIGNERS }}
```

Then make `verify-vault` a required status check in the branch protection
rule or ruleset of the base branch.

GitHub does not give repository variables to workflows for pull requests
from forks. If you accept pull requests from forks, write the
`trusted-signers` entries in the workflow file instead. They contain only
public keys.

On a `pull_request` event, `actions/checkout` checks out the merge that
GitHub makes for the pull request (`refs/pull/N/merge`) by default. On a
`merge_group` event, it checks out the merge queue's merge. Do not set `ref`,
or the step checks the branch and not the merge.

In verify mode, the action installs murk and runs
`murk verify --signature-only` on the vault. murk reads no key and decrypts
nothing. It checks that the vault is valid and that its signature verifies
against an entry in `trusted-signers`. The action ignores `murk-key` in this
mode and sets no `keys` output. Verify mode needs murk 0.15.2 or later and
the `trusted-signers` input.

The step fails in these cases:

- The vault is not valid, or its signature does not verify. The error tells
  you that both branches changed the vault and that a merge without the murk
  merge driver cannot combine them.
- No entry in `trusted-signers` signed the vault, or the vault is unsigned.
  The error shows the reason from murk.

The check does not decrypt the vault, so it does not check the MAC inside the
encrypted metadata. murk checks the signature on the vault's fields after it
parses the file. A change to a field fails the check. A change to formatting,
or a field that murk does not know, can still pass. The check does not prove
the exact bytes of the file.

The check accepts a vault from any signer in `trusted-signers`. It does not
apply the rules for removed keys or group membership that murk applies on a
teammate's machine. When someone leaves the team, remove their entry from
`trusted-signers`, in the repository variable or in the workflow file. Until
you do, the check accepts vaults that they sign.

A pull request where only the branch changed the vault passes, if a signer in
`trusted-signers` wrote the change.

### Fix a pull request that fails the check

1. Run `murk setup-merge-driver` in your clone, if you have not done it yet.
2. If the branch contains a merge commit that broke the vault, remove it.
   For example, reset the branch to the commit before that merge.
3. Run `git fetch origin && git merge origin/<base branch>`. The murk merge
   driver merges the vault.
4. Push the branch. If you removed a commit in step 2, use
   `git push --force-with-lease`.
5. When the check passes, merge the pull request.

### What the check does not do

- It does not run while the pull request has a merge conflict. GitHub runs
  no `pull_request` workflows then, and it does not let you merge. Resolve the
  conflict locally with the steps above.
- It cannot check an unsigned vault. Vaults written before murk 0.14, or by
  ssh-rsa or plugin keys, have no signature.
- It checks the merge with the base branch at the time of the check. If the
  base branch changes the vault later, the result is out of date. To prevent
  this, require branches to be up to date before merging, or use a merge queue
  with the `merge_group` trigger.
- It does not merge vaults. A merged vault must be signed, and a grant key
  cannot sign. A merge in CI would need a teammate's full key, so the action
  does not do it.

## Examples

### Pin a version

```yaml
- uses: interrupted-sh/murk-action@v1
  with:
    murk-key: ${{ secrets.MURK_KEY }}
    version: '0.14.0'
    trusted-signers: ${{ vars.MURK_TRUSTED_SIGNERS }}
```

### Custom vault path

```yaml
- uses: interrupted-sh/murk-action@v1
  with:
    murk-key: ${{ secrets.MURK_KEY }}
    trusted-signers: ${{ vars.MURK_TRUSTED_SIGNERS }}
    vault: 'prod.murk'
```

### Filter by tags

```yaml
- uses: interrupted-sh/murk-action@v1
  with:
    murk-key: ${{ secrets.MURK_KEY }}
    trusted-signers: ${{ vars.MURK_TRUSTED_SIGNERS }}
    tags: 'deploy aws'
```

### Use with murk exec

If you prefer subprocess injection over `$GITHUB_ENV`:

```yaml
- uses: interrupted-sh/murk-action@v1
  with:
    murk-key: ${{ secrets.MURK_KEY }}
    trusted-signers: ${{ vars.MURK_TRUSTED_SIGNERS }} # murk 0.14 and later

- run: murk exec --vault .murk -- ./deploy.sh
  env:
    MURK_KEY: ${{ secrets.MURK_KEY }}
    MURK_TRUSTED_SIGNERS: ${{ vars.MURK_TRUSTED_SIGNERS }} # murk 0.14 and later
```

## How it works

1. Downloads the murk binary from GitHub Releases for the runner platform and verifies its checksum and build-provenance signature
2. In export mode, runs `murk export` to decrypt the vault, with `MURK_TRUSTED_SIGNERS` set from `trusted-signers` when given. In verify mode, runs `murk verify --signature-only` without a key and stops there
3. Masks each secret value with `::add-mask::`
4. Writes each key-value pair to `$GITHUB_ENV`

## Supported runners

- `ubuntu-latest` (x86_64, arm64)
- `macos-latest` (x86_64, arm64)

## Security

- `murk-key` should always come from a GitHub Actions secret
- All decrypted values are masked before being written anywhere
- The murk binary is downloaded over HTTPS from GitHub Releases
- The step fails if the binary's build-provenance signature is missing or invalid, so murk-action requires murk 0.10.2 or newer (older releases are not signed)
- No secrets are written to disk

## License

MIT OR Apache-2.0
