<#
.SYNOPSIS
Creates or updates a single-mailbox Google Workspace Gmail send configuration using
OAuth (gmail.send) and a securely stored refresh token.

.DESCRIPTION
This is an organization-agnostic, idempotent setup/update script with a stable
filename and an internal semantic version for GitHub distribution and synchronization.

It can:
 - guide creation of a Google Cloud OAuth Desktop client for Gmail API access
 - authorize offline access as one dedicated sender mailbox
 - store a refresh token (DPAPI-protected on Windows by default)
 - validate that the authorized Google account matches the configured sender
 - refuse service-account / domain-wide-delegation credential files
 - run a read-only preflight
 - optionally send a test message
 - report its internal version with -Version
 - compare itself with a GitHub raw file using -CheckForUpdate
 - update itself from a GitHub raw file using -UpdateFromGitHub

IMPORTANT
Prefer a dedicated Workspace user mailbox and a mailbox-authorized OAuth refresh
token. Do not use a service account with domain-wide delegation for this
requirement. Delegation can impersonate users across the domain within its
authorized scopes and does not provide the same enforced single-mailbox boundary
as signing in as the sender.

.EXAMPLE
# Interactive create-or-update mode:
.\Create-OrUpdate-ScopedGmailSender.ps1

.EXAMPLE
# Read-only preflight:
.\Create-OrUpdate-ScopedGmailSender.ps1 -PreflightOnly

.EXAMPLE
# Authorize and send a test message:
.\Create-OrUpdate-ScopedGmailSender.ps1 `
  -Mailbox "noreply@contoso.com" `
  -ClientSecretsPath ".\credentials\client_secret.json" `
  -TestSend `
  -TestSendTo "admin@contoso.com"

.EXAMPLE
# Show the script version:
.\Create-OrUpdate-ScopedGmailSender.ps1 -Version

.EXAMPLE
# Check the GitHub copy for a newer version:
.\Create-OrUpdate-ScopedGmailSender.ps1 `
  -CheckForUpdate `
  -GitHubRawUrl "https://raw.githubusercontent.com/OWNER/REPOSITORY/main/Create-OrUpdate-ScopedGmailSender.ps1"
#>

