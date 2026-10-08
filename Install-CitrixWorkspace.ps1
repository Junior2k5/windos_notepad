<#
.SYNOPSIS
    Instala/atualiza o Citrix Workspace App mantendo a arquitetura atual (x86 ou x64).

.DESCRIPTION
    - Detecta a instalacao atual pelo registro (visoes 64 e 32 bits, independente
      de o script rodar em processo 32 ou 64 bits).
    - Escolhe o instalador da mesma arquitetura:
        x64 -> CitrixWorkspaceFullInstaller_x64.exe
        x86 -> CitrixWorkspaceFullInstaller.exe
    - Sem instalacao atual: usa $DefaultArch.
    - Nao instala se a versao atual ja for >= versao do instalador.
    - Se houver sessao ICA ativa, sai com 1618 (Intune/SCCM tentam de novo depois).
    - Arquitetura atual, nesta ordem: InstallLocation do registro -> pasta
      "Citrix Workspace*" em Program Files / Program Files (x86) -> binario
      wfica(32).exe -> visao do registro.
    - Remove em silencio o Citrix HDX RealTime Media Engine (RTME), se existir,
      porque o instalador do Workspace pede confirmacao para remove-lo.
    - Switches: /silent /includeSSON /IncludeAppProtection AutoUpdateCheck=disabled
      (padrao da equipe + auto-update desativado; upgrade in-place)
      NAO usa /CleanInstall: com App Protection ele pede ao usuario para reiniciar
      ou cancelar, mesmo em modo silencioso.

    Codigos de saida:
        0     sucesso / nada a fazer
        3010  sucesso, reinicializacao pendente
        1618  sessao Citrix ativa, tentar mais tarde
        1     erro do script (instalador ausente etc.)
        outro codigo retornado pelo instalador da Citrix

    Log: C:\Windows\Logs\CitrixWorkspace-Install.log
    Log do instalador Citrix: %TEMP% do SYSTEM (C:\Windows\Temp\CTXReceiverInstallLogs*)
#>

[CmdletBinding()]
param(
    # Arquitetura usada quando o Citrix Workspace nao esta instalado
    [ValidateSet('x86', 'x64')]
    [string]$DefaultArch = 'x86',

    # Parametros adicionais alem do padrao (ex.:
    # 'STORE0="Store;https://storefront.empresa/Citrix/Store/discovery;on;Store"')
    [string[]]$ExtraArgs = @()
)

$ErrorActionPreference = 'Stop'

$LogFile     = Join-Path $env:windir 'Logs\CitrixWorkspace-Install.log'
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallerX86 = Join-Path $ScriptDir 'CitrixWorkspaceFullInstaller.exe'
$InstallerX64 = Join-Path $ScriptDir 'CitrixWorkspaceFullInstaller_x64.exe'

function Write-Log {
    param([string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    Write-Host $line   # Write-Host para nao poluir o retorno das funcoes
}

function ConvertTo-Version {
    param([string]$Text)
    if (-not $Text) { return $null }
    $clean = ($Text -replace ',', '.' -replace '\s', '')
    if ($clean -match '^(\d+(\.\d+){1,3})') {
        try { return [version]$Matches[1] } catch { return $null }
    }
    return $null
}

function Get-CitrixWorkspaceInstall {
    # Le o registro nas duas visoes explicitamente (o IME do Intune roda em 32 bits)
    $uninstallPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    $results = @()

    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
        $root = $base.OpenSubKey($uninstallPath)
        if (-not $root) { continue }

        foreach ($name in $root.GetSubKeyNames()) {
            $key = $root.OpenSubKey($name)
            if (-not $key) { continue }
            $displayName = [string]$key.GetValue('DisplayName')

            # Pacote principal: chave CitrixOnlinePluginPackWeb ou nome "Citrix Workspace <versao>"
            if ($name -eq 'CitrixOnlinePluginPackWeb' -or $displayName -match '^Citrix Workspace \d') {
                $results += [pscustomobject]@{
                    View            = $view
                    KeyName         = $name
                    DisplayName     = $displayName
                    DisplayVersion  = [string]$key.GetValue('DisplayVersion')
                    InstallLocation = [string]$key.GetValue('InstallLocation')
                }
            }
            $key.Close()
        }
        $root.Close()
        $base.Close()
    }
    return $results
}

function Get-PEArch {
    # Le o cabecalho PE do executavel: 0x8664 = x64, 0x014C = x86, 0xAA64 = ARM64
    param([string]$Path)
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $br = New-Object System.IO.BinaryReader($fs)
            $fs.Seek(0x3C, 'Begin') | Out-Null
            $peOffset = $br.ReadInt32()
            $fs.Seek($peOffset + 4, 'Begin') | Out-Null
            $machine = $br.ReadUInt16()
        }
        finally { $fs.Close() }
        switch ($machine) {
            0x8664  { return 'x64' }
            0x014C  { return 'x86' }
            default { return $null }
        }
    }
    catch { return $null }
}

