# self-healing

**Objetivo**
-------------

- Buscar no Splunk Cloud os alertas que chegam ao Splunk ITSI (episódios correlacionados pelo AIOps), classificar por tipo no EDA do AAP e, depois do período de observação, disparar a autorremediação com throttle. O projeto integra só o Splunk e o AAP.
- Desde 08/10/2026, para cada alerta SLOW DISK de servidor Linux, servidor Windows, hypervisor (ESXi) ou processo: mandar e-mail ao time solucionador do tipo do alerta, sem acessar o servidor, avisando que a solução automática está pronta para receber a ação que vamos definir junto com o time, e devolver o resultado ao Splunk.
- A estrutura que entra no servidor pelo jumper do datacenter e lê só o uso do disco do alerta com `df` continua no repositório, desligada pela variável `acessar_servidor` (ver "Acesso ao servidor").
- Hoje o projeto trata só alertas SLOW DISK, no rulebook `self-healing-slowdisk`, na activation `self-healing-slowdisk` e nos Job Templates `self-healing-linux-slowdisk` e `self-healing-windows-slowdisk`. O LOW DISK SPACE de Linux, que até 08/10/2026 só era registrado no log deste rulebook, saiu dele e vai para o rulebook do time UNIX, que já faz a limpeza do `/var`.

=======================================================================

**Ambiente**
-------------

- [x] Desenvolvimento;
- [x] Homologação;
- [x] Produção.

=======================================================================

**Funções**
-------------

- [x] Buscar a cada 60 segundos, no índice `itsi_grouped_alerts` do Splunk Cloud, os episódios de SLOW DISK (todos os sistemas), com o source plugin `org_clbr_ti_ops_it_service_automation.eda_splunk.splunk_search`;
- [x] Entregar cada episódio uma única vez às regras (deduplicação por `episodeId`) e aplicar throttle de 30 minutos por host e disco;
- [x] Registrar em log cada alerta classificado, com os campos que a fase 2 vai usar (`alertToolId`, `problemId`, `entityId`, `solucionador`, `startTime`);
- [x] Registrar o estado da busca (heartbeat de hora em hora, erro, recuperação), para a falha nunca ficar silenciosa;
- [x] SLOW DISK de servidor Linux (`entityId` do alerta começando com `HOST-`): lançar o Job Template `self-healing-linux-slowdisk` no instance group da tabela `dc`, com throttle de 30 minutos por host e disco (ligado em 07/10/2026);
- [x] Mandar e-mail em HTML com os dados do alerta ao time solucionador do tipo do alerta, com cópia para o AIOps (destinatários em "E-mail"), sem acessar o servidor (desde 08/10/2026);
- [x] Envio do e-mail aos times solucionadores: ligado em 08/10/2026 (`notificacao_enviar_aos_times: true`, ver "Como ligar o envio aos times");
- [ ] Acesso ao servidor pelo jumper do datacenter, só com `df` no disco do alerta, tentando primeiro o nome e depois o IP: estrutura pronta e desligada (`acessar_servidor: false`, ver "Acesso ao servidor");
- [x] SLOW DISK de hypervisor (ESXi, `entityId` começando com `HYPERVISOR-`): lançar o Job Template `self-healing-linux-slowdisk` só para mandar e-mail, sem acessar o hypervisor, com throttle de 30 minutos por hypervisor e disco (ligado em 07/10/2026);
- [x] SLOW DISK de processo (`entityId` que não começa com `HOST-` nem com `HYPERVISOR-`, como `PROCESS_GROUP-`): lançar o Job Template `self-healing-linux-slowdisk` só para mandar e-mail, sem acesso a servidor, com throttle de 30 minutos por processo e disco;
- [x] SLOW DISK de servidor Windows (`entityOS` igual a `WINDOWS`): lançar o Job Template `self-healing-windows-slowdisk` só para mandar e-mail, sem acessar o servidor, com throttle de 30 minutos por servidor e disco (ligado em 07/10/2026);
- [x] SLOW DISK de outros sistemas operacionais ou sem sistema informado, e de servidor Linux, servidor Windows, hypervisor ou processo sem `diskPath`: só registro no log, sem job e sem e-mail;
- [ ] Fase 2: remediação por tipo de alerta, só com ação acordada com a equipe solucionadora;
- [x] Devolver ao Splunk, pelo HEC, o resultado de todo job dos dois Job Templates, para o episódio ser contabilizado: ligado em 08/10/2026; desde a ligação do envio aos times, todas as entradas da tabela `dc` rodam em Campinas com a credencial 282, então todo job devolve, inclusive os alertas de Lapa e Mackenzie, com token temporário (ver "Devolução ao Splunk");
- [ ] Troca para o token próprio do self-healing; devolução a partir dos execution nodes de Lapa e Mackenzie só se o acesso ao servidor for religado, depois da liberação de firewall;
- [ ] Fase 2: e-mail para a equipe responsável com o resultado da remediação.

=======================================================================

## Fluxo

```
Alertas que chegam ao Splunk ITSI (episódios do AIOps no índice itsi_grouped_alerts)
   <- activation "self-healing-slowdisk" no nó EDA 10.29.6.57
        source org_clbr_ti_ops_it_service_automation.eda_splunk.splunk_search
        a cada 60 s: POST https://claro.splunkcloud.com:8089/services/search/jobs (oneshot)
        pelo proxy de Lapa http://10.29.177.37:8080, token da credencial do EDA
        descarta episodeId já entregue e entrega um evento por episódio
   -> regras do rulebook (throttle de 30 minutos por host e disco; regras de controle só debug)
   -> SLOW DISK Linux: run_job_template "self-healing-linux-slowdisk" no instance group da tabela dc
        sem acesso ao servidor (acessar_servidor: false)
        e-mail ao time solucionador do tipo do alerta
        devolução do resultado ao HEC do Splunk on-prem (selfhealing_status failure)
        com acessar_servidor: true, antes do e-mail:
          exec node do datacenter -> jumper do datacenter -> servidor do alerta (só df do disco do alerta)
   -> SLOW DISK de hypervisor (ESXi): run_job_template "self-healing-linux-slowdisk" sem acesso, só e-mail
   -> SLOW DISK de processo: run_job_template "self-healing-linux-slowdisk" sem acesso, só e-mail
   -> SLOW DISK de servidor Windows: run_job_template "self-healing-windows-slowdisk" sem acesso, só e-mail
   -> SLOW DISK de outro sistema, sem sistema ou sem diskPath: só debug
```

O projeto integra só o Splunk e o AAP: as regras, o playbook e o e-mail usam apenas os campos que vêm no alerta do Splunk. O EDA busca os alertas; o Splunk não envia nada para o EDA. Não há porta aberta no nó EDA, regra de firewall de entrada nem configuração do lado do Splunk. A seleção dos alertas é a SPL do rulebook.

Até 06/10/2026 a entrada era um webhook na porta 5003, alimentado pelo heavy forwarder on-prem 10.88.4.246. Esse modelo foi trocado porque dependia de configuração no Splunk on-prem (os nossos alertas têm `automationValid=0` e nunca entravam na macro `automationAlerts`) e de liberação de firewall.

## Fases

**Fase 1: só observar (de 02/10/2026 a 07/10/2026, encerrada).** Todas as regras só geravam `debug` (e `print_event` nos casos fora do esperado), para medir volume por tipo de alerta, latência (`recebido` menos `inicio`/1000) e o comportamento do throttle. Hoje só as regras de controle e as de SLOW DISK sem os dados necessários continuam assim.

**Teste SLOW DISK (de 07/10/2026 a 08/10/2026, encerrado).** A regra SLOW DISK de servidor Linux lançava o Job Template, que entrava no servidor pelo jumper do datacenter e lia só o uso do disco do alerta com `df`. Essa estrutura continua no repositório, desligada pela variável `acessar_servidor` (ver "Acesso ao servidor").

**Atual: e-mail ao time solucionador, sem acesso ao servidor (desde 08/10/2026).** As regras SLOW DISK de servidor Linux, hypervisor e processo lançam o Job Template `self-healing-linux-slowdisk`, e a de servidor Windows lança o `self-healing-windows-slowdisk`. Os dois não acessam nenhum servidor, jumper ou hypervisor (`acessar_servidor: false`), mandam o e-mail ao time solucionador do tipo do alerta e devolvem ao Splunk `selfhealing_status` igual a `failure` ("Esse alerta ainda não possui self-healing, mas o time foi acionado por e-mail"). O envio aos times está ligado desde 08/10/2026 (`notificacao_enviar_aos_times: true`), e todos os jobs rodam em Campinas e devolvem o resultado ao Splunk (ver "Devolução ao Splunk"). SLOW DISK de outro sistema operacional, ou sem sistema informado, só gera `debug`. Detalhes em "Comportamento atual", "E-mail" e "Como ligar o envio aos times".

**Fase 2: remediação por tipo de alerta.** A ação `debug` das regras classificadas passa a ser `run_job_template` do Job Template do sistema operacional do alerta (`self-healing-linux-slowdisk` para Linux e `self-healing-windows-slowdisk` para Windows), no instance group do datacenter do alerta. O playbook usa o servidor que vem no próprio alerta do Splunk: o `entityHost` e, quando o alerta é de processo, o `entityIC`, que traz o servidor onde o processo roda. Depois aplica a ação aprovada para o tipo do alerta, mede antes e depois e manda e-mail para a equipe responsável. Regras que já valem para a fase 2:

- LOW DISK SPACE: fora deste projeto desde 08/10/2026; vai para o rulebook do time UNIX, que já faz a limpeza do `/var`;
- mounts de dados (`/dw`, `/bi`, `/app`, volumes de pod do Kubernetes e parecidos): nunca limpar, só diagnóstico e e-mail ao dono;
- `/var`: fica com a activation 24 e a automação de limpeza do `/var` do time UNIX; este projeto não mexe;
- episódios já cobertos por outra automação (`automationValid=1`): só observação;
- SLOW DISK: só leitura (`df` do disco do alerta) e e-mail, nunca remediação;
- produção sensível com aprovação antes da execução.

O `site.yml`, as roles e a EE do Job Template já existem para o teste SLOW DISK. A remediação da fase 2 entra como roles novas no mesmo playbook, mantendo o Job Template `self-healing-linux-slowdisk` para Linux e o `self-healing-windows-slowdisk` para Windows. Os dois Job Templates usam o mesmo `site.yml`; o tipo do alerta decide o que o job faz.

## Estrutura do repositório

| Caminho | Conteúdo |
|---|---|
| `rulebooks/self-healing-slowdisk.yml` | Rulebook `self-healing-slowdisk` da activation (fase 1 e teste SLOW DISK) |
| `decision-environment/` | Fonte da Decision Environment `self-healing` (ansible-builder v3) |
| `site.yml` | Playbook dos Job Templates `self-healing-linux-slowdisk` e `self-healing-windows-slowdisk`, só chama as roles |
| `roles/alvo/` | Lê o alerta, identifica o tipo do alerta e o datacenter pela localidade e, só com `acessar_servidor: true`, monta os endereços do servidor e inclui o jumper no inventário da execução |
| `roles/diagnostico/` | Só com `acessar_servidor: true`: no jumper, entra no servidor do alerta por ssh e lê só o uso do disco do alerta com `df` |
| `roles/notificacao/` | Escolhe os destinatários pelo tipo do alerta, monta e envia o e-mail; no fim do job, encerra com falha se o e-mail não saiu |
| `roles/devolucao/` | Devolve o resultado do job ao Splunk pelo HEC |
| `execution-environment/` | Fonte da EE do Job Template (imagem `self-healing-ee`) |
| `collections/requirements.yml` | Collections usadas pelo playbook |
| `group_vars/all.yml` | Variável `acessar_servidor` (hoje `false`), que liga ou desliga o acesso ao servidor pelo jumper |
| `ansible.cfg` | Configuração padrão do template |

## A busca

