import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/services/document_extraction_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'younzcode_documents_',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('reads Markdown as chat context', () async {
    final file = File(p.join(temporaryDirectory.path, 'notes.md'));
    await file.writeAsString('# Judul\n\nIsi dokumen.');

    final result = await DocumentExtractionService().extract(file.path);

    expect(result.kind, DocumentKind.markdown);
    expect(result.text, contains('Isi dokumen.'));
    expect(result.truncated, isFalse);
  });

  test('extracts paragraphs from DOCX Open XML', () async {
    final file = File(p.join(temporaryDirectory.path, 'sample.docx'));
    await file.writeAsBytes(
      _officeArchive({
        'word/document.xml': '''
          <?xml version="1.0" encoding="UTF-8"?>
          <w:document xmlns:w="word">
            <w:body>
              <w:p><w:r><w:t>Halo dari Word</w:t></w:r></w:p>
              <w:p><w:r><w:t>Baris kedua</w:t></w:r></w:p>
            </w:body>
          </w:document>
        ''',
      }),
    );

    final result = await DocumentExtractionService().extract(file.path);

    expect(result.kind, DocumentKind.word);
    expect(result.text, contains('Halo dari Word'));
    expect(result.text, contains('Baris kedua'));
  });

  test('extracts shared and inline values from XLSX', () async {
    final file = File(p.join(temporaryDirectory.path, 'sample.xlsx'));
    await file.writeAsBytes(
      _officeArchive({
        'xl/workbook.xml': '''
          <?xml version="1.0" encoding="UTF-8"?>
          <workbook xmlns:r="relationships">
            <sheets><sheet name="Data" r:id="rId1"/></sheets>
          </workbook>
        ''',
        'xl/_rels/workbook.xml.rels': '''
          <?xml version="1.0" encoding="UTF-8"?>
          <Relationships>
            <Relationship Id="rId1" Target="worksheets/sheet1.xml"/>
          </Relationships>
        ''',
        'xl/sharedStrings.xml': '''
          <?xml version="1.0" encoding="UTF-8"?>
          <sst><si><t>Produk</t></si><si><t>Kopi</t></si></sst>
        ''',
        'xl/worksheets/sheet1.xml': '''
          <?xml version="1.0" encoding="UTF-8"?>
          <worksheet>
            <sheetData>
              <row r="1">
                <c r="A1" t="s"><v>0</v></c>
                <c r="B1" t="inlineStr"><is><t>Jumlah</t></is></c>
              </row>
              <row r="2">
                <c r="A2" t="s"><v>1</v></c>
                <c r="B2"><v>12</v></c>
              </row>
            </sheetData>
          </worksheet>
        ''',
      }),
    );

    final result = await DocumentExtractionService().extract(file.path);

    expect(result.kind, DocumentKind.excel);
    expect(result.text, contains('## Data'));
    expect(result.text, contains('Produk\tJumlah'));
    expect(result.text, contains('Kopi\t12'));
  });

  test('routes PDF through the PDF reader and truncates long output', () async {
    final file = File(p.join(temporaryDirectory.path, 'sample.pdf'));
    await file.writeAsBytes(const [0x25, 0x50, 0x44, 0x46]);
    final service = DocumentExtractionService(
      maxCharacters: 8,
      pdfTextReader: (_) async => 'Teks PDF yang panjang',
    );

    final result = await service.extract(file.path);

    expect(result.kind, DocumentKind.pdf);
    expect(result.truncated, isTrue);
    expect(result.text, startsWith('Teks PDF'));
  });

  test('explains that legacy Word format must be converted', () async {
    final file = File(p.join(temporaryDirectory.path, 'legacy.doc'));
    await file.writeAsString('legacy');

    expect(
      () => DocumentExtractionService().extract(file.path),
      throwsA(
        isA<DocumentExtractionException>().having(
          (error) => error.message,
          'message',
          contains('.docx'),
        ),
      ),
    );
  });
}

List<int> _officeArchive(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.add(ArchiveFile.bytes(entry.key, utf8.encode(entry.value.trim())));
  }
  return ZipEncoder().encodeBytes(archive);
}
