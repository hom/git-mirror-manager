# Set UTF-8 encoding for proper display of Chinese characters
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$directory = Read-Host "Enter the directory path"

$stats = @{ Success = 0; Failed = 0; Skipped = 0 }
$failedRepositories = @()

function Run-Fetch($folder) {
    $gitPath = Join-Path -Path $folder.FullName -ChildPath ".git"
    
    if (Test-Path -Path $gitPath) {
        $currentBranch = (git -C $folder.FullName branch --show-current).Trim()
        $relativePath = $folder.FullName.Substring($script:basePath.Length).TrimStart('\', '/')
        
        Write-Host "[$relativePath] " -NoNewline -ForegroundColor Cyan
        git -C $folder.FullName pull origin $currentBranch --rebase 2>&1 | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK]" -ForegroundColor Green
            $script:stats.Success++
        } else {
            Write-Host "[FAIL]" -ForegroundColor Red
            $script:stats.Failed++
            $script:failedRepositories += $relativePath
        }
    } else {
        $script:stats.Skipped++
        Map-Fetch $folder.GetDirectories()
    }
}

function Map-Fetch($folders) {
    foreach ($folder in $folders) {
        Run-Fetch $folder
    }
}

$basePath = (Resolve-Path $directory).Path
Map-Fetch (Get-ChildItem -Path $directory -Directory)

Write-Host "`n统计: " -NoNewline
Write-Host "成功 $($stats.Success) " -NoNewline -ForegroundColor Green
Write-Host "失败 $($stats.Failed) " -NoNewline -ForegroundColor Red
Write-Host "跳过 $($stats.Skipped)" -ForegroundColor Yellow

if ($failedRepositories.Count -gt 0) {
    Write-Host "`n失败的仓库:" -ForegroundColor Red
    foreach ($repo in $failedRepositories) {
        Write-Host "  - $repo" -ForegroundColor Red
    }
}