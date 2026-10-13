import 'dart:convert';
import 'dart:math';

part 'wallet.dart';
part 'allowance.dart';

const schemaVersion = 3;
const _keepAllowance = Object();
const maxCentavos = 99999999999;
const maxBackupBytes = 5 * 1024 * 1024;

class LedgerException implements Exception {
  const LedgerException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum EntryKind { expense, income, transfer }

String newId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

int parseMoney(String input, {bool signed = false, bool allowZero = false}) {
  final value = input.trim();
  final pattern = signed
      ? r'^-?\d{1,9}(?:\.\d{0,2})?$'
      : r'^\d{1,9}(?:\.\d{0,2})?$';
  if (!RegExp(pattern).hasMatch(value)) {
    throw const LedgerException(
      'Enter an amount with at most two decimal places.',
    );
  }
  final negative = value.startsWith('-');
  final parts = (negative ? value.substring(1) : value).split('.');
  final cents =
      int.parse(parts[0]) * 100 +
      int.parse(parts.length == 1 ? '00' : parts[1].padRight(2, '0'));
  if (cents > maxCentavos || (!allowZero && cents == 0)) {
    throw const LedgerException(
      'Enter an amount greater than zero, up to ₱999,999,999.99.',
    );
  }
  return negative ? -cents : cents;
}

String money(int cents, {bool symbol = true}) {
  final absolute = cents.abs();
  final whole = (absolute ~/ 100).toString().replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+$)'),
    (m) => '${m[1]},',
  );
  return '${cents < 0 ? '−' : ''}${symbol ? '₱' : ''}$whole.${(absolute % 100).toString().padLeft(2, '0')}';
}

String moneyInput(int cents) =>
    '${cents < 0 ? '-' : ''}${cents.abs() ~/ 100}.${(cents.abs() % 100).toString().padLeft(2, '0')}';
String dayKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
String monthKey(DateTime date) => dayKey(date).substring(0, 7);
DateTime localDay(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    throw const LedgerException('A transaction date is invalid.');
  }
  final parts = value.split('-').map(int.parse).toList();
  final result = DateTime(parts[0], parts[1], parts[2]);
  if (dayKey(result) != value || result.year < 1900 || result.year > 2200) {
    throw const LedgerException('A transaction date is invalid.');
  }
  return result;
}

const monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];
String shortDate(String value) {
  final date = localDay(value);
  return '${date.day} ${monthNames[date.month - 1].substring(0, 3)} ${date.year}';
}

Map<String, dynamic> object(dynamic value) {
  if (value is! Map<String, dynamic>) {
    throw const LedgerException('The backup contains an invalid record.');
  }
  return value;
}

String stringField(Map<String, dynamic> map, String key, {int max = 500}) {
  final value = map[key];
  if (value is! String || value.length > max || value.contains('\u0000')) {
    throw LedgerException('The backup contains an invalid $key.');
  }
  return value;
}

int intField(
  Map<String, dynamic> map,
  String key, {
  int min = 0,
  int max = maxCentavos,
}) {
  final value = map[key];
  if (value is! int || value < min || value > max) {
    throw LedgerException('The backup contains an invalid $key.');
  }
  return value;
}

String idField(Map<String, dynamic> map, String key) {
  final value = stringField(map, key, max: 80);
  if (!RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(value)) {
    throw const LedgerException('The backup contains an invalid identifier.');
  }
  return value;
}

bool boolField(Map<String, dynamic> map, String key, {bool fallback = false}) {
  if (map[key] == null) return fallback;
  if (map[key] is! bool) {
    throw LedgerException('The backup contains an invalid $key.');
  }
  return map[key] as bool;
}

Wallet walletField(dynamic value) {
  if (value is! String || !RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(value)) {
    throw const LedgerException(
      'The backup contains an invalid wallet identifier.',
    );
  }
  return Wallet.reference(value);
}

