# Vendored Cognite system types

`cdf_cdm` and `cdf_idm` are Cognite-governed system spaces. They already exist in every CDF
project, so these files are **not** part of the Toolkit module tree and are never deployed —
`cdf build` does not see them.

AetherLake needs them for one reason: to create the physical Iceberg tables that back the CDM
containers our EDM views map properties from. Only the properties our own views actually map
are vendored. Adding the rest would produce empty Iceberg tables and dead YAML.

Refresh against a live project with `cdf dump datamodel` (enable the `dump` plugin in `cdf.toml`).
