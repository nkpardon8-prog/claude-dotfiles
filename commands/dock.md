---
description: "Run a molecular docking job — identifies compound, protein target, and parameters, then executes via MoleCopilot."
argument-hint: "[compound name/SMILES + protein target PDB ID]"
---

Run a molecular docking job. Parse the user's request to identify:
1. The compound to dock (name, SMILES, or CID)
2. The protein target (PDB ID or name)
3. Any custom parameters (exhaustiveness, grid box size)

Then execute the full pipeline using MoleCopilot MCP tools:
1. Fetch and prepare the protein (if not already prepped) — use fetch_protein then prepare_protein
   (prepare_protein auto-detects binding site and returns it in result["binding_site"])
2. Fetch/prepare the ligand — use fetch_compound or prepare_ligand with SMILES
3. Use binding site coordinates from step 1's result for docking
4. Run docking with AutoDock Vina — use the dock tool with center from binding_site
5. Analyze interactions — use analyze_interactions (accepts PDBQT directly, auto-converts)
6. Run ADMET check on the compound — use admet_check
7. Generate a summary with binding energy, key interactions, and drug-likeness — use generate_report

Report the binding energy, key interactions, drug-likeness assessment, and where files were saved.

Example usage: /dock theopapuamide against HIF-2α (PDB: 3H82)
Example usage: /dock aspirin against aromatase
Example usage: /dock CC(=O)Oc1ccccc1C(=O)O against 3S7S with exhaustiveness 64
