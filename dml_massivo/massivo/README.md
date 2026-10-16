# Massivo – execução em lote de DML Oracle no AAP

## Objetivo

Executar um script DML Oracle para **todas as linhas de um CSV** usando **um único
job** do `POC Oracle DML`, em vez de um job por linha.

| CSV com N linhas          | Jobs massivo | Jobs POC Oracle DML | Execuções Oracle |
|---------------------------|:------------:|:-------------------:|:----------------:|
| Antes (1 launch por linha)| 1            | **N**               | N                |
| Agora (1 launch por lote) | 1            | **1**               | N                |

Ponto negativo (aceito): o AAP deixa de ter métricas/status por registro; o resultado
de cada linha fica no **relatório do log** do job `POC Oracle DML`.

## Fluxo

```
Usuário ──Survey (chamado, platform, oracle_credencial, csv_text)──►
┌───────────────────────── Job Template MASSIVO ─────────────────────────┐
│ roles/execute_mass/tasks/main.yaml                                     │
│  1. valida o CSV (cabeçalho, colunas P_ da Survey do destino, linhas)  │
│  2. localiza o JT de destino na organização do massivo                 │
│  3. UMA chamada POST .../launch/  extra_vars:                          │
│       chamado, platform, oracle_credencial, csv_text (CSV completo)    │
└───────────────────────────────────┬────────────────────────────────────┘
                                    ▼
┌──────────────────────── Job Template POC Oracle DML ───────────────────┐
│ roles/oracle_dml/tasks/main.yaml                                       │
│  1. seleciona credencial Oracle (igual a antes)                        │
│  2. lê csv_text com community.general.read_csv                         │
│  3. para cada linha: dml.oracle_dml.execute_script (falha não aborta)  │
│  4. relatório consolidado no log                                       │
│  5. Failed se alguma linha falhou, Successful se todas passaram        │
└────────────────────────────────────────────────────────────────────────┘
```

## Arquivos alterados

| Projeto          | Arquivo                              | Mudança |
|------------------|--------------------------------------|---------|
| massivo          | `roles/execute_mass/tasks/main.yaml` | removido o loop que lançava 1 job por linha; validações do CSV; **1 único launch** com `csv_text`; tratamento de erro HTTP; remoção do arquivo temporário; sem debug do CSV/token |
| massivo          | `README.md`                          | este documento |
| poc_oracle_dml   | `roles/oracle_dml/tasks/main.yaml`   | modo massivo (lê `csv_text`, executa cada linha, relatório, status final); modo individual preservado |

Nada mais foi alterado: `playbook.yaml`, `ansible.cfg`, `script/script.sql`, roles de
plataforma, EE e a collection `dml.oracle_dml` continuam iguais.

## Configuração no AAP

**Survey do massivo** (como já existe): `chamado`, `platform`, `oracle_credencial`,
`csv_text` (Textarea).

**Survey do `POC Oracle DML`** – ajustes necessários:

1. **Criar a pergunta `csv_text`** (tipo *Textarea*, não obrigatória, *Maximum length*
   maior que o maior CSV esperado). Sem ela, a API descarta o CSV em silêncio; o
   massivo verifica isso e falha antes de lançar.
2. **Desmarcar *Required* nas perguntas `P_*`**: no lançamento massivo elas não são
   enviadas (os valores vêm do CSV) e a API recusaria o launch. Os nomes `P_*`
   continuam definindo as colunas obrigatórias do CSV.

Dimensione o *timeout* do Job Template `POC Oracle DML` para o tamanho dos lotes.

## Formato do CSV

Delimitador `;`, primeira linha não vazia = cabeçalho, uma coluna por variável `P_`.

```csv
P_NUM_CHAMADO;P_ACTIVE;P_STATUS;P_DEPARTMENT
1234;3213;123;DEPART
4321;ACT;STAT;DEPART2
```

## Regras de validação

| Situação                                         | massivo                  | POC Oracle DML |
|--------------------------------------------------|--------------------------|----------------|
| CSV vazio / sem registros                        | rejeita, não lança       | falha antes de executar |
| Coluna sem nome ou duplicada                     | rejeita                  | falha antes de executar |
| Coluna `P_` obrigatória ausente                  | rejeita (Survey do destino) | falha (binds `:P_` do `script.sql`) |
| Linha com nº de campos diferente do cabeçalho    | rejeita, lista as linhas | linha marcada **FALHA**, não executada, demais seguem |
| Linha com todos os campos vazios                 | aceita                   | **IGNORADA** (informada no relatório) |
| Linhas em branco                                 | descartadas              | descartadas |
| Valores vazios em alguns campos                  | aceitos                  | enviados como `''` (no Oracle `''` = `NULL`) |

