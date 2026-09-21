# ScopedGmailSender.Common.ps1
# Shared helpers for Create-OrUpdate-ScopedGmailSender.ps1 and Send-ScopedGmailMessage.ps1.
# Dot-source only; do not run this file directly.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ScopedGmailSenderIdentity = 'ScopedGmailSender'
$script:GmailSendScope = 'https://www.googleapis.com/auth/gmail.send'
$script:OpenIdScopes = @('openid', 'email')
$script:GoogleAuthEndpoint = 'https://accounts.google.com/o/oauth2/v2/auth'
$script:GoogleTokenEndpoint = 'https://oauth2.googleapis.com/token'
$script:GoogleUserInfoEndpoint = 'https://openidconnect.googleapis.com/v1/userinfo'
$script:GmailSendEndpoint = 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send'

function Section([string]$Text) {
    Write-Host ""
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
}

function Pass([string]$Text) { Write-Host "[PASS] $Text" -ForegroundColor Green }
function Info([string]$Text) { Write-Host "[INFO] $Text" -ForegroundColor Gray }
function Warn([string]$Text) { Write-Host "[WARN] $Text" -ForegroundColor Yellow }

function Test-MailAddress([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return $Value.Trim() -match '^[^@\s]+@[^@\s]+\.[^@\s]+$'
}

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [bool]$Default = $false
    )

    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }

    while ($true) {
        $answer = Read-Host "$Prompt $suffix"

        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $Default
        }

        switch ($answer.Trim().ToLowerInvariant()) {
            'y' { return $true }
            'yes' { return $true }
            'n' { return $false }
            'no' { return $false }
        }

        Write-Host "Please enter Y or N." -ForegroundColor Yellow
    }
}

function Get-RequiredGmailScopes {
    return @($script:GmailSendScope) + $script:OpenIdScopes
}

function ConvertTo-Base64Url([byte[]]$Bytes) {
    $b64 = [Convert]::ToBase64String($Bytes)
    return (($b64 -replace '\+', '-') -replace '/', '_') -replace '=+$', ''
}

function ConvertFrom-SecurePlainJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Token file not found: $Path"
    }

    $bytes = [IO.File]::ReadAllBytes($Path)

    # DPAPI-protected files start with a Windows ProtectedData blob; try decrypt first.
    try {
        Add-Type -AssemblyName System.Security -ErrorAction Stop | Out-Null
        $plain = [Security.Cryptography.ProtectedData]::Unprotect(
            $bytes,
            $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $json = [Text.Encoding]::UTF8.GetString($plain)
        return ($json | ConvertFrom-Json)
    }
    catch {
        # Fall through to plain JSON (non-Windows or intentionally unencrypted).
    }

    $text = [Text.Encoding]::UTF8.GetString($bytes)
    return ($text | ConvertFrom-Json)
}

