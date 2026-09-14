/// Extensions hidden from the names a student sees. Only known media and
/// container suffixes are stripped, so a title with a dot of its own
/// ("Lesson 1.2") keeps it.
const Set<String> _hiddenExtensions = {
  '.amo',
  '.mp4',
  '.m4v',
  '.mov',
  '.mkv',
  '.webm',
  '.avi',
  '.wmv',
  '.flv',
  '.3gp',
  '.mpg',
  '.mpeg',
  '.pdf',
};

/// The name shown to the student for a lesson file: [fileName] without its
/// known extensions, stripped repeatedly so `lesson.mp4.amo` becomes `lesson`.
///
/// Display only. Progress keys, download paths, catalogue lookups and server
/// calls must keep using the full file name.
String displayFileName(String fileName) {
  var name = fileName;
  while (true) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0) break;
    if (!_hiddenExtensions.contains(name.substring(dot).toLowerCase())) break;
    name = name.substring(0, dot);
  }
  name = name.trim();
  return name.isEmpty ? fileName : name;
}
