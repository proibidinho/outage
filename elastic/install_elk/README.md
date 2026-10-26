# Instalação do cluster ELK (Elasticsearch + Kibana + Fleet) — 21 servidores, RHEL 9

Projeto Ansible enxuto para o AAP. Versão fixada em **9.5.5** (`group_vars/all.yml`).

> **Aviso importante:** este projeto foi escrito e revisado (sintaxe YAML, templates e lógica do plano de
> discos testados offline), mas **ainda não foi executado em servidores reais**. Rode primeiro em
> homologação ou, no mínimo, as ações `precheck` e `ensaio` (que não alteram nada) antes de qualquer outro.

---

## 1. O que tem aqui

```
inventory.yml          <- só os servidores e os grupos
group_vars/            <- variáveis do ambiente: all.yml (acao, versão, bastion, F5, Fleet) e um arquivo por grupo
                          (es_master.yml, es_hot.yml, ...: papéis do nó, heap e discos); elastic.yml = como entrar nos servidores (aiops + salto pelo bastion); bastion.yml = como entrar no bastion
vault.yml.example      <- modelo dos 7 segredos (crie o vault.yml a partir dele)
ansible.cfg
collections/requirements.yml     <- community.general (lvg, lvol, filesystem) e ansible.posix (mount)

site.yml               <- O UNICO playbook; o que ele faz depende da variavel "acao" (secao 4)

roles/                 <- 4 roles; cada um tem um main.yml (infra tem 4 arquivos, ver abaixo)
  precheck/            verificacoes antes de instalar
  infra/               usuario.yml · discos.yml · volume.yml · sistema.yml
  instalacao/          tasks/main.yml (tudo, dividido em FASES) · handlers/main.yml · templates/
  validacao/           conferencia final
```

Não há `defaults/` nem `vars/` em nenhum role. O único `handlers/` é o do role de instalação (reinicia Elasticsearch/Kibana só
quando algo mudou). Cada arquivo começa com um cabeçalho explicando o que faz, e as tarefas complexas têm uma **LEGENDA** em comentário.

## 2. Como o AAP chega nos servidores

```
AAP  ->  exec node (Lapa)  ->  bastion 10.29.148.161  ->  21 servidores do cluster
```

**Uma vez (`acao=usuario`):**
1. O exec node entra no bastion **como root** e, no bastion: cria o `aiops`, libera **sudo completo sem senha**, autoriza para o `aiops`
   a **mesma chave que o exec node já usa para entrar como root** (assim o exec node passa a entrar como `aiops`) e gera o par de chaves do `aiops`.
2. O bastion entra como root em cada servidor, cria o `aiops` (senha bloqueada, sudo sem senha) e grava a **chave pública do `aiops` do bastion**
   em `/home/aiops/.ssh/authorized_keys`.

**Em todas as outras ações** (`precheck`, `ensaio`, `instalar`, `validar`): o playbook busca a chave privada do `aiops` no bastion,
guarda uma cópia temporária no job (permissão 0600), entra no bastion **como `aiops`** e nos servidores **como `aiops`**
(`ProxyCommand` do `group_vars/elastic.yml`) e apaga a cópia no fim. O mantenedor usa a mesma chave: entra no bastion, faz `sudo -iu aiops` e `ssh` para o servidor.

- Nada é instalado nem copiado no bastion, e nada muda no AAP além do Inventory e do Job Template.
- **Premissa:** o job consegue entrar no bastion como root com a chave que o exec node já usa (como nos seus outros jobs). Se o job
  não enxergar essa chave, informe o caminho dela em `bastion_key_file` (veja o comentário no `group_vars/all.yml`).
- **Qual chave entra como `aiops` no bastion?** Por padrão, as que estão em `/root/.ssh/authorized_keys` do bastion (são as que já entram como
  root). Para autorizar só a do exec node, preencha `exec_node_public_key` em `group_vars/all.yml`.
- O login do root não é alterado em nenhum servidor. O `usuario` pode ser repetido sem duplicar usuário, chave nem regra de sudo.
- Rede: porta 22 liberada do `10.29.148.161` para os 21 servidores.
- A chave privada do `aiops` passa do bastion para o job a cada execução (temporária, só dentro do job). Se o AAP registrar a saída,
  as tarefas que a manipulam usam `no_log`.

## 3. Antes de começar (uma vez)

1. **Inventário e variáveis** — revise `inventory.yml` (servidores e grupos) e `group_vars/` (papéis, heap, discos, nomes do F5, bastion).
2. **Segredos** — copie `vault.yml.example` para `vault.yml`, gere os valores (o próprio exemplo mostra como:
   `openssl rand -base64 32` para senhas, `openssl rand -hex 32` para as chaves do Kibana) e criptografe:
   `ansible-vault encrypt vault.yml`. **Nunca** versione o `vault.yml` aberto.
   As 3 chaves do Kibana e o nome do cluster **não podem mudar depois** de instalado.
3. **AAP** — crie o *Inventory* a partir do `inventory.yml` e um *Job Template* apontando para `site.yml`, com *Prompt on launch* em
   **Variáveis extras** (onde você informa `acao`), usando a credencial que você já usa para chegar no bastion e a credencial *Vault*
   do `vault.yml`. O *Execution Environment* precisa das collections de `collections/requirements.yml`
   (`community.general` e `ansible.posix`).
4. **Usuário `aiops`** — lance o Job Template com `acao: usuario` (uma vez). Pode repetir sem problema.
   Na criação nos servidores são comandos `ssh` executados no bastion (via `delegate_to`), e não os módulos `user`/`authorized_key`,
   porque um módulo com `delegate_to` rodaria no próprio bastion, e não no servidor.

