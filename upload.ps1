# ============================================================
#  Git 新手助手 (Git Beginner Helper)
#
#  双击打开 = 中文菜单;拖文件夹上来 = 直接进入上传流程。
#  菜单:上传新项目 / 更新项目 / 查看改动 / 拉取更新。
#
#  重要:本文件必须保存为 UTF-8(带 BOM)。PowerShell 5.1 对
#  无 BOM 的 .ps1 会按 GBK 读取,中文会乱码、甚至吞掉下一行,
#  导致脚本出错。若被编辑器改回无 BOM,请重新存为 UTF-8 带 BOM。
# ============================================================

# 'Stop' 会把 git/claude 等原生命令的任何 stderr 当成致命错误
# (哪怕 2>$null),一个无害的 CRLF 警告就会中断脚本。用
# 'Continue',git 成功与否靠 $LASTEXITCODE 判断。
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { [Console]::Title = 'Git 新手助手' } catch { }

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
function Ok   { param([string]$m) Write-Host ("   + " + $m) -ForegroundColor Green }

# ---- 检查 git 是否可用,不可用则给出中文安装引导 ----
function Test-Prerequisites {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) {
        Write-Host ""
        Write-Host "   X 没有找到 git,本工具无法工作。" -ForegroundColor Red
        Write-Host ""
        Write-Host "   请先安装 Git for Windows:" -ForegroundColor Yellow
        Write-Host "     https://git-scm.com/download/win" -ForegroundColor Cyan
        Write-Host "   安装时一路点『下一步』即可,装完重新双击本工具。" -ForegroundColor Yellow
        Write-Host ""
        Read-Host "   按回车退出"
        return $false
    }
    return $true
}

# ---- 还原拖到 .cmd 上的路径(空格会被拆开) ----
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

# ---- 弹窗选择文件夹(无参数时) ----
function Pick-Folder {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "请选择一个文件夹"
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dlg.SelectedPath
        }
    } catch { }
    return (Read-Host "   请输入文件夹完整路径").Trim()
}

# ---- 读取项目列表 repos.txt ----
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

# ---- 把项目追加进 repos.txt ----
function Add-Repo([string]$name, [string]$path) {
    $existing = Get-Repos
    foreach ($r in $existing) { if ($r.Path -ieq $path) { Ok "已在列表中。"; return } }
    $line = "`r`n" + $name + '|' + $path
    [System.IO.File]::AppendAllText($reposFile, $line, (New-Object System.Text.UTF8Encoding($false)))
    Ok ("已加入更新列表:" + $name + " -> " + $path)
}

# ---- 读取过滤规则 filter-rules.txt ----
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

# ---- 读取源文件夹的 .gitignore(尽力支持,暂不支持 ! 取反) ----
function Get-GitIgnorePatterns([string]$root) {
    $pat = New-Object System.Collections.Generic.List[string]
    $gi = Join-Path $root '.gitignore'
    if (Test-Path -LiteralPath $gi) {
        foreach ($line in Get-Content -LiteralPath $gi -Encoding UTF8) {
            $l = $line.Trim()
            if ($l -eq '' -or $l.StartsWith('#')) { continue }
            if ($l.StartsWith('!')) { continue }
            $l = $l -replace '\\', '/'
            if ($l.StartsWith('/')) { $l = $l.Substring(1) }
            if ($l) { $pat.Add($l) }
        }
    }
    return $pat
}

# ---- 目录名是否应跳过(不继续深入) ----
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

# ---- 相对路径是否命中排除规则 ----
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

# ---- 遍历文件夹,剪掉被排除的目录 ----
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

# ---- 取范围内有改动的路径(含状态),中文路径不转义 ----
function Get-Changed([string]$repo, [string]$scope) {
    $gitArgs = @('-c', 'core.quotepath=false', 'status', '--porcelain=v1', '--untracked-files=all')
    if ($scope -and $scope -ne '.') { $gitArgs += @('--', $scope) } else { $gitArgs += @('--', '.') }
    $lines = & git -C $repo @gitArgs 2>$null
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($line in $lines) {
        if ($line -isnot [string]) { continue }
        if ($line.Length -lt 4) { continue }
        $status = $line.Substring(0, 2)
        $p = $line.Substring(3)
        $idx = $p.IndexOf(' -> ')
        if ($idx -ge 0) { $p = $p.Substring($idx + 4) }
        $p = $p.Trim()
        if ($p) { $out.Add([pscustomobject]@{ Status = $status; Path = ($p -replace '\\', '/') }) }
    }
    return $out
}

