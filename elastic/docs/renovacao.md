# Renovação dos certificados TLS do cluster Elastic

## 1. Quando renovar

| Item | Validade | Onde fica |
|------|----------|-----------|
| CA de transporte e CA HTTP (internas) | 10 anos | 1º master, `/root/elastic-ca/ca_transport` e `/root/elastic-ca/ca_http` |
| Certificados dos nodes, Kibana e Fleet Server | 3 anos (1095 dias) | em cada servidor (ver tabela do item 2) |

- Renove **pelo menos 60 dias antes** do vencimento dos certificados dos servidores.
- A renovação usa a **CA atual**. Por isso nada muda para quem confia na CA: F5, Kibana, Elastic Agents e integrações.
- Os certificados da empresa (os nomes públicos) ficam **no F5** e não entram neste procedimento.

## 2. Conferir a validade

**Pelo AAP (recomendado):** rode o job com `acao = validar`. No fim do log, a tarefa **"Mostrar a validade"** lista a data de vencimento de cada certificado, servidor por servidor.

**Manualmente, em um servidor:**

| Servidor | Arquivo |
|----------|---------|
| Elasticsearch | `/etc/elasticsearch/tls/http.p12` e `/etc/elasticsearch/tls/transport.p12` |
| Kibana | `/etc/kibana/tls/kibana.p12` |
| Fleet Server (integration) | `/etc/fleet-server-tls/fleet.crt` |

```bash
# .p12 (pede a senha tls_p12_password do vault)
openssl pkcs12 -in /etc/elasticsearch/tls/http.p12 -nokeys -clcerts | openssl x509 -noout -enddate
# .crt (Fleet)
openssl x509 -in /etc/fleet-server-tls/fleet.crt -noout -enddate
# CA (no 1º master)
openssl x509 -in /root/elastic-ca/ca_http/ca/ca.crt -noout -enddate
```

## 3. Antes de executar

1. O cluster precisa estar **green**. Confira com `acao = validar`.
2. Faça **backup de `/root/elastic-ca`** do 1º master em local seguro. Essa pasta guarda as chaves das CAs.
3. Confira se **todos os servidores estão no `inventory.yml`**. Só os servidores do inventário recebem certificado novo. Um node incluído pela survey de adição e que ainda não está no inventário **fica de fora**.
4. Escolha uma janela de manutenção. Os serviços reiniciam **um por vez** e não há indisponibilidade, mas a execução leva cerca de 5 a 10 minutos por node.

## 4. Como executar

No AAP, abra o Job Template e escolha na survey **`acao = renovar_certificados`**. Os campos de IP e função ficam vazios.

Pela linha de comando:
```bash
ansible-playbook site.yml -e acao=renovar_certificados
```

O que o playbook faz:

| Ordem | O que acontece |
|-------|----------------|
| 1 | Confere se as duas CAs valem por mais 3 anos. Se não valerem, **para** (ver item 7) |
| 2 | Move os certificados emitidos para `/root/elastic-ca/backup_certificados_AAAAMMDD/` |
| 3 | Emite certificados novos com a CA atual, com os mesmos nomes e IPs |
| 4 | Elasticsearch, **um node por vez** (masters primeiro): copia, reinicia e espera o node voltar e o cluster ficar **green** |
| 5 | Kibana, um por vez: copia, reinicia e espera ficar *available* |
| 6 | Fleet Server, um por vez: copia, reinicia o elastic-agent e espera ficar *HEALTHY* |
| 7 | Mostra a nova data de validade de cada servidor |

**Se falhar no meio**, rode de novo no **mesmo dia**:
- o backup do dia já existe, então não é refeito;
- certificados já emitidos não são emitidos outra vez;
- servidores que já estão com o certificado novo não reiniciam de novo.

Para renovar só um componente, use o `componentes` (padrão: `[elasticsearch, kibana, fleet]`).

## 5. Como validar

1. Rode `acao = validar`. O cluster deve estar green, com todos os nodes, Kibana disponível e Fleet online.
2. No log, confira as novas datas na tarefa **"Mostrar a validade"**. Todas devem ficar cerca de 3 anos à frente.
3. No F5, os pools do Elasticsearch, Kibana e Fleet devem estar verdes.
4. No Kibana, abra **Fleet > Agents**. Os agentes devem continuar *Healthy*.

## 6. Como voltar ao estado anterior (rollback)

Os certificados antigos continuam válidos até a data original. Para voltar:

```bash
# no 1º master
cd /root/elastic-ca
mv emitidos emitidos_falhou_$(date +%H%M)
rm -f es_transport.zip es_http.zip kibana_http.zip fleet_http.zip
mv backup_certificados_AAAAMMDD/* .
```

Depois rode `acao = instalar`, com `componentes` contendo os itens afetados. O playbook copia de volta os arquivos antigos e reinicia um servidor por vez.
Se precisar renovar de novo no **mesmo dia**, primeiro renomeie a pasta `backup_certificados_AAAAMMDD`.

## 7. Se a CA também estiver vencendo

O playbook **para** quando uma CA vence antes de 3 anos. Nesse caso, a troca da CA é uma **mudança planejada**: é preciso criar a CA nova, publicá-la junto com a antiga (no F5, no Kibana/Fleet com a fingerprint nova e nos agents) e só depois reemitir. Abra uma mudança específica para isso. As CAs atuais valem 10 anos a partir da instalação.