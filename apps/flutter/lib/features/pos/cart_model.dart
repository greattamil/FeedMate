import 'package:decimal/decimal.dart';
import 'package:flutter/foundation.dart';

import 'product.dart';

class CartLine {
  final Product product;
  Decimal quantity;

  CartLine({required this.product, required this.quantity});
}

/// Client-side cart state only — no pricing/tax is computed here. The
/// authoritative total always comes from POST /api/v1/pos/quote (a preview)
/// and POST /api/v1/pos/invoices (the real charge), never from arithmetic in
/// this class, so the UI can never show a total the server wouldn't also
/// arrive at (PRD A28: the server is authoritative for pricing/tax).
class CartModel extends ChangeNotifier {
  final List<CartLine> _lines = [];

  List<CartLine> get lines => List.unmodifiable(_lines);
  bool get isEmpty => _lines.isEmpty;
  int get itemCount => _lines.length;

  void addProduct(Product product, {Decimal? quantity}) {
    final qty = quantity ?? Decimal.one;
    final existingIndex = _lines.indexWhere((l) => l.product.id == product.id);
    if (existingIndex >= 0) {
      _lines[existingIndex].quantity += qty;
    } else {
      _lines.add(CartLine(product: product, quantity: qty));
    }
    notifyListeners();
  }

  void updateQuantity(String productId, Decimal quantity) {
    final index = _lines.indexWhere((l) => l.product.id == productId);
    if (index < 0) return;
    if (quantity <= Decimal.zero) {
      _lines.removeAt(index);
    } else {
      _lines[index].quantity = quantity;
    }
    notifyListeners();
  }

  void removeLine(String productId) {
    _lines.removeWhere((l) => l.product.id == productId);
    notifyListeners();
  }

  void clear() {
    _lines.clear();
    notifyListeners();
  }
}