function Save-ScopedGmailTokenStore {
    param(
        [Parameter(Mandatory = $true)][psobject]$TokenStore,
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$PlainText
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $json = $TokenStore | ConvertTo-Json -Depth 8
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)

    $useDpapi = -not $PlainText -and ($IsWindows -or $env:OS -eq 'Windows_NT')

    if ($useDpapi) {
        Add-Type -AssemblyName System.Security -ErrorAction Stop | Out-Null
        $protected = [Security.Cryptography.ProtectedData]::Protect(
            $bytes,
            $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        [IO.File]::WriteAllBytes($Path, $protected)
        Info "Saved DPAPI-protected token store: $Path"
    }
    else {
        [IO.File]::WriteAllText($Path, $json)
        Warn "Saved plaintext token store: $Path"
        Warn "Protect this file with OS ACLs or a secrets manager. Prefer DPAPI on Windows."
    }
}

function Get-GoogleClientSecrets {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Client secrets file not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json

    if ($null -ne $raw.PSObject.Properties['type'] -and
        [string]$raw.type -eq 'service_account') {
        throw @"
Refusing service-account JSON.

This project uses a mailbox-authorized OAuth refresh token so send permission is
limited to the account that signed in. Do not use domain-wide delegation or a
service account JSON key for this requirement.

Download an OAuth client secrets JSON for a Desktop app instead.
"@
    }

    $installed = $null
    if ($null -ne $raw.PSObject.Properties['installed']) {
        $installed = $raw.installed
    }
    elseif ($null -ne $raw.PSObject.Properties['web']) {
        throw "Web OAuth clients are not supported. Create a Desktop OAuth client and download its JSON."
    }
    else {
        # Flat shape: client_id / client_secret at root.
        if ($null -ne $raw.PSObject.Properties['client_id']) {
            $installed = $raw
        }
    }

    if ($null -eq $installed -or
        [string]::IsNullOrWhiteSpace([string]$installed.client_id) -or
        [string]::IsNullOrWhiteSpace([string]$installed.client_secret)) {
        throw "Could not read client_id and client_secret from $Path"
    }

    [pscustomobject]@{
        ClientId     = [string]$installed.client_id
        ClientSecret = [string]$installed.client_secret
        AuthUri      = if ($installed.auth_uri) { [string]$installed.auth_uri } else { $script:GoogleAuthEndpoint }
        TokenUri     = if ($installed.token_uri) { [string]$installed.token_uri } else { $script:GoogleTokenEndpoint }
        SourcePath   = $Path
    }
}

function Get-FreeLoopbackPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    return [int]$port
}

function Invoke-GoogleTokenRequest {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Body,
        [string]$TokenUri = $script:GoogleTokenEndpoint
    )

    $form = ($Body.GetEnumerator() | ForEach-Object {
            '{0}={1}' -f [Uri]::EscapeDataString([string]$_.Key), [Uri]::EscapeDataString([string]$_.Value)
        }) -join '&'

    try {
        $response = Invoke-RestMethod `
            -Method Post `
            -Uri $TokenUri `
            -ContentType 'application/x-www-form-urlencoded' `
            -Body $form `
            -ErrorAction Stop
        return $response
    }
    catch {
        $detail = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $detail = $_.ErrorDetails.Message
        }
        throw "Google token request failed: $detail"
    }
}

function Get-GoogleAccessToken {
    param(
        [Parameter(Mandatory = $true)][psobject]$TokenStore
    )

    if ([string]::IsNullOrWhiteSpace([string]$TokenStore.refreshToken)) {
        throw "Token store is missing refreshToken. Re-run authorization."
    }

    $response = Invoke-GoogleTokenRequest -Body @{
        client_id     = [string]$TokenStore.clientId
        client_secret = [string]$TokenStore.clientSecret
        refresh_token = [string]$TokenStore.refreshToken
        grant_type    = 'refresh_token'
    }

    if ([string]::IsNullOrWhiteSpace([string]$response.access_token)) {
        throw "Google did not return an access_token."
    }

    return [pscustomobject]@{
        AccessToken = [string]$response.access_token
        ExpiresIn   = [int]($response.expires_in)
        Scope       = [string]$response.scope
        TokenType   = [string]$response.token_type
    }
}

function Get-GoogleAuthorizedEmail {
    param(
        [Parameter(Mandatory = $true)][string]$AccessToken
    )

    $headers = @{ Authorization = "Bearer $AccessToken" }
    $info = Invoke-RestMethod `
        -Method Get `
        -Uri $script:GoogleUserInfoEndpoint `
        -Headers $headers `
        -ErrorAction Stop

    if ([string]::IsNullOrWhiteSpace([string]$info.email)) {
        throw "OpenID userinfo did not return an email claim."
    }

    return [string]$info.email
}

function Assert-SenderMatchesMailbox {
    param(
        [Parameter(Mandatory = $true)][string]$AuthorizedEmail,
        [Parameter(Mandatory = $true)][string]$Mailbox
    )

    if (-not [string]::Equals(
            $AuthorizedEmail.Trim(),
            $Mailbox.Trim(),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw @"
Authorized Google account '$AuthorizedEmail' does not match the configured sender mailbox '$Mailbox'.

Sign in as the dedicated sender mailbox during OAuth consent. Do not authorize a different user
and then change the From address in application code.
"@
    }
}

function New-GmailRawMessage {
    param(
        [Parameter(Mandatory = $true)][string]$From,
        [Parameter(Mandatory = $true)][string]$To,
        [Parameter(Mandatory = $true)][string]$Subject,
        [Parameter(Mandatory = $true)][string]$BodyText,
        [string]$BodyHtml = ""
    )

    $boundary = 'scoped_gmail_' + [guid]::NewGuid().ToString('N')
    $sb = [Text.StringBuilder]::new()

    [void]$sb.AppendLine("From: $From")
    [void]$sb.AppendLine("To: $To")
    [void]$sb.AppendLine("Subject: $Subject")
    [void]$sb.AppendLine('MIME-Version: 1.0')

    if ([string]::IsNullOrWhiteSpace($BodyHtml)) {
        [void]$sb.AppendLine('Content-Type: text/plain; charset="UTF-8"')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine($BodyText)
    }
    else {
        [void]$sb.AppendLine("Content-Type: multipart/alternative; boundary=`"$boundary`"")
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("--$boundary")
        [void]$sb.AppendLine('Content-Type: text/plain; charset="UTF-8"')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine($BodyText)
        [void]$sb.AppendLine("--$boundary")
        [void]$sb.AppendLine('Content-Type: text/html; charset="UTF-8"')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine($BodyHtml)
        [void]$sb.AppendLine("--$boundary--")
    }

    $bytes = [Text.Encoding]::UTF8.GetBytes($sb.ToString())
    return (ConvertTo-Base64Url -Bytes $bytes)
}

