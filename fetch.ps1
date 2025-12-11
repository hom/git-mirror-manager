# Set UTF-8 encoding for proper display of Chinese characters
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$directory = Read-Host "Enter the directory path"

$stats = @{ Success = 0; Failed = 0; Skipped = 0 }

function Run-Fetch($folder) {
    $gitPath = Join-Path -Path $folder.FullName -ChildPath ".git"
    
    if (Test-Path -Path $gitPath) {
        $currentBranch = (git -C $folder.FullName branch --show-current).Trim()
        
        Write-Host "[$folder] " -NoNewline -ForegroundColor Cyan
        git -C $folder.FullName pull origin $currentBranch --rebase 2>&1 | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK]" -ForegroundColor Green
            $script:stats.Success++
        } else {
            Write-Host "[FAIL]" -ForegroundColor Red
            $script:stats.Failed++
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

Map-Fetch (Get-ChildItem -Path $directory -Directory)

Write-Host "`n统计: " -NoNewline
Write-Host "成功 $($stats.Success) " -NoNewline -ForegroundColor Green
Write-Host "失败 $($stats.Failed) " -NoNewline -ForegroundColor Red
Write-Host "跳过 $($stats.Skipped)" -ForegroundColor Yellow