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

# Workflow filename authorised for npm trusted publishing (OIDC).
# May be re-set by the merge step below if the user appends under a different name.
$publishWorkflowFile = 'ci.yml'

# ── Merge template files (only when running against a different repo) ──────────
# If setup.ps1 is invoked from the template clone while cwd is a different repo,
# copy/merge template files into cwd without overwriting established ones.

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

# ── Package info ───────────────────────────────────────────────────────────────

Write-Step "Package info"

$pkgJson = Get-Content package.json -Raw
if ($pkgJson -match '__PACKAGE_NAME__') {
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

    # Ensure npm auth (needed to claim names and configure trusted publishing)
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

    # Scoped or unscoped?
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

    # Claim the name on npm by publishing a placeholder. Required for BOTH scoped
    # and unscoped paths — npm trust can only target packages that already exist.
    if (-not $packageExists) {
        Write-Host "   Claiming '$packageName' on npm..." -ForegroundColor Gray
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
                # Publish under the 'alpha' dist-tag so it never becomes 'latest' —
                # the first real release from CI will claim 'latest' cleanly.
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

    # Configure npm trusted publishing (OIDC) so the workflow publishes without NPM_TOKEN.
    Write-Host "   Configuring npm trusted publisher (GitHub Actions OIDC)..." -ForegroundColor Gray
    npm trust github $packageName --file $publishWorkflowFile --repo $repo --env production --yes 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Done "Trusted publisher set: $repo / $publishWorkflowFile / env 'production'"
    } else {
        Write-Host "   Warning: 'npm trust' failed. Configure manually at https://www.npmjs.com/package/$packageName/access" -ForegroundColor Yellow
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
Write-Host "Remaining TODOs in the workflow (.github/workflows/$publishWorkflowFile):" -ForegroundColor White
Write-Manual "Fill in the lint, test, and build steps under the 'verify' job"
Write-Host ""