## 4. O que executar: a variável `acao`

O `site.yml` decide o que fazer por **condição**: a variável `acao` (definida em `group_vars/all.yml`, padrão `precheck`, que não altera nada)
e, dentro de `instalar`, a lista `componentes`.

| `acao` | O que faz | Observações |
|--------|-----------|-------------|
| `usuario` | cria o usuário `aiops` (senha bloqueada, chaves públicas, sudo sem senha) | roda uma vez; o bastion entra como root em cada servidor (seção 3) |
| `precheck` | versão, segredos, NTP, DNS, repositório, internet, portas... | mostra todos os problemas de uma vez; **não altera nada** |
| `ensaio` | mostra quais discos seriam formatados e por quê | **não altera nada** (seção 5) |
| `instalar` | pre-check + discos (LVM + XFS) + sistema (kernel, swap, THP, limites, chrony) + os `componentes` | veja abaixo |
| `validar` | discos montados, cluster *green*, 16 nós, serviços, Kibana, Fleet | **não altera nada** |

Na ação `instalar`, `componentes` (padrão `[elasticsearch, kibana, fleet]`) escolhe o que instalar, na ordem em que um depende do outro:

| componente | O que faz |
|------------|-----------|
| `elasticsearch` | pacote, certificados, configuração, formação do cluster (3 masters, depois os demais nós, um por vez), senhas definitivas |
| `kibana` | pacote, certificado, configuração, serviço (um por vez) |
| `fleet` | configura o Fleet no Kibana e instala o Fleet Server nos 2 servidores `integration` |

Exemplos:

```bash
ansible-playbook site.yml -e acao=usuario                  # uma vez
ansible-playbook site.yml                                  # padrao = precheck (so leitura)
ansible-playbook site.yml -e acao=ensaio                   # ensaio dos discos
ansible-playbook site.yml -e acao=instalar -e es_bootstrap_allowed=true     # cluster novo, tudo
ansible-playbook site.yml -e acao=instalar -e '{"componentes": ["kibana"]}' # so o Kibana
ansible-playbook site.yml -e acao=validar
```

Quem escolhe **em quais servidores** cada role roda é o `hosts:` de cada play no `site.yml` (grupos do `inventory.yml`).
Reexecutar é seguro: tudo é idempotente. Em cluster existente, a instalação reinicia os nós **um por vez** e só se algo mudou
(handler). No AAP, `es_bootstrap_allowed: true` entra nas variáveis extras **somente na primeira execução** do cluster.

## 5. Discos (como funciona)

Você declara em `group_vars/` (um arquivo por grupo) apenas **tamanho e quantidade** por volume (`storage_volumes`). Em cada servidor, 3 passos
(`roles/infra/tasks/discos.yml`, com comentários):

1. **Achar** os *discos crus*: disco inteiro, sem partição, sem volume em cima e sem nenhuma assinatura (`blkid` vazio).
   O `vg00` e os discos do sistema nunca entram, porque têm assinatura.
2. **Conferir:** o número de discos crus tem de ser **igual** ao pedido pelos volumes ainda não montados, e cada volume precisa
   de discos do tamanho certo (tolerância de 3%). Sobrou ou faltou disco → o play para e **nada é formatado** (em nenhum servidor).
3. **Criar** cada volume (`volume.yml`), com módulos que equivalem aos comandos manuais:

   | Módulo | Equivale a |
   |--------|-----------|
   | `community.general.lvg` | `pvcreate` + `vgcreate` / `vgextend` |
   | `community.general.lvol` | `lvcreate -l 100%FREE` |
   | `community.general.filesystem` | `mkfs.xfs` (nunca sobrescreve outro filesystem) |
   | `ansible.posix.mount` | linha no `/etc/fstab` + `mount` |

- Cada volume vira um VG próprio (`vg_esdata`, `vg_eslogs`, `vg_kbdata`).
- **Ensaio sem formatar nada:** `ansible-playbook site.yml -e acao=ensaio` mostra, por servidor, os discos crus encontrados e os volumes que seriam criados.
- Reexecutar é seguro: pontos já montados são ignorados.
- O fstab fica **sem `nofail`** de propósito: se o disco sumir, o servidor não sobe gravando no disco do sistema.
- O disco de 100 GB dos servidores `integration` fica cru (decisão do ambiente).

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

## 8. Usuário e acessos

- **`aiops`** não tem senha: a conta fica com a senha bloqueada e entra **só por chave SSH**; o sudo é sem senha (o Ansible não digita senha).
  A restrição por IP de origem não é usada (decisão do ambiente).
- **Manutenção do cluster:** o mantenedor entra no bastion `10.29.148.161` (onde já é root), faz `sudo -iu aiops` e `ssh <servidor>`
  com a chave do `aiops` do bastion, a mesma que o AAP usa. Se a chave for trocada, rode `acao=usuario` de novo no AAP (ele regrava o
  `authorized_keys`).
- Quem usa o `aiops` compartilhado não fica identificado individualmente nos servidores; o rastro de quem entrou está no login do bastion.
- Usuário `elastic` do Elasticsearch: senha em `vault.yml` (`es_elastic_password`). Depois da instalação, crie usuários nominais pelo Kibana.

## 9. Se algo falhar

| Sintoma | Causa provável |
|---------|----------------|
| `discos nao serao formatados` | quantidade/tamanho de discos crus diferente do `storage_volumes`; veja o debug "plano de discos" |
| `Cluster NOVO detectado` | faltou `-e es_bootstrap_allowed=true` na 1ª instalação do `elasticsearch` |
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
