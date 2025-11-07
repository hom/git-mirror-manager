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

    function Process-Folder([System.IO.DirectoryInfo]$folder) {
        $gitPath = Join-Path -Path $folder.FullName -ChildPath ".git"
        if ($script:cancelFlag) { $cancelled = $true; return }
        if (Test-Path -Path $gitPath) {
            Send-SseEvent $resp 'repo-start' @{ path = $folder.FullName }
            # Detect branch
            $branch = (& git -C $folder.FullName branch --show-current).Trim()
            if (-not $branch -or [string]::IsNullOrWhiteSpace($branch)) {
                $branch = (& git -C $folder.FullName rev-parse --abbrev-ref HEAD).Trim()
            }
            if ($branch -eq 'HEAD' -or [string]::IsNullOrWhiteSpace($branch)) {
                $skipped++
                Send-SseEvent $resp 'repo-status' @{ path = $folder.FullName; status = 'skipped'; reason = 'detached HEAD or no branch' }
                return
            }

            # Run git pull with streaming logs
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'git'
            $pathQuoted = '"' + $folder.FullName + '"'
            $branchQuoted = '"' + $branch + '"'
            $psi.Arguments = "-C $pathQuoted pull origin $branchQuoted --rebase"
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi
            [void]$proc.Start()

            # Asynchronously read output to avoid blocking and stream in real-time
            $repoPath = $folder.FullName
            $subOut = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -MessageData @{ resp = $response; path = $repoPath } -Action {
                param($sender, $eventArgs)
                $resp = $event.MessageData.resp
                $path = $event.MessageData.path
                $line = $eventArgs.Data
                if ($line) { Send-SseEvent $resp 'repo-log' @{ path = $path; stream = 'stdout'; line = $line } }
            }
            $subErr = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -MessageData @{ resp = $response; path = $repoPath } -Action {
                param($sender, $eventArgs)
                $resp = $event.MessageData.resp
                $path = $event.MessageData.path
                $line = $eventArgs.Data
                if ($line) { Send-SseEvent $resp 'repo-log' @{ path = $path; stream = 'stderr'; line = $line } }
            }

            $proc.BeginOutputReadLine()
            $proc.BeginErrorReadLine()
            while (-not $proc.HasExited) {
                if ($script:cancelFlag) { $cancelled = $true; try { $proc.Kill() } catch {} break }
                Start-Sleep -Milliseconds 100
            }

            if ($subOut) { Unregister-Event -SubscriptionId $subOut.Id }
            if ($subErr) { Unregister-Event -SubscriptionId $subErr.Id }

            if ($cancelled) { $skipped++; Send-SseEvent $resp 'repo-status' @{ path = $folder.FullName; status = 'cancelled' } }
            else {
                $exit = $proc.ExitCode
                if ($exit -eq 0) { $success++; Send-SseEvent $resp 'repo-status' @{ path = $folder.FullName; status = 'success' } }
                else { $failed++; Send-SseEvent $resp 'repo-status' @{ path = $folder.FullName; status = 'failed'; exitCode = $exit } }
            }
            $proc.Close()
        } else {
            foreach ($sub in $folder.GetDirectories()) { if ($script:cancelFlag) { $cancelled = $true; break }; Process-Folder $sub }
        }
    }

    foreach ($top in (Get-ChildItem -Path $rootDir -Directory)) { if ($script:cancelFlag) { $cancelled = $true; break }; Process-Folder $top }
    Send-SseEvent $resp 'summary' @{ root = $rootDir; success = $success; failed = $failed; skipped = $skipped }
    if ($cancelled -or $script:cancelFlag) { Send-SseEvent $resp 'cancelled' @{ root = $rootDir; ts = (Get-Date).ToString('o') } }
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
            try {
                Add-Type -AssemblyName System.Windows.Forms
                $selectedPath = $null
                $state = New-Object PSObject -Property @{ SelectedPath = $null }
                $thread = New-Object System.Threading.Thread([System.Threading.ParameterizedThreadStart]{
                    param($st)
                    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                    $dlg.Description = "选择根目录"
                    $dlg.ShowNewFolderButton = $false
                    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                        $st.SelectedPath = $dlg.SelectedPath
                    }
                })
                $thread.SetApartmentState([System.Threading.ApartmentState]::STA)
                $thread.Start($state)
                $thread.Join()
                $selectedPath = $state.SelectedPath
                $payload = @{ directoryPath = $selectedPath }
                $json = ConvertTo-Json $payload -Compress
                Send-TextResponse $response $json 200 "application/json; charset=utf-8"
            } catch {
                Send-TextResponse $response (ConvertTo-Json @{ error = $_.Exception.Message } -Compress) 500 "application/json; charset=utf-8"
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