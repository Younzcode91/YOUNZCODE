import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:xml/xml.dart';

typedef PdfTextReader = Future<String> Function(String filePath);

enum DocumentKind { text, markdown, pdf, word, excel }

class DocumentExtractionResult {
  const DocumentExtractionResult({
    required this.fileName,
    required this.kind,
    required this.text,
    required this.truncated,
  });

  final String fileName;
  final DocumentKind kind;
  final String text;
  final bool truncated;
}

class DocumentExtractionException implements Exception {
  const DocumentExtractionException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DocumentExtractionService {
  DocumentExtractionService({
    this.maxFileBytes = 25 * 1024 * 1024,
    this.maxCharacters = 160000,
    PdfTextReader? pdfTextReader,
  }) : _pdfTextReader = pdfTextReader ?? _readPdf;

  final int maxFileBytes;
  final int maxCharacters;
  final PdfTextReader _pdfTextReader;

  static Future<void>? _pdfInitialization;

  static const supportedExtensions = <String>{
    '.dart',
    '.py',
    '.js',
    '.ts',
    '.tsx',
    '.jsx',
    '.json',
    '.yaml',
    '.yml',
    '.toml',
    '.md',
    '.markdown',
    '.txt',
    '.html',
    '.css',
    '.scss',
    '.java',
    '.kt',
    '.go',
    '.rs',
    '.cpp',
    '.h',
    '.pdf',
    '.docx',
    '.xlsx',
  };

  Future<DocumentExtractionResult> extract(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw const DocumentExtractionException('File tidak ditemukan.');
    }
    final size = await file.length();
    if (size > maxFileBytes) {
      throw DocumentExtractionException(
        'File melebihi batas ${maxFileBytes ~/ (1024 * 1024)} MB.',
      );
    }

    final extension = p.extension(filePath).toLowerCase();
    if (extension == '.doc' || extension == '.xls') {
      throw const DocumentExtractionException(
        'Format lama .doc/.xls belum didukung. Simpan ulang sebagai '
        '.docx/.xlsx lalu lampirkan kembali.',
      );
    }
    if (!supportedExtensions.contains(extension)) {
      throw DocumentExtractionException(
        'Format $extension belum didukung untuk konteks chat.',
      );
    }

    late final String text;
    late final DocumentKind kind;
    try {
      switch (extension) {
        case '.pdf':
          kind = DocumentKind.pdf;
          text = await _pdfTextReader(filePath);
        case '.docx':
          kind = DocumentKind.word;
          text = _readDocx(await file.readAsBytes());
        case '.xlsx':
          kind = DocumentKind.excel;
          text = _readXlsx(await file.readAsBytes());
        case '.md' || '.markdown':
          kind = DocumentKind.markdown;
          text = await _readText(file);
        default:
          kind = DocumentKind.text;
          text = await _readText(file);
      }
    } on DocumentExtractionException {
      rethrow;
    } catch (error) {
      throw DocumentExtractionException(
        'Gagal membaca ${p.basename(filePath)}: $error',
      );
    }

    final cleaned = text.replaceAll('\u0000', '').trim();
    final truncated = cleaned.length > maxCharacters;
    final output = truncated
        ? '${cleaned.substring(0, maxCharacters)}\n\n'
              '[Isi dipotong karena dokumen terlalu panjang.]'
        : cleaned;
    return DocumentExtractionResult(
      fileName: p.basename(filePath),
      kind: kind,
      text: output.isEmpty
          ? '[Tidak ada teks yang dapat diekstrak. PDF hasil scan memerlukan OCR.]'
          : output,
      truncated: truncated,
    );
  }

  static Future<String> _readText(File file) async {
    final bytes = await file.readAsBytes();
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }

  static Future<String> _readPdf(String filePath) async {
    _pdfInitialization ??= pdfrxFlutterInitialize();
    await _pdfInitialization;
    final document = await PdfDocument.openFile(filePath);
    try {
      final output = StringBuffer();
      for (final page in document.pages) {
        final pageText = await page.loadStructuredText();
        if (pageText.fullText.trim().isEmpty) continue;
        if (output.isNotEmpty) {
          output.writeln('\n--- Page ${page.pageNumber} ---');
        }
        output.write(pageText.fullText);
      }
      return output.toString();
    } finally {
      await document.dispose();
    }
  }

  static String _readDocx(Uint8List bytes) {
    final archive = _decodeOfficeArchive(bytes);
    final documentBytes = _entryBytes(archive, 'word/document.xml');
    final document = XmlDocument.parse(utf8.decode(documentBytes));
    final output = StringBuffer();
    for (final paragraph in document.descendants.whereType<XmlElement>().where(
      (element) => element.name.local == 'p',
    )) {
      final line = StringBuffer();
      for (final element in paragraph.descendants.whereType<XmlElement>()) {
        switch (element.name.local) {
          case 't':
            line.write(element.innerText);
          case 'tab':
            line.write('\t');
          case 'br' || 'cr':
            line.writeln();
        }
      }
      final value = line.toString().trimRight();
      if (value.isNotEmpty) output.writeln(value);
    }
    return output.toString();
  }

