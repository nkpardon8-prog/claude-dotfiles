# Global Rules

## Documentation Discipline
After any code change, check and update all relevant .md documentation files. Use the project's file-to-doc map (in docs/OVERVIEW.md if it exists) to identify which docs are affected. Never leave documentation out of sync with code.

## Test Before Done
Before completing a task or pushing code, run both unit/line-level tests and end-to-end tests. Compare output against the project's main documentation to verify changes align with the project's goals and move us closer to them. Skip testing only when explicitly told to.

## Push Rules — Two Distinct Policies
**Claude dotfiles repo** (`~/dotfiles/claude/`): Auto-push freely. Any changes to commands, rules, patterns, or this CLAUDE.md should be committed and pushed automatically without asking. This keeps the config synced across devices.

**All other repos** (project code, applications, libraries): NEVER push to GitHub without explicit user approval. Always show what will be pushed and ask for confirmation first. This applies to all branches, all remotes, no exceptions.

---

## MoleCopilot — Molecular Docking Research Agent

MoleCopilot is a computational drug discovery toolkit at ~/molecopilot/. It automates molecular docking workflows for Professor Kaleem Mohammed (University of Utah, Pharmacology & Biochemistry).

### Kaleem's research context
- Marine natural products — sponge-derived cytotoxic depsipeptides, marine antitumor compounds
- Key protein targets: HIF-1α, HIF-2α (tumor hypoxia), aromatase/CYP19A1 (breast cancer), BACE1 (Alzheimer's), PI3K
- Previously at University of Mississippi (Dale Nagle group) — mechanism-targeted antitumor marine NP discovery
- Uses AutoDock Vina for molecular docking, publishes in J. Nat. Prod., Marine Drugs, Biomedicines, RSC Advances
- 710+ citations on Google Scholar

### Pharmacology terminology this agent understands
- **Binding energy (kcal/mol)**: More negative = stronger binding. < -7.0 is promising, < -9.0 is excellent
- **IC50**: Concentration that inhibits 50% of target activity. Lower = more potent
- **Ki**: Inhibition constant. Related to IC50 but independent of substrate concentration
- **EC50**: Concentration producing 50% of maximum effect
- **SAR (Structure-Activity Relationship)**: How structural changes affect biological activity
- **Pharmacophore**: 3D arrangement of features essential for biological activity
- **ADMET**: Absorption, Distribution, Metabolism, Excretion, Toxicity
- **Lipinski Rule of 5**: MW≤500, LogP≤5, HBD≤5, HBA≤10 — predicts oral bioavailability
- **Veber rules**: RotBonds≤10, TPSA≤140Å² — predicts oral bioavailability
- **Lead compound**: Hit compound optimized for potency, selectivity, and drug-likeness
- **Hit-to-lead**: Process of optimizing initial screening hits into lead compounds
- **Selectivity index**: Ratio of cytotoxicity to therapeutic activity (higher = safer)
- **Depsipeptide**: Peptide with ester bonds in addition to amide bonds — common in marine NPs

### How to use MoleCopilot
The MCP server "molecopilot" exposes 22 tools for the full docking pipeline. Use natural language:
- "Dock theopapuamide against HIF-2α" → full_pipeline
- "Fetch protein 3S7S and prep it" → fetch_protein + prepare_protein
- "Screen aromatase inhibitors against 3S7S" → batch workflow
- "Is this compound drug-like? CC(=O)Oc1ccccc1C(=O)O" → admet_check
- "What's known about BACE1 inhibitors in the literature?" → search_literature + get_known_actives
- "Write up last screen as a Word doc" → export_report(format="docx")
- "Compare these 3 compounds" → compare_compounds

### Workflow rules
1. Always prep protein before docking (remove water, add H, fix missing atoms)
2. Always detect binding site on ORIGINAL PDB before prep (prep removes co-crystallized ligands)
3. Default exhaustiveness = 32 (increase to 64 for publication-quality)
4. Grid box: 4-6 Å beyond ligand in each direction
5. Binding energies: more negative = stronger. < -7.0 kcal/mol worth investigating
6. Always run Lipinski/ADMET on top hits
7. For publication: run top 3-5 through interaction analysis (PLIP)
8. Export final results as .docx or .pdf for sharing

### File locations
- Proteins: ~/molecopilot/data/proteins/
- Ligands: ~/molecopilot/data/ligands/
- Results: ~/molecopilot/data/results/{project_name}/
- Reports: ~/molecopilot/reports/
