import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import 'axis_auth_service.dart';

/// One entry of a WebDAV collection, as returned by [AxisCloudService.list].
class AxisCloudEntry {
  final String name;
  final String path;
  final bool isDirectory;
  final int size;
  final DateTime? modified;
  final String? etag;

  const AxisCloudEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size = 0,
    this.modified,
    this.etag,
  });
}

class AxisCloudService {
  final AxisAuthService auth;
  AxisCloudService(this.auth);

  Future<Map<String, String>> _credentials() => auth.webDavCredentials();

  Map<String, String> _headers(Map<String, String> c) => {
    'Authorization':
        'Basic ${base64Encode(utf8.encode('${c['username']}:${c['secret']}'))}',
  };

  Uri _uri(String base, String path) {
    final cleanBase = base.endsWith('/')
        ? base.substring(0, base.length - 1)
        : base;
    final cleanPath = path.replaceAll(RegExp(r'^/+'), '');
    return Uri.parse('$cleanBase/${Uri.encodeFull(cleanPath)}');
  }

  Future<http.Response> _send(
    String method,
    Uri uri,
    Map<String, String> headers, {
    File? file,
    List<int>? body,
  }) async {
    final request = http.StreamedRequest(method, uri);
    request.headers.addAll(headers);
    if (file != null) {
      final length = await file.length();
      request.contentLength = length;
      await request.sink.addStream(file.openRead());
      await request.sink.close();
    } else {
      if (body != null) request.contentLength = body.length;
      if (body != null) request.sink.add(body);
      await request.sink.close();
    }
    return http.Response.fromStream(await request.send());
  }

  Future<http.Response> _withRefresh(
    Future<http.Response> Function(String access) action,
  ) async {
    var access = await auth.accessToken();
    if (access == null) throw const AxisAuthException('Not signed in');
    var response = await action(access);
    if ((response.statusCode == 401 || response.statusCode == 403) &&
        await auth.refresh()) {
      access = await auth.accessToken();
      response = await action(access!);
    }
    return response;
  }

  Future<http.Response> upload(
    String path,
    File file, {
    String mime = 'application/octet-stream',
  }) async {
    final c = await _credentials();
    final response = await _send('PUT', _uri(c['url']!, path), {
      ..._headers(c),
      'Content-Type': mime,
    }, file: file);
    if (response.statusCode == 401) {
      await auth.provisionWebDav();
      return upload(path, file, mime: mime);
    }
    return response;
  }

  Future<http.Response> download(String path, File destination) async {
    final c = await _credentials();
    var response = await _withRefresh((_) async {
      final req = http.Request('GET', _uri(c['url']!, path));
      req.headers.addAll(_headers(c));
      return http.Response.fromStream(await req.send());
    });
    if (response.statusCode == 401) {
      await auth.provisionWebDav();
      return download(path, destination);
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      await destination.writeAsBytes(response.bodyBytes);
    }
    return response;
  }

  Future<http.Response> delete(String path) async {
    final c = await _credentials();
    final response = await _send('DELETE', _uri(c['url']!, path), _headers(c));
    if (response.statusCode == 401) {
      await auth.provisionWebDav();
      return delete(path);
    }
    return response;
  }

