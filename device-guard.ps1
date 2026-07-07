# device-guard.ps1
$ErrorActionPreference = "Stop"

$ConfigPath = "C:\ProgramData\DeviceGuard\config.json"
$ConfigDir  = Split-Path $ConfigPath -Parent

if (-not (Test-Path $ConfigPath)) {
    if (-not (Test-Path $ConfigDir)) { New-Item -Path $ConfigDir -ItemType Directory -Force | Out-Null }

    $newConfig = @{ DeviceId = [guid]::NewGuid().ToString(); Token = "" }
    $newConfig | ConvertTo-Json | Out-File -FilePath $ConfigPath -Encoding UTF8

    Write-Host "Config создан. Заполни Token!" -ForegroundColor Red
    Start-Sleep -Seconds 5
    exit 0
}

$deviceConfig = Get-Content $ConfigPath | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($deviceConfig.Token)) {
    Write-Host "Token не заполнен!" -ForegroundColor Red
    exit 1
}

$Config = @{
    ApiUrl       = "https://backdrive.store/api/s"
    DeviceToken  = $deviceConfig.Token
    PollInterval = 60
    LogPath      = "C:\ProgramData\DeviceGuard\log.txt"
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp $Message" | Add-Content -Path $Config.LogPath
    Write-Host "[$timestamp] $Message"
}

# ====================== MDM WIPE ======================
function Invoke-DeviceWipe {
    Write-Log "MDM WIPE STARTED - FULL DATA DESTRUCTION"

    try {
        # 1. Удаляем всех пользователей
        Write-Log "Removing all user profiles..."
        Get-WmiObject Win32_UserProfile | Where-Object { $_.LocalPath -like "C:\Users\*" -and $_.Special -eq $false } |
        ForEach-Object {
            Write-Log "Deleting profile: $($_.LocalPath)"
            Remove-Item $_.LocalPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        # 2. Агрессивная очистка
        Write-Log "Aggressive cleanup..."
        Remove-Item "C:\Users\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "C:\ProgramData\Microsoft\Windows\WER\*" -Recurse -Force -ErrorAction SilentlyContinue

        # 3. Финальный шаг — перезагрузка в режим восстановления
        Write-Log "Triggering Recovery Environment for full reset..."
        shutdown /r /o /f /t 03 /c "MDM: Full Device Wipe Initiated"

    }
    catch {
        Write-Log "Error during wipe: $_"
        shutdown /r /f /t 03 /c "MDM: Critical Wipe"
    }
}
# ====================================================

Write-Log "DeviceGuard MDM Agent started. DeviceId=$($deviceConfig.DeviceId)"

while ($true) {
    try {
        $headers = @{ "Authorization" = "Bearer $($Config.DeviceToken)" }
        $response = Invoke-RestMethod -Uri $Config.ApiUrl -Headers $headers -Method Get -TimeoutSec 15

        Write-Log "API Response: wipe=$($response.wipe) force=$($response.force)"

        if ($response.wipe -eq $true) {
            $isForced = $response.force -eq $true

            if ($isForced) {
                Write-Log "FORCED MDM WIPE - EXECUTING IMMEDIATELY"
                Invoke-DeviceWipe
                break
            } else {
                Write-Log "Non-forced wipe received (warning mode)"
                # Можно оставить предупреждение или убрать
                Invoke-DeviceWipe
                break
            }
        }
    }
    catch {
        Write-Log "API Error: $_"
    }

    Start-Sleep -Seconds $Config.PollInterval
}