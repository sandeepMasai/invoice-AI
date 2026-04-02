#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

PORT="${1:-8001}"

if [[ ! -x ".venv/bin/uvicorn" ]]; then
  echo "Missing backend venv. Install deps first: cd /Users/sandeep/Desktop/invoice-AI/backend && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
  exit 1
fi

exec .venv/bin/uvicorn app.main:app --reload --host 127.0.0.1 --port "${PORT}"

