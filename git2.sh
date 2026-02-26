#!/bin/bash
#
# git2.sh - Large git repository change management tool
#
# Commands:
#   git2 init   - Create .git2 folder, move git2.sh, apply set (in original repo)
#   git2 start  - Move cloned content to .git2, apply get (after cloning my repo)
#   git2 set    - Save current git config to .git2/.git2config
#   git2 get    - Restore git config from .git2/.git2config to current folder
#   git2 push   - Sync current folder -> .git2 (add/modify/delete)
#   git2 pull   - Sync .git2 -> current folder (add/modify)
#

set -e

# Auto-detect project root
# Case 1: running from inside .git2 (cwd is .git2)
# Case 2: running from project root (cwd has .git2/)
# Case 3: script is in .git2/ but cwd is elsewhere
if [[ "$(basename "$(pwd)")" == ".git2" ]]; then
    cd ..
elif [[ ! -d ".git2" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ "$(basename "$SCRIPT_DIR")" == ".git2" ]]; then
        cd "$(dirname "$SCRIPT_DIR")"
    fi
fi

GIT2_DIR=".git2"
GIT2_CONFIG="$GIT2_DIR/.git2config"
GIT2_REMOVED="$GIT2_DIR/.git2removed"

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_help() {
    cat << 'EOF'
git2 - Large git repository change management tool

Usage:
  git2 init    Create .git2 folder, move git2.sh, apply set (in original repo)
  git2 start   Move cloned content to .git2, apply get (after cloning my repo)
  git2 set     Save current git config to .git2/.git2config
  git2 get     Restore git config from .git2/.git2config to current folder
  git2 push    Sync current folder -> .git2 (add/modify/delete)
  git2 pull    Sync .git2 -> current folder (add/modify)
  git2 help    Show this help message

Note: git2 can be run from either the project folder or the .git2 folder.
      If run from .git2, it automatically switches to the parent folder.

Workflow (initial setup in original repo):
  1. git clone <original-repo>
  2. cp /path/to/git2.sh .
  3. git2 init               # Create .git2, move git2.sh, save config
  4. Make code changes
  5. git2 push               # Sync only changed files to .git2/
  6. cd .git2 && git init && git remote add origin <my-repo>
  7. git add . && git commit && git push

Workflow (after cloning my repo):
  1. git clone <my-repo>      # Get .git2config, git2.sh, changed files
  2. git2 start              # Auto: create .git2, clone original, apply changes
  3. Start working
EOF
}

# set: Save current git config to .git2/git2config
cmd_set() {
    if [[ ! -d "$GIT2_DIR" ]]; then
        log_error ".git2 folder does not exist."
        return 1
    fi

    if [[ ! -d ".git" ]]; then
        log_error ".git folder does not exist."
        return 1
    fi

    log_info "Saving git config to .git2/.git2config..."

    local current_commit=$(git rev-parse HEAD 2>/dev/null)

    # Check current state: tag, branch, or detached HEAD
    local ref_type=""
    local ref_name=""
    local ref_remote=""

    # Check if tag
    local tag_name=$(git describe --tags --exact-match 2>/dev/null)
    if [[ -n "$tag_name" ]]; then
        ref_type="tag"
        ref_name="$tag_name"
    else
        # Check if branch
        local branch_name=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [[ "$branch_name" != "HEAD" ]]; then
            ref_type="branch"
            ref_name="$branch_name"
            # Check tracking remote
            ref_remote=$(git config --get "branch.${branch_name}.remote" 2>/dev/null || echo "origin")
        else
            # detached HEAD - treat as commit
            ref_type="commit"
            ref_name="$current_commit"
        fi
    fi

    {
        echo "# git2 config file"
        echo "# Created: $(date -Iseconds)"
        echo ""

        # Save all remotes
        echo "# remotes (name=url)"
        git remote -v | grep fetch | while read -r name url _; do
            echo "REMOTE['$name']='$url'"
        done
        echo ""

        echo "# Current ref info"
        echo "REF_TYPE='$ref_type'"
        echo "REF_NAME='$ref_name'"
        echo "REF_REMOTE='$ref_remote'"
        echo ""

        echo "# HEAD commit"
        echo "COMMIT='$current_commit'"

    } > "$GIT2_CONFIG"

    chmod +x "$GIT2_CONFIG"
    log_success "Git config saved ($GIT2_CONFIG)"
    log_info "  Type: $ref_type"
    log_info "  Name: $ref_name"
    [[ -n "$ref_remote" ]] && log_info "  Remote: $ref_remote"
    log_info "  Commit: $current_commit"
}

