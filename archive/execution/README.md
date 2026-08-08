# Retired execution prototype

This directory is historical, non-shipping source. Black Label Trading b27 and later are
signals/research only: they do not place, cancel, or close broker orders.

Release builds use an explicit backend allowlist and `Tests/signals-only-release-contract.sh`
rejects execution modules, order endpoints, execution routes, and execution UI copy. Do not add
this directory to an application target or runtime package.
