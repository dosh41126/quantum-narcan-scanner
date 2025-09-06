FROM python:3.12-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# minimal build deps for wheels like psutil; trim if your reqs don't need it
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git pkg-config ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# install Python deps (make sure requirements.txt has NO liboqs / liboqs-python)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# app code
COPY . .

# unprivileged user + perms
RUN useradd -ms /bin/bash appuser \
 && mkdir -p /app/static \
 && chmod 755 /app/static \
 && chown -R appuser:appuser /app

# --- KEEP KEYGEN: generate per-build secrets into /etc/qrs.env ---
# NOTE: new image build => new KDF inputs => old DB ciphertexts become unreadable.
# If you need stability across builds, set these as Render env vars instead.
RUN python - <<'PY'
import secrets, base64, pwd, grp, pathlib, os
def b64(n): return base64.b64encode(secrets.token_bytes(n)).decode()
env = {
  "INVITE_CODE_SECRET_KEY": secrets.token_hex(32),
  "ENCRYPTION_PASSPHRASE": base64.urlsafe_b64encode(secrets.token_bytes(48)).decode().rstrip("="),
  "QRS_SALT_B64": b64(32),
  # runtime behavior (no OQS; sealed on)
  "STRICT_PQ2_ONLY": "0",
  "QRS_ENABLE_SEALED": "1",
  "QRS_ROTATE_SESSION_KEY": "1",
}
p = pathlib.Path("/etc/qrs.env")
with p.open("w") as f:
    for k, v in env.items():
        f.write(f'export {k}="{v}"\n')
uid = pwd.getpwnam("appuser").pw_uid
gid = grp.getgrnam("appuser").gr_gid
os.chown("/etc/qrs.env", uid, gid)
os.chmod("/etc/qrs.env", 0o600)
PY

# entrypoint: load keygen secrets; optional fresh keypairs each boot
COPY --chown=appuser:appuser <<'SH' /app/entrypoint.sh
#!/usr/bin/env sh
set -euo pipefail

# Load per-build secrets (created at image build time)
# shellcheck disable=SC1091
. /etc/qrs.env

# Hard fail if key pieces missing
: "${INVITE_CODE_SECRET_KEY:?missing}"
: "${ENCRYPTION_PASSPHRASE:?missing}"
: "${QRS_SALT_B64:?missing}"

# Ensure non-strict (no OQS required) and sealed store enabled
export STRICT_PQ2_ONLY="${STRICT_PQ2_ONLY:-0}"
export QRS_ENABLE_SEALED="${QRS_ENABLE_SEALED:-1}"
export QRS_ROTATE_SESSION_KEY="${QRS_ROTATE_SESSION_KEY:-1}"

# Optional: reset ephemeral keypairs every boot WITHOUT nuking sealed store.
# Toggle by setting QRS_RESET_KEYPAIRS=1 in Render.
if [ "${QRS_RESET_KEYPAIRS:-0}" = "1" ]; then
  unset QRS_X25519_PUB_B64 QRS_X25519_PRIV_ENC_B64
  unset QRS_PQ_KEM_ALG QRS_PQ_PUB_B64 QRS_PQ_PRIV_ENC_B64
  unset QRS_SIG_ALG QRS_SIG_PUB_B64 QRS_SIG_PRIV_ENC_B64
  # DO NOT unset QRS_SEALED_B64 here; that would erase the sealed cache.
fi

exec "$@"
SH
RUN chmod +x /app/entrypoint.sh

USER appuser
EXPOSE 3000
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["waitress-serve","--host=0.0.0.0","--port=3000","--threads=4","main:app"]
