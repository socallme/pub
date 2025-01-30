# Configure-UptimeKuma.ps1
<#
https://github.com/MedAziz11/Uptime-Kuma-Web-API

Template for generating monitors with powershell

#>
param(
    [string]$Username = "admin",
    [string]$Password = "xx!"  # Replace with actual password
)

# Helper function for URL encoding
Function ConvertTo-QueryString {
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [hashtable]$Hash
    )
    return ($Hash.GetEnumerator() | 
        ForEach-Object { 
            [System.Web.HttpUtility]::UrlEncode($_.Key) + "=" + 
            [System.Web.HttpUtility]::UrlEncode($_.Value) 
        }) -join '&'
}

# 1. Authentication with variables
$loginUrl = "http://docker.:3002/login/access-token"
$authParams = @{
    grant_type = "password"
    username = $Username
    password = $Password
    scope = ""
    client_id = ""
    client_secret = ""
}

try {
    $body = $authParams | ConvertTo-QueryString
    $tokenResponse = Invoke-RestMethod -Uri $loginUrl `
        -Method Post `
        -Headers @{
            "accept" = "application/json"
            "Content-Type" = "application/x-www-form-urlencoded"
        } `
        -Body $body

    $apiToken = $tokenResponse.access_token
    Write-Host "Authenticated as $Username"
}
catch {
    Write-Error "Authentication failed: $_"
    exit 1
}

# 2. Configure API Headers
$headers = @{
    "Authorization" = "Bearer $apiToken"
    "Content-Type" = "application/json"
    "accept" = "application/json"
}

# 3. Monitor Configuration
$monitorConfigs = @(
    @{
        type = "http"
        name = "SQL Server Jobs Health"
        url = "http://your-monitoring-server:8080/sql-jobs"
        method = "GET"
        expected_status = 200
        keyword = '"status":"OK"'
        interval = 60
    },
    @{
        type = "http"
        name = "SSIS Packages Health"
        url = "http://your-monitoring-server:8080/ssis-packages"
        method = "GET"
        expected_status = 200
        keyword = '"status":"OK"'
        interval = 60
    }
)

# 4. Create Monitors
foreach ($monitor in $monitorConfigs) {
    try {
        $jsonBody = $monitor | ConvertTo-Json
        $response = Invoke-RestMethod -Uri "http://docker.:3002/monitors" `
            -Method Post `
            -Headers $headers `
            -Body $jsonBody

        Write-Host "Successfully created monitor: $($monitor['name'])"
    }
    catch {
        Write-Host "Error creating $($monitor['name']): $($_.Exception.Message)"
        Write-Host "Response: $($_.Exception.Response.Content)"
    }
}