# get: Read git config from .git2/.git2config and apply to current folder
cmd_get() {
    if [[ ! -d "$GIT2_DIR" ]]; then
        log_error ".git2 folder does not exist."
        return 1
    fi

    if [[ ! -f "$GIT2_CONFIG" ]]; then
        log_error "Git config file does not exist. ($GIT2_CONFIG)"
        return 1
    fi

    log_info "Applying git config..."

    # Read values from config file
    local REF_TYPE=$(grep "^REF_TYPE=" "$GIT2_CONFIG" | cut -d"'" -f2)
    local REF_NAME=$(grep "^REF_NAME=" "$GIT2_CONFIG" | cut -d"'" -f2)
    local REF_REMOTE=$(grep "^REF_REMOTE=" "$GIT2_CONFIG" | cut -d"'" -f2)
    local COMMIT=$(grep "^COMMIT=" "$GIT2_CONFIG" | cut -d"'" -f2)

    # Backward compatibility: support old format (BRANCH)
    if [[ -z "$REF_TYPE" ]]; then
        local BRANCH=$(grep "^BRANCH=" "$GIT2_CONFIG" | cut -d"'" -f2)
        if [[ -n "$BRANCH" ]]; then
            REF_TYPE="branch"
            REF_NAME="$BRANCH"
            REF_REMOTE="origin"
        fi
    fi

    # Parse remotes (using temp file)
    local tmp_remotes=$(mktemp)
    trap "rm -f '$tmp_remotes'" EXIT

    while IFS= read -r line; do
        if [[ "$line" =~ ^REMOTE\[\'([^\']+)\'\]=\'([^\']+)\' ]]; then
            echo "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}" >> "$tmp_remotes"
        fi
    done < "$GIT2_CONFIG"

    if [[ ! -s "$tmp_remotes" ]]; then
        log_error "Remote URL is not configured."
        return 1
    fi

    # Delete existing .git and start fresh
    # Handle symlink case (repo sync) - reinitialize target folder
    if [[ -L ".git" ]]; then
        local git_target=$(readlink -f ".git")
        log_info "Reinitializing .git symlink target..."
        rm -rf "$git_target"/*
        rm -rf "$git_target"/.[!.]*
        git init
    elif [[ -d ".git" ]]; then
        log_info "Removing existing .git folder..."
        rm -rf ".git"
        git init
    else
        git init
    fi
    log_success "git init complete"

    # Configure all remotes
    while IFS='=' read -r name url; do
        git remote add "$name" "$url"
        log_info "Remote configured: $name -> $url"
    done < "$tmp_remotes"

    # fetch
    log_info "Running git fetch..."
    git fetch --all --tags

    # checkout (handle based on REF_TYPE)
    case "$REF_TYPE" in
        tag)
            log_info "Checkout tag: $REF_NAME"
            git checkout "tags/$REF_NAME"
            ;;
        branch)
            log_info "Checkout branch: $REF_REMOTE/$REF_NAME"
            git checkout -b "$REF_NAME" "$REF_REMOTE/$REF_NAME" 2>/dev/null || \
                git checkout "$REF_NAME"
            # Set branch tracking
            git branch --set-upstream-to="$REF_REMOTE/$REF_NAME" "$REF_NAME" 2>/dev/null || true
            ;;
        commit|*)
            log_info "Checkout commit: $COMMIT"
            git checkout "$COMMIT"
            ;;
    esac

    log_success "Git config applied"
}

# init: Create .git2 folder, move git2.sh, apply set (in original repo)
cmd_init() {
    if [[ -d "$GIT2_DIR" ]]; then
        log_warn ".git2 folder already exists."
        return 1
    fi

    if [[ ! -d ".git" ]]; then
        log_error ".git folder does not exist. Run in a git repo."
        return 1
    fi

    log_info "Creating .git2 folder..."
    mkdir -p "$GIT2_DIR"

    # Move git2.sh into .git2
    if [[ -f "git2.sh" ]]; then
        mv "git2.sh" "$GIT2_DIR/git2.sh"
        log_info "git2.sh moved to .git2/"
    fi

    # Apply set (save current git config)
    cmd_set

    # Create empty .git2removed file
    touch "$GIT2_REMOVED"
    log_info ".git2removed created"

    # Create .find-ignore to exclude .git2 from Android build
    touch "$GIT2_DIR/.find-ignore"
    log_info ".find-ignore created (excludes .git2 from Android build)"

    log_success "git2 init complete"
}

# start: Move cloned content to .git2, apply get (after cloning my repo)
cmd_start() {
    # After clone, we have .git (my repo) and changed files
    # Create .git2 folder and move current content

    if [[ -d "$GIT2_DIR" ]]; then
        log_error ".git2 folder already exists."
        return 1
    fi

    if [[ ! -f ".git2config" ]] && [[ ! -f "git2.sh" ]]; then
        log_error "git2 related files not found. Check if this is the correct repo."
        return 1
    fi

    log_info "Creating .git2 folder and moving content..."
    mkdir -p "$GIT2_DIR"

    # Handle .git separately (symlink vs folder)
    if [[ -L ".git" ]]; then
        # .git is symlink (repo sync case)
        # Copy target contents to .git2/.git (preserve for custom repo info)
        # Keep symlink and target intact for repo sync
        # Use -L to dereference symlinks (objects, hooks, rr-cache)
        local git_target=$(readlink -f ".git")
        mkdir -p "$GIT2_DIR/.git"
        cp -aL "$git_target"/. "$GIT2_DIR/.git/"
        log_info ".git symlink target contents copied to .git2/.git"
    elif [[ -d ".git" ]]; then
        # .git is real folder
        mv ".git" "$GIT2_DIR/"
        log_info ".git moved to .git2/"
    fi

    # Move all other content to .git2
    for item in * .[!.]* ..?*; do
        [[ ! -e "$item" ]] && continue
        [[ "$item" == ".git2" ]] && continue
        [[ "$item" == ".git" ]] && continue

        mv "$item" "$GIT2_DIR/"
    done

    log_info "Content moved"

    # Create .find-ignore to exclude .git2 from Android build
    touch "$GIT2_DIR/.find-ignore"

    # Apply get (clone original git + checkout)
    cmd_get

    # Apply pull (overwrite with changes)
    cmd_pull

    log_success "git2 start complete"
}

# push: Sync only changed files from git to .git2
cmd_push() {
    if [[ ! -d "$GIT2_DIR" ]]; then
        log_error ".git2 folder does not exist."
        return 1
    fi

    if [[ ! -d ".git" ]]; then
        log_error ".git folder does not exist."
        return 1
    fi

    log_info "Syncing changed files to .git2..."

    # Save changed file list to temp files
    local tmp_changed=$(mktemp)
    local tmp_deleted=$(mktemp)
    trap "rm -f '$tmp_changed' '$tmp_deleted'" EXIT

    # Classify changed files using git status
    while IFS= read -r line; do
        local status="${line:0:2}"
        local file="${line:3}"
        file=$(echo "$file" | sed 's/^ *//' | sed 's/ *$//')

        [[ "$file" == "git2.sh" ]] && continue
        [[ "$file" == ".git2"* ]] && continue
        [[ "$file" == ".find-ignore" ]] && continue

        case "$status" in
            " M"|"M "|"MM"|"AM"|" A"|"A "|"??")
                if [[ -f "$file" ]]; then
                    echo "$file" >> "$tmp_changed"
                    local dir=$(dirname "$file")
                    mkdir -p "$GIT2_DIR/$dir"
                    cp "$file" "$GIT2_DIR/$file"
                    echo -e "${GREEN}Added:${NC} $file"
                fi
                ;;
            " D"|"D ")
                echo "$file" >> "$tmp_deleted"
                if [[ -f "$GIT2_DIR/$file" ]]; then
                    rm "$GIT2_DIR/$file"
                fi
                echo -e "${RED}Deleted:${NC} $file"
                ;;
        esac
    done < <(git status --porcelain 2>/dev/null)

    # Delete files in .git2 that are no longer changed (reverted to original)
    while IFS= read -r file; do
        local rel_path="${file#$GIT2_DIR/}"

        # Check if in changed file list
        if ! grep -qxF "$rel_path" "$tmp_changed" 2>/dev/null; then
            rm "$file"
            echo -e "${YELLOW}Removed:${NC} $rel_path (reverted to original)"
        fi
    done < <(find "$GIT2_DIR" -type f \
        ! -path "$GIT2_DIR/.git/*" \
        ! -name ".git2config" \
        ! -name ".git2removed" \
        ! -name ".find-ignore" \
        ! -name "git2.sh" \
        2>/dev/null)

    # Update .git2removed (deleted file list - cumulative)
    # Add newly deleted files to existing delete list
    if [[ -s "$tmp_deleted" ]]; then
        if [[ -f "$GIT2_REMOVED" ]]; then
            # Merge while removing duplicates
            cat "$GIT2_REMOVED" "$tmp_deleted" | sort -u > "${GIT2_REMOVED}.tmp"
            mv "${GIT2_REMOVED}.tmp" "$GIT2_REMOVED"
        else
            cp "$tmp_deleted" "$GIT2_REMOVED"
        fi
    fi

    # Remove re-added files from delete list
    if [[ -f "$GIT2_REMOVED" ]] && [[ -s "$tmp_changed" ]]; then
        grep -vxFf "$tmp_changed" "$GIT2_REMOVED" > "${GIT2_REMOVED}.tmp" 2>/dev/null || true
        mv "${GIT2_REMOVED}.tmp" "$GIT2_REMOVED"
    fi

    # Delete file if delete list is empty
    if [[ -f "$GIT2_REMOVED" ]] && [[ ! -s "$GIT2_REMOVED" ]]; then
        rm -f "$GIT2_REMOVED"
    fi

    # Clean up empty directories
    find "$GIT2_DIR" -type d -empty ! -path "$GIT2_DIR/.git/*" -delete 2>/dev/null || true

    log_success "git2 push complete"
}

# pull: Sync changed files from .git2 to current folder
cmd_pull() {
    if [[ ! -d "$GIT2_DIR" ]]; then
        log_error ".git2 folder does not exist."
        return 1
    fi

    log_info "Syncing changed files from .git2 to current folder..."

    # 1. Copy files from .git2 -> current folder (new/modified)
    while IFS= read -r file; do
        local rel_path="${file#$GIT2_DIR/}"

        # Copy if file doesn't exist or is different
        if [[ ! -f "$rel_path" ]]; then
            mkdir -p "$(dirname "$rel_path")"
            cp "$file" "$rel_path"
            echo -e "${GREEN}Added:${NC} $rel_path"
        elif ! cmp -s "$file" "$rel_path"; then
            cp "$file" "$rel_path"
            echo -e "${YELLOW}Modified:${NC} $rel_path"
        fi
    done < <(find "$GIT2_DIR" -type f \
        ! -path "$GIT2_DIR/.git/*" \
        ! -name ".git2config" \
        ! -name ".git2removed" \
        ! -name ".find-ignore" \
        ! -name "git2.sh" \
        2>/dev/null)

    # 2. Delete files recorded in .git2removed
    if [[ -f "$GIT2_REMOVED" ]]; then
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            if [[ -f "$file" ]]; then
                rm "$file"
                echo -e "${RED}Deleted:${NC} $file"
            fi
        done < "$GIT2_REMOVED"

        # Clean up empty directories
        find . -type d -empty ! -path "./.git/*" ! -path "./.git2/*" -delete 2>/dev/null || true
    fi

    log_success "git2 pull complete"
}

# Main
main() {
    local cmd="${1:-}"
    shift || true

    case "$cmd" in
        init)   cmd_init "$@" ;;
        start)  cmd_start "$@" ;;
        set)    cmd_set "$@" ;;
        get)    cmd_get "$@" ;;
        push)   cmd_push "$@" ;;
        pull)   cmd_pull "$@" ;;
        help|--help|-h) show_help ;;
        "")     show_help ;;
        *)
            log_error "Unknown command: $cmd"
            echo ""
            show_help
            ;;
    esac
}

main "$@"
