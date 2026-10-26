# Instalação do cluster ELK (Elasticsearch + Kibana + Fleet) — 21 servidores, RHEL 9

Projeto Ansible enxuto para o AAP. Versão fixada em **9.5.5** (`group_vars/all.yml`).

> **Aviso importante:** este projeto foi escrito e revisado (sintaxe YAML, templates e lógica do plano de
> discos testados offline), mas **ainda não foi executado em servidores reais**. Rode primeiro em
> homologação ou, no mínimo, a ação `precheck` (que não altera nada) antes de qualquer outro.

---

## 1. O que tem aqui

```
inventory.yml          <- só os servidores e os grupos
group_vars/            <- variáveis do ambiente: all.yml (acao, versão, bastion, F5, Fleet) e um arquivo por grupo
                          (es_master.yml, es_hot.yml, ...: papéis do nó, heap e discos);
                          elastic.yml = como entrar nos servidores (salto pelo bastion)
vault.yml.example      <- modelo dos 7 segredos (crie o vault.yml a partir dele)
ansible.cfg
collections/requirements.yml     <- community.general (lvg, lvol, filesystem) e ansible.posix (mount)

site.yml               <- O UNICO playbook: chama os roles, cada um com um "when" na variável "acao" (seção 4)

roles/
  acesso/              copia a chave do bastion para o job (e apaga no fim)
  precheck/            verificações antes de instalar + plano de discos (somente leitura)
  infra/               discos (LVM + XFS) e configuração do sistema (kernel, swap, THP, limites)
  instalacao/          tasks/main.yml (tudo, dividido em FASES) · handlers/main.yml · templates/
  validacao/           conferência final (somente leitura)
```

Não há `defaults/` nem `vars/` em nenhum role. O único `handlers/` é o do role de instalação (reinicia Elasticsearch/Kibana só
quando algo mudou). Cada arquivo começa com um cabeçalho explicando o que faz, e as tarefas complexas têm uma **LEGENDA** em comentário.

## 2. Como o AAP chega nos servidores

```
AAP  ->  exec node (Lapa)  ->  bastion 10.29.148.161  ->  21 servidores do cluster      (tudo como root)
```

- O exec node entra no **bastion como root** (credencial do Job Template, como nos seus outros jobs) e a conexão SSH com os servidores
  atravessa o bastion (`ProxyCommand` em `group_vars/elastic.yml`). Os servidores também são acessados **como root**.
- **A chave dos servidores.** Quem se autentica no servidor é a chave que o *job* tem, e não a do bastion. Como só o bastion tem chave
  trocada com os servidores, o role `acesso` **copia a chave privada do root do bastion para o job** (`chave_bastion_vms` em
  `group_vars/all.yml`; padrão `/root/.ssh/id_rsa`, ajuste o nome se for outro), com permissão 0600, usa nas conexões e **apaga no fim**.
  A tarefa usa `no_log`. Se a chave do exec node já estiver autorizada nos servidores, deixe `chave_bastion_vms: ""` e nada é copiado.
  Se o play falhar no meio, a cópia só some quando o container do job for descartado.
- Nada é instalado nem copiado no bastion, e nada muda no AAP além do Inventory e do Job Template.
- Se o job não enxergar a chave que entra no bastion, informe o caminho dela em `bastion_key_file` (comentário em `group_vars/all.yml`).
- Rede: porta 22 liberada do `10.29.148.161` para os 21 servidores.

## 3. Antes de começar (uma vez)

1. **Inventário e variáveis** — revise `inventory.yml` (servidores e grupos) e `group_vars/` (papéis, heap, discos, nomes do F5, bastion,
   `chave_bastion_vms`).
2. **Segredos** — copie `vault.yml.example` para `vault.yml`, gere os valores (o próprio exemplo mostra como: `openssl rand -hex 24`)
   e criptografe: `ansible-vault encrypt vault.yml`. **Nunca** versione o `vault.yml` aberto.
   As 3 chaves do Kibana e o nome do cluster **não podem mudar depois** de instalado.
3. **AAP** — crie o *Inventory* a partir do `inventory.yml` (fonte: o projeto) e um *Job Template* apontando para `site.yml`, com a
   credencial que você já usa para chegar no bastion e a credencial *Vault* do `vault.yml`. O *Execution Environment* precisa das
   collections de `collections/requirements.yml` (`community.general` e `ansible.posix`).
4. **Survey** — uma pergunta `acao` (múltipla escolha, uma opção): `precheck`, `instalar`, `validar`. Opcional: `es_bootstrap_allowed`
   (verdadeiro só na primeira instalação do cluster) e `componentes`.

## 4. O que executar: a variável `acao`

O `site.yml` chama os roles e cada um tem um `when` na variável `acao` (survey; padrão `precheck`, que não altera nada).