  /// Lists the direct children of [path] (the collection root when empty).
  ///
  /// The first PROPFIND response always describes the collection itself, so it
  /// is dropped; only its children are returned. Directories come first, then
  /// files, each group sorted by name.
  Future<List<AxisCloudEntry>> list([String path = '']) async {
    final c = await _credentials();
    final rootUri = Uri.parse(c['url']!);
    final req = http.Request('PROPFIND', _uri(c['url']!, path));
    req.headers.addAll({
      ..._headers(c),
      'Depth': '1',
      'Content-Type': 'application/xml; charset=utf-8',
    });
    req.body =
        '<?xml version="1.0" encoding="utf-8" ?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:getcontentlength/><d:getlastmodified/><d:getetag/><d:resourcetype/></d:prop></d:propfind>';
    final response = await http.Response.fromStream(await req.send());
    if (response.statusCode == 401) {
      await auth.provisionWebDav();
      return list(path);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxisAuthException(
        'AXIS Cloud could not list "$path" (HTTP ${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
    return parsePropfind(response.body, rootUri: rootUri, path: path);
  }

  /// Exposed for tests: turns a `207 Multi-Status` body into entries.
  ///
  /// [rootUri] is the WebDAV collection root taken from the credentials. It is
  /// needed because hrefs are absolute server paths while [path] is relative to
  /// that root. Entry paths are returned relative to the root, so they can be
  /// passed straight back into [list] and the other methods.
  @visibleForTesting
  static List<AxisCloudEntry> parsePropfind(
    String body, {
    required Uri rootUri,
    required String path,
  }) {
    final root = rootUri.toString();
    final rootPath = _normalize(Uri.parse(root).path);
    final collectionUri = _withoutTrailingSlash(
      Uri.parse(root).resolve(_relativePath(path)).toString(),
    );
    final doc = XmlDocument.parse(body);
    final entries = <AxisCloudEntry>[];
    for (final resp in doc.findAllElements('response', namespace: '*')) {
      final href = resp.getElement('href', namespace: '*')?.innerText ?? '';
      if (href.isEmpty) continue;
      // hrefs are percent-encoded, so resolve the raw href and let Uri do the
      // decoding; the collection we asked about is matched on the resolved URL.
      final absolute = Uri.parse(root).resolve(href).toString();
      if (_withoutTrailingSlash(absolute) == collectionUri) continue;
      // Uri.path keeps percent-encoding; pathSegments is the decoded form.
      final absolutePath = _normalizeSegments(Uri.parse(absolute).pathSegments);
      final entryPath = absolutePath.startsWith(rootPath)
          ? absolutePath.substring(rootPath.length)
          : absolutePath;
      final displayName = _first(resp, 'displayname')?.trim();
      final name = (displayName != null && displayName.isNotEmpty)
          ? displayName
          : _nameFromPath(absolutePath);
      if (name.isEmpty) continue;
      entries.add(
        AxisCloudEntry(
          name: name,
          path: entryPath.isEmpty ? '/' : entryPath,
          isDirectory:
              resp
                  .getElement('propstat', namespace: '*')
                  ?.getElement('prop', namespace: '*')
                  ?.getElement('resourcetype', namespace: '*')
                  ?.getElement('collection', namespace: '*') !=
              null,
          size: int.tryParse(_first(resp, 'getcontentlength') ?? '') ?? 0,
          modified: _parseModified(_first(resp, 'getlastmodified')),
          etag: _first(resp, 'getetag'),
        ),
      );
    }
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  static String? _first(XmlElement response, String localName) {
    final found = response
        .findAllElements(localName, namespace: '*')
        .map((e) => e.innerText)
        .firstWhere((v) => v.isNotEmpty, orElse: () => '');
    return found.isEmpty ? null : found;
  }

  /// WebDAV `getlastmodified` is an HTTP-date (RFC 1123), which `DateTime.parse`
  /// rejects. Some servers send ISO-8601 instead, so both are accepted.
  static DateTime? _parseModified(String? value) {
    if (value == null || value.isEmpty) return null;
    final iso = DateTime.tryParse(value);
    if (iso != null) return iso.toLocal();
    try {
      return HttpDate.parse(value).toLocal();
    } catch (_) {
      return null;
    }
  }

  static String _withoutTrailingSlash(String value) {
    return value.length > 1 && value.endsWith('/')
        ? value.substring(0, value.length - 1)
        : value;
  }

  /// Builds a relative, percent-encoded href for [path] so it can be resolved
  /// against the WebDAV root without re-encoding the existing segments.
  static String _relativePath(String path) {
    final segments = path.split('/').where((s) => s.isNotEmpty);
    if (segments.isEmpty) return '';
    return '${segments.map(Uri.encodeComponent).join('/')}/';
  }

  /// Strips leading/trailing slashes and collapses duplicates, so "", "/" and
  /// "folder/" all compare equal for the same collection.
  static String _normalize(String path) {
    final segments = path
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    return '/${segments.join('/')}';
  }

  static String _normalizeSegments(List<String> segments) {
    final kept = segments.where((s) => s.isNotEmpty).toList(growable: false);
    return '/${kept.join('/')}';
  }

  static String _nameFromPath(String normalizedPath) {
    final segments = normalizedPath.split('/').where((s) => s.isNotEmpty);
    return segments.isEmpty ? '' : segments.last;
  }
}
