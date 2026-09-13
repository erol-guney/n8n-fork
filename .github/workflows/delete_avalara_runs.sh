#!/bin/zsh

REPO="erol-guney/n8n-fork"
AVALARA_WORKFLOW_NAME="Avalara"
PAGE=1
PER_PAGE=100
DELETED=0

echo "=== STEP 1: Disabling all workflows except '$AVALARA_WORKFLOW_NAME' ==="

# Get all workflows
WORKFLOWS=$(gh api "repos/$REPO/actions/workflows" --jq '.workflows[] | "\(.id)|\(.name)|\(.state)"' 2>/dev/null)

if [ -n "$WORKFLOWS" ]; then
  DISABLED_COUNT=0
  SKIPPED_COUNT=0

  # Process each workflow
  while IFS='|' read -r workflow_id workflow_name workflow_state; do
    # Skip Avalara workflow
    if [ "$workflow_name" = "$AVALARA_WORKFLOW_NAME" ]; then
      echo "⏭️  Skipping '$workflow_name' (Avalara workflow)"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue
    fi
    
    # Check current state
    if [ "$workflow_state" = "disabled_manually" ]; then
      echo "✓ '$workflow_name' is already disabled"
      continue
    fi
    
    # Disable the workflow
    echo "🔒 Disabling '$workflow_name' (ID: $workflow_id)..."
    if gh api -X PUT "repos/$REPO/actions/workflows/$workflow_id/disable" --silent 2>/dev/null; then
      DISABLED_COUNT=$((DISABLED_COUNT + 1))
      echo "✓ Disabled '$workflow_name'"
    else
      echo "✗ Failed to disable '$workflow_name'"
    fi
    
    # Small delay to avoid rate limiting
    sleep 0.5
  done <<< "$WORKFLOWS"

  echo "✅ Disabled $DISABLED_COUNT workflows"
  echo "⏭️  Skipped $SKIPPED_COUNT workflows (including Avalara)"
else
  echo "⚠️  Could not fetch workflows (may not have permissions or workflows don't exist)"
fi

echo ""
echo "=== STEP 2: Deleting all workflow runs ==="
echo "Fetching all workflow run IDs..."

# Get all run IDs
while true; do
  # Get all runs from current page
  RUNS=$(gh api "repos/$REPO/actions/runs?per_page=$PER_PAGE&page=$PAGE" --jq ".workflow_runs[] | .id" 2>/dev/null)
  
  # If no runs found, we're done
  if [ -z "$RUNS" ] || [ "$RUNS" = "" ]; then
    break
  fi
  
  # Process each run (use array to avoid subshell issues)
  RUN_COUNT=0
  # Split RUNS into array by newlines
  run_ids=(${(f)RUNS})
  
  for run_id in "${run_ids[@]}"; do
    if [ -n "$run_id" ] && [ "$run_id" != "" ]; then
      # Get workflow name for this run
      WORKFLOW_NAME=$(gh api "repos/$REPO/actions/runs/$run_id" --jq -r '.name' 2>/dev/null)
      
      # Check run status
      RUN_STATUS=$(gh api "repos/$REPO/actions/runs/$run_id" --jq -r '.status' 2>/dev/null)
      
      # Cancel if in progress or queued
      if [ "$RUN_STATUS" = "in_progress" ] || [ "$RUN_STATUS" = "queued" ]; then
        echo "Cancelling $RUN_STATUS run $run_id ($WORKFLOW_NAME)..."
        gh run cancel "$run_id" --repo "$REPO" --silent 2>/dev/null
        # Wait a moment for cancellation to take effect
        sleep 1
      fi
      
      echo "Deleting run $run_id ($WORKFLOW_NAME)..."
      if gh api -X DELETE "repos/$REPO/actions/runs/$run_id" --silent 2>/dev/null; then
        DELETED=$((DELETED + 1))
        RUN_COUNT=$((RUN_COUNT + 1))
        echo "✓ Deleted run $run_id ($WORKFLOW_NAME) (Total: $DELETED)"
      else
        echo "✗ Failed to delete run $run_id ($WORKFLOW_NAME) (may need to wait for cancellation)"
      fi
      # Small delay to avoid rate limiting
      sleep 0.5
    fi
  done
  
  # If no runs were found on this page, we're done
  if [ "$RUN_COUNT" -eq 0 ]; then
    break
  fi
  
  # Move to next page
  PAGE=$((PAGE + 1))
done

echo ""
echo "=== SUMMARY ==="
echo "Deletion complete! Deleted $DELETED runs."
echo ""
echo "ℹ️  Only the '$AVALARA_WORKFLOW_NAME' workflow is enabled"
echo "To re-enable a workflow, go to GitHub Actions settings or use:"
echo "  gh workflow enable <workflow-id> --repo $REPO"

