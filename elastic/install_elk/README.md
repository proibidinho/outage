# Instalação do cluster ELK (Elasticsearch + Kibana + Fleet): 21 servidores, RHEL 9

Projeto Ansible para o AAP. Versão fixada em **9.5.5** (`group_vars/all.yml`).

> **Aviso:** escrito e revisado offline (sintaxe, templates, lógica do plano de discos), mas **ainda não executado em servidores reais**.
> Comece pela ação `precheck`, que não altera nada.

## 1. Estrutura

```
inventory.yml        só os servidores e os grupos
group_vars/          all.yml (acao, versão, F5, Fleet...) e um arquivo por grupo (papéis, heap e discos de cada tipo de servidor)
vault.yml.example    modelo dos 7 segredos (crie o vault.yml a partir dele e criptografe)
collections/requirements.yml     community.general (lvg, lvol, filesystem) e ansible.posix (mount)
site.yml             o único playbook: chama os roles, cada um com um "when" na variável acao

roles/precheck/      verificações antes de instalar + plano de discos (somente leitura)
roles/infra/         discos (LVM + XFS) e sistema (kernel, swap, THP, limites)
roles/instalacao/    tasks/main.yml dividido em FASES · handlers/main.yml · templates/
roles/validacao/     conferência final (somente leitura)
```

## 2. Acesso

O exec node entra nos 21 servidores **como root**, com a chave da credencial Machine do Job Template (essa chave precisa estar autorizada
no root dos servidores). Se o exec node **não** alcança os servidores direto, preencha `bastion_host` em `group_vars/all.yml`: o SSH
passa a atravessar o bastion como túnel (o `sshd` do bastion precisa permitir `AllowTcpForwarding`). Vazio = conexão direta.

## 3. Antes de começar

1. Revise `inventory.yml` e `group_vars/` (papéis, heap, discos, nomes do F5, bastion).
2. Segredos: copie `vault.yml.example` para `vault.yml`, gere os valores (`openssl rand -hex 24`) e criptografe com `ansible-vault encrypt vault.yml`.
   **Nunca** versione o `vault.yml` aberto. As 3 chaves do Kibana e o nome do cluster **não podem mudar depois** de instalado.
3. AAP: Inventory com fonte no projeto (`inventory.yml`); Job Template com `site.yml`, a credencial Machine (root) e a credencial *Vault*.
   O Execution Environment precisa das collections de `collections/requirements.yml`.
4. Survey: pergunta `acao` (escolha única: `precheck`, `instalar`, `validar`). Opcionais: `es_bootstrap_allowed` e `componentes`.

## 4. O que executar: a variável `acao`

| `acao` | Roles | O que faz |
|--------|-------|-----------|
| `precheck` | `precheck` | versão, segredos, NTP, DNS, repositório, internet, portas e **plano de discos**. Não altera nada |
| `instalar` | `precheck` + `infra` + `instalacao` | pre-check, discos, sistema e os `componentes` |
| `validar` | `validacao` | discos montados, cluster *green*, 16 nós, serviços, Kibana, Fleet. Não altera nada |

`componentes` (padrão `[elasticsearch, kibana, fleet]`) escolhe o que a ação `instalar` executa:
`elasticsearch` (pacote, certificados, configuração, formação do cluster com os 3 masters e depois os demais nós, um por vez, senhas),
`kibana` (um por vez) e `fleet` (configura o Fleet no Kibana e instala o Fleet Server nos 2 `integration`).

```bash
ansible-playbook site.yml                                                   # precheck (so leitura)
ansible-playbook site.yml -e acao=instalar -e es_bootstrap_allowed=true     # cluster novo, tudo
ansible-playbook site.yml -e acao=instalar -e '{"componentes": ["kibana"]}' # so o Kibana
ansible-playbook site.yml -e acao=validar
```

Reexecutar é seguro (idempotente). Em cluster existente os nós reiniciam **um por vez** e só se algo mudou.
`es_bootstrap_allowed: true` só na **primeira** execução do cluster.

