#!/usr/bin/env bash
# Single, side-effect-free help entry point for the shell CLI contract.
set -euo pipefail
command="${1:-}"
[[ $# -le 1 ]] || { printf 'Usage: gitwo help [COMMAND]\n' >&2; exit 2; }
case "$command" in
  ''|--help|-h)
    cat <<'EOF'
Gitwo - ticket worktrees with adapter-managed Rails environments
Usage: gitwo <command> [arguments] [options]

Workspace:
  new TYPE ISSUE [OPTIONS]       Create a numbered issue worktree (seed by default)
  new develop [OPTIONS]          Create develop-1, develop-2,... without an issue tracker
  checkout [WORKSPACE]           Change shell directory to worktree (alias: co, switch)
  base                           Change to the permanent develop worktree
  list [--json]                  List local Git worktrees (alias: ls)
  status [WORKSPACE] [--json]    Read-only Git, DB and runtime status
  up [WORKSPACE]                 Safely prepare and run Puma + Redis + Portless
  down [WORKSPACE]               Stop verified workspace-owned processes
  logs [WORKSPACE] [OPTIONS]     Read or follow service logs
  remove [WORKSPACE] [OPTIONS]   Safely remove a worktree (DBs retained by default)

Tools:
  run [WORKSPACE] MODE [ARGS]    Run Rails, Minitest, RSpec, console or Sidekiq
  setup [WORKSPACE] [OPTIONS]   Initialize Rails environment
  init [OPTIONS]                Detect project and configure Gitwo
  detect [--json]               Inspect repo/framework/workflow without changes
  workspace adopt [WORKSPACE]   Inspect/adopt an existing database
  redis MODE [WORKSPACE]        Start/stop/check workspace Redis
  open [WORKSPACE] [--print]     Open browser or print workspace URL
  env [WORKSPACE] [--json]      Show allowlisted computed runtime settings
  dump <list|inspect|create>    Manage private local PostgreSQL archives
  clean [--json]                Audit orphaned metadata; opt-in port cleanup
  repair [WORKSPACE]            Read-only recovery plan
  config <show|path|validate|init>  Inspect or create optional local gitwo.yml
  doctor [--deps]               Check installation and dependencies
  jira-init                     Set up private Jira credentials
  jira-test ISSUE               Check Jira connectivity
  --version                     Print installed version
  help [COMMAND]                Print this help or command-specific help

Run gitwo help new, gitwo help config, or gitwo <command> --help.
EOF
    ;;
  new) cat <<'EOF'
Usage: gitwo new <feature|hotfix|bugfix> ISSUE [OPTIONS]
       gitwo new develop [OPTIONS]
  --no-setup              Create Git worktree without Rails setup
  --offline               Use ticket key without contacting Jira
  --title TITLE           Override issue title (no lookup)
  --instance N            Pick an explicit sequential suffix (develop starts at 1)
  --resume                Resume matching existing worktree
  --preview               Show branch/path without creating them
  --seed | --no-seed      Set default data mode (seed is default)
  --dump=PATH             Restore a pg_dump archive under the configured dumps folder, without seeds
  --db=schema|baseline    Data bootstrap source
  --rebuild-db            Explicit managed DB rebuild with confirmation
  --test                  Run Rails smoke tests during setup
  --verbose               Stream full setup output
EOF
    ;;
  up) cat <<'EOF'
Usage: gitwo up [WORKSPACE]
Prepare/adopt a local workspace and run Puma + workspace Redis via Portless.
Existing databases are never automatically overwritten; adoption requires confirmation.
EOF
    ;;
  run) cat <<'EOF'
Usage: gitwo run [WORKSPACE] <server|test|minitest|rspec|rails|console|sidekiq> [ARGS]
  server     Run Puma + dedicated Redis
  test       Auto-select Minitest or RSpec; refuse ambiguous projects
  minitest   Rails test (Minitest) + isolated test DB and Redis
  rspec      RSpec + isolated test DB and Redis
  rails      Run Rails task with development DB and Redis
  console    Start Rails console
  sidekiq    Requires GITWO_ENABLE_SIDEKIQ=1
