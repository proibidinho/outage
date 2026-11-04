# Cluster Elastic: visão geral e instalação de Elastic Agents

## 1. Topologia

| Função | Grupo no inventário | Qtde | Papéis do Elasticsearch | Heap | Atrás do F5? |
|--------|---------------------|------|-------------------------|------|--------------|
| Master | `es_master` | 3 | `master` | 3g | não |
| Hot | `es_hot` | 8 | `data_hot`, `data_content`, `ingest` | 30g | **sim**: VIP `elastic.claro.com.br` (10.29.177.76:9200) |
| Cold | `es_cold` | 2 | `data_cold` | 30g | não |
| Frozen | `es_frozen` | 1 | `data_frozen` (cache em disco) | 12g | não |
| ML | `es_ml` | 2 | `ml` | 4g | não |
| Kibana | `kibana` | 3 | — | — | **sim**: VIP `kibana.claro.com.br` (10.29.177.75:5601) |
| Integration (Fleet Server) | `integration` | 2 | — (Elastic Agent) | — | **sim**: VIP `fleet.claro.com.br` (10.29.177.77:8220) |

- Versão: **9.5.5**, fixada em `group_vars/all.yml` e travada com `dnf versionlock`.
- Cluster: `elasticsearch_corp`. A descoberta é feita pelos IPs dos 3 masters.
- Dados em `/var/lib/elasticsearch` (LVM + XFS). Logs no `journalctl` e em `/var/log/elasticsearch`.
- Os dados chegam pelos nodes **Hot** e passam para Cold e Frozen conforme as políticas de ILM.

## 2. Certificados e CA

- O cluster usa **duas CAs internas**: uma de transporte (node ↔ node) e uma **HTTP** (clientes ↔ Elasticsearch, Kibana e Fleet).
- Os **Elastic Agents precisam confiar na CA HTTP**. Ela fica em:
  - 1º master: `/root/elastic-ca/ca_http/ca/ca.crt`;
  - qualquer node do Elasticsearch: `/etc/elasticsearch/tls/http_ca.crt`;
  - qualquer Fleet Server: `/etc/fleet-server-tls/http_ca.crt`.
- Copie **só o `ca.crt`**. Os arquivos `ca.key` e `.p12` nunca saem dos servidores.
- Fingerprint (SHA-256) da CA, usada pelo output do Fleet:
  ```bash
  openssl x509 -in /etc/elasticsearch/tls/http_ca.crt -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f'
  ```

## 3. Fleet

- Os 2 servidores `integration` são os **Fleet Servers**, na porta 8220. Os agents falam com `https://fleet.claro.com.br:8220`.
- No Kibana, em **Fleet > Settings**, ficam:
  - Fleet Server hosts: `fleet-server-aiops` (URL do VIP);
  - Output `default`: os 8 Hot, na porta 9200, com a fingerprint da CA HTTP.
- A política `fleet-server-policy` é **só dos Fleet Servers**. Não inscreva agents comuns nela.

## 4. Instalar e inscrever um Elastic Agent

### 4.1 Pré-requisitos no servidor de origem
- Acesso a `fleet.claro.com.br:8220` e aos Hot na porta 9200 (ou ao VIP `elastic.claro.com.br:9200`, conforme o output).
- O DNS resolve `fleet.claro.com.br`.
- O arquivo `ca.crt` da CA HTTP foi copiado para o servidor, por exemplo em `/etc/pki/elastic/ca.crt`.

### 4.2 No Kibana
1. Abra **Fleet > Agent policies > Create agent policy**. Use uma política por tipo de servidor, por exemplo `linux-apps`.
2. Adicione as integrações (System, Nginx etc.).
3. Abra **Fleet > Enrollment tokens** e copie o token da política.

### 4.3 No servidor (Linux)
```bash
VER=9.5.5
curl -L -O https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-$VER-linux-x86_64.tar.gz
tar xzf elastic-agent-$VER-linux-x86_64.tar.gz && cd elastic-agent-$VER-linux-x86_64
sudo ./elastic-agent install --non-interactive \
  --url=https://fleet.claro.com.br:8220 \
  --enrollment-token=<TOKEN_DA_POLITICA> \
  --certificate-authorities=/etc/pki/elastic/ca.crt
```
Se o servidor usa proxy, inclua `--proxy-url=http://10.29.177.37:8080`.

### 4.4 No servidor (Windows, PowerShell como administrador)
```powershell
.\elastic-agent.exe install --non-interactive `
  --url=https://fleet.claro.com.br:8220 `
  --enrollment-token=<TOKEN_DA_POLITICA> `
  --certificate-authorities=C:\elastic\ca.crt
```

### 4.5 Conferir
- No servidor: `sudo elastic-agent status` deve mostrar `Healthy`.
- No Kibana: em **Fleet > Agents**, o agent aparece *Healthy* na política escolhida.
- Os dados aparecem em **Discover** (data streams `logs-*` e `metrics-*`).

| Sintoma | Causa provável |
|---------|----------------|
| `x509: certificate signed by unknown authority` | faltou `--certificate-authorities` ou o `ca.crt` está errado |
| O agent fica *Offline* | firewall ou DNS até `fleet.claro.com.br:8220` |
| O agent fica *Healthy*, mas não chegam dados | o servidor não alcança os Hot na porta 9200 (output do Fleet) |

## 5. Operação
- **Adicionar ou remover nodes:** veja o documento *Adicionar e remover nodes*.
- **Certificados:** veja o documento *Renovação dos certificados TLS*.
- **Saúde do cluster:** rode o job com `acao = validar`. Ele não altera nada.