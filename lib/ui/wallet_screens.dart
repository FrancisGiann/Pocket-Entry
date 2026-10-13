part of 'screens.dart';

class WalletEditorPage extends StatefulWidget {
  const WalletEditorPage({super.key, required this.app, this.wallet});
  final AppController app;
  final Wallet? wallet;
  @override
  State<WalletEditorPage> createState() => _WalletEditorState();
}

class _WalletEditorState extends State<WalletEditorPage> {
  late final String id = widget.wallet?.id ?? newId();
  late final TextEditingController name = TextEditingController(
    text: widget.wallet?.label ?? '',
  );
  late String icon = widget.wallet?.icon ?? 'wallet',
      color = widget.wallet?.color ?? 'plum';
  String? error;
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final value = Wallet(
      id: id,
      label: name.text.trim(),
      icon: icon,
      color: color,
      archived:
          widget.app.ledger.wallet(Wallet.reference(id))?.archived ?? false,
    );
    final ok = await widget.app.setWallet(value);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() => error = widget.app.storageError);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.app,
    builder: (context, _) {
      final p = Palette.of(context), app = widget.app;
      final current = app.ledger.wallet(Wallet.reference(id));
      return PocketPage(
        current == null ? 'New wallet' : 'Wallet settings',
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'Make it yours.',
              style: textStyle(context, size: 27, weight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Manual records only. No bank or e-wallet connection.',
              style: textStyle(context, size: 14, color: p.secondary),
            ),
            const SizedBox(height: 24),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: name,
              builder: (context, value, _) => Center(
                child: Column(
                  children: [
                    IconTile(
                      walletIcon(icon),
                      color: walletColor(
                        context,
                        Wallet(id: id, label: '', color: color),
                      ),
                      size: 72,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      value.text.trim().isEmpty
                          ? 'New wallet'
                          : value.text.trim(),
                      textAlign: TextAlign.center,
                      style: textStyle(
                        context,
                        size: 21,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            CupertinoTextField(
              key: const ValueKey('wallet-name'),
              controller: name,
              maxLength: 30,
              placeholder: 'Wallet name, e.g. Maya',
              placeholderStyle: textStyle(context, color: p.secondary),
              style: textStyle(context),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: p.surface,
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            const SizedBox(height: 24),
            Text('Icon', style: textStyle(context, weight: FontWeight.w600)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final value in walletIcons)
                  Press(
                    key: ValueKey('wallet-icon-$value'),
                    label: '$value icon${icon == value ? ', selected' : ''}',
                    color: icon == value ? p.tint : p.surface,
                    onPressed: app.busy
                        ? null
                        : () => setState(() => icon = value),
                    child: Icon(walletIcon(value), color: p.accent),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            Text('Color', style: textStyle(context, weight: FontWeight.w600)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final value in walletColors)
                  Press(
                    label: '$value color${color == value ? ', selected' : ''}',
                    color: color == value ? p.tint : p.surface,
                    onPressed: app.busy
                        ? null
                        : () => setState(() => color = value),
                    child: Icon(
                      CupertinoIcons.circle_fill,
                      color: walletColor(
                        context,
                        Wallet(id: id, label: '', color: value),
                      ),
                      size: 24,
                    ),
                  ),
              ],
            ),
            if (current != null) ...[
              const SizedBox(height: 24),
              Surface(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    if (!current.archived)
                      GroupRow(
                        'Direct entry button',
                        subtitle: 'Pin up to two wallets. Others stay in More wallets.',
                        trailing: PocketSwitch(
                          label: 'Pin ${current.label} for direct entry',
                          value: app.ledger.preferences.quickWallets.contains(
                            id,
                          ),
                          onChanged: app.busy
                              ? null
                              : (v) async {
                                  await app.pinWallet(current, v);
                                  if (mounted) {
                                    setState(() => error = app.storageError);
                                  }
                                },
                        ),
                      ),
                    GroupRow(
                      current.archived ? 'Unarchive wallet' : 'Archive wallet',
                      subtitle: 'History, transfers and balances are kept.',
                      icon: CupertinoIcons.archivebox,
                      last: true,
                      onTap: app.busy
                          ? null
                          : () async {
                              final ok = await app.setWallet(
                                current.copy(archived: !current.archived),
                              );
                              if (mounted) {
                                setState(
                                  () => error = ok ? null : app.storageError,
                                );
                              }
                            },
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 24),
            ErrorLine(error),
            PrimaryButton('Save wallet', onPressed: app.busy ? null : save),
          ],
        ),
      );
    },
  );
}