O source é a collection `org_clbr_ti_ops_it_service_automation.eda_splunk` (repositório `CLBR-TI-OPS-IT-SERVICE-AUTOMATION/eda-splunk`, publicada no Hub do AAP). O README dela descreve todos os parâmetros, o formato dos eventos e o troubleshooting do plugin.

Parâmetros usados neste rulebook:

| Parâmetro | Valor | Motivo |
|---|---|---|
| `url` | `https://claro.splunkcloud.com:8089` | API do Splunk Cloud (o `itsi.claro.splunkcloud.com` recusa o token) |
| `token` | `{{ splunk_token }}` | injetado pela credencial `self-healing-splunk` |
| `proxy` | `http://10.29.177.37:8080` | o nó EDA só alcança o Splunk Cloud pelo proxy de Lapa |
| `interval` | 60 s | uma busca por minuto |
| `lookback` | 600 s | cobre restart rápido da activation |
| `overlap` / `delay` | 60 s / 30 s | sobreposição absorvida pela deduplicação; atraso para o dado indexado ficar pesquisável |
| `max_window` | 1800 s | maior janela depois de falhas |
| `timeout` / `max_time` | 50 s / 45 s | a busca termina no Splunk antes de o plugin desistir |
| `search_level` | `fast` | sem descoberta de campos; a SPL nomeia todos os campos e o resultado foi igual ao `smart` no teste de 06/10/2026 |
| `max_results` | 1000 | |
| `dedup_field` / `dedup_ttl` | `episodeId` / 6 h | um evento por episódio |
| `heartbeat` | 3600 s | estado `ok` de hora em hora no log |

### SPL

- Lê `index=itsi_grouped_alerts`, só `orig_title="SLOW DISK*"`, de qualquer sistema. O filtro de LOW DISK SPACE de Linux saiu da SPL em 08/10/2026.
- No `itsi_grouped_alerts` todo campo chega duplicado, como lista de dois valores iguais. O `foreach ... mvindex(..., 0)` normaliza todos os campos antes do `split`, do `coalesce` e do `stats`.
- `stats ... by episodeId` devolve uma linha por episódio com o valor mais recente de cada campo. Episódio com evento de fechamento (`itsi_dummy_closing_flag`) na mesma janela é descartado.
- A SPL tem `earliest=-15m@m latest=@m` logo depois do `index=itsi_grouped_alerts`, a pedido do time do Splunk (07/10/2026). O Splunk troca o `earliest_time`/`latest_time` enviado pelo plugin pelo tempo da SPL (mensagem INFO "Your timerange was substituted based on your search string"), mas continua aplicando o `index_earliest`/`index_latest` do plugin. A busca devolve só os episódios indexados na janela do plugin e com `_time` nos últimos 15 minutos (teste de 07/10/2026: mesmo resultado da busca sem o `earliest`, mesmo tempo, cerca de 1 s). Episódio indexado com mais de 14 minutos de atraso, ou parada da activation maior que 15 minutos, fica de fora; o atraso medido em 24 horas foi de no máximo 72 s.
- A SPL não pode ter `{{`, `{%` ou `{#`, porque os argumentos do source passam pelo Jinja.

### Campos do evento

| Campo | Exemplo | Observação |
|---|---|---|
| `episodeId` | `<itsi_group_id>\|\|\|<eventId>\|\|\|<idCorrelacao>` | chave da deduplicação |
| `alertTitle` | `SLOW DISK` | as regras comparam só o começo do título |
| `entityHost` | `CBC2AM29312.CORP.CLAROBR` | |
| `entityName` | `HOST \| IP1, IP2` | |
| `entityIp` | `172.28.138.30, 172.28.165.102` | texto, pode ter vários IPs |
| `entityOS`, `entityIC`, `entityLocation`, `ambiente` | `LINUX`, `...`, `DC-CAMPINAS`, `PRD` | |
| `diskPath` | `/DW/HUB_QOD` | em maiúsculas; normalizar com `lower` só no playbook |
| `alertToolId`, `problemId` | `4480021706547709792_1791297420000V2` | id do Problem na ferramenta de origem do alerta; usado só como texto |
| `displayId` | `P-261015865` | |
| `entityId` | `HOST-19B616637E6C56B4` | |
| `startTime` | `1791297600000` | em milissegundos |
| `indexTime` | `1791297844` | `_indextime` do evento mais recente, em segundos |
| `solucionador` | `CLBR-TI-OPS-DATAOPS_PLATAFORMA` | equipe responsável |
| `originTool` | `Dynatrace SaaS` | parte dos SLOW DISK vem como `Dynatrace SaaS - Redirected - (Info)` |
| `automationValid`, `automationName` | `0`, `Nenhuma` | `1` quando outra automação já cobre o episódio |
| `splunk_search` | `dedup_key`, `window_start`, `window_end` | acrescentado pelo plugin |
| `meta` | `source.name`, `received_at`, `uuid` | acrescentado pelo ansible-rulebook |

Todos os valores chegam como texto. Campo nulo não vem do Splunk e chega como "não definido" nas regras.

## Regras do rulebook

O ruleset se chama `self-healing-slowdisk` (nome que aparece no Rule Audit do EDA e na variável `ansible_eda.ruleset` dos jobs). Até 08/10/2026 havia também as regras `LOW DISK SPACE - com diskPath` e `LOW DISK SPACE - sem diskPath`, só de log; elas saíram junto com o filtro de LOW DISK SPACE da SPL.

| Regra | Condição resumida | Throttle (30 min) | Ação na fase 1 |
|---|---|---|---|
| SLOW DISK - Linux | título começa com SLOW DISK, tem `entityHost`, `entityOS` igual a `LINUX` (sem diferenciar maiúsculas), `entityId` começando com `HOST-` e `diskPath` | `entityHost` + `diskPath` | debug + `run_job_template` do JT `self-healing-linux-slowdisk` (teste SLOW DISK) |
| SLOW DISK - Linux sem diskPath | igual à anterior, sem `diskPath` | `entityHost` | debug |
| SLOW DISK - hypervisor | título começa com SLOW DISK, tem `entityHost`, `entityOS` igual a `LINUX`, `entityId` começando com `HYPERVISOR-` e `diskPath` | `entityHost` + `diskPath` | debug + `run_job_template` do JT `self-healing-linux-slowdisk` com a entrada `PADRAO` da tabela `dc` (sem acesso, só e-mail) |
| SLOW DISK - hypervisor sem diskPath | igual à anterior, sem `diskPath` | `entityHost` | debug |
| SLOW DISK - processo | título começa com SLOW DISK, tem `entityHost`, `entityOS` igual a `LINUX`, `entityId` que não começa com `HOST-` nem com `HYPERVISOR-` e `diskPath` | `entityHost` + `diskPath` | debug + `run_job_template` do JT `self-healing-linux-slowdisk` com a entrada `PADRAO` da tabela `dc` (sem acesso, só e-mail) |
| SLOW DISK - processo sem diskPath | igual à anterior, sem `diskPath` | `entityHost` | debug |
| SLOW DISK - Linux sem entityId | título começa com SLOW DISK, tem `entityHost`, `entityOS` igual a `LINUX` e não tem `entityId` | `entityHost` | debug |
| SLOW DISK - Windows | título começa com SLOW DISK, tem `entityHost`, `entityOS` igual a `WINDOWS` (sem diferenciar maiúsculas) e `diskPath` | `entityHost` + `diskPath` | debug + `run_job_template` do JT `self-healing-windows-slowdisk` com a entrada `PADRAO` da tabela `dc` (sem acesso, só e-mail) |
| SLOW DISK - Windows sem diskPath | igual à anterior, sem `diskPath` | `entityHost` | debug |
| SLOW DISK - outro SO | título começa com SLOW DISK, tem `entityHost` e `entityOS` diferente de `LINUX` e de `WINDOWS` | `entityHost` | debug |
| SLOW DISK - sem SO | título começa com SLOW DISK, tem `entityHost` e não tem `entityOS` | `entityHost` | debug |
| Disco sem host | título começa com SLOW DISK e não tem `entityHost` | `meta.source.name` | debug + print_event |
| Fora do filtro | título que não começa com SLOW DISK (a SPL ou o ITSI mudou); um LOW DISK SPACE que chegue por engano cai aqui e não lança job | `meta.source.name` | debug + print_event |
| Sem titulo | episódio sem `alertTitle` | `meta.source.name` | debug + print_event |
| Estado da busca no Splunk | evento de estado do plugin | nenhum | debug |

Cada evento casa com uma regra só. As condições são cadeias de `and` com `is defined`, `is not defined` e `is not search`. Não usar `not ( ... )` com campo opcional dentro: no ansible-rulebook isso descarta o evento em silêncio.

Linhas esperadas no log da activation:

```
splunk_search: busca ok; janela 1791299447 a 1791299567 (120 s); 4 linhas; 0 eventos novos; 0.73 s
[self-healing][linux][SLOW DISK] alerta=SLOW DISK host=... ip=... so=LINUX local=DC-CAMPINAS diskPath=/DW/LOGS ...
[self-healing][hypervisor][SLOW DISK] alerta=SLOW DISK hypervisor=BALTIMORE01... entityId=HYPERVISOR-... diskPath=... ...
[self-healing][processo][SLOW DISK] alerta=SLOW DISK processo=PMDTM ... local=NAO_MAPEADO diskPath=... entityId=PROCESS_GROUP-... ...
[self-healing][windows][SLOW DISK] alerta=SLOW DISK host=CLNEWCLAW7422.CORP.CLAROBR ... so=WINDOWS local=DC-MACKENZIE diskPath=G:\\ ...
[self-healing][fase1][SLOW DISK] alerta=SLOW DISK host=... so=<outro sistema> local=... diskPath=... ...
[self-healing][busca][OK] mensagem=1 buscas, 0 falhas, 8 eventos, 8 chaves lembradas ...
```

## Comportamento atual

Desde 08/10/2026 o job não acessa nenhum servidor. Para todo alerta SLOW DISK que chega ao Job Template (servidor Linux, servidor Windows, hypervisor e processo), o job:

1. lê o alerta e identifica o tipo pelo `entityId` e pelo `entityOS` (role `alvo`);
2. pula o play do jumper: nenhum host entra no grupo `jumper`, o play aparece como "skipping: no hosts matched" e nenhum `ssh` é feito;
3. manda o e-mail ao time solucionador do tipo do alerta (role `notificacao`, ver "E-mail");
4. devolve ao Splunk `selfhealing_status` igual a `failure` (role `devolucao`, ver "Devolução ao Splunk").

### Variáveis de controle

| Variável | Onde fica | Valor hoje | Para que serve |
|---|---|---|---|
| `acessar_servidor` | `group_vars/all.yml` | `false` | `true` liga de novo o acesso ao servidor pelo jumper do datacenter (ver "Acesso ao servidor") |
| `notificacao_enviar_aos_times` | `roles/notificacao/defaults/main.yml` | `true` (desde 08/10/2026) | `false` manda o e-mail só para `notificacao_destinatarios_validacao` (`leonardo.costa.terceiros@claro.com.br`); `true` manda aos times pelo tipo do alerta |
| `notificacao_destinatarios_por_tipo` | `roles/notificacao/defaults/main.yml` | ver "E-mail" | destinatário (Para) de cada tipo de alerta |
| `notificacao_destinatarios_copia` | `roles/notificacao/defaults/main.yml` | ver "E-mail" | cópia (Cc) de todos os e-mails aos times |
| `notificacao_destinatarios_validacao` | `roles/notificacao/defaults/main.yml` | `leonardo.costa.terceiros@claro.com.br` | destinatário enquanto `notificacao_enviar_aos_times` for `false` |
| `notificacao_destinatarios_teste` | `roles/notificacao/defaults/main.yml` | `[]` | para teste: quando tem algum endereço, o e-mail vai só para essa lista, sem cópia, em qualquer modo |
| `devolucao_ativa` | `roles/devolucao/defaults/main.yml` | `true` | `false` monta e mostra o evento no log, mas não envia ao Splunk |

