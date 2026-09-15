/// Media and container extensions a student never needs to see.
const Set<String> _hiddenExtensions = {
  '.amo', '.mp4', '.m4v', '.mov', '.mkv', '.webm', '.avi', '.wmv', '.flv',
  '.3gp', '.mpg', '.mpeg', '.pdf',
};

/// A teacher-chosen course extension (`.nhb`, `.omc`): starts with a letter,
/// two to five characters. The Encryptor names every file `<name>.<ext>`, and
/// the apps are not told the course's extension, so it is recognised by shape.
/// A digit-led tail (`Lesson 1.2`) is part of the title and stays.
final RegExp _courseExtension = RegExp(r'^\.[A-Za-z][A-Za-z0-9]{1,4}$');

/// [fileName] as the student sees it: known media extensions removed, plus a
/// single course extension at the end. Display only — keep the full name for
/// keys, lookups, search and storage.
String displayFileName(String fileName) {
  var name = fileName;
  var courseExtStripped = false;
  while (true) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0) break;
    final ext = name.substring(dot);
    if (_hiddenExtensions.contains(ext.toLowerCase())) {
      name = name.substring(0, dot);
    } else if (!courseExtStripped && _courseExtension.hasMatch(ext)) {
      courseExtStripped = true;
      name = name.substring(0, dot);
    } else {
      break;
    }
  }
  name = name.trim();
  return name.isEmpty ? fileName : name;
}
