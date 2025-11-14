param(
    [Parameter(Mandatory=$false)]
    [string]$directoryPath
)

if (-not $directoryPath -or [string]::IsNullOrWhiteSpace($directoryPath)) {
    $directoryPath = Read-Host "Enter the directory path"
}

try {
    $env:LANG = "en_US.UTF-8"
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

$script:successCount = 0
$script:failedCount = 0
$script:skippedCount = 0

function Run-Fetch($folder)
{
    $gitPath = Join-Path -Path $folder.FullName -ChildPath ".git"
    
    if (Test-Path -Path $gitPath) {
        $repoPath = $folder.FullName
        Write-Output "========================================"
        Write-Output $repoPath
        
        try {
            # Check for uncommitted changes
            $status = & git -C $repoPath status --porcelain 2>&1
            if ($status -and $status.Length -gt 0) {
                Write-Output "! 检测到未提交的更改，跳过拉取"
                $script:skippedCount++
                return
            }

            # Detect current branch
            $currentBranch = (& git -C $repoPath branch --show-current 2>&1).Trim()
            if (-not $currentBranch -or [string]::IsNullOrWhiteSpace($currentBranch)) {
                $currentBranch = (& git -C $repoPath rev-parse --abbrev-ref HEAD 2>&1).Trim()
            }
            
            if ($currentBranch -eq 'HEAD' -or [string]::IsNullOrWhiteSpace($currentBranch)) {
                Write-Output "! 分离的 HEAD 状态，跳过"
                $script:skippedCount++
                return
            }

            Write-Output "📌 当前分支: $currentBranch"

            # Check if remote exists
            $remotes = & git -C $repoPath remote 2>&1
            if (-not $remotes -or $remotes.Length -eq 0) {
                Write-Output "! 没有配置远程仓库，跳过"
                $script:skippedCount++
                return
            }

            # Run git fetch
            Write-Output "🔄 正在执行 git fetch..."
            $fetchOutput = & git -C $repoPath fetch origin 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Output "❌ Fetch 失败: $fetchOutput"
                $script:failedCount++
                return
            }
            
            if ($fetchOutput) {
                Write-Output $fetchOutput
            }

            # Check if pull is needed
            $localCommit = (& git -C $repoPath rev-parse $currentBranch 2>&1).Trim()
            $remoteCommit = (& git -C $repoPath rev-parse "origin/$currentBranch" 2>&1).Trim()
            
            if ($localCommit -eq $remoteCommit) {
                Write-Output "✓ 已是最新，无需拉取"
                $script:successCount++
                return
            }

            # Run git pull with rebase
            Write-Output "🔄 正在执行 git pull --rebase..."
            $pullOutput = & git -C $repoPath pull origin $currentBranch --rebase 2>&1
            $exitCode = $LASTEXITCODE
            
            if ($pullOutput) {
                Write-Output $pullOutput
            }

            if ($exitCode -eq 0) {
                Write-Output "✓ 拉取成功"
                $script:successCount++
            } else {
                Write-Output "❌ 拉取失败 (退出码: $exitCode)"
                $script:failedCount++
            }
        } catch {
            Write-Output "❌ 异常: $($_.Exception.Message)"
            $script:failedCount++
        }
    } else {
        # Recursively process subdirectories
        try {
            $subdirs = $folder.GetDirectories()
            Map-Fetch $subdirs
        } catch {
            Write-Output "Error accessing directory $($folder.FullName): $_"
        }
    }
}

function Map-Fetch($folders)
{
    foreach ($folder in $folders) {
        Run-Fetch $folder
    }
}

Write-Output "开始处理目录: $directoryPath"
Write-Output "========================================"

$startTime = Get-Date
Map-Fetch (Get-ChildItem -Path $directoryPath -Directory -ErrorAction SilentlyContinue)
$endTime = Get-Date
$elapsed = ($endTime - $startTime).TotalSeconds

Write-Output "========================================"
Write-Output "📊 统计信息"
Write-Output "========================================"
Write-Output "v 成功: $($script:successCount)"
Write-Output "x 失败: $($script:failedCount)"
Write-Output "!  跳过: $($script:skippedCount)"
Write-Output "总计: $($script:successCount + $script:failedCount + $script:skippedCount)"
Write-Output "========================================"