class Category {
  const Category({
    required this.id,
    required this.name,
    required this.icon,
    this.archived = false,
  });
  final String id;
  final String name;
  final String icon;
  final bool archived;
  Category copy({String? name, String? icon, bool? archived}) => Category(
    id: id,
    name: name ?? this.name,
    icon: icon ?? this.icon,
    archived: archived ?? this.archived,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'icon': icon,
    'archived': archived,
  };
  factory Category.fromJson(dynamic value) {
    final map = object(value);
    final name = stringField(map, 'name', max: 30).trim();
    if (name.isEmpty) throw const LedgerException('A category needs a name.');
    final icon = stringField(map, 'icon', max: 30);
    if (!categoryIcons.contains(icon)) {
      throw const LedgerException('A category icon is unknown.');
    }
    return Category(
      id: idField(map, 'id'),
      name: name,
      icon: icon,
      archived: boolField(map, 'archived'),
    );
  }
}

const categoryIcons = [
  'food',
  'travel',
  'bills',
  'shopping',
  'health',
  'fun',
  'home',
  'income',
  'other',
];
const defaultCategories = [
  Category(id: 'food', name: 'Food', icon: 'food'),
  Category(id: 'travel', name: 'Travel', icon: 'travel'),
  Category(id: 'bills', name: 'Bills', icon: 'bills'),
  Category(id: 'shopping', name: 'Shopping', icon: 'shopping'),
  Category(id: 'health', name: 'Health', icon: 'health'),
  Category(id: 'fun', name: 'Leisure', icon: 'fun'),
  Category(id: 'income', name: 'Income', icon: 'income'),
  Category(id: 'other', name: 'Other', icon: 'other'),
];

class Entry {
  const Entry({
    required this.id,
    required this.kind,
    required this.centavos,
    required this.date,
    required this.wallet,
    required this.createdAt,
    required this.updatedAt,
    this.toWallet,
    this.categoryId,
    this.note = '',
    this.deletedAt,
    this.scheduleId,
    this.occurrenceDate,
  });
  final String id;
  final EntryKind kind;
  final int centavos;
  final String date;
  final Wallet wallet;
  final Wallet? toWallet;
  final String? categoryId;
  final String note;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  final String? scheduleId, occurrenceDate;
  bool get deleted => deletedAt != null;
  Entry withDeletion(int? timestamp) => Entry(
    id: id,
    kind: kind,
    centavos: centavos,
    date: date,
    wallet: wallet,
    toWallet: toWallet,
    categoryId: categoryId,
    note: note,
    createdAt: createdAt,
    updatedAt: timestamp ?? DateTime.now().millisecondsSinceEpoch,
    deletedAt: timestamp,
    scheduleId: scheduleId,
    occurrenceDate: occurrenceDate,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'centavos': centavos,
    'date': date,
    'wallet': wallet.name,
    'toWallet': toWallet?.name,
    'categoryId': categoryId,
    'note': note,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'deletedAt': deletedAt,
    'scheduleId': scheduleId,
    'occurrenceDate': occurrenceDate,
  };
  factory Entry.fromJson(dynamic value) {
    final map = object(value);
    final kindValue = stringField(map, 'kind', max: 10);
    final kind = EntryKind.values.where((k) => k.name == kindValue).firstOrNull;
    if (kind == null) {
      throw const LedgerException(
        'The backup contains an unknown transaction type.',
      );
    }
    final date = stringField(map, 'date', max: 10);
    localDay(date);
    final wallet = walletField(map['wallet']);
    final toWallet = map['toWallet'] == null
        ? null
        : walletField(map['toWallet']);
    final category = map['categoryId'] == null
        ? null
        : idField(map, 'categoryId');
    if (kind == EntryKind.transfer
        ? (toWallet == null || wallet == toWallet || category != null)
        : (toWallet != null || category == null)) {
      throw const LedgerException(
        'A transaction has invalid category or transfer wallets.',
      );
    }
    final createdAt = intField(map, 'createdAt', max: 9000000000000000);
    final updatedAt = intField(map, 'updatedAt', max: 9000000000000000);
    if (updatedAt < createdAt) {
      throw const LedgerException('A transaction has invalid change dates.');
    }
    final origin = map['scheduleId'] == null
        ? null
        : idField(map, 'scheduleId');
    final occurrence = map['occurrenceDate'] == null
        ? null
        : stringField(map, 'occurrenceDate', max: 10);
    if ((origin == null) != (occurrence == null)) {
      throw const LedgerException('An allowance occurrence is invalid.');
    }
    if (origin != null) {
      localDay(occurrence!);
      if (origin.length > 32 ||
          map['id'] != 'allow_${origin}_${occurrence.replaceAll('-', '')}') {
        throw const LedgerException(
          'An allowance occurrence identifier is invalid.',
        );
      }
    }
    return Entry(
      scheduleId: origin,
      occurrenceDate: occurrence,
      id: idField(map, 'id'),
      kind: kind,
      centavos: intField(map, 'centavos', min: 1),
      date: date,
      wallet: wallet,
      toWallet: toWallet,
      categoryId: category,
      note: stringField(map, 'note'),
      createdAt: createdAt,
      updatedAt: updatedAt,
      deletedAt: map['deletedAt'] == null
          ? null
          : intField(map, 'deletedAt', max: 9000000000000000),
    );
  }
}