# ---- 识别目标仓库/方式 ----
function Resolve-Target([string]$folder, $repos) {
    if (Test-Path -LiteralPath (Join-Path $folder '.git')) {
        return [pscustomobject]@{ Mode = 'inplace'; Repo = (Resolve-Path -LiteralPath $folder).Path; Scope = '.'; Dest = $null; RepoName = '(自身)' }
    }
    return $null
}

# ---- 文件夹没有仓库:新建 或 放进已有仓库 ----
function Prompt-Target([string]$folder, $repos) {
    Say "这个文件夹还没有 git 仓库。"
    Say "  [N] 为它新建一个 git 仓库(推荐,适合第一次上传)"
    if ($repos.Count -gt 0) {
        Say "  ... 或者放进下面某个已有仓库:"
        for ($i = 0; $i -lt $repos.Count; $i++) {
            Say ("  [" + ($i + 1) + "] " + $repos[$i].Name + "  ->  " + $repos[$i].Path)
        }
    }
    $sel = Read-Host "输入 N 新建仓库,或输入数字选择已有仓库(输入 q 取消)"
    if ($sel -match '^[nN]$') {
        return [pscustomobject]@{ Mode = 'new'; Repo = $null; Scope = $null; Dest = $null; RepoName = '(新项目)' }
    }
    if ($sel -match '^[0-9]+$') {
        $n = [int]$sel
        if ($n -ge 1 -and $n -le $repos.Count) {
            $r = $repos[$n - 1]
            $rpFull = (Resolve-Path -LiteralPath $r.Path -ErrorAction SilentlyContinue).Path
            if (-not $rpFull) { Fail ("找不到仓库路径:" + $r.Path); return $null }
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

function Confirm {
    $r = Read-Host "   确认继续? [y/N]"
    return ($r -match '^[yY]')
}

# ---- 给没有 .gitignore 的新项目生成一个基础的 ----
function Ensure-StarterGitignore([string]$folder) {
    $gi = Join-Path $folder '.gitignore'
    if (Test-Path -LiteralPath $gi) { return }
    $lines = @(
        '# 由 Git 新手助手自动生成,可自行增删',
        'node_modules/',
        '__pycache__/',
        '.venv/',
        'venv/',
        'env/',
        'dist/',
        'build/',
        '.idea/',
        '.vscode/',
        '*.log',
        '*.pyc',
        '*.DS_Store',
        'Thumbs.db'
    )
    $content = ($lines -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($gi, $content, (New-Object System.Text.UTF8Encoding($false)))
    Ok ("已生成基础 .gitignore(忽略 node_modules 等常见文件)。")
}

# ---- 润色提交信息,失败则退回原文 ----
function Get-CommitMessage([string]$raw) {
    $raw = ($raw -replace "`r`n", ' ' -replace "`n", ' ' -replace '"', "'").Trim()
    if (-not $raw) { return "更新" }
    $claude = Get-Command claude -ErrorAction SilentlyContinue
    if ($claude) {
        try {
            Info "正在用 Claude 润色提交信息..."
            $prompt = 'You are writing a git commit message. Rewrite the description below into ONE concise subject line (imperative mood, at most 72 chars). Match the language of the description (Chinese -> Chinese, English -> English). Output ONLY the message text, no quotes, no markdown, no explanation. Description: ' + $raw
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

# ---- 提交并推送;无远程时引导建仓;返回是否成功 ----
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
        Info "没有需要提交的改动(可能已是最新,或改动都被过滤掉了)。"
        return $false
    }
    $msgFile = Join-Path $env:TEMP ('gitmsg_' + [guid]::NewGuid().ToString('N') + '.txt')
    [System.IO.File]::WriteAllText($msgFile, $msg, (New-Object System.Text.UTF8Encoding($false)))
    & git -C $repo commit -F $msgFile
    $commitCode = $LASTEXITCODE
    Remove-Item $msgFile -Force -ErrorAction SilentlyContinue

    if ($commitCode -ne 0) {
        Fail ("提交失败(git 退出码 " + $commitCode + "),本次没有上传任何东西。")
        return $false
    }

    $remote = (& git -C $repo config --get remote.origin.url 2>$null)
    if (-not $remote) {
        Write-Host ""
        Warn "这个仓库还没有关联 GitHub 远程仓库。"
        Write-Host ""
        Write-Host "   请按下面步骤在 GitHub 上新建一个空仓库:" -ForegroundColor Cyan
        Write-Host "     1) 打开  https://github.com/new" -ForegroundColor Yellow
        Write-Host ("     2) Repository name 填一个名字(建议:" + (Split-Path -Leaf $repo) + ")")
        Write-Host "     3) Public(公开)/ Private(私有) 任选"
        Write-Host "     4) README / .gitignore / license 三个复选框都【不要勾】"
        Write-Host "     5) 点绿色的 Create repository 按钮"
        Write-Host ""
        $url = Read-Host "   然后把新仓库的网址粘到这里(形如 https://github.com/你的名字/仓库名.git);直接回车则跳过推送"
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
            Warn ("推送失败(git 退出码 " + $LASTEXITCODE + ")。提交已保存在本地,但没有传到 GitHub。")
            Info "常见原因:远程仓库不是空的(建仓库时勾了 README),或者账号没有登录/权限。"
            Info "如果远程不是空的,可在 GitHub 网页上删掉该仓库,重新建一个空的再试。"
            return $false
        }
    }
    $hash = (& git -C $repo rev-parse --short HEAD 2>$null)
    Ok ("完成!commit " + $hash)
    return $true
}

# ---- 上传一个文件夹 ----
function Upload-Folder([string]$folder, $repos, [string[]]$rules) {
    Step ("上传:" + $folder)

    $target = Resolve-Target $folder $repos
    if ($null -eq $target) {
        $target = Prompt-Target $folder $repos
        if ($null -eq $target) { Fail "没有选择目标,已跳过。"; return $false }
        if ($target.Mode -eq 'new') {
            Info "正在为这个文件夹新建 git 仓库..."
            & git -C $folder init -b main 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { & git -C $folder init 2>&1 | Out-Null }
            Ensure-StarterGitignore $folder
            $target = [pscustomobject]@{ Mode = 'inplace'; Repo = (Resolve-Path -LiteralPath $folder).Path; Scope = '.'; Dest = $null; RepoName = '(新项目)' }
        }
    }

    $repo = $target.Repo
    $mode = $target.Mode

    if ($mode -eq 'copy') {
        $srcRules = @($rules) + @(Get-GitIgnorePatterns $folder)
        $allFiles = Get-Files $folder $srcRules
        $included = @(); $excluded = @()
        foreach ($f in $allFiles) { if (Match-Rule $f.Rel $srcRules) { $excluded += $f } else { $included += $f } }
        Info ("方式:复制到 -> " + $target.Dest)
        Info ("要上传的核心文件:" + $included.Count + " 个    已跳过(测试/构建等):" + $excluded.Count + " 个")
        $shown = [Math]::Min(30, $excluded.Count)
        if ($shown -gt 0) {
            Info "跳过的示例:"
            for ($i = 0; $i -lt $shown; $i++) { Info ("    - " + $excluded[$i].Rel) }
        }
        if ($included.Count -eq 0) { Info "没有找到核心文件,无需处理。"; return $false }
        if (-not (Confirm)) { Info "已取消。"; return $false }
        foreach ($f in $included) {
            $dst = Join-Path $target.Dest ($f.Rel -replace '/', '\')
            $dstDir = Split-Path -Parent $dst
            if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
            Copy-Item -LiteralPath $f.Abs -Destination $dst -Force
        }
        $desc = Read-Host "   这次做了什么改动?(一句话,直接回车用默认)"
        $msg = Get-CommitMessage $desc
        Info ("提交信息:" + $msg)
        return (Do-CommitAndPush $repo $target.Scope @() $msg)
    } else {
        $scope = $target.Scope
        $changed = Get-Changed $repo $scope
        $commitPaths = @(); $skipPaths = @()
        foreach ($c in $changed) {
            $isUntracked = ($c.Status -eq '??')
            if ($isUntracked -and (Match-Rule $c.Path $rules)) { $skipPaths += $c.Path }
            else { $commitPaths += $c.Path }
        }
        $scopeLabel = $(if ($scope -and $scope -ne '.') { $scope } else { '<仓库根目录>' })
        Info ("方式:原地提交 " + $repo + "  (范围:" + $scopeLabel + ")")
        Info ("有改动、将提交的文件:" + $commitPaths.Count + " 个    已跳过(测试/构建):" + $skipPaths.Count + " 个")
        $shown = [Math]::Min(30, $skipPaths.Count)
        if ($shown -gt 0) {
            Info "已跳过:"
            for ($i = 0; $i -lt $shown; $i++) { Info ("    - " + $skipPaths[$i]) }
        }
        if ($commitPaths.Count -eq 0) { Info "只有测试/构建文件变了,或没有改动,无需提交。"; return $false }
        if (-not (Confirm)) { Info "已取消。"; return $false }
        $desc = Read-Host "   这次做了什么改动?(一句话,直接回车用默认)"
        $msg = Get-CommitMessage $desc
        Info ("提交信息:" + $msg)
        return (Do-CommitAndPush $repo $scope $skipPaths $msg)
    }
}

# ---- 更新已有项目(一键更新) ----
function Update-Folder([string]$repoPath, [string[]]$rules) {
    $repo = (Resolve-Path -LiteralPath $repoPath).Path
    Step ("更新:" + $repo)
    $scope = '.'
    $changed = Get-Changed $repo $scope
    $commitPaths = @(); $skipPaths = @()
    foreach ($c in $changed) {
        $isUntracked = ($c.Status -eq '??')
        if ($isUntracked -and (Match-Rule $c.Path $rules)) { $skipPaths += $c.Path }
        else { $commitPaths += $c.Path }
    }
    if ($commitPaths.Count -eq 0) {
        Ok "没有需要提交的改动,工作区是干净的。"
        return
    }
    Info ("有改动、将提交的文件:" + $commitPaths.Count + " 个    已跳过(测试/构建):" + $skipPaths.Count + " 个")
    $shown = [Math]::Min(30, $commitPaths.Count)
    Info "将要提交:"
    for ($i = 0; $i -lt $shown; $i++) { Info ("    - " + $commitPaths[$i]) }
    if ($skipPaths.Count -gt 0) {
        $shown = [Math]::Min(10, $skipPaths.Count)
        Info "已跳过:"
        for ($i = 0; $i -lt $shown; $i++) { Info ("    - " + $skipPaths[$i]) }
    }
    $desc = Read-Host "   这次改了什么?(一句话,直接回车用『更新』)"
    $msg = Get-CommitMessage $desc
    Info ("提交信息:" + $msg)
    $null = Do-CommitAndPush $repo $scope $skipPaths $msg
}

# ---- 查看改动 ----
function Show-Status([string]$repoPath) {
    $repo = (Resolve-Path -LiteralPath $repoPath).Path
    Step ("改动:" + $repo)
    $changed = Get-Changed $repo '.'
    if ($changed.Count -eq 0) {
        Ok "没有改动,工作区是干净的。"
    } else {
        Info "以下文件有改动(状态码在前):"
        foreach ($c in $changed) { Info ("    [" + $c.Status + "] " + $c.Path) }
    }
    Write-Host ""
    Info "最近 5 条提交:"
    $log = & git -C $repo log --oneline -5 2>$null
    foreach ($l in $log) { if ($l -is [string] -and $l.Trim()) { Info ("    " + $l.Trim()) } }
}

# ---- 拉取更新 ----
function Pull-Repo([string]$repoPath) {
    $repo = (Resolve-Path -LiteralPath $repoPath).Path
    Step ("拉取:" + $repo)
    $remote = (& git -C $repo config --get remote.origin.url 2>$null)
    if (-not $remote) {
        Fail "这个仓库还没有关联远程仓库,无法拉取。"
        return
    }
    & git -C $repo pull
    if ($LASTEXITCODE -eq 0) { Ok "拉取完成。" }
    else { Warn ("拉取失败(git 退出码 " + $LASTEXITCODE + ")。") }
}

# ---- 选择一个项目路径(列表或手动) ----
function Pick-RepoPath($repos) {
    if ($repos.Count -eq 0) {
        Write-Host ""
        Warn "repos.txt 里还没有项目。"
        Info "可以直接选一个文件夹;或先用菜单『上传新项目』,上传后可自动加入列表。"
    }
    Write-Host ""
    Info "选择一个项目:"
    $idx = 0
    for ($i = 0; $i -lt $repos.Count; $i++) {
        $idx = $i + 1
        Write-Host ("    [" + $idx + "] " + $repos[$i].Name + "  ->  " + $repos[$i].Path)
    }
    $manual = $idx + 1
    Write-Host ("    [" + $manual + "] 手动选文件夹...")
    Write-Host "    [0] 返回"
    $sel = Read-Host "   请输入数字"
    if ($sel -match '^[0-9]+$') {
        $v = [int]$sel
        if ($v -ge 1 -and $v -le $repos.Count) {
            $p = $repos[$v - 1].Path
            if (Test-Path -LiteralPath $p) { return (Resolve-Path -LiteralPath $p).Path }
            Fail ("找不到路径:" + $p)
            return $null
        }
        if ($v -eq $manual) {
            $p = Pick-Folder
            if ($p) { return (Resolve-Path -LiteralPath $p).Path }
        }
    }
    return $null
}

# ---- 菜单处理 ----
function Menu-Upload {
    $p = Pick-Folder
    if (-not $p) { return }
    $p = (Resolve-Path -LiteralPath $p).Path
    $rules = Get-Rules
    $repos = Get-Repos
    $ok = Upload-Folder $p $repos $rules
    if ($ok) {
        $name = Split-Path -Leaf $p
        $r = Read-Host "   把这个项目加进『更新列表』,方便以后一键更新? [y/N]"
        if ($r -match '^[yY]') { Add-Repo $name $p }
    }
}

function Menu-Update {
    $repos = Get-Repos
    $p = Pick-RepoPath $repos
    if ($p) { Update-Folder $p (Get-Rules) }
}

function Menu-Status {
    $repos = Get-Repos
    $p = Pick-RepoPath $repos
    if ($p) { Show-Status $p }
}

function Menu-Pull {
    $repos = Get-Repos
    $p = Pick-RepoPath $repos
    if ($p) { Pull-Repo $p }
}

# ---- 主菜单 ----
function Show-Menu {
    while ($true) {
        Write-Host ""
        Write-Host "  ==========================================" -ForegroundColor Cyan
        Write-Host "              Git 新手助手" -ForegroundColor Cyan
        Write-Host "  ==========================================" -ForegroundColor Cyan
        Write-Host "    [1] 上传新项目    (第一次把这个项目传到 GitHub)"
        Write-Host "    [2] 更新项目      (改了东西,推上去)"
        Write-Host "    [3] 查看改动      (看看哪些文件变了)"
        Write-Host "    [4] 拉取更新      (下载远程的最新改动)"
        Write-Host "    [0] 退出"
        Write-Host ""
        $sel = Read-Host "   请输入数字后回车"
        switch ($sel) {
            '1' { Menu-Upload }
            '2' { Menu-Update }
            '3' { Menu-Status }
            '4' { Menu-Pull }
            '0' { Write-Host "  再见!"; return }
            default { Write-Host "  没看懂,请输入 0 到 4。" -ForegroundColor Yellow }
        }
    }
}

# ============ main ============
if (-not (Test-Prerequisites)) { return }

$rawArgs = @()
if ($args -and $args.Count -gt 0) { $rawArgs = $args }

if ($rawArgs.Count -gt 0) {
    # 拖拽模式:直接上传这些文件夹
    $folders = Reconstruct-Paths $rawArgs
    $rules = Get-Rules
    $repos = Get-Repos
    foreach ($f in $folders) {
        if (Test-Path -LiteralPath $f -PathType Container) {
            $null = Upload-Folder (Resolve-Path -LiteralPath $f).Path $repos $rules
        } else {
            Warn ("跳过(不是文件夹):" + $f)
        }
    }
    Say "`n全部完成。"
} else {
    Show-Menu
}
