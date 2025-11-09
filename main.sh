#!/usr/bin/env bash
# ======================================================================
# envcast — cast .env values into GitHub Secrets or Variables via gh
# Version: 1.1.1
#
# Behavior:
#   - Non-interactive by default when required inputs are provided via flags
#     and/or a config file (-cf/--config-file).
#   - Wizard runs only when flags/config are incomplete or when
#     --interactive/--select are passed.
#   - If fzf is available during wizard, use it; otherwise numbered picks.
#   - Questions highlighted; descriptions dimmed.
#   - Full .env iteration; handles BOM/CRLF/quotes/inline comments/`export`.
#   - Quiet put_var() (no duplicate success logs).
#
# Config file:
#   -cf, --config-file <PATH>  # supports .env-style or YAML (.yml/.yaml)
#   YAML requires 'yq'.
#
# Supported config keys (same as flags):
#   file, mode (secrets|variables), repo, org, env, prefix,
#   select (true|false), dry_run (true|false), verbose (true|false),
#   interactive (true|false)
#
# Precedence: CLI flags > config file values.
# ======================================================================

set -Eeuo pipefail

VERSION="1.1.1"

# ---------------------- Colors ----------------------
if [[ -t 2 ]]; then
  CLR_RESET=$'\033[0m'
  CLR_BOLD=$'\033[1m'
  CLR_DIM=$'\033[90m'
  CLR_CYAN=$'\033[36m'
  CLR_GREEN=$'\033[32m'
  CLR_RED=$'\033[31m'
  HL="${CLR_CYAN}${CLR_BOLD}"
  DESC="${CLR_DIM}"
else
  CLR_RESET=""; CLR_BOLD=""; CLR_DIM=""; CLR_CYAN=""; CLR_GREEN=""; CLR_RED=""
  HL=""; DESC=""
fi

# ---------------------- Logging helpers ----------------------
die() { printf 'envcast: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*" >&2; }
vlog() { [[ "${VERBOSE:-false}" == "true" ]] && printf '[v] %s\n' "$*" >&2; }
q() { # q "Question" ["Description"]
  printf '%s? %s%s\n' "$HL" "$1" "$CLR_RESET" >&2
  if [[ -n "${2:-}" ]]; then
    printf '%s‣ %s%s\n' "$DESC" "$2" "$CLR_RESET" >&2
  fi
}

# ======================================================================
#  CLI ARGUMENTS
# ======================================================================
INTERACTIVE="false"   # default: flags/config mode; wizard only if needed/requested
FILE=""
MODE=""
REPO=""
ORG=""
ENV_NAME=""
PREFIX=""
DRY_RUN="false"
VERBOSE="false"
SELECT_REPO="false"
CONFIG_FILE=""

bool_from() {
  # Bash 3.2-safe lowercasing via tr
  local raw="${1:-}"
  local lc; lc="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$lc" in
    1|true|yes|on)  echo "true" ;;
    0|false|no|off) echo "false" ;;
    *)              echo "" ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interactive) INTERACTIVE="true"; shift ;;
    -cf|--config-file) CONFIG_FILE="${2:-}"; shift 2 ;;
    -f|--file) FILE="${2:-}"; shift 2 ;;
    --secrets) MODE="secrets"; shift ;;
    --variables) MODE="variables"; shift ;;
    --repo|-r) REPO="${2:-}"; shift 2 ;;
    --org) ORG="${2:-}"; shift 2 ;;
    -e|--env) ENV_NAME="${2:-}"; shift 2 ;;
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --select) SELECT_REPO="true"; shift ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --verbose) VERBOSE="true"; shift ;;
    --version) echo "$VERSION"; exit 0 ;;
    --help|-h)
      cat <<EOF
${CLR_BOLD}envcast${CLR_RESET} v$VERSION — cast .env values into GitHub Secrets or Variables via gh

USAGE:
  envcast [-cf PATH] [--interactive]
          --file <.env> (--secrets | --variables)
          [--repo OWNER/REPO | --org ORG] [--env NAME]
          [--prefix STR] [--select] [--dry-run] [--verbose]