- Os valores **não são alterados**: são strings, com zeros à esquerda e espaços
  preservados. Só o cabeçalho recebe `trim`.
- Os números de linha do relatório e das mensagens são os do **CSV original**.
- Não suportado: campo entre aspas com quebra de linha dentro (o lote é rejeitado com
  mensagem).
- Os valores vão para o Oracle **só como bind variables** (`binds`); nunca são
  concatenados no SQL.

## Execução e relatório

Cada linha é uma chamada a `dml.oracle_dml.execute_script` (nova sessão Oracle por
linha), em loop com `ignore_errors`: uma falha não impede as próximas. O sucesso/falha
de cada linha vem do resultado retornado pelo módulo (`failed`/`msg`).

Exemplo do log:

```
===================== RELATÓRIO DML ORACLE =====================
Chamado ............: CHG1
Plataforma .........: JIRA
Credencial Oracle ..: JIRA_HML
Modo ...............: massivo (CSV)
Linhas encontradas .: 5
Linhas processadas .: 3
Sucessos ...........: 2
Falhas .............: 2
Ignoradas ..........: 1 (todos os campos vazios: linhas 6)
------------------------- detalhe por linha -----------------------
SUCESSO | linha 2 | 1234
FALHA   | linha 3 | 17 | ORA-00942: table or view does not exist
FALHA   | linha 5 | 18 | quantidade de campos diferente do cabeçalho (4); não executada
IGNORADA| linha 6 | todos os campos vazios
SUCESSO | linha 7 | 19
================================================================
```

O identificador exibido é o valor da 1ª coluna do CSV. O `DBMS_OUTPUT` de cada linha
bem-sucedida continua sendo impresso (tarefa "Imprimir result"). Totais também ficam
nas estatísticas do job (`dml_total`, `dml_sucessos`, `dml_falhas`, `dml_ignorados`).

**Status final:** o relatório é sempre impresso; depois, o job termina **Failed** se
houver qualquer falha e **Successful** se todas as linhas passarem. O job massivo fica
*Successful* quando o lote é validado e lançado; o resultado real está no job de destino,
cujo ID aparece no log do massivo.

**Modo individual:** se o `POC Oracle DML` for executado direto, sem `csv_text`, ele
funciona como antes (binds da Survey), agora com o mesmo relatório.

## Teste com lote pequeno

1. Use credencial Oracle de **homologação**.
2. Lance o massivo com um CSV de 3 linhas, uma com erro conhecido (ex.: campos a menos).
3. Esperado: 1 job massivo, **1** job `POC Oracle DML`, relatório com 2 sucessos e
   1 falha, e job de destino **Failed**.
4. Para testar sem DML real, aponte `script/script.sql` para um bloco só com
   `DBMS_OUTPUT` (como o script atual) ou use um banco de homologação.

## Erros comuns

| Mensagem                                         | Ação |
|--------------------------------------------------|------|
| `HTTP 401`                                       | token do AAP inválido/expirado |
| `HTTP 403`                                       | token sem permissão nos Job Templates |
| `Job Template '...' não encontrado`              | nome errado ou destino em outra organização |
| `não possui a pergunta csv_text`                 | criar `csv_text` na Survey do destino |
| `variables_needed_to_start` no erro de launch    | desmarcar *Required* das perguntas `P_*` |
| `CSV não contém todas as variáveis`              | ajustar o cabeçalho do CSV |
| `Linhas do CSV com quantidade de campos diferente` | corrigir as linhas indicadas |
| `Confira no AAP se o job foi criado`             | timeout/5xx no launch: verificar antes de reenviar |

## Validação feita

- YAML dos dois `main.yaml` validado e todas as expressões Jinja (107) com sintaxe
  válida; somente módulos já usados no projeto; 1 única chamada `/launch/` no massivo.
- Relatório renderizado com dados de exemplo (saída acima).
- **Não** executado contra AAP/Oracle. Homologar: lote pequeno, lote grande (limite da
  Survey), `platform = OS/OC`, e confirmar 1 único job de destino por lote.

## Segurança

- Chamadas à API com `no_log` (o header `Authorization` levava o token ao log); erros
  mostram só status e `detail`. Credenciais Oracle continuam com `no_log`.
- O CSV não é mais impresso; o arquivo temporário é removido ao final.
- `validate_certs: false` mantido como no código original (CA interna). Recomendado
  instalar a CA no EE e habilitar a validação.
- **Atenção:** `Execution Environments/context/_build/ansible.cfg` do `poc_oracle_dml`
  contém **tokens reais** (Automation Hub, Galaxy, hub interno). Revogue-os e passe a
  injetá-los no build por variável/secret, sem versionar.
