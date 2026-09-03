path "secret/data/application-b/*" {
  capabilities = ["read"]
}

path "secret/metadata/application-b/*" {
  capabilities = ["list"]
}
