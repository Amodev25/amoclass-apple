import 'package:flutter_test/flutter_test.dart';
import 'package:amo_player_apple/services/remote_library_service.dart';

/// The online tab badges PDFs only. The catalogue's `kind` decides; the name
/// and content type still count for rows sent before the server knew it.
void main() {
  RemoteFile file(
    String name, {
    String type = 'application/octet-stream',
    String kind = 'video',
  }) => RemoteFile(
    id: 1,
    displayName: name,
    folderPath: '',
    fileSize: 0,
    contentType: type,
    kind: kind,
    isActive: true,
    uploadedAt: '',
  );

  test('the catalogue kind marks a plain .amo as a PDF', () {
    expect(file('notes.amo', kind: 'pdf').isPdf, isTrue);
    expect(file('lesson.amo').isPdf, isFalse);
  });

  test('kind is read from the catalogue and survives the cache round trip', () {
    final parsed = RemoteFile.fromJson({
      'id': 7,
      'display_name': 'notes.amo',
      'content_type': 'application/octet-stream',
      'kind': 'pdf',
    });
    expect(parsed.isPdf, isTrue);
    expect(RemoteFile.fromJson(parsed.toJson()).kind, 'pdf');
    // A row cached before the field existed reads as a video.
    expect(RemoteFile.fromJson({'id': 8, 'display_name': 'x.amo'}).kind, 'video');
  });

  test('PDF by extension, bare or under a container suffix', () {
    expect(file('notes.pdf').isPdf, isTrue);
    expect(file('Notes.PDF.amo').isPdf, isTrue);
    expect(file('notes', type: 'application/pdf').isPdf, isTrue);
  });

  test('videos and ambiguous names are not PDFs', () {
    expect(file('lesson.mp4.amo').isPdf, isFalse);
    expect(file('lesson.amo').isPdf, isFalse);
    expect(file('pdf.amo').isPdf, isFalse);
    expect(file('pdf').isPdf, isFalse);
  });
}