class Preferences {
  const Preferences({
    this.welcomed = false,
    this.theme = 'system',
    this.reduceMotion = false,
    this.haptics = true,
    this.privatePreview = true,
    this.widgetCategories = const ['food', 'travel', 'bills', 'shopping'],
    this.quickWallets = const ['cash', 'gcash'],
  });
  final bool welcomed;
  final String theme;
  final bool reduceMotion;
  final bool haptics;
  final bool privatePreview;
  final List<String> widgetCategories, quickWallets;
  Preferences copy({
    bool? welcomed,
    String? theme,
    bool? reduceMotion,
    bool? haptics,
    bool? privatePreview,
    List<String>? widgetCategories,
    List<String>? quickWallets,
  }) => Preferences(
    welcomed: welcomed ?? this.welcomed,
    theme: theme ?? this.theme,
    reduceMotion: reduceMotion ?? this.reduceMotion,
    haptics: haptics ?? this.haptics,
    privatePreview: privatePreview ?? this.privatePreview,
    quickWallets: List.unmodifiable(quickWallets ?? this.quickWallets),
    widgetCategories: List.unmodifiable(
      widgetCategories ?? this.widgetCategories,
    ),
  );
  Map<String, dynamic> toJson() => {
    'welcomed': welcomed,
    'theme': theme,
    'reduceMotion': reduceMotion,
    'haptics': haptics,
    'privatePreview': privatePreview,
    'widgetCategories': widgetCategories,
    'quickWallets': quickWallets,
  };
  factory Preferences.fromJson(dynamic value) {
    final map = object(value);
    final theme = stringField(map, 'theme', max: 10);
    if (!['system', 'light', 'dark'].contains(theme)) {
      throw const LedgerException('The backup theme is invalid.');
    }
    final ids = map['widgetCategories'];
    if (ids is! List ||
        ids.length > 4 ||
        ids.any((id) => id is! String) ||
        ids.toSet().length != ids.length) {
      throw const LedgerException('The widget category selection is invalid.');
    }
    final quick = map['quickWallets'] ?? ['cash', 'gcash'];
    if (quick is! List ||
        quick.isEmpty ||
        quick.length > 2 ||
        quick.any((id) => id is! String) ||
        quick.toSet().length != quick.length) {
      throw const LedgerException('The preferred wallets are invalid.');
    }
    return Preferences(
      quickWallets: List<String>.unmodifiable(quick),
      welcomed: boolField(map, 'welcomed'),
      theme: theme,
      reduceMotion: boolField(map, 'reduceMotion'),
      haptics: boolField(map, 'haptics', fallback: true),
      privatePreview: boolField(map, 'privatePreview', fallback: true),
      widgetCategories: List<String>.unmodifiable(ids),
    );
  }
}

bool sameEntry(Entry? a, Entry? b) =>
    jsonEncode(a?.toJson()) == jsonEncode(b?.toJson());

class Change {
  const Change({required this.after, this.before});
  final Entry? before;
  final Entry after;
  Map<String, dynamic> toJson() => {
    'before': before?.toJson(),
    'after': after.toJson(),
  };
  factory Change.fromJson(dynamic value) {
    final map = object(value);
    final after = Entry.fromJson(map['after']);
    final before = map['before'] == null ? null : Entry.fromJson(map['before']);
    if (before != null && before.id != after.id) {
      throw const LedgerException('A change record is invalid.');
    }
    return Change(before: before, after: after);
  }
}

