import 'package:flutter_test/flutter_test.dart';
import 'package:aidazi/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('pads old character records to the new field layout', () async {
    SharedPreferences.setMockInitialValues({
      'name': 'Old Character',
      'student_123_Old Character': <String>[
        'Old Character',
        'avatar',
        'hello',
        'description',
        '123',
        'draw prompt',
        'https://example.com/reference.wav',
        'lora',
      ],
    });

    final students = await getStudents();
    // 新布局：0-18 共 19 槽（6 voice_id / 7 refImage / 9 voiceRefUrl / 10 bgImages
    // / 13 chat_background / 14 personality / 15 voice_model
    // / 16 voice_url / 17 voice_prompt / 18 appearance_prompt）
    expect(students.single, hasLength(19));
    expect(students.single[8], isEmpty);
    expect(students.single[9], isEmpty);
    expect(students.single[10], isEmpty);
    expect(students.single[13], isEmpty);
    expect(students.single[14], isEmpty);
    expect(students.single[15], isEmpty);
    expect(students.single[16], isEmpty);
    expect(students.single[17], isEmpty);
    expect(students.single[18], isEmpty);
  });

  test('voice and ref-image fields persist to the current character record',
      () async {
    SharedPreferences.setMockInitialValues({
      'name': 'Tester',
      'student_456_Tester': <String>[
        'Tester',
        'avatar',
        'hello',
        'description',
        '456',
        'draw prompt',
        '',
        '',
        '',
        '',
        '',
      ],
    });

    await saveVoiceId('voice-abc');
    await saveVoiceRefUrl('aidazi/characters/x/voice_ref.wav');
    await saveRefImage('aidazi/characters/x/ref_image.png');

    expect(await getVoiceId(), 'voice-abc');
    expect(await getVoiceRefUrl(), 'aidazi/characters/x/voice_ref.wav');
    expect(await getRefImage(), 'aidazi/characters/x/ref_image.png');

    // 记录槽位同步持久化
    final students = await getStudents();
    expect(students.single[6], 'voice-abc');
    expect(students.single[9], 'aidazi/characters/x/voice_ref.wav');
    expect(students.single[7], 'aidazi/characters/x/ref_image.png');

    // 背景图列表（索引 10，逗号分隔）
    await addBgImage('bg1.png');
    await addBgImage('bg2.png');
    expect(await getBgImages(), ['bg1.png', 'bg2.png']);
    await removeBgImage('bg1.png');
    expect(await getBgImages(), ['bg2.png']);
  });
}
