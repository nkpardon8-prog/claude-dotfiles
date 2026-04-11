The user wants to run FRAIM. The requested job or topic is: $ARGUMENTS

Follow this process:

1. **If no argument was given** (the line above ends with ": "):
   Call `list_fraim_jobs()` to discover available jobs. Present the results to the user grouped by business function (the server returns jobs organized by category — use those categories as group headings). For each group, list 3-5 of the most impactful jobs with a one-line description.

   After listing, suggest 2-3 starting points based on what seems most relevant:
   - If in a code repo: suggest jobs from engineering/product-building categories
   - If no repo context: suggest jobs from marketing, fundraising, or business categories

   Ask the user which job they want to run, then proceed to step 2.

2. **Find the match**: from the list returned by `list_fraim_jobs()`, find the job whose name matches or closely resembles the argument. If no job matches, search for a matching skill by calling `get_fraim_file({ path: "skills/<likely-category>/<argument>.md" })` — try common categories like `engineering/`, `marketing/`, `business/`, `product-management/`, `ai-tools/`. Confirm the match with the user.

3. **Load the full content**:
   - For jobs: call `get_fraim_job({ job: "<matched-job-name>" })` — never execute from stub content.
   - For skills: the content from `get_fraim_file` is the full skill. Use it directly.

4. **Execute**: for jobs, follow the phased instructions returned by `get_fraim_job`, using `seekMentoring` at phase transitions where indicated. For skills, apply the skill steps to the user's current context.