[CmdletBinding()]
param(
    [Alias('v')]
    [switch]$Version,

    [switch]$CheckForUpdate,

    [switch]$UpdateFromGitHub,

    [string]$GitHubRawUrl = "",

    [ValidateSet('Auto', 'Create', 'Update')]
    [string]$Mode = 'Auto',

    [string]$AppDisplayName = "",

    [string]$Mailbox = "",

    [string]$ClientSecretsPath = "",

    [string]$TokenStorePath = "",

    [switch]$ForceReauthorize,

    [switch]$PlainTextTokenStore,

    [switch]$TestSend,

    [string]$TestSendTo = "",

    [switch]$PreflightOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptIdentity = 'ScopedGmailSender'
$ScriptName = 'Create-OrUpdate-ScopedGmailSender.ps1'
$ScriptVersion = [version]'1.0.0'

# Optional: set this once after publishing the script to GitHub. If left blank,
# callers can provide -GitHubRawUrl when checking/updating.
$DefaultGitHubRawUrl = 'https://raw.githubusercontent.com/NEOnetOH/scoped-gmail-sender/main/Create-OrUpdate-ScopedGmailSender.ps1'

$commonPath = Join-Path $PSScriptRoot 'lib\ScopedGmailSender.Common.ps1'
if (-not (Test-Path -LiteralPath $commonPath)) {
    throw "Missing shared library: $commonPath"
}
. $commonPath

# ---------------------------------------------------------------------------
# Script version / GitHub synchronization
# ---------------------------------------------------------------------------

function Resolve-GitHubRawUrl {
    if (-not [string]::IsNullOrWhiteSpace($GitHubRawUrl)) {
        return $GitHubRawUrl.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($DefaultGitHubRawUrl)) {
        return $DefaultGitHubRawUrl.Trim()
    }

    throw @"
No GitHub raw URL is configured.

Either:
 1. Pass -GitHubRawUrl with the raw GitHub URL, or
 2. Set `$DefaultGitHubRawUrl near the top of this script.

Expected form:
https://raw.githubusercontent.com/OWNER/REPOSITORY/main/Create-OrUpdate-ScopedGmailSender.ps1
"@
}

function Get-RemoteScriptRelease {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RawUrl
    )

    Info "Reading release metadata from GitHub..."

    $response = Invoke-WebRequest `
        -Uri $RawUrl `
        -UseBasicParsing `
        -ErrorAction Stop

    $remoteText = [string]$response.Content

    if ([string]::IsNullOrWhiteSpace($remoteText)) {
        throw "GitHub returned an empty script."
    }

    $identityPattern = [regex]::Escape('$ScriptIdentity') +
        "\s*=\s*['""]ScopedGmailSender['""]"

    if ($remoteText -notmatch $identityPattern) {
        throw "The GitHub file does not identify itself as '$ScriptIdentity'. Update aborted."
    }

    $versionPattern = [regex]::Escape('$ScriptVersion') +
        "\s*=\s*\[version\]\s*['""](?<Version>\d+\.\d+\.\d+)['""]"

    $match = [regex]::Match($remoteText, $versionPattern)

    if (-not $match.Success) {
        throw "Could not read the remote script version."
    }

    [pscustomobject]@{
        Version = [version]$match.Groups['Version'].Value
        Content = $remoteText
        Url     = $RawUrl
    }
}

function Show-ScriptVersion {
    Write-Output "$ScriptName $ScriptVersion"
}

function Invoke-GitHubVersionCheck {
    param(
        [switch]$InstallUpdate
    )

    $rawUrl = Resolve-GitHubRawUrl
    $remote = Get-RemoteScriptRelease -RawUrl $rawUrl

    Write-Host ""
    Write-Host "Script         : $ScriptName"
    Write-Host "Local version  : $ScriptVersion"
    Write-Host "GitHub version : $($remote.Version)"
    Write-Host "GitHub source  : $rawUrl"

    if ($remote.Version -lt $ScriptVersion) {
        Warn "The GitHub copy is older than this local copy."
        return
    }

    if ($remote.Version -eq $ScriptVersion) {
        Pass "This script is already current."
        return
    }

    Warn "A newer version is available: $($remote.Version)"

    if (-not $InstallUpdate) {
        Info "Run with -UpdateFromGitHub to install it."
        return
    }

    if ([string]::IsNullOrWhiteSpace($PSCommandPath) -or
        -not (Test-Path -LiteralPath $PSCommandPath)) {
        throw "The running script path could not be determined, so self-update is unavailable."
    }

    $currentPath = [IO.Path]::GetFullPath($PSCommandPath)
    $directory = Split-Path -Parent $currentPath
    $fileName = Split-Path -Leaf $currentPath
    $backupPath = "$currentPath.bak"
    $stagingPath = Join-Path $directory ".$fileName.update"

    [IO.File]::WriteAllText($stagingPath, $remote.Content)

    $staged = Get-Content -LiteralPath $stagingPath -Raw
    $stagedIdentityPattern = [regex]::Escape('$ScriptIdentity') +
        "\s*=\s*['""]ScopedGmailSender['""]"
    if ($staged -notmatch $stagedIdentityPattern) {
        Remove-Item -LiteralPath $stagingPath -Force -ErrorAction SilentlyContinue
        throw "Staged update failed identity validation."
    }

    if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Force
    }

    Copy-Item -LiteralPath $currentPath -Destination $backupPath -Force
    Move-Item -LiteralPath $stagingPath -Destination $currentPath -Force

    Pass "Updated $fileName to $($remote.Version)"
    Info "Previous copy saved as: $backupPath"
    Warn "If lib\ScopedGmailSender.Common.ps1 also changed, pull the full repository."
}

# ---------------------------------------------------------------------------
# Guided Google Cloud setup
# ---------------------------------------------------------------------------

