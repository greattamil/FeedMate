// Unit tests for the CSV-building logic every report export shares.
// Deliberately does not exercise shareCsv() itself (writing a temp file and
// invoking the platform share sheet needs real platform bindings this
// headless test environment doesn't have) — buildCsv() is the part with
// real logic (RFC 4180 quoting) worth testing in isolation.
import 'package:flutter_test/flutter_test.dart';
import 'package:feedmate_app/core/csv_export.dart';

void main() {
  test('builds a simple CSV with header and rows', () {
    final csv = buildCsv(
      ['Name', 'Amount'],
      [
        ['Cattle Feed', '1200.00'],
        ['Poultry Feed', '950.50'],
      ],
    );
    expect(csv, 'Name,Amount\nCattle Feed,1200.00\nPoultry Feed,950.50\n');
  });

  test('quotes a field containing a comma', () {
    final csv = buildCsv(['Description'], [['Cattle Feed, 50kg bag']]);
    expect(csv, 'Description\n"Cattle Feed, 50kg bag"\n');
  });

  test('quotes and escapes a field containing a double quote', () {
    final csv = buildCsv(['Note'], [['Farmer said "thanks"']]);
    expect(csv, 'Note\n"Farmer said ""thanks"""\n');
  });

  test('quotes a field containing a newline', () {
    final csv = buildCsv(['Note'], [['Line one\nLine two']]);
    expect(csv, 'Note\n"Line one\nLine two"\n');
  });

  test('handles an empty row set, producing just the header', () {
    final csv = buildCsv(['A', 'B'], []);
    expect(csv, 'A,B\n');
  });

  test('does not quote a plain field', () {
    final csv = buildCsv(['X'], [['plain value']]);
    expect(csv, 'X\nplain value\n');
  });
}
