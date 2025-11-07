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