class WalletCalculation {
  const WalletCalculation(
    this.opening,
    this.income,
    this.expenses,
    this.incoming,
    this.outgoing,
  );
  final int opening, income, expenses, incoming, outgoing;
  int get balance => opening + income - expenses + incoming - outgoing;
}

class Ledger {
  Ledger({
    required List<Category> categories,
    required List<Entry> entries,
    required Map<Wallet, int> openings,
    required Map<String, int> budgets,
    Preferences? preferences,
    List<Change> changes = const [],
    List<Wallet> wallets = Wallet.values,
    this.allowance,
  }) : categories = List.unmodifiable(categories),
       entries = List.unmodifiable(entries),
       openings = Map.unmodifiable(openings),
       budgets = Map.unmodifiable(budgets),
       preferences = preferences ?? const Preferences(),
       changes = List.unmodifiable(changes),
       wallets = List.unmodifiable(wallets);
  factory Ledger.empty() => Ledger(
    categories: defaultCategories,
    entries: [],
    openings: {Wallet.cash: 0, Wallet.gcash: 0},
    budgets: {},
  );
  final List<Category> categories;
  final List<Entry> entries;
  final Map<Wallet, int> openings;
  final Map<String, int> budgets;
  final Preferences preferences;
  final List<Change> changes;
  final List<Wallet> wallets;
  final AllowanceSchedule? allowance;
  // Ledger snapshots are immutable. Derived indexes belong to one snapshot and
  // disappear naturally when an edit/restore creates its replacement.
  late final Map<String, Wallet> _walletIndex = {
    for (final w in wallets) w.id: w,
  };
  late final Map<String, Category> _categoryIndex = {
    for (final c in categories) c.id: c,
  };
  late final Map<String, Entry> _entryIndex = {
    for (final e in entries) e.id: e,
  };
  Wallet? wallet(Wallet? ref) => _walletIndex[ref?.id];
  late final List<Wallet> availableWallets = List.unmodifiable(
    wallets.where((w) => !w.archived),
  );
  late final List<Wallet> quickWallets = List.unmodifiable(
    preferences.quickWallets
        .map((id) => _walletIndex[id])
        .whereType<Wallet>()
        .where((w) => !w.archived),
  );
  late final List<Entry> active = List.unmodifiable(
    entries.where((e) => !e.deleted).toList()..sort((a, b) {
      final date = b.date.compareTo(a.date);
      return date == 0 ? b.createdAt.compareTo(a.createdAt) : date;
    }),
  );
  late final List<Category> availableCategories = List.unmodifiable(
    categories.where((c) => !c.archived),
  );
  Category? category(String? id) => _categoryIndex[id];
  Entry? entry(String id) => _entryIndex[id];
  final Map<Wallet, WalletCalculation> _walletCalculations = {};
  final Map<(EntryKind, String?, String?, String?), int> _totals = {};
  Ledger copy({
    List<Category>? categories,
    List<Entry>? entries,
    Map<Wallet, int>? openings,
    Map<String, int>? budgets,
    Preferences? preferences,
    List<Change>? changes,
    List<Wallet>? wallets,
    Object? allowance = _keepAllowance,
  }) => Ledger(
    categories: categories ?? this.categories,
    entries: entries ?? this.entries,
    openings: openings ?? this.openings,
    budgets: budgets ?? this.budgets,
    preferences: preferences ?? this.preferences,
    changes: changes ?? this.changes,
    wallets: wallets ?? this.wallets,
    allowance: identical(allowance, _keepAllowance)
        ? this.allowance
        : allowance as AllowanceSchedule?,
  );
  WalletCalculation calculate(Wallet wallet) =>
      _walletCalculations.putIfAbsent(wallet, () {
        var income = 0, expenses = 0, incoming = 0, outgoing = 0;
        for (final e in entries.where((e) => !e.deleted)) {
          if (e.kind == EntryKind.transfer) {
            if (e.wallet == wallet) outgoing += e.centavos;
            if (e.toWallet == wallet) incoming += e.centavos;
          } else if (e.wallet == wallet) {
            if (e.kind == EntryKind.income) {
              income += e.centavos;
            } else {
              expenses += e.centavos;
            }
          }
        }
        return WalletCalculation(
          openings[wallet] ?? 0,
          income,
          expenses,
          incoming,
          outgoing,
        );
      });

