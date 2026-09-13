#!/usr/bin/env zsh

# Script to run build_avalara_release job steps locally
# Mirrors the build_avalara_release job in .github/workflows/avalara.yml
#
# Usage: ./scripts/run-avalara-actions-local.sh \
#          [--skip-push] [--skip-build] [--skip-tests] [--skip-cleanup-runs]

set -e

SKIP_PUSH=false
SKIP_BUILD=false
SKIP_TESTS=false
SKIP_CLEANUP_RUNS=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-push)
      SKIP_PUSH=true
      shift
      ;;
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    --skip-tests)
      SKIP_TESTS=true
      shift
      ;;
    --skip-cleanup-runs)
      SKIP_CLEANUP_RUNS=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--skip-push] [--skip-build] [--skip-tests] [--skip-cleanup-runs]"
      exit 1
      ;;
  esac
done

echo "=== Running build_avalara_release job locally ==="
echo ""

# Step 1: Configure Git user (use current config if already set)
echo "Step 1: Configuring Git user..."
if [ -z "$(git config user.name)" ]; then
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  echo "  Git user configured"
else
  echo "  Using existing Git user: $(git config user.name)"
fi

# Step 2: Refresh avalara-release from latest upstream release/2.X.X
echo ""
echo "Step 2: Refreshing avalara-release from latest upstream release/2.X.X..."

# Add upstream remote if it doesn't exist
if ! git remote get-url upstream >/dev/null 2>&1; then
  echo "  Adding upstream remote..."
  git remote add upstream https://github.com/n8n-io/n8n.git
fi

git fetch --all

echo "  Discovering latest upstream release/2.X.X branch..."
LATEST_RELEASE_BRANCH=$(git ls-remote --refs upstream 'refs/heads/release/2.*' \
  | awk '{print $2}' \
  | sed 's|refs/heads/||' \
  | sort -V \
  | tail -1)

if [ -z "$LATEST_RELEASE_BRANCH" ]; then
  echo "ERROR: No upstream release/2.X.X branches found"
  exit 1
fi

echo "  Latest upstream release branch: $LATEST_RELEASE_BRANCH"

# Fetch only the chosen release branch (and master, used for the avalara delta)
git fetch upstream master "$LATEST_RELEASE_BRANCH":"refs/remotes/upstream/$LATEST_RELEASE_BRANCH"

# Check if avalara-release branch exists (informational)
if git show-ref --verify --quiet refs/remotes/origin/avalara-release 2>/dev/null; then
  echo "  Remote avalara-release branch exists"
else
  echo "  Remote avalara-release branch does not exist, will create it from upstream/$LATEST_RELEASE_BRANCH"
fi

echo "  Resetting avalara-release to upstream/$LATEST_RELEASE_BRANCH..."
git checkout -B avalara-release "upstream/$LATEST_RELEASE_BRANCH"
git reset --hard "upstream/$LATEST_RELEASE_BRANCH"
git clean -fd

echo "  Successfully reset avalara-release to upstream/$LATEST_RELEASE_BRANCH"

# Step 3: Port avalara feature delta from avalara-dev
echo ""
echo "Step 3: Porting avalara feature delta from avalara-dev..."
git fetch origin avalara-dev
git fetch upstream master  # base for the avalara delta

# avalara-dev = upstream/master + avalara feature changes.
# The diff between them is the precise avalara delta.
# Apply that diff as a patch (with 3-way merge) onto the release branch
# so only avalara additions land here, without dragging in unrelated
# master-side context. Dependency manifests are excluded so release
# branch deps stay intact.
PATCH="${TMPDIR:-/tmp}/avalara-feature.patch"
git diff upstream/master..origin/avalara-dev \
  -- ':(exclude)package.json' \
     ':(exclude)pnpm-lock.yaml' \
     ':(exclude)**/package.json' \
     ':(exclude)*.lock' \
  > "$PATCH"

if [ ! -s "$PATCH" ]; then
  echo "  No avalara feature delta to apply; nothing to do."
  rm -f "$PATCH"
else
  echo "  Patch summary:"
  git apply --stat "$PATCH"

  # 3-way merge resolves context drift between upstream/master
  # (the base avalara-dev was authored on) and the release branch.
  #
  # Some files deleted in avalara-dev vs master may never have existed on the
  # release branch. Exclude them from apply — the file is already absent, so
  # skipping the deletion produces the same end state.
  APPLY_ARGS=(--3way --whitespace=fix)
  DELETED_IN_PATCH=$(awk '/^diff --git/{f=$3; sub(/^a\//,"",f)} /^deleted file mode/{print f}' "$PATCH")
  if [ -n "$DELETED_IN_PATCH" ]; then
    while IFS= read -r f; do
      if ! git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
        echo "  Skipping deletion of file absent from release branch: $f"
        APPLY_ARGS+=(--exclude="$f")
      fi
    done <<< "$DELETED_IN_PATCH"
  fi

  if ! git apply "${APPLY_ARGS[@]}" "$PATCH"; then
    echo "ERROR: avalara feature port failed to apply cleanly on release branch."
    echo "Working tree status:"
    git status
    echo "Whitespace/conflict check:"
    git diff --check || true
    rm -f "$PATCH"
    exit 1
  fi

  rm -f "$PATCH"

  git add -A
  if git diff --cached --quiet; then
    echo "  Patch produced no changes; skipping commit."
  else
    git commit -m "feat: apply avalara feature changes from avalara-dev"
    echo "  Committed avalara feature delta to avalara-release."
  fi
