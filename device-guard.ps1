# device-guard.ps1
$ErrorActionPreference = "Stop"

$ConfigPath = "C:\ProgramData\DeviceGuard\config.json"

if (-not (Test-Path $ConfigPath)) {
    Write-Host "Конфиг не найден. Сначала запусти install.ps1"
    exit 1
}

$deviceConfig = Get-Content $ConfigPath | ConvertFrom-Json

$Config = @{
    ApiUrl        = "https://backdrive.store/api/s"
    DeviceToken   = $deviceConfig.Token
    PollInterval  = 10          # чаще опрос в тесте
    LogPath       = "C:\ProgramData\DeviceGuard\log.txt"
    CountdownMin  = 1
    TestMode      = $true       # <-- явный флаг, видно в коде и в логах
    TestCountdownSec = 5        # автоподтверждение через 5 сек вместо 30 минут
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $prefix = if ($Config.TestMode) { "[TEST]" } else { "" }
    $line = "[$timestamp] $prefix $Message"
    Add-Content -Path $Config.LogPath -Value $line
    Write-Host $line
}

function Show-WipeWarning {
    param([int]$Minutes)

    if ($Config.TestMode) {
        Write-Log "TEST MODE: окно пропущено, автоподтверждение через $($Config.TestCountdownSec) сек."
        Start-Sleep -Seconds $Config.TestCountdownSec
        return "expired"
    }

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
    Write-Log "Инициирован сброс устройства (после подтверждённого таймаута)."
    if ($Config.TestMode) {
        Write-Log "TEST MODE: реальный wipe НЕ вызывается, это заглушка."
        return
    }
    # systemreset.exe -factoryreset
    # Reset-Computer -RemoveData -ResetType Full
    Write-Log "ЗАГЛУШКА: здесь вызывается реальная команда сброса."
}

Write-Log "DeviceGuard запущен. DeviceId=$($deviceConfig.DeviceId) PollInterval=$($Config.PollInterval)s TestMode=$($Config.TestMode)"

while ($true) {
    try {
        $headers = @{ "Authorization" = "Bearer $($Config.DeviceToken)" }
        $response = Invoke-RestMethod -Uri $Config.ApiUrl -Headers $headers -Method Get -TimeoutSec 15

        Write-Log "Опрос API: wipe=$($response.wipe)"

        if ($response.wipe -eq $true) {
            Write-Log "Получен сигнал wipe=true."
            $result = Show-WipeWarning -Minutes $Config.CountdownMin

            if ($result -eq "cancelled") {
                Write-Log "Пользователь отменил сброс."
            } else {
                Invoke-DeviceWipe
                break
            }
        }
    }
    catch {
        Write-Log "Ошибка запроса к API: $_"
    }

    Start-Sleep -Seconds $Config.PollInterval
}