Prepare a protein target for docking. Fetches the structure from RCSB PDB, cleans it
(removes water, adds hydrogens, fixes missing atoms), converts to PDBQT format, and
detects the binding site from any co-crystallized ligand.

Use MoleCopilot MCP tools:
1. Fetch the protein structure — use fetch_protein with the PDB ID
2. Prepare the protein — use prepare_protein (this ALSO detects the binding site
   automatically on the original PDB before cleaning, and returns it in the result
   as result["binding_site"])
3. Optionally get UniProt annotations — use protein_info

Note: prepare_protein internally detects the binding site BEFORE removing the
co-crystallized ligand. You do NOT need to call detect_binding_site separately.

Report:
- Protein name, organism, resolution, experimental method
- Binding site coordinates and box size (from prepare_protein result)
- What co-crystallized ligand was found (if any)
- Where the PDBQT file was saved
- The protein is ready for docking

Example usage: /prep-target 3S7S
Example usage: /prep-target 3H82