fi

# Step 4: Setup and Build
if [ "$SKIP_BUILD" = false ]; then
  echo ""
  echo "Step 4: Setting up and building..."
  if ! command -v pnpm > /dev/null 2>&1; then
    echo "ERROR: pnpm is not installed. Please install pnpm first."
    exit 1
  fi
  echo "  Installing dependencies..."
  if ! pnpm install --frozen-lockfile 2>&1 | tee /tmp/pnpm-install.log; then
    if grep -q "ERR_PNPM_OUTDATED_LOCKFILE\|ERR_PNPM_LOCKFILE_CONFIG_MISMATCH" /tmp/pnpm-install.log; then
      echo "  Lockfile is outdated, regenerating it..."
      pnpm install --no-frozen-lockfile
      echo "  Lockfile regenerated successfully"
    else
      echo "ERROR: pnpm install failed. Check the error above."
      cat /tmp/pnpm-install.log
      exit 1
    fi
  fi
  echo "  Building..."
  pnpm build > build.log 2>&1 || {
    echo "ERROR: Build failed. Check build.log for details."
    tail -n 50 build.log
    exit 1
  }
  echo "  Build completed successfully"
else
  echo ""
  echo "Step 4: Skipping build (--skip-build flag set)"
fi

# Step 5: Run unit tests
if [ "$SKIP_TESTS" = false ]; then
  echo ""
  echo "Step 5: Running unit tests..."
  pnpm --filter @n8n/config test:unit
  pnpm --filter n8n test:unit -- \
    src/workflows/__tests__/workflow-validation.service.test.ts \
    src/workflows/__tests__/workflows.controller.test.ts
  pnpm --filter n8n-core test:unit -- \
    src/execution-engine/__tests__/scheduled-task-manager.test.ts
  echo "  Unit tests completed successfully"
else
  echo ""
  echo "Step 5: Skipping unit tests (--skip-tests flag set)"
fi

# Step 6: Verify avalara environment variables
echo ""
echo "Step 6: Verifying avalara environment variables..."
echo "=== AVALARA ENVIRONMENT VARIABLES VERIFICATION ==="
echo "Verifying avalara environment variables in current branch (avalara-release)"

echo " Checking for required environment variables..."

ERROR_COUNT=0

if git grep -q "N8N_MIN_SCHEDULE_INTERVAL_SECONDS"; then
  echo " Found: N8N_MIN_SCHEDULE_INTERVAL_SECONDS environment variable"
else
  echo " Missing: N8N_MIN_SCHEDULE_INTERVAL_SECONDS environment variable"
  ERROR_COUNT=$((ERROR_COUNT + 1))
fi

echo " Environment variable definitions found:"
git grep -n "N8N_MIN_SCHEDULE_INTERVAL_SECONDS" | head -10 || echo "  No environment variables found"

echo ""
echo " VERIFICATION SUMMARY:"
echo "  - Errors found: $ERROR_COUNT"

if [ $ERROR_COUNT -eq 0 ]; then
  echo " AVALARA ENVIRONMENT VARIABLES VERIFICATION PASSED - All required environment variables are present!"
else
  echo " AVALARA ENVIRONMENT VARIABLES VERIFICATION FAILED - $ERROR_COUNT errors found!"
  echo ""
  echo "The avalara-release branch is missing required environment variables."
  echo "Cannot push without avalara features. Aborting push."
  exit 1
fi

# Step 7: Verify package.json version matches upstream release branch
echo ""
echo "Step 7: Verifying package.json version matches upstream/$LATEST_RELEASE_BRANCH..."
echo "=== PACKAGE.JSON VERSION VERIFICATION ==="
echo "Verifying package.json version consistency with upstream/$LATEST_RELEASE_BRANCH"

git fetch upstream "$LATEST_RELEASE_BRANCH":"refs/remotes/upstream/$LATEST_RELEASE_BRANCH"

