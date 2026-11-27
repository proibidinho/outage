# Logstash (8 VMs, RHEL 9): projeto Ansible para o AAP

Projeto **separado** do projeto do cluster: não depende do inventário, do vault nem das roles dele.
Ele enxerga o cluster só pelo **VIP do Elasticsearch** (porta 443 do F5) e pela **CA pública** do cluster. Versão do Logstash: **9.5.5** (`group_vars/all.yml`).

> **Aviso:** escrito e revisado offline (sintaxe, templates, lógica do plano de discos), mas **ainda não executado em servidores reais**.
> Comece pela ação `precheck`, que não altera nada.

## 1. Estrutura

```
inventory.yml                   as 8 VMs, em 3 grupos de datacenter dentro do grupo logstash
group_vars/all.yml              survey, bastion, versão, heap, fila, usuário no cluster, disco
group_vars/{lapa,mackenzie,campinas}.yml   proxy de cada datacenter
vault.yml.example               modelo dos 2 segredos
collections/requirements.yml    community.general (lvg, lvol, filesystem) e ansible.posix (mount)
site.yml                        o único playbook (cada fase tem um "when" na variável acao)
roles/logstash/                 tasks/main.yml em FASES · plano_disco.yml · volume.yml · handlers · templates · files/http_ca.crt
```

## 2. Antes de começar

1. **CA:** coloque em `roles/logstash/files/http_ca.crt` a cadeia (PEM) da CA da empresa que assinou o certificado do VIP do Elasticsearch. É pública.
2. **Vault:** copie `vault.yml.example` para `vault.yml`, preencha, e criptografe com `ansible-vault encrypt vault.yml`. Nunca versione o `vault.yml` aberto.
   - `es_elastic_password`: a senha do usuário `elastic` do cluster (só serve para criar o usuário do Logstash).
   - `logstash_writer_password`: senha nova do usuário `logstash_internal` (`openssl rand -hex 24`).
3. **AAP:** Project novo apontando para este repositório; Inventory com fonte no projeto (`inventory.yml`); Job Template com `site.yml`,
   a credencial Machine (root) e a credencial *Vault*. O Execution Environment precisa das collections de `collections/requirements.yml`.
4. **Chamado de portas:** cada Logstash → VIP do Elasticsearch na **443**, e cada Logstash → proxy do próprio datacenter (para `artifacts.elastic.co`).
5. **F5:** o pool do VIP do Elasticsearch precisa conter os 8 Hot na 9200.

## 3. Survey do Job Template

| Campo | Tipo | Exemplo |
|-------|------|---------|
| `acao` | escolha única | `precheck` (padrão), `instalar`, `validar`, `pipeline_teste`, `pipeline_teste_remover` |
| `es_cluster_nome` | texto | `elasticsearch_corp` |
| `elastic_vip` | texto | `elastic.claro.com.br` (use o **nome**) |

- `es_cluster_nome` é **conferido**: se o VIP responder outro nome de cluster, o playbook para antes de criar qualquer coisa.
- `elastic_vip` é o destino dos Logstash. O Logstash não precisa falar com o Kibana nem com o Fleet.
- O F5 recebe na 443 e encaminha aos Hot na 9200, apresentando o certificado da **empresa**. Por isso `roles/logstash/files/http_ca.crt` deve ter a **cadeia da CA da empresa** (não a CA interna do cluster).

## 4. O que executar

| `acao` | O que faz |
|--------|-----------|
| `precheck` | SO, proxy do datacenter até a Elastic, DNS e porta do VIP, NTP, hostname e **plano de discos**. Não altera nada |
| `instalar` | precheck + disco, chrony, pacote, configuração, serviço e usuário de escrita no cluster |
| `pipeline_teste` | grava um pipeline simples (1 evento por minuto, índice `logstash-teste-comunicacao`), inicia o Logstash e espera o evento de cada VM chegar ao cluster |
| `pipeline_teste_remover` | apaga o pipeline de teste, para o Logstash (se não sobrar pipeline) e apaga o índice de teste |
| `validar` | disco XFS, versão, serviço, NTP, heap e **login no VIP** (com o nome do cluster conferido). Não altera nada |

Ordem: `precheck` → `instalar` → `validar`. Reexecutar é seguro: disco montado não é formatado, pacote não é reinstalado, e o serviço só reinicia se a configuração mudou.

