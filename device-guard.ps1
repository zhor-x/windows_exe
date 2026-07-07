# device-guard.ps1
$ErrorActionPreference = "Stop"

$ConfigPath = "C:\ProgramData\DeviceGuard\config.json"
$ConfigDir  = Split-Path $ConfigPath -Parent

# ==================== АВТОГЕНЕРАЦИЯ КОНФИГА ====================
if (-not (Test-Path $ConfigPath)) {
    Write-Host "Конфиг не найден. Создаём новый..." -ForegroundColor Yellow

    # Создаём папку, если её нет
    if (-not (Test-Path $ConfigDir)) {
        New-Item -Path $ConfigDir -ItemType Directory -Force | Out-Null
    }

    # Генерируем новый config
    $newConfig = @{
        DeviceId = [guid]::NewGuid().ToString()
        Token    = ""  # Нужно будет заполнить вручную или через install.ps1
    }

    $newConfig | ConvertTo-Json -Depth 3 | Out-File -FilePath $ConfigPath -Encoding UTF8

    Write-Host "Создан новый config.json: $ConfigPath" -ForegroundColor Green
    Write-Host "ВНИМАНИЕ: Заполните поле 'Token' в файле config.json!" -ForegroundColor Red
    Write-Host "После заполнения токена перезапустите скрипт." -ForegroundColor Yellow

    # Даём пользователю время прочитать сообщение
    Start-Sleep -Seconds 8
    exit 0
}
# ============================================================

$deviceConfig = Get-Content $ConfigPath | ConvertFrom-Json

# Проверка наличия токена
if ([string]::IsNullOrWhiteSpace($deviceConfig.Token)) {
    Write-Host "Ошибка: В config.json не заполнен Token!" -ForegroundColor Red
    Write-Host "Откройте файл: $ConfigPath и вставьте токен." -ForegroundColor Yellow
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
    $cancelButton.Add_Click({
        $form.Tag = "cancelled"
        $form.Close()
    })
    $form.Controls.Add($cancelButton)

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = $Minutes * 60 * 1000
    $timer.Add_Tick({
        $form.Tag = "expired"
        $timer.Stop()
        $form.Close()
    })
    $timer.Start()

    $form.Add_Shown({ $form.Activate() })
    [void]$form.ShowDialog()

    return $form.Tag
}

function Invoke-DeviceWipe {
    Write-Log "Инициирован полный сброс устройства (factory reset)."

    $systemResetPath = "$env:SystemRoot\System32\systemreset.exe"

    try {
        if (Test-Path $systemResetPath) {
            Write-Log "Запуск: $systemResetPath -factoryreset"
            Start-Process -FilePath $systemResetPath -ArgumentList "-factoryreset" -NoNewWindow
            Write-Log "Команда factory reset успешно запущена."
        }
        else {
            Write-Log "ОШИБКА: systemreset.exe не найден."
            shutdown /r /t 10 /f /c "DeviceGuard: Принудительный сброс (systemreset не найден)"
        }
    }
    catch {
        Write-Log "Критическая ошибка при запуске сброса: $_"
        shutdown /r /t 10 /f /c "DeviceGuard: Ошибка сброса - выполняется перезагрузка"
    }
}

Write-Log "DeviceGuard запущен. DeviceId=$($deviceConfig.DeviceId) PollInterval=$($Config.PollInterval)s"

while ($true) {
    try {
        $headers = @{ "Authorization" = "Bearer $($Config.DeviceToken)" }
        $response = Invoke-RestMethod -Uri $Config.ApiUrl -Headers $headers -Method Get -TimeoutSec 15

        Write-Log "Опрос API: wipe=$($response.wipe), force=$($response.force)"

        if ($response.wipe -eq $true) {
            $isForced = $response.force -eq $true

            if ($isForced) {
                Write-Log "Получена ПРИНУДИТЕЛЬНАЯ команда от MDM. Сброс БЕЗ предупреждения."
                Invoke-DeviceWipe
                break
            }
            else {
                Write-Log "Получен сигнал wipe=true. Показываю предупреждение пользователю."
                $result = Show-WipeWarning -Minutes $Config.CountdownMin

                if ($result -eq "cancelled") {
                    Write-Log "Пользователь отменил сброс."
                } else {
                    Invoke-DeviceWipe
                    break
                }
            }
        }
    }
    catch {
        Write-Log "Ошибка запроса к API: $_"
    }

    Start-Sleep -Seconds $Config.PollInterval
}