function Show-GoogleCloudChecklist {
    param(
        [string]$SuggestedAppName
    )

    Section "Google Cloud / Workspace checklist"

    Write-Host @"
Complete these steps in Google Cloud Console and Google Workspace Admin before
continuing. The script does not create Workspace users or Cloud projects for you.

1. Create or select a dedicated Workspace user with Gmail enabled
   Example: noreply@contoso.com
   This must be a real mailbox. The script authorizes that account; it does not
   create the mailbox.

2. Create a Google Cloud project for this mail sender.
   Suggested name: $SuggestedAppName

3. Enable the Gmail API on that project.

4. Configure the OAuth consent screen:
   - User type: Internal (Workspace organization)
   - App name: $SuggestedAppName
   - Scopes to add later during OAuth: gmail.send, openid, email
   - Do NOT enable domain-wide delegation for this use case

5. Create an OAuth client:
   - Application type: Desktop app
   - Download the client secrets JSON

6. Sign in as the dedicated sender during the script's browser consent prompt.
   An administrator account is not a substitute for the sender mailbox.

Documentation:
 - Gmail API: https://developers.google.com/gmail/api
 - OAuth for desktop apps: https://developers.google.com/identity/protocols/oauth2/native-app
 - gmail.send scope: https://developers.google.com/gmail/api/auth/scopes
 - Avoid domain-wide delegation here: https://support.google.com/a/answer/162106
"@
}

function Read-RequiredMailAddress {
    param(
        [string]$Prompt,
        [string]$Current = ""
    )

    while ($true) {
        $value = $Current
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = Read-Host $Prompt
        }

        if (Test-MailAddress $value) {
            return $value.Trim()
        }

        Write-Host "Enter a valid email address." -ForegroundColor Yellow
        $Current = ""
    }
}

function Resolve-ClientSecretsPath {
    param(
        [string]$Path
    )

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $full = [IO.Path]::GetFullPath($Path)
        if (-not (Test-Path -LiteralPath $full)) {
            throw "Client secrets path not found: $full"
        }
        return $full
    }

    $candidates = @(
        (Join-Path $PSScriptRoot 'credentials\client_secret.json'),
        (Join-Path (Get-Location) 'client_secret.json'),
        (Join-Path (Get-Location) 'credentials\client_secret.json')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            Info "Found client secrets: $candidate"
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    Write-Host ""
    Write-Host "Locate the Desktop OAuth client secrets JSON downloaded from Google Cloud." -ForegroundColor Cyan
    $entered = Read-Host "Path to client_secret JSON"
    if ([string]::IsNullOrWhiteSpace($entered)) {
        throw "Client secrets path is required."
    }

    $full = [IO.Path]::GetFullPath($entered.Trim('"'))
    if (-not (Test-Path -LiteralPath $full)) {
        throw "Client secrets path not found: $full"
    }

    return $full
}

