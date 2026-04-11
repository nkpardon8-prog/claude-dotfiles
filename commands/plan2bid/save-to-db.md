---
description: "Save estimation results to Supabase — writes line items, metadata, anomalies to the database. Run after /plan2bid:run completes."
argument-hint: "[project_id]"
---

# Save Estimation to Database — /plan2bid:save-to-db

Save the current estimate to the Plan2Bid database. This skill writes structured estimation data to the Supabase tables that the web frontend reads from.

## Steps

1. Verify `./estimate_output.json` exists in the current working directory. Resolve it to an absolute path.
2. Find the worker directory. Check these paths in order and use the first one that exists:
   - `$WORKER_DIR` environment variable (if set)
   - `~/plan2bid-worker`
   - `~/workermacmini`
   - `~/Desktop/CODEBASES/estim8r/plan2bid-worker`
3. Run the save script (activate venv first, use `python3`):

```bash
cd {worker_dir} && source .venv/bin/activate 2>/dev/null; python3 save_estimate.py --input {absolute path to estimate_output.json} --project-id $ARGUMENTS
```

4. Check the output for success or errors
5. Report the result: total estimate amount, number of line items, trades processed

If the script fails with a format error (e.g., "No line_items array found"):
1. Read save_estimate.py to understand the expected schema
2. Reformat estimate_output.json to match — ensure `line_items` is a flat top-level array where each item has `is_material`, `is_labor`, `trade`, `description`, `quantity` and all required pricing fields
3. Run the save command again

If the script fails with a database or connection error, report the error — do not retry.
