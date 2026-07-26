import 'package:flutter_test/flutter_test.dart';
import 'package:kode_agent_desktop/models/chat_entry.dart';

void main() {
  test('heading agent menjadi bagian dengan jarak yang rapi', () {
    expect(
      formatAgentResponse(
        '## Ringkasan\nIsi\n\n## Verifikasi\n### Test\n- Semua lulus',
      ),
      'Ringkasan\n\nIsi\n\nVerifikasi\n\nTest\n\n• Semua lulus',
    );
  });

  test('fence backtick dan tanda petik dihapus dari tampilan', () {
    expect(
      formatAgentResponse(
        "## Perintah\n```powershell\ndocker compose ps\n```\n'''text\nSelesai\n'''",
      ),
      'Perintah\n\ndocker compose ps\nSelesai',
    );
  });

  test('inline code memakai petik ganda dan bullet memakai titik', () {
    expect(
      formatAgentResponse(
        "Gunakan `docker compose up -d`.\n- HTTP `200` dan status 'sehat'",
      ),
      'Gunakan "docker compose up -d".\n\n• HTTP "200" dan status "sehat"',
    );
  });

  test('backtick di dalam blok kode tidak diubah', () {
    expect(
      formatAgentResponse('```javascript\nconst value = `hello`;\n```'),
      'const value = `hello`;',
    );
  });

  test('bold markdown menjadi petik ganda', () {
    expect(
      formatAgentResponse(
        'Younz AI sekarang menggunakan **cx/gpt-5.6-sol melalui 9router**.',
      ),
      'Younz AI sekarang menggunakan "cx/gpt-5.6-sol melalui 9router".',
    );
  });

  test('bagian bernomor otomatis diberi satu baris kosong', () {
    expect(
      formatAgentResponse(
        'Pembuka singkat.\n1. Temuan utama\nPenjelasan.\n2. Langkah berikutnya',
      ),
      'Pembuka singkat.\n\n1. Temuan utama\nPenjelasan.\n\n'
      '2. Langkah berikutnya',
    );
  });
}
