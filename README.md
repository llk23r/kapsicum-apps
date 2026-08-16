# Kapsicum Apps

This repository is the public, static source catalogue for Kapps. A Kapp is reviewed and built from source on the recipient's Mac; this repository does not distribute executable binaries, grant access, or certify publishers.

The first Included Kapp is [xactivity](packages/x-activities), a private local journal built from approved x.com captures. Its checked-in portable source ZIP is [xactivity-0.2.3.zip](releases/xactivity-0.2.3.zip), and `catalogue.json` pins both the ZIP SHA-256 and Kapsicum's canonical source digest. Prior release ZIPs remain available for explicit update and restore flows.

## One portable source contract

Every shared Kapp ZIP has these root members only:

- `Package.swift`
- `Kapp.json`
- admitted source files under `Sources/`

The package must not contain KappData, grants or permissions, credentials, chats, history, build output, Git metadata, executables, or other host-private state. Capability declarations in `Kapp.json` are requests only. The recipient reviews them and grants access locally after Kapsicum validates the source and builds it locally.

Source can itself contain private text. Inspect every file before sharing it.

## Discover, install, customize, and share

Kapsicum ships a pinned bundled copy of the catalogue and xactivity ZIP so Included discovery works offline. Selecting **Review & Install** uses the same archive importer, access review, and local build path as any portable source ZIP. xactivity requests text and screenshot retrieval plus optional AI; those are declarations only, and each installation receives access only after the user reviews and grants it locally.

For direct sharing, send an exported source ZIP. A recipient opens it in Kapsicum and performs the same review and local build. **Customize a Copy** creates an isolated local project: it does not copy data, grants, credentials, conversations, history, or builds. Before publishing that copy as a distinct Kapp, keep the new `appID` Kapsicum assigned (or choose another globally distinct package identity) so it cannot collide with the original.

## Contribute a Kapp

1. Fork this repository and create a branch.
2. Add the exact portable source tree at `packages/<package-name>/`.
3. Export or reproducibly create `releases/<Name>-<version>.zip` with `Package.swift`, `Kapp.json`, and `Sources/` at the ZIP root.
4. Add or update one entry in `catalogue.json`. Its facts must match `Kapp.json`; `sourceZIPLocation` must point to the checked-in ZIP on the repository's default branch.
5. Run `python3 scripts/validate_catalogue.py` from the repository root.
6. In a clean Kapsicum profile, import the ZIP directly, inspect the review facts, build and install it, exercise its primary use, and remove it. For an update, also import the later ZIP from the same catalogue `appID`, install the staged update, and restore the previous source.
7. Inspect the ZIP listing once more for private text and excluded local state, then open a pull request containing the source tree, ZIP, catalogue entry, and validator result together.

CI is intentionally deferred because of current billing constraints. The validator and clean-profile lifecycle check above are the required manual pre-merge gate until CI is explicitly funded and enabled. Do not add a workflow as a substitute for completing those checks.

## Trust boundary

Catalogue listing is discovery metadata, not trust. Digests prove that the reviewed bytes match the catalogue entry; they do not prove that the source is safe or that a publisher is trustworthy. Kapsicum still validates the portable tree, presents requested access and AI use, builds locally, and keeps every grant and all user data on the receiving Mac.

The app deliberately has no remote catalogue refresh today. The bundled catalogue remains available offline, and repository downloads enter the ordinary ZIP importer. A future optional refresh is appropriate only when catalogue scale or release cadence creates demonstrated freshness needs; it must retain the bundled fallback, validate the same metadata and digests, cache only a last-valid catalogue, and use the same importer without adding authority.
