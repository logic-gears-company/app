import 'package:Kelivo/core/services/axis_cloud_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The WebDAV root as the server reports it in the credentials.
final _root = Uri.parse('https://cloud.test/dav/');

/// A trimmed 207 Multi-Status body: the collection itself, two subfolders and
/// two files, one of them with a name that needs percent-decoding.
const _multistatus = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/</d:href>
    <d:propstat>
      <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/notes/</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>notes</d:displayname>
        <d:resourcetype><d:collection/></d:resourcetype>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/archive/</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>archive</d:displayname>
        <d:resourcetype><d:collection/></d:resourcetype>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/my%20notes.md</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>my notes.md</d:displayname>
        <d:getcontentlength>42</d:getcontentlength>
        <d:getlastmodified>Mon, 22 Sep 2026 10:00:00 GMT</d:getlastmodified>
        <d:getetag>"abc"</d:getetag>
        <d:resourcetype/>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/report.pdf</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>report.pdf</d:displayname>
        <d:getcontentlength>7</d:getcontentlength>
        <d:resourcetype/>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>
''';

/// Captured verbatim from the production AXIS WebDAV endpoint
/// (207 Multi-Status for PROPFIND Depth:1 on the root). Locked in so a change
/// in the server's href shape or date format cannot silently break the client.
const _realMultistatus =
    '<?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:"><d:response><d:href>/webdav/</d:href><d:propstat><d:prop><d:displayname>AXIS Cloud</d:displayname><d:getcontentlength>4</d:getcontentlength><d:getlastmodified>Mon, 28 Sep 2026 14:59:48 GMT</d:getlastmodified><d:getetag>root</d:getetag><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response><d:response><d:href>/webdav/notas/</d:href><d:propstat><d:prop><d:displayname>notas</d:displayname><d:getcontentlength>0</d:getcontentlength><d:getlastmodified>Mon, 28 Sep 2026 14:59:41 GMT</d:getlastmodified><d:getetag></d:getetag><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>';

void main() {
  group('AxisCloudService.parsePropfind', () {
    test('drops the collection itself and returns only its children', () {
      final entries = AxisCloudService.parsePropfind(
        _multistatus,
        rootUri: _root,
        path: '',
      );

      expect(entries.map((e) => e.name), isNot(contains('dav')));
      expect(entries, hasLength(4));
    });

    test('sorts directories before files, then by name', () {
      final entries = AxisCloudService.parsePropfind(
        _multistatus,
        rootUri: _root,
        path: '',
      );

      expect(entries.map((e) => e.name), [
        'archive',
        'notes',
        'my notes.md',
        'report.pdf',
      ]);
      expect(entries.take(2).every((e) => e.isDirectory), isTrue);
      expect(entries.skip(2).every((e) => !e.isDirectory), isTrue);
    });

    test('reads size, modification date and etag of a file', () {
      final entries = AxisCloudService.parsePropfind(
        _multistatus,
        rootUri: _root,
        path: '',
      );
      final notes = entries.firstWhere((e) => e.name == 'my notes.md');

      expect(notes.isDirectory, isFalse);
      expect(notes.size, 42);
      expect(notes.modified, DateTime(2026, 9, 22, 10));
      expect(notes.etag, '"abc"');
    });

    test('decodes percent-encoded names and exposes a usable path', () {
      final entries = AxisCloudService.parsePropfind(
        _multistatus,
        rootUri: _root,
        path: '',
      );
      final notes = entries.firstWhere((e) => e.name == 'my notes.md');

      expect(notes.name, 'my notes.md');
      expect(notes.path, '/my notes.md');
      expect(notes.path.endsWith('/'), isFalse);
    });

    test('falls back to the last path segment when displayname is absent', () {
      const body = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/deep/unnamed%20file.txt</d:href>
    <d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat>
  </d:response>
</d:multistatus>
''';
      final entries = AxisCloudService.parsePropfind(
        body,
        rootUri: _root,
        path: '',
      );

      expect(entries, hasLength(1));
      expect(entries.single.name, 'unnamed file.txt');
      expect(entries.single.size, 0);
      expect(entries.single.modified, isNull);
    });

    test('skips the collection it was asked about, not just the root', () {
      const body = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/notes/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/notes/child.md</d:href>
    <d:propstat><d:prop><d:displayname>child.md</d:displayname><d:resourcetype/></d:prop></d:propstat>
  </d:response>
</d:multistatus>
''';

      expect(
        AxisCloudService.parsePropfind(body, rootUri: _root, path: 'notes'),
        hasLength(1),
      );
      expect(
        AxisCloudService.parsePropfind(body, rootUri: _root, path: '/notes/'),
        hasLength(1),
      );
      expect(
        AxisCloudService.parsePropfind(
          body,
          rootUri: _root,
          path: 'notes',
        ).single.name,
        'child.md',
      );
    });

    test('returns nothing for an empty collection', () {
      const body = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
  </d:response>
</d:multistatus>
''';

      expect(
        AxisCloudService.parsePropfind(body, rootUri: _root, path: ''),
        isEmpty,
      );
    });
  });

  group('against a real production 207 body', () {
    final root = Uri.parse(
      'https://pointy-earthen-museum.ngrok-free.dev/webdav/',
    );

    test('skips the AXIS Cloud root and returns the child folders', () {
      final entries = AxisCloudService.parsePropfind(
        _realMultistatus,
        rootUri: root,
        path: '',
      );

      expect(entries.map((e) => e.name), isNot(contains('AXIS Cloud')));
      expect(entries, isNotEmpty);
      expect(entries.every((e) => e.isDirectory), isTrue);
    });

    test(
      'returns paths relative to the WebDAV root so they can be re-listed',
      () {
        final entries = AxisCloudService.parsePropfind(
          _realMultistatus,
          rootUri: root,
          path: '',
        );

        for (final entry in entries) {
          expect(entry.path, startsWith('/'));
          expect(entry.path, isNot(startsWith('/webdav')));
          expect(entry.path, isNot(endsWith('/')));
        }
        expect(entries.map((e) => e.path), contains('/notas'));
      },
    );

    test('parses the HTTP-date the server actually sends', () {
      final entries = AxisCloudService.parsePropfind(
        _realMultistatus,
        rootUri: root,
        path: '',
      );

      expect(entries.every((e) => e.modified != null), isTrue);
    });
  });
}
