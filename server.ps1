$ErrorActionPreference = "Stop"

$script:cancelFlag = $false

$prefix = "http://localhost:8080/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Clear()
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Output "Server running at $prefix"

function Send-TextResponse([System.Net.HttpListenerResponse]$resp, [string]$text, [int]$status = 200, [string]$contentType = "text/plain; charset=utf-8") {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $resp.StatusCode = $status
    $resp.ContentType = $contentType
    $resp.ContentLength64 = $bytes.Length
    $resp.OutputStream.Write($bytes,0,$bytes.Length)
    $resp.OutputStream.Close()
}

function Send-SseEvent([System.Net.HttpListenerResponse]$resp, [string]$eventName, $payload) {
    $resp.ContentType = "text/event-stream"
    $resp.StatusCode = 200
    $resp.SendChunked = $true
    $resp.KeepAlive = $true
    $resp.Headers.Remove("Cache-Control")
    $resp.Headers.Add("Cache-Control","no-cache")

    $json = ($payload | ConvertTo-Json -Depth 6 -Compress)
    $frame = "event: $eventName`n" + "data: $json`n`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($frame)
    $resp.OutputStream.Write($bytes,0,$bytes.Length)
    try { $resp.OutputStream.Flush() } catch {}
}

function Walk-And-Pull([System.Net.HttpListenerResponse]$resp, [string]$rootDir) {
    $success = 0; $failed = 0; $skipped = 0; $cancelled = $false
    $script:currentResponse = $resp

    function Send-Log([string]$path, [string]$line, [string]$stream = 'stdout') {
        try {
            Send-SseEvent $script:currentResponse 'repo-log' @{ path = $path; stream = $stream; line = $line }
        } catch {
            Write-Host "Failed to send log: $_"
        }
    }

    function Process-Folder([System.IO.DirectoryInfo]$folder) {
        $gitPath = Join-Path -Path $folder.FullName -ChildPath ".git"
        if ($script:cancelFlag) { $script:cancelled = $true; return }
        
        if (Test-Path -Path $gitPath) {
            $repoPath = $folder.FullName
            Send-SseEvent $resp 'repo-start' @{ path = $repoPath }
            
            try {
                # Check if repo has uncommitted changes
                $status = & git -C $repoPath status --porcelain 2>&1
                if ($status -and $status.Length -gt 0) {
                    Send-Log $repoPath "检测到未提交的更改，跳过拉取" "stderr"
                    $script:skipped++
                    Send-SseEvent $resp 'repo-status' @{ path = $repoPath; status = 'skipped'; reason = 'uncommitted changes' }
                    return
                }

                # Detect current branch
                $branch = (& git -C $repoPath branch --show-current 2>&1).Trim()
                if (-not $branch -or [string]::IsNullOrWhiteSpace($branch)) {
                    $branch = (& git -C $repoPath rev-parse --abbrev-ref HEAD 2>&1).Trim()
                }
                
                if ($branch -eq 'HEAD' -or [string]::IsNullOrWhiteSpace($branch)) {
                    Send-Log $repoPath "分离的 HEAD 状态，跳过" "stderr"
                    $script:skipped++
                    Send-SseEvent $resp 'repo-status' @{ path = $repoPath; status = 'skipped'; reason = 'detached HEAD' }
                    return
                }

                Send-Log $repoPath "当前分支: $branch"
                
                # Check if remote exists
                $remotes = & git -C $repoPath remote 2>&1
                if (-not $remotes -or $remotes.Length -eq 0) {
                    Send-Log $repoPath "没有配置远程仓库，跳过" "stderr"
                    $script:skipped++
                    Send-SseEvent $resp 'repo-status' @{ path = $repoPath; status = 'skipped'; reason = 'no remote' }
                    return
                }

                # Run git fetch first
                Send-Log $repoPath "正在执行 git fetch..."
                $fetchOutput = & git -C $repoPath fetch origin 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Send-Log $repoPath "Fetch 失败: $fetchOutput" "stderr"
                    $script:failed++
                    Send-SseEvent $resp 'repo-status' @{ path = $repoPath; status = 'failed'; reason = 'fetch failed' }
                    return
                }
                
                foreach ($line in $fetchOutput) {
                    if ($line) { Send-Log $repoPath $line }
                }

                if ($script:cancelFlag) { $script:cancelled = $true; return }

                # Check if pull is needed
                $localCommit = (& git -C $repoPath rev-parse $branch 2>&1).Trim()
                $remoteCommit = (& git -C $repoPath rev-parse "origin/$branch" 2>&1).Trim()
                
                if ($localCommit -eq $remoteCommit) {
                    Send-Log $repoPath "已是最新，无需拉取"
                    $script:success++
                    Send-SseEvent $resp 'repo-status' @{ path = $repoPath; status = 'success'; upToDate = $true }
                    return
                }

                # Run git pull with rebase
                Send-Log $repoPath "正在执行 git pull --rebase..."
                $pullOutput = & git -C $repoPath pull origin $branch --rebase 2>&1
                $exitCode = $LASTEXITCODE
                
                foreach ($line in $pullOutput) {
                    if ($line) { 
                        $isError = $exitCode -ne 0
                        Send-Log $repoPath $line $(if ($isError) { "stderr" } else { "stdout" })
                    }
                }

                if ($script:cancelFlag) { 
                    $script:cancelled = $true
                    Send-SseEvent $resp 'repo-status' @{ path = $repoPath; status = 'cancelled' }
                    return
                }

                if ($exitCode -eq 0) {
                    Send-Log $repoPath "✓ 拉取成功"
                    $script:success++
                    Send-SseEvent $resp 'repo-status' @{ path = $repoPath; status = 'success' }
                } else {
                    Send-Log $repoPath "✗ 拉取失败 (退出码: $exitCode)" "stderr"
                    $script:failed++
                    Send-SseEvent $resp 'repo-status' @{ path = $repoPath; status = 'failed'; exitCode = $exitCode }
                }
            } catch {
                Send-Log $repoPath "异常: $($_.Exception.Message)" "stderr"
                $script:failed++
                Send-SseEvent $resp 'repo-status' @{ path = $repoPath; status = 'failed'; error = $_.Exception.Message }
            }
        } else {
            # Recursively process subdirectories
            try {
                $subdirs = $folder.GetDirectories()
                foreach ($sub in $subdirs) { 
                    if ($script:cancelFlag) { $script:cancelled = $true; break }
                    Process-Folder $sub 
                }
            } catch {
                Write-Host "Error accessing directory $($folder.FullName): $_"
            }
        }
    }

    try {
        $topDirs = Get-ChildItem -Path $rootDir -Directory -ErrorAction SilentlyContinue
        foreach ($top in $topDirs) { 
            if ($script:cancelFlag) { $script:cancelled = $true; break }
            Process-Folder $top 
        }
    } catch {
        Send-SseEvent $resp 'error' @{ message = "Error processing root directory: $($_.Exception.Message)" }
    }

    Send-SseEvent $resp 'summary' @{ root = $rootDir; success = $success; failed = $failed; skipped = $skipped }
    if ($cancelled -or $script:cancelFlag) { 
        Send-SseEvent $resp 'cancelled' @{ root = $rootDir; ts = (Get-Date).ToString('o') } 
    }
}