  int total(EntryKind kind, {String? month, String? date, String? categoryId}) {
    if (_totals.length >= 512) _totals.clear();
    return _totals.putIfAbsent(
      (kind, month, date, categoryId),
      () => entries
          .where(
            (e) =>
                !e.deleted &&
                e.kind == kind &&
                (month == null || e.date.startsWith(month)) &&
                (date == null || e.date == date) &&
                (categoryId == null || e.categoryId == categoryId),
          )
          .fold(0, (sum, e) => sum + e.centavos),
    );
  }

  Ledger put(Entry next, {bool editing = false}) {
    Entry.fromJson(next.toJson());
    final previous = entry(next.id);
    final retainsWallets =
        editing &&
        previous != null &&
        next.kind == previous.kind &&
        next.wallet == previous.wallet &&
        next.toWallet == previous.toWallet;
    if (wallet(next.wallet) == null ||
        next.toWallet != null && wallet(next.toWallet) == null ||
        !retainsWallets &&
            (wallet(next.wallet)?.archived != false ||
                (next.toWallet != null &&
                    wallet(next.toWallet)?.archived != false))) {
      throw const LedgerException('Choose active wallets before saving.');
    }
    if (previous != null && !editing) {
      if (sameEntry(previous, next)) return this;
      throw const LedgerException(
        'This entry was already saved. Open History to edit it.',
      );
    }
    if (editing && (previous == null || previous.deleted)) {
      throw const LedgerException('This entry is no longer available to edit.');
    }
    if (next.categoryId != null &&
        (category(next.categoryId) == null ||
            category(next.categoryId)!.archived)) {
      throw const LedgerException('Choose an available category.');
    }
    if (entries.length >= 20000 && previous == null) {
      throw const LedgerException(
        'This ledger is full. Export a backup before starting another ledger.',
      );
    }
    return copy(
      entries: [...entries.where((e) => e.id != next.id), next],
      changes: [
        ...changes,
        Change(before: previous, after: next),
      ].reversed.take(30).toList().reversed.toList(),
    );
  }

  Ledger delete(String id, int now) {
    final before = entry(id);
    if (before == null || before.deleted) return this;
    final after = before.withDeletion(max(now, before.updatedAt));
    return copy(
      entries: [
        for (final e in entries)
          if (e.id == id) after else e,
      ],
      changes: [
        ...changes,
        Change(before: before, after: after),
      ].reversed.take(30).toList().reversed.toList(),
    );
  }

  Ledger restoreDeleted(String id, int now) {
    final before = entry(id);
    if (before == null || !before.deleted) return this;
    final after = Entry(
      id: before.id,
      kind: before.kind,
      centavos: before.centavos,
      date: before.date,
      wallet: before.wallet,
      toWallet: before.toWallet,
      categoryId: before.categoryId,
      note: before.note,
      createdAt: before.createdAt,
      updatedAt: max(now, before.updatedAt),
      scheduleId: before.scheduleId,
      occurrenceDate: before.occurrenceDate,
    );
    return copy(
      entries: [
        for (final e in entries)
          if (e.id == id) after else e,
      ],
      changes: [
        ...changes,
        Change(before: before, after: after),
      ].reversed.take(30).toList().reversed.toList(),
    );
  }

  Ledger undo(int now) {
    if (changes.isEmpty) {
      throw const LedgerException('There is no transaction change to undo.');
    }
    final change = changes.last;
    if (!sameEntry(entry(change.after.id), change.after)) {
      throw const LedgerException(
        'This entry changed again. Review it in History.',
      );
    }
    final restored =
        change.before ??
        change.after.withDeletion(max(now, change.after.updatedAt));
    return copy(
      entries: [
        for (final e in entries)
          if (e.id == restored.id) restored else e,
      ],
      changes: changes.sublist(0, changes.length - 1),
    );
  }

