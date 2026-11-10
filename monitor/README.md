# Automação de alertas de certificado — Jira → Zabbix

Playbook Ansible (executado no AAP) que lê chamados do Jira e, conforme o tipo
do chamado, **atualiza**, **cria** ou **remove** a monitoração de certificados
no Zabbix. No fim envia um relatório HTML por e-mail.

Cada certificado é um item do host `CERTIFICADOS_CLARO_BRASIL` cuja key tem
o formato:

```
zbx_valida_data_certificado["<host>","<Tipo>","DD/MM/AAAA"]
```

Exemplo: `zbx_valida_data_certificado["netsmsmfa.claro.com.br","Externo","30/03/2027"]`

---

## 1. O que a automação faz

| Resumo (summary) do chamado | Operação | O que acontece no Zabbix |
|---|---|---|
| `Atualização de Alerta de Certificado - Zabbix` | ATUALIZAÇÃO | Troca a data dentro da key do item e acrescenta `Chamado Jira: <ticket>` na description |
| `Criação de Alerta de Certificado - Zabbix` | CRIAÇÃO | Cria o item (copiando atributos de um item-modelo) e as triggers de expiração e pré-expiração |
| `Remoção de Alerta de Certificado - Zabbix` | REMOÇÃO | Desabilita o item. **Opcional:** trata as triggers (ver seção 5) |

Pontos importantes:

- **Simulação por padrão.** Nada é gravado no Zabbix a menos que
  `aplicar_alteracoes: true`. O e-mail é enviado nos dois modos.
- **A automação não fecha o chamado no Jira.** O e-mail lembra disso.
- **Nunca "adivinha".** Se não encontra uma correspondência exata (ignorando
  maiúsculas/minúsculas) o certificado fica `NAO_ENCONTRADO` e nada é alterado.
- **Remoção não exige data** no chamado. Atualização e criação exigem.

---

## 2. Estrutura do projeto

```
monitor/
├── playbook.yml
└── roles/
    ├── inventory/    # cria o host virtual usado pelo módulo community.zabbix
    ├── descoberta/   # busca chamados no Jira e extrai os certificados
    ├── atualiza/     # altera a validade de itens existentes
    ├── remove/       # desabilita o item (e, opcionalmente, trata as triggers)
    ├── cria/         # cria item novo + triggers
    │   └── vars/main.yml   # atributos copiados do item-modelo
    └── relatorios/   # monta o HTML e envia o e-mail
        └── templates/corpo_email.html.j2
```

Ordem de execução das roles: `inventory` → `descoberta` → `atualiza` →
`remove` → `cria` → `relatorios`. As roles `atualiza`, `remove` e `cria` só
rodam se houver certificados daquele tipo.

---

## 3. Como executar (Survey / extra vars)

| Variável | Obrigatória | Padrão | Descrição |
|---|---|---|---|
| `email` | **Sim** | — | Destinatário do relatório. O playbook falha antes de qualquer alteração se faltar |
| `aplicar_alteracoes` | Não | `false` | `true` grava no Zabbix. `false` é simulação |
| `chamado` | Não | vazio | Ex.: `PDST-123456`. Processa **somente** esse chamado. Vazio = todos os chamados abertos |
| `tratar_triggers` | Não | `false` | `true` faz a remoção também tratar as triggers (seção 5) |

**Fluxo recomendado:** rodar primeiro em simulação (sem `aplicar_alteracoes`),
conferir o e-mail e só então rodar com `aplicar_alteracoes: true`.

### Variáveis externas necessárias

Definidas fora deste projeto (credenciais/inventário/extra vars do AAP). Confira
os nomes no seu ambiente:

- Jira: `jira_base_url`, `jira_user`, `jira_password`, `projeto_jira`, `proxy_env`
- Zabbix: `zabbix_host`, `zabbix_port`, `zabbix_use_ssl`, `zabbix_url_path`,
  `zabbix_api_token`, `zabbix_validate_certs`, `zabbix_habilitado`,
  `zabbix_inventory_host`