Os valores em `group_vars/all.yml` e nos `defaults` das roles valem para todos os jobs. Uma extra var no lançamento do Job Template vale só para aquele job e tem prioridade sobre eles.

As extra vars da activation (a tabela `dc`) não chegam ao job: o rulebook usa a tabela só para escolher o instance group e as credenciais, e passa ao Job Template apenas a variável `alerta`. Por isso as chaves acima mudam por commit no repositório, seguido do sync do Project 2844, e não pela activation.

### Teste manual sem atingir os times nem o Splunk

Lançar o Job Template com o alerta e com as duas variáveis de teste:

```json
{
  "instance_groups": [3],
  "credentials": [282],
  "extra_vars": {
    "notificacao_destinatarios_teste": ["leonardo.costa.terceiros@claro.com.br"],
    "devolucao_ativa": false,
    "alerta": { "...": "campos do evento, como em Teste manual pelo Controller" }
  }
}
```

O job mostra na task "Destinatários do e-mail" o modo do envio, o Para e o Cc deste envio e também os destinatários que o tipo do alerta teria com o envio aos times ligado. A devolução aparece como "Devolução ao Splunk não enviada: desligada pela variável devolucao_ativa (false)."

### Como ligar o envio aos times

Ligado em 08/10/2026, depois do OK nos e-mails de validação, com os passos abaixo (backup da activation em `/root/claude/backup-aap/eda-activation-25-pre-envio-times-20261008-171701.json` na bastion; activation 25 de volta às 17h18, instância 337):

1. Activation 25: desabilitar (o EDA recusa a alteração com ela ligada), fazer backup do objeto, trocar a tabela `dc` das extra vars para todas as entradas no instance group de Campinas e só com a credencial da devolução, e habilitar de novo:

   ```yaml
   dc:
     DC-CAMPINAS:
       instance_groups: [3]
       credentials: [282]
     DC-LAPA:
       instance_groups: [3]
       credentials: [282]
     DC-MACKENZIE:
       instance_groups: [3]
       credentials: [282]
     PADRAO:
       instance_groups: [3]
       credentials: [282]
   ```

   Sem acesso ao servidor, o job não precisa rodar no datacenter do alerta nem das credenciais Machine dos jumpers. Rodando todo em Campinas, o único execution node que alcança o HEC, todos os alertas devolvem o resultado ao Splunk, inclusive os de Lapa e Mackenzie.
2. Repositório: em `roles/notificacao/defaults/main.yml`, trocar `notificacao_enviar_aos_times: false` por `notificacao_enviar_aos_times: true`, fazer commit e push na `main` e sincronizar o Project 2844.
3. Conferir o primeiro job real de cada tipo: task "Destinatários do e-mail" com "Modo do envio: times solucionadores", o Para e o Cc esperados, e a linha "Devolução ao Splunk: HTTP 200".

Para voltar a mandar só para a validação, trocar de novo para `false`, fazer commit e push na `main` e sincronizar o Project 2844. A tabela `dc` pode continuar como está: sem acesso ao servidor, ela só define onde o job roda e a credencial da devolução.

## Acesso ao servidor

A estrutura de acesso ao servidor (jumper do datacenter, `ssh` e `df` no disco do alerta) fica no repositório e está desligada desde 08/10/2026 por `acessar_servidor: false` em `group_vars/all.yml`. As roles `alvo` e `diagnostico`, as credenciais Machine 279, 280 e 281 e a EE não mudaram.

Com `false`, a role `alvo` não monta endereços nem inclui o jumper no inventário, o play da role `diagnostico` não tem host e nenhum `ssh` é feito. Com `true`, o job volta a funcionar como no teste SLOW DISK de 07/10/2026, descrito na seção seguinte: servidor Linux é acessado pelo jumper do datacenter e o e-mail usa as frases de acesso OK, falha no acesso e localidade não mapeada, com a tabela SITUAÇÃO DO DISCO quando o acesso dá certo. Windows, hypervisor e processo continuam sem acesso e com as frases novas.

Para religar:

1. Activation 25: desabilitar, voltar a tabela `dc` para o instance group e a credencial Machine de cada datacenter e habilitar de novo. Sem isso o job roda em Campinas sem a credencial do jumper de Lapa e de Mackenzie e cai em "o jumper não respondeu":

   ```yaml
   dc:
     DC-CAMPINAS:
       instance_groups: [3]
       credentials: [279, 282]
     DC-LAPA:
       instance_groups: [4]
       credentials: [280]
     DC-MACKENZIE:
       instance_groups: [5]
       credentials: [281]
     PADRAO:
       instance_groups: [3]
       credentials: [282]
   ```

2. Repositório: em `group_vars/all.yml`, trocar `acessar_servidor: false` por `acessar_servidor: true`, fazer commit e push na `main` e sincronizar o Project 2844.
3. Lapa e Mackenzie: com o job rodando nos execution nodes de Lapa (10.29.6.54) e de Mackenzie (10.53.9.92), a devolução ao Splunk só funciona depois da liberação de firewall desses nós até o 10.88.4.246, porta 8088; depois dela, incluir a 282 nas entradas `DC-LAPA` (`[280, 282]`) e `DC-MACKENZIE` (`[281, 282]`). Ver "Liberação de Lapa e Mackenzie".

## Teste SLOW DISK

Objetivo: para cada alerta SLOW DISK de servidor Linux, ver o disco do servidor no momento do alerta e decidir, com os e-mails, se esse tipo de alerta pode virar um self-healing. É só leitura: no servidor só é lida a lista de montagens (`/proc/mounts`) e rodado `df -hP` no disco do alerta (ou `bdf`, em HP-UX). Nada é criado, alterado ou apagado no servidor nem no jumper.

Ligado em produção de 07/10/2026 a 08/10/2026. Desde 08/10/2026 o acesso ao servidor está desligado (`acessar_servidor: false`); os passos 3 e 4 do fluxo abaixo só rodam com `acessar_servidor: true`, e as seções "Datacenters" e "O que é rodado no jumper e no servidor" descrevem esse modo. A seção "Extra vars da activation" mostra a tabela `dc` em uso hoje (todas as entradas em Campinas, desde a ligação do envio aos times) e a tabela usada enquanto o acesso estava ligado.

### Fluxo

1. A regra `SLOW DISK - Linux` do rulebook vale só para servidor Linux: `entityOS` igual a `LINUX`, `entityId` começando com `HOST-` e `diskPath` informado. Ela registra a linha `[self-healing][linux][SLOW DISK]` no log da activation e lança o Job Template `self-healing-linux-slowdisk` com o evento inteiro na variável `alerta`. Throttle de 30 minutos por host e disco: o mesmo disco do mesmo servidor gera no máximo um job e um e-mail a cada 30 minutos, inclusive quando a activation reinicia e o Splunk devolve episódios ainda abertos. A deduplicação por `episodeId` do plugin continua valendo.
   Alerta Linux cujo `entityId` não começa com `HOST-` não é de servidor: é de processo (`PROCESS_GROUP-`, como PMDTM, SQLLDR, SORT e ARCSIGHT) ou de hypervisor VMware (`HYPERVISOR-`). Os de hypervisor (ESXi, como BALTIMORE01, MEMPHIS05 e TACOMA) com `diskPath` caem na regra `SLOW DISK - hypervisor`, que registra a linha `[self-healing][hypervisor][SLOW DISK]` e lança o mesmo Job Template com a entrada `PADRAO` da tabela `dc` (instance group de Campinas, nenhuma credencial Machine), com throttle de 30 minutos por hypervisor e disco. O Self-healing não acessa ESXi: para hypervisor a role `alvo` não monta jumper nem tentativas, nenhum `ssh` é feito e o job só manda o e-mail. Os de processo com `diskPath` caem na regra `SLOW DISK - processo`, que registra a linha `[self-healing][processo][SLOW DISK]` e lança o Job Template do mesmo jeito, com a entrada `PADRAO` e throttle de 30 minutos por processo e disco. O alerta de processo traz em `entityIC` o servidor onde o processo roda, mas o Self-healing ainda não trata alertas de processo, por isso a role `alvo` também não monta jumper nem tentativas, nenhum `ssh` é feito e o job só manda o e-mail. Hypervisor e processo sem `diskPath` caem nas regras `SLOW DISK - hypervisor sem diskPath` e `SLOW DISK - processo sem diskPath`, só log. Em 30 dias (até 07/10/2026) foram 1.503 episódios de servidor (71 hosts), 278 de processo (28 processos) e 218 de hypervisor (26 hypervisors); todos com `entityId` e `diskPath`. Servidor Linux sem `diskPath` e Linux sem `entityId` caem nas regras `SLOW DISK - Linux sem diskPath` e `SLOW DISK - Linux sem entityId`, também só log. SLOW DISK de servidor Windows (`entityOS` igual a `WINDOWS`) com `diskPath` cai na regra `SLOW DISK - Windows`, que registra a linha `[self-healing][windows][SLOW DISK]` e lança o Job Template `self-healing-windows-slowdisk` com a entrada `PADRAO` da tabela `dc`, com throttle de 30 minutos por servidor e disco. O Self-healing ainda não acessa servidores Windows: a role `alvo` reconhece o Windows pelo `entityOS`, não monta jumper nem tentativas, nenhum acesso é feito (nem `ssh` nem WinRM) e o job só manda o e-mail. Windows sem `diskPath` cai na regra `SLOW DISK - Windows sem diskPath`, só log. As duas regras de Windows não olham o `entityId`: se um dia chegar alerta de processo ou de hypervisor com `entityOS` igual a `WINDOWS`, ele cai na regra `SLOW DISK - Windows` e no Job Template `self-healing-windows-slowdisk`, sem acesso, e o e-mail segue o tipo do `entityId` (processo ou hypervisor), porque nas roles `alvo` e `notificacao` o tipo do `entityId` tem prioridade sobre o sistema operacional. Em 30 dias (até 07/10/2026) foram 46 episódios de Windows, de 4 servidores, todos com `entityId` começando com `HOST-` e com `diskPath` (letra do disco, como `D:\\` e `G:\\`, ou compartilhamento de rede); nenhum SLOW DISK de outro sistema, sem `entityOS` ou sem `entityId`. SLOW DISK de outro sistema, ou sem `entityOS`, cai nas regras `SLOW DISK - outro SO` e `SLOW DISK - sem SO`. Todas essas regras de log têm throttle de 30 minutos por host.
2. O rulebook escolhe o instance group e a credencial Machine pela localidade do alerta (`entityLocation`), na tabela `dc` das extra vars da activation. Localidade fora da tabela, ou vazia, usa a entrada `PADRAO`: instance group de Campinas e só a credencial da devolução ao Splunk, nenhuma credencial Machine. Nesse caso o job não acessa nada e só manda o e-mail avisando que a localidade não está mapeada.
3. Play 1, em `localhost`, role `alvo`: lê o alerta, acha o datacenter e, só com `acessar_servidor: true`, monta os endereços do servidor (nome completo, nome curto e IPs, nessa ordem, no máximo 4) e inclui o jumper do datacenter no inventário da execução, como root.
4. Play 2, no jumper, role `diagnostico`, só com `acessar_servidor: true` (com `false` o play não tem host e é pulado): sem coleta de fatos e só com o módulo `raw`, porque o brux0156 é HP-UX sem Python. Do jumper, roda `ssh` no servidor do alerta com cada endereço até o primeiro acesso. Nenhuma falha aqui derruba o job: o resultado de cada tentativa fica registrado para o e-mail.
5. Play 3, em `localhost`, role `notificacao`: monta e envia o e-mail. Se o e-mail não sair depois das tentativas, o erro fica guardado e o job segue para a devolução.
6. Play 4, em `localhost`, role `devolucao`: devolve o resultado ao Splunk (ver "Devolução ao Splunk"). Nunca falha o job.
7. Play 5, em `localhost`: encerra o job com falha se o e-mail não saiu. É o único caso em que o job termina com falha.

### Datacenters

