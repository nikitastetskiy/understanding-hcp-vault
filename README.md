# Understanding How HCP Vault Works

To begin, we'll set up a Vault development server to support the use cases we'll implement. There are several ways to do this:

## Running Vault Locally in dev mode

Running Vault locally is straightforward. For a detailed explanation or video tutorial, visit the [official guide](https://developer.hashicorp.com/vault/tutorials/get-started/setup).

For convenience and to streamline the learning process, you can start Vault in development mode with a predefined root token by running:

```
vault server -dev -dev-root-token-id=root -dev-tls
```

Running Vault with TLS, even in development, helps simulate a production-like environment and prevents the exposure of sensitive information over unencrypted connections.

To establish trust, you need to import these certificates into your browser or operating system's certificate store.

Also, configure your client applications or the CLI to explicitly trust the Vault server's CA certificate by setting environment variables:

```
export VAULT_ADDR='https://127.0.0.1:8200'
export VAULT_CACERT='/path/to/vault-ca.pem'
```

Replace `/path/to/vault-ca.pem` with the actual path to the Vault CA certificate generated during server startup.

### Stopping the Server

To stop the Vault development server, press `CTRL+C` in the terminal window where the server is running. You can also check this section directly on the [guide](https://developer.hashicorp.com/vault/tutorials/get-started/setup#clean-up).

## Running Vault with Docker

This section will be completed later.