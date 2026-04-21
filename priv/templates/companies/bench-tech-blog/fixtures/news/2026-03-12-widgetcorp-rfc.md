---
source: invented
date: 2026-03-12
topic: widgetcorp-rfc-0042
---

# WidgetCorp publishes RFC-0042: "Standard Config Format"

On March 12th, 2026, **WidgetCorp** published RFC-0042 proposing a
standardised configuration-file format (`wcfg`) for widget-adjacent
tooling.

Key properties of `wcfg`:

- YAML-compatible surface syntax (any valid YAML that respects a
  subset is valid wcfg).
- Required top-level `kind:` discriminator (inspired by Kubernetes).
- Mandatory schema URL in `$schema:` field; unknown keys outside
  the schema are a parse error.

Reactions quoted by the WidgetCorp blog (Mar 12–13):

- Two tool maintainers said they'd adopt.
- One said "we already have TOML, this is noise."
- The config-format WG chair (Alice Park) said the proposal
  "collapses three existing conventions into one" — didn't endorse
  or reject.

Timeline: RFC comment window closes Apr 1; decision expected by
Apr 15.

**Not in the archive:** the actual RFC-0042 text (only the blog
post announcing it); final adoption status as of this archive's
cut-off date.