| `acao` | Roles que rodam | O que faz |
|--------|-----------------|-----------|
| `precheck` | `precheck` | versão, segredos, NTP, DNS, repositório, internet, portas e **plano de discos**. Mostra todos os problemas de uma vez; **não altera nada** |
| `instalar` | `precheck` + `infra` + `instalacao` | pre-check, discos (LVM + XFS), sistema (kernel, swap, THP, limites, chrony) e os `componentes` |
| `validar` | `validacao` | discos montados, cluster *green*, 16 nós, serviços, Kibana, Fleet. **Não altera nada** |

(O role `acesso` roda antes e depois de qualquer ação, só para copiar e apagar a chave.)

Na ação `instalar`, `componentes` (padrão `[elasticsearch, kibana, fleet]`) escolhe o que instalar, na ordem em que um depende do outro:

| componente | O que faz |
|------------|-----------|
| `elasticsearch` | pacote, certificados, configuração, formação do cluster (3 masters, depois os demais nós, um por vez), senhas definitivas |
| `kibana` | pacote, certificado, configuração, serviço (um por vez) |
| `fleet` | configura o Fleet no Kibana e instala o Fleet Server nos 2 servidores `integration` |

Exemplos (linha de comando; no AAP é a survey):

```bash
ansible-playbook site.yml                                  # padrao = precheck (so leitura)
ansible-playbook site.yml -e acao=instalar -e es_bootstrap_allowed=true     # cluster novo, tudo
ansible-playbook site.yml -e acao=instalar -e '{"componentes": ["kibana"]}' # so o Kibana
ansible-playbook site.yml -e acao=validar
```

O `hosts:` de cada play no `site.yml` diz **em quais servidores** cada role roda (grupos do `inventory.yml`); o `when` diz **quando**.
Reexecutar é seguro: tudo é idempotente. Em cluster existente, a instalação reinicia os nós **um por vez** e só se algo mudou
(handler). `es_bootstrap_allowed: true` entra **somente na primeira execução** do cluster.

## 5. Discos (como funciona)

Você declara em `group_vars/` (um arquivo por grupo) apenas **tamanho e quantidade** por volume (`storage_volumes`). Em cada servidor:

1. **Achar** os *discos crus* (role `precheck`): disco inteiro, sem partição, sem volume em cima e sem nenhuma assinatura (`blkid` vazio).
   O `vg00` e os discos do sistema nunca entram, porque têm assinatura.
2. **Conferir** (role `precheck`): o número de discos crus tem de ser **igual** ao pedido pelos volumes ainda não montados, e cada volume
   precisa de discos do tamanho certo (tolerância de 3%). Sobrou ou faltou disco → o play para e **nada é formatado** (em nenhum servidor).
3. **Criar** cada volume (role `infra`, `volume.yml`), com módulos que equivalem aos comandos manuais:

   | Módulo | Equivale a |
   |--------|-----------|
   | `community.general.lvg` | `pvcreate` + `vgcreate` / `vgextend` |
   | `community.general.lvol` | `lvcreate -l 100%FREE` |
   | `community.general.filesystem` | `mkfs.xfs` (nunca sobrescreve outro filesystem) |
   | `ansible.posix.mount` | linha no `/etc/fstab` + `mount` |

- Cada volume vira um VG próprio (`vg_esdata`, `vg_eslogs`, `vg_kbdata`).
- **Ver o plano sem formatar nada:** `acao=precheck` mostra, por servidor, os discos crus encontrados e os volumes que seriam criados.
- Reexecutar é seguro: pontos já montados são ignorados.
- O fstab fica **sem `nofail`** de propósito: se o disco sumir, o servidor não sobe gravando no disco do sistema.
- Servidores sem `storage_volumes` (os `integration`) não entram no plano: o disco de 100 GB deles fica cru (decisão do ambiente).

## 6. Fleet — perguntas frequentes

**O que é?** O Elastic Agent é instalado nos servidores a monitorar; ele busca suas configurações num **Fleet Server** (porta 8220),
que consulta o Kibana. Os 2 servidores `integration` são os Fleet Servers. O componente `fleet` instala e liga tudo isso.

**Preciso emitir certificados para esses 2 servidores?** Não. O projeto os emite sozinho com a CA http interna
(`/root/elastic-ca` no primeiro master) e instala em `/etc/fleet-server-tls`.

**Precisam estar no F5?** Recomendado, mas opcional. Sem F5, os agentes recebem as duas URLs (IP de cada servidor) e fazem failover.
Com F5: crie um VIP para a porta 8220 em modo **TCP/SSL passthrough** (o certificado é o do Fleet Server, emitido pela CA interna; o
Elastic Agent valida contra ela), com *idle timeout* de pelo menos 10 minutos, e preencha `fleet_public_name` em `group_vars/all.yml`
antes de instalar `elasticsearch` e `fleet` (assim o nome entra no certificado e na configuração do Fleet).

