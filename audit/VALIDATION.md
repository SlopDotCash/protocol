# Validation record

This record is pending final source acceptance. The audit baseline is `ac59fdff2c8603ad642f2e73772871e6e0b79807`; intermediate passing tests do not prove the final source revision.

- Fresh pinned dependency installer: completed; 1,587 Solidity files compared, zero mismatches.
- Clean isolated Claims parser regressions: 12 passed, zero failed.
- Combined launch/Reclaim/vesting snapshot: 100 passed, zero failed.
- Exact SDK exports: all 24 typed ABI arrays matched raw exports at the export snapshot; TypeScript check passed.
- Independent oracle arithmetic: sub-agent checked 20,000 exact partition identities; Solidity partition/lifecycle tests remain in the suite.
- Hub canonical-asset migration, reversible-pause ordering, expiry boundaries and legacy supersession regressions: 15 passed, zero failed, in a clean dependency snapshot.
- Hub upgrade layout: all baseline field slots, offsets and widths preserved; new token mappings consume gap slots 19 and 20.
- Current Solidity source ABI compilation: all 24 public export arrays rebuilt with Solidity 0.8.26 and typechecked.
- Full source/hosted test suite: final run and results will be recorded after all patches and ABI exports are committed.
- Source-license check: passed locally.
- Deployed contracts, mainnet upgrades, live attestor behavior, configured RPC forks and full Certora proofs: not verified by this work.
