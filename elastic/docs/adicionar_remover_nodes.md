# Adicionar e remover nodes do cluster (survey do AAP)

## 1. Campos da survey

| Campo | Tipo | Valores |
|-------|------|---------|
| `acao` | escolha única | `precheck`, `instalar`, `validar`, **`adicao`**, **`remocao`**, `renovar_certificados` |
| `node_ip` | texto | IP da VM, por exemplo `10.29.88.230`. Só para `adicao` e `remocao` |
| `node_funcao` | escolha única | `Hot`, `Cold`, `Frozen`, `ML`, `Integration`. Só para `adicao` e `remocao` |

Quem configura o AAP inclui na survey as perguntas `node_ip` e `node_funcao` e as opções novas de `acao`.
O playbook **recusa** IPs de master e de Kibana.

## 2. Antes de adicionar (checklist da VM)

- [ ] RHEL 9, com acesso SSH de **root** a partir do exec node (a mesma chave dos outros servidores).
- [ ] O hostname da VM é o nome definitivo. `hostname -s` é usado como nome do node e não pode repetir o de outro node.
- [ ] O DNS resolve o nome da VM para o IP dela.
- [ ] Discos de dados **novos e vazios**, sem partição e sem formatação. O playbook usa todos os discos vazios que encontrar.
- [ ] Memória e CPU adequadas à função (ver item 3).
- [ ] Portas 9200/9300 (Elasticsearch) ou 8220 (Fleet) liberadas entre a VM e o cluster.

## 3. O que o playbook define sozinho (pelo gather_facts)

| Função | Heap | Disco de dados | Observação |
|--------|------|----------------|------------|
| Hot | 50% da RAM, no máximo 31g | todos os discos vazios → `/var/lib/elasticsearch` | recebe escrita e tráfego do F5 |
| Cold | 50% da RAM, no máximo 31g | idem | dados mais antigos |
| Frozen | 40% da RAM, no máximo 31g | idem | o resto da RAM e do disco vira cache dos snapshots |
| ML | 25% da RAM, no máximo 31g | idem | os modelos usam memória fora do heap |
| Integration | — | nenhum (o disco fica cru, como nos atuais) | vira um Fleet Server |

Se o IP já está no `inventory.yml`, o playbook usa o nome e o heap que estão lá.

Ajustes de sistema, os mesmos dos nodes atuais:
- `vm.max_map_count`, `swappiness = 1` e swap desligado;
- THP em `madvise`;
- `LimitMEMLOCK = infinity`, `LimitNOFILE = 65535` e `LimitNPROC = 4096`;
- chrony apontando para o NTP da empresa.

## 4. Adicionar um node (Hot, Cold, Frozen, ML ou Integration)

1. Abra o Job Template e escolha `acao = adicao`.
2. Preencha `node_ip` e `node_funcao`.
3. Execute. O playbook faz, nesta ordem:

| Ordem | Etapa |
|-------|-------|
| 1 | Lê CPU, memória e discos da VM e mostra o resumo, com nome, grupo e heap |
| 2 | Roda o precheck na VM: SO, DNS, NTP, repositório, portas e heap |
| 3 | Cria o disco de dados (LVM + XFS + fstab). **Se `/var/lib/elasticsearch` já está montado, não faz nada** |
| 4 | Aplica os ajustes de kernel e de sistema |
| 5 | Emite o certificado da VM com a CA atual. **Se já existe, não emite de novo** |
| 6 | Instala o Elasticsearch 9.5.5 com os papéis da função, inicia o serviço e espera o node **entrar no cluster** e o cluster ficar **green**. Para Integration, instala o Fleet Server e espera ficar *HEALTHY* |
| 7 | **Só para Hot:** reinicia os 3 Kibanas **um por vez**, já com a lista nova de Hot, e atualiza o output padrão do Fleet. Os agents recebem a lista nova sozinhos, sem reinício |
| 8 | Mostra o **lembrete do F5** e a linha que deve entrar no inventário |

### Exemplo de lembrete no fim do log
```
NODE ADICIONADO: cbl2am12345.claro.com.br (10.29.88.230) como Hot.
F5: INCLUIR 10.29.88.230 porta 9200 no pool do VIP elastic.claro.com.br (10.29.177.76).
KIBANA/FLEET: ja usam a lista nova de Hot (Kibanas reiniciados um por vez).
INVENTARIO: ADICIONE no inventory.yml, grupo es_hot, a linha:   cbl2am12345.claro.com.br: {ansible_host: 10.29.88.230, es_heap_size: 31g}
```

