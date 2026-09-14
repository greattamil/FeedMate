import 'package:flutter/material.dart';

import 'cart_panel.dart';

/// A standalone cart/checkout page. All of the actual behavior (quoting,
/// tenders, checkout, offline queuing) lives in [CartPanel] — this route
/// exists for any caller that wants a dedicated cart page rather than the
/// single-screen POS layout (see PosScreen), and stays a thin wrapper so
/// that behavior can never drift between the two hosts.
class CartScreen extends StatelessWidget {
  const CartScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text('Checkout & Cart', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      ),
      body: const CartPanel(),
    );
  }
}
