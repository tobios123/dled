// IP ADDRESS (FINDINGS 20.18): an invalid address sends nothing, like the
// reference app (999 / 888 were not sent); valid ones become 4 bytes.

import 'package:flutter_test/flutter_test.dart';
import 'package:dled/models/show_model.dart';

void main() {
  test('IPv4 addresses are checked like the reference app', () {
    expect(ShowModel.parseIpv4('192.168.1.13'), [192, 168, 1, 13]);
    expect(ShowModel.parseIpv4(' 255.255.255.0 '), [255, 255, 255, 0]);
    for (final bad in ['999', '888', '192.168.1', '192.168.1.256', '192.168..1', 'a.b.c.d', '']) {
      expect(ShowModel.parseIpv4(bad), isNull, reason: bad);
    }
  });
}
