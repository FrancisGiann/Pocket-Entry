import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_entry/app_controller.dart';
import 'package:pocket_entry/data/storage.dart';
import 'package:pocket_entry/domain/ledger.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'private offline persistence, restart draft, and atomic file recovery',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'pocket-synthetic-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = FileLedgerStore(directory);
      final one = Ledger.empty().copy(
        openings: {Wallet.cash: 20001, Wallet.gcash: 30002},
      );
      await store.save(one);
      final two = one.copy(budgets: {'2026-10': 150000});
      await store.save(two);
      expect(
        (await FileLedgerStore(directory).load()).ledger.encode(),
        two.encode(),
      );
      final draft = Draft(
        categoryId: 'food',
        amount: '1.25',
        date: '2026-10-12',
        note: 'Synthetic only',
      );
      await store.saveDraft(jsonEncode(draft.toJson()));
      expect((await FileLedgerStore(directory).loadDraft())!.amount, '1.25');
      await store.file('ledger.json').writeAsString('{truncated');
      final recovered = await store.load();
      expect(recovered.notice, isNotNull);
      expect(recovered.ledger.encode(), one.encode());
      await store.save(recovered.ledger);
      expect(
        await store.file('ledger.unreadable.json').readAsString(),
        '{truncated',
      );
      expect((await store.load()).ledger.encode(), one.encode());
    },
  );
  test(
    'both damaged saves fail closed without resetting existing files',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'pocket-synthetic-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = FileLedgerStore(directory);
      await store.file('ledger.json').writeAsString('broken');
      await store.file('ledger.previous.json').writeAsString('also broken');
      expect(store.load, throwsA(isA<LedgerException>()));
      expect(await store.file('ledger.json').readAsString(), 'broken');
    },
  );
  test('repeated save taps create exactly one entry and one write', () async {
    final store = MemoryLedgerStore(
      Ledger.empty().copy(preferences: const Preferences(haptics: false)),
    )..delay = const Duration(milliseconds: 30);
    final app = AppController(
      store: store,
      clock: () => DateTime(2026, 10, 12),
    );
    addTearDown(app.dispose);
    await app.initialize();
    app.startDraft(categoryId: 'food');
    app.draft!.amount = '0.01';
    app.updateDraft();
    final results = await Future.wait([
      app.saveDraft(Wallet.cash),
      app.saveDraft(Wallet.gcash),
      app.saveDraft(Wallet.cash),
    ]);
    expect(results.where((v) => v).length, 1);
    expect(store.writes, 1);
    expect(app.ledger.entries.single.wallet, Wallet.cash);
    expect(app.ledger.entries.single.centavos, 1);
    expect(app.draft, isNull);
    app.startDraft(categoryId: 'food');
    app.draft!.amount = '0.02';
    await app.saveDraft(Wallet.gcash);
    expect(app.ledger.active.length, 2);
    expect(app.ledger.calculate(Wallet.gcash).balance, -2);
  });
  test('a failed save preserves the draft and ledger for retry', () async {
    final store = MemoryLedgerStore(
      Ledger.empty().copy(preferences: const Preferences(haptics: false)),
    )..failWrites = true;
    final app = AppController(store: store);
    addTearDown(app.dispose);
    await app.initialize();
    app.startDraft(categoryId: 'food');
    app.draft!.amount = '123.45';
    expect(await app.saveDraft(Wallet.cash), false);
    expect(app.ledger.entries, isEmpty);
    expect(app.draft!.amount, '123.45');
    expect(app.storageError, contains('Could not save'));
    store.failWrites = false;
    expect(await app.saveDraft(Wallet.gcash), true);
    expect(app.ledger.entries.single.wallet, Wallet.gcash);
  });
  test(
    'crash after commit before clearing draft never replays the transaction',
    () async {
      final store = MemoryLedgerStore(
        Ledger.empty().copy(preferences: const Preferences(haptics: false)),
      );
      final d = Draft(
        id: 'crash_case',
        amount: '15.01',
        categoryId: 'food',
        date: '2026-10-12',
      );
      await store.saveDraft(jsonEncode(d.toJson()));
      await store.save(
        store.value.put(
          Entry(
            id: d.id,
            kind: d.kind,
            centavos: 1501,
            date: d.date,
            wallet: Wallet.gcash,
            categoryId: d.categoryId,
            createdAt: 1000,
            updatedAt: 1000,
          ),
        ),
      );
      final app = AppController(store: store);
      addTearDown(app.dispose);
      await app.initialize();
      expect(app.draft, null);
      expect(store.draft, null);
      expect(app.ledger.active.length, 1);
      expect(await app.saveDraft(Wallet.cash), false);
      expect(app.ledger.active.length, 1);
    },
  );
  test('restore preserves a snapshot and rejects a stale preview', () async {
    final store = MemoryLedgerStore();
    final app = AppController(store: store);
    addTearDown(app.dispose);
    await app.initialize();
    final incoming = Ledger.empty().copy(
      openings: {Wallet.cash: 123, Wallet.gcash: 456},
    );
    final preview = previewRestore(app.ledger, incoming);
    await app.setBudget('2026-10', 150000);
    expect(await app.restore(preview), false);
    expect(app.storageError, contains('changed after'));
    final fresh = previewRestore(Ledger.empty(), incoming);
    app.ledger = Ledger.empty();
    expect(await app.restore(fresh), true);
    expect(store.recovery, isNotNull);
    expect(await app.recoverBeforeRestore(), true);
    expect(app.ledger.openings[Wallet.cash], 0);
  });
  test(
    'unfinished edit remains recoverable after restart and rotation',
    () async {
      final store = MemoryLedgerStore();
      final app = AppController(store: store);
      addTearDown(app.dispose);
      await app.initialize();
      app.startDraft(categoryId: 'travel');
      app.draft!.amount = '123.01';
      app.draft!.note = 'Synthetic trip';
      app.updateDraft();
      // Drain the exact write queue through a discard-free restart.
      await Future<void>.delayed(Duration.zero);
      final restarted = AppController(store: store);
      addTearDown(restarted.dispose);
      await restarted.initialize();
      expect(restarted.draft!.amount, '123.01');
      expect(restarted.draft!.categoryId, 'travel');
      expect(restarted.draft!.toJson().keys, isNot(contains('wallet')));
    },
  );
}