FLAGS:
  -cf, --config-file PATH    Load options from a config file (.env style or YAML)
  -f,  --file PATH           Path to .env to import
       --secrets             Write as GitHub Actions secrets (encrypted)
       --variables           Write as GitHub Actions variables (plain)
  -r,  --repo OWNER/REPO     Target repository
       --org ORG             Target organization (if not repo)
  -e,  --env NAME            GitHub Environment name (staging, production, ...)
       --prefix STR          Prefix to apply for plain Actions scope (e.g. DEV_)
       --select              Force interactive repo selection
       --dry-run             Preview changes without writing
       --verbose             Extra logs
       --version             Show version
       --help                Show help

NOTES:
- If --env is set, prefix is ignored.
- Wizard runs only when required fields are missing or --interactive/--select is used.
- Config precedence: CLI flags override config values.
EOF
      exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# ======================================================================
#  Config loader
# ======================================================================
_set_from_cfg() {
  # _set_from_cfg <key> <value>
  local k="$1" v="$2"
  [[ -z "${v:-}" ]] && return 0
  case "$k" in
    file)         FILE="$v" ;;
    mode)         MODE="$v" ;;
    repo)         REPO="$v" ;;
    org)          ORG="$v" ;;
    env)          ENV_NAME="$v" ;;
    prefix)       PREFIX="$v" ;;
    select)       v="$(bool_from "$v")"; [[ -n "$v" ]] && SELECT_REPO="$v" ;;
    dry_run)      v="$(bool_from "$v")"; [[ -n "$v" ]] && DRY_RUN="$v" ;;
    verbose)      v="$(bool_from "$v")"; [[ -n "$v" ]] && VERBOSE="$v" ;;
    interactive)  v="$(bool_from "$v")"; [[ -n "$v" ]] && INTERACTIVE="$v" ;;
  esac
}

load_config_envfile() {
  local path="$1" raw line k v
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="${raw%%#*}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"
    [[ -z "$line" || "$line" != *"="* ]] && continue
    k="${line%%=*}"; v="${line#*=}"
    k="$(printf '%s' "$k" | sed -e 's/[[:space:]]//g')"
    v="$(printf '%s' "$v" | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"
    if [[ "$v" == \"*\" && "$v" == *\" ]]; then v="${v:1:-1}"; fi
    if [[ "$v" == \'*\' && "$v" == *\' ]]; then v="${v:1:-1}"; fi
    _set_from_cfg "$k" "$v"
  done < "$path"
}

load_config_yaml() {
  local path="$1"
  command -v yq >/dev/null 2>&1 || die "yq is required to parse YAML config: $path"
  _set_from_cfg file        "$(yq -r '.file // ""'        "$path")"
  _set_from_cfg mode        "$(yq -r '.mode // ""'        "$path")"
  _set_from_cfg repo        "$(yq -r '.repo // ""'        "$path")"
  _set_from_cfg org         "$(yq -r '.org // ""'         "$path")"
  _set_from_cfg env         "$(yq -r '.env // ""'         "$path")"
  _set_from_cfg prefix      "$(yq -r '.prefix // ""'      "$path")"
  _set_from_cfg select      "$(yq -r '.select // ""'      "$path")"
  _set_from_cfg dry_run     "$(yq -r '.dry_run // ""'     "$path")"
  _set_from_cfg verbose     "$(yq -r '.verbose // ""'     "$path")"
  _set_from_cfg interactive "$(yq -r '.interactive // ""' "$path")"
}

load_config_file() {
  local path="$1"
  [[ -n "$path" ]] || return 0
  [[ -f "$path" ]] || die "Config file not found: $path"
  case "$path" in
    *.yml|*.yaml) load_config_yaml "$path" ;;
    *)            load_config_envfile "$path" ;;
  esac
}

# ======================================================================
#  Bootstrap helpers
# ======================================================================
attempt_install_pkg() {
  local pkg="$1"
  if command -v brew >/dev/null 2>&1; then
    brew install "$pkg" || true
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y || true
    sudo apt-get install -y "$pkg" || true
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y "$pkg" || true
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -Sy --noconfirm "$pkg" || true
  fi
  command -v "$pkg" >/dev/null 2>&1
}

ensure_gh() {
  if ! command -v gh >/dev/null 2>&1; then
    q "GitHub CLI not installed" "Required for setting secrets/variables. Install now?"
    read -r -p "${HL}[Y/n]${CLR_RESET} " a; a="${a:-Y}"
    if [[ "$a" =~ ^[Yy]$ ]]; then
      attempt_install_pkg gh || die "Failed installing gh. Install manually: https://cli.github.com/"
    else
      die "gh required. Install from https://cli.github.com/"
    fi
  fi
}

ensure_auth() {
  if ! gh auth status >/dev/null 2>&1; then
    q "You are not logged in" "A browser login will open."
    read -r -p "${HL}[Y/n]${CLR_RESET} " a; a="${a:-Y}"
    if [[ "$a" =~ ^[Yy]$ ]]; then
      gh auth login -w || die "gh auth login failed."
    else
      die "Cannot continue without authentication."
    fi
  fi
}

ensure_fzf_available_if_wizard() {
  if command -v fzf >/dev/null 2>&1; then return 0; fi
  q "fzf not installed" "fzf enables searchable menus; otherwise you’ll get simple numbered picks."
  read -r -p "${HL}Install fzf? [Y/n]${CLR_RESET} " a; a="${a:-Y}"
  if [[ "$a" =~ ^[Yy]$ ]]; then
    attempt_install_pkg fzf || log "${DESC}Skipping fzf install; falling back to numbered picks.${CLR_RESET}"
  fi
}
fzf_available() { command -v fzf >/dev/null 2>&1; }

# ======================================================================
#  Basic input helpers
# ======================================================================
prompt_input() {
  local label="$1"; local desc="$2"
  q "$label" "$desc"
  local v; read -r -p "${HL}> ${CLR_RESET}" v
  printf '%s' "$v"
}

numbered_select() {
  local prompt="$1"; shift
  local -a items=("$@")
  local count="${#items[@]}"
  (( count > 0 )) || die "No items to select from."
  local i
  for i in "${!items[@]}"; do
    printf "%2d) %s\n" $((i+1)) "${items[i]}" >&2
  done
  local attempts=0 sel
  while (( attempts < 3 )); do
    read -r -p "${HL}# Pick a number [1-$count]: ${CLR_RESET}" sel
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >=1 && sel <= count )); then
      printf '%s' "${items[sel-1]}"
      return 0
    fi
    echo "Invalid selection. ($(($attempts+1))/3)" >&2
    (( attempts++ ))
  done
  die "Too many invalid attempts."
}

