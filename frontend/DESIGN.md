# Frontend design: Zero Trust Workshop

This UI follows **Vault daylight glass**, the house system also used by Arcanium, Shift Gear and Vault Reference. `src/styles/vault-glass.css` and `shell.css` come from the `vault-ui-design` skill with Tailwind removed. `src/styles/app.css` holds this project's page layer. Where this file is silent, the skill applies.

## The idea

Students climb from a password in source code to per-caller credentials with human approval on writes. The UI shows two things as they climb: **where the database password comes from now**, and **what the current identity can read because of it**.

The signature is the **credential ladder** in the Overview hero: seven rungs, from Hardcoded to Identity. It is a progress line, so it stays quiet and flat.

## Views

| View | Hero | Below the hero |
| --- | --- | --- |
| Overview | Current rung, explanation, ladder, four live tiles | Data access, Active credential |
| Data | Current identity | Six tables with classification pills and counts |
| Approvals | What the gate does and who enforces it | Request → Approve → Write, order picker |
| Ask | What the model may receive | Suggestions, question, streamed answer |

Each view has exactly one ink hero. Navigation is hash based (`#data`), with no router dependency.

## Colour meaning

Classifications always use the same colours: public green, internal blue, confidential amber, restricted red. All are tokens, mixed through `color-mix`. A locked classification is `--vg-text-dim`, never faded with `opacity`.

## Honesty rules

- Everything displayed comes from the running backend. Nothing is simulated.
- One credential source can cover several labs, so a rung names its lab range. The UI never claims a precise lab it cannot observe.
- The expiry countdown uses `expiresAt` from the backend's lease. It says "expired" and does not fake a renewal.
- A locked classification names its cause: trust level or role.
- The CIBA gate is application-enforced, and the Approvals view says so.
- Passwords are never rendered.
- Missing values read "Not reported".

## Verification

Screenshot each view at 1440×900 and 390×844, and run an axe WCAG 2.1 AA scan with 0 violations. Existing instances keep their built image, so check UI changes after `make reset`, on a fresh `INSTANCE`, or with `build frontend` and a recreate of the service.