| Localidade | Instance group | Execution node | Jumper | IP do jumper | SO do jumper | Credencial Machine |
|---|---|---|---|---|---|---|
| `DC-CAMPINAS` | `DC_Campinas` (id 3) | 10.54.7.168 | brux0156 | 10.18.48.133 | HP-UX B.11.31 | `self-healing-jumper-campinas` (id 279) |
| `DC-LAPA` | `DC_Lapa` (id 4) | 10.29.6.54 | NET001PRDLNX010 | 10.28.129.16 | RHEL 8.9 | `self-healing-jumper-lapa` (id 280) |
| `DC-MACKENZIE` | `DC_Mackenzie` (id 5) | 10.53.9.92 | zabbix1 | 10.243.149.38 | RHEL 6.10 | `self-healing-jumper-mackenzie` (id 281) |
| outra ou vazia | `DC_Campinas` (id 3) | 10.54.7.168 | nenhum | | | nenhuma |

A tabela aparece em dois lugares, cada um com o seu papel: os ids do AAP (instance group e credencial) ficam na tabela `dc` das extra vars da activation, e os jumpers ficam em `roles/alvo/vars/main.yml`. Datacenter novo entra nos dois.

A credencial Machine é o usuário root com a chave privada que já entra no jumper a partir do exec node do datacenter. A chave fica só no Controller: nunca no repositório, na EE ou em log. Do jumper para o servidor do alerta vale a chave do root do próprio jumper.

### Extra vars da activation

Em uso desde 08/10/2026, com o envio aos times ligado e o acesso ao servidor desligado:

```yaml
dc:
  DC-CAMPINAS:
    instance_groups: [3]
    credentials: [282]
  DC-LAPA:
    instance_groups: [3]
    credentials: [282]
  DC-MACKENZIE:
    instance_groups: [3]
    credentials: [282]
  PADRAO:
    instance_groups: [3]
    credentials: [282]
```

Todas as entradas rodam em Campinas, o único execution node que alcança o HEC, e levam só a credencial 282 (`self-healing-splunk-hec`), da devolução ao Splunk. Sem acesso ao servidor, o job não precisa das credenciais Machine dos jumpers, e todos os alertas, inclusive os de Lapa e Mackenzie, devolvem o resultado.

Tabela usada até 08/10/2026, com o acesso ao servidor e a devolução ao Splunk ligados (volta a valer se `acessar_servidor` for `true`; `DC-LAPA` e `DC-MACKENZIE` recebem a 282 depois da liberação de firewall, ver "Devolução ao Splunk"):

```yaml
dc:
  DC-CAMPINAS:
    instance_groups: [3]
    credentials: [279, 282]
  DC-LAPA:
    instance_groups: [4]
    credentials: [280]
  DC-MACKENZIE:
    instance_groups: [5]
    credentials: [281]
  PADRAO:
    instance_groups: [3]
    credentials: [282]
```

As chaves da tabela são a localidade em maiúsculas e com hífen. Antes de procurar na tabela, o rulebook e a role `alvo` passam o `entityLocation` do alerta para maiúsculas e trocam `_` por `-`: `DC_CAMPINAS`, que aparece em parte dos alertas, vale como `DC-CAMPINAS` (o mesmo para `DC_LAPA` e `DC_MACKENZIE`). O token do Splunk não entra aqui: ele continua vindo da credencial `self-healing-splunk`. Depois de mudar as extra vars, reinicie a activation.

### O que é rodado no jumper e no servidor

No jumper, para cada endereço:

```bash
ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@<endereço> '<comando no servidor>' 2>&1; echo SELF_HEALING_RC=$?
```

No servidor:

```bash
t=""; command -v timeout >/dev/null 2>&1 && t="timeout -k 5 30"; m=""; [ -r /proc/mounts ] && m=$(cut -d" " -f2 /proc/mounts | grep -i -x -F -- "<disco do alerta em minúsculas>" | tail -1); [ -z "$m" ] && m="<disco do alerta em minúsculas>"; $t df -hP "$m" 2>/dev/null; r=$?; case $r in 0|124|137) ;; *) if [ -n "$t" ]; then $t df -hP; else df -hP 2>/dev/null || bdf; fi; r=$? ;; esac; exit $r
```

O `df -hP` é lido primeiro só no disco do alerta. O `diskPath` do alerta vem em maiúsculas e o Linux diferencia maiúsculas de minúsculas, por isso o comando procura em `/proc/mounts`, sem diferenciar a caixa, o ponto de montagem real do disco e roda o `df -hP` só nele; sem `/proc/mounts` (HP-UX), usa o caminho em minúsculas. Se esse caminho não existir no servidor, o comando roda o `df -hP` completo, e a role procura a linha cuja coluna "Mounted on" é igual ao disco do alerta, sem diferenciar maiúsculas e minúsculas. O caminho só entra na linha de comando se tiver apenas letras minúsculas, números e `/ . _ - + @`; fora disso, vai direto para o `df -hP` completo. O e-mail mostra só a linha desse disco (Disco, Tamanho, Usado, Livre e Uso) ou "Disco não encontrado no servidor."

| Item | Motivo |
|---|---|
| `BatchMode=yes` | nunca pede senha; sem chave aceita, falha na hora |
| `ConnectTimeout=10` | servidor fora do ar não prende o job |
| `StrictHostKeyChecking=no` e `UserKnownHostsFile=/dev/null` | não pergunta pela chave do servidor e não grava nada no `known_hosts` do jumper |
| `timeout -k 5 30 df -hP` | SLOW DISK costuma ser montagem NFS lenta, e o `df` pode travar nela. Servidor sem o comando `timeout` (HP-UX) roda `df -hP` e, se não existir, `bdf` |
| `-P` (formato POSIX) | uma linha por filesystem, sem quebra de linha em nomes longos, o que permite separar Tamanho, Usado, Livre, Uso e Montado em |
| `echo SELF_HEALING_RC=$?` | o `raw` sempre termina com código 0, porque o Ansible trata o código 255 de um comando remoto como queda da conexão com o jumper. O código real do `ssh` vem nessa linha |
| tempo máximo de 90 s por tentativa | se passar, a tentativa é interrompida e as próximas não são feitas |

Leitura do código de retorno:

| Código | Resultado no e-mail | Tenta o próximo endereço |
|---|---|---|
| 0 | acesso OK, `df` concluído | não |
| 124 ou 137 | acesso OK, mas o `df` passou de 30 s e foi interrompido (possível montagem travada) | não |
| 255 | falha no ssh, com a mensagem do ssh | sim |
| outro | acesso OK, `df` terminou com o código informado | não |
| jumper sem resposta | o jumper não respondeu, com o erro da conexão | não |

Nomes e IPs vindos do alerta só são usados se tiverem apenas letras, números, ponto, hífen e sublinhado (IP no formato IPv4), porque viram parte de uma linha de comando rodada como root no jumper.

### E-mail

| Item | Valor |
|---|---|
| Servidor SMTP | `vip_smtp.claro.com.br` (10.54.24.153), porta 25, sem autenticação e sem TLS |
| Remetente | `aiops.centroexcelencia@claro.com.br` |
| Destinatários | pelo tipo do alerta, ver a tabela abaixo (envio aos times ligado desde 08/10/2026; com `notificacao_enviar_aos_times: false`, só `leonardo.costa.terceiros@claro.com.br`) |
| Assunto | `[self-healing] SLOW DISK <servidor> <localidade>` |

Destinatários com o envio aos times ligado (`notificacao_enviar_aos_times: true`), em `roles/notificacao/defaults/main.yml`:

| Tipo do alerta | Como o tipo é reconhecido | Para | Cc |
|---|---|---|---|
| Servidor Linux | `entityOS` igual a `LINUX` | `supunix@claro.com.br` | `leonardo.costa.terceiros@claro.com.br`, `hassan.silva.terceiros@claro.com.br` |
| Servidor Windows | `entityOS` igual a `WINDOWS` | `SupServWin@claro.com.br` | os mesmos |
| Processo | `entityId` que não começa com `HOST-` nem com `HYPERVISOR-`; o destinatário segue o `entityOS` do alerta (`LINUX` para `supunix`, `WINDOWS` para `SupServWin`) | `supunix@claro.com.br` ou `SupServWin@claro.com.br` | os mesmos |
| Hypervisor (ESXi) | `entityId` começando com `HYPERVISOR-`, qualquer `entityOS` | `vmware.infrati@claro.com.br` | os mesmos |
| Sistema operacional diferente de `LINUX` e de `WINDOWS` (caso raro, as regras do rulebook não lançam job para ele) | | só os dois endereços da cópia, como Para | nenhum |

No último caso o log do job registra, na task "Destinatários do e-mail", que o sistema do alerta não é `LINUX` nem `WINDOWS`. Em qualquer modo, a lista `notificacao_destinatarios_teste`, quando tem algum endereço, substitui todos os destinatários e tira a cópia.

O e-mail é HTML feito para o Outlook (template `roles/notificacao/templates/corpo_email.html.j2`): tabelas, estilos inline, largura de 640 px, fonte Arial ou Segoe UI, sem imagens e sem CSS externo. Os valores do alerta passam por escape de HTML. De cima para baixo:

1. Faixa laranja com "SELF-HEALING • <título do alerta>" (verde só com `acessar_servidor: true` e acesso OK).
2. Frase de abertura, com o título em negrito. O texto é o mesmo para todos os tipos: "O processo de solução automática está pronto, porém o alerta não foi resolvido, pois **precisamos da ajuda do time solucionador para definirmos juntos a ação adequada** para este alerta e incluí-la no código." Os títulos:
   - servidor Linux: "O Ansible Automation Platform recebeu este alerta de um servidor Linux.";
   - servidor Windows: "O Ansible Automation Platform recebeu este alerta de um servidor Windows.";
   - hypervisor (ESXi): "O Ansible Automation Platform recebeu este alerta de um hypervisor (ESXi).";
   - processo: "O Ansible Automation Platform recebeu este alerta de um processo (<processo>), que roda no servidor <servidor>." O nome do processo é o `entityHost` do alerta (por exemplo, PMDTM) e o servidor é o `entityIC` (por exemplo, CLIICSLX0425.CLARO.COM.BR). Quando o `entityIC` vem vazio ou igual ao nome do processo, o título fica só "O Ansible Automation Platform recebeu este alerta de um processo (<processo>).";
   - sistema operacional diferente de `LINUX` e de `WINDOWS`: "O Ansible Automation Platform recebeu este alerta de um servidor.".

   Só com `acessar_servidor: true`, o servidor Linux usa as frases do teste SLOW DISK, guardadas em `roles/notificacao/vars/main.yml`:
   - acesso OK: "O Self-healing recebeu este alerta e acessou o servidor." e "O acesso foi somente para consulta: **nenhuma alteração foi feita no ambiente**. Abaixo está a situação atual do disco que está alarmando.";
   - falha no acesso: "O Self-healing recebeu este alerta, mas não conseguiu acessar o servidor." e "Para que este alerta possa ser resolvido automaticamente, **precisamos da ajuda do time solucionador para liberar a regra de firewall ou o acesso ao servidor** para o Self-healing.";
   - localidade não mapeada ou alerta sem nome e IP válidos: "O Self-healing recebeu este alerta, mas não acessou o servidor." e o motivo.
