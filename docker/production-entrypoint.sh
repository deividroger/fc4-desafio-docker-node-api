#!/bin/sh
set -eu

node /app/dist/db/migrate.js
exec "$@"