Variáveis fixas no `playbook.yml`: `zabbix_host_certificados`
(`CERTIFICADOS_CLARO_BRASIL`), `zabbix_chave_certificado`, `zabbix_chave_regex`,
`zabbix_data_regex`, e os três resumos de chamado (`jira_resumo_*`).

---

## 4. Formato esperado dos chamados

O resumo do chamado precisa **conter** o texto configurado em `jira_resumo_*`.
A comparação ignora maiúsculas, espaços repetidos e o tipo de hífen.

A descrição aceita dois esquemas. Um chamado usa um ou outro.

**Esquema A (atualização, criação ou remoção):** parágrafos com o tipo
(`Externo`/`Interno`), a data `DD/MM/AAAA` e uma lista com marcadores com os
hosts.

**Esquema B (principalmente criação e remoção):** blocos "rótulo: valor",
um por certificado:

```
Nome completo do certificado: clarocustodioa.claro.com.br
Tipo de certificado: Interno
Data de renovação: 06/10/2027
```

As linhas podem vir como parágrafos separados ou como um parágrafo com quebras
de linha. Um chamado pode ter vários blocos. Em chamados de **remoção** a linha
"Data de renovação" pode faltar.

Regras de normalização:

- `*.dominio.com` no chamado vira `star.dominio.com` ao procurar o item;
- o **tipo** aceita `Externo`, `Interno` e `Internos`, em qualquer caixa;
- o **host** é comparado ignorando maiúsculas/minúsculas, mas precisa ser
  idêntico no restante (um espaço ou `.com` x `.com.br` já não casa).

---

## 5. Remoção e triggers

### Comportamento padrão (`tratar_triggers` desligado)

A remoção **só desabilita o item** (`status: 1`). As triggers continuam ativas
e precisam ser removidas manualmente pelo time de Zabbix. O e-mail traz um aviso
em destaque quando há remoções.

### Com `tratar_triggers: true`

Depois de desabilitar o item, a role busca as triggers que usam esse item pela
API (`trigger.get` por `itemid`, não por nome) e decide:

| Trigger | Ação | Status |
|---|---|---|
| Nome idêntico ao criado pela automação: `Certificado <Tipo> <host> expirado` ou `... próximo de expirar` (sem diferenciar caixa) | **Exclui** | `EXCLUIDA` |
| Qualquer outro nome (criada à mão) | **Desabilita** (reversível) | `DESABILITADA` |
| Nome fora do padrão e já desabilitada | Nada | `JA_DESABILITADA` |
| Usa **outros itens**, é herdada de template ou vem de descoberta | **Não altera** | `NAO_ALTERADA` (tratar manualmente) |
| O item não tem triggers | Nada | `NENHUMA` |
| Falha na consulta ou na alteração | Nada | `ERRO` |

Observações:

- A consulta é somente leitura e roda **também na simulação**, então o e-mail
  mostra o que seria feito.
- São tratadas também as triggers de itens que já estavam desabilitados
  (`JA_REMOVIDO`), por exemplo de remoções anteriores.
- Item com `ERRO`, `NAO_ENCONTRADO` ou `AMBIGUO` não tem as triggers tocadas.
- O Zabbix **não fecha problemas já abertos** de uma trigger desabilitada.
  Triggers excluídas não deixam esse problema.
- O token da API precisa de permissão para excluir e alterar triggers no host
  `CERTIFICADOS_CLARO_BRASIL`.
- Trigger criada pela automação cujo nome foi editado depois conta como "nome
  diferente" e só é desabilitada.

