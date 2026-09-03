# Monitoramento de Memória via Intune Proactive Remediation

## Contexto

Diante do volume de chamados solicitando upgrade de memória em notebooks, esta solução usa o recurso **Proactive Remediations** do Intune para coletar, de forma automatizada e recorrente, dados reais de pressão de memória e os processos que mais consomem RAM em cada máquina — permitindo diferenciar com dados:

- **RAM realmente insuficiente** para a carga de trabalho do usuário (justifica upgrade)
- **Processo/aplicação vazando memória** (o problema é o app, não o hardware)
- **Padrão pontual** (pico isolado, não crônico)

## Como funciona

O Proactive Remediation do Intune roda em pares de script:

1. **Detection script**: executa periodicamente em todas as máquinas do grupo atribuído. Verifica se há pressão de memória (pouca RAM disponível ou % Committed alto). Se detectar pressão, marca o device como "não conforme" (`exit 1`) e dispara o remediation script. Se estiver normal, sai com `exit 0`.
2. **Remediation script** (opcional): roda apenas quando a detecção aponta pressão. Aqui, em vez de tentar "corrigir" algo (upgrade de memória é ação de hardware, não script), ele registra um segundo snapshot no momento exato do problema — permitindo comparar antes/depois e ver se algum processo específico estava crescendo.

Ambos os scripts gravam:
- Um **snapshot JSON local** em `C:\ProgramData\IntuneMemoryMonitor\` (histórico rotativo, mantém os últimos 60 arquivos)
- Um **evento no Event Log** (`Application`, source `IntuneMemoryMonitor`) com o resumo — isso é o que possibilita centralizar os dados depois via Log Analytics, sem precisar instalar outro agente.

## Script 1 — Detection-MemoryPressure.ps1

```powershell
<#
.SYNOPSIS
    Script de DETECÇÃO para Intune Proactive Remediation.
    Verifica pressão de memória e captura top processos consumidores.

.DESCRIPTION
    - Roda no contexto SYSTEM (padrão do Intune).
    - Se disponibilidade de memória estiver abaixo do limiar OU % Committed
      estiver acima do limiar, considera o device "não conforme" (exit 1),
      o que dispara o script de remediação (se configurado).
    - Sempre grava um snapshot JSON local + evento no Event Log, independente
      de estar em pressão ou não, para dar histórico comparável.

.NOTES
    Ajuste os thresholds abaixo conforme o perfil de hardware do seu parque.
#>

# ===================== CONFIGURAÇÃO =====================
$MinAvailableMB      = 1024   # alerta se memória disponível < 1 GB
$MaxCommittedPercent = 90     # alerta se % Committed Bytes In Use > 90%
$TopProcessCount     = 10
$LogFolder           = "C:\ProgramData\IntuneMemoryMonitor"
$MaxSnapshotsToKeep  = 60     # rotação simples (evita crescer indefinidamente)
$EventLogName        = "Application"
$EventSource         = "IntuneMemoryMonitor"
# ==========================================================

