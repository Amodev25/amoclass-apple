import 'dart:typed_data';

import '../core/display_name.dart';

/// Represents a media item (video or PDF) in the library
class VideoItem {
  final String filePath;
  final String name;
  final String originalExtension;
  final int fileSize;
  final int originalSize;
  final Uint8List? thumbnail;
  final DateTime addedAt;
  final String? folderName;
  final String contentType; // 'video' or 'pdf'

  VideoItem({
    required this.filePath,
    required this.name,
    required this.originalExtension,
    required this.fileSize,
    required this.originalSize,
    this.thumbnail,
    this.folderName,
    this.contentType = 'video',
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();

  bool get isPdf => contentType == 'pdf';
  bool get isVideo => contentType == 'video';

  /// [name] as the student sees it, without known extensions. Display only:
  /// keep using [name] and [filePath] for keys, lookups and storage.
  String get displayName => displayFileName(name);

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'filePath': filePath,
      'name': name,
      'originalExtension': originalExtension,
      'fileSize': fileSize,
      'originalSize': originalSize,
      'contentType': contentType,
      'addedAt': addedAt.toIso8601String(),
    };
    if (folderName != null && folderName!.isNotEmpty) {
      map['folderName'] = folderName;
    }
    return map;
  }

  factory VideoItem.fromJson(Map<String, dynamic> json) {
    // Determine content type: from JSON field, or infer from extension
    String type = json['contentType'] ?? 'video';
    if (type == 'video') {
      final ext = (json['originalExtension'] ?? '').toString().toLowerCase();
      if (ext == 'pdf') type = 'pdf';
    }
    return VideoItem(
      filePath: json['filePath'],
      name: json['name'],
      originalExtension: json['originalExtension'] ?? 'mp4',
      fileSize: json['fileSize'] ?? 0,
      originalSize: json['originalSize'] ?? 0,
      folderName: json['folderName'],
      contentType: type,
      addedAt: DateTime.tryParse(json['addedAt'] ?? '') ?? DateTime.now(),
    );
  }
}
