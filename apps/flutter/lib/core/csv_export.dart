import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// One field of a CSV row, quoted per RFC 4180 whenever it contains a
/// comma, quote, or newline — the three characters that would otherwise
/// break a naive comma-join.
String _csvField(String value) {
  if (value.contains(',') || value.contains('"') || value.contains('\n')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}

/// Builds RFC 4180 CSV text from a header row and data rows. Every report
/// export in this app goes through this one function so the quoting rule
/// is applied consistently everywhere.
String buildCsv(List<String> headers, List<List<String>> rows) {
  final buffer = StringBuffer();
  buffer.writeln(headers.map(_csvField).join(','));
  for (final row in rows) {
    buffer.writeln(row.map(_csvField).join(','));
  }
  return buffer.toString();
}

/// Writes CSV text to a temp file and opens the platform share sheet for
/// it — the shop owner can save it, email it to their accountant, or send
/// it over WhatsApp as a real .csv attachment (not just shared as plain
/// text, which most apps would otherwise mangle or truncate).
Future<void> shareCsv({required String fileName, required List<String> headers, required List<List<String>> rows}) async {
  final csv = buildCsv(headers, rows);
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$fileName');
  await file.writeAsString(csv);
  await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], fileNameOverrides: [fileName]));
}
