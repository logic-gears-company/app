import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class AxisAuthException implements Exception {
  final String message;
  final int? statusCode;
  const AxisAuthException(this.message, {this.statusCode});
  @override
  String toString() => message;
}

class AxisAuthService {
  static const baseUrl = String.fromEnvironment(
    'AXIS_BASE_URL',
    defaultValue: 'https://pointy-earthen-museum.ngrok-free.dev',
  );
  static const _accessKey = 'axis.access_token';
  static const _refreshKey = 'axis.refresh_token';
  static const _webDavUrlKey = 'axis.webdav.url';
  static const _webDavUserKey = 'axis.webdav.username';
  static const _webDavSecretKey = 'axis.webdav.secret';
  static const _userIdKey = 'axis.user_id';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<String?> accessToken() => _storage.read(key: _accessKey);
  Future<String?> refreshToken() => _storage.read(key: _refreshKey);
  Future<String?> userId() => _storage.read(key: _userIdKey);

  Future<bool> hasSession() async =>
      (await _storage.read(key: _refreshKey))?.isNotEmpty == true;

  Future<Map<String, dynamic>> _json(http.Response response) async {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return <String, dynamic>{};
  }

  Future<void> login(String email, String password) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/v1/auth/login'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email.trim(), 'password': password}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await _json(response);
      throw AxisAuthException(
        (body['detail'] ?? 'Invalid email or password').toString(),
        statusCode: response.statusCode,
      );
    }
    final body = await _json(response);
    await _saveTokens(body);
    await provisionWebDav();
  }

  Future<void> register(String name, String email, String password) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/v1/auth/register'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'name': name.trim(),
        'email': email.trim(),
        'password': password,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await _json(response);
      throw AxisAuthException(
        (body['detail'] ?? body['message'] ?? 'Registration failed').toString(),
        statusCode: response.statusCode,
      );
    }
    final body = await _json(response);
    // The API creates the same AXIS account and returns the normal session;
    // do not perform a second login request.
    await _saveTokens(body);
    await provisionWebDav();
  }

  Future<void> _saveTokens(Map<String, dynamic> body) async {
    final access = body['access_token']?.toString();
    final refresh = body['refresh_token']?.toString();
    if (access == null || refresh == null) {
      throw const AxisAuthException('AXIS returned an incomplete session');
    }
    await _storage.write(key: _accessKey, value: access);
    await _storage.write(key: _refreshKey, value: refresh);
    final payload = _decodeJwtPayload(access);
    final sub = payload['sub']?.toString();
    if (sub != null) await _storage.write(key: _userIdKey, value: sub);
  }

  Map<String, dynamic> _decodeJwtPayload(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return {};
      final normalized = base64Url.normalize(parts[1]);
      final data = utf8.decode(base64Url.decode(normalized));
      final value = jsonDecode(data);
      return value is Map<String, dynamic> ? value : {};
    } catch (_) {
      return {};
    }
  }

  Future<bool> refresh() async {
    final refresh = await _storage.read(key: _refreshKey);
    if (refresh == null || refresh.isEmpty) return false;
    final response = await http.post(
      Uri.parse('$baseUrl/api/v1/auth/refresh'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'refresh_token': refresh}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await clearLocalSession();
      return false;
    }
    await _saveTokens(await _json(response));
    return true;
  }

  Future<Map<String, String>> webDavCredentials() async {
    final url = await _storage.read(key: _webDavUrlKey);
    final username = await _storage.read(key: _webDavUserKey);
    final secret = await _storage.read(key: _webDavSecretKey);
    if (url != null && username != null && secret != null && url.isNotEmpty) {
      return {'url': url, 'username': username, 'secret': secret};
    }
    return provisionWebDav();
  }

  Future<Map<String, String>> provisionWebDav() async {
    var access = await accessToken();
    if (access == null || access.isEmpty) {
      throw const AxisAuthException('AXIS session is missing');
    }
    var response = await http.post(
      Uri.parse('$baseUrl/api/v1/cloud/webdav/credentials'),
      headers: {'Authorization': 'Bearer $access'},
    );
    if (response.statusCode == 401 && await refresh()) {
      access = await accessToken();
      response = await http.post(
        Uri.parse('$baseUrl/api/v1/cloud/webdav/credentials'),
        headers: {'Authorization': 'Bearer $access'},
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxisAuthException(
        'Could not initialize AXIS Cloud',
        statusCode: response.statusCode,
      );
    }
    final body = await _json(response);
    final url = body['url']?.toString();
    final username = body['username']?.toString();
    final secret = body['secret']?.toString();
    if ([url, username, secret].any((v) => v == null || v.isEmpty)) {
      throw const AxisAuthException(
        'AXIS Cloud returned incomplete credentials',
      );
    }
    await _storage.write(key: _webDavUrlKey, value: url);
    await _storage.write(key: _webDavUserKey, value: username);
    await _storage.write(key: _webDavSecretKey, value: secret);
    return {'url': url!, 'username': username!, 'secret': secret!};
  }

  Future<void> logout() async {
    final access = await _storage.read(key: _accessKey);
    final refresh = await _storage.read(key: _refreshKey);
    if (access != null && access.isNotEmpty) {
      try {
        await http.post(
          Uri.parse('$baseUrl/api/v1/cloud/webdav/credentials/revoke'),
          headers: {'Authorization': 'Bearer $access'},
        );
      } catch (_) {}
    }
    if (refresh != null && refresh.isNotEmpty) {
      try {
        await http.post(
          Uri.parse('$baseUrl/api/v1/auth/logout'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'refresh_token': refresh}),
        );
      } catch (_) {}
    }
    await clearLocalSession();
  }

  Future<void> clearLocalSession() async {
    await _storage.delete(key: _accessKey);
    await _storage.delete(key: _refreshKey);
    await _storage.delete(key: _webDavUrlKey);
    await _storage.delete(key: _webDavUserKey);
    await _storage.delete(key: _webDavSecretKey);
    await _storage.delete(key: _userIdKey);
  }
}
