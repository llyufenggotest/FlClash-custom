import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:test/test.dart';

void main() {
  group('Rule parse/serialize compatibility', () {
    for (final value in const [
      'MATCH,DIRECT',
      'DOMAIN-SUFFIX,example.com,PROXY',
      'RULE-SET,my-set,PROXY',
      'SUB-RULE,payload,my-sub-rule',
      'IP-CIDR,1.1.1.1/32,DIRECT,no-resolve',
      'IP-CIDR,10.0.0.0/8,DIRECT,src,no-resolve',
      'AND,((DOMAIN,baidu.com),(NETWORK,UDP)),DIRECT',
      'OR,((DOMAIN,a.com),(DOMAIN,b.com)),PROXY',
      'NOT,((DOMAIN,example.com)),PROXY',
      r'DOMAIN-REGEX,^a{1,3}\.example\.com$,PROXY',
    ]) {
      test('round-trips $value', () {
        expect(Rule.parse(value, id: 1).rawValue, value);
      });
    }

    test('MATCH never serializes stale content', () {
      const rule = Rule(
        ruleAction: RuleAction.MATCH,
        content: 'stale',
        ruleTarget: 'DIRECT',
      );
      expect(rule.rawValue, 'MATCH,DIRECT');
    });

    test('inner parameter words do not become outer flags', () {
      const value =
          'AND,((IP-CIDR,10.0.0.0/8,src,no-resolve),(NETWORK,TCP)),DIRECT';
      final rule = Rule.parse(value, id: 1);
      expect(rule.src, isFalse);
      expect(rule.noResolve, isFalse);
      expect(rule.rawValue, value);
    });

    test('only trailing fields are outer parameters', () {
      final rule = Rule.parse(
        ' RULE-SET , src-no-resolve , src , src , no-resolve ',
        id: 1,
      );
      expect(rule.ruleProvider, 'src-no-resolve');
      expect(rule.ruleTarget, 'src');
      expect(rule.src, isTrue);
      expect(rule.noResolve, isTrue);
      expect(rule.rawValue, 'RULE-SET,src-no-resolve,src,src,no-resolve');
    });
  });
}