  Map<String, dynamic> toJson() => {
    'application': 'pocket_entry',
    'schemaVersion': schemaVersion,
    'currency': 'PHP',
    'categories': categories.map((c) => c.toJson()).toList(),
    'entries': entries.map((e) => e.toJson()).toList(),
    'wallets': wallets.map((w) => w.toJson()).toList(),
    'allowance': allowance?.toJson(),
    'openings': {for (final w in wallets) w.name: openings[w] ?? 0},
    'budgets': budgets,
    'preferences': preferences.toJson(),
    'changes': changes.map((c) => c.toJson()).toList(),
  };
  String encode() => jsonEncode(toJson());
  factory Ledger.decode(String text) {
    if (utf8.encode(text).length > maxBackupBytes) {
      throw const LedgerException(
        'Choose a Pocket Entry backup smaller than 5 MB.',
      );
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const LedgerException(
        'This file is not valid JSON. Choose a Pocket Entry backup.',
      );
    }
    var map = object(decoded);
    if (map['application'] != 'pocket_entry' || map['currency'] != 'PHP') {
      throw const LedgerException('Choose a PHP backup made by Pocket Entry.');
    }
    final version = map['schemaVersion'];
    if (version is! int) {
      throw const LedgerException('The backup schema version is invalid.');
    }
    if (version == 1) map = migrateV1(map);
    if (version == 1 || version == 2) {
      map = migrateV2(map);
    } else if (version != schemaVersion) {
      throw const LedgerException(
        'This backup version is not supported. Your current data is unchanged.',
      );
    }
    final rawWallets = map['wallets'];
    if (rawWallets is! List || rawWallets.isEmpty || rawWallets.length > 20) {
      throw const LedgerException('Keep one to twenty wallets.');
    }
    final wallets = rawWallets.map(Wallet.fromJson).toList();
    final walletIds = wallets.map((w) => w.id).toSet();
    if (wallets.map((w) => w.label.toLowerCase()).toSet().length !=
        wallets.length) {
      throw const LedgerException('Wallet names must be distinct.');
    }
    if (walletIds.length != wallets.length ||
        !wallets.any((w) => !w.archived)) {
      throw const LedgerException(
        'Wallet identifiers or active wallets are invalid.',
      );
    }
    final allowance = map['allowance'] == null
        ? null
        : AllowanceSchedule.fromJson(map['allowance']);
    if (allowance != null &&
        (!walletIds.contains(allowance.wallet.id) ||
            allowance.enabled &&
                wallets.where((w) => w == allowance.wallet).single.archived)) {
      throw const LedgerException(
        'The allowance wallet is missing or archived.',
      );
    }
    final rawCategories = map['categories'],
        rawEntries = map['entries'],
        rawChanges = map['changes'];
    if (rawCategories is! List ||
        rawCategories.isEmpty ||
        rawCategories.length > 100 ||
        rawEntries is! List ||
        rawEntries.length > 20000 ||
        rawChanges is! List ||
        rawChanges.length > 30) {
      throw const LedgerException(
        'The backup has invalid or excessive records.',
      );
    }
    final categories = rawCategories.map(Category.fromJson).toList();
    final entries = rawEntries.map(Entry.fromJson).toList();
    final changes = rawChanges.map(Change.fromJson).toList();
    if (categories.map((c) => c.id).toSet().length != categories.length ||
        entries.map((e) => e.id).toSet().length != entries.length) {
      throw const LedgerException('The backup contains duplicate identifiers.');
    }
    if (!categories.any((c) => !c.archived)) {
      throw const LedgerException('Keep at least one available category.');
    }
    final categoryIds = categories.map((c) => c.id).toSet();
    for (final e in [
      ...entries,
      ...changes.expand((c) => [if (c.before != null) c.before!, c.after]),
    ]) {
      if (!walletIds.contains(e.wallet.id) ||
          e.toWallet != null && !walletIds.contains(e.toWallet!.id)) {
        throw const LedgerException(
          'A transaction references a missing wallet.',
        );
      }
      if (e.scheduleId != null && e.scheduleId != allowance?.id) {
        throw const LedgerException('An allowance origin is missing.');
      }
      if (e.categoryId != null && !categoryIds.contains(e.categoryId)) {
        throw const LedgerException(
          'A transaction references a missing category.',
        );
      }
    }
    if (changes.any((c) => !entries.any((e) => e.id == c.after.id))) {
      throw const LedgerException('A change references a missing transaction.');
    }
    final openingMap = object(map['openings']);
    if (openingMap.keys.toSet().difference(walletIds).isNotEmpty) {
      throw const LedgerException(
        'The backup contains an unknown opening wallet.',
      );
    }
    final openings = {
      for (final w in wallets)
        w: intField(openingMap, w.name, min: -maxCentavos),
    };
    final budgetMap = object(map['budgets']);
    if (budgetMap.length > 3600) {
      throw const LedgerException('The backup has too many budgets.');
    }
    final budgets = <String, int>{};
    for (final key in budgetMap.keys) {
      if (!RegExp(r'^\d{4}-\d{2}$').hasMatch(key)) {
        throw const LedgerException('A budget month is invalid.');
      }
      localDay('$key-01');
      budgets[key] = intField(budgetMap, key);
    }
    final preferences = Preferences.fromJson(map['preferences']);
    if (preferences.widgetCategories.any((id) => !categoryIds.contains(id))) {
      throw const LedgerException('A widget category is missing.');
    }
    if (preferences.quickWallets.any(
      (id) => !wallets.any((w) => w.id == id && !w.archived),
    )) {
      throw const LedgerException('A preferred wallet is missing or archived.');
    }
    return Ledger(
      wallets: wallets,
      allowance: allowance,
      categories: categories,
      entries: entries,
      openings: openings,
      budgets: budgets,
      preferences: preferences,
      changes: changes,
    );
  }
}