3. DADOS DO ALERTA, uma linha por campo, na ordem abaixo. As linhas marcadas com * aparecem sempre, com "não informado" quando o alerta não traz o campo; as outras só aparecem quando têm valor. A linha "Equipe solucionadora" saiu em 08/10/2026.

   | Linha | Campo do alerta |
   |---|---|
   | Título do alerta * | `alertTitle` |
   | Tipo * | Hypervisor (ESXi) ou Processo pelo início do `entityId`; senão Servidor Windows pelo `entityOS`; senão Servidor |
   | Processo * (só em alerta de processo) | `entityHost` |
   | Hostname * | nome curto do servidor (em alerta de processo, do servidor onde o processo roda), ver a regra abaixo |
   | FQDN | nome completo do mesmo servidor, quando o alerta traz um |
   | IC no CMDB | `entityIC`, fora de alerta de processo, só quando é outro servidor |
   | IP * | `entityIp`, entre parênteses |
   | Localidade * | `entityLocation` |
   | Ambiente | `ambiente` (PRD, HML, DSV) |
   | Disco * | `diskPath` |
   | Sistema operacional * | `entityOS` |
   | Origem do alerta | `originTool` |
   | Automação cadastrada no AIOps | `automationName` |
   | Início do alerta * | `startTime`, em dd/mm/aaaa hh:mm:ss no horário de São Paulo |
   | Registrado no Splunk | `indexTime`, no mesmo formato |
   | Recebido pelo Self-healing | `meta.received_at`, no mesmo formato |
   | Problem * | `displayId` (ou, sem ele, `problemId` e depois `alertToolId`), só como texto |
   | Entidade | `entityId` |
   | Episódio no ITSI | primeira parte do `episodeId` (o id do episódio no ITSI) |

   Regra do Hostname e do FQDN: o servidor é o `entityHost` (em alerta de processo, o `entityIC`). Fora de alerta de processo, quando o `entityIC` é o mesmo servidor (a parte antes do primeiro ponto é igual, sem diferenciar maiúsculas e minúsculas, como `CLIICSLX0425` e `CLIICSLX0425.CLARO.COM.BR`), os dois nomes viram uma linha Hostname com o nome curto e uma linha FQDN com o nome completo, e a linha IC no CMDB não aparece. Com um nome só: nome curto mostra só o Hostname; nome completo mostra o Hostname (a parte antes do primeiro ponto) e o FQDN. Quando o `entityIC` é outro servidor, ele aparece separado na linha IC no CMDB. O e-mail não tem link para nenhuma ferramenta.
4. SITUAÇÃO DO DISCO: não aparece com o acesso desligado. Só com `acessar_servidor: true` e acesso OK: tabela Disco, Tamanho, Usado, Livre e Uso, só com o disco do alerta. O Uso fica vermelho a partir de 90%, laranja de 80% a 89% e verde abaixo de 80%. Sem a linha do disco, aparece "Disco não encontrado no servidor." (ou o aviso de `df` interrompido por tempo).
5. Rodapé cinza, igual para todos: "Mensagem automática enviada pelo Ansible Automation Platform: nada foi criado, alterado ou apagado. A solução automática deste alerta é construída em conjunto pelo time de AIOps e pela área solucionadora. Procure-nos para desenvolvermos juntos a automação deste alerta."

Um resumo em texto do mesmo e-mail (template `corpo_email.txt.j2`) aparece na saída do job, na task "E-mail enviado", com o Para e o Cc usados.

### Job Template

| Campo | Valor |
|---|---|
| Nome | `self-healing-linux-slowdisk` (id 2846), usado para alertas de servidores Linux |
| Project / Inventory / EE | `self-healing` (id 2844) / `self-healing` (id 133) / `self-healing` (id 51) |
| Playbook | `site.yml` |
| Credencial | nenhuma fixa; vem no lançamento (`ask_credential_on_launch`) |
| Instance group | nenhum fixo; vem no lançamento (`ask_instance_groups_on_launch`) |
| Extra vars | vêm no lançamento (`ask_variables_on_launch`) |
| Execução simultânea | ligada |
| Timeout | 300 s (era 900 s até 08/10/2026; o job normal leva de 5 a 50 s, ver "Troubleshooting") |
| Label | nenhuma |

O Job Template `self-healing-windows-slowdisk` (id 2847), dos alertas de servidores Windows, tem a mesma configuração do `self-healing-linux-slowdisk`: mesmo Project, Inventory, EE e playbook `site.yml`, credencial, instance group e extra vars no lançamento, execução simultânea, timeout de 300 s e nenhuma label. Ele é lançado com a entrada `PADRAO` da tabela `dc` (instance group de Campinas, só a credencial da devolução ao Splunk) e não acessa o servidor: só manda o e-mail.

Os dois Job Templates foram renomeados em 08/10/2026, com os mesmos ids: antes eram `self-healing-linux` e `self-healing-windows`. O rulebook chama o Job Template pelo nome, por isso renomear um deles exige mudar o `run_job_template` do rulebook na mesma janela, com a activation parada.

O Job Template `self-healing` (id 2845), usado nos primeiros testes com a mesma configuração, foi apagado em 07/10/2026; o backup dele está na bastion, em `/root/claude/backup-aap/`.

Sem os `ask_*` ligados o Controller não dá erro: ignora o instance group e a credencial enviados (aparecem em `ignored_fields` na resposta do launch) e roda com os padrões do Job Template. Por isso o teste confere o job criado e não só o lançamento.

Inventory `self-healing`: um host `localhost` com `ansible_connection: local` e `ansible_python_interpreter: "{{ ansible_playbook_python }}"`. O jumper entra só em memória, com `add_host`, durante o job.

### Teste manual pelo Controller

Lançar o Job Template `self-healing-linux-slowdisk` com o instance group e a credencial do datacenter e a variável `alerta` com os campos do evento, por exemplo:

```json
{
  "instance_groups": [3],
  "credentials": [279],
  "extra_vars": {
    "alerta": {
      "alertTitle": "SLOW DISK",
      "entityHost": "<SERVIDOR>.CORP.CLAROBR",
      "entityIp": "<IP>",
      "entityName": "<SERVIDOR>.CORP.CLAROBR | <IP>",
      "entityLocation": "DC-CAMPINAS",
      "entityOS": "LINUX",
      "diskPath": "/<DISCO>",
      "episodeId": "teste-manual"
    }
  }
}
```

Conferir na resposta que `ignored_fields` veio vazio e, no job criado, o instance group, o execution node e a credencial usados.

Com a devolução ligada, um teste manual com a credencial 282 na lista `credentials` grava um evento de verdade em `index=ansible`, que entra na contabilização do painel de governança pelo `episode_id`. Para teste sem devolução, passar `"devolucao_ativa": false` nas extra vars (ou deixar a 282 fora da lista); para testar a devolução, combinar antes com o time Splunk. Para o e-mail não chegar aos times, passar também `"notificacao_destinatarios_teste"` (ver "Comportamento atual").

## Devolução ao Splunk

Todo job dos Job Templates `self-healing-linux-slowdisk` e `self-healing-windows-slowdisk` devolve ao Splunk o resultado do alerta, para o episódio ser contabilizado no painel de governança do AIOps. A role `devolucao` roda no fim do `site.yml`, depois do e-mail, em todas as situações: servidor acessado, falha no acesso, localidade não mapeada, Windows, hypervisor e processo. O e-mail e a devolução não dependem um do outro: se o e-mail falhar, a devolução é feita assim mesmo e o job termina com falha no fim; se a devolução falhar, o job e o e-mail seguem normais.

Situação em 08/10/2026: ligada nos jobs que rodam em Campinas, ou seja, nas entradas `DC-CAMPINAS` e `PADRAO` da tabela `dc` (localidade não mapeada, hypervisor, processo e Windows). Os jobs de `DC-LAPA` e `DC-MACKENZIE` ainda não devolvem e registram "Devolução ao Splunk não enviada". Com o passo de ligar o envio aos times (ver "Como ligar o envio aos times"), todas as entradas da tabela `dc` passam a rodar em Campinas com a 282 e todos os alertas passam a devolver, sem depender da liberação de firewall de Lapa e Mackenzie, que só volta a ser necessária se o acesso ao servidor for religado.

O token na credencial `self-healing-splunk-hec` é temporário: é o mesmo token HEC compartilhado do Job Template `devolve-splunk` (id 749), usado com autorização do dono do Splunk até ele gerar o token próprio do self-healing. Por isso os eventos chegam em `index=ansible`, `sourcetype=ansibleAutomation` e `source="http:Automações Ansible"`, os mesmos do Job Template 749. Quando o token próprio chegar, ver "Troca para o token próprio".

### Destino e formato

| Item | Valor |
|---|---|
| Endpoint | `https://10.88.4.246:8088/services/collector/raw`, HEC do Splunk on-prem, o mesmo da devolução dos outros self-healing |
| Autenticação | header `Authorization: Splunk <token>`, com o token próprio do self-healing gerado pelo time Splunk |
| Index e sourcetype | definidos pelo token no Splunk (index `ansible`); o playbook não define |
| Corpo | JSON plano, com os mesmos nomes de campo da devolução dos outros self-healing |
| Certificado | `validate_certs: false`, porque o certificado do HEC é autoassinado (ver "Riscos conhecidos e aceitos") |
| Proxy | nenhum: `use_proxy: false` e o IP do HEC no `no_proxy` |
| Tempo e repetição | timeout de 10 s e mais 2 tentativas, com 5 s de intervalo |
| Falha no envio | `failed_when: false` no envio e `block`/`rescue` na role inteira: nenhum erro da devolução falha o job. A task seguinte mostra só o código HTTP (`-1` quando não houve resposta); um erro ao montar o evento aparece como "Devolução ao Splunk não feita" |
| Log | a task do envio tem `no_log: true`. O evento enviado aparece antes, na task "Evento da devolução ao Splunk", sem o token |

### Resultado devolvido

Padrão desde 08/10/2026. **Os valores de `selfhealing_status` mudaram de `SUCESSO`, `PARCIAL` e `FALHA` para `success`, `partial` e `failure`**, e as mensagens também mudaram; avisar o time Splunk, porque o painel de governança e as buscas que filtram pelo valor antigo precisam acompanhar.

| `selfhealing_status` | `mensagem` | Quando |
|---|---|---|
| `failure` | Esse alerta ainda não possui self-healing, mas o time foi acionado por e-mail | hoje, em todos os alertas |
| `success` | Esse alerta possui self-healing, e a remediação funcionou | futuro, quando houver remediação e ela der certo |
| `partial` | Esse alerta possui self-healing, e a remediação falhou | futuro, quando houver remediação e ela falhar |

O mapeamento fica em `roles/devolucao/vars/main.yml`: `devolucao_mensagens` tem a mensagem de cada status e `devolucao_status_por_situacao` diz o status de cada situação do job (`linux`, `windows`, `hypervisor`, `processo`, `servidor` e, com `acessar_servidor: true`, `ok`, `falha` e `sem_acesso`). Hoje todas as situações estão em `failure`; situação que não estiver na lista também vira `failure`. `selfhealing_sucesso` é `true` só quando o status é `success`. A situação é a mesma que a role `notificacao` calcula para o e-mail; a role `devolucao` não repete essa regra.

A variável `devolucao_ativa` (padrão `true`, em `roles/devolucao/defaults/main.yml`) desliga o envio para teste: com `false` o evento continua montado e mostrado na task "Evento da devolução ao Splunk", mas nada é enviado, e o log mostra "Devolução ao Splunk não enviada: desligada pela variável devolucao_ativa (false)."

### Campos

| Campo | Conteúdo |
|---|---|
| `job_id` | id do job no Controller (`tower_job_id`), como número inteiro |
| `job_name` | nome do Job Template |
| `job_playbook` | `site.yml` |
| `job_status` | `successful` quando o job chega ao fim sem erro; `failed` quando o e-mail não saiu |
| `job_started` e `job_finished` | primeira task da role `alvo` e momento da devolução, em UTC (`aaaa-mm-ddThh:mm:ssZ`) |
| `job_duration` | segundos entre os dois, como número decimal com até 3 casas (por exemplo, `2.288`) |
| `job_errors` | lista curta de motivos; com o acesso desligado, fica vazia ou só com o erro do e-mail. Com `acessar_servidor: true`: motivo de não acessar, resultado de cada tentativa de `ssh` que falhou, disco não encontrado e erro do e-mail. Cada item tem no máximo 200 caracteres; a saída do job nunca vai |
| `hostname` | nome curto do servidor (em alerta de processo, do servidor onde o processo roda); `NAO_MAPEADO` quando não há nome |
| `datacenter` | localidade do alerta em maiúsculas e com hífen, como `DC-CAMPINAS`; `NAO_MAPEADO` quando vem vazia ou como `NAO_MAPEADO` no alerta |
| `alert_title` | `alertTitle` |
| `episode_id` | `episodeId` exatamente como veio do Splunk, com as três partes separadas por `\|\|\|`. Sem ele o episódio não é contabilizado |
| `tipo` | `disco` |
| `servico` | `Disco <diskPath>` |
| `metrica_antes` e `metrica_depois` | `N/A` com o acesso ao servidor desligado (hoje, sempre); com `acessar_servidor: true`, uso do disco lido no `df`, como `19%`, igual nos dois porque nada é alterado, e `N/A` quando o disco não foi lido |
| `metrica_esperada` | `N/A` |
| `metrica_atingida` | `false` |
| `selfhealing_status`, `selfhealing_sucesso` e `mensagem` | ver "Resultado devolvido" |

