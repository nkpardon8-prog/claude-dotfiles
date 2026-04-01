---
description: "Launch the MoleCopilot Streamlit web dashboard — finds a free port, starts the server, and opens the browser."
---

Launch the MoleCopilot web dashboard. Checks for a free port, starts the Streamlit server,
waits for it to respond, and opens the browser.

Steps:
1. Check if port 8501 is available using: `lsof -i :8501`
2. If busy, try 8502, 8503, etc. up to 8510
3. Start Streamlit in background: `conda run -n molecopilot streamlit run ~/Desktop/Projects/Kaleem/app.py --server.port {port} &`
4. Wait up to 15 seconds for the server to respond: poll `curl -s http://localhost:{port}` until it returns HTML
5. Open the browser: `open http://localhost:{port}`
6. Report the URL to the user

If the server fails to start, check stderr output and report the error.

The dashboard runs in the background. To stop it: find the process with `lsof -i :{port}` and kill it,
or use `pkill -f "streamlit run"`.