function Get-InstallArch {
    param($Install)

    # Layout confirmado:
    #   x86 -> C:\Program Files (x86)\Citrix\Citrix Workspace <versao>
    #   x64 -> C:\Program Files\Citrix\Citrix Workspace <versao>
    $pf64 = $env:ProgramW6432          # C:\Program Files mesmo em processo 32 bits
    $pf86 = ${env:ProgramFiles(x86)}   # C:\Program Files (x86)

    # 1) InstallLocation do registro
    if ($Install.InstallLocation) {
        if ($Install.InstallLocation -like "$pf86\*") { Write-Log "Arquitetura pelo InstallLocation: x86"; return 'x86' }
        if ($Install.InstallLocation -like "$pf64\*") { Write-Log "Arquitetura pelo InstallLocation: x64"; return 'x64' }
    }

    # 2) Pastas "Citrix Workspace*" no disco (prefere a pasta da versao instalada)
    $dir64 = @(Get-ChildItem -Path "$pf64\Citrix" -Directory -Filter 'Citrix Workspace*' -ErrorAction SilentlyContinue)
    $dir86 = @(Get-ChildItem -Path "$pf86\Citrix" -Directory -Filter 'Citrix Workspace*' -ErrorAction SilentlyContinue)
    $ver = $Install.DisplayVersion
    if ($ver) {
        if ($dir64 | Where-Object Name -like "*$ver*") { Write-Log "Arquitetura pela pasta da versao ${ver}: x64"; return 'x64' }
        if ($dir86 | Where-Object Name -like "*$ver*") { Write-Log "Arquitetura pela pasta da versao ${ver}: x86"; return 'x86' }
    }
    if ($dir64.Count -gt 0 -and $dir86.Count -eq 0) { Write-Log 'Arquitetura pelas pastas: x64'; return 'x64' }
    if ($dir86.Count -gt 0 -and $dir64.Count -eq 0) { Write-Log 'Arquitetura pelas pastas: x86'; return 'x86' }

    # 3) Binario do motor HDX (wfica.exe / wfica32.exe)
    $searchRoots = @($Install.InstallLocation) + $dir64.FullName + $dir86.FullName | Where-Object { $_ -and (Test-Path $_) }
    foreach ($r in $searchRoots) {
        $engine = Get-ChildItem -Path $r -Include 'wfica.exe', 'wfica32.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($engine) {
            $peArch = Get-PEArch $engine.FullName
            if ($peArch) { Write-Log "Arquitetura pelo binario $($engine.FullName): $peArch"; return $peArch }
        }
    }

    # 4) Visao do registro onde a entrada foi encontrada
    if ($Install.View -eq [Microsoft.Win32.RegistryView]::Registry64) { Write-Log 'Arquitetura pela visao do registro: x64'; return 'x64' }
    Write-Log 'Arquitetura pela visao do registro: x86'
    return 'x86'
}

# ---------------------------------------------------------------------------

