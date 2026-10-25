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

  /// On a narrow phone, catalog and cart used to share the screen 50/50
  /// (catalog on top, cart below) — cramped enough on its own, and the
  /// direct cause of split-payment's extra tender rows pushing the Pay
  /// button off-screen (see CartPanel.useGuidedSteps's doc comment). Now
  /// the cart takes over the full screen once the cashier taps through to
  /// it, with its own guided stages, and catalog browsing gets the full
  /// screen the rest of the time — never two cramped halves at once.
  bool _mobileShowCart = false;

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

  Widget _cartHeader({VoidCallback? onBack}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Row(
        children: [
          if (onBack != null) ...[
            IconButton(
              key: const Key('mobile_cart_back'),
              icon: const Icon(Icons.arrow_back_rounded),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: onBack,
            ),
            const SizedBox(width: 6),
          ],
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              gradient: AppColors.gradientIndigo,
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: AppColors.secondary.withValues(alpha: 0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: const Icon(Icons.shopping_cart_rounded, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 10),
          Text('Cart', style: AppTypography.title.copyWith(fontSize: 16, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  /// A phone-only floating bar shown while browsing the catalog once the
  /// cart has at least one item — tapping it switches to the full-screen
  /// cart (see [_mobileShowCart]), which is where quantity, customer and
  /// payment all live now via CartPanel's guided stages.
  Widget _mobileCartBar(CartModel cart) {
    return SafeArea(
      top: false,
      child: Material(
        color: AppColors.primary,
        child: InkWell(
          key: const Key('mobile_view_cart_bar'),
          onTap: () => setState(() => _mobileShowCart = true),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Row(
              children: [
                const Icon(Icons.shopping_cart_rounded, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Text(
                  '${cart.itemCount} item${cart.itemCount == 1 ? '' : 's'} in cart',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const Spacer(),
                const Text('View Cart', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(width: 4),
                const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AuthSession>();
    final cart = context.watch<CartModel>();
    // An emptied cart (e.g. right after a completed sale) has nothing left
    // to show full-screen — fall back to browsing automatically rather
    // than leaving the cashier stuck looking at an empty-cart message with
    // no way back to the catalog except the guided stage's own back arrow.
    if (cart.isEmpty && _mobileShowCart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _mobileShowCart = false);
      });
    }

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

          if (isWide) {
            // Plenty of vertical space either way on a wide screen —
            // catalog and cart stay side by side, cart keeps the classic
            // single-screen layout (CartPanel's default, useGuidedSteps:
            // false) that a cashier can scan fastest when there's room.
            final cartSide = DecoratedBox(
              key: const Key('cart_panel_container'),
              decoration: const BoxDecoration(
                color: AppColors.surface,
                border: Border(left: BorderSide(color: AppColors.border)),
              ),
              child: Column(
                children: [
                  _cartHeader(),
                  const Divider(height: 1, color: AppColors.border),
                  const Expanded(child: CartPanel(standalone: false)),
                ],
              ),
            );
            return Row(
              children: [
                Expanded(flex: 3, child: catalog),
                SizedBox(width: 380, child: cartSide),
              ],
            );
          }

          // Narrow/phone: catalog and cart used to split the screen in
          // half permanently — the direct cause of the cart's checkout
          // controls (especially split payment's extra tender rows)
          // regularly overflowing below the visible screen. Now only one
          // of the two ever shows at a time, each getting the full
          // screen, with a floating bar to move between them.
          if (_mobileShowCart && !cart.isEmpty) {
            return DecoratedBox(
              key: const Key('cart_panel_container'),
              decoration: const BoxDecoration(color: AppColors.surface),
              child: Column(
                children: [
                  _cartHeader(onBack: () => setState(() => _mobileShowCart = false)),
                  const Divider(height: 1, color: AppColors.border),
                  const Expanded(child: CartPanel(standalone: false, useGuidedSteps: true)),
                ],
              ),
            );
          }
          return Column(
            children: [
              Expanded(child: catalog),
              if (!cart.isEmpty) _mobileCartBar(cart),
            ],
          );
        },
      ),
    );
  }
}
