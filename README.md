# Fork mirror sync

Keeps the default branches of selected `psy-repos-*` forks aligned with their upstream repositories using a GitHub App. The scheduled workflow checks daily and runs the sync no more than once every four days. A manual dispatch runs it immediately.

The workflow code lives in this standalone public repository so Actions can remain disabled in every fork. Configure repository secret `MIRROR_APP_ID`, secret `MIRROR_APP_PRIVATE_KEY`, and repository variable `MIRROR_SYNC_ENABLED=true`. The GitHub App installation must have Contents read and write access to the selected fork repositories.

The sync hard-resets fork default branches to the upstream default branch. Fork-specific commits on those branches are discarded.
