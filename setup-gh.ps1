#!/usr/bin/env pwsh
# setup-gh.ps1
# Step 2 of 2. Merge template files into the repo, configure branch protection
# and the 'production' environment, and register GitHub Actions + production as
# a trusted publisher (OIDC) on the already-claimed npm package.
#
# Requires: claim-npm.ps1 has been run (or package.json is already populated
# with a real npm name); gh CLI authenticated; npm installed and logged in.

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
gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "gh not authenticated. Run: gh auth login"
}
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-Error "npm not found."
}
Write-Done "gh + npm available"

# ── Detect repo ───────────────────────────────────────────────────────────────

Write-Step "Detecting repository"

$repo = gh repo view --json nameWithOwner -q .nameWithOwner 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Could not detect GitHub repo. Make sure the remote is set and pushed."
}
$owner   = $repo.Split('/')[0]
$ownerId = gh api "users/$owner" -q .id
Write-Done "$repo (owner id: $ownerId)"

# Workflow filename authorised for npm trusted publishing (OIDC).
# May be re-set by the merge step below if the user appends under a different name.
$publishWorkflowFile = 'ci.yml'

# ── Merge template files (only when running against a different repo) ─────────
# If setup-gh.ps1 is invoked from the template clone while cwd is a different
# repo, copy/merge template files into cwd without overwriting established ones.

$templateRoot = (Resolve-Path $PSScriptRoot).Path
$targetRoot   = (Resolve-Path (Get-Location)).Path

if ($templateRoot -ne $targetRoot) {
    Write-Step "Merging template files into $targetRoot"

    # Keep-yours: copy only if missing. Never overwrite established config.
    $keepYours = @(
        '.github/FUNDING.yml',
        '.releaserc.json',
        'package.json'
    )
    foreach ($rel in $keepYours) {
        $src = Join-Path $templateRoot $rel
        $dst = Join-Path $targetRoot $rel
        if (-not (Test-Path $src)) { continue }
        if (Test-Path $dst) {
            Write-Done "$rel exists, keeping yours"
        } else {
            $dstDir = Split-Path $dst -Parent
            if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
            Copy-Item $src $dst
            Write-Done "$rel installed"
        }
    }

    # .gitignore: append any missing lines instead of overwriting
    $giSrc = Join-Path $templateRoot '.gitignore'
    $giDst = Join-Path $targetRoot '.gitignore'
    if (Test-Path $giSrc) {
        if (Test-Path $giDst) {
            $existing = [System.IO.File]::ReadAllLines($giDst)
            $toAdd    = [System.IO.File]::ReadAllLines($giSrc) |
                Where-Object { $_ -ne '' -and ($existing -notcontains $_) }
            if ($toAdd) {
                Add-Content -Path $giDst -Value ''
                Add-Content -Path $giDst -Value $toAdd
                Write-Done ".gitignore merged (+$(@($toAdd).Count) lines)"
            } else {
                Write-Done ".gitignore already has template entries"
            }
        } else {
            Copy-Item $giSrc $giDst
            Write-Done ".gitignore installed"
        }
    }

    # Workflows: if any exist already, ask append vs nuke vs skip
    $ciSrc        = Join-Path $templateRoot '.github/workflows/ci.yml'
    $workflowsDir = Join-Path $targetRoot '.github/workflows'
    if (Test-Path $ciSrc) {
        if (-not (Test-Path $workflowsDir)) {
            New-Item -ItemType Directory -Path $workflowsDir -Force | Out-Null
        }
        $existing = @(Get-ChildItem $workflowsDir -Filter '*.yml' -File -ErrorAction SilentlyContinue)
        if ($existing.Count -eq 0) {
            Copy-Item $ciSrc (Join-Path $workflowsDir 'ci.yml')
            Write-Done "ci.yml installed"
        } else {
            Write-Host "   Existing workflows: $(($existing.Name) -join ', ')" -ForegroundColor Yellow
            $choice = Read-Host "   (a)ppend template ci.yml alongside, (n)uke existing and replace, or (s)kip? [a/n/s]"
            switch -Regex ($choice) {
                '^[Nn]' {
                    $existing | ForEach-Object { Remove-Item $_.FullName }
                    Copy-Item $ciSrc (Join-Path $workflowsDir 'ci.yml')
                    Write-Done "Existing workflows removed; ci.yml installed"
                }
                '^[Ss]' {
                    Write-Done "Skipped workflow install"
                }
                default {
                    $target = Join-Path $workflowsDir 'ci.yml'
                    if (Test-Path $target) { $target = Join-Path $workflowsDir 'ci-template.yml' }
                    Copy-Item $ciSrc $target
                    $publishWorkflowFile = Split-Path $target -Leaf
                    Write-Done "Template workflow installed as $publishWorkflowFile"
                }
            }
        }
    }
}

# ── Detect claimed npm package ────────────────────────────────────────────────

Write-Step "Detecting claimed npm package"

if (-not (Test-Path 'package.json')) {
    Write-Error "package.json not found. Run claim-npm.ps1 first."
}
$pkgJsonRaw = Get-Content package.json -Raw
if ($pkgJsonRaw -match '__PACKAGE_NAME__') {
    Write-Error "package.json still has the __PACKAGE_NAME__ placeholder. Run claim-npm.ps1 first."
}
$packageName = ($pkgJsonRaw | ConvertFrom-Json).name
if (-not $packageName) {
    Write-Error "package.json has no 'name' field."
}
Write-Done "Using claimed package: $packageName"

# ── Branch protection on main ─────────────────────────────────────────────────

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

# ── Production environment ────────────────────────────────────────────────────

Write-Step "Configuring 'production' environment"

$environment = @{
    reviewers                = @(@{ type = 'User'; id = [int]$ownerId })
    deployment_branch_policy = $null
} | ConvertTo-Json -Depth 5

$environment | gh api --method PUT "repos/$repo/environments/production" --input - | Out-Null
Write-Done "Environment created with $owner as required reviewer"

# ── npm trusted publisher (OIDC) ──────────────────────────────────────────────

Write-Step "Configuring npm trusted publisher (GitHub Actions OIDC)"

npm trust github $packageName --file $publishWorkflowFile --repo $repo --env production --yes 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Done "Trusted publisher set: $repo / $publishWorkflowFile / env 'production'"
} else {
    Write-Host "   Warning: 'npm trust' failed. Configure manually at https://www.npmjs.com/package/$packageName/access" -ForegroundColor Yellow
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Setup complete." -ForegroundColor Green
Write-Host ""
Write-Host "One step requires the GitHub UI (no API support):" -ForegroundColor White
Write-Manual "Merge queue: Settings → Branches → Edit 'main' → Enable merge queue"
Write-Host ""
Write-Host "Remaining TODOs in the workflow (.github/workflows/$publishWorkflowFile):" -ForegroundColor White
Write-Manual "Fill in the lint, test, and build steps under the 'verify' job"
Write-Host ""
