function Invoke-DeviceWipe {
    Write-Log "ЗАПУСК ПОЛНОГО СБРОСА УСТРОЙСТВА (агрессивный режим)"

    try {
        Write-Log "Попытка 1: systemreset.exe (полный путь)"
        $systemResetPath = "$env:SystemRoot\System32\systemreset.exe"
        
        if (Test-Path $systemResetPath) {
            Start-Process -FilePath $systemResetPath -ArgumentList "-factoryreset" -NoNewWindow
            Write-Log "systemreset.exe запущен"
            return
        }
    }
    catch { }

    try {
        Write-Log "Попытка 2: Запуск через recovery (самый надёжный способ)"
        # Этот метод переводит компьютер в среду восстановления и запускает сброс
        shutdown /r /o /f /t 00
        Write-Log "Команда перехода в среду восстановления отправлена"
        return
    }
    catch { }

    # Последний запасной вариант — принудительная перезагрузка
    Write-Log "Все основные методы не сработали. Выполняем принудительную перезагрузку."
    shutdown /r /f /t 5 /c "DeviceGuard: Принудительный сброс устройства"
}