function Send-ScopedGmailRaw {
    param(
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)][string]$RawMessage
    )

    $headers = @{
        Authorization = "Bearer $AccessToken"
    }

    $payload = @{ raw = $RawMessage } | ConvertTo-Json -Compress

    try {
        return Invoke-RestMethod `
            -Method Post `
            -Uri $script:GmailSendEndpoint `
            -Headers $headers `
            -ContentType 'application/json' `
            -Body $payload `
            -ErrorAction Stop
    }
    catch {
        $detail = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $detail = $_.ErrorDetails.Message
        }
        throw "Gmail send failed: $detail"
    }
}

function Assert-GmailSendScopePresent {
    param(
        [string]$GrantedScope
    )

    if ([string]::IsNullOrWhiteSpace($GrantedScope)) {
        Warn "Token response did not echo scopes; continuing."
        return
    }

    $parts = $GrantedScope -split '\s+' | Where-Object { $_ }
    if ($parts -notcontains $script:GmailSendScope) {
        throw "Authorized scopes do not include gmail.send. Granted: $GrantedScope"
    }

    $dangerous = @(
        'https://mail.google.com/',
        'https://www.googleapis.com/auth/gmail.modify',
        'https://www.googleapis.com/auth/gmail.readonly',
        'https://www.googleapis.com/auth/gmail.compose'
    )

    foreach ($scope in $dangerous) {
        if ($parts -contains $scope) {
            throw "Refusing broader Gmail scope '$scope'. Re-authorize with gmail.send only (plus openid/email for identity)."
        }
    }
}

function Get-DefaultTokenStorePath {
    param(
        [string]$Mailbox = ""
    )

    $root = Join-Path $env:LOCALAPPDATA 'ScopedGmailSender'
    if ([string]::IsNullOrWhiteSpace($Mailbox)) {
        return (Join-Path $root 'token.dpapi')
    }

    $safe = ($Mailbox.Trim().ToLowerInvariant() -replace '[^a-z0-9@._-]', '_')
    return (Join-Path $root "$safe.token.dpapi")
}
