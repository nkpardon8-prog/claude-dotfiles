---
description: "Save scenario results to Supabase — writes re-priced line items to scenario mirror tables. Run after /plan2bid:scenarios completes."
argument-hint: "[scenario_id] [project_id]"
---

# Save Scenario to Database — /plan2bid:save-scenario-to-db

Save the current scenario results to the Plan2Bid database.

## Steps

1. Verify `./scenario_output.json` exists in the current working directory. Resolve it to an absolute path.
2. Parse arguments: first argument is the scenario_id, second is the project_id
3. Find the worker directory. Check these paths in order and use the first one that exists:
   - `$WORKER_DIR` environment variable (if set)
   - `~/plan2bid-worker`
   - `~/workermacmini`
   - `~/Desktop/CODEBASES/estim8r/plan2bid-worker`
4. Run the save script (activate venv first, use `python3`):

```bash
cd {worker_dir} && source .venv/bin/activate 2>/dev/null; python3 save_scenario.py --input {absolute path to scenario_output.json} --scenario-id {first_arg} --project-id {second_arg}
```

5. Check the output for success or errors
6. Report the result

If the script fails with a format error (e.g., "No line_items found"):
1. Read save_scenario.py to understand the expected schema
2. Reformat scenario_output.json to match — ensure `line_items` is a flat top-level array
3. Run the save command again

If it fails with a database error, report the error — do not retry.