## 5. O que o `instalar` faz em cada VM

| Etapa | Detalhe |
|-------|---------|
| Disco | o `sdb` (512 GB, cru) vira LVM + XFS em `/var/lib/logstash` (fila persistente e dead letter queue). Se o disco não for único e cru, **para sem formatar** |
| Chrony | aponta só para o NTP da empresa (`ntp_server`) |
| Pacote | `logstash-9.5.5`, repositório Elastic pelo **proxy do datacenter**, `dnf versionlock` |
| Heap | 40% da RAM, máximo 8g (16 GB → **6g**), em `/etc/logstash/jvm.options` |
| `logstash.yml` | fila persistente (100 GB por pipeline), DLQ ligada, API só no localhost |
| CA | `/etc/logstash/certs/http_ca.crt`, a do projeto |
| Credencial | `ES_USER` e `ES_PWD` em `/etc/sysconfig/logstash` (root, 0600), lidas pelo serviço |
| Exemplo | `/etc/logstash/saida-elasticsearch.conf.exemplo`: bloco `output` pronto, apontando para o VIP |
| Serviço | habilitado no boot. **Só inicia se existir pipeline** em `/etc/logstash/conf.d/*.conf` |
| Cluster | cria (uma vez) o role `logstash_writer` e o usuário `logstash_internal`. O Logstash **não** usa o `elastic` |

A primeira VM roda sozinha e as outras 7 em paralelo (se a primeira falhar, o playbook para).

## 6. O que ainda não está definido (de propósito)

- **Entradas, filtros e saída:** sem pipeline o Logstash encerra sozinho. Por isso o serviço fica *enabled* e parado até os `.conf` entrarem em `/etc/logstash/conf.d/`.
- **Índices:** o role nasce com `logstash_indices: ["logstash-*"]`. Ajuste em `group_vars/all.yml` quando os nomes ou data streams forem definidos e rode `instalar` de novo.
- **Renovação de certificados do cluster:** a CA http não muda (10 anos), os Logstash não precisam de nada.

## 6.1 VMs sem Satellite e proxy que bloqueia a Elastic

- Os RPMs do sistema (`lvm2`, `xfsprogs`, `chrony`, `openssl`, `python3-dnf-plugin-versionlock` e dependências) ficam em `/root` das VMs (`logstash_rpm_dir`) e são instalados todos juntos, sem consultar repositórios. Mantenha lá só o necessário.
- Logstash: `logstash_rpm_local: auto` (padrão) tenta o repositório da Elastic pelo proxy do datacenter e, se não alcançar, usa o `logstash-9.5.5*.rpm` de `/root`. Se também não houver RPM, o precheck reprova e diz para baixar o RPM e enviar para `/root` das VMs. `true` força o RPM local e `false` força o repositório (em `group_vars/<datacenter>.yml`).

## 7. Se algo falhar

| Sintoma | Causa provável |
|---------|----------------|
| `Falta roles/logstash/files/http_ca.crt` | passo 1 da seção 2 |
| erro de certificado no `validar` ou no `pipeline_teste` | o `http_ca.crt` não é a cadeia da CA que assinou o certificado do F5 |
| `artifacts.elastic.co inacessivel pelo proxy ...` | proxy do datacenter errado (`group_vars/<datacenter>.yml`) ou sem liberação para a Elastic |
| aviso `Sem resposta (chamado de portas aberto?)` | chamado de portas ainda não aplicado |
| `O VIP ... respondeu cluster_name=X` | `es_cluster_nome` da survey diferente do cluster atrás do VIP |
| `disco(s) cru(s) ... Nada foi formatado` | o `sdb` não está limpo, ou há mais de um disco cru |
| `validar`: `login ok no VIP=False` | senha diferente da do vault, CA errada, pool do F5 sem Hot ou 9200 bloqueada |
| `Relogio nao sincronizado` | o NTP pode não ser alcançável desse datacenter: sobrescreva `ntp_server` no arquivo do datacenter |

## 8. Adicionar uma 9ª VM

Inclua no `inventory.yml`, no grupo do datacenter, e rode `instalar`. As VMs prontas não mudam.
O inventário antigo tinha `CBL2BM25341` (Lapa) sem IP, fora das 8 VMs do chamado. Está comentada no inventário: preencha o IP e descomente.
