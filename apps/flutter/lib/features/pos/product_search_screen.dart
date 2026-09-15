import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth_session.dart';
import '../../core/local_db.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../auth/login_screen.dart';
import '../sync/outbox_screen.dart';
import 'cart_model.dart';
import 'cart_panel.dart';
import 'catalog_panel.dart';

/// The single-screen POS counter: product catalog and cart/checkout live
/// side by side (or stacked on a narrow phone) on one screen, exactly like a
/// real point-of-sale terminal — tapping a product adds it to the cart and
/// the cart panel updates immediately, with no navigation to a separate
/// cart page required to see it, adjust quantities, or check out.
/// Back-office actions (Customers, GRN, Reports, staff/admin screens, etc.)
/// intentionally do not live here any more — they're one tap away from the
/// Home Dashboard's MANAGE grid — so this screen stays focused on the one
/// thing a cashier is doing at the counter: ringing up a sale.
class ProductSearchScreen extends StatefulWidget {
  const ProductSearchScreen({super.key});

  @override
  State<ProductSearchScreen> createState() => _ProductSearchScreenState();
}

class _ProductSearchScreenState extends State<ProductSearchScreen> {
  int _pendingSyncCount = 0;

  @override
  void initState() {
    super.initState();
    _refreshPendingSyncCount();
  }

  Future<void> _refreshPendingSyncCount() async {
    final localDb = context.read<LocalDatabase>();
    final count = await localDb.pendingInvoiceCount();
    if (!mounted) return;
    setState(() => _pendingSyncCount = count);
  }

  Future<void> _openOutbox() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const OutboxScreen()),
    );
    await _refreshPendingSyncCount();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AuthSession>();
    final cart = context.watch<CartModel>();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(session.displayName ?? 'POS Counter', style: AppTypography.headline),
        actions: [
          IconButton(
            key: const Key('sync_button'),
            tooltip: 'Offline sales outbox',
            icon: Badge(
              key: const Key('pending_sync_badge'),
              label: Text('$_pendingSyncCount'),
              isLabelVisible: _pendingSyncCount > 0,
              backgroundColor: AppColors.warning,
              child: const Icon(Icons.sync_rounded),
            ),
            onPressed: _openOutbox,
          ),
          IconButton(
            icon: const Icon(Icons.logout_rounded),
            tooltip: 'Logout',
            onPressed: () async {
              await session.logout();
              if (!context.mounted) return;
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const LoginScreen()),
              );
            },
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 700;
          final catalog = const CatalogPanel();
          final cartSide = DecoratedBox(
            key: const Key('cart_panel_container'),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border(
                left: isWide ? const BorderSide(color: AppColors.border) : BorderSide.none,
                top: isWide ? BorderSide.none : const BorderSide(color: AppColors.border),
              ),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                  child: Row(
                    children: [
                      const Icon(Icons.shopping_cart_rounded, color: AppColors.primary, size: 20),
                      const SizedBox(width: 8),
                      Text('Cart (${cart.itemCount})', style: AppTypography.title.copyWith(fontSize: 16)),
                    ],
                  ),
                ),
                const Expanded(child: CartPanel(standalone: false)),
              ],
            ),
          );

          if (isWide) {
            return Row(
              children: [
                Expanded(flex: 3, child: catalog),
                SizedBox(width: 380, child: cartSide),
              ],
            );
          }
          return Column(
            children: [
              Expanded(flex: 4, child: catalog),
              Expanded(flex: 5, child: cartSide),
            ],
          );
        },
      ),
    );
  }
}