function Invoke-GoogleDesktopAuthorization {
    param(
        [Parameter(Mandatory = $true)]$ClientSecrets,
        [Parameter(Mandatory = $true)][string]$Mailbox,
        [Parameter(Mandatory = $true)][string[]]$Scopes
    )

    $port = Get-FreeLoopbackPort
    $redirectUri = "http://127.0.0.1:$port/"
    $state = [guid]::NewGuid().ToString('N')
    $scopeString = ($Scopes -join ' ')

    $authQuery = @{
        client_id               = $ClientSecrets.ClientId
        redirect_uri            = $redirectUri
        response_type           = 'code'
        scope                   = $scopeString
        access_type             = 'offline'
        include_granted_scopes  = 'false'
        prompt                  = 'consent select_account'
        state                   = $state
        login_hint              = $Mailbox
    }

    $query = ($authQuery.GetEnumerator() | ForEach-Object {
            '{0}={1}' -f [Uri]::EscapeDataString([string]$_.Key), [Uri]::EscapeDataString([string]$_.Value)
        }) -join '&'

    $authUrl = "$($ClientSecrets.AuthUri)?$query"

    $listener = [Net.HttpListener]::new()
    $listener.Prefixes.Add($redirectUri)
    $listener.Start()

    try {
        Section "Authorize as $Mailbox"
        Info "Opening the browser for Google OAuth consent..."
        Info "If the browser does not open, visit:"
        Write-Host $authUrl -ForegroundColor Yellow
        Info "Sign in as $Mailbox and approve gmail.send (plus openid/email)."

        Start-Process $authUrl | Out-Null

        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        $errorParam = $request.QueryString['error']
        $code = $request.QueryString['code']
        $returnedState = $request.QueryString['state']

        $html = '<html><body style="font-family:sans-serif;padding:2rem"><h2>Authorization complete</h2><p>You can close this window and return to PowerShell.</p></body></html>'
        if ($errorParam) {
            $html = "<html><body style=`"font-family:sans-serif;padding:2rem`"><h2>Authorization failed</h2><p>$errorParam</p></body></html>"
        }

        $buffer = [Text.Encoding]::UTF8.GetBytes($html)
        $response.ContentLength64 = $buffer.Length
        $response.ContentType = 'text/html; charset=utf-8'
        $response.OutputStream.Write($buffer, 0, $buffer.Length)
        $response.OutputStream.Close()

        if ($errorParam) {
            throw "Google OAuth error: $errorParam"
        }

        if ([string]::IsNullOrWhiteSpace($code)) {
            throw "Google OAuth response did not include an authorization code."
        }

        if (-not [string]::Equals($returnedState, $state, [StringComparison]::Ordinal)) {
            throw "OAuth state mismatch. Aborting."
        }

        Info "Exchanging authorization code for tokens..."

        $tokenResponse = Invoke-GoogleTokenRequest -TokenUri $ClientSecrets.TokenUri -Body @{
            code          = $code
            client_id     = $ClientSecrets.ClientId
            client_secret = $ClientSecrets.ClientSecret
            redirect_uri  = $redirectUri
            grant_type    = 'authorization_code'
        }

        if ([string]::IsNullOrWhiteSpace([string]$tokenResponse.refresh_token)) {
            throw @"
Google did not return a refresh_token.

This usually means the account already authorized the client without offline
access. Re-run with -ForceReauthorize (prompt=consent is already requested), or
revoke the app under Google Account > Security > Third-party access and try again.
"@
        }

        Assert-GmailSendScopePresent -GrantedScope ([string]$tokenResponse.scope)

        $authorizedEmail = Get-GoogleAuthorizedEmail -AccessToken ([string]$tokenResponse.access_token)
        Assert-SenderMatchesMailbox -AuthorizedEmail $authorizedEmail -Mailbox $Mailbox

        [pscustomobject]@{
            AccessToken     = [string]$tokenResponse.access_token
            RefreshToken    = [string]$tokenResponse.refresh_token
            Scope           = [string]$tokenResponse.scope
            AuthorizedEmail = $authorizedEmail
            ExpiresIn       = [int]$tokenResponse.expires_in
        }
    }
    finally {
        if ($listener.IsListening) {
            $listener.Stop()
        }
        $listener.Close()
    }
}

function Invoke-Preflight {
    param(
        [string]$MailboxValue,
        [string]$SecretsPath,
        [string]$StorePath
    )

    Section "Preflight (read-only)"

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "PowerShell 7.0 or later is required. Detected: $($PSVersionTable.PSVersion)"
    }
    Pass "PowerShell $($PSVersionTable.PSVersion)"

    if (-not (Test-MailAddress $MailboxValue)) {
        throw "Mailbox is missing or invalid."
    }
    Pass "Mailbox format: $MailboxValue"

    if ([string]::IsNullOrWhiteSpace($SecretsPath) -or -not (Test-Path -LiteralPath $SecretsPath)) {
        Warn "Client secrets JSON not found yet."
    }
    else {
        $secrets = Get-GoogleClientSecrets -Path $SecretsPath
        Pass "Desktop OAuth client secrets readable ($($secrets.ClientId.Substring(0, [Math]::Min(12, $secrets.ClientId.Length)))...)"
    }

    if (-not [string]::IsNullOrWhiteSpace($StorePath) -and (Test-Path -LiteralPath $StorePath)) {
        $store = ConvertFrom-SecurePlainJson -Path $StorePath
        if ([string]$store.scriptIdentity -ne $ScriptIdentity) {
            throw "Token store identity mismatch at $StorePath"
        }
        Pass "Existing token store found for $($store.authorizedEmail)"
        if (-not [string]::Equals(
                [string]$store.mailbox,
                $MailboxValue,
                [StringComparison]::OrdinalIgnoreCase)) {
            Warn "Token store mailbox '$($store.mailbox)' differs from requested '$MailboxValue'."
        }
    }
    else {
        Info "No token store present yet (expected for first-time setup)."
    }

    Warn "Domain-wide delegation / service-account keys are intentionally unsupported."
    Pass "Preflight completed with no tenant changes."
}

function Invoke-TestSend {
    param(
        [Parameter(Mandatory = $true)][psobject]$TokenStore,
        [Parameter(Mandatory = $true)][string]$To
    )

    Section "Test send"
    $access = Get-GoogleAccessToken -TokenStore $TokenStore
    Assert-GmailSendScopePresent -GrantedScope $access.Scope

    $raw = New-GmailRawMessage `
        -From $TokenStore.mailbox `
        -To $To `
        -Subject "Scoped Gmail Sender test $($ScriptVersion)" `
        -BodyText @"
This is a test message from Scoped Gmail Sender $ScriptVersion.

Sender mailbox: $($TokenStore.mailbox)
Authorized account: $($TokenStore.authorizedEmail)

If you received this, gmail.send with the stored refresh token is working.
"@

    $result = Send-ScopedGmailRaw -AccessToken $access.AccessToken -RawMessage $raw
    Pass "Test message accepted by Gmail. id=$($result.id)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if ($Version) {
    Show-ScriptVersion
    return
}

if ($CheckForUpdate -or $UpdateFromGitHub) {
    Invoke-GitHubVersionCheck -InstallUpdate:$UpdateFromGitHub
    return
}

Section "Scoped Gmail Sender $ScriptVersion"

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7.0 or later is required."
}

if ([string]::IsNullOrWhiteSpace($AppDisplayName)) {
    $AppDisplayName = Read-Host "Google Cloud / OAuth application display name (example: Contoso MFA Mail)"
    if ([string]::IsNullOrWhiteSpace($AppDisplayName)) {
        $AppDisplayName = 'Scoped Gmail Sender'
    }
}

$Mailbox = Read-RequiredMailAddress -Prompt "Sender mailbox (primary address)" -Current $Mailbox

if ([string]::IsNullOrWhiteSpace($TokenStorePath)) {
    $TokenStorePath = Get-DefaultTokenStorePath -Mailbox $Mailbox
}
else {
    $TokenStorePath = [IO.Path]::GetFullPath($TokenStorePath)
}

Show-GoogleCloudChecklist -SuggestedAppName $AppDisplayName

$tokenExists = Test-Path -LiteralPath $TokenStorePath

switch ($Mode) {
    'Create' {
        if ($tokenExists -and -not $ForceReauthorize) {
            throw "Token store already exists at $TokenStorePath. Use -Mode Update or -ForceReauthorize."
        }
    }
    'Update' {
        if (-not $tokenExists -and -not $ForceReauthorize) {
            throw "No token store found at $TokenStorePath. Use -Mode Create/Auto or authorize first."
        }
    }
    'Auto' {
        # create or update
    }
    default {
        $never = $Mode
        throw "Unhandled mode: $never"
    }
}

$ClientSecretsPath = Resolve-ClientSecretsPath -Path $ClientSecretsPath

if ($PreflightOnly) {
    Invoke-Preflight -MailboxValue $Mailbox -SecretsPath $ClientSecretsPath -StorePath $TokenStorePath
    return
}

$clientSecrets = Get-GoogleClientSecrets -Path $ClientSecretsPath
$needAuthorize = $ForceReauthorize -or -not $tokenExists

if (-not $needAuthorize -and $tokenExists) {
    $existing = ConvertFrom-SecurePlainJson -Path $TokenStorePath
    try {
        Assert-SenderMatchesMailbox -AuthorizedEmail ([string]$existing.authorizedEmail) -Mailbox $Mailbox
        $probe = Get-GoogleAccessToken -TokenStore $existing
        Assert-GmailSendScopePresent -GrantedScope $probe.Scope
        Pass "Existing refresh token is usable for $($existing.authorizedEmail)"
        $tokenStore = $existing
    }
    catch {
        Warn $_.Exception.Message
        if (Read-YesNo -Prompt "Re-authorize now?" -Default $true) {
            $needAuthorize = $true
        }
        else {
            throw
        }
    }
}

if ($needAuthorize) {
    $auth = Invoke-GoogleDesktopAuthorization `
        -ClientSecrets $clientSecrets `
        -Mailbox $Mailbox `
        -Scopes (Get-RequiredGmailScopes)

    $tokenStore = [pscustomobject]@{
        scriptIdentity   = $ScriptIdentity
        scriptVersion    = [string]$ScriptVersion
        appDisplayName   = $AppDisplayName
        mailbox          = $Mailbox
        authorizedEmail  = $auth.AuthorizedEmail
        clientId         = $clientSecrets.ClientId
        clientSecret     = $clientSecrets.ClientSecret
        refreshToken     = $auth.RefreshToken
        scopes           = (Get-RequiredGmailScopes)
        grantedScope     = $auth.Scope
        clientSecretsPath = $ClientSecretsPath
        createdUtc       = [DateTime]::UtcNow.ToString('o')
        updatedUtc       = [DateTime]::UtcNow.ToString('o')
    }

    Save-ScopedGmailTokenStore `
        -TokenStore $tokenStore `
        -Path $TokenStorePath `
        -PlainText:$PlainTextTokenStore

    Pass "Authorized $($auth.AuthorizedEmail) with gmail.send offline access."
}
else {
    $tokenStore.updatedUtc = [DateTime]::UtcNow.ToString('o')
    $tokenStore.appDisplayName = $AppDisplayName
    $tokenStore.mailbox = $Mailbox
    Save-ScopedGmailTokenStore `
        -TokenStore $tokenStore `
        -Path $TokenStorePath `
        -PlainText:$PlainTextTokenStore
}

Section "Configuration summary"
Write-Host "App display name : $AppDisplayName"
Write-Host "Sender mailbox   : $Mailbox"
Write-Host "Authorized as    : $($tokenStore.authorizedEmail)"
Write-Host "Client secrets   : $ClientSecretsPath"
Write-Host "Token store      : $TokenStorePath"
Write-Host "Scopes           : $((Get-RequiredGmailScopes) -join ', ')"
Write-Host "OAuth model      : mailbox refresh token (not domain-wide delegation)"

if ($TestSend) {
    if ([string]::IsNullOrWhiteSpace($TestSendTo)) {
        $TestSendTo = Read-RequiredMailAddress -Prompt "Test recipient address"
    }
    Invoke-TestSend -TokenStore $tokenStore -To $TestSendTo
}
elseif (Read-YesNo -Prompt "Send a test message now?" -Default $false) {
    $TestSendTo = Read-RequiredMailAddress -Prompt "Test recipient address"
    Invoke-TestSend -TokenStore $tokenStore -To $TestSendTo
}

Section "Next steps"
Write-Host @"
1. Store the token file path and client secrets path in your secrets process.
2. Prefer the DPAPI token store on Windows service hosts that run as a dedicated account.
3. Use Send-ScopedGmailMessage.ps1 for operational / CI test sends.
4. Monitor for refresh-token revocation (password reset, admin revoke, unused token policies).
5. Re-run this script with -ForceReauthorize when the sender must consent again.

Consuming applications should:
 - refresh an access token with the stored refresh token
 - call POST https://gmail.googleapis.com/gmail/v1/users/me/messages/send
 - never impersonate other users via domain-wide delegation for this mailbox
"@

Pass "Scoped Gmail Sender setup finished."
