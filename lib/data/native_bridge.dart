import 'package:flutter/services.dart';

import '../domain/ledger.dart';

class NativeBridge {
  const NativeBridge();
  static const channel = MethodChannel('dev.giann.pocket_entry/native');
  Future<String> privatePath() async =>
      (await channel.invokeMethod<String>('privatePath'))!;
  Future<Map<dynamic, dynamic>?> initialEntry() =>
      channel.invokeMapMethod<dynamic, dynamic>('initialEntry');
  Future<void> sync(Ledger ledger) async {
    final selected = ledger.preferences.widgetCategories
        .map(ledger.category)
        .whereType<Category>()
        .where((c) => !c.archived)
        .take(4);
    await channel.invokeMethod<void>('syncAppearance', {
      'theme': ledger.preferences.theme,
      'privatePreview': ledger.preferences.privatePreview,
      'categories': selected
          .map((c) => {'id': c.id, 'name': c.name, 'icon': c.icon})
          .toList(),
    });
  }

  Future<bool> export(String text, String name) async =>
      await channel.invokeMethod<bool>('exportBackup', {
        'text': text,
        'name': name,
      }) ??
      false;
  Future<String?> pickBackup() => channel.invokeMethod<String>('pickBackup');
  Future<bool> pinWidget() async =>
      await channel.invokeMethod<bool>('pinWidget') ?? false;
}