EOF
    ;;
  checkout|co|switch) printf 'Usage: gitwo checkout [WORKSPACE]\nChange to feature worktree; prompts if ambiguous and interactive.\n' ;;
  base) printf 'Usage: gitwo base\nChange to the configured permanent source checkout.\n' ;;
  list|ls) printf 'Usage: gitwo list [--json]\nList linked Git worktrees.\n' ;;
  down) printf 'Usage: gitwo down [WORKSPACE]\nStop verified Puma, Sidekiq, and Redis. Do not stop shared Portless.\n' ;;
  logs) cat <<'EOF'
Usage: gitwo logs [WORKSPACE] [--service=puma|rails|redis|sidekiq|all] [--lines=N] [-f|--follow]
Read only; no processes started.
EOF
    ;;
  remove) cat <<'EOF'
Usage: gitwo remove [WORKSPACE] [--dry-run] [--delete-ignored] [--delete-db]
Requires a stopped worktree with no tracked/untracked changes and typed confirmation.
--delete-ignored can erase local secrets; --delete-db additionally drops two owned DBs.
EOF
    ;;
  status) printf 'Usage: gitwo status [WORKSPACE] [--json] [--check-http]\nInspect Git, DB, provenance and runtime without mutation.\n' ;;
  config) cat <<'EOF'
Usage: gitwo config <show|path|validate|init> [--json]
  show        Display effective nonsecret config (supports --json)
  path        Print optional gitwo.yml path
  validate    Validate YAML schema and effective values
  init        Copy the example safely; never overwrite existing gitwo.yml
Optional gitwo.yml lives beside shell.zsh; gitwo init can generate it from detections.
Use project.adapter=project-rails (legacy) or rails-standard (conventional Rails).
Environment overrides take precedence. Credentials stay in private per-profile files or gh auth.
EOF
    ;;
  open) printf 'Usage: gitwo open [WORKSPACE] [--print]\nOpen browser or display workspace URL.\n' ;;
  env) printf 'Usage: gitwo env [WORKSPACE] [--json]\nShow generated Gitwo variables; secrets not shown.\n' ;;
  dump) printf 'Usage: gitwo dump <list|inspect PATH|create [WORKSPACE] [--name=LABEL]>\nPrivate local dumps; do not share unsanitized backups.\n' ;;
  clean) printf 'Usage: gitwo clean [--json] [--prune-ports=WORKSPACE]\nAudit or explicitly release orphaned port reservations.\n' ;;
  repair) printf 'Usage: gitwo repair [WORKSPACE]\nRead-only recovery plan.\n' ;;
  doctor) printf 'Usage: gitwo doctor [--deps]\nInspect installation; --deps checks toolchain and Portless TLS.\n' ;;
  init) cat <<'EOF'
Usage: gitwo init [--project=PATH] [--config=PATH] [--yes] [--dry-run] [--json]
Auto-detect Rails/PostgreSQL/Sidekiq/Redis, infer Git workflow, and propose defaults.
Without flags, reuse and validate any existing private Gitwo gitwo.yml.
--config reads and validates an existing YAML; no prompting, no secrets in YAML.
--yes is noninteractive. --dry-run previews without writes.
Legacy: gitwo init WORKSPACE --adopt-db; preferred: gitwo workspace adopt WORKSPACE --adopt-db.
EOF
    ;;
  detect) printf 'Usage: gitwo detect [--project=PATH] [--json]\nRead-only project and Git workflow detection.\n' ;;
  workspace) printf 'Usage: gitwo workspace adopt [WORKSPACE] [--adopt-db]\nVerify and adopt an existing local DB without modifying it.\n' ;;
  setup) cat <<'EOF'
Usage: gitwo setup [WORKSPACE] [--db=schema|baseline] [--seed|--no-seed] [--dump=PATH] [--rebuild-db] [--test] [--verbose]
Seeds only freshly created schema DBs. Restore only into new DB. Rebuild requires explicit confirmation.
EOF
    ;;
  redis) printf 'Usage: gitwo redis <start|stop|status> [WORKSPACE]\nManage dedicated Redis processes.\n' ;;
  jira-init) printf 'Usage: gitwo jira-init [--no-edit]\nCreate or edit local private Jira credentials.\n' ;;
  jira-test) printf 'Usage: gitwo jira-test ISSUE\nVerify Jira credentials and inspect issue.\n' ;;
  version|--version) printf 'Usage: gitwo --version\nPrint the installed Gitwo version.\n' ;;
  *) printf 'gitwo: unknown help topic: %s\n' "$command" >&2; exit 2 ;;
esac
