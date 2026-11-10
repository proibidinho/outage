# 🚨 Auto Outage GMUD Observabilidade

> **Objetivo:** automatizar a criação de **Maintenance Windows no Dynatrace** e **Maintenances no Zabbix** a partir de GMUDs aprovadas para o time de Observabilidade, eliminando atividades manuais e aumentando a rastreabilidade operacional.

https://img.shields.io/badge/status-ativo-brightgreen
https://img.shields.io/badge/automation-AAP-red
https://img.shields.io/badge/monitoring-Dynatrace-orange
https://img.shields.io/badge/monitoring-Zabbix-red
https://img.shields.io/badge/ITSM-Jira-blue

---

# 🧭 Em poucas palavras

O projeto identifica automaticamente GMUDs que possuem atividades de aprovação para o grupo:

```text
OBSERVABILIDADE(APR)
```

A partir dessas GMUDs, a automação:

✅ Descobre os ativos vinculados na CMDB

✅ Localiza os servidores relacionados

✅ Busca os respectivos HOSTs e SERVICEs no Dynatrace

✅ Cria uma única Maintenance Window contendo todos os componentes encontrados

✅ Cria a Maintenance correspondente no Zabbix

✅ Gera uma planilha detalhada com todos os ativos processados

✅ Envia relatório por e-mail

---

# 🔄 Fluxo simplificado

```text
Jira GMUD
    │
    ▼
Role Descoberta
    │
    ▼
Assets / CMDB
    │
    ▼
Expansão dos ativos
    │
    ├────────► Dynatrace
    │             │
    │             ├─ HOSTs
    │             └─ SERVICEs
    │
    └────────► Zabbix
                    │
                    └─ Maintenances
    │
    ▼
Relatório Excel
    │
    ▼
E-mail
```

---

# 📋 O que a automação faz

## 1️⃣ Descobre GMUDs elegíveis

A automação consulta o Jira procurando atividades com status:

```text
Aguardando aprovação dos Executantes
```

e executante:

```text
OBSERVABILIDADE(APR)
```

A partir dessas atividades, identifica automaticamente a GMUD pai relacionada.

---

## 2️⃣ Obtém os ativos da CMDB

Cada GMUD possui um campo:

```text
customfield_14007
```

que referencia objetos do Jira Assets.

A automação suporta:

### ✅ Um ativo

Exemplo:

```text
P00PP4
```

### ✅ Vários ativos

Exemplo:

```text
PS8
FachadaSOACRM
```

### ✅ Objeto do tipo Sistema

```text
Sistema
 ├─ srv01
 ├─ srv02
 └─ srv03
```

### ✅ Objeto do tipo Servidor

```text
NET002PRDSAS025
```

---

## 3️⃣ Busca os ativos no Dynatrace

Após expandir a CMDB, a automação procura:

### HOSTs

Utilizando os nomes dos servidores.

Exemplo:

```text
NET002PRDLNX395
BRUX0206
ECC05CASDB02
```

---

### SERVICEs

Utilizando o nome do sistema CMDB.

Exemplo:

```text
GITLAB
P00PP4
MPE
```

---

## 4️⃣ Cria uma única Maintenance Window

Todos os componentes encontrados são consolidados.

Exemplo:

```text
HOST-123
HOST-456
SERVICE-ABC
SERVICE-DEF
```

Resultado:

```text
1 GMUD
1 Maintenance Window
N HOSTs
N SERVICEs
```

---

## 5️⃣ Cria Maintenance no Zabbix

Quando habilitado:

```yaml
zabbix_habilitado: true
```

a automação também cria a manutenção correspondente no Zabbix.

A busca dos hosts é case-insensitive através de consultas em:

```text
UPPER
LOWER
```

para aumentar a taxa de sucesso.

---

# 📊 Relatório Excel

Ao final da execução é gerada uma planilha Excel contendo todos os ativos relacionados às GMUDs processadas.

## Estrutura

| Coluna | Conteúdo |
|----------|----------|
| A | GML |
| B | Ativo |
| C | Tipo |
| D | Início |
| E | Fim |

---

## Exemplo

```text
GML-171661 | NET002PRDLNX395            | HOST
GML-171661 | BRUX1696                   | HOST
GML-171661 | SERVICE-219C556A892645F5   | SERVICE
GML-171661 | SERVICE-E3D067EED7B24615   | SERVICE
```

---

# 📧 E-mail automático

Ao término da execução é enviado um e-mail contendo:

- Quantidade de GMUDs processadas
- Quantidade de ativos encontrados
- Planilha Excel em anexo
- Resumo da execução

---

# 🧪 Modo de teste

Para validar a automação sem criar uma Maintenance Window real:

```yaml
dynatrace_validate_only: true
```

Nesse modo:

✅ Busca ativos

✅ Busca HOSTs

✅ Busca SERVICEs

✅ Valida payload

✅ Gera relatório

❌ Não cria Maintenance Window

---

# 🧪 Teste sem GMUD real

Caso não existam GMUDs abertas, é possível utilizar uma GMUD fictícia.

Arquivo:

```text
roles/outage/vars/main.yml
```

Exemplo:

```yaml
gmuds:
  - chave: "GML-TESTE"
    resumo: "Teste Dynatrace"
    inicio: "2026-09-18T18:08:00.000-0300"
    fim: "2026-09-18T19:10:00.000-0300"
    ativos:
      - "901269"
```

Para esse cenário basta comentar a role:

```yaml
# - role: descoberta
```

no playbook principal.

---

# ⚙️ Roles do projeto

## 📂 inventory

Responsável por:

- Registrar host virtual do Zabbix
- Validar parâmetros de acesso
- Preparar conexão API

---

## 📂 descoberta

Responsável por:

- Consultar Jira
- Descobrir GMUDs pai
- Obter datas da janela
- Obter ativos vinculados

---

## 📂 outage

Responsável por:

- Consultar CMDB
- Expandir ativos
- Buscar HOSTs
- Buscar SERVICEs
- Criar Maintenance Window Dynatrace
- Criar Maintenance Zabbix

---

## 📂 relatorios

Responsável por:

- Consolidar dados
- Gerar Excel
- Enviar e-mail
- Produzir rastreabilidade operacional

---

# 🚨 Problemas comuns

| Sintoma | Verificar |
|----------|----------|
| Nenhuma GMUD encontrada | Status da atividade |
| Nenhum ativo encontrado | customfield_14007 |
| Nenhum HOST encontrado | Nome do servidor no Dynatrace |
| Nenhum SERVICE encontrado | Nome do sistema CMDB |
| Maintenance não criada | dynatrace_validate_only |
| Host não encontrado no Zabbix | Cadastro do host |
| E-mail sem anexo | Caminho da planilha |

---

# ✅ Resultado esperado

Ao final da execução o processo entrega:

```text
GMUD
  ↓
CMDB
  ↓
HOSTs
  ↓
SERVICEs
  ↓
Dynatrace
  ↓
Zabbix
  ↓
Excel
  ↓
E-mail
```

Tudo de forma automática, auditável e sem intervenção manual.