fzf_or_numbered() {
  local prompt="$1"; shift
  local -a items=("$@")
  if fzf_available; then
    printf '%s\n' "${items[@]}" | fzf --prompt="$prompt: " --height=20 --border || die "Selection cancelled."
  else
    numbered_select "$prompt" "${items[@]}"
  fi
}

# ======================================================================
#  GitHub data helpers
# ======================================================================
fetch_user_login() { gh api /user --jq .login 2>/dev/null || echo ""; }
fetch_orgs_tsv() {
  gh api /user/orgs --paginate \
    --jq '.[] | [.login, (.description // "(no description)")] | @tsv' 2>/dev/null || true
}
fetch_repos_for_owner() {
  local owner="$1"
  gh repo list "$owner" --limit 500 --json nameWithOwner \
    --jq '.[].nameWithOwner' 2>/dev/null || true
}

# ======================================================================
#  Selections (wizard)
# ======================================================================
select_mode() {
  [[ -n "$MODE" ]] && return
  local items=("secrets — encrypted (API keys, tokens, certs)" "variables — plain text (URLs, feature flags)")
  q "Mode" "Secrets are encrypted; Variables are plain text."
  local choice; choice="$(fzf_or_numbered "Mode" "${items[@]}")"
  if [[ "$choice" =~ ^secrets ]]; then MODE="secrets"; else MODE="variables"; fi
}

select_file() {
  if [[ -n "$FILE" ]]; then
    [[ -f "$FILE" ]] || die "File not found: $FILE"
    return
  fi
  FILE="$(prompt_input "Path to .env file" "This file is parsed for KEY=VALUE pairs. Lines starting with # or 'export ' are handled.")"
  [[ -f "$FILE" ]] || die "File not found: $FILE"
}

