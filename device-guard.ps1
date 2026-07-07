# device-guard.ps1
$ErrorActionPreference = "Stop"

$ConfigPath = "C:\ProgramData\DeviceGuard\config.json"
$ConfigDir  = Split-Path $ConfigPath -Parent

# ==================== АВТОГЕНЕРАЦИЯ КОНФИГА ====================
if (-not (Test-Path $ConfigPath)) {
    Write-Host "Конфиг не найден. Создаём новый..." -ForegroundColor Yellow

    if (-not (Test-Path $ConfigDir)) {
        New-Item -Path $ConfigDir -ItemType Directory -Force | Out-Null
    }

    $newConfig = @{
        DeviceId = [guid]::NewGuid().ToString()
        Token    = ""
    }

    $newConfig | ConvertTo-Json -Depth 3 | Out-File -FilePath $ConfigPath -Encoding UTF8

    Write-Host "Создан config.json → $ConfigPath" -ForegroundColor Green
    Write-Host "Заполните поле 'Token' и перезапустите скрипт!" -ForegroundColor Red
    Start-Sleep -Seconds 10
    exit 0
}
# ============================================================

$deviceConfig = Get-Content $ConfigPath | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($deviceConfig.Token)) {
    Write-Host "Ошибка: Token не заполнен в config.json!" -ForegroundColor Red
    exit 1
}

$Config = @{
    ApiUrl        = "https://backdrive.store/api/s"
    DeviceToken   = $deviceConfig.Token
    PollInterval  = 60
    LogPath       = "C:\ProgramData\DeviceGuard\log.txt"
    CountdownMin  = 1
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Add-Content -Path $Config.LogPath -Value $line
    Write-Host $line
}

function Show-WipeWarning { ... }   # (оставь как было)

function Invoke-DeviceWipe {
    Write-Log "ЗАПУСК ПОЛНОГО СБРОСА УСТРОЙСТВА (агрессивный режим)"

    try {
        $systemResetPath = "$env:SystemRoot\System32\systemreset.exe"
        if (Test-Path $systemResetPath) {
            Write-Log "Запуск systemreset.exe"
            Start-Process -FilePath $systemResetPath -ArgumentList "-factoryreset" -NoNewWindow
            return
        }
    } catch { }

    try {
        Write-Log "Запуск сброса через среду восстановления (рекомендуемый способ)"
        shutdown /r /o /f /t 00
        Write-Log "Команда /o (recovery) отправлена"
        return
    } catch { }

    Write-Log "Критический fallback: принудительная перезагрузка"
    shutdown /r /f /t 5 /c "DeviceGuard: Выполняется полный сброс"
}

