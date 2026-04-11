---
description: "Semantic search across a project's construction documents — finds specific sections, schedules, spec clauses, and details from document sets. Returns relevant chunks with source citations. One of several tools available for reading construction documents."
argument-hint: "[what to search for, e.g. 'panel schedule for Panel H' or 'fire-rated conduit requirements']"
---

You have **semantic search** over this project's construction documents. It uses Voyage AI vector embeddings + reranking to find the most relevant chunks from the indexed document set.

## How to search

Pick whichever is more convenient:

**Via API** (if the dev server is running):
```bash
curl -s "http://localhost:3001/api/search?projectId={ID}&q={QUERY}&n=5"
```

**Via script** (always works):
```bash
source ~/Desktop/Projects/Plan2BidAgent/.venv/bin/activate && python3 ~/Desktop/Projects/Plan2BidAgent/scripts/search_docs.py --project-id {ID} --query "{QUERY}" --top-n 5
```

Note: If the Plan2BidAgent scripts directory does not exist, semantic search is not available. Use the Read tool and Grep to search documents manually.

Returns JSON with results: `text`, source `filename`, `page` number, `type`, and relevance `score`.

## When this tends to be helpful

- Large document sets (100+ pages) where sequential reading is impractical
- Finding specific details: a particular panel schedule, spec clause, addendum change, or schedule entry
- Cross-referencing specs against drawings across many pages
- Post-estimation Q&A — after `/plan2bid:run` completes, answering follow-up questions without re-reading everything

## When direct reading is probably better

- Small document sets where you can just read the whole thing
- Counting symbols on drawings (vision task, not text search)
- When you need full document context rather than a snippet

## If embeddings don't exist yet

Trigger indexing first:
```bash
source ~/Desktop/Projects/Plan2BidAgent/.venv/bin/activate && python3 ~/Desktop/Projects/Plan2BidAgent/scripts/chunk_and_embed.py --project-id {ID} --uploads-dir ~/Desktop/Projects/Plan2BidAgent/webapp/uploads/{ID}
```
Or POST to the API: `curl -X POST http://localhost:3001/api/embed -H 'Content-Type: application/json' -d '{"projectId":"{ID}"}'`

## If no API key

Tell the user to set `VOYAGE_API_KEY` in their environment. Free keys available at https://dash.voyageai.com/api-keys

## Tips for good queries

Be specific and include trade context. Use construction terminology the documents would contain. Examples:
- "panel schedule Panel H" not "electrical panel info"
- "fire-rated conduit penetration sealing" not "fire requirements"
- "Section 26 05 19 low-voltage wire" not "wiring specs"
