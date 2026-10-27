# Releasing

Checklist for cutting a new version. The mock-based test suite catches regressions in the behaviour we know how to model, but it can't catch netcup API contract drift, real busybox `crond` behaviour, or Alpine PHP differences. The smoke test in step 2 is what closes that gap — never tag without it.

For repeated releases, keep API credentials in a gitignored `.env.release` file at the repo root so step 2 doesn't require retyping them.

## 1. Pre-flight (everything in git)

- [ ] `bash tests/test.sh` → all green, 0 failed
- [ ] `const VERSION` in `functions.php:3` matches the tag you're about to cut
- [ ] CLI options table in `README.md` matches the `--help` output of `php update.php --help`
- [ ] `git status` clean, on `master`, up-to-date with `origin/master`

## 2. Smoke test (the part that catches what mocks can't)

Build a release-candidate image:

```bash
docker build -t dyndns:rc-$(git rev-parse --short HEAD) .
```

Run `--run-once --force` against a **throwaway subdomain** you own — not a record anything depends on. Both modes need to pass.

**Env-var mode** (covers entrypoint, env-var path, real netcup login, real cURL, real Alpine PHP):

```bash
set -a; source .env.release; set +a
docker run --rm \
  -e CUSTOMERNR -e APIKEY -e APIPASSWORD \
  -e "DOMAINLIST=$RELEASE_TEST_DOMAINLIST" \
  dyndns:rc-$(git rev-parse --short HEAD) --run-once --force
```

**File-mount mode** (covers the historical / NAS path):

```bash
docker run --rm \
  -v ./config.test.php:/app/config.php:ro \
  dyndns:rc-$(git rev-parse --short HEAD) --run-once --force
```

**CloudDNS DynDNS mode** (covers the wsDynDns.php path — the mock can't catch contract drift in the real endpoint). Requires a throwaway fqdn on a *CloudDNS-managed* domain; keep `RELEASE_TEST_CLOUDDNS_DOMAINLIST` and `CLOUDDNS_DYNDNS_APIKEY` in `.env.release`:

```bash
docker run --rm \
  -e "DOMAINLIST_CLOUDDNS_DYNDNS=$RELEASE_TEST_CLOUDDNS_DOMAINLIST" \
  -e CLOUDDNS_DYNDNS_APIKEY \
  dyndns:rc-$(git rev-parse --short HEAD) --run-once --force
```

Expect `Record(s) have been saved.` (or `No record update needed.` on a repeat run) and no `Logged in successfully` line — pure-CloudDNS runs must not open a CCP session. Skip this block only if no CloudDNS-managed domain is available to you, and say so in the release notes.

For each: confirm the run logs `Logged in successfully`, the expected `IPvN address has changed` or `hasn't changed`, `Logged out successfully`, and **no `PHP Warning`, `PHP Fatal`, or `Deprecated` lines** (the Alpine image's PHP is often newer than local PHP and surfaces fresh deprecations first). Then check the netcup CCP and verify the record actually has the IP the script reported.

Also run a short cron-mode start-up against the same `TZ` as an end-to-end gut check. Tests 52a (Dockerfile installs `tzdata`) and 65a (PHP code overrides a pinned `date.timezone`) cover the *intent* of both layers; this verifies the *built artifact* behaves accordingly — that the `tzdata` package actually made it into the layer, that an upstream `php:8-cli-alpine` change didn't slip a new default through, and that nothing in the runtime stack quietly swallows `TZ`:

```bash
docker run -d --rm --name dyndns-tz-check \
  -v ./config.test.php:/app/config.php:ro,z \
  -e TZ=Europe/Berlin \
  dyndns:rc-$(git rev-parse --short HEAD)
sleep 3
docker logs dyndns-tz-check | head -5
docker stop dyndns-tz-check
```

The startup `[YYYY/MM/DD HH:MM:SS ±HHMM]` line should show your `TZ`'s offset (e.g. `+0200` for Europe/Berlin in summer), not `+0000`. If it shows `+0000`, run tests 52a and 65a locally — one of them is now failing and will tell you which layer broke.

## 3. Tag and push

```bash
git tag -a "v$(grep -oP "VERSION = '\K[^']+" functions.php)" -m "<one-line summary>"
git push origin master
git push origin --tags
```

Open the new tag on the GitHub releases page, click **Create release from tag**, paste a summary lifted from `git log v<previous>..HEAD --oneline`. Publishing the release fires `.github/workflows/docker-publish.yml`, which builds and pushes the image to Docker Hub. (Tag-pushing alone does **not** trigger the publish — release publication does.)

## 4. Post-release verification

```bash
docker pull stecklars/dynamic-dns-netcup-api:v<new>
```

Restart your own deployment with the new tag and watch one full cron cycle:

```bash
docker compose up -d
docker logs -f dyndns
```

Expect a `Logged in successfully … Logged out successfully` cycle within `CRON_SCHEDULE`.

## 5. Rollback (only if step 4 surfaces a problem)

```bash
docker pull stecklars/dynamic-dns-netcup-api:v<previous>
# pin your compose `image:` line to v<previous>, then:
docker compose up -d
```

Mark the new release as a **pre-release** in the GitHub UI so users on `:latest` aren't pulled forward, and open an issue describing what broke.

## Rebuilding an image for a base-image security fix

The Dockerfile uses the floating `php:8-cli-alpine` tag, but images are only rebuilt when the publish workflow runs. When PHP or Alpine ship a security release (e.g. php2shell, issue #45), prefer cutting a patch release: it notifies users and gives them a clear version to upgrade to. When a new version isn't worth it, or users pinned to an older tag also need the fix, rebuild the existing release instead:

1. Wait until Docker Hub's `php:8-cli-alpine` points to the patched PHP (its digest matches the fixed `8.x.y-cli-alpine` tag).
2. Run the workflow by hand: `gh workflow run docker-publish.yml -f tag=v<current> -f latest=true` (or **Actions → Publish Docker image → Run workflow**). Set `latest=false` when rebuilding a tag that is not the newest release.
3. Check the result: `docker run --rm --entrypoint php stecklars/dynamic-dns-netcup-api:v<current> -v` should report the patched PHP version.

The workflow checks out the given tag, runs the test suite, and pushes a fresh build (`pull: true`, `no-cache: true`) under the same tags. Because the application code is unchanged, there's no new version and no smoke test. The smoke test is still a good idea if the PHP minor version changed (e.g. 8.4 → 8.5).

## What this checklist intentionally does NOT do

- No `CHANGELOG.md` format — release notes live in the GitHub release body, lifted from `git log`.
- No mandatory release cadence.
- No automated bump script — too many one-off decisions per release (which version bump, what release body, which subdomains to smoke against). The point of this file is to make the manual ritual unambiguous, not to remove it.