echo "Extracting version from avalara-release package.json..."
AVALARA_RELEASE_VERSION=$(git show "HEAD:package.json" | grep '"version"' | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/')

echo "Extracting version from upstream/$LATEST_RELEASE_BRANCH package.json..."
RELEASE_VERSION=$(git show "upstream/$LATEST_RELEASE_BRANCH:package.json" | grep '"version"' | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/')

echo "avalara-release version: $AVALARA_RELEASE_VERSION"
echo "upstream/$LATEST_RELEASE_BRANCH version: $RELEASE_VERSION"

if [ "$AVALARA_RELEASE_VERSION" = "$RELEASE_VERSION" ]; then
  echo "VERSION MATCH: avalara-release version ($AVALARA_RELEASE_VERSION) matches upstream/$LATEST_RELEASE_BRANCH version ($RELEASE_VERSION)"
  echo "PACKAGE.JSON VERSION VERIFICATION PASSED - Versions are consistent!"
else
  echo "VERSION MISMATCH: avalara-release version ($AVALARA_RELEASE_VERSION) does not match upstream/$LATEST_RELEASE_BRANCH version ($RELEASE_VERSION)"
  echo ""
  echo "The avalara-release branch has a different package.json version than upstream/$LATEST_RELEASE_BRANCH."
  echo "This indicates the refresh process may not have completed correctly."
  exit 1
fi

# Step 8: Push (optional, prompts for confirmation)
if [ "$SKIP_PUSH" = false ]; then
  echo ""
  echo "Step 8: Pushing refreshed avalara-release branch..."
  read -k 1 "REPLY?Do you want to push the avalara-release branch to origin? (y/N): "
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    if ! git push origin avalara-release --force; then
      echo "ERROR: Failed to push avalara-release to origin. Check permissions and network connectivity."
      exit 1
    fi
    echo "Successfully pushed refreshed avalara-release branch"
  else
    echo "Skipping push (user cancelled)"
  fi
else
  echo ""
  echo "Step 8: Skipping push (--skip-push flag set)"
fi

# Step 9: Cleanup old Avalara workflow runs on GitHub Actions (optional)
if [ "$SKIP_CLEANUP_RUNS" = false ]; then
  echo ""
  echo "Step 9: Cleaning up old Avalara workflow runs on GitHub Actions..."

  if ! command -v gh > /dev/null 2>&1; then
    echo "  WARNING: gh CLI is not installed. Skipping workflow run cleanup."
  else
    # Resolve repo (owner/name) from origin remote
    ORIGIN_URL=$(git remote get-url origin 2>/dev/null || true)
    REPO=$(echo "$ORIGIN_URL" | sed -E 's#(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')

    if [ -z "$REPO" ]; then
      echo "  WARNING: Could not determine origin repository. Skipping cleanup."
    else
      echo "  Looking up Avalara workflow in $REPO..."
      WORKFLOW_ID=$(gh api -X GET "/repos/$REPO/actions/workflows" --paginate --jq '.workflows[] | select(.name == "Avalara" or (.path | endswith("/avalara.yml"))) | .id' | head -1)

      if [ -z "$WORKFLOW_ID" ]; then
        echo "  WARNING: Could not find Avalara workflow on $REPO. Skipping cleanup."
      else
        TOTAL_COUNT=$(gh api -X GET "/repos/$REPO/actions/workflows/$WORKFLOW_ID/runs" -f per_page=1 --jq '.total_count')
        echo "  Found Avalara workflow (id: $WORKFLOW_ID) with $TOTAL_COUNT runs"

        if [ "$TOTAL_COUNT" -eq 0 ]; then
          echo "  No runs to delete"
        else
          read -k 1 "REPLY?Delete all $TOTAL_COUNT Avalara workflow runs? (y/N): "
          echo
          if [[ $REPLY =~ ^[Yy]$ ]]; then
            TOTAL_DELETED=0
            while true; do
              RUN_IDS=$(gh api -X GET "/repos/$REPO/actions/workflows/$WORKFLOW_ID/runs" -f per_page=100 --jq '.workflow_runs[].id')
              if [ -z "$RUN_IDS" ]; then
                break
              fi
              COUNT=$(echo "$RUN_IDS" | wc -l | tr -d ' ')
              echo "  Deleting batch of $COUNT runs..."
              echo "$RUN_IDS" | xargs -n 1 -P 10 -I {} gh api -X DELETE "/repos/$REPO/actions/runs/{}" --silent
              TOTAL_DELETED=$((TOTAL_DELETED + COUNT))
              echo "  Progress: deleted $TOTAL_DELETED so far"
            done
            echo "  Successfully deleted $TOTAL_DELETED Avalara workflow runs"
          else
            echo "  Skipping cleanup (user cancelled)"
          fi
        fi
      fi
    fi
  fi
else
  echo ""
  echo "Step 9: Skipping workflow run cleanup (--skip-cleanup-runs flag set)"
fi

echo ""
echo "=== build_avalara_release job completed successfully ==="
