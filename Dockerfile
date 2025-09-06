# Use a lightweight Python image as the base
FROM python:3.11-slim

# (Optional but nice) safer defaults
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

# Set working directory
WORKDIR /app

# Copy requirements file and install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of the application code
COPY . .

# Ensure static assets are accessible
RUN mkdir -p /app/static && chmod 755 /app/static

# Create a non-root user for security
RUN useradd -ms /bin/bash appuser

# Secure directory for encryption keys
RUN mkdir -p /home/appuser/.keys && chmod 700 /home/appuser/.keys \
 && chown -R appuser:appuser /home/appuser/.keys

# Secure directory for database storage
RUN mkdir -p /home/appuser/data && chmod 700 /home/appuser/data \
 && chown -R appuser:appuser /home/appuser/data

# If a database file is needed, create it with appropriate permissions
RUN touch /home/appuser/data/secure_data.db && chmod 600 /home/appuser/data/secure_data.db \
 && chown appuser:appuser /home/appuser/data/secure_data.db

# Set correct permissions for the /app directory
RUN chmod -R 755 /app && chown -R appuser:appuser /app

# --- entrypoint: load secrets from Docker/K8s secrets or generate at runtime ---
#   - Will read /run/secrets/{INVITE_CODE_SECRET_KEY,ENCRYPTION_PASSPHRASE} if provided
#   - If missing, securely generates new values and stores them only in an ephemeral runtime file
COPY --chown=appuser:appuser <<'SH' /app/entrypoint.sh
#!/usr/bin/env sh
set -euo pipefail
umask 077

# Prefer orchestrator secrets (Docker/K8s):
if [ -f /run/secrets/INVITE_CODE_SECRET_KEY ]; then
  export INVITE_CODE_SECRET_KEY="$(tr -d '\r\n' < /run/secrets/INVITE_CODE_SECRET_KEY)"
fi
if [ -f /run/secrets/ENCRYPTION_PASSPHRASE ]; then
  export ENCRYPTION_PASSPHRASE="$(tr -d '\r\n' < /run/secrets/ENCRYPTION_PASSPHRASE)"
fi

# Generate at runtime only if not supplied externally
if [ -z "${INVITE_CODE_SECRET_KEY:-}" ]; then
  INVITE_CODE_SECRET_KEY="$(python - <<'PY'
import secrets, sys
sys.stdout.write(secrets.token_hex(32))  # 64 hex chars
PY
)"
fi

if [ -z "${ENCRYPTION_PASSPHRASE:-}" ]; then
  ENCRYPTION_PASSPHRASE="$(python - <<'PY'
import secrets, base64, sys
sys.stdout.write(base64.urlsafe_b64encode(secrets.token_bytes(48)).decode().rstrip("="))
PY
)"
fi

# Persist only for this container lifetime (no image layer): ~/.runtime/qrs.env
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/home/appuser/.runtime}"
mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

ENV_FILE="$RUNTIME_DIR/qrs.env"
tmpf="$(mktemp "$RUNTIME_DIR/.qrs.env.XXXXXX")"
{
  printf 'export INVITE_CODE_SECRET_KEY="%s"\n' "$INVITE_CODE_SECRET_KEY"
  printf 'export ENCRYPTION_PASSPHRASE="%s"\n' "$ENCRYPTION_PASSPHRASE"
} > "$tmpf"
chmod 600 "$tmpf"
mv "$tmpf" "$ENV_FILE"

# Load for current process & children
# shellcheck disable=SC1090
. "$ENV_FILE"

# Harden a bit: disable core dumps (avoid secrets in cores)
ulimit -c 0 || true

exec "$@"
SH
RUN chmod +x /app/entrypoint.sh

# Switch to the non-root user
USER appuser

# Expose the port that waitress will listen on
EXPOSE 3000

# Use the secure entrypoint that loads/generates secrets at runtime
ENTRYPOINT ["/app/entrypoint.sh"]

# Start the Flask application using waitress
CMD ["waitress-serve", "--host=0.0.0.0", "--port=3000", "--threads=4", "main:app"]
