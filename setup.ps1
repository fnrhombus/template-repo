#!/usr/bin/env pwsh
# setup.ps1
# Run once from the repo root after creating a new repo from this template.
# Requires: gh CLI authenticated, git remote set to GitHub.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string]$msg) { Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-Done([string]$msg) { Write-Host "   $msg" -ForegroundColor Green }
function Write-Manual([string]$msg) { Write-Host "   [manual] $msg" -ForegroundColor Yellow }

# ── Prerequisites ─────────────────────────────────────────────────────────────

Write-Step "Checking prerequisites"

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Error "gh CLI not found. Install from https://cli.github.com"
}

$authStatus = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Not authenticated. Run: gh auth login"
}

Write-Done "gh CLI authenticated"

# ── Detect repo ────────────────────────────────────────────────────────────────

Write-Step "Detecting repository"

$repo = gh repo view --json nameWithOwner -q .nameWithOwner 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Could not detect GitHub repo. Make sure the remote is set and pushed."
}

$owner = $repo.Split('/')[0]
$ownerId = gh api "users/$owner" -q .id
Write-Done "$repo (owner id: $ownerId)"

# ── Package info ───────────────────────────────────────────────────────────────

Write-Step "Package info"

$pkgJson = Get-Content package.json -Raw
if ($pkgJson -match '__PACKAGE_NAME__') {
    # Derive bare name from repo name (strip any @owner convention, e.g. "my-lib@fnrhombus" → "my-lib")
    $repoName = $repo.Split('/')[1] -replace '@.*$', ''

    # Scoped or unscoped?
    $scopeAnswer = Read-Host "   Publish as scoped package? (@$owner/$repoName) [Y/n]"
    if ($scopeAnswer -eq '' -or $scopeAnswer -match '^[Yy]') {
        $packageName = "@$owner/$repoName"
        Write-Done "Using scoped name: $packageName (your npm scope — always available)"
    } else {
        # Unscoped: check npm availability
        $packageName = $repoName
        Write-Host "   Checking npm availability of '$packageName'..." -ForegroundColor Gray
        npm view $packageName version 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   '$packageName' is already taken on npm." -ForegroundColor Yellow
            $packageName = Read-Host "   Enter a different package name"
            # Re-check
            npm view $packageName version 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "   Warning: '$packageName' also appears to be taken. Continuing anyway." -ForegroundColor Yellow
            } else {
                Write-Done "'$packageName' is available"
            }
        } else {
            Write-Done "'$packageName' is available on npm"
        }
    }

    $description = Read-Host "   Description"

    ($pkgJson `
        -replace '__PACKAGE_NAME__', $packageName `
        -replace '__DESCRIPTION__', $description
    ) | Set-Content package.json -NoNewline

    Write-Done "package.json updated"
} else {
    Write-Done "package.json already populated, skipping"
}

# ── Branch protection on main ──────────────────────────────────────────────────

Write-Step "Configuring branch protection on main"

$protection = @{
    required_status_checks         = @{
        strict   = $true
        contexts = @('verify')
    }
    enforce_admins                  = $false
    required_pull_request_reviews   = @{
        required_approving_review_count = 0
        dismiss_stale_reviews           = $false
        require_code_owner_reviews      = $false
        require_last_push_approval      = $false
    }
    restrictions                    = $null
} | ConvertTo-Json -Depth 5

$protection | gh api --method PUT "repos/$repo/branches/main/protection" --input - | Out-Null
Write-Done "Branch protection set (require PR + verify status check)"

# ── Production environment ─────────────────────────────────────────────────────

Write-Step "Configuring 'production' environment"

$environment = @{
    reviewers                = @(@{ type = 'User'; id = [int]$ownerId })
    deployment_branch_policy = $null
} | ConvertTo-Json -Depth 5

$environment | gh api --method PUT "repos/$repo/environments/production" --input - | Out-Null
Write-Done "Environment created with $owner as required reviewer"

# ── Summary ────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Setup complete." -ForegroundColor Green
Write-Host ""
Write-Host "One step requires the GitHub UI (no API support):" -ForegroundColor White
Write-Manual "Merge queue: Settings → Branches → Edit 'main' → Enable merge queue"
Write-Host ""
Write-Host "Secrets to add when ready (Settings → Secrets → Actions):" -ForegroundColor White
Write-Manual "NPM_TOKEN — needs 'Automation' role or a granular publish token"
Write-Host ""
Write-Host "Remaining TODOs in the workflow (.github/workflows/ci.yml):" -ForegroundColor White
Write-Manual "Fill in the lint, test, and build steps under the 'verify' job"
Write-Host ""
