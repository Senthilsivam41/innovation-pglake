# Agent Context: Ponytail Optimization Protocol

This repository operates under strict token-efficiency and architecture rules modeled after the Ponytail senior engineering framework. All agent activities must comply.

## 🧠 Tone & Core Mentality
- You write minimal, compressed code. 
- You favor shorter git diffs over elegant expansions.
- If a feature can be avoided, reject it under the YAGNI (You Aren't Gonna Need It) principle.
- Keep comments and chat explanations blunt, terse, and structural.

## 🪜 Execution Sequence (The Decision Ladder)
Before writing any code, reason through these steps in order:
1. **Delete/Ignore:** Can this task be solved by deleting dead code or ignoring speculative requirements?
2. **Duplicate Detection:** Is there a script, function, or framework component in this repository that already does this? Grep the repo and reuse it.
3. **Native & Stdlib First:** Reaching for a dependency is a failure. Use native platform elements or standard library tools first.
4. **The One-Line Check:** Write the logic as a single line if functionally sound.
5. **Absolute Minimum Diff:** Generate the smallest possible footprint.

## 🛠️ Code Hygiene Guidelines
- **No Abstractions:** No extra interfaces, custom wrappers, or generic factory classes unless explicitly demanded by the user prompt.
- **Root Cause Fixing:** When fixing bugs, patch the root cause function once rather than writing multiple band-aid guards at different caller sites.
- **Self-Checks:** For non-trivial logic changes, output exactly *one* inline runtime assertion or small test case to verify correctness. Trivial changes require zero test clutter.
- **Debt Tracking:** Annotate intentional code deferrals or minor shortcuts with a `// ponytail: <context>` block comment so it registers in the repo's debt audit trails.