while ($true) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response

    try {
        if ($request.HttpMethod -eq "GET" -and ($request.Url.AbsolutePath -eq "/" -or $request.Url.AbsolutePath -eq "/index.html")) {
            $htmlPath = Join-Path $PSScriptRoot "public\index.html"
            if (-not (Test-Path $htmlPath)) {
                Send-TextResponse $response "index.html not found" 500
                continue
            }
            $html = [System.IO.File]::ReadAllText($htmlPath, [System.Text.Encoding]::UTF8)
            Send-TextResponse $response $html 200 "text/html; charset=utf-8"
            continue
        }

        # Pick folder dialog endpoint (local UI on server host)
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/pick-folder") {
            Write-Host "Folder picker requested..."
            try {
                # Create a temporary script file to run the dialog with visible window
                $tempScript = [System.IO.Path]::GetTempFileName() + ".ps1"
                $scriptContent = @'
# Use Shell.Application COM object for folder picker
$shell = New-Object -ComObject Shell.Application
$folder = $shell.BrowseForFolder(0, "选择包含 Git 仓库的根目录", 0, 0)
if ($folder) {
    $folder.Self.Path
}
'@
                [System.IO.File]::WriteAllText($tempScript, $scriptContent, [System.Text.Encoding]::UTF8)
                
                # Run the dialog with visible window (UseShellExecute = $true)
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "powershell.exe"
                $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File `"$tempScript`""
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.CreateNoWindow = $false
                
                $proc = [System.Diagnostics.Process]::Start($psi)
                $selectedPath = $proc.StandardOutput.ReadToEnd().Trim()
                $stderr = $proc.StandardError.ReadToEnd()
                $proc.WaitForExit(30000) # 30 second timeout
                
                # Clean up temp file
                try { Remove-Item $tempScript -Force -ErrorAction SilentlyContinue } catch {}
                
                if ($stderr) {
                    Write-Host "Stderr: $stderr"
                }
                
                if ($selectedPath -and $selectedPath.Length -gt 0) {
                    Write-Host "Selected: $selectedPath"
                    $json = ConvertTo-Json @{ directoryPath = $selectedPath } -Compress
                } else {
                    Write-Host "No folder selected or cancelled"
                    $json = ConvertTo-Json @{ directoryPath = "" } -Compress
                }
                
                Send-TextResponse $response $json 200 "application/json; charset=utf-8"
            } catch {
                Write-Host "Error: $($_.Exception.Message)"
                $json = ConvertTo-Json @{ directoryPath = ""; error = $_.Exception.Message } -Compress
                Send-TextResponse $response $json 200 "application/json; charset=utf-8"
            }
            continue
        }

        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -eq "/cancel") {
            $script:cancelFlag = $true
            Send-TextResponse $response "OK" 200 "text/plain; charset=utf-8"
            continue
        }

        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/fetch-stream") {
            $dir = $request.QueryString["dir"]
            if (-not $dir -or [string]::IsNullOrWhiteSpace($dir)) {
                Send-SseEvent $response 'error' @{ message = 'Query parameter "dir" is required.' }
                $response.OutputStream.Close()
                continue
            }
            if (-not (Test-Path -Path $dir)) {
                Send-SseEvent $response 'error' @{ message = 'Directory not found.'; dir = $dir }
                $response.OutputStream.Close()
                continue
            }
            $script:cancelFlag = $false
            Send-SseEvent $response 'start' @{ dir = $dir; ts = (Get-Date).ToString('o') }
            Walk-And-Pull -resp $response -rootDir $dir
            Send-SseEvent $response 'done' @{ ts = (Get-Date).ToString('o') }
            $response.OutputStream.Close()
            continue
        }

        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -eq "/fetch") {
            $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
            $body = $reader.ReadToEnd()
            $reader.Close()

            $dir = $null
            try {
                $json = ConvertFrom-Json $body
                $dir = $json.directoryPath
            } catch {
                $dir = $null
            }

            if (-not $dir -or [string]::IsNullOrWhiteSpace($dir)) {
                Send-TextResponse $response "directoryPath is required in JSON body." 400
                continue
            }

            try {
                $scriptPath = Join-Path $PSScriptRoot "fetch.ps1"
                $output = powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath -directoryPath "$dir"
                $outText = ($output | Out-String)
                Send-TextResponse $response $outText 200 "text/plain; charset=utf-8"
            } catch {
                Send-TextResponse $response $_.Exception.Message 500
            }
            continue
        }

        Send-TextResponse $response "Not Found" 404
    } catch {
        try {
            Send-TextResponse $response $_.Exception.Message 500
        } catch {}
    }
}