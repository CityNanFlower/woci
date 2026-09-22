import 'package:flutter_test/flutter_test.dart';

import 'package:wo_ci/db.dart';
import 'package:wo_ci/dict.dart';

void main() {
  test('艾宾浩斯调度表正确', () {
    expect(DB.schedule, [0, 1, 2, 4, 7, 15, 30]);
  });

  test('日期平移正确', () {
    expect(DB.today().length, 10);
  });

  test('Dict 空载时不崩溃', () {
    expect(Dict.size, 0);
    expect(Dict.lookup('acquire'), isNull);
  });
}