function Write-MemEvent {
    param(
        [string]$Message,
        [ValidateSet("Information","Warning","Error")]
        [string]$EntryType = "Information",
        [int]$EventId = 1000
    )
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
            New-EventLog -LogName $EventLogName -Source $EventSource -ErrorAction Stop
        }
        Write-EventLog -LogName $EventLogName -Source $EventSource -EntryType $EntryType `
            -EventId $EventId -Message $Message -ErrorAction Stop
    } catch {
        # Se não conseguir registrar (permissão, etc.), não deve travar o script
    }
}

try {
    if (-not (Test-Path $LogFolder)) {
        New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
    }

    # ---- Coleta de contadores de memória ----
    $availCounter = (Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples.CookedValue
    $commitCounter = (Get-Counter '\Memory\% Committed Bytes In Use' -ErrorAction Stop).CounterSamples.CookedValue
    $pageFaultsSec = (Get-Counter '\Memory\Page Faults/sec' -ErrorAction SilentlyContinue).CounterSamples.CookedValue
    $pagesPerSec   = (Get-Counter '\Memory\Pages/sec' -ErrorAction SilentlyContinue).CounterSamples.CookedValue

    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $totalRAM_GB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)

    # ---- Top processos por consumo de memória (Working Set) ----
    $topProcesses = Get-Process -ErrorAction SilentlyContinue |
        Sort-Object WorkingSet64 -Descending |
        Select-Object -First $TopProcessCount -Property `
            @{N='Name';E={$_.ProcessName}},
            @{N='PID';E={$_.Id}},
            @{N='WorkingSetMB';E={[math]::Round($_.WorkingSet64/1MB,1)}},
            @{N='PrivateMemMB';E={[math]::Round($_.PrivateMemorySize64/1MB,1)}}

    $topProcessesText = ($topProcesses | ForEach-Object {
        "$($_.Name) (PID $($_.PID)): WS=$($_.WorkingSetMB)MB Priv=$($_.PrivateMemMB)MB"
    }) -join "; "

    $isPressure = ($availCounter -lt $MinAvailableMB) -or ($commitCounter -gt $MaxCommittedPercent)

    $snapshot = [PSCustomObject]@{
        Timestamp          = (Get-Date).ToString("o")
        ComputerName       = $env:COMPUTERNAME
        LoggedOnUser       = (Get-CimInstance Win32_ComputerSystem).UserName
        TotalRAM_GB        = $totalRAM_GB
        AvailableMB        = [math]::Round($availCounter,1)
        CommittedPercent   = [math]::Round($commitCounter,1)
        PageFaultsPerSec   = [math]::Round($pageFaultsSec,1)
        PagesPerSec        = [math]::Round($pagesPerSec,1)
        MemoryPressure     = $isPressure
        TopProcesses       = $topProcesses
    }

    # ---- Grava snapshot JSON local (histórico) ----
    $fileName = "MemorySnapshot_{0}.json" -f (Get-Date -Format "yyyyMMdd_HHmmss")
    $snapshot | ConvertTo-Json -Depth 4 | Out-File -FilePath (Join-Path $LogFolder $fileName) -Encoding utf8

    # Rotação: mantém só os N mais recentes
    Get-ChildItem -Path $LogFolder -Filter "MemorySnapshot_*.json" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $MaxSnapshotsToKeep |
        Remove-Item -Force -ErrorAction SilentlyContinue

    # ---- Registra no Event Log (para coleta remota futura via Log Analytics/AMA) ----
    $eventMsg = "RAM total: $totalRAM_GB GB | Disponivel: $([math]::Round($availCounter,1)) MB | " +
                "Committed: $([math]::Round($commitCounter,1))% | TopProcessos: $topProcessesText"

    if ($isPressure) {
        Write-MemEvent -Message "PRESSAO DE MEMORIA DETECTADA. $eventMsg" -EntryType Warning -EventId 1001
        Write-Host "Memory pressure detected. Available=${availCounter}MB Committed=${commitCounter}%. TopProcesses: $topProcessesText"
        exit 1   # dispara remediação (se houver script associado)
    } else {
        Write-MemEvent -Message "Snapshot normal. $eventMsg" -EntryType Information -EventId 1000
        Write-Host "OK. Available=${availCounter}MB Committed=${commitCounter}%."
        exit 0
    }

} catch {
    Write-Host "Erro na coleta: $($_.Exception.Message)"
    Write-MemEvent -Message "Erro no script de deteccao: $($_.Exception.Message)" -EntryType Error -EventId 1099
    exit 0   # não força não-conformidade por falha de coleta
}
```

## Script 2 — Remediation-MemoryPressure.ps1

```powershell
<#
.SYNOPSIS
    Script de REMEDIAÇÃO para Intune Proactive Remediation (par do Detection-MemoryPressure.ps1).

.DESCRIPTION
    Upgrade de memória é uma ação de hardware — este script não "resolve" o problema,
    mas registra um segundo snapshot no momento em que a pressão foi detectada,
    permitindo comparar antes/depois e identificar se algum processo específico
    está vazando memória (crescendo entre snapshots) vs. é apenas RAM insuficiente
    para a carga normal de trabalho do usuário.

    Pode ser estendido futuramente com ações seguras (ex.: reiniciar um processo
    específico conhecido por vazar memória), mas isso deve ser avaliado caso a caso
    antes de automatizar - reiniciar processos sem critério pode causar perda de
    trabalho do usuário.
#>

$LogFolder    = "C:\ProgramData\IntuneMemoryMonitor"
$EventLogName = "Application"
$EventSource  = "IntuneMemoryMonitor"

