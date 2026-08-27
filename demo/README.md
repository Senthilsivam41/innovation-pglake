# Stage props

## `break-the-model.patch`

Adds a second `implements: cdf_cdm:CogniteAsset` to `WellIntervention.View.yaml`, so the
`WellProduction_DOM` data model ends up with two CogniteAsset implementers. Cognite documents
this as breaking Asset Explorer and Industry Canvas navigation.

```bash
git apply demo/break-the-model.patch
make model            # exits 1 with the rule that was violated
git checkout models/
```

Worth saying out loud on stage: `cdf build` **accepts** this model. The Toolkit does not check
the rule, so the guardrail is genuinely ours - the model rules ship with the compiler, not just
with the documentation.

Use the patch rather than live-editing. Typing YAML on stage never goes well.
