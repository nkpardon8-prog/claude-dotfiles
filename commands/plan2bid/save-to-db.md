---
description: "Save estimation results to Supabase — writes line items, metadata, anomalies to the database. Run after /plan2bid:run completes."
argument-hint: "[project_id]"
---

# Save Estimation to Database — /plan2bid:save-to-db

Save the current estimate to the Plan2Bid database. This skill writes structured estimation data to the Supabase tables that the web frontend reads from.

## Steps

1. Verify `./estimate_output.json` exists in the current working directory
2. Run the save script:

```bash
python ~/Desktop/CODEBASES/estim8r/plan2bid-worker/save_estimate.py --input ./estimate_output.json --project-id $ARGUMENTS
```

3. Check the output for success or errors
4. Report the result: total estimate amount, number of line items, trades processed

If the script fails, read the error output and report it. Do not attempt to fix the JSON or retry — the estimation data must be preserved as-is.
