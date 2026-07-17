# cherry-all: 将指定 commit cherry-pick 到选定的本地分支
# 用法:
#   cherry-all <commit-hash>
#   cherry-all <commit-hash> -Branches master,feature/a
#   cherry-all <commit-hash> -Exclude main,master
#   cherry-all <commit-hash> -IncludeOnly feature/*,fix/*
#   cherry-all <commit-hash> -All
#   cherry-all <commit-hash> -DryRun

param(
    [Parameter(Position = 0)]
    [string]$Commit,

    # 直接指定分支（跳过交互选择），支持通配符
    [string[]]$Branches = @(),

    [string[]]$Exclude = @(),

    [string[]]$IncludeOnly = @(),

    # 不交互，直接作用于过滤后的全部本地分支
    [switch]$All,

    # 自动 stash 当前改动，结束后再 stash pop
    [switch]$Stash,

    # 跳过工作区干净检查（有冲突风险，慎用）
    [switch]$Force,

    [switch]$DryRun,

    [switch]$ContinueOnConflict
)

$ErrorActionPreference = "Stop"

# 修复 Windows 下 git 中文分支名乱码：按 UTF-8 解码外部命令输出
try { chcp 65001 | Out-Null } catch {}
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$env:LC_ALL = "C.UTF-8"

