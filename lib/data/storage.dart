import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../domain/ledger.dart';

class LoadResult {
  const LoadResult(this.ledger, {this.notice});
  final Ledger ledger;
  final String? notice;
}

abstract class LedgerStore {
  Future<LoadResult> load();
  Future<void> save(Ledger ledger);
  Future<Draft?> loadDraft();
  Future<void> saveDraft(String encoded);
  Future<void> clearDraft();
  Future<void> saveRestoreRecovery(Ledger ledger);
  Future<Ledger?> loadRestoreRecovery();
}

/// Only app-private paths are supplied by the Android bridge. Writes stage and
/// flush bytes before an atomic rename; current and previous saves are separate.
class FileLedgerStore implements LedgerStore {
  FileLedgerStore(this.directory);
  final Directory directory;
  File file(String name) => File('${directory.path}/$name');

  Future<void> _atomic(String name, String data) async {
    if (utf8.encode(data).length > maxBackupBytes) {
      throw const LedgerException(
        'The ledger is too large to save. Export a backup before adding more entries.',
      );
    }
    await directory.create(recursive: true);
    final stage = file('$name.next');
    await stage.writeAsString(data, flush: true);
    await stage.rename(file(name).path);
  }

  @override
  Future<LoadResult> load() async {
    final current = file('ledger.json');
    final previous = file('ledger.previous.json');
    if (!await current.exists() && !await previous.exists()) {
      return LoadResult(Ledger.empty());
    }
    try {
      return LoadResult(Ledger.decode(await current.readAsString()));
    } catch (_) {
      try {
        return LoadResult(
          Ledger.decode(await previous.readAsString()),
          notice: 'Recovered the previous save. Review your most recent entry before adding another.',
        );
      } catch (_) {
        throw const LedgerException(
          'Your saved ledger could not be opened. Your files are preserved. Retry or restore a valid backup.',
        );
      }
    }
  }

  @override
  Future<void> save(Ledger ledger) {
    final privatePath = directory.path;
    // Encoding, validation and disk flushes must not occupy the UI isolate.
    return Isolate.run(
      () => FileLedgerStore(Directory(privatePath))._saveInWorker(ledger),
    );
  }

  Future<void> _saveInWorker(Ledger ledger) async {
    final encoded = ledger.encode();
    Ledger.decode(encoded);
    final current = file('ledger.json');
    if (await current.exists()) {
      String? validCurrent;
      try {
        final bytes = await current.readAsString();
        Ledger.decode(bytes);
        validCurrent = bytes;
      } catch (_) {
        await _atomic('ledger.unreadable.json', await current.readAsString());
      }
      if (validCurrent != null) {
        await _atomic('ledger.previous.json', validCurrent);
      }
    }
    await _atomic('ledger.json', encoded);
  }

  @override
  Future<Draft?> loadDraft() async {
    final current = file('draft.json');
    if (!await current.exists()) return null;
    try {
      return Draft.fromJson(jsonDecode(await current.readAsString()));
    } catch (_) {
      throw const LedgerException(
        'The unfinished entry could not be recovered. Your saved transactions are safe.',
      );
    }
  }

  @override
  Future<void> saveDraft(String encoded) => _atomic('draft.json', encoded);
  @override
  Future<void> clearDraft() async {
    if (await file('draft.json').exists()) await file('draft.json').delete();
  }

  @override
  Future<void> saveRestoreRecovery(Ledger ledger) =>
      _atomic('before-restore.json', ledger.encode());
  @override
  Future<Ledger?> loadRestoreRecovery() async =>
      await file('before-restore.json').exists()
      ? Ledger.decode(await file('before-restore.json').readAsString())
      : null;
}

class MemoryLedgerStore implements LedgerStore {
  MemoryLedgerStore([Ledger? value]) : value = value ?? Ledger.empty();
  Ledger value;
  String? draft;
  Ledger? recovery;
  bool failWrites = false;
  int writes = 0;
  Duration delay = Duration.zero;
  @override
  Future<LoadResult> load() async => LoadResult(value);
  @override
  Future<void> save(Ledger ledger) async {
    if (delay != Duration.zero) await Future<void>.delayed(delay);
    if (failWrites) throw const FileSystemException('Synthetic disk failure');
    value = Ledger.decode(ledger.encode());
    writes++;
  }

  @override
  Future<Draft?> loadDraft() async =>
      draft == null ? null : Draft.fromJson(jsonDecode(draft!));
  @override
  Future<void> saveDraft(String encoded) async {
    draft = encoded;
  }

  @override
  Future<void> clearDraft() async {
    draft = null;
  }

  @override
  Future<void> saveRestoreRecovery(Ledger ledger) async {
    recovery = ledger;
  }

  @override
  Future<Ledger?> loadRestoreRecovery() async => recovery;
}
