# ---- base -------------------------------------------------------------
FROM python:3.12-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Build tools & headers (Rust needed by cryptography>=41 on Py3.12)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential python3-dev libffi-dev libssl-dev \
    cargo rustc git pkg-config ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# ---- app --------------------------------------------------------------
WORKDIR /app

# Upgrade pip tooling first, then install deps (prefer wheels)
COPY requirements.txt .
RUN python -m pip install --upgrade pip setuptools wheel \
 && pip install --prefer-binary -r requirements.txt

# Copy your source
COPY . .

# Unprivileged user and static dir perms
RUN useradd -ms /bin/bash appuser \
 && mkdir -p /app/static \
 && chmod 755 /app/static \
 && chown -R appuser:appuser /app

# ---- per-build keygen (KEEPING THIS) ---------------------------------
# Writes strong KDF inputs & flags to /etc/qrs.env (owned by appuser)
RUN python - <<'PY'
import secrets, base64, pwd, grp, pathlib, os
def b64(n): return base64.b64encode(secrets.token_bytes(n)).decode()
env = {
  # app secret at import time
  "INVITE_CODE_SECRET_KEY": secrets.token_hex(32),
  # KDF inputs — changing these breaks old ciphertexts (intended)
  "ENCRYPTION_PASSPHRASE": base64.urlsafe_b64encode(secrets.token_bytes(48)).decode().rstrip("="),
  "QRS_SALT_B64": b64(32),
  # behavior flags (NO OQS → STRICT_PQ2_ONLY must be 0)
  "STRICT_PQ2_ONLY": "0",
  # enable sealed store if you want it active by default
  "QRS_ENABLE_SEALED": "1",
  # keep session key rotation on
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

# ---- runtime entrypoint ----------------------------------------------
# Loads /etc/qrs.env and sanity-checks required secrets.
# By default we *also* force new keypairs each start; comment out the
# 'unset' block below if you prefer to keep the same ones between restarts.
COPY --chown=appuser:appuser <<'SH' /app/entrypoint.sh
#!/usr/bin/env sh
set -euo pipefail

# Load per-build secrets
if [ -f /etc/qrs.env ]; then
  # shellcheck disable=SC1091
  . /etc/qrs.env
fi

# Force fresh keypairs on every container start (optional).
# Comment out this block if you want to reuse previous keypairs.
unset QRS_X25519_PUB_B64 QRS_X25519_PRIV_ENC_B64 \
      QRS_PQ_KEM_ALG QRS_PQ_PUB_B64 QRS_PQ_PRIV_ENC_B64 \
      QRS_SIG_ALG QRS_SIG_PUB_B64 QRS_SIG_PRIV_ENC_B64 \
      QRS_SEALED_B64

# Hard fail if mandatory inputs missing
: "${ENCRYPTION_PASSPHRASE:?missing}"
: "${QRS_SALT_B64:?missing}"
: "${INVITE_CODE_SECRET_KEY:?missing}"

exec "$@"
SH
RUN chmod +x /app/entrypoint.sh

USER appuser
EXPOSE 3000

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["waitress-serve","--host=0.0.0.0","--port=3000","--threads=4","main:app"]
