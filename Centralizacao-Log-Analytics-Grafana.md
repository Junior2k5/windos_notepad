# Centralizando os Dados de Memória — Log Analytics + Grafana

Este guia detalha os dois caminhos possíveis para tirar os dados de memória coletados nas
máquinas (via `Detection-MemoryPressure.ps1`) do disco local de cada device e colocá-los
num workspace central consultável — sem precisar montar Prometheus.

**Pré-requisito comum aos dois caminhos**: uma **Log Analytics Workspace** já criada
(ou nova) dentro de uma subscription Azure com permissão de administração.

---

# Opção 1 — Azure Monitor Agent (AMA) + Data Collection Rule (DCR)

Aqui você não altera o script — ele já grava no Event Log local (source `IntuneMemoryMonitor`).
O AMA, instalado na máquina, lê esse Event Log e envia para o Log Analytics conforme a regra
de coleta definida.

### Passo 1 — Criar (ou confirmar) a Log Analytics Workspace

1. No portal Azure: **Log Analytics workspaces > Create**
2. Escolha a subscription, resource group e região (idealmente a mesma região das outras
   cargas de monitoramento da empresa)
3. Anote o **Workspace ID** — será usado depois nas queries e na config do Grafana

### Passo 2 — Distribuir o Azure Monitor Agent nas máquinas via Intune

1. **Devices > Configuration profiles > Create profile**
   → Platform: Windows 10/11 → Profile type: **Settings catalog**
2. Procure por "Azure Monitor Agent" nas configurações, ou — caminho mais comum —
   distribua o AMA como **Win32 app** (pacote MSI do agente) via **Apps > Windows > Add**
3. Atribua ao mesmo grupo de devices usado no Proactive Remediation

> Alternativa: se as máquinas já forem gerenciadas via **Azure Arc**, o AMA pode ser
> habilitado direto pelo Arc, sem depender do pacote Win32 no Intune.

### Passo 3 — Criar a Data Collection Rule (DCR) para o Event Log customizado

1. Portal Azure: **Monitor > Data Collection Rules > Create**
2. **Basics**: nome (ex: `dcr-memoria-endpoint`), region, resource group
3. **Resources**: associe os devices (ou o grupo/Azure Arc resource) que terão o AMA
4. **Collect and deliver**:
   - Data source type: **Windows Event Logs**
   - XPath query customizado, filtrando pela source do evento:
     ```
     Application!*[System[Provider[@Name='IntuneMemoryMonitor']]]
     ```
   - Destination: a Log Analytics Workspace criada no Passo 1
5. Salve — a partir daqui, todo evento gravado pelo script com a source
   `IntuneMemoryMonitor` passa a ser replicado para a tabela `Event` no workspace.

### Passo 4 — Validar a ingestão

No workspace, em **Logs**, rode:

```kql
Event
| where Source == "IntuneMemoryMonitor"
| project TimeGenerated, Computer, EventLevelName, RenderedDescription
| order by TimeGenerated desc
```

Se aparecerem eventos, a pipeline está funcionando. Como o payload vai como texto na
`RenderedDescription`, para extrair campos (RAM, % Committed, top processos) use `parse`
ou `extract`:

```kql
Event
| where Source == "IntuneMemoryMonitor"
| extend AvailMB = extract(@"Disponivel: ([\d\.]+) MB", 1, RenderedDescription)
| extend CommittedPct = extract(@"Committed: ([\d\.]+)%", 1, RenderedDescription)
| project TimeGenerated, Computer, AvailMB, CommittedPct, RenderedDescription
| order by TimeGenerated desc
```

### Passo 5 — Conectar o Grafana

1. No Grafana: **Connections > Data sources > Add data source > Azure Monitor**
2. Configure a autenticação — normalmente via **App Registration** (Client ID, Client
   Secret, Tenant ID) com permissão de **Log Analytics Reader** no workspace
3. Em **Logs**, selecione a subscription e o workspace criado no Passo 1
4. Crie um painel novo, tipo **Table** ou **Time series**, e cole a query KQL do Passo 4
   como fonte dos dados
5. Salve o dashboard — a partir daqui, atualização é automática conforme o refresh
   configurado no Grafana (ex: a cada 5 min)

### Vantagens desta opção
- Não altera o script já em produção — só adiciona infraestrutura de coleta em cima
- AMA é o agente padrão da Microsoft, já usado por Defender/Sentinel se a empresa tiver
- Um único AMA pode coletar múltiplas fontes (não só este Event Log) — reaproveitável