### Depois da adição (checklist)
- [ ] **F5:** inclua a VM no pool, se a função for Hot (VIP elastic, porta 9200) ou Integration (VIP fleet, porta 8220). Cold, Frozen e ML não ficam atrás do F5.
- [ ] **Inventário:** copie a linha `INVENTARIO` do log para o `inventory.yml`, no grupo indicado, e faça commit. Sem isso, a VM fica fora do `validar` e da renovação de certificados. Se o IP já estava no inventário, o log avisa *"nada a fazer"*.
- [ ] Rode `acao = validar`. O cluster deve estar green, com o número de nodes igual ao do inventário.
- [ ] No Kibana, em **Stack Monitoring** ou **Dev Tools**, rode `GET _cat/nodes?v` e confira o node e os papéis.

### Rodar de novo é seguro
Se o job falhar, por exemplo por timeout ou rede, corrija o problema e rode **a mesma survey de novo**:
- um disco já montado não é formatado;
- um VG criado pela metade é aproveitado;
- um certificado já emitido não é emitido de novo;
- o pacote não é reinstalado;
- um node que já está no cluster não reinicia, a menos que a configuração tenha mudado.

## 5. Remover um node

1. Abra o Job Template e escolha `acao = remocao`.
2. Preencha `node_ip` e `node_funcao`.
3. Execute. O playbook faz, nesta ordem:

| Ordem | Etapa |
|-------|-------|
| 1 | Localiza o node no cluster pelo IP. **Masters nunca são removidos** |
| 2 | Aplica a exclusão de alocação (`cluster.routing.allocation.exclude._name`). Os shards migram para os outros nodes |
| 3 | Espera o node ficar **sem shards**, por até 6 horas |
| 4 | Para e desabilita o serviço na VM (`elasticsearch` ou `elastic-agent`). O pacote e os dados **continuam** na VM |
| 5 | Espera o node sair do cluster e **limpa a exclusão de alocação** |
| 6 | Mostra o **lembrete do F5** e a linha que deve sair do inventário |
| 7 | **Só para Hot:** reinicia os 3 Kibanas **um por vez**, já sem o IP removido, e atualiza o output padrão do Fleet |

### Antes de remover
- O cluster não pode estar **red**.
- Os nodes que ficam precisam ter espaço para os shards do node removido.
- **Nunca remova o único node de uma função.** Por exemplo, o Frozen hoje é único: os shards dele não têm para onde ir e a espera termina em timeout.

### Depois da remoção (checklist)
- [ ] **F5:** tire a VM do pool, se a função for Hot ou Integration.
- [ ] Integration: em **Kibana > Fleet > Agents**, faça o *unenroll* do agent da VM, que vai aparecer *Offline*.
- [ ] **Inventário:** apague a linha indicada em `INVENTARIO` no log. Se ela ficar lá, a próxima `instalar` religa o serviço e devolve o IP para a lista de Hot do Kibana e do Fleet.
- [ ] Rode `acao = validar`.
- [ ] Para descartar a VM, apague os dados e o pacote manualmente, ou destrua a VM.

### Rodar de novo é seguro
Se o node já saiu do cluster, o playbook avisa *"já removido"*. Mesmo assim, ele confere se o serviço está parado e limpa uma exclusão de alocação que tenha sobrado. Os shards não são movidos de novo.

## 6. Problemas comuns

| Mensagem | O que fazer |
|----------|-------------|
| `nenhum disco vazio para /var/lib/elasticsearch` | Adicione um disco novo na VM ou confira se ele não foi formatado antes |
| `nome curto já usado por outro servidor` | Corrija o hostname da VM |
| `o IP já está no inventory.yml em outro grupo` | A função escolhida não bate com o inventário. Confira a survey |
| `PRECHECK REPROVADO` | Veja a lista de erros na mensagem (DNS, NTP, repositório, portas) |
| Espera pelo cluster green demora | `journalctl -u elasticsearch` na VM; portas 9300 entre a VM e os outros nodes |
| Remoção: espera de shards em timeout | `GET _cluster/allocation/explain`. Normalmente falta espaço ou não há outro node da mesma função |