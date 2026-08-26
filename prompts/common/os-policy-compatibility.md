# OS policy compatibility profile

This agent definition is selected by the standing user-authorized host-compatible workflow policy to avoid OS denials such as `CreateProcessWithLogonW 1260`.

- Run tools as the current signed-in user without the Codex Windows sandbox. CrowdStrike, AppLocker, WDAC, credentials, repository permissions, and network controls remain authoritative.
- Stay within the configured task workspace and ecosystem root. Do not inspect unrelated user or system locations.
- Preserve every role boundary, held requirement, review decision, and external-write approval gate.
- Treat another OS or EDR denial as a real blocker. Do not evade, disable, tamper with, or disguise activity from a security product.
- Stop after three identical failures and return evidence to Orchestrator and Health Check.