  static String _readXlsx(Uint8List bytes) {
    final archive = _decodeOfficeArchive(bytes);
    final sharedStrings = _readSharedStrings(archive);
    final workbook = XmlDocument.parse(
      utf8.decode(_entryBytes(archive, 'xl/workbook.xml')),
    );
    final relationships = _readWorkbookRelationships(archive);
    final output = StringBuffer();

    for (final sheet in workbook.descendants.whereType<XmlElement>().where(
      (element) => element.name.local == 'sheet',
    )) {
      final name = _attributeByLocalName(sheet, 'name') ?? 'Sheet';
      final relationshipId = _attributeByLocalName(sheet, 'id');
      final target = relationshipId == null
          ? null
          : relationships[relationshipId];
      if (target == null) continue;
      final normalizedTarget = target.startsWith('/')
          ? p.posix.normalize(target.substring(1))
          : p.posix.normalize('xl/$target');
      final entry = archive.find(normalizedTarget);
      if (entry == null) continue;
      final sheetDocument = XmlDocument.parse(
        utf8.decode(entry.readBytes() ?? Uint8List(0)),
      );
      output.writeln('## $name');
      for (final row in sheetDocument.descendants.whereType<XmlElement>().where(
        (element) => element.name.local == 'row',
      )) {
        final values = <int, String>{};
        for (final cell in row.children.whereType<XmlElement>().where(
          (element) => element.name.local == 'c',
        )) {
          final reference = _attributeByLocalName(cell, 'r') ?? '';
          final column = _columnIndex(reference);
          if (column < 0 || column > 255) continue;
          values[column] = _xlsxCellValue(cell, sharedStrings);
        }
        if (values.isEmpty) continue;
        final lastColumn = values.keys.reduce((a, b) => a > b ? a : b);
        output.writeln(
          List.generate(
            lastColumn + 1,
            (index) => values[index] ?? '',
          ).join('\t'),
        );
      }
      output.writeln();
    }
    return output.toString();
  }

  static Archive _decodeOfficeArchive(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    var uncompressedBytes = 0;
    for (final entry in archive) {
      uncompressedBytes += entry.size;
      if (uncompressedBytes > 64 * 1024 * 1024) {
        throw const DocumentExtractionException(
          'Dokumen Office terlalu besar setelah diekstrak.',
        );
      }
    }
    return archive;
  }

  static Uint8List _entryBytes(Archive archive, String path) {
    final entry = archive.find(path);
    final bytes = entry?.readBytes();
    if (bytes == null) {
      throw DocumentExtractionException(
        'Struktur dokumen tidak lengkap: $path tidak ditemukan.',
      );
    }
    if (bytes.length > 16 * 1024 * 1024) {
      throw const DocumentExtractionException(
        'Bagian dokumen terlalu besar untuk diproses dengan aman.',
      );
    }
    return bytes;
  }

  static List<String> _readSharedStrings(Archive archive) {
    final entry = archive.find('xl/sharedStrings.xml');
    if (entry == null) return const [];
    final bytes = entry.readBytes();
    if (bytes == null || bytes.length > 16 * 1024 * 1024) return const [];
    final document = XmlDocument.parse(utf8.decode(bytes));
    return document.descendants
        .whereType<XmlElement>()
        .where((element) => element.name.local == 'si')
        .map(
          (element) => element.descendants
              .whereType<XmlElement>()
              .where((child) => child.name.local == 't')
              .map((child) => child.innerText)
              .join(),
        )
        .toList(growable: false);
  }

  static Map<String, String> _readWorkbookRelationships(Archive archive) {
    final bytes = _entryBytes(archive, 'xl/_rels/workbook.xml.rels');
    final document = XmlDocument.parse(utf8.decode(bytes));
    return {
      for (final relationship
          in document.descendants.whereType<XmlElement>().where(
            (element) => element.name.local == 'Relationship',
          ))
        if (_attributeByLocalName(relationship, 'Id') != null &&
            _attributeByLocalName(relationship, 'Target') != null)
          _attributeByLocalName(relationship, 'Id')!: _attributeByLocalName(
            relationship,
            'Target',
          )!,
    };
  }

  static String _xlsxCellValue(XmlElement cell, List<String> sharedStrings) {
    final type = _attributeByLocalName(cell, 't');
    final elements = cell.descendants.whereType<XmlElement>();
    if (type == 'inlineStr') {
      return elements
          .where((element) => element.name.local == 't')
          .map((element) => element.innerText)
          .join();
    }
    final raw = elements
        .where((element) => element.name.local == 'v')
        .map((element) => element.innerText)
        .firstOrNull;
    if (raw == null) return '';
    if (type == 's') {
      final index = int.tryParse(raw);
      return index != null && index >= 0 && index < sharedStrings.length
          ? sharedStrings[index]
          : raw;
    }
    if (type == 'b') return raw == '1' ? 'TRUE' : 'FALSE';
    return raw;
  }

  static String? _attributeByLocalName(XmlElement element, String name) {
    for (final attribute in element.attributes) {
      if (attribute.name.local == name) return attribute.value;
    }
    return null;
  }

  static int _columnIndex(String cellReference) {
    var index = 0;
    var found = false;
    for (final unit in cellReference.codeUnits) {
      if (unit < 65 || unit > 90) break;
      found = true;
      index = index * 26 + unit - 64;
    }
    return found ? index - 1 : -1;
  }
}
