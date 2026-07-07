# device-guard.ps1
$ErrorActionPreference = "Stop"

$ConfigPath = "C:\ProgramData\DeviceGuard\config.json"

if (-not (Test-Path $ConfigPath)) {
    Write-Host "Конфиг не найден. Сначала запусти install.ps1"
    exit 1
}

$deviceConfig = Get-Content $ConfigPath | ConvertFrom-Json

$Config = @{
    ApiUrl        = "backdrive.store/api/s"
    DeviceToken   = $deviceConfig.Token
    PollInterval  = 60
    LogPath       = "C:\ProgramData\DeviceGuard\log.txt"
    CountdownMin  = 1
}

function Ensure-LogFolder {
    $logFolder = Split-Path $Config.LogPath -Parent

    if (-not (Test-Path $logFolder)) {
        New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
    }
}

function Write-Log {
    param([string]$Message)

    Ensure-LogFolder

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"

    Add-Content -Path $Config.LogPath -Value $line
    Write-Host $line
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Load-GuiAssemblies {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
}

function Show-Message {
    param(
        [string]$Text,
        [string]$Title = "DeviceGuard"
    )

    Load-GuiAssemblies

    [System.Windows.Forms.MessageBox]::Show(
        $Text,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

function Get-SystemResetPath {
    $paths = @(
        "$env:WINDIR\System32\systemreset.exe",
        "$env:WINDIR\Sysnative\systemreset.exe"
    )

    foreach ($path in $paths) {
        if (Test-Path $path) {
            return $path
        }
    }

    return $null
}

function Test-WindowsRecoveryEnabled {
    try {
        $info = reagentc /info 2>&1
        $infoText = $info -join "`n"

        if ($infoText -match "Windows RE status:\s+Enabled") {
            return $true
        }

        return $false
    }
    catch {
        Write-Log "Не удалось проверить Windows RE: $_"
        return $false
    }
}

function Show-WipeWarning {
    param([int]$Minutes)

    Load-GuiAssemblies

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "DeviceGuard — Внимание"
    $form.Size = New-Object System.Drawing.Size(450, 220)
    $form.StartPosition = "CenterScreen"
    $form.TopMost = $true
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

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

    $form.Add_Shown({
        $form.Activate()
    })

    [void]$form.ShowDialog()

    if ([string]::IsNullOrWhiteSpace($form.Tag)) {
        return "closed"
    }

    return $form.Tag
}

function Invoke-DeviceWipe {
    Write-Log "Инициирован полный сброс устройства."

    try {
        if (-not (Test-IsAdmin)) {
            throw "Скрипт не запущен от имени администратора. Factory reset требует admin permissions."
        }

        $systemResetPath = Get-SystemResetPath

        if ([string]::IsNullOrWhiteSpace($systemResetPath)) {
            throw "systemreset.exe не найден. Проверено: C:\Windows\System32\systemreset.exe и C:\Windows\Sysnative\systemreset.exe"
        }

        $winReEnabled = Test-WindowsRecoveryEnabled

        if (-not $winReEnabled) {
            Write-Log "Windows RE отключён. Пытаюсь включить reagentc /enable"

            try {
                reagentc /enable | Out-Null
                Start-Sleep -Seconds 2
            }
            catch {
                Write-Log "Не удалось включить Windows RE: $_"
            }
        }

        Write-Log "Запускаю сброс: $systemResetPath -factoryreset"

        Start-Process -FilePath $systemResetPath -ArgumentList "-factoryreset"

        Write-Log "Команда systemreset.exe -factoryreset успешно запущена."
    }
    catch {
        Write-Log "ОШИБКА при запуске сброса: $_"

        Show-Message -Text "Не удалось запустить factory reset.`n`nОшибка:`n$_`n`nПроверь, что скрипт запущен от администратора и Windows RE включён."
    }
}

Write-Log "DeviceGuard запущен. DeviceId=$($deviceConfig.DeviceId) PollInterval=$($Config.PollInterval)s"

while ($true) {
    try {
        $headers = @{
            "Authorization" = "Bearer $($Config.DeviceToken)"
        }

        $response = Invoke-RestMethod `
            -Uri $Config.ApiUrl `
            -Headers $headers `
            -Method Get `
            -TimeoutSec 15

        Write-Log "Опрос API: wipe=$($response.wipe), force=$($response.force)"

        if ($response.wipe -eq $true) {
            $isForced = $response.force -eq $true

            if ($isForced) {
                Write-Log "Получена ПРИНУДИТЕЛЬНАЯ команда от MDM. Выполняем сброс БЕЗ предупреждения."
                Invoke-DeviceWipe
                break
            }
            else {
                Write-Log "Получен сигнал wipe=true. Показываю предупреждение."

                $result = Show-WipeWarning -Minutes $Config.CountdownMin

                if ($result -eq "cancelled") {
                    Write-Log "Пользователь отменил сброс."
                }
                else {
                    Write-Log "Предупреждение истекло или было закрыто. Выполняем сброс."
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