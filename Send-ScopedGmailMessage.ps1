<#
.SYNOPSIS
Sends a message using a Scoped Gmail Sender token store (gmail.send refresh token).

.DESCRIPTION
Operational helper for MFA/OTP and notification test sends. Loads the DPAPI or
plaintext token store produced by Create-OrUpdate-ScopedGmailSender.ps1, refreshes
an access token, validates the authorized mailbox, and sends via the Gmail API.

.EXAMPLE
.\Send-ScopedGmailMessage.ps1 `
  -To "recipient@contoso.com" `
  -Subject "One-time code" `
  -BodyText "Your code is 123456"

.EXAMPLE
.\Send-ScopedGmailMessage.ps1 `
  -TokenStorePath "$env:LOCALAPPDATA\ScopedGmailSender\noreply@contoso.com.token.dpapi" `
  -To "recipient@contoso.com" `
  -Subject "Hello" `
  -BodyText "Plain body" `
  -BodyHtml "<p>HTML body</p>"
#>

[CmdletBinding()]
param(
    [Alias('v')]
    [switch]$Version,

    [string]$TokenStorePath = "",

    [string]$Mailbox = "",

    [Parameter(Mandatory = $false)]
    [string]$To = "",

    [Parameter(Mandatory = $false)]
    [string]$Subject = "",

    [Parameter(Mandatory = $false)]
    [string]$BodyText = "",

    [string]$BodyHtml = "",

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptIdentity = 'ScopedGmailSender'
$ScriptName = 'Send-ScopedGmailMessage.ps1'
$ScriptVersion = [version]'1.0.0'

$commonPath = Join-Path $PSScriptRoot 'lib\ScopedGmailSender.Common.ps1'
if (-not (Test-Path -LiteralPath $commonPath)) {
    throw "Missing shared library: $commonPath"
}
. $commonPath

if ($Version) {
    Write-Output "$ScriptName $ScriptVersion"
    return
}

if ([string]::IsNullOrWhiteSpace($TokenStorePath)) {
    if (-not [string]::IsNullOrWhiteSpace($Mailbox)) {
        $TokenStorePath = Get-DefaultTokenStorePath -Mailbox $Mailbox
    }
    else {
        $TokenStorePath = Get-DefaultTokenStorePath
        if (-not (Test-Path -LiteralPath $TokenStorePath)) {
            $root = Join-Path $env:LOCALAPPDATA 'ScopedGmailSender'
            if (Test-Path -LiteralPath $root) {
                $matches = Get-ChildItem -LiteralPath $root -Filter '*.token.dpapi' -ErrorAction SilentlyContinue
                if ($matches.Count -eq 1) {
                    $TokenStorePath = $matches[0].FullName
                    Info "Using token store: $TokenStorePath"
                }
            }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($TokenStorePath) -or -not (Test-Path -LiteralPath $TokenStorePath)) {
    throw "Token store not found. Run Create-OrUpdate-ScopedGmailSender.ps1 first, or pass -TokenStorePath / -Mailbox."
}

$tokenStore = ConvertFrom-SecurePlainJson -Path $TokenStorePath

if ([string]$tokenStore.scriptIdentity -ne $ScriptIdentity) {
    throw "Token store is not a ScopedGmailSender file: $TokenStorePath"
}

if (-not [string]::IsNullOrWhiteSpace($Mailbox)) {
    Assert-SenderMatchesMailbox -AuthorizedEmail ([string]$tokenStore.authorizedEmail) -Mailbox $Mailbox
    if (-not [string]::Equals(
            [string]$tokenStore.mailbox,
            $Mailbox.Trim(),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Requested -Mailbox does not match token store mailbox '$($tokenStore.mailbox)'."
    }
}

while (-not (Test-MailAddress $To)) {
    $To = Read-Host "Recipient (-To)"
}

while ([string]::IsNullOrWhiteSpace($Subject)) {
    $Subject = Read-Host "Subject"
}

while ([string]::IsNullOrWhiteSpace($BodyText)) {
    $BodyText = Read-Host "Plain-text body"
}

Section "Send as $($tokenStore.mailbox)"
Info "Token store : $TokenStorePath"
Info "Authorized  : $($tokenStore.authorizedEmail)"
Info "To          : $To"
Info "Subject     : $Subject"

$raw = New-GmailRawMessage `
    -From ([string]$tokenStore.mailbox) `
    -To $To `
    -Subject $Subject `
    -BodyText $BodyText `
    -BodyHtml $BodyHtml

if ($DryRun) {
    Pass "Dry run only. MIME raw length: $($raw.Length) base64url characters."
    return
}

$access = Get-GoogleAccessToken -TokenStore $tokenStore
Assert-GmailSendScopePresent -GrantedScope $access.Scope
Assert-SenderMatchesMailbox `
    -AuthorizedEmail ([string]$tokenStore.authorizedEmail) `
    -Mailbox ([string]$tokenStore.mailbox)

$result = Send-ScopedGmailRaw -AccessToken $access.AccessToken -RawMessage $raw
Pass "Message accepted by Gmail. id=$($result.id)"
