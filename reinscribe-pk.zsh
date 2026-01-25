#!/usr/bin/env zsh
emulate -L zsh
set -euo pipefail

# Safe under set -u
trap 'print -r -- "ERROR: line $LINENO: ${ZSH_DEBUG_CMD-<unknown>}"; exit 1' ERR

ENV_FILE="${ENV_FILE:-.env}"
EMIT_EXPORT=0
KEYSTR="${KEYSTR:-}"
PK_INPUT=""
MODE="apply"   # apply (default), encode, decode

while (( $# )); do
  case "$1" in
    --)
      shift
      continue
      ;;
    --export) EMIT_EXPORT=1 ;;
    --key)
      shift
      KEYSTR="${1:-}"
      ;;
    --pk)
      shift
      PK_INPUT="${1:-}"
      ;;
    --encode) MODE="encode" ;;
    --decode) MODE="decode" ;;
    --help|-h)
      cat <<'USAGE'
Usage:
  zsh reinscribe-pk.zsh [--export] [--key KEY] [--pk PK] [--encode|--decode]

Defaults: read PK from .env, prompt for key, write back to .env.

Quick commands:
  # Compute value to store in .env for a desired PK
  zsh reinscribe-pk.zsh --encode --pk 0x... --key "your-key"

  # Decode stored PK to the desired PK
  zsh reinscribe-pk.zsh --decode --pk 0x... --key "your-key"
USAGE
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done

if [[ -n "$PK_INPUT" ]]; then
  PK="$PK_INPUT"
else
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "Missing $ENV_FILE"
    exit 1
  fi

  # Grab the last PK= line
  pk_line="$(grep -E '^[[:space:]]*(export[[:space:]]+)?PK=' "$ENV_FILE" | tail -n 1 || true)"
  if [[ -z "$pk_line" ]]; then
    echo "No PK=... line found in $ENV_FILE"
    exit 1
  fi

  # Extract RHS after PK=
  PK="${pk_line#*PK=}"
fi

# Strip quotes if present
PK="${PK#\"}"; PK="${PK%\"}"
PK="${PK#\'}"; PK="${PK%\'}"

# Strip trailing whitespace/comments and Windows CR
PK="${PK%%[[:space:]]*}"
PK="${PK//$'\r'/}"

[[ $PK == 0x* ]] || { echo "PK must start with 0x"; exit 1; }

HEX="${PK#0x}"
(( ${#HEX} % 2 == 0 )) || { echo "PK hex length must be even"; exit 1; }
[[ $HEX =~ '^[0-9A-Fa-f]+$' ]] || { echo "PK must be valid hex"; exit 1; }

# Key: interactive unless KEYSTR is provided
if [[ -z "$KEYSTR" ]]; then
  printf "Enter key (any length; full key is used): "
  read -r KEYSTR
fi

# 64-bit mask (2^64 - 1) without hex literal warnings
typeset -i MASK state ord b ks
: $(( MASK = (1<<63) - 1 + (1<<63) ))
: $(( state = 0 ))

# Derive 64-bit state from the FULL key string
for ((i=1; i<=${#KEYSTR}; i++)); do
  ord=$(printf "%d" "'${KEYSTR[i]}")
  : $(( state = (state * 131 + ord) & MASK ))
done

# XOR keystream across PK bytes
out=""
for ((i=1; i<=${#HEX}; i+=2)); do
  : $(( state ^= (state << 13) & MASK ))
  : $(( state ^= (state >> 7)  & MASK ))
  : $(( state ^= (state << 17) & MASK ))

  : $(( ks = state & 0xff ))
  : $(( b  = 16#${HEX[i,i+1]} ^ ks ))
  out+=$(printf "%02x" "$b")
done

NEW_PK="0x$out"

# If PK was provided directly or encode/decode mode, just print result.
if [[ -n "$PK_INPUT" || "$MODE" != "apply" ]]; then
  if (( EMIT_EXPORT )); then
    printf 'export PK="%s"\n' "$NEW_PK"
  else
    printf '%s\n' "$NEW_PK"
  fi
  exit 0
fi

# Replace the LAST PK= line in .env
tmp="$ENV_FILE.tmp.$$"
awk -v newpk="$NEW_PK" '
  BEGIN { last = 0 }
  /^[[:space:]]*(export[[:space:]]+)?PK=/ { last = NR }
  { lines[NR] = $0 }
  END {
    for (i=1; i<=NR; i++) {
      if (i == last) print "PK=\"" newpk "\""
      else print lines[i]
    }
  }
' "$ENV_FILE" > "$tmp"

mv "$tmp" "$ENV_FILE"

if (( EMIT_EXPORT )); then
  printf 'export PK="%s"\n' "$NEW_PK"
else
  echo "Updated $ENV_FILE"
  echo "Backup: $ENV_FILE.bak"
  echo "New PK: $NEW_PK"
fi
