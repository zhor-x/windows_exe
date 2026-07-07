# install.ps1
$ConfigDir = "C:\ProgramData\DeviceGuard"
$ConfigPath = "$ConfigDir\config.json"

New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null

if (-not (Test-Path $ConfigPath)) {
    $token = [System.Guid]::NewGuid().ToString()
    $config = @{
        Token    = $token
        DeviceId = $env:COMPUTERNAME
    }
    $config | ConvertTo-Json | Set-Content -Path $ConfigPath

    Write-Host "Устройство зарегистрировано."
    Write-Host "Token: $token"
    Write-Host "Отправь этот токен на сервер вручную (или через enrollment API), чтобы связать его с устройством в базе."
} else {
    Write-Host "Конфиг уже существует, токен не пересоздан."
}
