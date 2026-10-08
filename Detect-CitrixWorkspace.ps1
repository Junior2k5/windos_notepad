<#
    Deteccao - Citrix Workspace App 2603.20 ou superior
    Serve para Intune (Win32 app > Detection rules > Custom script)
    e para SCCM (Deployment Type > Detection Method > Script, PowerShell).

    Instalado  = escreve na saida padrao e exit 0
    Nao instalado = sem saida e exit 0
    Confirme $MinVersion com a versao do instalador:
      (Get-Item .\CitrixWorkspaceFullInstaller.exe).VersionInfo.FileVersion
#>

$MinVersion = [version]'26.3.20.0'

$uninstallPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'

foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
    $root = $base.OpenSubKey($uninstallPath)
    if (-not $root) { continue }

    foreach ($name in $root.GetSubKeyNames()) {
        $key = $root.OpenSubKey($name)
        if (-not $key) { continue }
        $displayName = [string]$key.GetValue('DisplayName')

        if ($name -eq 'CitrixOnlinePluginPackWeb' -or $displayName -match '^Citrix Workspace \d') {
            $raw = ([string]$key.GetValue('DisplayVersion')) -replace ',', '.' -replace '\s', ''
            if ($raw -match '^(\d+(\.\d+){1,3})') {
                $ver = $null
                if ([version]::TryParse($Matches[1], [ref]$ver) -and $ver -ge $MinVersion) {
                    Write-Output "Citrix Workspace $ver instalado ($view)"
                    exit 0
                }
            }
        }
    }
}

exit 0