Map<String, dynamic> migrateV1(Map<String, dynamic> old) {
  final migrated = Map<String, dynamic>.from(old);
  migrated['schemaVersion'] = 2;
  migrated['changes'] = <dynamic>[];
  migrated['preferences'] =
      migrated['preferences'] ?? const Preferences().toJson();
  if (old['entries'] is List) {
    migrated['entries'] = (old['entries'] as List).map((value) {
      final entry = Map<String, dynamic>.from(object(value));
      entry.putIfAbsent('deletedAt', () => null);
      entry['updatedAt'] = entry['updatedAt'] ?? entry['createdAt'];
      return entry;
    }).toList();
  }
  if (old['categories'] is List) {
    migrated['categories'] = (old['categories'] as List).map((value) {
      final category = Map<String, dynamic>.from(object(value));
      category['archived'] = category['archived'] ?? false;
      return category;
    }).toList();
  }
  return migrated;
}

Map<String, dynamic> migrateV2(Map<String, dynamic> old) => {
  ...old,
  'schemaVersion': 3,
  'wallets': Wallet.values.map((w) => w.toJson()).toList(),
  'allowance': null,
};

class RestorePreview {
  const RestorePreview({
    required this.ledger,
    required this.added,
    required this.skipped,
    required this.base,
  });
  final Ledger ledger;
  final int added, skipped;
  final String base;
}