### Desvantagens
- Precisa instalar e manter mais um agente por máquina (AMA)
- Parsing do payload via `extract`/`parse` em KQL é menos limpo que campos estruturados
  nativos (ver Opção 2)
- Latência de ingestão do AMA costuma ser maior que envio direto via API

---

# Opção 2 — Logs Ingestion API (envio direto do script via HTTPS)

Aqui o script passa a enviar o JSON estruturado direto para o Log Analytics, sem depender
de nenhum agente instalado na máquina — só precisa de conectividade HTTPS de saída.

### Passo 1 — Criar a tabela customizada no Log Analytics Workspace

1. No workspace: **Tables > Create > New custom log (DCR-based)**
2. Nome da tabela, ex: `MemoryMonitor_CL` (o sufixo `_CL` é automático para tabelas custom)
3. Defina o schema (pode subir um JSON de exemplo do seu snapshot para o portal inferir
   os tipos automaticamente):

```json
{
  "TimeGenerated": "2026-09-03T12:00:00Z",
  "ComputerName": "NOTE-12345",
  "LoggedOnUser": "DOMINIO\\usuario",
  "TotalRAM_GB": 8,
  "AvailableMB": 512.3,
  "CommittedPercent": 93.2,
  "PageFaultsPerSec": 1450.2,
  "PagesPerSec": 220.1,
  "MemoryPressure": true,
  "TopProcessesJson": "[{\"Name\":\"chrome\",\"WorkingSetMB\":1200.5}]"
}
```

> Dica: mantenha `TopProcesses` como uma string JSON serializada (`TopProcessesJson`) em
> vez de objeto aninhado — tabelas custom no Log Analytics lidam melhor com campos
> "achatados"; você desserializa depois na query KQL com `parse_json()`.

### Passo 2 — Criar o Data Collection Endpoint (DCE)

1. Portal Azure: **Monitor > Data Collection Endpoints > Create**
2. Nome, region, resource group
3. Após criado, anote a **Logs ingestion URL** (algo como
   `https://dcr-memoria-xxxx.brazilsouth-1.ingest.monitor.azure.com`)

### Passo 3 — Criar a Data Collection Rule (DCR) para ingestão via API

1. **Monitor > Data Collection Rules > Create**
2. Associe o **Data Collection Endpoint** do Passo 2
3. Em **Data sources**, escolha **fonte customizada** (não Windows Event Log desta vez) —
   isso define o schema de entrada esperado pela API
4. Em **Destination**, aponte para a tabela `MemoryMonitor_CL` criada no Passo 1
5. Salve e anote:
   - **DCR Immutable ID** (aparece em **JSON View** da DCR, campo `immutableId`)
   - **Stream name** (geralmente `Custom-MemoryMonitor_CL`)

### Passo 4 — Criar uma App Registration para autenticação

1. **Microsoft Entra ID > App registrations > New registration**
   - Nome: `sp-memorymonitor-ingest`
   - Sem necessidade de redirect URI
2. Em **Certificates & secrets**, crie um **Client secret** e anote o valor (só aparece
   uma vez)
3. Anote também **Application (client) ID** e **Directory (tenant) ID**
4. Na **DCR criada no Passo 3**, vá em **Access control (IAM) > Add role assignment**
   - Role: **Monitoring Metrics Publisher**
   - Assign access to: o App Registration criado acima

> Esse App Registration é o "usuário de serviço" que o script vai usar para se autenticar
> e enviar dados — sem precisar de credencial de usuário real.

### Passo 5 — Distribuir as credenciais de forma segura para o script

**Não** deixe o `Client Secret` em texto puro no script. Opções recomendadas:

- Gravar o secret como valor protegido usando `DPAPI`/`Protect-CmsMessage` local por
  máquina (mais trabalho, mas evita secret compartilhado)
- Ou — mais simples e comum em ambientes Intune — usar um **Managed Identity** se as
  máquinas forem **Azure Arc-enabled**, eliminando o secret por completo
- Como alternativa pragmática para começar, o secret pode ser injetado como variável de
  ambiente pelo próprio Proactive Remediation (script criptografado no payload do Intune,
  que já trafega de forma segura entre o serviço e o device)

### Passo 6 — Adaptar o script de detecção para enviar via API

Adicione ao final do `Detection-MemoryPressure.ps1` (após montar o `$snapshot`), antes do
`exit`:

