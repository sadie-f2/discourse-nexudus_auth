# discourse-nexudus_auth

Authenticate Discourse users against a Nexudus coworking instance via the Nexudus REST API.

## How it works

1. User submits email + password on a custom OmniAuth form
2. Email is looked up in a paginated, in-process member cache (sourced from `/billing/coworkercontracts`)
3. Password is verified against the Nexudus public token endpoint (`/{space}.spaces.nexudus.com/api/token`)
4. On success, the user is logged into Discourse and added to the configured member group

API calls shell out to `curl` rather than using Ruby's `Net::HTTP` — see **TLS fingerprint note** below.

## Environment variables

| Variable | Description |
|---|---|
| `NEXUDUS_BASE_URL` | API base, default `https://spaces.nexudus.com/api` |
| `NEXUDUS_EMAIL` | Admin email for basic auth |
| `NEXUDUS_PASSWORD` | Admin password for basic auth |
| `NEXUDUS_BOOKING_TOKEN` | Bearer token (alternative to basic auth, leave blank to use basic) |
| `NEXUDUS_SPACE` | Space subdomain, e.g. `artisans` for `artisans.spaces.nexudus.com` |

Set permanently in `app.yml` (`env:` block) and rebuild. Temporary workaround: add to `/etc/default/discourse` — survives restarts but not a full `./launcher rebuild app`.

## Site settings

| Setting | Default | Description |
|---|---|---|
| `nexudus_auth_enabled` | `true` | Enable/disable the provider |
| `nexudus_auth_group` | `makerspace-members` | Discourse group members are added to on login |
| `nexudus_auth_diagnostics` | `false` | Show diagnostic output on failed login — **dev/debug only, never leave on in production** |

## TLS fingerprint note

Ruby's `Net::HTTP` (via OpenSSL) presents a TLS ClientHello fingerprint that Nexudus's CloudFront WAF blocks. All Nexudus API calls therefore shell out to `curl`, which uses libssl and is not blocked.

**On Ubuntu 24 upgrade:** test `probe_auth.rb` against the Nexudus API before assuming curl is still needed. The Ruby + OpenSSL version change may produce a fingerprint that is no longer blocked — if so, the `Open3.capture3('curl', ...)` calls in `lib/nexudus_membership_provider.rb` can be replaced with clean `Net::HTTP`, removing the subprocess overhead and simplifying error handling.

## Known limitations

### Show/hide password toggle

The form uses a custom `request_phase` (not `OmniAuth::Form`) with an inline `<script>` toggle.

**Why not a `<script src="...">` file?** Discourse's CSP uses `strict-dynamic`, not `'self'` — same-origin script URLs are still blocked without a nonce. Nonces aren't available at OmniAuth middleware depth (`action_dispatch.content_security_policy_nonce` is not populated there).

**Current approach:** the toggle script is an inline `<script>` block. Its SHA-256 hash is computed at load time from the constant `NEXUDUS_TOGGLE_JS` and registered with Discourse's CSP via `extend_content_security_policy(script_src: [NEXUDUS_TOGGLE_JS_CSP_HASH])` in `plugin.rb`. CSP allows an inline script whose content matches a whitelisted hash without needing a nonce. **If the script content ever changes, the constant and the hash update together automatically** — no manual hash management.

**Earlier failed approaches (for reference):**
- Inline `onclick` attribute — blocked by CSP
- `<script>` block with `addEventListener` — blocked by CSP (no hash registered)
- Nonce via `action_dispatch.content_security_policy_nonce` — nonce not populated at OmniAuth depth
- `autocomplete="current-password"` on custom form — caused browsers to autofill with the visual mask string (`••••••••`), breaking `verify_password`; current form omits `autocomplete` on the password field

**Upgrade note:** if Discourse ever changes how `extend_content_security_policy` is processed or stops applying the global CSP to OmniAuth middleware responses, the toggle will silently stop working (no crash — the script is just ignored). The fix would be to adopt plan 3 below.

**Architectural alternatives (in order of effort):**

1. **(done)** SHA-256 hash of inline script via `extend_content_security_policy` — current implementation.

2. **(1-2 days)** Use a Discourse plugin outlet inside the login modal's Ember template to inject a show/hide toggle into the OmniAuth popup's password field.

3. **(2-3 days)** Move the Nexudus email/password fields into Discourse's own login modal as an Ember component, POST to the OmniAuth callback via `fetch`, handle the result in JS. Eliminates the popup entirely and all CSP constraints with it. Architecturally correct long-term target.

## Architectural retrospective: OAuth2 provider

In hindsight, the cleanest approach would have been to run a standalone OAuth2 authorization server backed by the Nexudus API, rather than embedding auth logic inside a Discourse plugin.

This plugin already contains the two hard pieces of that server:

- **Identity**: paginated member cache keyed by email, sourced from the Nexudus contracts API
- **Credential verification**: `verify_password` against the Nexudus token endpoint, including the `curl` workaround for the TLS fingerprint block

Wrapping those in a standard OAuth2 authorization code flow would produce a first-party **"Log in with Artisans Asylum"** provider. Any internal tool — Discourse, door access, equipment booking, whatever comes next — could authenticate against it without independently reimplementing the Nexudus API, the pagination, the rate-limit handling, or the TLS workaround.

The current implementation also spans two languages (Ruby for the Discourse plugin, Python for the reporting scripts in the companion repo), with duplicated Nexudus API client logic in each. A shared OAuth2 provider would have been the single point of integration.

This is a meaningful refactor, not a quick fix. Noted here as the long-term target if the makerspace adds more tools that need Nexudus-backed auth.

## Cache architecture

Member data is cached in a class variable (`@@cache`) per Pitchfork worker process, with a 300-second TTL. The cache warms at boot via a background thread. Multiple concurrent requests during a cache-expired window are serialized by a `Mutex` (per-process).

**Known limitation:** each Pitchfork worker holds its own independent cache after fork. Workers can briefly disagree on membership during the TTL window after a Nexudus data change. At typical makerspace traffic levels this is acceptable; if real-time cross-worker consistency is needed, migrate to `Rails.cache` (Redis-backed, shared across all workers).
