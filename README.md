# Scoped Gmail Sender

**Scripts:** `Create-OrUpdate-ScopedGmailSender.ps1`, `Send-ScopedGmailMessage.ps1`  
**Version:** `1.0.0`

Companion to [scoped-graph-mail-sender](https://github.com/NEOnetOH/scoped-graph-mail-sender) for Google Workspace.

## Purpose

These PowerShell scripts create or update a **single-mailbox** Gmail send configuration for MFA/OTP, notifications, and other service-to-service mail scenarios.

The Microsoft companion authorizes an existing Exchange mailbox with Exchange Application RBAC. This Google companion authorizes an existing Workspace Gmail mailbox with OAuth `gmail.send` and a securely stored refresh token.

The scripts are organization-agnostic. They prompt for the sender mailbox and OAuth client material, then guide consent as that mailbox.

> **Security:** Prefer a dedicated Workspace user and a mailbox-authorized refresh token. Do **not** use a service account with domain-wide delegation for this requirement. Delegation can impersonate users across the domain within its scopes and does not enforce the same single-mailbox boundary as signing in as the sender.

## Microsoft vs Google

| Component | Microsoft (`scoped-graph-mail-sender`) | Google (`scoped-gmail-sender`) |
| --- | --- | --- |
| Sender | Existing Exchange mailbox | Dedicated Workspace user with Gmail enabled |
| Application | Entra app registration | Google Cloud project and OAuth Desktop client |
| Send permission | Application `Mail.Send` via Exchange RBAC | `gmail.send` |
| Mailbox restriction | Exchange Application RBAC scope | Token authorized by the specific sender account |
| Unattended operation | Client credentials | Securely stored refresh token |
| Initial authorization | Administrator configuration | Sign in as the sender and grant consent |

Google’s `gmail.send` scope permits sending without granting permission to read or delete mail. See [Gmail API scopes](https://developers.google.com/gmail/api/auth/scopes).

## Capabilities

- Guide Google Cloud / Workspace setup for a dedicated sender mailbox.
- Load an OAuth Desktop client secrets JSON (refuses service-account keys).
- Authorize offline access as the sender with `gmail.send` + `openid`/`email`.
- Store a refresh token (DPAPI-protected on Windows by default).
- Validate that the authorized Google account matches the configured mailbox.
- Refuse broader Gmail scopes if they appear on the token.
- Run a read-only preflight.
- Send a test message during setup or via `Send-ScopedGmailMessage.ps1`.
- Report the script version.
- Check a GitHub raw file for a newer version and self-update the setup script.

## Security model

```text
Dedicated Workspace mailbox
  -> Google OAuth consent (as that mailbox)
  -> refresh token (gmail.send)
  -> Gmail API users/me/messages/send
  -> mail sent only as the authorized account
```

Do not substitute domain-wide delegation and then “set From” in application code. The boundary is the account that granted consent.

## Prerequisites

- PowerShell 7.0 or later.
- Internet access to Google OAuth and the Gmail API.
- An existing Google Workspace sender mailbox (primary address). The scripts authorize that mailbox; they do not create it.
- A Google Cloud project with the Gmail API enabled.
- An **Internal** OAuth consent screen for your organization.
- An OAuth client of type **Desktop app**, with the client secrets JSON available to the setup host.
- Ability to sign in interactively as the sender mailbox once (or again after revocation).

## Quick start

1. Create or select the dedicated sender mailbox in Google Workspace Admin.
2. In Google Cloud Console: create/select a project, enable **Gmail API**, configure an **Internal** OAuth app, create a **Desktop** OAuth client, and download the JSON.
3. Place the JSON somewhere local (for example `.\credentials\client_secret.json`). Never commit real secrets.
4. Run a read-only preflight:

```powershell
.\Create-OrUpdate-ScopedGmailSender.ps1 -PreflightOnly `
  -Mailbox "noreply@contoso.com" `
  -ClientSecretsPath ".\credentials\client_secret.json"
```

5. Authorize and optionally test-send:

```powershell
.\Create-OrUpdate-ScopedGmailSender.ps1 `
  -Mailbox "noreply@contoso.com" `
  -AppDisplayName "Contoso MFA Mail" `
  -ClientSecretsPath ".\credentials\client_secret.json" `
  -TestSend `
  -TestSendTo "admin@contoso.com"
```

Sign in as `noreply@contoso.com` in the browser consent prompt.

## Operational send

```powershell
.\Send-ScopedGmailMessage.ps1 `
  -Mailbox "noreply@contoso.com" `
  -To "user@contoso.com" `
  -Subject "Your sign-in code" `
  -BodyText "Your code is 123456"
```

By default the token store is:

```text
%LOCALAPPDATA%\ScopedGmailSender\<mailbox>.token.dpapi
```

## Create and update behavior

`-Mode Auto` is the default.

- **Auto**: Uses an existing token store when present and still valid; otherwise authorizes.
- **Create**: Requires no existing token store unless `-ForceReauthorize` is set.
- **Update**: Requires an existing token store (or `-ForceReauthorize`).

Force a fresh consent:

```powershell
.\Create-OrUpdate-ScopedGmailSender.ps1 `
  -Mode Update `
  -ForceReauthorize `
  -Mailbox "noreply@contoso.com" `
  -ClientSecretsPath ".\credentials\client_secret.json"
```

## Token storage

| Option | Behavior |
| --- | --- |
| Default (Windows) | DPAPI `CurrentUser` protected binary file |
| `-PlainTextTokenStore` | JSON on disk (use only with strong OS ACLs / secrets tooling) |

The token store includes the OAuth client id/secret and refresh token so unattended refresh works. Treat it like a password.

Refresh tokens can be revoked or become invalid after password changes, admin revoke, app deletion, or Google unused-token policies. Keep a reauthorization procedure.

## Versioning

The public setup filename remains stable:

```text
Create-OrUpdate-ScopedGmailSender.ps1
```

The semantic version is stored inside the script. The initial GitHub release is:

```text
1.0.0
```

```powershell
.\Create-OrUpdate-ScopedGmailSender.ps1 -Version
.\Create-OrUpdate-ScopedGmailSender.ps1 -v
```

## GitHub update checking

```powershell
.\Create-OrUpdate-ScopedGmailSender.ps1 -CheckForUpdate

.\Create-OrUpdate-ScopedGmailSender.ps1 -UpdateFromGitHub
```

Self-update replaces the setup script and keeps a `.bak` backup. If `lib\ScopedGmailSender.Common.ps1` also changed, pull the full repository.

## Parameter reference

### `Create-OrUpdate-ScopedGmailSender.ps1`

| Parameter | Purpose | Default / Notes |
| --- | --- | --- |
| `-Version` / `-v` | Show the internal script version and exit. | `1.0.0` |
| `-CheckForUpdate` | Compare local version to a GitHub raw file. | Uses `$DefaultGitHubRawUrl` when set. |
| `-UpdateFromGitHub` | Install a newer GitHub copy of the setup script. | Creates a `.bak` backup. |
| `-GitHubRawUrl` | Override raw GitHub URL. | Optional. |
| `-Mode` | `Auto`, `Create`, or `Update`. | `Auto` |
| `-AppDisplayName` | Friendly name for checklist / token metadata. | Prompted if omitted. |
| `-Mailbox` | Single sender mailbox to authorize. | Prompted; primary address required. |
| `-ClientSecretsPath` | Desktop OAuth client secrets JSON. | Prompted / discovered. |
| `-TokenStorePath` | Where to save the refresh token store. | `%LOCALAPPDATA%\ScopedGmailSender\...` |
| `-ForceReauthorize` | Force a new browser consent. | Switch. |
| `-PlainTextTokenStore` | Skip DPAPI protection. | Switch. |
| `-TestSend` | Send a test message after setup. | Switch. |
| `-TestSendTo` | Test recipient. | Prompted when testing. |
| `-PreflightOnly` | Validation without authorization changes. | Switch. |

### `Send-ScopedGmailMessage.ps1`

| Parameter | Purpose |
| --- | --- |
| `-TokenStorePath` | Explicit token store path. |
| `-Mailbox` | Resolve the default token path / validate sender. |
| `-To` / `-Subject` / `-BodyText` / `-BodyHtml` | Message fields. |
| `-DryRun` | Build the MIME payload without calling Gmail. |

## Successful-run checks

A successful setup should show:

- Client secrets are a Desktop OAuth client (not a service account).
- Browser consent completed as the intended sender.
- Authorized email matches the configured mailbox.
- Granted scopes include `gmail.send` and do not include broad Gmail modify/read scopes.
- Optional test send returns a Gmail message id.

The send API is:

```text
POST https://gmail.googleapis.com/gmail/v1/users/me/messages/send
```

Use `users/me` with the mailbox-authorized token. Do not impersonate other users.

## Troubleshooting

| Symptom | Action |
| --- | --- |
| Service account JSON rejected | Download a Desktop OAuth client JSON instead. Do not enable domain-wide delegation for this project. |
| No refresh token returned | Revoke the app under the Google Account’s third-party access, then re-run with `-ForceReauthorize`. |
| Authorized account mismatch | Sign in as the sender mailbox, not an admin’s personal account. |
| `invalid_grant` on refresh | Token revoked or expired; re-authorize. |
| Browser does not open | Copy the printed authorization URL manually. |
| Loopback redirect fails | Allow local HTTP listener use; corporate proxies can interfere with `127.0.0.1`. |
| Need to send as another mailbox | Authorize that mailbox separately. Do not widen to domain-wide delegation. |

## Operational recommendations

- Store client secrets and token files in an approved secrets/password-management system when hosts are shared.
- Never commit client secrets, refresh tokens, access tokens, or real mailbox addresses to GitHub.
- Run `-PreflightOnly` before planned changes.
- After reauthorization, validate the consuming application before deleting the previous token store.
- Document who can sign in as the sender mailbox and how to rotate consent.
- Review the configuration when the sender mailbox changes or the application is retired.

## Public repository privacy checklist

Before each GitHub release:

- Search scripts and documentation for real email addresses.
- Search for client ids/secrets, refresh tokens, and access tokens.
- Use only fictional example domains such as `contoso.com`.
- Keep real console output and screenshots out of the public repository.
- Review Git history as well as the current files.

## Google documentation

- Gmail API overview: https://developers.google.com/gmail/api
- Gmail API scopes: https://developers.google.com/gmail/api/auth/scopes
- OAuth 2.0 for desktop apps: https://developers.google.com/identity/protocols/oauth2/native-app
- Using OAuth 2.0 to access Google APIs: https://developers.google.com/identity/protocols/oauth2
- Domain-wide delegation (avoid for this design): https://support.google.com/a/answer/162106
- Send message: https://developers.google.com/gmail/api/reference/rest/v1/users.messages/send

## Related project

- Microsoft Graph / Exchange Application RBAC companion: https://github.com/NEOnetOH/scoped-graph-mail-sender

## Change record

| Version | Notes |
| --- | --- |
| `1.0.0` | Initial public GitHub release. Guided setup, Desktop OAuth authorization, DPAPI token store, sender validation, preflight, test send, operational send helper, version reporting, and GitHub update checking. |