RestorePreview previewRestore(Ledger current, Ledger imported) {
  final pristine =
      current.entries.isEmpty &&
      current.allowance == null &&
      jsonEncode(current.wallets.map((w) => w.toJson()).toList()) ==
          jsonEncode(Wallet.values.map((w) => w.toJson()).toList()) &&
      current.budgets.isEmpty &&
      current.openings.values.every((v) => v == 0) &&
      jsonEncode(current.categories.map((c) => c.toJson()).toList()) ==
          jsonEncode(defaultCategories.map((c) => c.toJson()).toList());
  if (pristine) {
    return RestorePreview(
      ledger: imported.copy(
        preferences: imported.preferences.copy(
          welcomed: current.preferences.welcomed,
        ),
        allowance: imported.allowance?.copy(enabled: false),
        changes: imported.changes,
      ),
      added: imported.entries.length,
      skipped: 0,
      base: current.encode(),
    );
  }
  final categories = [...current.categories];
  for (final c in imported.categories) {
    final existing = current.category(c.id);
    if (existing == null) {
      categories.add(c);
    } else if (jsonEncode(existing.toJson()) != jsonEncode(c.toJson())) {
      throw const LedgerException(
        'A category changed since this backup. Use a fresh backup; nothing has been restored.',
      );
    }
  }
  final entries = [...current.entries];
  var skipped = 0, added = 0;
  for (final e in imported.entries) {
    final existing = current.entry(e.id);
    if (existing == null) {
      entries.add(e);
      added++;
    } else if (sameEntry(existing, e)) {
      skipped++;
    } else {
      throw const LedgerException(
        'An entry changed since this backup. It will not be duplicated or overwritten. Use a fresh backup.',
      );
    }
  }
  final wallets = [...current.wallets];
  final openings = {...current.openings};
  for (final w in imported.wallets) {
    final old = current.wallet(w);
    if (old == null) {
      wallets.add(w);
      openings[w] = imported.openings[w]!;
    } else if (jsonEncode(old.toJson()) != jsonEncode(w.toJson()) ||
        current.openings[w] != imported.openings[w]) {
      throw const LedgerException(
        'A wallet or opening balance differs. Nothing has been restored.',
      );
    }
  }
  var allowance = current.allowance;
  if (imported.allowance != null) {
    if (allowance == null) {
      allowance = imported.allowance!.copy(enabled: false);
    } else if (jsonEncode(allowance.toJson()) !=
        jsonEncode(imported.allowance!.toJson())) {
      throw const LedgerException(
        'Allowance schedules differ. Nothing has been restored.',
      );
    }
  }
  final budgets = {...current.budgets};
  for (final item in imported.budgets.entries) {
    if (budgets.containsKey(item.key) && budgets[item.key] != item.value) {
      throw const LedgerException(
        'A budget differs from this backup. Nothing has been restored.',
      );
    }
    budgets[item.key] = item.value;
  }
  final merged = current.copy(
    categories: categories,
    entries: entries,
    budgets: budgets,
    wallets: wallets,
    openings: openings,
    allowance: allowance,
  );
  Ledger.decode(merged.encode());
  return RestorePreview(
    ledger: merged,
    added: added,
    skipped: skipped,
    base: current.encode(),
  );
}

class Draft {
  Draft({
    String? id,
    this.amount = '',
    this.kind = EntryKind.expense,
    String? date,
    this.categoryId,
    this.note = '',
    this.from = Wallet.cash,
    this.to = Wallet.gcash,
    this.editingId,
  }) : id = id ?? newId(),
       date = date ?? dayKey(DateTime.now());
  final String id;
  String amount;
  EntryKind kind;
  String date;
  String? categoryId;
  String note;
  Wallet from, to;
  String? editingId;
  bool get dirty => amount.isNotEmpty || note.isNotEmpty || editingId != null;
  Map<String, dynamic> toJson() => {
    'id': id,
    'amount': amount,
    'kind': kind.name,
    'date': date,
    'categoryId': categoryId,
    'note': note,
    'from': from.name,
    'to': to.name,
    'editingId': editingId,
  };
  factory Draft.fromEntry(Entry e) => Draft(
    id: e.id,
    amount: moneyInput(e.centavos),
    kind: e.kind,
    date: e.date,
    categoryId: e.categoryId,
    note: e.note,
    from: e.wallet,
    to: e.toWallet ?? Wallet.gcash,
    editingId: e.id,
  );
  factory Draft.fromJson(dynamic value) {
    final map = object(value);
    final date = stringField(map, 'date', max: 10);
    localDay(date);
    final amount = stringField(map, 'amount', max: 12);
    if (amount.isNotEmpty &&
        !RegExp(r'^\d{0,9}(?:\.\d{0,2})?$').hasMatch(amount)) {
      throw const LedgerException('The saved amount is invalid.');
    }
    final kind = EntryKind.values
        .where((k) => k.name == map['kind'])
        .firstOrNull;
    if (kind == null) {
      throw const LedgerException('The saved entry type is invalid.');
    }
    return Draft(
      id: idField(map, 'id'),
      amount: amount,
      kind: kind,
      date: date,
      categoryId: map['categoryId'] == null ? null : idField(map, 'categoryId'),
      note: stringField(map, 'note'),
      from: walletField(map['from']),
      to: walletField(map['to'] ?? (map['from'] == 'cash' ? 'gcash' : 'cash')),
      editingId: map['editingId'] == null ? null : idField(map, 'editingId'),
    );
  }
}
