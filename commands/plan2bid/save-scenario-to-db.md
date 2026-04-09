---
description: "Save scenario results to Supabase — writes re-priced line items to scenario mirror tables. Run after /plan2bid:scenarios completes."
argument-hint: "[scenario_id] [project_id]"
---

# Save Scenario to Database — /plan2bid:save-scenario-to-db

Save the current scenario results to the Plan2Bid database.

## Steps

1. Verify `./scenario_output.json` exists in the current working directory
2. Parse arguments: first argument is the scenario_id, second is the project_id
3. Run the save script:

```bash
python ~/Desktop/CODEBASES/estim8r/plan2bid-worker/save_scenario.py --input ./scenario_output.json --scenario-id {first_arg} --project-id {second_arg}
```

4. Check the output for success or errors
5. Report the result

If the script fails, read the error output and report it.
