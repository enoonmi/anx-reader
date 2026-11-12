import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/sync/sync_client_base.dart';
import 'package:anx_reader/utils/get_path/get_temp_dir.dart';
import 'package:anx_reader/utils/log/common.dart';

/// Applies reading progress pushed by a OnePage e-reader into the local library.
///
/// Why this exists
/// ---------------
/// Anx Reader's own sync treats `database*.db` as the whole world: it uploads a
/// snapshot or replaces the local file, and `syncFiles()` deletes any remote book
/// that is not in `tb_books`. A dedicated e-reader therefore cannot join that
/// protocol without either overwriting the phone's library or being wiped
/// itself.
///
/// So the reader writes progress to a separate file instead:
///
///     anx/onepage/progress.json
///
/// That path is outside `anx/data/`, so `syncFiles()` never touches it, and it is
/// not named `database*.db`, so `determineSyncDirection()` does not mistake it
/// for a database. This service reads it and merges the percentages in.
///
/// What is merged
/// --------------
/// Only `reading_percentage`. `tb_books.last_read_position` holds an EPUB CFI
/// produced by foliate-js; the e-reader has no DOM and cannot produce one, so its
/// value is never written. Leaving the CFI alone means the phone keeps its
/// precise position and the percentage is used only for display and coarse
/// positioning.
///
/// Conflicts
/// ---------
/// The document carries a per-book `updated_at`. An entry is applied only when it
/// is strictly newer than the book's `update_time`, so a device that has been
/// sitting in a drawer cannot drag the phone backwards.
class OnepageProgressMerge {
  /// Remote path the reader writes to.
  static const String remotePath = 'anx/onepage/progress.json';

  /// Schema this build understands.
  static const int supportedSchema = 1;

  /// Result of one merge pass, for logging and for a summary toast.
  class Result {
    Result({this.applied = 0, this.skipped = 0, this.unmatched = 0, this.found = false});

    /// Books whose percentage was updated.
    final int applied;

    /// Entries present in the document but older than the local book.
    final int skipped;

    /// Entries whose `file_path` matched no book in `tb_books`.
    final int unmatched;

    /// Whether the remote document existed at all.
    final bool found;

    bool get hasChanges => applied > 0;

    @override
    String toString() =>
        'onepage merge: applied=$applied skipped=$skipped unmatched=$unmatched found=$found';
  }

  /// Download [remotePath] and merge it into the library.
  ///
  /// Returns an empty [Result] with `found == false` when the file is absent -
  /// that is the normal state for a user who has not set up an e-reader, and it
  /// must not surface as an error.
  static Future<Result> mergeFromClient(SyncClientBase client) async {
    if (!await client.isExist(remotePath)) {
      AnxLog.info('OnepageProgressMerge: no $remotePath on the server');
      return Result();
    }

    // SyncClientBase offers no "read this file into memory" call - only
    // downloadFile - so the document goes through the temp directory. It is a
    // few hundred bytes, so the extra hop costs nothing.
    String raw;
    try {
      final tempDir = await getAnxTempDir();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final localPath = '${tempDir.path}/onepage_progress_$stamp.json';
      await client.downloadFile(remotePath, localPath);

      final file = File(localPath);
      if (!await file.exists()) {
        AnxLog.warning('OnepageProgressMerge: download produced no file');
        return Result();
      }
      raw = await file.readAsString();
      // Best effort: a leftover temp file is harmless, but clean up anyway.
      try {
        await file.delete();
      } catch (_) {}
    } catch (e) {
      AnxLog.warning('OnepageProgressMerge: failed to fetch $remotePath: $e');
      return Result();
    }

    final Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        AnxLog.warning('OnepageProgressMerge: $remotePath is not a JSON object');
        return Result();
      }
      json = decoded;
    } catch (e) {
      AnxLog.warning('OnepageProgressMerge: $remotePath is not valid JSON: $e');
      return Result();
    }

    return mergeDocument(json);
  }

  /// Merge an already-parsed document. Split out from [mergeFromClient] so the
  /// logic can be exercised without a network client.
  static Future<Result> mergeDocument(Map<String, dynamic> json) async {
    final schema = json['schema'];
    if (schema is int && schema > supportedSchema) {
      // A newer reader wrote this. Its extra fields are unknown, but the
      // percentage contract is stable, so carry on rather than refusing.
      AnxLog.info('OnepageProgressMerge: document schema $schema is newer than '
          '$supportedSchema, merging known fields only');
    }

    final books = json['books'];
    if (books is! List) {
      AnxLog.warning('OnepageProgressMerge: document has no books array');
      return Result(found: true);
    }

    // One query instead of one per entry: a library with a few hundred books
    // would otherwise issue a few hundred selects.
    final allBooks = await bookDao.selectBooks();
    final byFilePath = <String, Book>{};
    for (final book in allBooks) {
      byFilePath[book.filePath] = book;
    }

    var applied = 0;
    var skipped = 0;
    var unmatched = 0;

    for (final entry in books) {
      if (entry is! Map<String, dynamic>) continue;

      final filePath = entry['file_path'];
      final percentage = entry['reading_percentage'];
      if (filePath is! String || filePath.isEmpty) continue;
      if (percentage is! num) continue;

      final book = byFilePath[filePath];
      if (book == null) {
        ++unmatched;
        continue;
      }

      final clamped = percentage.toDouble().clamp(0.0, 1.0);

      // Timestamp guard: only a strictly newer position wins, so a stale device
      // cannot pull the phone backwards.
      final updatedAt = _parseTimestamp(entry['updated_at']);
      if (updatedAt != null && !updatedAt.isAfter(book.updateTime)) {
        ++skipped;
        continue;
      }

      // A no-op write still bumps update_time, which would make this book look
      // modified on the next sync and ping-pong forever.
      if ((book.readingPercentage - clamped).abs() < 0.001) {
        ++skipped;
        continue;
      }

      book.readingPercentage = clamped;
      if (updatedAt != null) book.updateTime = updatedAt;
      // lastReadPosition (the CFI) is deliberately untouched: only foliate-js
      // can produce a valid one.
      await bookDao.updateBook(book);
      ++applied;
    }

    final result = Result(applied: applied, skipped: skipped, unmatched: unmatched, found: true);
    AnxLog.info('OnepageProgressMerge: $result');
    return result;
  }

  /// Accept either a Unix timestamp (seconds) or an RFC 1123 string.
  ///
  /// The reader writes `updated_at` as an integer; accepting a string as well
  /// keeps the door open for a human-readable variant without a schema break.
  static DateTime? _parseTimestamp(dynamic value) {
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
    }
    if (value is String) {
      final numeric = int.tryParse(value);
      if (numeric != null) {
        return DateTime.fromMillisecondsSinceEpoch(numeric * 1000, isUtc: true);
      }
      try {
        return DateTime.parse(value);
      } catch (_) {
        return null;
      }
    }
    return null;
  }
}
