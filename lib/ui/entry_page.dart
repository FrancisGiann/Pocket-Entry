import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../domain/ledger.dart';
import 'design.dart';

class EntryPage extends StatefulWidget {
  const EntryPage({super.key, required this.controller});
  final AppController controller;
  @override
  State<EntryPage> createState() => _EntryPageState();
}

class _EntryPageState extends State<EntryPage> {
  AppController get app => widget.controller;
  Draft get draft => app.draft!;
  List<Wallet> get selectableWallets {
    final old = app.ledger.entry(draft.editingId ?? '');
    return [
      ...app.ledger.availableWallets,
      if (old != null)
        for (final w in app.ledger.wallets.where(
          (w) => w.archived && (w == old.wallet || w == old.toWallet),
        ))
          w,
    ];
  }

  bool submitting = false;
  final selectedCategoryKey = GlobalKey();
  void showSelectedCategory() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = selectedCategoryKey.currentContext;
      if (mounted && context != null) {
        // Reveal the selected chip only within its horizontal category strip.
        // Scrolling ancestor pages would move the landscape header off screen.
        Scrollable.of(context).position.ensureVisible(
          context.findRenderObject()!,
          duration: Duration.zero,
          alignment: .5,
        );
      }
    });
  }

  @override
  void initState() {
    super.initState();
    app.entryVisible = true;
    showSelectedCategory();
  }

  @override
  void dispose() {
    app.entryVisible = false;
    super.dispose();
  }

  void change(VoidCallback update) {
    if (app.busy || submitting || app.draft == null) return;
    setState(() {
      update();
      app.storageError = null;
    });
    app.updateDraft();
    showSelectedCategory();
  }

  void digit(String key) {
    change(() {
      if (key == '⌫') {
        if (draft.amount.isNotEmpty) {
          draft.amount = draft.amount.substring(0, draft.amount.length - 1);
        }
      } else if (key == '.') {
        if (!draft.amount.contains('.')) {
          draft.amount = '${draft.amount.isEmpty ? '0' : draft.amount}.';
        }
      } else {
        final parts = draft.amount.split('.');
        if (parts.length == 2 && parts[1].length >= 2 ||
            parts.length == 1 && parts[0].length >= 9) {
          return;
        }
        draft.amount = draft.amount == '0' ? key : '${draft.amount}$key';
      }
    });
    if (app.ledger.preferences.haptics) HapticFeedback.selectionClick();
  }

  Future<void> save(Wallet wallet) async {
    if (submitting || app.busy) return;
    setState(() => submitting = true);
    final result = await app.saveDraft(wallet);
    if (!mounted) return;
    if (result) {
      Navigator.of(context).pop();
    } else {
      setState(() => submitting = false);
    }
  }

  Future<void> chooseDate() async {
    var date = localDay(draft.date);
    final now = app.clock();
    await showPocketSheet<void>(
      context: context,
      builder: (ctx) => SheetFrame(
        title: 'Entry date',
        height: 350,
        action: Press(
          onPressed: () {
            change(() => draft.date = dayKey(date));
            Navigator.pop(ctx);
          },
          child: Text(
            'Done',
            style: textStyle(
              ctx,
              color: Palette.of(ctx).accent,
              weight: FontWeight.w600,
            ),
          ),
        ),
        child: CupertinoDatePicker(
          mode: CupertinoDatePickerMode.date,
          initialDateTime: date.isAfter(now) ? now : date,
          minimumDate: DateTime(1900),
          maximumDate: DateTime(now.year, now.month, now.day, 23, 59),
          onDateTimeChanged: (value) => date = value,
        ),
      ),
    );
  }

  Future<void> chooseCategory() async {
    final chosen = await showPocketSheet<String>(
      context: context,
      builder: (ctx) => SheetFrame(
        title: 'Choose a category',
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            Surface(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (
                    var i = 0;
                    i < app.ledger.availableCategories.length;
                    i++
                  )
                    Builder(
                      builder: (ctx) {
                        final c = app.ledger.availableCategories[i];
                        return GroupRow(
                          c.name,
                          icon: categoryIcon(c.icon),
                          last: i == app.ledger.availableCategories.length - 1,
                          trailing: c.id == draft.categoryId
                              ? Icon(
                                  CupertinoIcons.checkmark_circle_fill,
                                  color: Palette.of(ctx).accent,
                                )
                              : null,
                          onTap: () => Navigator.pop(ctx, c.id),
                        );
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (chosen != null && mounted) change(() => draft.categoryId = chosen);
  }

  Future<void> note() async {
    final original = draft.note;
    final result = await textPrompt(
      context,
      title: 'A note, if you need it',
      value: original,
      hint: 'What was this for?',
      maxLength: 500,
      onChanged: (value) => change(() => draft.note = value),
    );
    if (mounted && app.draft != null) {
      change(() => draft.note = result?.trim() ?? original);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: app,
    builder: (context, _) {
      if (app.draft == null) {
        return CupertinoPageScaffold(
          child: Center(
            child: CupertinoActivityIndicator(
              color: Palette.of(context).accent,
            ),
          ),
        );
      }
      final p = Palette.of(context);
      final isTransfer = draft.kind == EntryKind.transfer;
      final quickCategories = app.ledger.availableCategories
          .where((c) => c.id != 'income')
          .take(4)
          .toList();
      final chosen = app.ledger.category(draft.categoryId);
      if (chosen != null && !quickCategories.any((c) => c.id == chosen.id)) {
        if (quickCategories.length == 4) quickCategories.removeLast();
        quickCategories.add(chosen);
      }
      final isToday = draft.date == dayKey(app.clock());
      return CupertinoPageScaffold(
        backgroundColor: p.background,
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth:
                    MediaQuery.sizeOf(context).width >
                        MediaQuery.sizeOf(context).height
                    ? 920
                    : 520,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final small =
                      constraints.maxHeight < 680 ||
                      MediaQuery.textScalerOf(context).scale(1) > 1.25;
                  final content = Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 0, 16, 0),
                        child: Row(
                          children: [
                            Press(
                              onPressed: submitting
                                  ? null
                                  : () => Navigator.pop(context),
                              label: 'Close entry, keep unfinished amount',
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                              child: Icon(
                                CupertinoIcons.xmark_circle_fill,
                                color: p.secondary,
                                size: 27,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                draft.editingId == null
                                    ? 'New entry'
                                    : 'Edit entry',
                                textAlign: TextAlign.center,
                                style: textStyle(
                                  context,
                                  size: 17,
                                  weight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Press(
                              label: draft.note.isEmpty
                                  ? 'Add a note'
                                  : 'Edit note',
                              onPressed: app.busy ? null : note,
                              padding: const EdgeInsets.all(12),
                              child: Icon(
                                CupertinoIcons.pencil,
                                size: 21,
                                color: p.accent,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 6, 24, 0),
                        child: SizedBox(
                          width: double.infinity,
                          child: CupertinoSlidingSegmentedControl<EntryKind>(
                            groupValue: draft.kind,
                            backgroundColor: p.line.withValues(alpha: .55),
                            thumbColor: p.surface,
                            padding: const EdgeInsets.all(4),
                            onValueChanged: (value) {
                              if (!submitting && !app.busy && value != null) {
                                change(() {
                                  draft.kind = value;
                                  if (value == EntryKind.income &&
                                      draft.categoryId == null) {
                                    draft.categoryId = null;
                                  }
                                });
                              }
                            },
                            children: {
                              for (final kind in EntryKind.values)
                                kind: SegmentLabel(switch (kind) {
                                  EntryKind.expense => 'Expense',
                                  EntryKind.income => 'Income',
                                  EntryKind.transfer => 'Transfer',
                                }, key: ValueKey('entry-kind-${kind.name}')),
                            },
                          ),
                        ),
                      ),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, amountBounds) => SingleChildScrollView(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: amountBounds.maxHeight,
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const SizedBox(height: 8),
                                  Semantics(
                                    label:
                                        'Amount in Philippine pesos, ${draft.amount.isEmpty ? 'zero' : draft.amount}',
                                    liveRegion: true,
                                    child: ExcludeSemantics(
                                      child: SizedBox(
                                        height: small ? 58 : 96,
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          children: [
                                            Text(
                                              '₱',
                                              style: textStyle(
                                                context,
                                                size: 29,
                                                weight: FontWeight.w500,
                                                color: p.secondary,
                                              ),
                                            ),
                                            const SizedBox(width: 10),
                                            Flexible(
                                              child: FittedBox(
                                                fit: BoxFit.scaleDown,
                                                child: Text(
                                                  draft.amount.isEmpty
                                                      ? '0'
                                                      : draft.amount,
                                                  style: textStyle(
                                                    context,
                                                    size: small ? 54 : 72,
                                                    weight: FontWeight.w500,
                                                    tabular: true,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Press(
                                        onPressed: app.busy ? null : chooseDate,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 14,
                                          vertical: 10,
                                        ),
                                        label:
                                            'Edit date, ${shortDate(draft.date)}',
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              CupertinoIcons.calendar,
                                              size: 16,
                                              color: p.secondary,
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              '${isToday ? 'Today, ' : ''}${shortDate(draft.date)}',
                                              style: textStyle(
                                                context,
                                                size: 13,
                                                color: p.secondary,
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            Icon(
                                              CupertinoIcons.chevron_down,
                                              size: 11,
                                              color: p.secondary,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  if (!small)
                                    Press(
                                      onPressed: app.busy ? null : note,
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 10,
                                        horizontal: 12,
                                      ),
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Icon(
                                            CupertinoIcons.pencil,
                                            color: p.secondary,
                                            size: 16,
                                          ),
                                          const SizedBox(width: 8),
                                          Flexible(
                                            child: Text(
                                              draft.note.isEmpty
                                                  ? 'Add a note'
                                                  : draft.note,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: textStyle(
                                                context,
                                                size: 13,
                                                color: p.secondary,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ErrorLine(app.storageError ?? app.draftError),
                                  const SizedBox(height: 8),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 4,
                        ),
                        child: isTransfer
                            ? Row(
                                children: [
                                  Expanded(
                                    child: Press(
                                      key: const ValueKey('transfer-from'),
                                      color: p.surface,
                                      label:
                                          'Transfer from ${app.ledger.wallet(draft.from)?.label ?? "Choose wallet"}',
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 12,
                                      ),
                                      onPressed: app.busy
                                          ? null
                                          : () async {
                                              final w = await chooseWallet(
                                                context,
                                                selectableWallets,
                                                title: 'Transfer from',
                                              );
                                              if (w != null && mounted) {
                                                change(() => draft.from = w);
                                              }
                                            },
                                      child: Text(
                                        app.ledger.wallet(draft.from)?.label ??
                                            'From',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: textStyle(context, size: 14),
                                      ),
                                    ),
                                  ),
                                  Press(
                                    label: 'Reverse transfer direction',
                                    padding: const EdgeInsets.all(8),
                                    onPressed: app.busy
                                        ? null
                                        : () => change(() {
                                            final from = draft.from;
                                            draft.from = draft.to;
                                            draft.to = from;
                                          }),
                                    child: Icon(
                                      CupertinoIcons.arrow_right_arrow_left,
                                      color: p.accent,
                                      size: 20,
                                    ),
                                  ),
                                  Expanded(
                                    child: Press(
                                      key: const ValueKey('transfer-to'),
                                      color: p.surface,
                                      label:
                                          'Transfer to ${app.ledger.wallet(draft.to)?.label ?? "Choose wallet"}',
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 12,
                                      ),
                                      onPressed: app.busy
                                          ? null
                                          : () async {
                                              final w = await chooseWallet(
                                                context,
                                                selectableWallets,
                                                title: 'Transfer to',
                                              );
                                              if (w != null && mounted) {
                                                change(() => draft.to = w);
                                              }
                                            },
                                      child: Text(
                                        app.ledger.wallet(draft.to)?.label ??
                                            'To',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: textStyle(context, size: 14),
                                      ),
                                    ),
                                  ),
                                ],
                              )
                            : Row(
                                children: [
                                  Expanded(
                                    child: SingleChildScrollView(
                                      scrollDirection: Axis.horizontal,
                                      child: Row(
                                        children: quickCategories
                                            .map(
                                              (c) => Padding(
                                                padding: const EdgeInsets.only(
                                                  right: 8,
                                                ),
                                                child: Press(
                                                  key: c.id == draft.categoryId
                                                      ? selectedCategoryKey
                                                      : null,
                                                  onPressed: app.busy
                                                      ? null
                                                      : () => change(
                                                          () =>
                                                              draft.categoryId =
                                                                  c.id,
                                                        ),
                                                  color:
                                                      c.id == draft.categoryId
                                                      ? categoryColor(
                                                          context,
                                                          c.icon,
                                                        ).withValues(alpha: .14)
                                                      : p.surface,
                                                  label:
                                                      '${c.name} category${c.id == draft.categoryId ? ', selected' : ''}',
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 12,
                                                        vertical: 12,
                                                      ),
                                                  radius: 14,
                                                  child: Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Icon(
                                                        categoryIcon(c.icon),
                                                        size: 18,
                                                        color: categoryColor(
                                                          context,
                                                          c.icon,
                                                        ),
                                                      ),
                                                      const SizedBox(width: 6),
                                                      Text(
                                                        c.name,
                                                        style: textStyle(
                                                          context,
                                                          size: 13,
                                                          weight:
                                                              FontWeight.w600,
                                                          color: categoryColor(
                                                            context,
                                                            c.icon,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            )
                                            .toList(),
                                      ),
                                    ),
                                  ),
                                  Press(
                                    label: 'All categories',
                                    onPressed: app.busy ? null : chooseCategory,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 12,
                                    ),
                                    child: Icon(
                                      CupertinoIcons.ellipsis,
                                      color: p.accent,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          24,
                          small ? 2 : 4,
                          24,
                          small ? 6 : 8,
                        ),
                        child: Column(
                          children: [
                            for (final row in const [
                              ['1', '2', '3'],
                              ['4', '5', '6'],
                              ['7', '8', '9'],
                              ['.', '0', '⌫'],
                            ])
                              Row(
                                children: row
                                    .map(
                                      (key) => Expanded(
                                        child: Padding(
                                          padding: EdgeInsets.all(
                                            small ? 3 : 4,
                                          ),
                                          child: Press(
                                            key: ValueKey('key-$key'),
                                            onPressed: submitting || app.busy
                                                ? null
                                                : () => digit(key),
                                            padding: EdgeInsets.symmetric(
                                              vertical: small ? 0 : 12,
                                            ),
                                            radius: 18,
                                            color: p.surface,
                                            label: key == '⌫'
                                                ? 'Delete last digit'
                                                : key == '.'
                                                ? 'Decimal point'
                                                : 'Digit $key',
                                            child: key == '⌫'
                                                ? Icon(
                                                    CupertinoIcons.delete_left,
                                                    size: 24,
                                                    color: p.ink,
                                                  )
                                                : Text(
                                                    key,
                                                    style: textStyle(
                                                      context,
                                                      size: small ? 24 : 30,
                                                      weight: FontWeight.w400,
                                                      tabular: true,
                                                    ),
                                                  ),
                                          ),
                                        ),
                                      ),
                                    )
                                    .toList(),
                              ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                        child: isTransfer
                            ? PrimaryButton(
                                'Record ${app.ledger.wallet(draft.from)?.label ?? "From"} → ${app.ledger.wallet(draft.to)?.label ?? "To"}',
                                icon: CupertinoIcons.arrow_right_arrow_left,
                                onPressed: submitting || app.busy
                                    ? null
                                    : () => save(draft.from),
                              )
                            : Row(
                                children: [
                                  Expanded(
                                    child: _SaveWallet(
                                      wallet: app.ledger.quickWallets.first,
                                      kind: draft.kind,
                                      onPressed: submitting || app.busy
                                          ? null
                                          : () => save(
                                              app.ledger.quickWallets.first,
                                            ),
                                    ),
                                  ),
                                  if (app.ledger.quickWallets.length > 1)
                                    const SizedBox(width: 12),
                                  if (app.ledger.quickWallets.length > 1)
                                    Expanded(
                                      child: _SaveWallet(
                                        wallet: app.ledger.quickWallets[1],
                                        kind: draft.kind,
                                        onPressed: submitting || app.busy
                                            ? null
                                            : () => save(
                                                app.ledger.quickWallets[1],
                                              ),
                                      ),
                                    ),
                                  if (selectableWallets.length >
                                      app.ledger.quickWallets.length) ...[
                                    const SizedBox(width: 8),
                                    Press(
                                      key: const ValueKey('more-wallets'),
                                      label: 'More wallets',
                                      padding: const EdgeInsets.all(8),
                                      color: p.surface,
                                      onPressed: submitting || app.busy
                                          ? null
                                          : () async {
                                              final w = await chooseWallet(
                                                context,
                                                selectableWallets,
                                                title: entryAction(draft.kind),
                                              );
                                              if (w != null && mounted) {
                                                await save(w);
                                              }
                                            },
                                      child: Icon(
                                        CupertinoIcons.ellipsis,
                                        color: p.accent,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                      ),
                    ],
                  );
                  if (constraints.maxHeight < 480 &&
                      constraints.maxWidth >= 620) {
                    // Two working columns keep typing and final wallet actions
                    // in the first landscape viewport, with full touch targets.
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: Column(
                            children: content.children.take(4).toList(),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 20),
                          child: Container(width: .5, color: p.line),
                        ),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: content.children.skip(4).toList(),
                          ),
                        ),
                      ],
                    );
                  }
                  return constraints.maxHeight < 480
                      ? SingleChildScrollView(
                          child: SizedBox(height: 640, child: content),
                        )
                      : content;
                },
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _SaveWallet extends StatelessWidget {
  const _SaveWallet({required this.wallet, required this.kind, this.onPressed});
  final Wallet wallet;
  final EntryKind kind;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final tone = walletColor(context, wallet);
    final foreground = p.dark ? p.background : const Color(0xFFFFFFFF);
    return Press(
      key: ValueKey('save-${wallet.name}'),
      label: '${entryAction(kind)} ${wallet.label}',
      color: tone,
      onPressed: onPressed,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      radius: 20,
      child: Column(
        children: [
          Text(
            entryAction(kind),
            style: textStyle(
              context,
              size: 12,
              weight: FontWeight.w500,
              color: foreground,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (MediaQuery.textScalerOf(context).scale(1) <= 1.25) ...[
                Icon(walletIcon(wallet.icon), color: foreground, size: 19),
                const SizedBox(width: 7),
              ],
              Flexible(
                child: Text(
                  wallet.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textStyle(
                    context,
                    size: 17,
                    weight: FontWeight.w600,
                    color: foreground,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
