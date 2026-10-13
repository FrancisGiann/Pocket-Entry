import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_entry/app_controller.dart';
import 'package:pocket_entry/data/storage.dart';
import 'package:pocket_entry/domain/ledger.dart';

Ledger largeSyntheticLedger(int count) => Ledger.empty().copy(
  entries: [
    for (var i = 0; i < count; i++)
      Entry(
        id: 'synthetic_$i',
        kind: EntryKind.expense,
        centavos: 100 + i,
        date: '2026-10-${(1 + i % 28).toString().padLeft(2, '0')}',
        wallet: i.isEven ? Wallet.cash : Wallet.gcash,
        categoryId: 'food',
        note: 'Synthetic performance fixture',
        createdAt: i,
        updatedAt: i,
      ),
  ],
);

class BusyDraftStore extends MemoryLedgerStore {
  final release = Completer<void>();
  final snapshots = <String>[];
  @override
  Future<void> saveDraft(String encoded) async {
    snapshots.add(encoded);
    if (snapshots.length == 1) await release.future;
    await super.saveDraft(encoded);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('immutable derived caches survive repeated reads and refresh after edits and undo', () {
    final ledger = largeSyntheticLedger(2000);
    final expected = List.generate(
      2000,
      (i) => 100 + i,
    ).reduce((a, b) => a + b);
    final active = ledger.active;
    expect(() => active.clear(), throwsUnsupportedError);
    for (var i = 0; i < 10; i++) {
      expect(identical(ledger.active, active), true);
      expect(ledger.total(EntryKind.expense, month: '2026-10'), expected);
      expect(
        ledger.calculate(Wallet.cash).expenses +
            ledger.calculate(Wallet.gcash).expenses,
        expected,
      );
    }
    final changed = ledger.delete('synthetic_1', 3000);
    expect(changed.total(EntryKind.expense, month: '2026-10'), expected - 101);
    expect(
      changed.calculate(Wallet.gcash).expenses,
      ledger.calculate(Wallet.gcash).expenses - 101,
    );
    expect(changed.active.length, 1999);
    expect(ledger.active.length, 2000);
    final restored = changed.undo(3001);
    expect(restored.total(EntryKind.expense, month: '2026-10'), expected);
    expect(restored.active.length, 2000);
  });

  test('busy draft disk coalesces rapid inputs while save drains the newest snapshot', () async {
    final store = BusyDraftStore();
    final app = AppController(
      store: store,
      clock: () => DateTime(2026, 10, 12),
    );
    addTearDown(app.dispose);
    app.startDraft(categoryId: 'food');
    for (var i = 1; i <= 100; i++) {
      app.draft!.amount = '$i';
      app.updateDraft();
    }
    expect(store.snapshots.length, 1);
    store.release.complete();
    expect(await app.saveDraft(Wallet.cash), true);
    expect(store.snapshots.length, 2);
    expect(jsonDecode(store.snapshots.last)['amount'], '100');
    expect(app.ledger.active.single.centavos, 10000);
    expect(store.draft, isNull);
  });

  test('large synthetic ledger saves through worker and round-trips without changing totals', () async {
    final directory = await Directory.systemTemp.createTemp('pocket-worker-');
    addTearDown(() => directory.delete(recursive: true));
    final ledger = largeSyntheticLedger(10000);
    final store = FileLedgerStore(directory);
    await store.save(ledger);
    final loaded = (await store.load()).ledger;
    expect(loaded.encode(), ledger.encode());
    expect(
      loaded.calculate(Wallet.cash).balance,
      ledger.calculate(Wallet.cash).balance,
    );
    expect(loaded.active.length, 10000);
  });
}