```powershell
# ===================== ENVIO PARA LOG ANALYTICS =====================
$TenantId     = "<tenant-id>"
$ClientId     = "<client-id>"
$ClientSecret = "<client-secret>"   # ver Passo 5 sobre como proteger isso
$DceEndpoint  = "https://dcr-memoria-xxxx.brazilsouth-1.ingest.monitor.azure.com"
$DcrImmutableId = "dcr-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
$StreamName   = "Custom-MemoryMonitor_CL"

try {
    # 1. Obter token OAuth2 para o recurso monitor.azure.com
    $tokenBody = @{
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "https://monitor.azure.com/.default"
        grant_type    = "client_credentials"
    }
    $tokenResponse = Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Body $tokenBody

    $accessToken = $tokenResponse.access_token

    # 2. Montar o payload no formato esperado pela tabela custom
    $payload = @(
        @{
            TimeGenerated     = (Get-Date).ToString("o")
            ComputerName      = $env:COMPUTERNAME
            LoggedOnUser      = $snapshot.LoggedOnUser
            TotalRAM_GB       = $snapshot.TotalRAM_GB
            AvailableMB       = $snapshot.AvailableMB
            CommittedPercent  = $snapshot.CommittedPercent
            PageFaultsPerSec  = $snapshot.PageFaultsPerSec
            PagesPerSec       = $snapshot.PagesPerSec
            MemoryPressure    = $snapshot.MemoryPressure
            TopProcessesJson  = ($snapshot.TopProcesses | ConvertTo-Json -Compress)
        }
    ) | ConvertTo-Json -Depth 5

    # 3. Enviar via Logs Ingestion API
    $ingestUri = "$DceEndpoint/dataCollectionRules/$DcrImmutableId/streams/$StreamName" + "?api-version=2023-01-01"

    Invoke-RestMethod -Method Post -Uri $ingestUri `
        -Headers @{ Authorization = "Bearer $accessToken" } `
        -ContentType "application/json" `
        -Body $payload

} catch {
    Write-MemEvent -Message "Falha ao enviar para Log Analytics: $($_.Exception.Message)" `
        -EntryType Error -EventId 1098
    # não interrompe o script — falha de envio não deve gerar não-conformidade
}
# ======================================================================
```

### Passo 7 — Validar a ingestão

No workspace, em **Logs**:

```kql
MemoryMonitor_CL
| project TimeGenerated, ComputerName, AvailableMB, CommittedPercent, MemoryPressure,
          TopProcessesJson
| order by TimeGenerated desc
```

Para desserializar o top de processos:

```kql
MemoryMonitor_CL
| extend Processes = parse_json(TopProcessesJson)
| mv-expand Processes
| project TimeGenerated, ComputerName, ProcessName = Processes.Name,
          WorkingSetMB = Processes.WorkingSetMB
| order by TimeGenerated desc
```

### Passo 8 — Conectar o Grafana

Mesmo processo da Opção 1 (data source **Azure Monitor**, autenticação via App
Registration com **Log Analytics Reader**), mas agora as queries apontam para
`MemoryMonitor_CL` — dados já estruturados, sem precisar de `extract`/`parse` em texto
livre.

### Vantagens desta opção
- Dados **nativamente estruturados** na tabela — queries mais simples e rápidas, sem regex
- **Nenhum agente adicional** instalado na máquina (só HTTPS de saída)
- Menor latência entre coleta e disponibilidade no workspace
- Schema controlado por você — fácil adicionar novos campos no futuro

### Desvantagens
- Mais peças de infraestrutura para montar na criação (DCE, DCR, App Registration, tabela
  custom) — maior esforço inicial de setup
- Gestão de credencial (client secret) exige cuidado — rotação periódica, ou migrar para
  Managed Identity via Azure Arc quando possível
- Se a máquina estiver sem internet/VPN no momento da execução, o envio falha silenciosamente
  (o script já trata isso sem quebrar a detecção, mas o dado daquele ciclo se perde do lado
  central — só fica local)

---

# Qual escolher primeiro?

| Critério | Opção 1 (AMA + Event Log) | Opção 2 (Logs Ingestion API) |
|---|---|---|
| Esforço inicial de setup | Menor (reaproveita agente se já existir) | Maior (DCE, DCR, App Reg, tabela custom) |
| Alteração no script | Nenhuma | Necessária |
| Qualidade do dado para consulta | Texto livre (precisa parse) | Estruturado nativamente |
| Agente adicional na máquina | Sim (AMA) | Não |
| Gestão de credenciais | Não aplicável | Client secret ou Managed Identity |
| Latência | Maior | Menor |

Se a empresa **já usa AMA** para outras finalidades (Sentinel, Defender for Endpoint,
etc.), a **Opção 1** tende a ser mais rápida de colocar em produção. Se o objetivo é um
dado limpo e sem depender de mais um agente por máquina, a **Opção 2** compensa o esforço
inicial maior.