select_owner_and_repo() {
  local user_login; user_login="$(fetch_user_login)"
  [[ -z "$user_login" ]] && die "Could not determine your GitHub login. Check 'gh auth status'."

  # Owners list: user first, then orgs
  local -a owners; owners+=("${user_login} (your account)")
  local orgs_tsv; orgs_tsv="$(fetch_orgs_tsv)"
  if [[ -n "$orgs_tsv" ]]; then
    while IFS=$'\t' read -r org desc; do
      [[ -z "$org" ]] && continue
      owners+=("${org} — ${desc}")
    done <<< "$orgs_tsv"
  fi

  q "Select owner" "Main account shown first, followed by any organizations you belong to."
  local owner_choice; owner_choice="$(fzf_or_numbered "Owner" "${owners[@]}")"
  local owner="$owner_choice"; owner="${owner%% *}"  # split at first space

  q "Select repository" "Listing repositories under ${owner}."
  local -a repos
  IFS=$'\n' read -r -d '' -a repos < <(fetch_repos_for_owner "$owner"; printf '\0')
  (( ${#repos[@]} > 0 )) || die "No repositories found for '${owner}'."

  local repo_choice; repo_choice="$(fzf_or_numbered "Repository" "${repos[@]}")"
  REPO="$repo_choice"
  ORG="" # ensure org cleared if repo chosen
}

select_scope_and_prefix() {
  q "Are you using GitHub Environments?" "Environments (e.g., staging, production) isolate secrets/variables."
  local items=("Use a GitHub Environment" "Use plain Actions secrets/variables")
  local scope_choice; scope_choice="$(fzf_or_numbered "Scope" "${items[@]}")"

  if [[ "$scope_choice" =~ ^Use\ a\ GitHub ]]; then
    q "Environment name" "For example: staging or production."
    read -r -p "${HL}> ${CLR_RESET}" ENV_NAME
    [[ -z "$ENV_NAME" ]] && die "Environment name is required for environment-scoped configuration."
    PREFIX=""
  else
    ENV_NAME=""
    q "Apply an environment prefix to keys?" "Examples: DEV_, STAGING_. Leave empty to skip."
    read -r -p "${HL}Prefix (optional): ${CLR_RESET}" PREFIX
    if [[ -n "$PREFIX" && "$PREFIX" != *_ ]]; then PREFIX="${PREFIX}_"; fi
  fi
}

# ======================================================================
#  .env parsing helpers
# ======================================================================
trim() {
  # normalize CR, then trim leading/trailing whitespace (POSIX-safe)
  printf '%s' "$(printf '%s' "${1-}" | sed -e 's/\r$//' -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"
}
unquote_if_wrapped() {
  local v="$1"
  if [[ "$v" == \"*\" && "$v" == *\" ]]; then v="${v:1:-1}"; fi
  if [[ "$v" == \'*\' && "$v" == *\' ]]; then v="${v:1:-1}"; fi
  printf '%s' "$v"
}

parse_line() {
  local line="$1"
  # Strip BOM + CR
  line="${line//$'\ufeff'/}"; line="${line//$'\r'/}"
  line="$(trim "$line")"
  [[ -z "$line" || "$line" =~ ^# ]] && return 1
  [[ "$line" =~ ^export[[:space:]]+ ]] && line="${line#export }"
  [[ "$line" != *"="* ]] && return 1

  local key="${line%%=*}" raw="${line#*=}"
  key="$(trim "$key")"; raw="$(trim "$raw")"

  if [[ ! "$raw" =~ ^\".*\"$ && ! "$raw" =~ ^\'.*\'$ ]]; then
    raw="$(printf '%s' "$raw" | awk '{
      out=""; esc=0;
      for (i=1;i<=length($0);i++){
        c=substr($0,i,1);
        if (c=="#" && !esc){ break; }
        if (c=="\\") { if (esc) { out=out"\\"; esc=0; } else { esc=1; continue; } }
        else { if (esc){ out=out"\\"; esc=0; } out=out c; }
      }
      print out;
    }')"
    raw="$(trim "$raw")"
  fi

  raw="$(unquote_if_wrapped "$raw")"
  printf '%s\t%s' "$key" "$raw"
  return 0
}

is_valid_key() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }

# ======================================================================
#  Writer: calls gh secret/variable (quiet)
# ======================================================================
put_var() {
  local key="$1" val="$2"
  local scope_flags=()
  if [[ -n "$REPO" ]]; then scope_flags+=(--repo "$REPO"); else scope_flags+=(--org "$ORG"); fi
  [[ -n "$ENV_NAME" ]] && scope_flags+=(--env "$ENV_NAME")

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[dry-run] $MODE set $key ${scope_flags[*]}"
    return 0
  fi

  local envblock=(env GH_PROMPT_DISABLED=1 GH_NO_TTY=1)

  if [[ "$MODE" == "secrets" ]]; then
    # gh secret set reads value from stdin when --body is omitted
    printf '%s' "$val" | "${envblock[@]}" gh secret set "$key" "${scope_flags[@]}" >/dev/null
  else
    # gh variable set reliably supports --body
    "${envblock[@]}" gh variable set "$key" "${scope_flags[@]}" --body "$val" >/dev/null
  fi
}

# ======================================================================
#  Process .env file (BOM/CRLF safe; full iteration)
# ======================================================================
process_env_file() {
  local line parsed key val
  local count_total=0 count_set=0 count_skip=0

  exec 3< "$FILE"
  while IFS= read -r -u 3 line || [[ -n "$line" ]]; do
    ((count_total++))
    parsed="$(parse_line "$line" 2>/dev/null || true)"
    if [[ -z "$parsed" ]]; then ((count_skip++)); continue; fi

    key="${parsed%%$'\t'*}"
    val="${parsed#*$'\t'}"

    if [[ -n "$PREFIX" ]]; then
      [[ "$PREFIX" != *_ ]] && PREFIX="${PREFIX}_"
      key="${PREFIX}${key}"
    fi

    if ! is_valid_key "$key"; then
      log "Skipping invalid key: '$key'"; ((count_skip++)); continue
    fi

    if put_var "$key" "$val"; then
      log "✓ $key"; ((count_set++))
    else
      log "✗ Failed to set $key"; ((count_skip++))
    fi
  done
  exec 3<&-

  log "Processed $count_total lines ($count_set set, $count_skip skipped)."
  log "${CLR_GREEN}Done.${CLR_RESET}"
}

# ======================================================================
#  MAIN
# ======================================================================
# 1) Load config file first (so CLI flags can override)
if [[ -n "$CONFIG_FILE" ]]; then
  load_config_file "$CONFIG_FILE"
fi

# 2) gh and auth
ensure_gh
ensure_auth

# 3) Decide whether to run wizard
NEED_WIZ="false"
if [[ "$INTERACTIVE" == "true" || "$SELECT_REPO" == "true" ]]; then
  NEED_WIZ="true"
elif [[ -z "${MODE:-}" || -z "${FILE:-}" || ( -z "${REPO:-}" && -z "${ORG:-}" ) ]]; then
  NEED_WIZ="true"
fi

if [[ "$NEED_WIZ" == "true" ]]; then
  ensure_fzf_available_if_wizard
  select_mode
  select_file
  if [[ -z "$REPO" && -z "$ORG" ]] || [[ "$SELECT_REPO" == "true" ]]; then
    select_owner_and_repo
  else
    if [[ -n "$REPO" ]]; then gh repo view "$REPO" >/dev/null 2>&1 || die "Repository not accessible: $REPO"; fi
  fi
  select_scope_and_prefix
else
  # flags/config only: validate and go
  [[ -f "$FILE" ]] || die "File not found: $FILE"
  if [[ -n "$REPO" && -n "$ORG" ]]; then die "Use either --repo or --org, not both."; fi
  if [[ -n "$REPO" ]]; then gh repo view "$REPO" >/dev/null 2>&1 || die "Repository not accessible: $REPO"; fi
  # If environment selected, ignore prefix
  if [[ -n "$ENV_NAME" && -n "$PREFIX" ]]; then PREFIX=""; fi
fi

log "${CLR_BOLD}envcast v$VERSION${CLR_RESET}"
log "-> file: $(realpath "$FILE")"
[[ -n "$REPO" ]] && log "-> repo: $REPO"
[[ -n "$ORG"  ]] && log "-> org:  $ORG"
[[ -n "$ENV_NAME" ]] && log "-> environment: $ENV_NAME"
[[ -n "$PREFIX" ]] && log "-> prefix: $PREFIX"
log "-> mode: $MODE"
[[ "$DRY_RUN" == "true" ]] && log "-> dry-run: yes"

process_env_file