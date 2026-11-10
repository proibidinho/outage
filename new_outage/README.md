# 🚨 Auto Outage GMUD – Observabilidade

Automação (Ansible / AAP) que cria **Maintenance Windows no Dynatrace** e **Maintenances no Zabbix** a partir de GMUDs que têm uma atividade atribuída ao time de Observabilidade, e envia um **relatório por e-mail** (corpo em HTML + planilha Excel em anexo).

---

## 📑 Sumário

1. [Visão geral](#-visão-geral)
2. [Fluxo](#-fluxo)
3. [Como funciona, passo a passo](#-como-funciona-passo-a-passo)
4. [Estrutura do projeto](#-estrutura-do-projeto)
5. [Execução no AAP (Surveys)](#-execução-no-aap-surveys)
6. [Modos de execução e segurança](#-modos-de-execução-e-segurança)
7. [Variáveis](#-variáveis)
8. [Relatório por e-mail](#-relatório-por-e-mail)
9. [Roteiro de testes](#-roteiro-de-testes)
10. [Habilitando o Zabbix](#-habilitando-o-zabbix)
11. [Problemas comuns](#-problemas-comuns)
12. [Pontos de atenção conhecidos](#-pontos-de-atenção-conhecidos)
13. [Requisitos](#-requisitos)
14. [Histórico de alterações](#-histórico-de-alterações)

---

## 🧭 Visão geral

Para cada GMUD elegível, a automação:

- ✅ descobre a GMUD pai e a **janela de downtime** (início e fim);
- ✅ lê os **ativos** vinculados na CMDB (Jira Assets);
- ✅ localiza **HOSTs** e **SERVICEs** no Dynatrace;
- ✅ cria **uma única Maintenance Window** no Dynatrace por GMUD;
- ✅ (opcional) cria a **Maintenance** correspondente no Zabbix;
- ✅ gera uma **planilha Excel** com todos os ativos processados;
- ✅ envia um **e-mail HTML** com o resultado por GMUD e a planilha anexa.

---

## 🔄 Fluxo

```text
Jira (atividades de Observabilidade)
        │
        ▼
 role descoberta ──► GMUD pai + janela de downtime + ativos (IDs da CMDB)
        │
        ▼
 role outage
   ├─ CMDB: expande sistemas em servidores
   ├─ Dynatrace: busca HOSTs e SERVICEs → cria/valida Maintenance Window
   └─ Zabbix (se habilitado): busca hosts → cria/valida Maintenance
        │
        ▼
 role relatorios ──► planilha Excel + e-mail HTML
```

Ordem das roles no `playbook.yml`: `inventory` → `descoberta` → `outage` → `relatorios`.

---

## 📋 Como funciona, passo a passo

### 1. Descoberta das GMUDs (`roles/descoberta`)

1. Consulta o Jira (`/rest/api/3/search/jql`) por atividades do projeto `projeto_jira` nos status **"Pronto para Implementação"** ou **"Atividade em execução"**.
2. Mantém só as atividades cujo executante (`customfield_14998`) é igual a `executante_alvo` (ex.: `OBSERVABILIDADE(APR)`).
3. Descobre a **GMUD pai** de cada atividade pelo vínculo (`issuelinks` → `inwardIssue`).
4. **Survey `gml` (opcional):** se informada, restringe o processamento a essa GML, desde que ela esteja entre as elegíveis. Se não estiver, o log explica e nada é processado.
5. Lê a **janela de downtime** (início/fim), conforme `jira_janela_origem` (veja abaixo).
6. Consulta os dados completos da GMUD (resumo e ativos da CMDB em `customfield_14007`).
7. Valida: início, fim e ativos precisam existir. **Se uma GMUD não tiver, o job para** (veja [Pontos de atenção](#-pontos-de-atenção-conhecidos)).

#### De onde vem a janela de downtime

Controlado por `jira_janela_origem` (padrão em `roles/descoberta/defaults/main.yml`):

| Valor | Origem da janela |
|---|---|
| `atividade` (padrão) | Campos de início/fim da **atividade de Observabilidade** |
| `gml_pai` | Campos de início/fim da **própria GMUD** (comportamento antigo) |

Em ambos os modos os campos usados são os de `jira_inicio_field` e `jira_fim_field`. Quem decide o que eles apontam é o `group_vars/all.yml`.

**Configuração atual (origem = atividade):**

```yaml
jira_inicio_field: customfield_10044
jira_fim_field:    customfield_10045
```

**Para voltar a ler da GML pai**, altere somente o `group_vars/all.yml` (sem mexer em código):

```yaml
jira_janela_origem: gml_pai
jira_inicio_field: customfield_14318
jira_fim_field:    customfield_14319
```

Se uma GMUD tiver **mais de uma** atividade de Observabilidade, vale a primeira (menor chave) que tenha início **e** fim preenchidos, e o log avisa de qual atividade a janela foi lida. Se a atividade vier sem datas, o job falha com mensagem clara. **Não há reserva automática para a GMUD pai**, de propósito, para nunca usar um horário errado sem ninguém ver.

### 2. Expansão da CMDB (`roles/outage/tasks/busca_ativos_no_cmdb.yml`)

Cada ID em `customfield_14007` é consultado no Jira Assets (`{{ jira_url }}/object/<id>`):

| Tipo do objeto | Resultado |
|---|---|
| **Sistema** (tem o atributo `Servidor`) | Os servidores vinculados viram os "ativos" (HOSTs) |
| **Servidor** (não tem o atributo) | O próprio nome do objeto é o ativo |

O **nome do objeto** (sistema ou servidor) também é guardado em `nome_cmdb` e usado para buscar SERVICEs no Dynatrace.

### 3. Dynatrace (`criar_outage.yml`)

- **HOSTs:** para cada servidor, busca `type(HOST)` com `entityName.contains("<nome>")`.
- **SERVICEs:** para cada nome do CMDB, busca `type(SERVICE)` com `entityName.contains("<nome>")`.
- Se **nenhuma** entidade for encontrada, a GMUD é marcada como **ignorada** no Dynatrace.
- Caso contrário, cria **uma** Maintenance Window `GMUD <chave>` via Settings API (`builtin:alerting.maintenance-window`):
  tipo `PLANNED`, supressão `DETECT_PROBLEMS_AND_ALERT`, agendamento `ONCE`, fuso `dynatrace_timezone`, com todas as entidades como filtros.
- `dynatrace_validate_only: true` envia o payload com `validateOnly=true` (valida sem criar).

### 4. Zabbix (`criar_outage_zabbix.yml`), só se `zabbix_habilitado: true`

- Converte a janela para o formato do Zabbix (`YYYY-MM-DD HH:MM`) e calcula a duração em minutos.
- Procura cada ativo no Zabbix por nome técnico exato, em MAIÚSCULAS e minúsculas.
- **Regra "todos ou nenhum":** só cria a maintenance se **todos** os ativos forem encontrados. Se faltar algum, a GMUD é ignorada no Zabbix e o log/e-mail listam os que faltaram.
- Cria/atualiza a maintenance `GMUD <chave>` (`state: present`, idempotente pelo nome).
- `zabbix_validate_only: true` só valida (não cria).

> O Dynatrace **sempre** roda; o Zabbix é opcional. Cada plataforma decide por conta própria se a GMUD é válida nela.

---

## 🗂️ Estrutura do projeto

```text
new_outage/
├── playbook.yml                       # play principal, vars de modo e Survey gml
├── group_vars/all.yml                 # variáveis e segredos (Ansible Vault)
└── roles/
    ├── inventory/                     # registra o host virtual da API do Zabbix
    │   └── tasks/main.yml
    ├── descoberta/                    # Jira: atividades, GMUD pai, janela, ativos
    │   ├── defaults/main.yml          # jira_janela_origem
    │   └── tasks/main.yml
    ├── outage/                        # CMDB + Dynatrace + Zabbix
    │   ├── defaults/main.yml          # defaults do Zabbix (baixa precedência)
    │   ├── vars/main.yml              # GMUD fictícia para testes (comentada)
    │   └── tasks/
    │       ├── main.yml
    │       ├── busca_ativos_no_cmdb.yml
    │       ├── criar_outage.yml
    │       └── criar_outage_zabbix.yml
    └── relatorios/                    # planilha Excel + e-mail HTML
        ├── defaults/main.yml          # SMTP, remetente, destinatário, cor, etc.
        ├── tasks/main.yml
        └── templates/corpo_email.html.j2
```

---

## 🖥️ Execução no AAP (Surveys)

Campos de Survey usados (todos opcionais):

| Variável | Para quê |
|---|---|
| `gml` | Processa **somente** essa GML pai (ex.: `GML-171661`). Vazio = todas as elegíveis. O formato é validado no início do job. |
| `email_destino` (ou `email`) | Destinatário do relatório. Sem nenhum dos dois, usa o endereço padrão de `roles/relatorios/defaults/main.yml`. |

Variáveis extras (Survey) **sobrescrevem** as do playbook. Por isso é possível criar surveys também para `dynatrace_validate_only`, `zabbix_habilitado` e `zabbix_validate_only`, e alternar os modos sem editar código.

---

## 🛡️ Modos de execução e segurança

| Variável | Padrão | Efeito |
|---|---|---|
| `dynatrace_validate_only` | `true` (playbook) | `true`: valida o payload, **não cria** a janela. `false`: **cria de verdade**. |
| `zabbix_habilitado` | `false` (playbook) | `false`: pula o Zabbix. `true`: executa as tasks do Zabbix. |
| `zabbix_validate_only` | acompanha o Dynatrace | `true`: não cria a maintenance. `false`: **cria de verdade**. |

O e-mail mostra o modo de cada plataforma e o assunto leva o sufixo **(VALIDAÇÃO)** quando o Dynatrace está em teste.

---

## 🔧 Variáveis

Definidas em `group_vars/all.yml` (cofre) e/ou no AAP:

| Grupo | Variáveis |
|---|---|
| Jira | `jira_base_url` (API REST), `jira_url` (Assets), `jira_user`, `jira_password`, `projeto_jira`, `executante_alvo` |
| Janela | `jira_inicio_field`, `jira_fim_field`, `jira_janela_origem` |
| Rede | `proxy_env` |
| Dynatrace | `dynatrace_url`, `dynatrace_token`, `dynatrace_timezone` |
| Zabbix | `zabbix_host`, `zabbix_api_token`, `zabbix_port`, `zabbix_use_ssl`, `zabbix_validate_certs`, `zabbix_url_path`, `zabbix_inventory_host` |
| Zabbix (opcionais) | `zabbix_validate_only`, `zabbix_usar_visible_name`, `zabbix_collect_data` |

Campos do Jira usados: `customfield_14998` (executante da atividade), `customfield_14007` (ativos da CMDB) e os campos de janela (`jira_inicio_field` / `jira_fim_field`).

**Defaults de baixa precedência** (o cofre/Survey/playbook sempre vencem):

- `roles/outage/defaults/main.yml`: `zabbix_validate_only` (acompanha o Dynatrace) e `zabbix_usar_visible_name: false`. Os hosts vêm do nome **técnico** do Zabbix; o módulo, por padrão, procuraria pelo nome **visível**.
- `roles/descoberta/defaults/main.yml`: `jira_janela_origem: atividade`.
- `roles/relatorios/defaults/main.yml`: SMTP, remetente, destinatário padrão, assunto, título, cor, link do Jira, limite de servidores listados e se envia e-mail sem GMUD.

---

## 📧 Relatório por e-mail

### Corpo HTML

- Cabeçalho com o **modo** de cada plataforma e a data.
- **Resumo:** nº de GMUDs, Dynatrace OK, Zabbix OK e GMUDs com pendência.
- **Aviso de atenção** quando alguma GMUD ficou sem janela/maintenance por ativos não localizados.
- **Um bloco por GMUD:** link para o Jira, resumo, janela (início → fim e duração), atividade de onde a janela foi lida, sistemas, servidores (os primeiros N; o restante vai na planilha) e o resultado por plataforma.
- Todo texto vindo do Jira/CMDB é escapado; layout em tabelas com CSS inline, adaptável a celular.

**Status por plataforma:**

| Plataforma | Status | Significado |
|---|---|---|
| Dynatrace | `CRIADA` | Maintenance Window criada |
| Dynatrace | `VALIDADO` | Modo teste: payload validado, nada criado |
| Dynatrace | `IGNORADA` | Nenhum HOST/SERVICE encontrado |
| Zabbix | `APLICADA` | Maintenance criada ou atualizada |
| Zabbix | `SEM_ALTERACAO` | Maintenance já existia idêntica |
| Zabbix | `VALIDADO` | Modo teste: nada criado |
| Zabbix | `IGNORADA` | Algum ativo não existe no Zabbix |
| Zabbix | `DESABILITADO` | `zabbix_habilitado: false` |

### Planilha Excel (anexo)

Arquivo `/tmp/outages_gml.xlsx`, aba **Outages**:

| Coluna | Conteúdo |
|---|---|
| A | GML |
| B | ATIVO |
| C | TIPO (`HOST` ou `SERVICE`) |
| D | INICIO |
| E | FIM |

As linhas `HOST` vêm dos servidores da CMDB; as linhas `SERVICE`, das entidades `SERVICE-…` encontradas no Dynatrace. Uma GMUD com vários ativos gera uma linha por ativo.

### Envio

- Assunto: `Relatorio Outages GMUD - <data>` (+ ` (VALIDAÇÃO)` em modo teste).
- Destinatário: `email_destino` → `email` → padrão de `roles/relatorios/defaults/main.yml`.
- `relatorio_enviar_sem_gmud: true` mantém o envio mesmo sem GMUD; `false` só envia quando houver GMUD processada.

---

## 🧪 Roteiro de testes

1. **Validação, uma GML.** Rode com a Survey `gml` preenchida, `dynatrace_validate_only: true` e `zabbix_habilitado: false`. Confira no log:
   - a task **"Mostrar resultado da descoberta"**: `inicio` e `fim` devem estar no formato `2026-11-12T14:00:00.000-0300`;
   - a janela e a atividade de origem no e-mail.
2. **Validação com Zabbix.** Habilite `zabbix_habilitado: true` mantendo `zabbix_validate_only: true`. Confira hosts encontrados/faltantes.
3. **Aplicação real em uma GML.** Só depois, com `dynatrace_validate_only: false` (e `zabbix_validate_only: false`), em **uma** GML. Confira no Dynatrace e no Zabbix:
   - os horários da janela;
   - as entidades/hosts incluídos.
4. Só então rode sem a Survey (todas as GMUDs elegíveis).

**Teste sem GMUD real (técnica herdada do README anterior):** defina `gmuds` em `roles/outage/vars/main.yml` e comente a role `descoberta` no playbook. Exemplo:

```yaml
gmuds:
  - chave: "GML-TESTE"
    resumo: "Teste Dynatrace"
    inicio: "2026-09-18T18:08:00.000-0300"
    fim: "2026-09-18T19:10:00.000-0300"
    ativos:
      - "901269"   # ID de objeto da CMDB
```

> Revalide essa técnica antes de depender dela: ela não foi retestada após as mudanças de 10/11/2026.

---

## 🟢 Habilitando o Zabbix

Checklist antes de criar maintenances reais:

1. `zabbix_host`, `zabbix_api_token` e demais variáveis do Zabbix definidas no cofre.
2. `zabbix_habilitado: true` e `zabbix_validate_only: true`; rode e confira o resultado no e-mail.
3. Verifique a versão da collection `community.zabbix` (`ansible-galaxy collection list community.zabbix`). O parâmetro `minutes` do módulo `zabbix_maintenance` está **deprecated** (remoção prevista na 4.0.0); se a versão for 4.0 ou superior, a task precisa migrar para `time_periods`.
4. Na primeira criação real, confira na tela de Maintenance do Zabbix se o **horário** bate com o da GMUD (o módulo não documenta o tratamento de fuso).
5. Se houver timeout só na criação da maintenance, revise o `environment: proxy_env` dessa task.

---

## 🚨 Problemas comuns

| Sintoma | Verificar |
|---|---|
| Nenhuma GMUD encontrada | Status da atividade (precisa estar em "Pronto para Implementação" ou "Atividade em execução") e se o executante é `executante_alvo` |
| Survey `gml` não processa nada | O log informa as GMLs elegíveis; confira a chave, o status e o vínculo da atividade com a GML |
| `A GML informada ... não tem o formato esperado` | Digite no formato `GML-123456`, sem espaços |
| `A GMUD X não possui todos os dados necessários` | Atividade sem início/fim, ou GMUD sem ativos (`customfield_14007`); confira `jira_inicio_field`/`jira_fim_field` |
| Horário diferente do esperado | Veja o texto bruto de `inicio`/`fim` no log e confira o campo no Jira (API: `.../rest/api/3/issue/GML-xxx?expand=names&fields=<campo>`); o dono pode ter preenchido o campo diferente do texto da descrição |
| `jira_janela_origem ... é inválido` | Use `atividade` ou `gml_pai` |
| Nenhum HOST/SERVICE no Dynatrace (`IGNORADA`) | Nome do servidor/sistema na CMDB vs. nome da entidade no Dynatrace |
| Janela não criada | `dynatrace_validate_only` está `true`? |
| Maintenance não criada no Zabbix | `zabbix_habilitado`, `zabbix_validate_only`, e se **todos** os hosts existem no Zabbix (o e-mail lista os faltantes) |
| E-mail sem anexo | Caminho da planilha (`/tmp/outages_gml.xlsx`) e etapa "Criar planilha" |

---

## ⚠️ Pontos de atenção conhecidos

- **Busca por `contains` no Dynatrace.** `entityName.contains("SRV1")` também casa `SRV10`, `SRV100`…, podendo incluir entidades além das desejadas. Revise a lista de entidades na primeira execução de cada sistema novo.
- **Sem checagem de duplicidade no Dynatrace.** Cada execução em modo real cria uma nova janela, mesmo que já exista uma `GMUD <chave>`. Reexecutar a mesma GMUD gera janelas repetidas (e uma janela criada com horário errado precisa ser removida/ajustada manualmente). No Zabbix isso não ocorre (`state: present` pelo nome).
- **Uma GMUD sem dados para o job inteiro.** A validação de início/fim/ativos usa `assert` em loop; uma GMUD incompleta interrompe o processamento das demais. Use a Survey `gml` para isolar.
- **Zabbix: todos ou nenhum.** Basta um host faltar para a GMUD ficar sem maintenance no Zabbix.
- **Fuso horário.** O Dynatrace trata literalmente o sufixo `-0300` (`.000-0300`) e o Zabbix usa a hora do relógio do texto, sem converter. Valores com outro deslocamento podem ser rejeitados ou gerar horário errado.
- **Fonte de verdade da janela.** A automação lê apenas os campos estruturados do Jira, nunca o texto da descrição. Divergências entre os dois devem ser corrigidas por quem preencheu o chamado, antes da janela começar.
- **A automação não fecha chamados.**

---

## 📦 Requisitos

- **AAP / Ansible** com as collections: `community.general` (envio de e-mail), `community.zabbix` (módulos e conexão `httpapi`) e `ans2dev.general` (geração do Excel).
- **Jira:** usuário com leitura de issues e do Assets.
- **Dynatrace:** token com permissão de leitura de entidades e de leitura/escrita de Settings.
- **Zabbix:** token com permissão de leitura de hosts e criação de maintenance.
- **Rede:** acesso ao SMTP interno, ao Jira, ao Dynatrace e ao Zabbix (via `proxy_env`, quando aplicável).

---

## 🕓 Histórico de alterações

**2026-11-10**

- E-mail em **HTML** com resultado por GMUD (Dynatrace e Zabbix), mantendo a planilha anexa; parâmetros do relatório em `roles/relatorios/defaults/main.yml`.
- **Survey `gml`** para processar uma GML pai individual.
- **Janela de downtime** passou a ser lida da **atividade de Observabilidade** (campos 10044/10045), com chave `jira_janela_origem` para voltar à GML pai.
- **Zabbix:** defaults seguros (`zabbix_validate_only`, `zabbix_usar_visible_name: false`), lista dos hosts não encontrados, resultado no relatório.
