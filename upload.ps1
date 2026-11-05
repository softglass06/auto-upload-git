# ============================================================
#  GitHub Upload Helper - drag & drop launcher
#  Drop one or more folders onto "上传到GitHub.cmd", or run with
#  no arguments and pick a folder in the dialog.
#
#  What it does:
#    1. figures out the target git repo (in-place or copy)
#    2. filters out test/build/cache files (filter-rules.txt + .gitignore)
#    3. shows a preview and asks for confirmation
#    4. asks for a one-line description, polishes it with Claude
#    5. commits and pushes
#
#  NOTE: this file is ASCII-only on purpose - PowerShell 5.1 reads
#  non-BOM .ps1 as GBK, and non-ASCII bytes silently break the next
#  line. Do NOT add non-ASCII characters to this file.
# ============================================================

# 'Stop' would turn ANY stderr from native commands (git/claude) into a
# terminating NativeCommandError - even with 2>$null - so a harmless git
# "LF will be replaced by CRLF" warning aborts the script mid-run. Use
# 'Continue'; git success/failure is checked via $LASTEXITCODE below.
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$scriptDir = ''
if ($MyInvocation.MyCommand.Path) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$reposFile = Join-Path $scriptDir 'repos.txt'
$rulesFile = Join-Path $scriptDir 'filter-rules.txt'

function Say  { param([string]$m) Write-Host $m }
function Step { param([string]$m) Write-Host ("`n== " + $m + " ==") -ForegroundColor Cyan }
function Info { param([string]$m) Write-Host ("   " + $m) }
function Warn { param([string]$m) Write-Host ("   ! " + $m) -ForegroundColor Yellow }
function Fail { param([string]$m) Write-Host ("   X " + $m) -ForegroundColor Red }

# ---- reconstruct paths dropped onto the .cmd (spaces get split) ----
function Reconstruct-Paths([string[]]$tokens) {
    $paths = New-Object System.Collections.Generic.List[string]
    $cur = $null
    foreach ($t in $tokens) {
        if ($t -match '^[a-zA-Z]:') {
            if ($cur) { $paths.Add($cur) }
            $cur = $t
        } else {
            if ($cur) { $cur = $cur + ' ' + $t } else { $cur = $t }
        }
    }
    if ($cur) { $paths.Add($cur) }
    $out = @()
    foreach ($p in $paths) { $out += $p.Trim() }
    return $out
}

# ---- pick a folder (no-argument case) ----
function Pick-Folder {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "Choose a folder to upload"
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dlg.SelectedPath
        }
    } catch { }
    return (Read-Host "Enter folder path").Trim()
}

# ---- load repos ----
function Get-Repos {
    $repos = @()
    if (Test-Path -LiteralPath $reposFile) {
        foreach ($line in Get-Content -LiteralPath $reposFile -Encoding UTF8) {
            $l = $line.Trim()
            if ($l -eq '' -or $l.StartsWith('#')) { continue }
            $i = $l.IndexOf('|')
            if ($i -lt 1) { continue }
            $name = $l.Substring(0, $i).Trim()
            $path = $l.Substring($i + 1).Trim()
            $repos += [pscustomobject]@{ Name = $name; Path = $path }
        }
    }
    return $repos
}

# ---- load filter rules ----
function Get-Rules {
    $rules = @()
    if (Test-Path -LiteralPath $rulesFile) {
        foreach ($line in Get-Content -LiteralPath $rulesFile -Encoding UTF8) {
            $l = $line.Trim()
            if ($l -eq '' -or $l.StartsWith('#')) { continue }
            $rules += $l
        }
    }
    if ($rules.Count -eq 0) {
        # Built-in defaults so a standalone .exe works without filter-rules.txt.
        $rules = @(
            'node_modules/', '__pycache__/', '.git/', '.venv/', 'venv/', 'env/',
            '.idea/', '.vscode/', 'dist/', 'build/', 'out/', 'coverage/',
            '.next/', '.nuxt/', '.pytest_cache/', '.mypy_cache/', '.ruff_cache/',
            '.cache/', 'target/', '.eggs/', '*.egg-info/',
            'test/', 'tests/', '__tests__/', 'spec/', 'specs/', 'testdata/', 'fixtures/',
            '*.test.*', '*.spec.*', '*_test.*', '*_spec.*', 'test_*.py', '*_test.py',
            '*.pyc', '*.pyo', '*.class', '*.o', '*.log', '*.tmp', '*.bak', '*.swp',
            '*.DS_Store', 'Thumbs.db'
        )
    }
    return $rules
}