function Write-MemEvent {
    param(
        [string]$Message,
        [ValidateSet("Information","Warning","Error")]
        [string]$EntryType = "Information",
        [int]$EventId = 2000
    )
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
            New-EventLog -LogName $EventLogName -Source $EventSource -ErrorAction Stop
        }
        Write-EventLog -LogName $EventLogName -Source $EventSource -EntryType $EntryType `
            -EventId $EventId -Message $Message -ErrorAction Stop
    } catch { }
}

try {
    if (-not (Test-Path $LogFolder)) {
        New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
    }

    $topProcesses = Get-Process -ErrorAction SilentlyContinue |
        Sort-Object WorkingSet64 -Descending |
        Select-Object -First 10 -Property `
            @{N='Name';E={$_.ProcessName}},
            @{N='PID';E={$_.Id}},
            @{N='WorkingSetMB';E={[math]::Round($_.WorkingSet64/1MB,1)}}

    $topText = ($topProcesses | ForEach-Object { "$($_.Name)=$($_.WorkingSetMB)MB" }) -join "; "

    $avail = (Get-Counter '\Memory\Available MBytes').CounterSamples.CookedValue

    $fileName = "RemediationSnapshot_{0}.json" -f (Get-Date -Format "yyyyMMdd_HHmmss")
    [PSCustomObject]@{
        Timestamp    = (Get-Date).ToString("o")
        ComputerName = $env:COMPUTERNAME
        AvailableMB  = [math]::Round($avail,1)
        TopProcesses = $topProcesses
    } | ConvertTo-Json -Depth 4 | Out-File -FilePath (Join-Path $LogFolder $fileName) -Encoding utf8

    Write-MemEvent -Message "Remediacao executada (log-only). Available=${avail}MB. TopProcessos: $topText" `
        -EntryType Warning -EventId 2001

    Write-Host "Snapshot de remediacao registrado. Available=${avail}MB."
    exit 0

} catch {
    Write-Host "Erro na remediacao: $($_.Exception.Message)"
    exit 0
}
```

## Como configurar no Intune

1. **Devices > Scripts and remediations > Proactive remediations > Create**
2. Suba o `Detection-MemoryPressure.ps1` como detection script e o `Remediation-MemoryPressure.ps1` como remediation script (opcional — pode rodar só a detecção)
3. **Run this script using the logged-on credentials: No** — precisa ser SYSTEM para acessar contadores de todos os processos, não só os do usuário logado
4. Agende a execução — sugestão: a cada 4-6h nas máquinas que já abriram chamado, ou diário no parque todo para gerar uma baseline
5. Atribua a um grupo Entra ID: comece pelos devices dos chamados abertos, depois expanda conforme necessidade

## Onde ficam os dados

- **Local, por máquina**: `C:\ProgramData\IntuneMemoryMonitor\` — snapshots JSON com timestamp, RAM total, disponível, % committed, page faults e os 10 processos que mais consomem memória
- **Event Log local**: `Application`, source `IntuneMemoryMonitor` — resumo estruturado de cada execução (normal ou com pressão)
- **Painel do Intune**: mostra apenas taxa de compliant/non-compliant e o texto resumido do `Write-Host` — não o JSON completo

### Centralizando os dados (próximo passo, se necessário)

Como os eventos já ficam estruturados no Event Log, existem dois caminhos para consolidar isso sem precisar montar Prometheus:

1. **Azure Monitor Agent + Log Analytics**: uma Data Collection Rule coletando esse Event Log/source customizado nas máquinas envia os dados para o Log Analytics Workspace. O **Grafana tem plugin nativo de Azure Monitor/Log Analytics**, então dá para consultar via KQL direto no Grafana — sem exporter, sem Prometheus.
2. **Logs Ingestion API direto do script**: adaptar o script para, além de gravar no Event Log, enviar o snapshot JSON via HTTPS para um Data Collection Endpoint, caindo numa tabela custom no Log Analytics — sem precisar de agente adicional nas máquinas.

## Vantagens de usar Proactive Remediation dessa forma

- **Usa infraestrutura que já existe**: nenhum agente novo, nenhuma aprovação de ARB para infraestrutura adicional (Prometheus server, storage, etc.) — roda em cima do que o Intune já gerencia.
- **Dado real, não achismo de chamado**: em vez de decidir upgrade de memória baseado só na reclamação do usuário, você tem série histórica objetiva de disponibilidade de RAM e quais processos pesam mais em cada máquina.
- **Diferencia causa raiz**: separa "RAM insuficiente para a carga normal" de "app com vazamento de memória" — isso muda completamente a ação corretiva (upgrade de hardware vs. correção/atualização de software).
- **Escala para o parque todo sem esforço manual**: uma vez configurado, roda automaticamente e recorrente em todas as máquinas do grupo atribuído, sem depender de alguém logar manualmente para investigar.
- **Baixo risco operacional**: o script é somente leitura (não altera nada no sistema, não mata processos, não reinicia serviços) — o `exit 1` apenas sinaliza pressão para fins de relatório/gatilho do remediation, sem impacto no usuário.
- **Caminho de evolução natural**: o mesmo dado coletado pode alimentar Log Analytics + Grafana futuramente, sem precisar trocar de abordagem — só adiciona a camada de ingestão quando fizer sentido.
- **Baseline para negociação de hardware**: dá munição objetiva para justificar (ou não) upgrades em lote, com dados por device em vez de decisão caso a caso via chamado.
