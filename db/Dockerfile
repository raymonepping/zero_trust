FROM postgres:17.4

ENV POSTGRES_DB=appdb
ENV POSTGRES_USER=appuser
ENV POSTGRES_PASSWORD=apppassword

COPY seed.sql /docker-entrypoint-initdb.d/seed.sql

EXPOSE 5432