try {
    New-Item -ItemType Directory -Path (Split-Path $LogFile) -Force -ErrorAction SilentlyContinue | Out-Null
    Write-Log '===== Inicio da instalacao do Citrix Workspace ====='
    Write-Log ("Processo 64 bits: {0} | SO 64 bits: {1}" -f [Environment]::Is64BitProcess, [Environment]::Is64BitOperatingSystem)

    # --- Instalacao atual ---------------------------------------------------
    $installs = @(Get-CitrixWorkspaceInstall)
    $current  = $null
    if ($installs.Count -gt 0) {
        foreach ($i in $installs) {
            Write-Log ("Encontrado: {0} | {1} | {2} | {3}" -f $i.KeyName, $i.DisplayName, $i.DisplayVersion, $i.InstallLocation)
        }
        # Se houver mais de uma, usa a de maior versao
        $current = $installs | Sort-Object { ConvertTo-Version $_.DisplayVersion } -Descending | Select-Object -First 1
        $arch = Get-InstallArch $current
        Write-Log "Arquitetura atual: $arch | Versao atual: $($current.DisplayVersion)"
    }
    else {
        $arch = $DefaultArch
        Write-Log "Citrix Workspace nao instalado. Usando arquitetura padrao: $arch"
    }

    if ($arch -eq 'x64' -and -not [Environment]::Is64BitOperatingSystem) {
        Write-Log 'SO 32 bits: forcando x86.'
        $arch = 'x86'
    }

    $installer = if ($arch -eq 'x64') { $InstallerX64 } else { $InstallerX86 }
    if (-not (Test-Path $installer)) {
        Write-Log "ERRO: instalador nao encontrado: $installer"
        exit 1
    }

    # --- Ja esta na versao alvo? -------------------------------------------
    $targetVersion = ConvertTo-Version (Get-Item $installer).VersionInfo.FileVersion
    Write-Log "Instalador: $(Split-Path $installer -Leaf) | Versao: $targetVersion"

    if ($current) {
        $currentVersion = ConvertTo-Version $current.DisplayVersion
        if ($currentVersion -and $targetVersion -and $currentVersion -ge $targetVersion) {
            Write-Log "Versao atual ($currentVersion) >= alvo ($targetVersion). Nada a fazer."
            exit 0
        }
    }

    # --- Sessao ICA ativa: nao derrubar o usuario ----------------------------
    $sessionProcs = Get-Process -Name 'wfica32', 'wfica', 'CDViewer' -ErrorAction SilentlyContinue
    if ($sessionProcs) {
        Write-Log ("Sessao Citrix ativa ({0}). Saindo com 1618 para nova tentativa." -f (($sessionProcs.Name | Sort-Object -Unique) -join ', '))
        exit 1618
    }

    # Fecha somente a interface (bandeja/Self-Service), sem sessao ativa
    Get-Process -Name 'Receiver', 'SelfService', 'SelfServicePlugin' -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Log "Encerrando $($_.Name) (PID $($_.Id))"; Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }

    # --- Remove o HDX RTME em silencio (senao o instalador pede OK ao usuario) --
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
        $root = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
        if (-not $root) { continue }
        foreach ($name in $root.GetSubKeyNames()) {
            $key = $root.OpenSubKey($name)
            if (-not $key) { continue }
            $dn = [string]$key.GetValue('DisplayName')
            if ($dn -like '*HDX RealTime Media Engine*' -and $name -match '^\{[0-9A-Fa-f\-]{36}\}$') {
                Write-Log "Removendo $dn ($name)"
                $rtme = Start-Process -FilePath "$env:windir\System32\msiexec.exe" -ArgumentList "/x $name /qn /norestart" -Wait -PassThru -WindowStyle Hidden
                Write-Log "RTME msiexec exit: $($rtme.ExitCode)"
            }
            $key.Close()
        }
        $root.Close(); $base.Close()
    }

    # --- Parametros ----------------------------------------------------------
    # Sintaxe conforme documentacao Citrix: AutoUpdateCheck sem barra
    # Padrao da equipe (application atual do SCCM): /silent /includeSSON /IncludeAppProtection
    $arguments = @('/silent', '/includeSSON', '/IncludeAppProtection', 'AutoUpdateCheck=disabled')

    foreach ($a in $ExtraArgs) {
        if ($arguments -notcontains $a) { $arguments += $a }
    }
    $argLine = $arguments -join ' '
    Write-Log "Executando: `"$installer`" $argLine"

    # --- Instalacao ----------------------------------------------------------
    $proc = Start-Process -FilePath $installer -ArgumentList $argLine -Wait -PassThru -WindowStyle Hidden
    $code = $proc.ExitCode
    Write-Log "Codigo de saida do instalador: $code"

    switch ($code) {
        0       { $result = 0 }
        3010    { $result = 3010 }
        40008   { $result = 3010 }   # Citrix: instalado, reinicializacao necessaria
        default { $result = $code }
    }

    # --- Verificacao ---------------------------------------------------------
    $after = @(Get-CitrixWorkspaceInstall)
    foreach ($i in $after) {
        Write-Log ("Pos-instalacao: {0} | {1} | {2}" -f $i.DisplayName, $i.DisplayVersion, $i.InstallLocation)
    }
    if ($after.Count -gt 1) {
        Write-Log 'ATENCAO: mais de uma entrada do Citrix Workspace no registro apos a instalacao.'
    }

    Write-Log "===== Fim (exit $result) ====="
    exit $result
}
catch {
    Write-Log "ERRO: $($_.Exception.Message)"
    exit 1
}
