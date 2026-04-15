# Security Policy

Weft runs user-authored code, talks to LLMs, hits external APIs, and stores credentials. Security matters, and we take it seriously.

## Reporting a vulnerability

**Do not open a public GitHub issue for security problems.**

Email **contact@weavemind.ai** with:

- A short description of the issue.
- Steps to reproduce (a minimal Weft project, a curl command, a code snippet, whatever shows the problem).
- The impact you think it has.
- Your name or handle if you want credit.

You will get an acknowledgement within 48 hours. We will work with you on a fix and coordinate disclosure. Once the fix is shipped and users have had a reasonable window to update, the report becomes public in the changelog and you get credit unless you prefer to stay anonymous.

## What counts as a security issue

- Credential leakage (logs, error messages, API responses, dashboard leaks).
- Authentication or authorization bypasses.
- SQL injection, SSRF, or similar classic web vulnerabilities in the API or dashboard.
- Anything that lets one user see or modify another user's projects, executions, or files.
- Denial of service that is not rate-limited and does not require unusual conditions.

## What does not count

- A user running `rm -rf /` inside an ExecPython node in their own sandbox. The sandbox is there to protect the host, not the user from themselves.
- An LLM returning unsafe content. That is a model and prompt issue, not a Weft vulnerability.
- Bugs that require the attacker to already have admin access to your system.
- Missing security headers on the marketing site.

## Scope

This policy covers the `weft` repository and its official binaries. Third-party nodes, community forks, and external services that Weft talks to are out of scope, report those to their respective maintainers.

## Hall of fame

People who have reported valid issues will be listed here once we have any.

---

Thanks for helping keep Weft and its users safe.