Os nomes dos campos não mudam sem aviso ao time Splunk, porque o painel de governança depende deles. Tipos no JSON enviado: `job_id` e `job_duration` vão como número (o Ansible converte o valor calculado), `job_errors` como lista, `metrica_atingida` e `selfhealing_sucesso` como booleanos (`true` ou `false`) e todos os outros como texto.

Exemplo, servidor Linux sem acesso ao servidor:

```json
{
  "job_id": 1234567,
  "job_name": "self-healing-linux-slowdisk",
  "job_playbook": "site.yml",
  "job_status": "successful",
  "job_started": "2026-10-08T17:36:31Z",
  "job_finished": "2026-10-08T17:36:33Z",
  "job_duration": 2.381,
  "job_errors": [],
  "hostname": "SRVTESTE01",
  "datacenter": "DC-CAMPINAS",
  "alert_title": "SLOW DISK",
  "episode_id": "<id do episódio>|||<id do alerta original>|||<id de correlação>",
  "tipo": "disco",
  "servico": "Disco /DW/HUB_QOD",
  "metrica_antes": "N/A",
  "metrica_depois": "N/A",
  "metrica_esperada": "N/A",
  "metrica_atingida": false,
  "selfhealing_status": "failure",
  "selfhealing_sucesso": false,
  "mensagem": "Esse alerta ainda não possui self-healing, mas o time foi acionado por e-mail"
}
```

### Credencial

| Objeto | Nome | Detalhe |
|---|---|---|
| Tipo de credencial (Controller) | `Splunk HEC` (id 62) | campos `url` (texto) e `token` (secreto), obrigatórios; injeta `splunk_hec_url` e `splunk_hec_token` nas extra vars do job |
| Credencial (Controller) | `self-healing-splunk-hec` (id 282) | org 12, URL do HEC acima e, desde 08/10/2026, o token HEC compartilhado do Job Template 749 (temporário, até o time Splunk entregar o token próprio) |

A role só envia quando as duas variáveis existem e o token é diferente de `TROCAR_PELO_TOKEN_REAL`. Sem a credencial no job, ou com o token fictício, registra "Devolução ao Splunk não enviada" e segue. O token nunca aparece no log do job: a tarefa de envio usa `no_log`.

### Alcance por datacenter

Teste de 08/10/2026, `curl` sem proxy no `/services/collector/health` do HEC a partir de cada execution node:

| Execution node | Instance group | Resultado |
|---|---|---|
| 10.54.7.168 | `DC_Campinas` (id 3) | alcança (HTTP 200) |
| 10.29.6.54 | `DC_Lapa` (id 4) | não alcança (timeout) |
| 10.53.9.92 | `DC_Mackenzie` (id 5) | não alcança (timeout) |

Enquanto o firewall não liberar Lapa e Mackenzie para o 10.88.4.246 na porta 8088, um job nesses instance groups com a credencial gasta cerca de 40 s a mais nas tentativas e não consegue devolver. Por isso todas as entradas da tabela `dc` rodam hoje em Campinas (ver "Extra vars da activation").

### Como foi ligado (08/10/2026)

1. O token foi colado na credencial `self-healing-splunk-hec` pela tela do Controller, no campo "Token do HEC".
2. A activation 25 foi desabilitada (o EDA recusa a alteração com ela ligada), a tabela `dc` das extra vars passou a ter a credencial 282 nas entradas `DC-CAMPINAS` e `PADRAO`, a `PADRAO` passou para o instance group de Campinas (3), e a descrição da activation passou a ser "Busca alertas SLOW DISK no Splunk e chama os Job Templates self-healing-linux-slowdisk e self-healing-windows-slowdisk". A tabela atual está em "Extra vars da activation". Backup da activation antes da mudança: `/root/claude/backup-aap/eda-activation-25-pre-devolucao-20261008-150601.json`, na bastion.
3. A activation 25 foi habilitada de novo.
4. Testes com "Devolução ao Splunk: HTTP 200" e um evento por job em `index=ansible`, com o `episode_id` igual ao do alerta: job 2973497 (manual, Linux, Campinas, PARCIAL), job 2973514 (manual, Windows, FALHA) e job 2973511 (primeiro job lançado pela activation depois de ligar, Linux, Campinas, PARCIAL). Esses três ainda usavam os valores antigos de `selfhealing_status`; o primeiro job real no padrão novo foi o 2974069 (Windows, `failure`, HTTP 200, e-mail só para a validação).

Para conferir um job: procurar a linha "Devolução ao Splunk: HTTP 200" no log e o evento no Splunk com `index=ansible job_id=<id do job>`. Para um teste manual, lançar o Job Template como em "Teste manual pelo Controller", com a 282 na lista `credentials`.

Para desligar, desabilitar a activation 25, tirar a 282 das listas da tabela `dc` e habilitar de novo; ou voltar o token da credencial para `TROCAR_PELO_TOKEN_REAL`, sem parar a activation.

### Liberação de Lapa e Mackenzie

Depois que o firewall liberar o execution node do datacenter até o 10.88.4.246, porta 8088 (conferir com `curl` sem proxy no `/services/collector/health` a partir do execution node), desabilitar a activation 25, incluir a 282 na lista `credentials` da entrada `DC-LAPA` (`[280, 282]`) ou `DC-MACKENZIE` (`[281, 282]`) e habilitar de novo.

### Troca para o token próprio

Quando o time Splunk enviar o token HEC próprio do self-healing, colar o token novo na credencial `self-healing-splunk-hec` (id 282) pela tela do Controller, no campo "Token do HEC". Não é preciso mexer na activation nem no código: o próximo job já usa o token novo. Conferir o primeiro job depois da troca (linha "Devolução ao Splunk: HTTP 200") e o evento no Splunk: o `index` e o `sourcetype` passam a ser os definidos no token novo, e o `source` deixa de ser `http:Automações Ansible`. Avisar o time Splunk antes, porque a contabilização no painel de governança pode depender do `sourcetype`.

### Pendências

- Token próprio do self-healing, gerado pelo time Splunk, no lugar do token compartilhado do Job Template 749.
- Liberação de firewall de Lapa (10.29.6.54) e Mackenzie (10.53.9.92) para o 10.88.4.246, porta 8088: só necessária se o acesso ao servidor for religado.
- Avisar o time Splunk da troca dos valores de `selfhealing_status` para `success`, `partial` e `failure` e das mensagens novas.
- Certificado confiável no HEC, para ligar `validate_certs`.

## Execution Environment do Job Template

Pasta `execution-environment/`, fonte de verdade da EE. Mudança sempre aqui primeiro, depois copiada para `/root/claude/ee-aap/self-healing/` na bastion 10.29.6.52, só para o build.

| Item | Conteúdo |
|---|---|
| Base | `registry.redhat.io/ansible-automation-platform-25/ee-minimal-rhel9:latest`, Python 3.11, ansible-core 2.19.14, ansible-runner 2.4.3, fuso `America/Sao_Paulo` |
| `requirements.yml` | `community.general` 11.0.0 (módulo `mail`) e `ansible.posix` 2.1.0 (callbacks do `ansible.cfg`) |
| `bindep.txt` | `openssh-clients` (ssh do job até o jumper) e `tzdata` |
| `requirements.txt` | vazio |

A imagem se chama `self-healing-ee`, e não `self-healing`, porque a tag `aap.claro.com.br/self-healing` já é a Decision Environment. No Controller o objeto EE se chama `self-healing`, igual ao repositório. Nenhuma chave ou senha entra na imagem.

