Run ADMET/drug-likeness analysis on a compound. Accepts a compound name, SMILES string, or PubChem CID.

Use MoleCopilot MCP tools:
1. If a name is given, search PubChem — use search_compounds to get SMILES
2. Run full ADMET analysis — use admet_check with the SMILES string
3. Generate a 2D structure image — use draw_molecule
4. Optionally generate an ADMET radar plot

Report in a clear table:
- Lipinski Rule of 5: MW, LogP, H-bond donors, H-bond acceptors (pass/fail each)
- Veber rules: rotatable bonds, TPSA (pass/fail each)
- Additional: rings, aromatic rings, fraction Csp3, heavy atoms
- Overall drug-likeness score and assessment
- Plain-language explanation of what the results mean for drug development

Example usage: /admet aspirin
Example usage: /admet CC(=O)Oc1ccccc1C(=O)O
Example usage: /admet thymoquinone
