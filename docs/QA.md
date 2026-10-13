# Verification and device checks

The local 0.2.0 delivery recorded 73 passing Flutter tests, ten passing native Android tests, and clean Flutter analysis. Fixtures contain invented entries; the application starts with no seeded financial records. These checks do not establish physical-device performance.

The tests cover integer centavos, transfer conservation, wallet and allowance validation, undo/recovery, backup validation and migration, repeated-save protection, draft restart behavior, cached ledger calculations, and a 10,000-record synthetic storage round trip. Native tests cover widget/shortcut routing, explicit immutable pending intents, private receivers, and layouts without financial widget text.

Before everyday use, test on an Android phone with synthetic data:

1. Check a fresh install starts empty with zero opening balances and inactive allowance.
2. Record and edit small invented expenses, income, and transfers; verify the balance equation, undo, soft deletion, and recovery.
3. Try home-screen widgets, launcher Quick add, cold launch, resizing, orientation, font scaling, and system Back.
4. Export and restore synthetic backups; test cancellation, duplicate restore, conflict rejection, and draft recovery after restart.
5. Check TalkBack, reduced motion, haptics, private app previews, and actual scrolling/entry responsiveness.

Build outputs, raw QA logs, generated captures, signing material, and runtime data stay outside the public source snapshot. No APK release or device-installation verification is supplied by this repository.