Para trocar os textos das mensagens, veja `roles/remove/tasks/main.yml`
(task "Planejar o tratamento das triggers" e task "Consolidar resultado das
triggers") e a nota amarela em `corpo_email.html.j2`. Não altere os nomes dos
status, pois o e-mail e o job dependem deles.

---

## 6. Criação (itens e triggers)

- O item novo é montado a partir de um **item-modelo Enabled do mesmo tipo**
  (Externo/Interno) já existente no host: a key e o nome do modelo, trocando
  host e data. Os demais atributos listados em `roles/cria/vars/main.yml`
  (`cria_campos_modelo`) são copiados do modelo.
- A `description` do item novo é **somente** `Chamado Jira: <ticket>` (não herda
  a do modelo).
- Se já existe item para host + tipo: `JA_EXISTE`, nada é criado. Para mudar a
  data, use um chamado de atualização.
- Para cada item criado, duas triggers (módulo `community.zabbix.zabbix_trigger`,
  via host virtual da role `inventory`):
  - **Expiração:** `Certificado <Tipo> <host> expirado`, severidade *high*,
    dispara quando o último valor contém `expirado`;
  - **Pré-expiração:** `Certificado <Tipo> <host> próximo de expirar`,
    severidade *average*, dispara quando o último valor contém `irá expirar em`.
  - Ambas têm recuperação quando o valor contém `OK`, fechamento manual,
    e tags `impacto=SERVICO` e `solucionador={$SOLUCIONADOR_GA_CERTIFICADOS}`.
- Se o item for criado mas uma trigger falhar, o status é `ERRO` e a mensagem
  indica o `itemid` e qual trigger falhou. **Crie a trigger manualmente**, pois
  uma nova execução veria `JA_EXISTE`.

> A trigger de pré-expiração depende do texto que o item devolve no valor
> (`irá expirar em`). Se o script do item mudar esse texto, ajuste a expressão
> em `roles/cria/tasks/main.yml`.

---

## 7. Atualização

- Procura o item por host + tipo (ignorando caixa) e troca somente a data dentro
  da key.
- Na `description`, **acrescenta** em nova linha `Chamado Jira: <ticket>`,
  preservando o texto existente. Se o chamado já consta, não duplica.
- Com mais de um item para host + tipo, só age se exatamente um estiver Enabled.

---

## 8. Status possíveis

| Status | Significado |
|---|---|
| `ATUALIZADO` / `CRIADO` / `REMOVIDO` | A API confirmou a operação |
| `SIMULADO` | `aplicar_alteracoes=false`: nada foi gravado |
| `JA_ATUALIZADO` | O item já está com a validade pedida |
| `JA_EXISTE` | Criação: já há item para host + tipo |
| `JA_REMOVIDO` | Remoção: o item já estava desabilitado |
| `NAO_ENCONTRADO` | Nenhum item para host + tipo |
| `AMBIGUO` | Mais de um item e não há exatamente um Enabled |
| `CONFLITO` | Chamados pedem validades diferentes para o mesmo certificado |
| `TIPO_INVALIDO` | Descrição sem Externo/Interno |
| `SEM_MODELO` | Criação: não há item-modelo Enabled do mesmo tipo |
| `ERRO` | A API retornou erro ou não respondeu |

O e-mail é enviado **antes** de o job falhar. Se qualquer operação (certificado
ou trigger) terminar em `ERRO`, o job termina com falha depois do envio.

---

## 9. Relatório por e-mail

HTML gerado por `roles/relatorios/templates/corpo_email.html.j2`: resumo
(quantidade por operação), seção por chamado, tabela de resultado no Zabbix
(operação, chamado, host, tipo, validade anterior/solicitada, status e
mensagem), e, quando aplicável, o aviso de remoção e a tabela de triggers. O
assunto leva `(SIMULAÇÃO)` quando `aplicar_alteracoes` é falso.

---

## 10. Limitações e cuidados

- Sem `chamado`, são lidos da API do Jira (`/rest/api/3/search/jql`, até 1000)
  somente os chamados que **não** estão em `statusCategory = Done`. Com
  `chamado`, a busca é pela chave informada, sem esse filtro de status.
- A key do item precisa seguir exatamente o padrão da seção inicial; itens com
  outro formato são ignorados.
- Alterações de key, exclusões de trigger e criações não têm desfazer
  automático. Use a simulação antes.
- A cada execução, o módulo `zabbix_trigger` atualiza a trigger se já houver
  uma com o mesmo nome no host.
