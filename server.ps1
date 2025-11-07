$ErrorActionPreference = "Stop"

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
    $success = 0; $failed = 0; $skipped = 0

    function Process-Folder([System.IO.DirectoryInfo]$folder) {
        $gitPath = Join-Path -Path $folder.FullName -ChildPath ".git"
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

            $outReader = $proc.StandardOutput
            $errReader = $proc.StandardError

            while (-not $proc.HasExited) {
                while (-not $outReader.EndOfStream) {
                    $line = $outReader.ReadLine()
                    if ($line) { Send-SseEvent $resp 'repo-log' @{ path = $folder.FullName; stream = 'stdout'; line = $line } }
                }
                while (-not $errReader.EndOfStream) {
                    $line = $errReader.ReadLine()
                    if ($line) { Send-SseEvent $resp 'repo-log' @{ path = $folder.FullName; stream = 'stderr'; line = $line } }
                }
                Start-Sleep -Milliseconds 50
            }
            # Drain remaining
            while (-not $outReader.EndOfStream) { $line = $outReader.ReadLine(); if ($line) { Send-SseEvent $resp 'repo-log' @{ path = $folder.FullName; stream = 'stdout'; line = $line } } }
            while (-not $errReader.EndOfStream) { $line = $errReader.ReadLine(); if ($line) { Send-SseEvent $resp 'repo-log' @{ path = $folder.FullName; stream = 'stderr'; line = $line } } }

            $exit = $proc.ExitCode
            if ($exit -eq 0) { $success++; Send-SseEvent $resp 'repo-status' @{ path = $folder.FullName; status = 'success' } }
            else { $failed++; Send-SseEvent $resp 'repo-status' @{ path = $folder.FullName; status = 'failed'; exitCode = $exit } }
            $proc.Close()
        } else {
            foreach ($sub in $folder.GetDirectories()) { Process-Folder $sub }
        }
    }

    foreach ($top in (Get-ChildItem -Path $rootDir -Directory)) { Process-Folder $top }
    Send-SseEvent $resp 'summary' @{ root = $rootDir; success = $success; failed = $failed; skipped = $skipped }
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