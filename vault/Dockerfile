FROM hashicorp/vault-enterprise:2.0.0-ent

ENV VAULT_DEV_ROOT_TOKEN_ID=root
ENV VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200
ENV VAULT_ADDR=http://0.0.0.0:8200

EXPOSE 8200

CMD ["vault", "server", "-dev"]
