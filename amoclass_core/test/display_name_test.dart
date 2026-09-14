import 'package:amo_core/amo_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('strips known media extensions, case-insensitively', () {
    expect(displayFileName('Lesson 1.mp4'), 'Lesson 1');
    expect(displayFileName('Notes.PDF'), 'Notes');
    expect(displayFileName('intro.MOV'), 'intro');
  });

  test('strips stacked extensions', () {
    expect(displayFileName('lesson.mp4.amo'), 'lesson');
    expect(displayFileName('sheet.pdf.amo'), 'sheet');
  });

  test('keeps dots that are part of the title', () {
    expect(displayFileName('Lesson 1.2'), 'Lesson 1.2');
    expect(displayFileName('Lesson 1.2.mp4'), 'Lesson 1.2');
    expect(displayFileName('v2.final.docx'), 'v2.final.docx');
  });

  test('never returns an empty name', () {
    expect(displayFileName('.mp4'), '.mp4');
    expect(displayFileName('   .pdf'), '   .pdf');
    expect(displayFileName(''), '');
  });

  test('VideoItem.displayName leaves name untouched', () {
    final item = VideoItem(
      filePath: '/x/الدرس الأول.mp4.amo',
      name: 'الدرس الأول.mp4',
      originalExtension: 'mp4',
      fileSize: 1,
      originalSize: 1,
    );
    expect(item.displayName, 'الدرس الأول');
    expect(item.name, 'الدرس الأول.mp4');
  });
}
