import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'axis_auth_service.dart';

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

  Future<http.Response> list([String path = '']) async {
    final c = await _credentials();
    final req = http.Request('PROPFIND', _uri(c['url']!, path));
    req.headers.addAll({
      ..._headers(c),
      'Depth': '1',
      'Content-Type': 'application/xml',
    });
    req.body =
        '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:getcontentlength/><d:getlastmodified/><d:getetag/><d:resourcetype/></d:prop></d:propfind>';
    final response = await http.Response.fromStream(await req.send());
    if (response.statusCode == 401) {
      await auth.provisionWebDav();
      return list(path);
    }
    return response;
  }
}