# ---- true if a directory NAME should not be recursed into ----
function Test-DirSkipped([string]$name, [string[]]$rules) {
    foreach ($r in $rules) {
        $r = $r.Trim() -replace '\\', '/'
        if ($r -eq '') { continue }
        $core = $r.TrimEnd('/')
        $glob = ($core.IndexOf('*') -ge 0) -or ($core.IndexOf('?') -ge 0)
        if ($glob) { if ($name -like $core) { return $true } }
        elseif ($name -ieq $core) { return $true }
    }
    return $false
}

# ---- true + rule if a relative path should be excluded ----
function Match-Rule([string]$rel, [string[]]$rules) {
    $rel = $rel -replace '\\', '/'
    $segs = @($rel -split '/') | Where-Object { $_ -ne '' }
    foreach ($r in $rules) {
        $r = $r.Trim() -replace '\\', '/'
        if ($r -eq '') { continue }
        $core = $r.TrimEnd('/')
        $glob = ($core.IndexOf('*') -ge 0) -or ($core.IndexOf('?') -ge 0)
        if ($glob) {
            if ($rel -like $core) { return $r }
            foreach ($s in $segs) { if ($s -like $core) { return $r } }
        } else {
            foreach ($s in $segs) { if ($s -eq $core) { return $r } }
            if ($rel -match ('(^|/)' + [regex]::Escape($core) + '(/|$)')) { return $r }
        }
    }
    return $null
}

# ---- enumerate files under a folder, pruning excluded dirs ----
function Get-Files([string]$root, [string[]]$rules) {
    $root = (Resolve-Path -LiteralPath $root).Path.TrimEnd('\')
    $items = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.PSIsContainer) {
                if ($_.Name -eq '.git') { return }
                if (Test-DirSkipped $_.Name $rules) { return }
                $stack.Push($_.FullName)
            } else {
                $rel = $_.FullName.Substring($root.Length + 1) -replace '\\', '/'
                $items.Add([pscustomobject]@{ Abs = $_.FullName; Rel = $rel })
            }
        }
    }
    return $items
}

# ---- changed paths under scope (repo-relative), quoting disabled ----
function Get-Changed([string]$repo, [string]$scope) {
    $gitArgs = @('-c', 'core.quotepath=false', 'status', '--porcelain=v1', '--untracked-files=all')
    if ($scope -and $scope -ne '.') { $gitArgs += @('--', $scope) } else { $gitArgs += @('--', '.') }
    $lines = & git -C $repo @gitArgs 2>$null
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -isnot [string]) { continue }
        if ($line.Length -lt 4) { continue }
        $p = $line.Substring(3)
        $idx = $p.IndexOf(' -> ')
        if ($idx -ge 0) { $p = $p.Substring($idx + 4) }
        $p = $p.Trim()
        if ($p) { $out.Add(($p -replace '\\', '/')) }
    }
    return $out
}

# ---- resolve target repo / mode ----
function Resolve-Target([string]$folder, $repos) {
    if (Test-Path -LiteralPath (Join-Path $folder '.git')) {
        return [pscustomobject]@{ Mode = 'inplace'; Repo = (Resolve-Path -LiteralPath $folder).Path; Scope = '.'; Dest = $null; RepoName = '(self)' }
    }
    return $null
}

