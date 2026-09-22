import 'package:decimal/decimal.dart';
import 'package:intl/intl.dart';

/// The one place every rupee amount and quantity in this app gets its
/// thousand-separator grouping from — a shop owner reading "₹123456.00" at
/// a glance can't tell 1.2 lakh from 12 lakh, which is exactly the
/// confusion this exists to remove. Uses Indian digit grouping
/// (1,23,456.78, not 123,456.78) since the app's users are Tamil Nadu
/// retail shop owners, matching how they already read prices everywhere
/// else (MRP labels, GST invoices, bank statements).
final _moneyFormat = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2);
final _plainMoneyFormat = NumberFormat.decimalPattern('en_IN')..minimumFractionDigits = 2
  ..maximumFractionDigits = 2;
final _intFormat = NumberFormat.decimalPattern('en_IN');

double _toDouble(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  if (value is Decimal) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

/// Formats any amount (Decimal, double, int, or numeric String) as a
/// rupee-symbol string with Indian thousand-separator grouping and exactly
/// two decimal places, e.g. `money(123456.7)` → `"₹1,23,456.70"`.
String money(dynamic value) => _moneyFormat.format(_toDouble(value));

/// Same grouping as [money] but without the ₹ symbol, for contexts that
/// already show a currency icon/label separately (e.g. `₹` rendered as a
/// leading Icon widget rather than text) or that show a bare number that
/// happens to be money (e.g. a table column already headed "Amount").
String moneyPlain(dynamic value) => _plainMoneyFormat.format(_toDouble(value));

/// Formats a quantity (Decimal, double, int, or numeric String) with
/// Indian thousand-separator grouping, keeping decimals only when the
/// value actually has a fractional part (quantities like "68 BAG" read
/// worse as "68.00 BAG") — up to 3 decimal places for fractional
/// quantities (e.g. 12.5 KG), matching this app's existing precision.
String qty(dynamic value) {
  final d = _toDouble(value);
  if (d == d.roundToDouble()) {
    return _intFormat.format(d);
  }
  final f = NumberFormat.decimalPattern('en_IN')..maximumFractionDigits = 3;
  return f.format(d);
}

/// Formats a plain integer count (invoice counts, product counts, etc.)
/// with Indian thousand-separator grouping.
String intGrouped(int value) => _intFormat.format(value);
