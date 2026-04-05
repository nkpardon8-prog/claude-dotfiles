Optimize a docking hit into better drug candidates using NVIDIA MolMIM AI. Parse the user's request to identify:
1. The seed compound (name, SMILES, or reference to a previous docking hit)
2. The target property to optimize ("QED" for drug-likeness or "plogP" for penalized LogP, default QED)
3. Optional protein target for re-docking analogs

Pipeline using MoleCopilot MCP tools:
1. If a name is given, search PubChem — use search_compounds to get SMILES
2. Run ADMET + SA score on the seed compound first — use admet_check to establish baseline
3. Generate optimized analogs — use optimize_compound (MolMIM CMA-ES, 20 molecules)
4. Run ADMET on all generated analogs — use batch_admet (now includes SA score automatically)
5. Filter: reject any analogs with SA score > 7 (Very Difficult to synthesize)
6. If a protein target is specified, dock the top 5-10 analogs against it using the existing docking pipeline (fetch_protein, prepare_protein, prepare_ligand, dock)
7. Present a ranked comparison table showing for each analog:
   - SMILES (truncated), property score, SA score, synthetic assessment
   - Lipinski pass/fail, drug-likeness score, ADMET assessment
   - Binding energy (if docked)
   - Comparison vs seed compound baseline

Report which analogs improve on the seed compound and why. Highlight any that are both more drug-like AND easier to synthesize.

Example usage: /optimize strongylophorine-9 for QED against HIF-1α
Example usage: /optimize CC(=O)Oc1ccccc1C(=O)O targeting plogP
Example usage: /optimize aspirin for QED
