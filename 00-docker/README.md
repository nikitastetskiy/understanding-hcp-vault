# Local HashiCorp Vault Setup with TLS (Docker Compose)

This guide creates a local Vault server secured with a self-signed SSL certificate.

## 1. Create directories

Create the necessary directories for Vault:

```bash
mkdir vault && cd vault
mkdir -p ./{config,file,logs,certs,data}
```

## 2. Generate SSL certificates

Generate a private key and a self-signed certificate for Vault:

```bash
# Private key
openssl genrsa -out ./certs/vault.key 4096

# Self-signed certificate
openssl req -x509 -new -nodes -key ./certs/vault.key -sha256 -days 825 \
  -subj "/CN=vault.local" \
  -addext "subjectAltName=DNS:vault.local,IP:127.0.0.1" \
  -out ./certs/vault.crt
```

## 3. Create the Vault configuration

Create the Vault configuration file with UI enabled, Raft storage, and TLS listener:

```bash
cat <<EOF > ./config/config.hcl
ui = true
disable_mlock = "true"

storage "raft" {
  path    = "/vault/data"
  node_id = "node1"
}

listener "tcp" {
  address       = "[::]:8200"
  tls_disable   = "false"
  tls_cert_file = "/certs/vault.crt"
  tls_key_file  = "/certs/vault.key"
}

api_addr     = "https://127.0.0.1:8200"
cluster_addr = "https://127.0.0.1:8201"
EOF
```

## 4. Create the Docker Compose file

Define the Docker Compose service for Vault with environment variables, ports, volumes, and entrypoint:

```bash
cat <<EOF > ./docker-compose.yml
services:
  vault:
    image: hashicorp/vault:latest
    container_name: vault-local
    environment:
      VAULT_ADDR: "https://127.0.0.1:8200"
      VAULT_API_ADDR: "https://127.0.0.1:8200"
      VAULT_CACERT: "/certs/vault.crt"
      VAULT_UI: "true"
    ports:
      - "8200:8200"
      - "8201:8201"
    restart: unless-stopped
    volumes:
      - ./logs:/vault/logs
      - ./data:/vault/data
      - ./config:/vault/config
      - ./certs:/certs
      - ./file:/vault/file
    cap_add:
      - IPC_LOCK
    entrypoint: vault server -config /vault/config/config.hcl
EOF
```

## 5. Start Vault

Start the Vault container in detached mode:

```bash
docker compose up -d
```

Access the UI at: [https://127.0.0.1:8200](https://127.0.0.1:8200) (you may need to accept the self-signed certificate warning).

## 6. Initialize Vault

Initialize Vault and obtain unseal keys and a root token:

```bash
docker exec -it vault-local /bin/sh
vault operator init
```

Store the output keys and token securely.


## 7. Stop or clean up

Stop and remove Vault containers and optionally remove volumes:

```bash
docker compose down              # stop and remove containers
docker compose down --volumes    # also remove data volumes
```