| Tag | Data | Conteúdo |
|---|---|---|
| `1.0` | 06/10/2026 | primeira versão, teste SLOW DISK |
| `1.1` | 06/10/2026 | política de criptografia `DEFAULT:SHA1` e chave de host `ssh-rsa` só para os jumpers brux0156 e zabbix1 (ver "Riscos conhecidos e aceitos") |
| `1.2` | 08/10/2026 | igual à 1.1, só com o ansible-core 2.19.14 no lugar do 2.19.3. Motivo: bug de corrida entre os plays do ansible-core 2.19.0 a 2.19.3 ([issue 85879](https://github.com/ansible/ansible/issues/85879)), corrigido a partir do 2.19.4, que travava cerca de 5% dos jobs (ver "Troubleshooting"). Digest `sha256:153d92fe004a98943b26ef598e45a37bb39f92d927940eda035d897e0094c8bf` |

A tag publicada nunca é sobrescrita. Toda mudança gera uma tag nova e um `PATCH` no campo `image` do objeto EE `self-healing` do Controller.

A `1.1` usa o ansible-core 2.19.3, que tem um bug de corrida entre os plays (issues [85879](https://github.com/ansible/ansible/issues/85879) e [86027](https://github.com/ansible/ansible/issues/86027) do ansible-core, corrigido pelo [PR 85907](https://github.com/ansible/ansible/pull/85907) a partir do 2.19.4). Ele travava cerca de 5% dos jobs quando vários começavam juntos no mesmo execution node (ver "Troubleshooting"). A `1.2`, vigente desde 08/10/2026, sobe só o `ansible-core` para 2.19.14, sem outra mudança. Teste da `1.2` antes de entrar em produção: 100 execuções locais do `site.yml` (5 rodadas de 20 simultâneas, sem rede, SMTP falso) e, no Controller, 2 jobs avulsos (2975339 no 2846 e 2975340 no 2847) mais 2 rodadas de 10 jobs simultâneos do 2846 no mesmo execution node de Campinas (2975341 a 2975360), todos no modo teste: todos `successful`, nenhum `KeyError`, nenhum timeout. Para voltar atrás, `PATCH` da EE 51 com `{"image": "aap.claro.com.br/self-healing-ee:1.1"}`.

Build, push e limpeza seguem os mesmos passos da DE (seção "Decision Environment"), trocando a pasta para `/root/claude/ee-aap/self-healing`, o arquivo para `execution-environment.yml` e a imagem para `self-healing-ee:<versão>`. Esta EE não baixa nada do Hub, então o build não precisa das variáveis `ANSIBLE_GALAXY_SERVER_HUB_PUBLICADO_*`.

Teste antes do push:

```bash
podman run --rm localhost/self-healing-ee:<versão> ansible --version
podman run --rm localhost/self-healing-ee:<versão> ansible-galaxy collection list
podman run --rm localhost/self-healing-ee:<versão> ssh -V
```

## Decision Environment

Pasta `decision-environment/`, fonte de verdade da DE. Mudança sempre aqui primeiro, depois copiada para `/root/claude/de-aap/self-healing/` na bastion 10.29.6.52, só para o build.

| Item | Conteúdo |
|---|---|
| Base | `registry.redhat.io/ansible-automation-platform-25/de-minimal-rhel9:latest`: ansible-rulebook 1.1.7, ansible-core 2.16.19, Python 3.12, `ansible.eda` 2.10.0 certificada |
| `requirements.yml` | só `org_clbr_ti_ops_it_service_automation.eda_splunk` 1.0.0, baixada do Hub |
| `requirements.txt`, `bindep.txt` | vazios: a base já traz o `aiohttp` que o plugin usa |
| `ansible.cfg` | servidores Galaxy do build: Hub `published` e galaxy.ansible.com |
| `DROOLS_JPY_JVM_MAXMEM=128M` | heap máximo do Java do Drools (motor de regras do ansible-rulebook), passado como `-Xmx128M`. Sem essa variável o padrão é 512M, maior que o limite de 200 MB do container da activation |

Diferenças em relação ao padrão de EE da diretriz interna, por necessidade:

- Base `de-minimal-rhel9` e Python 3.12, e não `ee-minimal-rhel9` com Python 3.11: a DE precisa do ansible-rulebook, que só vem na imagem de DE, e essa base roda em 3.12. Apontar para outro interpretador faz o `ansible-builder` instalar um Python vazio e tentar compilar as dependências nele.
- `exclude.all_from_collections: [ansible.eda]`: a `ansible.eda` da base declara o `systemd-python`, que exige compilador e só serve para a fonte journald. Sem a exclusão o build tenta compilá-lo.

Versões:

| Tag | Data | Conteúdo |
|---|---|---|
| `1.0` | 02/10/2026 | `ansible.eda` 2.7.0 do galaxy.ansible.com (fonte webhook) |
| `1.1` | 06/10/2026 | `eda_splunk` 1.0.0 do Hub, `ansible.eda` certificada da base |
| `1.2` | 06/10/2026 | igual à 1.1, mais `DROOLS_JPY_JVM_MAXMEM=128M`. Motivo: o container da activation tem limite de 200 MB (`PODMAN_MEM_LIMIT` do nó EDA) e o Java do Drools podia crescer até 512M; o pico de memória já tinha chegado perto dos 200 MB e a instância 324 caiu com exit 137 em 05/10/2026 |

A tag publicada nunca é sobrescrita. Toda mudança gera uma tag nova e um `PATCH` no `image_url` da DE 3 do EDA.

### Medição de memória da 1.2

A DE 3 passou para a 1.2 em 06/10/2026 às 13:32, com restart da activation 25 (instância 327). Valores lidos no cgroup do container no nó EDA 10.29.6.57 (`memory.current`, `memory.peak`, `memory.events`) e no `ruleset_stats` da activation. O limite do container é 209.715.200 bytes (200 MiB).

| Momento | Instância | DE | `memory.current` | `memory.peak` | `memory.events` (max/oom/oom_kill) | Heap do Drools (`maxAvailableMemory`) |
|---|---|---|---|---|---|---|
| 06/10 13:31, cerca de 40 min no ar | 326 | 1.1 | 146,3 MB | 209,7 MB (no limite) | 0/0/0 | 536.870.912 (512 MiB) |
| 06/10 13:32, 25 s depois da subida | 327 | 1.2 | 125,1 MB | 152,7 MB | 0/0/0 | 134.217.728 (128 MiB) |
| 06/10 13:58, 26 min no ar | 327 | 1.2 | 130,6 MB | 152,7 MB | 0/0/0 | 134.217.728 (128 MiB) |
| 06/10 14:06, 34 min no ar | 327 | 1.2 | 132,2 MB | 152,7 MB | 0/0/0 | 134.217.728 (128 MiB) |

Leitura: o pico da 1.2 ficou em 152,7 MB, cerca de 57 MB abaixo do limite, só na subida, e depois a memória estabilizou entre 130 e 132 MB. O heap realmente usado pelo Drools fica entre 23 e 27 MB (`usedMemory`). Cerca de 105 MB do container são o Python do ansible-rulebook e a parte nativa do Java, que não encolhem; o heap pode crescer até os 128 MB antes de o Java limpar, por isso o acompanhamento é pelo `memory.peak` e não pelo `usedMemory`.

Acompanhamento: uma leitura por dia na primeira semana, depois uma por semana. O `memory.peak` é o maior valor desde a subida do container e só zera em restart, por isso a instância vai anotada junto. Gerar uma tag nova com `DROOLS_JPY_JVM_MAXMEM=96M` se o `memory.peak` passar de 180 MB ou se o contador `max` do `memory.events` deixar de ser 0 (o container tocou o limite; é o sinal que antecede a queda com exit 137). Com `usedMemory` abaixo de 30 MB, 96M ainda deixa folga de três vezes para o heap.

Para medir, no nó EDA como root. O comando acha o container da activation sozinho e mostra nome, imagem, tempo no ar, `memory.current`, `memory.peak`, `memory.max` e os contadores `max` e `oom_kill`:

```bash
su - eda -s /bin/bash -c 'c=$(podman ps --format "{{.ID}} {{.Image}}" | awk "/self-healing/ {print \$1}"); d=/sys/fs/cgroup$(podman inspect "$c" --format "{{.State.CgroupPath}}"); podman ps --filter id="$c" --format "{{.Names}} {{.Image}} {{.Status}}"; cat $d/memory.current $d/memory.peak $d/memory.max; grep -E "^(max|oom_kill) " $d/memory.events'
```

### Build

A senha do Hub vai pelo stdin e por variável de ambiente, nunca na linha de comando nem em arquivo:

```bash
cd /root/claude/de-aap/self-healing
export ANSIBLE_GALAXY_SERVER_HUB_PUBLICADO_USERNAME=admin
read -rs ANSIBLE_GALAXY_SERVER_HUB_PUBLICADO_PASSWORD
export ANSIBLE_GALAXY_SERVER_HUB_PUBLICADO_PASSWORD
ansible-builder build --no-cache -t self-healing:<versão> -f decision-environment.yml --verbosity=2 \
  --build-arg ANSIBLE_GALAXY_SERVER_HUB_PUBLICADO_USERNAME \
  --build-arg ANSIBLE_GALAXY_SERVER_HUB_PUBLICADO_PASSWORD
```

O pull da base exige login no `registry.redhat.io`. A bastion é usada por outras pessoas e o arquivo de autenticação padrão do root guarda a sessão de outro usuário no `aap.claro.com.br`, que um `podman login` ou `podman logout` comum troca ou apaga. Por isso todo login do build e do push usa um arquivo de autenticação próprio e temporário, criado antes do build e apagado no fim do push:

```bash
cd /root/claude/de-aap/self-healing
umask 077; printf '{}' > .auth-build.json
export REGISTRY_AUTH_FILE=$PWD/.auth-build.json
podman login registry.redhat.io -u <usuário> --password-stdin
```

Conferir com `podman login --get-login aap.claro.com.br` num shell sem a variável que a sessão do outro usuário continua a mesma.

### Teste antes do push

```bash
podman run --rm localhost/self-healing:<versão> ansible-rulebook --version
podman run --rm localhost/self-healing:<versão> ansible-galaxy collection list
```

Esperado: ansible-rulebook 1.1.x, `org_clbr_ti_ops_it_service_automation.eda_splunk` na versão do `requirements.yml` e `ansible.eda` da base.

Para rodar o rulebook na imagem sem tocar no EDA (token por variável de ambiente, nunca na linha de comando):

```bash
read -rs SPLUNK_TOKEN; export SPLUNK_TOKEN
podman run --rm --http-proxy=false -e SPLUNK_TOKEN -v "$PWD/rulebooks":/rulebooks:ro,Z localhost/self-healing:<versão> \
  bash -c 'ansible-rulebook -r /rulebooks/self-healing-slowdisk.yml -i /dev/null -v --vars <(printf "splunk_token: %s\n" "$SPLUNK_TOKEN")'
```

### Push e limpeza

```bash
export REGISTRY_AUTH_FILE=/root/claude/de-aap/self-healing/.auth-build.json
podman login aap.claro.com.br -u admin --password-stdin --tls-verify=false
podman tag localhost/self-healing:<versão> aap.claro.com.br/self-healing:<versão>
podman push aap.claro.com.br/self-healing:<versão> --tls-verify=false
podman search --list-tags --tls-verify=false aap.claro.com.br/self-healing
podman logout --all
rm -f /root/claude/de-aap/self-healing/.auth-build.json
unset REGISTRY_AUTH_FILE
podman rmi aap.claro.com.br/self-healing:<versão> localhost/self-healing:<versão> && rm -rf /root/claude/de-aap/self-healing/context
```

A limpeza só roda depois de a tag aparecer no `podman search`. O `podman logout --all` atua só no arquivo próprio, por causa da variável `REGISTRY_AUTH_FILE`. Não usar `podman image prune` nem `podman system prune`: eles apagam imagens sem tag de outros projetos da bastion. A limpeza remove só as imagens deste projeto.

## Objetos no AAP

Todos na organização `ORG-CLBR-TI-OPS-IT-SERVICE-AUTOMATION` (id 12).

| Objeto | Nome | Detalhe |
|---|---|---|
| Repositório GitLab | `self-healing` | grupo `CLBR-TI-OPS-IT-SERVICE-AUTOMATION` (namespace 71) |
| Collection (Hub) | `org_clbr_ti_ops_it_service_automation.eda_splunk` | repositório `eda-splunk`, mesmo grupo |
| Decision Environment (EDA) | `self-healing` (id 3) | `10.29.6.55/self-healing:1.2` desde 06/10/2026, credencial 2 do registry |
| Project (EDA) | `self-healing` (id 10) | credencial SCM 11 "GitLab Credential AIOps" |
| Tipo de credencial (EDA) | `Splunk Search Token` | genérico, campo `splunk_token` obrigatório e secreto, injector `extra_vars` |
| Credencial (EDA) | `self-healing-splunk` | token da conta `integracao.autom` do Splunk Cloud |
| Activation (EDA) | `self-healing-slowdisk` (id 25) | descrição "Busca alertas SLOW DISK no Splunk e chama os Job Templates self-healing-linux-slowdisk e self-healing-windows-slowdisk", rulebook `self-healing-slowdisk.yml` (id 28), log level `info`, restart policy `on-failure`, credenciais `self-healing-splunk` (45) e `RHAAP Credential` (18); extra vars com a tabela `dc` |
| Credencial (EDA) | `RHAAP Credential` (id 18) | na activation desde 07/10/2026, para o `run_job_template` |
| Project (Controller) | `self-healing` (id 2844) | mesmo repositório, credencial SCM 87 |
| Inventory (Controller) | `self-healing` (id 133) | só o host `localhost` |
| Credencial Machine (Controller) | `self-healing-jumper-campinas` (279), `self-healing-jumper-lapa` (280), `self-healing-jumper-mackenzie` (281) | usuário `root`, chave que já entra no jumper a partir do exec node do datacenter (a chave é diferente em cada exec node) |
| Execution Environment (Controller) | `self-healing` (id 51) | imagem `aap.claro.com.br/self-healing-ee:1.2`, credencial 8 do registry |
| Job Template (Controller) | `self-healing-linux-slowdisk` (id 2846) | Job Template dos alertas de servidores Linux, ver "Teste SLOW DISK" |
| Job Template (Controller) | `self-healing-windows-slowdisk` (id 2847) | Job Template dos alertas de servidores Windows: só e-mail, sem acesso ao servidor |
| Tipo de credencial (Controller) | `Splunk HEC` (id 62) | campos `url` e `token`, injeta `splunk_hec_url` e `splunk_hec_token` nas extra vars |
| Credencial (Controller) | `self-healing-splunk-hec` (id 282) | devolução ao Splunk; token compartilhado temporário até o time Splunk entregar o próprio, ver "Devolução ao Splunk" |

Objetos do modelo antigo, mantidos sem uso para rollback: tipo de credencial `self-healing-webhook-token` (17), credencial `self-healing-webhook-token` (43) e a tag `self-healing:1.0` no Hub.

Deixe o `log_level` da activation em `info`. Em `debug` o ansible-rulebook imprime o rulebook com as variáveis substituídas, o que exporia o token.

Depois de trocar o token na credencial `self-healing-splunk`, reinicie a activation.

### Rollback para o webhook

Desabilitar a activation 25, `PATCH` da DE 3 para `10.29.6.55/self-healing:1.0`, `git revert` do commit do rulebook novo, sync do Project 10, `PATCH` da activation 25 com o rulebook do webhook e a credencial 43, habilitar.

## Riscos conhecidos e aceitos

- O token é da conta `integracao.autom`, compartilhada com o AIOps e com capacidade de escrita no Splunk. O projeto só faz buscas. Antes da fase 2, pedir uma conta de serviço própria só leitura, com acesso apenas ao `itsi_grouped_alerts`.
- A conta tem cota de 8 buscas concorrentes, dividida com o router do AIOps. O plugin faz uma busca por vez, uma por minuto, com duração abaixo de 1 segundo.
- Checkpoint, deduplicação e throttle ficam em memória. Depois de um restart a primeira busca volta 10 minutos e episódios já registrados podem aparecer de novo no log. Parada maior que 10 minutos perde episódios abertos nesse intervalo que não forem atualizados depois. Na fase 2 o playbook mede o disco antes de agir.
- A credencial 18 do EDA ("RHAAP Credential") usa o `svc_aap`, superuser efetivo no AAP. Ela entra na activation com o teste SLOW DISK, porque o `run_job_template` precisa dela para lançar o Job Template.
- No teste SLOW DISK o jumper entra nos servidores como root, com a chave que o root do jumper já tem. O texto do alerta vai para uma linha de comando no jumper; por isso só passam nomes e IPs com letras, números, ponto, hífen e sublinhado.
- Limite de 200 MB de memória por activation no EDA, valor global do nó que vale para todas as activations. A partir da DE 1.2 o heap do Java do Drools fica limitado a 128 MB, para o container não passar do limite. A deduplicação guarda só as chaves de texto das últimas 6 horas.
- A EE `self-healing-ee` a partir da 1.1 usa a política de criptografia `DEFAULT:SHA1`, que aceita assinatura SHA1 em todo SSH feito pelo job, e um `ssh_config` que aceita chave de host `ssh-rsa` só para os jumpers 10.18.48.133 (brux0156, HP-UX) e 10.243.149.38 (zabbix1, RHEL 6.10), que não oferecem algoritmos atuais. Liberado pelo usuário em 06/10/2026 para o teste. Voltar ao padrão quando esses jumpers forem atualizados.
- A devolução ao Splunk usa `validate_certs: false`, igual à devolução dos outros self-healing, porque o HEC 10.88.4.246 usa certificado autoassinado. O token vai sem conferência do certificado do servidor. Quando o HEC tiver certificado emitido pela CA da Claro, colocar a CA na EE e ligar `validate_certs`.
- O token do HEC chega ao job como extra var injetada pela credencial. A task do envio tem `no_log: true` e nenhuma task mostra a variável; não mudar o nível de verbosidade do Job Template para depurar a devolução.

## Troubleshooting

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| Activation falha na subida com `splunk_search: parâmetro obrigatório ausente ou vazio: token` | credencial `self-healing-splunk` não anexada à activation | anexar a credencial e reiniciar |
| Activation falha com erro ao carregar o source `org_clbr_ti_ops_it_service_automation.eda_splunk.splunk_search` | DE sem a collection (imagem errada na DE 3) | conferir o `image_url` da DE 3 e o `ansible-galaxy collection list` da imagem |
| Log com `busca falhou: HTTP 401` e linha `[self-healing][busca][ERROR]` | token inválido ou trocado | conferir o token na credencial e reiniciar a activation |
| Log com `busca falhou: erro de conexão (...)` ou `timeout na busca` | proxy de Lapa fora ou lento, ou Splunk Cloud indisponível | testar `curl -x http://10.29.177.37:8080 https://claro.splunkcloud.com:8089` a partir do nó EDA; o plugin tenta de novo sozinho e registra `[RECOVERED]` quando volta |
| Log com `mensagem de erro do Splunk` | SPL inválida ou cota de buscas da conta esgotada | rodar a mesma SPL no Splunk; ver as buscas concorrentes da conta `integracao.autom` |
| `busca ok` sempre com 0 linhas por dias | o ITSI mudou título, campo ou índice | rodar a SPL no Splunk; acompanhar o contador `eventos` da linha `[self-healing][busca][OK]` |
| Linha `[FORA DO FILTRO]` | a SPL trouxe um título que não começa com SLOW DISK | revisar a SPL |
| Linha `[busca][WINDOW_TRUNCATED]` | activation parada ou com falha por mais de 30 minutos | a mensagem traz o intervalo perdido em epoch; buscar à mão no Splunk se precisar |
| Linha `[busca][TRUNCATED]` | mais de 1000 episódios numa busca | aumentar `max_results` |
| Episódio aparece no Splunk e não no log | throttle de 30 minutos para o mesmo host e disco, ou episódio fechado na mesma janela | conferir o Rule Audit do EDA |
| SLOW DISK Linux com linha `[SLOW DISK][processo][sem diskPath]` ou `[SLOW DISK][hypervisor][sem diskPath]` no log e nenhum job | alerta de processo ou de hypervisor sem `diskPath` | esperado: só registro no log |
| Linha `[self-healing][processo][SLOW DISK]` no log e nenhum job no Controller | activation sem a credencial 18, ou sem a entrada `PADRAO` na tabela `dc` das extra vars | conferir as credenciais e as extra vars da activation 25 e o erro logo abaixo da linha no log |
| Linha `[self-healing][windows][SLOW DISK]` no log e nenhum job no Controller | activation sem a credencial 18, sem a entrada `PADRAO` na tabela `dc` ou Job Template `self-healing-windows-slowdisk` renomeado | conferir as credenciais e as extra vars da activation 25, o nome do Job Template e o erro logo abaixo da linha no log |
| E-mail de Windows com frase de falha ou de localidade não mapeada | job rodou com o código anterior à situação `windows` (Project 2844 sem sync) | sincronizar o Project 2844 e conferir o commit usado pelo job |
| E-mail de processo com "Servidor" e frase de falha ou de localidade não mapeada | job rodou com o código anterior à situação `processo` (Project 2844 sem sync) | sincronizar o Project 2844 e conferir o commit usado pelo job |
| Project não sincroniza no EDA | credencial SCM sem acesso ao grupo | conferir a URL do repositório e a credencial 11 |
| Build da DE falha ao baixar a collection | usuário e senha do Hub não passados como variáveis de build | exportar as variáveis `ANSIBLE_GALAXY_SERVER_HUB_PUBLICADO_*` e passar `--build-arg` sem valor |
| Build da DE falha ao puxar a base | sem login no `registry.redhat.io` | fazer o login com a conta Red Hat e o logout depois |
| Linha `[self-healing][linux][SLOW DISK]` no log e nenhum job no Controller | activation sem a credencial 18, sem a tabela `dc` nas extra vars ou Job Template `self-healing-linux-slowdisk` renomeado | conferir as credenciais e as extra vars da activation 25, o nome do Job Template e o erro logo abaixo da linha no log |
| Job do SLOW DISK rodou no instance group errado ou sem credencial | Job Template sem `ask_instance_groups_on_launch` ou `ask_credential_on_launch` | ligar os dois no Job Template; conferir `ignored_fields` num lançamento de teste |
| E-mail com "o jumper não respondeu" | credencial errada para o datacenter, chave trocada no jumper ou job fora do exec node do datacenter | conferir a tabela `dc`, a credencial e o execution node do job |
| E-mail com "falha no ssh (Permission denied ...)" em todos os endereços | o root do jumper não tem chave aceita no servidor do alerta | só registrar; o teste não muda nada no servidor nem no jumper |
| E-mail com "falha no ssh (Could not resolve hostname ...)" seguido de acesso OK pelo IP | o jumper não resolve o nome do servidor | nada a fazer; por isso o IP é tentado depois do nome |
| E-mail com "O df passou de 30 segundos e foi interrompido" | montagem travada ou muito lenta no servidor, provável causa do alerta | avaliar com a equipe solucionadora |
| E-mail "a localidade ... não está mapeada" | alerta de localidade sem jumper (OCI, por exemplo) | esperado; para incluir, acrescentar o datacenter nas duas tabelas |
| Job com "Devolução ao Splunk não enviada" | credencial `self-healing-splunk-hec` fora da lista `credentials` da tabela `dc`, ou ainda com o token fictício | esperado nos jobs de Lapa e Mackenzie até a liberação de firewall; em Campinas ou na entrada `PADRAO`, conferir a tabela `dc` da activation e o token da credencial 282, ver "Devolução ao Splunk" |
| Job com "Devolução ao Splunk: HTTP -1" | o execution node do job não alcança o 10.88.4.246:8088 (firewall de Lapa e Mackenzie) ou o HEC está fora | testar `curl -sk --noproxy '*' https://10.88.4.246:8088/services/collector/health` a partir do execution node do job |
| Job com "Devolução ao Splunk: HTTP 401" ou "HTTP 403" | token errado, desabilitado ou sem permissão no index | conferir o token da credencial com o time Splunk |
| Job com "Devolução ao Splunk: HTTP 400" | corpo recusado pelo HEC | conferir o evento na task "Evento da devolução ao Splunk" e o endpoint `/services/collector/raw` na credencial |
| Evento chega ao Splunk e o episódio não é contabilizado | `episode_id` diferente do episódio no ITSI ou campo renomeado | comparar o `episode_id` do evento com o `episodeId` do alerta; os nomes dos campos não podem mudar |
| Job termina com falha "O e-mail não foi enviado" | SMTP fora ou bloqueado a partir do execution node | a devolução já foi feita antes da falha; testar a porta 25 do `vip_smtp.claro.com.br` a partir do execution node |
| E-mail de um alerta real chega só para `leonardo.costa.terceiros@claro.com.br` | envio aos times desligado (`notificacao_enviar_aos_times: false`) ou Project 2844 sem o sync da revisão que ligou | conferir o valor em `roles/notificacao/defaults/main.yml` (ligado desde 08/10/2026), o sync do Project 2844 e o `scm_revision` do job |
| E-mail chega ao time antes da hora, ou um teste manual chega ao time | `notificacao_enviar_aos_times: true` no repositório, ou teste lançado sem `notificacao_destinatarios_teste` | conferir a task "Destinatários do e-mail" do job; em teste manual, passar sempre `notificacao_destinatarios_teste` |
| Log com "Sistema operacional do alerta (...) não é LINUX nem WINDOWS" | `entityOS` diferente de `LINUX` e de `WINDOWS` | com o envio aos times ligado, o e-mail vai só para os dois endereços da cópia; incluir o sistema novo em `notificacao_destinatarios_por_tipo` e na role `alvo` se ele passar a ser comum |
| Job com play do jumper rodando, "o jumper não respondeu" ou frases "O Self-healing recebeu este alerta..." em servidor Linux | `acessar_servidor` igual a `true` no repositório ou na extra var do lançamento, ou job rodou com o código anterior a 08/10/2026 (Project 2844 sem sync) | conferir `group_vars/all.yml`, as extra vars do job e o commit usado pelo job |
| Job parado no início de um play até terminar com "Job terminated due to timeout", sem e-mail e sem devolução; no log, `Exception in thread Thread-2 (results_thread_main)` e `KeyError: ('localhost', '...')` em `_queued_task_cache` | bug de corrida do ansible-core 2.19.0 a 2.19.3 ([issue 85879](https://github.com/ansible/ansible/issues/85879)), que existia na EE `1.1`: o resultado da última task de um play chega de novo no play seguinte, que não reconhece a task e fica esperando para sempre. Aparecia em cerca de 5% dos jobs, quase sempre com vários jobs começando no mesmo segundo no mesmo execution node; não depende do código do repositório | corrigido na EE `1.2` (ansible-core 2.19.14), vigente desde 08/10/2026. Se voltar a acontecer, conferir se a EE 51 está mesmo na `1.2`; o job termina sozinho no timeout de 300 s e o episódio volta a gerar job no próximo lembrete do rulebook se continuar aberto (ver "Execution Environment do Job Template") |
| Job real com "Devolução ao Splunk não enviada: desligada pela variável devolucao_ativa (false)" | `devolucao_ativa: false` no repositório | voltar para `true` em `roles/devolucao/defaults/main.yml`; o `false` é só para extra var de teste |