## 5. Discos

Você declara em `group_vars/` apenas **tamanho e quantidade** por volume (`storage_volumes`). Em cada servidor:

1. **Achar** os *discos crus* (precheck): disco inteiro, sem partição, sem volume e sem assinatura (`blkid` vazio). O `vg00` e os discos do sistema nunca entram.
2. **Conferir** (precheck): nº de discos crus **igual** ao pedido pelos volumes ainda não montados, e discos do tamanho certo (tolerância 3%).
   Sobrou ou faltou disco → para e **nada é formatado** em nenhum servidor.
3. **Criar** cada volume (infra, `volume.yml`): `lvg`, `lvol`, `filesystem` (xfs) e `mount`, um VG próprio por volume.

`acao=precheck` mostra o plano sem formatar nada. Pontos já montados são ignorados. O fstab fica **sem `nofail`** de propósito.
Servidores sem `storage_volumes` (os `integration`) ficam fora do plano.

## 6. Fleet

- Os 2 servidores `integration` são os **Fleet Servers** (porta 8220). Os certificados deles são emitidos pelo projeto (CA http interna).
- **F5 é opcional.** Sem F5, os agentes recebem as 2 URLs e fazem failover. Com F5: VIP na 8220 em *TCP/SSL passthrough*, *idle timeout* ≥ 10 min,
  e `fleet_public_name` em `group_vars/all.yml` antes de instalar `elasticsearch` e `fleet`.
- O **service token** de cada Fleet Server é criado pelo playbook (não é o *enrollment token*, que você gera no Kibana para os agentes comuns).
- A licença Enterprise não bloqueia nada: o Fleet funciona na Basic. O Kibana precisa alcançar `epr.elastic.co`.

## 7. F5 e certificados

- Os certificados **da empresa ficam só no F5**; os servidores usam **CAs internas** (transporte e http). VIP Kibana `10.29.177.75` → 3 Kibana (5601, HTTPS);
  VIP Elasticsearch `10.29.177.76` → nós hot (9200, HTTPS).
- Para o F5 validar o backend, a CA http pública está no primeiro master em `/root/elastic-ca/ca_http/ca/ca.crt`.
  **Faça backup seguro de `/root/elastic-ca`** (contém as chaves das CAs).
- Servidor novo depois: inclua no `inventory.yml`, apague no primeiro master o `.zip` do conjunto dele em `/root/elastic-ca` e rode `instalar` com o componente certo.

## 8. Se algo falhar

| Sintoma | Causa provável |
|---------|----------------|
| `disco(s) cru(s) encontrado(s)...` (precheck) | discos diferentes do `storage_volumes`; veja o debug "Mostrar o plano de discos" |
| `Permission denied` / `kex_exchange_identification` ao conectar | chave não autorizada no root dos servidores, ou o `sshd` do bastion bloqueia redirecionamento |
| `Cluster NOVO detectado` | faltou `-e es_bootstrap_allowed=true` na 1ª instalação |
| `X de 3 masters tem a marca` | estado inconsistente: confira `/etc/elasticsearch/.cluster_uuid` nos 3 masters |
| espera "cluster green" por muito tempo | `journalctl -u elasticsearch` no nó; DNS e portas 9200/9300 entre os nós |
| Kibana não fica *available* | `journalctl -u kibana`; confira a senha do `kibana_system` |
| Fleet Server não fica HEALTHY | `elastic-agent status` e `journalctl -u elastic-agent`; acesso do Kibana ao registry |

## 9. Pontos a conferir na primeira execução

Dependem do comportamento real das ferramentas: a estrutura do `.zip` do `elasticsearch-certutil`, as chamadas de Fleet pela API do Kibana,
as opções do `elastic-agent install` e o `kibana-keystore add --stdin --force`. Se algum falhar, a mensagem do Ansible aponta a tarefa exata.
