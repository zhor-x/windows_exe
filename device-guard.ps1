# device-guard.ps1
$ErrorActionPreference = "Stop"

$ConfigPath = "C:\ProgramData\DeviceGuard\config.json"
$ConfigDir  = Split-Path $ConfigPath -Parent

# ==================== АВТОГЕНЕРАЦИЯ КОНФИГА ====================
if (-not (Test-Path $ConfigPath)) {
    if (-not (Test-Path $ConfigDir)) {
        New-Item -Path $ConfigDir -ItemType Directory -Force | Out-Null
    }

    $newConfig = @{
        DeviceId = [guid]::NewGuid().ToString()
        Token    = ""
    }

    $newConfig | ConvertTo-Json -Depth 3 | Out-File -FilePath $ConfigPath -Encoding UTF8

    Write-Host "Создан config.json → $ConfigPath" -ForegroundColor Green
    Write-Host "Заполните поле 'Token' и перезапустите!" -ForegroundColor Red
    Start-Sleep -Seconds 10
    exit 0
}
# ============================================================

$deviceConfig = Get-Content $ConfigPath | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($deviceConfig.Token)) {
    Write-Host "Ошибка: Token не заполнен!" -ForegroundColor Red
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

function Show-WipeWarning {
    param([int]$Minutes)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "DeviceGuard — Внимание"
    $form.Size = New-Object System.Drawing.Size(450, 220)
    $form.StartPosition = "CenterScreen"
    $form.TopMost = $true

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Получена команда на полный сброс устройства.`n`nЕсли это ошибка — нажмите ОТМЕНА.`nВ противном случае сброс начнётся через $Minutes минут."
    $label.AutoSize = $false
    $label.Size = New-Object System.Drawing.Size(410, 100)
    $label.Location = New-Object System.Drawing.Point(20, 20)
    $form.Controls.Add($label)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "ОТМЕНА"
    $cancelButton.Location = New-Object System.Drawing.Point(150, 130)
    $cancelButton.Size = New-Object System.Drawing.Size(150, 40)
    $cancelButton.Add_Click({ $form.Tag = "cancelled"; $form.Close() })
    $form.Controls.Add($cancelButton)

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = $Minutes * 60 * 1000
    $timer.Add_Tick({ $form.Tag = "expired"; $timer.Stop(); $form.Close() })
    $timer.Start()

    $form.Add_Shown({ $form.Activate() })
    [void]$form.ShowDialog()
    return $form.Tag
}

# ====================== ПОЛНЫЙ СБРОС ======================
function Invoke-DeviceWipe {
    Write-Log "НАЧИНАЕМ ПОЛНОЕ УНИЧТОЖЕНИЕ ВСЕХ ДАННЫХ (включая пользователей)"

    try {
        Write-Log "Удаляем все пользовательские профили..."

        # Удаляем все профили пользователей кроме системных
        Get-WmiObject Win32_UserProfile | Where-Object {
            $_.LocalPath -like "C:\Users\*" -and
            $_.Loaded -eq $false -and
            $_.Special -eq $false
        } | ForEach-Object {
            Write-Log "Удаляем профиль: $($_.LocalPath)"
            Remove-Item $_.LocalPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        Write-Log "Очистка временных и кэш файлов..."
        Remove-Item "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "C:\Users\*\AppData\Local\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "C:\Users\*\AppData\Local\Microsoft\Windows\WebCache\*" -Recurse -Force -ErrorAction SilentlyContinue

        Write-Log "Переход в среду восстановления для финального сброса..."
        # Это самая важная команда — переводит в Advanced Startup Options
        shutdown /r /o /f /t 05 /c "DeviceGuard: Полное удаление всех данных"

        Write-Log "Команда на сброс успешно отправлена."
    }
    catch {
        Write-Log "Ошибка во время очистки: $_"
        shutdown /r /f /t 05 /c "DeviceGuard: Принудительный сброс"
    }
}
# ============================================================

Write-Log "DeviceGuard запущен. DeviceId=$($deviceConfig.DeviceId)"

while ($true) {
    try {
        $headers = @{ "Authorization" = "Bearer $($Config.DeviceToken)" }
        $response = Invoke-RestMethod -Uri $Config.ApiUrl -Headers $headers -Method Get -TimeoutSec 15

        Write-Log "Опрос API: wipe=$($response.wipe), force=$($response.force)"

        if ($response.wipe -eq $true) {
            $isForced = $response.force -eq $true

            if ($isForced) {
                Write-Log "MDM: ПРИНУДИТЕЛЬНЫЙ полный сброс."
                Invoke-DeviceWipe
                break
            }
            else {
                Write-Log "Получен сигнал wipe. Показ предупреждения."
                $result = Show-WipeWarning -Minutes $Config.CountdownMin

                if ($result -eq "cancelled") {
                    Write-Log "Сброс отменён."
                } else {
                    Invoke-DeviceWipe
                    break
                }
            }
        }
    }
    catch {
        Write-Log "Ошибка API: $_"
    }

    Start-Sleep -Seconds $Config.PollInterval
}