# ---- folder has no repo: offer new repo or existing repo ----
function Prompt-Target([string]$folder, $repos) {
    Say "This folder has no git repo yet."
    Say "  [N] Create a new git repo for this folder (recommended)"
    if ($repos.Count -gt 0) {
        Say "  ... or add it into an existing repo:"
        for ($i = 0; $i -lt $repos.Count; $i++) {
            Say ("  [" + ($i + 1) + "] " + $repos[$i].Name + "  ->  " + $repos[$i].Path)
        }
    }
    $sel = Read-Host "Enter N for a new repo, or a number for an existing repo (q to cancel)"
    if ($sel -match '^[nN]$') {
        return [pscustomobject]@{ Mode = 'new'; Repo = $null; Scope = $null; Dest = $null; RepoName = '(new)' }
    }
    if ($sel -match '^[0-9]+$') {
        $n = [int]$sel
        if ($n -ge 1 -and $n -le $repos.Count) {
            $r = $repos[$n - 1]
            $rpFull = (Resolve-Path -LiteralPath $r.Path -ErrorAction SilentlyContinue).Path
            if (-not $rpFull) { Fail ("Repo path not found: " + $r.Path); return $null }
            $f = (Resolve-Path -LiteralPath $folder).Path.TrimEnd('\')
            $rpFull = $rpFull.TrimEnd('\')
            if ($f.StartsWith($rpFull + '\')) {
                $scope = $f.Substring($rpFull.Length + 1) -replace '\\', '/'
                return [pscustomobject]@{ Mode = 'inplace'; Repo = $rpFull; Scope = $scope; Dest = $null; RepoName = $r.Name }
            }
            return [pscustomobject]@{ Mode = 'copy'; Repo = $rpFull; Scope = (Split-Path -Leaf $folder); Dest = (Join-Path $rpFull (Split-Path -Leaf $folder)); RepoName = $r.Name }
        }
    }
    return $null
}

# ---- pick a repo from the list ----
function Pick-Repo($repos) {
    if ($repos.Count -eq 0) {
        Fail "No repos configured. Edit repos.txt and add lines like:  name|C:\path\to\repo"
        return $null
    }
    Say "Choose target repo:"
    for ($i = 0; $i -lt $repos.Count; $i++) {
        Say ("  [" + ($i + 1) + "] " + $repos[$i].Name + "  ->  " + $repos[$i].Path)
    }
    $sel = Read-Host "Enter number (or q to cancel)"
    if ($sel -match '^[0-9]+$') {
        $n = [int]$sel
        if ($n -ge 1 -and $n -le $repos.Count) { return $repos[$n - 1] }
    }
    return $null
}

function Confirm {
    $r = Read-Host "Proceed? [y/N]"
    return ($r -match '^[yY]')
}

# ---- polish a commit message with Claude, fall back to raw input ----
function Get-CommitMessage([string]$raw) {
    $raw = ($raw -replace "`r`n", ' ' -replace "`n", ' ' -replace '"', "'").Trim()
    if (-not $raw) { return "Update" }
    $claude = Get-Command claude -ErrorAction SilentlyContinue
    if ($claude) {
        try {
            Info "Polishing commit message with Claude..."
            $prompt = 'You are writing a git commit message. Rewrite the description below into ONE concise conventional-commit subject line (imperative mood, at most 72 chars). Match the language of the description (Chinese description -> Chinese message, English -> English). Output ONLY the message text, no quotes, no markdown, no explanation. Description: ' + $raw
            $out = & claude -p $prompt --output-format text 2>$null | Out-String
            $out = $out -replace '\x1b\[[0-9;]*m', ''
            $msgLine = $null
            foreach ($line in ($out -split "`r?`n")) {
                $t = $line.Trim()
                if (-not $t) { continue }
                if ($t.StartsWith('[') -or $t.StartsWith('{')) { continue }
                $msgLine = $t
                break
            }
            if ($msgLine) {
                $msgLine = $msgLine.Trim('`', '"', "'", ' ').Trim()
                if ($msgLine) { return $msgLine }
            }
        } catch { }
    }
    return $raw
}

# ---- stage, commit, push ----
function Do-CommitAndPush([string]$repo, [string]$scope, [string[]]$excluded, [string]$msg) {
    if ($scope -and $scope -ne '.') {
        & git -C $repo add -A -- $scope 2>$null
    } else {
        & git -C $repo add -A 2>$null
    }
    if ($excluded -and $excluded.Count -gt 0) {
        $i = 0
        while ($i -lt $excluded.Count) {
            $chunk = @()
            for ($j = 0; $j -lt 100 -and ($i + $j) -lt $excluded.Count; $j++) { $chunk += $excluded[$i + $j] }
            if ($chunk.Count -gt 0) { & git -C $repo reset -q -- @chunk 2>$null }
            $i += 100
        }
    }
    & git -C $repo diff --cached --quiet 2>$null
    if ($LASTEXITCODE -eq 0) {
        Info "Nothing staged to commit (already up to date, or everything was skipped)."
        return
    }
    $msgFile = Join-Path $env:TEMP ('gitmsg_' + [guid]::NewGuid().ToString('N') + '.txt')
    [System.IO.File]::WriteAllText($msgFile, $msg, (New-Object System.Text.UTF8Encoding($false)))
    & git -C $repo commit -F $msgFile
    $commitCode = $LASTEXITCODE
    Remove-Item $msgFile -Force -ErrorAction SilentlyContinue

    if ($commitCode -ne 0) {
        Fail ("Commit failed (git exit code " + $commitCode + "). Nothing was uploaded.")
        return
    }

    $remote = (& git -C $repo config --get remote.origin.url 2>$null)
    if (-not $remote) {
        Warn "No 'origin' remote on this repo. Commit created but NOT pushed yet."
        $url = Read-Host "Enter a remote URL to add as origin (or press Enter to skip):"
        if ($url.Trim()) { & git -C $repo remote add origin $url.Trim(); $remote = $url.Trim() }
    }
    if ($remote) {
        $branch = (& git -C $repo rev-parse --abbrev-ref HEAD 2>$null)
        & git -C $repo rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            & git -C $repo push -u origin $branch
        } else {
            & git -C $repo push
        }
        if ($LASTEXITCODE -ne 0) {
            Warn ("Push FAILED (git exit code " + $LASTEXITCODE + "). Commit created locally but NOT uploaded.")
            Info "Common causes: remote repo is not empty, or you lack push permission."
            return
        }
    }
    $hash = (& git -C $repo rev-parse --short HEAD 2>$null)
    Info ("Done. commit " + $hash)
}

# ---- process one folder ----
function Process-Folder([string]$folder, $repos, [string[]]$rules) {
    Step ("Folder: " + $folder)

    $target = Resolve-Target $folder $repos
    if ($null -eq $target) {
        $target = Prompt-Target $folder $repos
        if ($null -eq $target) { Fail "No target selected, skipping."; return }
        if ($target.Mode -eq 'new') {
            Info "Creating a new git repo for this folder..."
            & git -C $folder init -b main 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { & git -C $folder init 2>&1 | Out-Null }
            $target = [pscustomobject]@{ Mode = 'inplace'; Repo = (Resolve-Path -LiteralPath $folder).Path; Scope = '.'; Dest = $null; RepoName = '(new)' }
        }
    }

    $repo = $target.Repo
    $mode = $target.Mode

    if ($mode -eq 'copy') {
        $allFiles = Get-Files $folder $rules
        $included = @(); $excluded = @()
        foreach ($f in $allFiles) { if (Match-Rule $f.Rel $rules) { $excluded += $f } else { $included += $f } }
        Info ("Mode : copy -> " + $target.Dest)
        Info ("Core files to upload : " + $included.Count + "   |   Skipped (test/build) : " + $excluded.Count)
        $shown = [Math]::Min(30, $excluded.Count)
        if ($shown -gt 0) {
            Info "Skipped examples:"
            for ($i = 0; $i -lt $shown; $i++) { Info ("    - " + $excluded[$i].Rel) }
        }
        if ($included.Count -eq 0) { Info "No core files found. Nothing to do."; return }
        if (-not (Confirm)) { Info "Cancelled."; return }
        foreach ($f in $included) {
            $dst = Join-Path $target.Dest ($f.Rel -replace '/', '\')
            $dstDir = Split-Path -Parent $dst
            if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
            Copy-Item -LiteralPath $f.Abs -Destination $dst -Force
        }
        $desc = Read-Host "Describe what changed (short):"
        $msg = Get-CommitMessage $desc
        Info ("Commit message: " + $msg)
        Do-CommitAndPush $repo $target.Scope @() $msg
    } else {
        $scope = $target.Scope
        $changed = Get-Changed $repo $scope
        $commitPaths = @(); $skipPaths = @()
        foreach ($c in $changed) { if (Match-Rule $c $rules) { $skipPaths += $c } else { $commitPaths += $c } }
        $scopeLabel = $(if ($scope -and $scope -ne '.') { $scope } else { '<repo root>' })
        Info ("Mode : in-place in " + $repo + "  (scope: " + $scopeLabel + ")")
        Info ("Changed files to commit : " + $commitPaths.Count + "   |   Skipped (test/build) : " + $skipPaths.Count)
        $shown = [Math]::Min(30, $skipPaths.Count)
        if ($shown -gt 0) {
            Info "Skipped:"
            for ($i = 0; $i -lt $shown; $i++) { Info ("    - " + $skipPaths[$i]) }
        }
        if ($commitPaths.Count -eq 0) { Info "Only skipped/test files changed, or nothing changed. Nothing to commit."; return }
        if (-not (Confirm)) { Info "Cancelled."; return }
        $desc = Read-Host "Describe what changed (short):"
        $msg = Get-CommitMessage $desc
        Info ("Commit message: " + $msg)
        Do-CommitAndPush $repo $scope $skipPaths $msg
    }
}

# ============ main ============
Step "GitHub Upload Helper"

$rawArgs = @()
if ($args -and $args.Count -gt 0) { $rawArgs = $args }

$folders = @()
if ($rawArgs.Count -gt 0) {
    $folders = Reconstruct-Paths $rawArgs
} else {
    $p = Pick-Folder
    if ($p) { $folders = @($p) }
}
if ($folders.Count -eq 0) { Fail "No folder given. Exiting."; return }

$valid = @()
foreach ($f in $folders) {
    if (Test-Path -LiteralPath $f -PathType Container) { $valid += (Resolve-Path -LiteralPath $f).Path }
    else { Warn ("Skipping (not a folder): " + $f) }
}
if ($valid.Count -eq 0) { Fail "No valid folders. Exiting."; return }

$rules = Get-Rules
$repos = Get-Repos

foreach ($folder in $valid) {
    Process-Folder $folder $repos $rules
}

Say "`nAll done."
