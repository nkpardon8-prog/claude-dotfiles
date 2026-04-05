Run a virtual screening campaign. Parse the user's request to identify:
1. The compound library or search query
2. The protein target (PDB ID or name)
3. Number of top hits to report (default: 10)

Pipeline using MoleCopilot MCP tools:
1. Fetch and prepare protein target — use fetch_protein then prepare_protein
2. Search PubChem for compounds matching the query — use search_compounds
3. Fetch SDF files for each compound — use fetch_compound for each CID
4. Prepare all ligands for docking — use batch_prepare_ligands
5. Batch dock entire library — use batch_dock
6. Rank by binding energy — use rank_results
7. Run ADMET on top 10 hits — use batch_admet
8. Generate comprehensive report with figures — use generate_report

Report progress as you go. At the end, provide:
- Top hits table (compound, energy, drug-likeness)
- Any compounds that are both strong binders AND drug-like
- Where all output files were saved

Example usage: /screen marine depsipeptides against HIF-2α
Example usage: /screen "aromatase inhibitors" against 3S7S top 20

After screening, suggest the user run /optimize on the top hit(s) to generate optimized analogs with improved drug-likeness and synthetic accessibility.