function Write-Info([string]$msg) { Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "[OK]    $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-Err([string]$msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }

# 以 UTF-8 读取 git 标准输出，避免分支名/提交说明乱码
function Invoke-GitText {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$GitArgs,
        [switch]$AllowFail
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "git"
    $psi.Arguments = ($GitArgs | ForEach-Object {
        $a = "$_"
        if ($a -match '[\s"]') { '"' + ($a -replace '\\', '\\' -replace '"', '\"') + '"' } else { $a }
    }) -join " "
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.WorkingDirectory = (Get-Location).Path
    $p = [System.Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    if (-not $AllowFail -and $p.ExitCode -ne 0) {
        throw ("git {0} 失败({1}): {2}" -f ($GitArgs -join " "), $p.ExitCode, $stderr.Trim())
    }
    return @{
        ExitCode = $p.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

function Invoke-GitLines {
    param([string[]]$GitArgs)
    $r = Invoke-GitText -GitArgs $GitArgs
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($r.StdOut -split "`r?`n")) {
        $t = $line.TrimEnd()
        if ($t -ne "") { [void]$list.Add($t) }
    }
    # 逗号运算符：阻止 PowerShell 展开集合；否则单行时返回 string，[0] 会取到首字符
    return ,$list
}

# 安全取第一行（避免 string[0] 取字符）
function Get-GitFirstLine {
    param([string[]]$GitArgs)
    $lines = @(Invoke-GitLines -GitArgs $GitArgs)
    if ($lines.Count -eq 0) { return $null }
    return [string]$lines[0]
}

# 解析选择输入：支持 1,3,5-8 / a|all / * 
function ConvertFrom-BranchSelection {
    param(
        [string]$InputText,
        [string[]]$CandidateBranches
    )
    $text = $InputText.Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }

    if ($text -match '^(a|all|\*)$') {
        return @($CandidateBranches)
    }

    $selected = New-Object System.Collections.Generic.List[string]
    $parts = $text -split '[,，\s]+' | Where-Object { $_ -ne "" }

    foreach ($part in $parts) {
        if ($part -match '^\d+\-\d+$') {
            $range = $part -split '-'
            $start = [int]$range[0]
            $end = [int]$range[1]
            if ($start -gt $end) { $tmp = $start; $start = $end; $end = $tmp }
            for ($i = $start; $i -le $end; $i++) {
                if ($i -lt 1 -or $i -gt $CandidateBranches.Count) {
                    throw "编号越界: $i（有效范围 1-$($CandidateBranches.Count)）"
                }
                $name = $CandidateBranches[$i - 1]
                if (-not $selected.Contains($name)) { [void]$selected.Add($name) }
            }
        }
        elseif ($part -match '^\d+$') {
            $i = [int]$part
            if ($i -lt 1 -or $i -gt $CandidateBranches.Count) {
                throw "编号越界: $i（有效范围 1-$($CandidateBranches.Count)）"
            }
            $name = $CandidateBranches[$i - 1]
            if (-not $selected.Contains($name)) { [void]$selected.Add($name) }
        }
        else {
            # 按名称/通配符匹配
            $matched = @($CandidateBranches | Where-Object { $_ -like $part })
            if ($matched.Count -eq 0) {
                throw "未匹配到分支: $part"
            }
            foreach ($name in $matched) {
                if (-not $selected.Contains($name)) { [void]$selected.Add($name) }
            }
        }
    }

    return @($selected)
}

# 交互输入 commit hash
if ([string]::IsNullOrWhiteSpace($Commit)) {
    $Commit = Read-Host "请输入要 cherry-pick 的 commit hash"
}
$Commit = $Commit.Trim()
if ([string]::IsNullOrWhiteSpace($Commit)) {
    Write-Err "未提供 commit hash，已退出。"
    exit 1
}

# 确认在 git 仓库内
try {
    $repoRoot = Get-GitFirstLine -GitArgs @("rev-parse", "--show-toplevel")
    if (-not $repoRoot) { throw "not a git repo" }
} catch {
    Write-Err "当前目录不是 git 仓库，请先 cd 到目标仓库再执行。"
    exit 1
}

# 校验 commit 是否存在（不用 ^{commit}，避免 Windows 下 ^ 转义问题）
try {
    $fullHash = Get-GitFirstLine -GitArgs @("rev-parse", "--verify", $Commit)
} catch {
    $fullHash = $null
}
if (-not $fullHash) {
    Write-Err "找不到 commit: $Commit"
    exit 1
}

$shortHash = Get-GitFirstLine -GitArgs @("rev-parse", "--short", $fullHash)
$commitMsg = Get-GitFirstLine -GitArgs @("-c", "core.quotepath=false", "log", "-1", "--pretty=format:%s", $fullHash)
Write-Info "仓库: $repoRoot"
Write-Info "Commit: $shortHash ($fullHash)"
Write-Info "说明: $commitMsg"

# 仅检查已跟踪文件的未提交改动（未跟踪文件一般不阻止 checkout）
$didStash = $false
$statusLines = @(Invoke-GitLines -GitArgs @("status", "--porcelain", "--untracked-files=no"))
if ($statusLines.Count -gt 0) {
    if ($Force) {
        Write-Warn "工作区有 $($statusLines.Count) 处未提交改动，已用 -Force 跳过检查。"
    }
    elseif ($Stash) {
        Write-Info "工作区有 $($statusLines.Count) 处未提交改动，自动 stash..."
        $stashResult = Invoke-GitText -GitArgs @("stash", "push", "-u", "-m", "cherry-all auto-stash") -AllowFail
        if ($stashResult.ExitCode -ne 0) {
            Write-Err "自动 stash 失败。"
            if ($stashResult.StdErr) { Write-Host $stashResult.StdErr }
            exit 1
        }
        $didStash = $true
        Write-Ok "已 stash，结束后会尝试恢复。"
    }
    else {
        Write-Err "工作区有未提交改动（$($statusLines.Count) 个），请先 commit / stash，或加 -Stash / -Force。"
        $statusLines | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
        if ($statusLines.Count -gt 20) {
            Write-Host "  ... 还有 $($statusLines.Count - 20) 个"
        }
        exit 1
    }
}

# 记录当前分支，结束后切回
$originalBranch = Get-GitFirstLine -GitArgs @("-c", "core.quotepath=false", "rev-parse", "--abbrev-ref", "HEAD")
if ($originalBranch -eq "HEAD") {
    Write-Err "当前处于 detached HEAD，请先切到某个分支再执行。"
    exit 1
}
Write-Info "当前分支: $originalBranch"

# 收集本地分支（不含 remote）
$allLocalBranches = @(Invoke-GitLines -GitArgs @("-c", "core.quotepath=false", "for-each-ref", "--format=%(refname:short)", "refs/heads/"))
$candidates = @($allLocalBranches)

if ($IncludeOnly.Count -gt 0) {
    $candidates = @($candidates | Where-Object {
        $b = $_
        $IncludeOnly | Where-Object { $b -like $_ } | Select-Object -First 1
    })
}

if ($Exclude.Count -gt 0) {
    $candidates = @($candidates | Where-Object {
        $b = $_
        -not ($Exclude | Where-Object { $b -like $_ } | Select-Object -First 1)
    })
}

$candidates = @($candidates | Sort-Object)
if ($candidates.Count -eq 0) {
    Write-Warn "没有匹配到任何本地分支。"
    exit 0
}

# 选择目标分支
$selectedBranches = @()

if ($Branches.Count -gt 0) {
    # 命令行直接指定
    $resolved = New-Object System.Collections.Generic.List[string]
    foreach ($pat in $Branches) {
        $matched = @($candidates | Where-Object { $_ -like $pat })
        if ($matched.Count -eq 0) {
            # 也允许指定尚未在 candidates 里的精确本地分支名
            $exact = @($allLocalBranches | Where-Object { $_ -eq $pat })
            if ($exact.Count -eq 0) {
                Write-Err "指定的分支不存在或已被过滤: $pat"
                exit 1
            }
            $matched = $exact
        }
        foreach ($name in $matched) {
            if (-not $resolved.Contains($name)) { [void]$resolved.Add($name) }
        }
    }
    $selectedBranches = @($resolved)
}
elseif ($All) {
    $selectedBranches = @($candidates)
}
else {
    # 交互选择
    Write-Host ""
    Write-Info "可选本地分支（共 $($candidates.Count) 个）:"
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $mark = if ($candidates[$i] -eq $originalBranch) { " (当前)" } else { "" }
        Write-Host ("  [{0,3}] {1}{2}" -f ($i + 1), $candidates[$i], $mark)
    }
    Write-Host ""
    Write-Host "选择方式:" -ForegroundColor DarkGray
    Write-Host "  编号: 1,3,5-8" -ForegroundColor DarkGray
    Write-Host "  名称/通配: master,项目-*" -ForegroundColor DarkGray
    Write-Host "  全部: a / all / *" -ForegroundColor DarkGray
    Write-Host "  取消: 直接回车" -ForegroundColor DarkGray
    Write-Host ""

    $raw = Read-Host "请选择要 cherry-pick 的分支"
    try {
        $selectedBranches = @(ConvertFrom-BranchSelection -InputText $raw -CandidateBranches $candidates)
    } catch {
        Write-Err "$_"
        exit 1
    }

    if ($selectedBranches.Count -eq 0) {
        Write-Warn "未选择任何分支，已取消。"
        exit 0
    }
}

Write-Host ""
Write-Info "将处理 $($selectedBranches.Count) 个分支:"
$selectedBranches | ForEach-Object { Write-Host "  - $_" }

if ($DryRun) {
    Write-Warn "DryRun 模式，不执行实际 cherry-pick。"
    exit 0
}

$confirm = Read-Host "确认继续？(y/N)"
if ($confirm -notin @("y", "Y", "yes", "YES")) {
    Write-Warn "已取消。"
    exit 0
}

$okList = New-Object System.Collections.Generic.List[string]
$skipList = New-Object System.Collections.Generic.List[string]
$failList = New-Object System.Collections.Generic.List[string]

foreach ($branch in $selectedBranches) {
    Write-Host ""
    Write-Info "==== 分支: $branch ===="

    try {
        $co = Invoke-GitText -GitArgs @("-c", "core.quotepath=false", "checkout", $branch) -AllowFail
        if ($co.ExitCode -ne 0) {
            if ($co.StdErr) { Write-Host $co.StdErr }
            throw "checkout 失败"
        }
        if ($co.StdOut) { Write-Host $co.StdOut.TrimEnd() }
        if ($co.StdErr) { Write-Host $co.StdErr.TrimEnd() }

        # 已包含该 commit 则跳过
        $anc = Invoke-GitText -GitArgs @("merge-base", "--is-ancestor", $fullHash, "HEAD") -AllowFail
        if ($anc.ExitCode -eq 0) {
            Write-Warn "已包含该 commit，跳过。"
            [void]$skipList.Add($branch)
            continue
        }

        $cp = Invoke-GitText -GitArgs @("cherry-pick", $fullHash) -AllowFail
        if ($cp.StdOut) { Write-Host $cp.StdOut.TrimEnd() }
        if ($cp.StdErr) { Write-Host $cp.StdErr.TrimEnd() }
        if ($cp.ExitCode -ne 0) {
            Write-Err "cherry-pick 冲突或失败。"
            [void](Invoke-GitText -GitArgs @("cherry-pick", "--abort") -AllowFail)
            [void]$failList.Add($branch)

            if (-not $ContinueOnConflict) {
                Write-Err "已中止。可用 -ContinueOnConflict 跳过失败分支继续。"
                break
            }
            continue
        }

        Write-Ok "cherry-pick 成功 -> $branch"
        [void]$okList.Add($branch)
    } catch {
        Write-Err "处理分支 $branch 时出错: $_"
        [void](Invoke-GitText -GitArgs @("cherry-pick", "--abort") -AllowFail)
        [void]$failList.Add($branch)
        if (-not $ContinueOnConflict) { break }
    }
}

# 切回原分支
Write-Host ""
Write-Info "切回原分支: $originalBranch"
[void](Invoke-GitText -GitArgs @("-c", "core.quotepath=false", "checkout", $originalBranch) -AllowFail)

# 恢复自动 stash
if ($didStash) {
    Write-Info "恢复之前的 stash..."
    $pop = Invoke-GitText -GitArgs @("stash", "pop") -AllowFail
    if ($pop.ExitCode -ne 0) {
        Write-Warn "stash pop 失败，请手动处理: git stash list / git stash pop"
        if ($pop.StdErr) { Write-Host $pop.StdErr }
    } else {
        Write-Ok "stash 已恢复。"
    }
}

Write-Host ""
Write-Host "========== 结果汇总 ==========" -ForegroundColor Magenta
Write-Ok  "成功 ($($okList.Count)): $($okList -join ', ')"
Write-Warn "跳过 ($($skipList.Count)): $($skipList -join ', ')"
Write-Err  "失败 ($($failList.Count)): $($failList -join ', ')"

if ($failList.Count -gt 0) { exit 2 } else { exit 0 }