**Que token é esse?** O **service token** do Fleet Server: credencial para o Fleet Server conversar com o Elasticsearch.
O playbook cria um por servidor, automaticamente, e usa na instalação. **Não** é o *enrollment token*, que é o dos agentes
comuns (esse você gera no Kibana quando for instalar agentes nos servidores a monitorar). Nada disso precisa ser pedido a ninguém.

**E a licença Enterprise que só chega em dois dias?** Não bloqueia nada. O Fleet funciona na licença Basic, e a instalação
inteira roda sem ela. Quando chegar, aplique em *Stack Management → License Management*.

**Requisito de rede:** o Kibana precisa alcançar `epr.elastic.co` (Elastic Package Registry) para instalar o pacote do Fleet.

## 7. F5 e certificados

- Os certificados **da empresa ficam só no F5**. Os servidores usam **somente CAs internas** (transporte e http), com validade
  de 3 anos para os certificados e 10 anos para as CAs.
- VIP Kibana `10.29.177.75` → 3 servidores Kibana, porta **5601 em HTTPS** (re-encrypt; o certificado do Kibana tem o IP no SAN).
- VIP Elasticsearch `10.29.177.76` → nós hot, porta **9200 em HTTPS**.
- Para o F5 validar o backend, a CA http pública (`/root/elastic-ca/ca_http/ca/ca.crt`, primeiro master) é copiada para
  `/etc/kibana/tls/http_ca.crt` e `/etc/elasticsearch/tls/http_ca.crt`. **Guarde também o `/root/elastic-ca` (contém as chaves das CAs):** faça backup seguro.
- Adicionar um servidor novo depois: inclua-o no `inventory.yml` (no grupo certo), apague no primeiro master o `.zip` do conjunto dele em
  `/root/elastic-ca` (ex.: `es_transport.zip`, `es_http.zip`) e rode `acao=instalar` com o componente correspondente (`componentes`).

## 8. Acessos

- O projeto **não cria usuários** nos servidores: tudo roda como **root**, pelo caminho exec node → bastion → servidores.
- **Manutenção do cluster:** o mantenedor entra no bastion `10.29.148.161` (onde já é root) e dali no servidor, como já faz hoje.
- Usuário `elastic` do Elasticsearch: senha em `vault.yml` (`es_elastic_password`). Depois da instalação, crie usuários nominais pelo Kibana.

## 9. Se algo falhar

| Sintoma | Causa provável |
|---------|----------------|
| `disco(s) cru(s) encontrado(s)...` (precheck) | quantidade/tamanho de discos crus diferente do `storage_volumes`; veja o debug "plano de discos" |
| `Cluster NOVO detectado` | faltou `-e es_bootstrap_allowed=true` na 1ª instalação do `elasticsearch` |
| `Permission denied` / `kex_exchange_identification` ao conectar nos servidores | o bastion não consegue entrar nos servidores com a chave de `chave_bastion_vms` (nome errado?), ou o `sshd` do bastion bloqueia redirecionamento (`AllowTcpForwarding`) |
| `X de 3 masters tem a marca` | estado inconsistente: confira `/etc/elasticsearch/.cluster_uuid` nos 3 masters |
| a instalação do `elasticsearch` espera "cluster green" por muito tempo | olhe `journalctl -u elasticsearch` no nó; confira DNS/portas 9200 e 9300 entre os nós |
| Kibana não fica *available* | `journalctl -u kibana`; confira o `kibana_system` e se a instalação do `elasticsearch` terminou |
| Fleet Server não fica HEALTHY | `elastic-agent status` e `journalctl -u elastic-agent` no servidor; confira acesso do Kibana ao registry |

## 10. O que foi removido do projeto original (de propósito)

Survey/arquivos de AAP e Execution Environment (use um Job Template com `site.yml` e a variável `acao`), testes, rotação automática de certificados,
modo "adotar cluster existente", gestão de firewalld, relatórios `set_stats`, senhas separadas por finalidade (agora são 2 senhas de
certificado), e a pasta de scaffold que não fazia parte do Ansible (backend/, frontend/, etc.). O `vault.yml` caiu de dezenas de
chaves para 7. Se precisar de alguma dessas funções, dá para reintroduzir pontualmente.

## 11. Pontos que merecem atenção na primeira execução

Foram escritos conforme a documentação da Elastic, mas dependem do comportamento real das APIs/ferramentas, então confira nos logs:
a estrutura do `.zip` do `elasticsearch-certutil` (`<nome>/<nome>.p12|.crt|.key`), as chamadas de Fleet pela API do Kibana, as
opções do `elastic-agent install` e o `kibana-keystore add --stdin --force`. Se algum desses falhar, a mensagem do Ansible aponta a
tarefa exata (o comando está legível no arquivo correspondente).
