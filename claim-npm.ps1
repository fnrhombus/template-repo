#!/usr/bin/env pwsh
# claim-npm.ps1
# Step 1 of 2. Pick an npm package name, check availability, publish a
# 0.0.0-alpha.0 placeholder under the 'alpha' dist-tag (so it never becomes
# 'latest'), and populate package.json. Run setup-gh.ps1 after this.
#
# Requires: gh CLI authenticated, npm installed, logged in to npm.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string]$msg) { Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-Done([string]$msg) { Write-Host "   $msg" -ForegroundColor Green }

# ── Prerequisites ─────────────────────────────────────────────────────────────

Write-Step "Checking prerequisites"

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Error "gh CLI not found. Install from https://cli.github.com"
}
gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "gh not authenticated. Run: gh auth login"
}

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-Error "npm not found."
}
Write-Done "gh + npm available"

# ── Detect repo (for name derivation + scope default) ─────────────────────────

Write-Step "Detecting repository"

$repo = gh repo view --json nameWithOwner -q .nameWithOwner 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Could not detect GitHub repo. Make sure the remote is set and pushed."
}
$owner = $repo.Split('/')[0]
Write-Done "$repo"

# ── Ensure package.json exists ────────────────────────────────────────────────
# If we're running from the template clone and cwd has no package.json, copy
# the template's (with its __PACKAGE_NAME__ placeholder) so we have something to fill in.

$templateRoot = (Resolve-Path $PSScriptRoot).Path
$targetRoot   = (Resolve-Path (Get-Location)).Path
if (-not (Test-Path (Join-Path $targetRoot 'package.json'))) {
    $templatePkg = Join-Path $templateRoot 'package.json'
    if ($templateRoot -ne $targetRoot -and (Test-Path $templatePkg)) {
        Copy-Item $templatePkg (Join-Path $targetRoot 'package.json')
        Write-Done "package.json copied from template"
    } else {
        Write-Error "package.json not found in $targetRoot and no template to copy from."
    }
}

$pkgJson = Get-Content package.json -Raw
if ($pkgJson -notmatch '__PACKAGE_NAME__') {
    Write-Done "package.json already populated — nothing to claim. Skipping."
    exit 0
}

# ── npm auth ──────────────────────────────────────────────────────────────────

Write-Step "Checking npm auth"

$npmUser = npm whoami 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "   Not logged in to npm." -ForegroundColor Yellow
    Write-Host "   Run 'npm login' in another terminal, then come back." -ForegroundColor Yellow
    Read-Host "   Press Enter once logged in"
    $npmUser = npm whoami 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Still not authenticated to npm. Aborting."
    }
}
Write-Done "npm: authenticated as $npmUser"

# ── Name selection ────────────────────────────────────────────────────────────

Write-Step "Choosing package name"

# Derive bare name from repo name (strip any @owner convention, e.g. "my-lib@fnrhombus" → "my-lib")
$derivedName = $repo.Split('/')[1] -replace '@.*$', ''
$nameConfirm = Read-Host "   Use '$derivedName' as the base package name? [Y/n, or type a different name]"
if ($nameConfirm -match '^[Nn]$') {
    $repoName = Read-Host "   Enter base package name"
} elseif ($nameConfirm -eq '' -or $nameConfirm -match '^[Yy]$') {
    $repoName = $derivedName
} else {
    $repoName = $nameConfirm
}

$scopeAnswer   = Read-Host "   Publish as scoped package? (@$owner/$repoName) [Y/n]"
$packageExists = $false
if ($scopeAnswer -eq '' -or $scopeAnswer -match '^[Yy]') {
    $packageName = "@$owner/$repoName"
    Write-Done "Using scoped name: $packageName"
    npm view $packageName version 2>&1 | Out-Null
    $packageExists = ($LASTEXITCODE -eq 0)
    if ($packageExists) { Write-Done "'$packageName' already exists on npm; skipping claim" }
} else {
    # Unscoped: loop until we find an available name — never silently continue with a taken one
    $packageName = $repoName
    while ($true) {
        Write-Host "   Checking npm availability of '$packageName'..." -ForegroundColor Gray
        npm view $packageName version 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Done "'$packageName' is available on npm"
            break
        }
        Write-Host "   '$packageName' is already taken on npm." -ForegroundColor Yellow
        $packageName = Read-Host "   Enter a different package name"
    }
}

# ── Claim on npm ──────────────────────────────────────────────────────────────
# Publish a placeholder so the name is ours. Use the 'alpha' dist-tag so it
# never becomes 'latest' — the first real release from CI claims that cleanly.

if (-not $packageExists) {
    Write-Step "Claiming '$packageName' on npm"

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "npm-claim-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $tmpDir | Out-Null
    try {
        @{
            name        = $packageName
            version     = '0.0.0-alpha.0'
            description = 'Placeholder — real release coming soon.'
        } | ConvertTo-Json | Set-Content (Join-Path $tmpDir 'package.json') -NoNewline
        Push-Location $tmpDir
        try {
            npm publish --access public --tag alpha 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Done "Claimed '$packageName' on npm (0.0.0-alpha.0, tag: alpha)"
            } else {
                Write-Error "Failed to publish placeholder for '$packageName'. Aborting so the name isn't lost."
            }
        } finally {
            Pop-Location
        }
    } finally {
        Remove-Item -Recurse -Force $tmpDir
    }
}

# ── Populate package.json ─────────────────────────────────────────────────────

Write-Step "Populating package.json"

$description = Read-Host "   Description"

($pkgJson `
    -replace '__PACKAGE_NAME__', $packageName `
    -replace '__DESCRIPTION__', $description
) | Set-Content package.json -NoNewline

Write-Done "package.json updated"

Write-Host ""
Write-Host "npm claim complete." -ForegroundColor Green
Write-Host "Next: run setup-gh.ps1 to configure branch protection, environment, and OIDC." -ForegroundColor White
Write-Host ""
