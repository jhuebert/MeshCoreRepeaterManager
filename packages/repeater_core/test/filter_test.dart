import 'package:repeater_core/repeater_core.dart';
import 'package:test/test.dart';

void main() {
  group('dialect', () {
    test('top-level pipes split, escaped pipes and classes do not', () {
      expect(splitAlternatives('^Alice|Bob\$'), ['^Alice', 'Bob\$']);
      expect(splitAlternatives(r'A\|B'), [r'A\|B']);
      expect(splitAlternatives('[a|b]'), ['[a|b]']);
      expect(splitAlternatives(r'[\]|]'), [r'[\]|]']);
      expect(splitAlternatives('[abc'), isNull);
    });

    test('add-time validation rejects empty branches and too many alts', () {
      expect(validatePattern('A|', sender: false),
          anyOf(contains(isA<PatternIssue>()), isNotEmpty));
      expect(validatePattern('A||B', sender: false).map((e) => e.message),
          contains('An empty alternative matches everything.'));
      expect(
          validatePattern(List.filled(9, 'a').join('|'), sender: false)
              .map((e) => e.message),
          contains(startsWith('Too many alternatives')));
    });

    test('length and trailing escape are rejected', () {
      expect(validatePattern('a' * 32, sender: true), isNotEmpty);
      expect(validatePattern('a' * 64, sender: false), isNotEmpty);
      expect(validatePattern(r'abc\', sender: false).map((e) => e.message),
          contains('Trailing backslash or unclosed class.'));
    });

    test('valid patterns pass', () {
      expect(validatePattern(r'^SpamBot$', sender: true), isEmpty);
      expect(validatePattern(r'^Alice$|^Bob$', sender: true), isEmpty);
      expect(validatePattern(r'[a-z]+\s\w', sender: false), isEmpty);
    });
  });

  group('dry run', () {
    test('anchors bind per alternative and first match wins', () {
      expect(dryRun(r'^SpamBot$', 'SpamBot').matched, isTrue);
      expect(dryRun(r'^SpamBot$', 'MySpamBot').matched, isFalse);
      expect(dryRun(r'Alice|Bob', 'Bob says hi').matched, isTrue);
      expect(dryRun(r'^Alice|Bob$', 'Bob').matched, isTrue);
    });

    test('dialect parentheses are literals, so ^(Alice|Bob)\$ matches neither',
        () {
      expect(dryRun(r'^(Alice|Bob)$', 'Alice').matched, isFalse);
      expect(dryRun(r'^(Alice|Bob)$', 'Bob').matched, isFalse);
    });

    test('backslash n and t match the literal letters', () {
      expect(dryRun(r'\n', 'n').matched, isTrue);
      expect(dryRun(r'\n', '\n').matched, isFalse);
      expect(dryRun(r'\t', 't').matched, isTrue);
    });

    test('classes and escapes work', () {
      expect(dryRun(r'^\d+$', '123').matched, isTrue);
      expect(dryRun(r'^\d+$', '12a').matched, isFalse);
      expect(dryRun(r'^[a-z]+$', 'abc').matched, isTrue);
      expect(dryRun(r'\s', ' ').matched, isTrue);
      expect(dryRun(r'\S', ' ').matched, isFalse);
    });

    test('nested repetition is flagged as a step-budget abort', () {
      expect(estimateStepCost(r'.*.*'), greaterThan(5000));
      expect(dryRun(r'.*.*', 'anything').aborted, isTrue);
    });
  });

  group('translator', () {
    test('whole-pattern groups split into alternatives with anchors copied',
        () {
      final t = translateRegex(r'^(Alice|Bob)$');
      expect(t.result, r'^Alice$|^Bob$');
      expect(t.warnings, isNotEmpty);
      expect(t.supported, isTrue);
      expect(dryRun(t.result, 'Alice').matched, isTrue);
    });

    test('bounded quantifiers expand', () {
      expect(translateRegex('abc').result, 'abc');
      expect(translateRegex('a{3}').result, 'aaa');
      expect(translateRegex('a{2,}').result, 'aa+');
      expect(translateRegex('a{2,4}').result, 'aaa?a?');
    });

    test('escapes and lazy quantifiers are translated with warnings', () {
      final newline = translateRegex(r'\n');
      expect(newline.result, r'\s');
      expect(newline.warnings.join(), contains('whitespace'));
      expect(translateRegex(r'.*?').result, '.*');
      expect(translateRegex(r'.+?').result, '.+');
      expect(translateRegex(r'\.').result, r'\.');
    });

    test('unsupported constructs are reported instead of silently changed', () {
      final boundary = translateRegex(r'\bfoo\b');
      expect(boundary.supported, isFalse);
      expect(boundary.warnings.join(), contains('Word boundaries'));
      final lookahead = translateRegex(r'(?=foo)');
      expect(lookahead.supported, isFalse);
      expect(lookahead.warnings.join(), contains('lookaround'));
    });

    test('too many alternatives need two rules', () {
      final t = translateRegex('a|b|c|d|e|f|g|h|i');
      expect(t.supported, isFalse);
      expect(t.warnings.join(), contains('two rules'));
    });
  });

  group('rule CLI', () {
    test('serializes a rule into the exact filter add command', () {
      expect(
          ruleToAddCommand(const FilterRule(
              channels: ['#test'], sender: r'^bob', throttle: 60)),
          r'filter add chan=#test sender=^bob throttle=60');
      expect(
          ruleToAddCommand(
              const FilterRule(action: 'forward', types: ['advert'])),
          'filter add forward type=advert');
    });

    test('parses a list line including disabled state and counters', () {
      final rule =
          parseRuleLine('2: disabled drop chan=#test sender=^bob throttle=60')!;
      expect(rule.index, 2);
      expect(rule.enabled, isFalse);
      expect(rule.action, 'drop');
      expect(rule.channels, ['#test']);
      expect(rule.sender, r'^bob');
      expect(rule.throttle, 60);
    });

    test('a paged list exposes the next index', () {
      final page = parseFilterList('''0: drop advert
1: forward chan=#weather
...''');
      expect(page.rules, hasLength(2));
      expect(page.nextIndex, 2);
      expect(parseFilterList('0: drop advert').nextIndex, isNull);
    });

    test('rules survive a json roundtrip and copyWith', () {
      final rule = const FilterRule(
        index: 1,
        action: 'forward',
        types: ['txt'],
        channels: ['#a'],
        sender: r'^bob$',
        throttle: 30,
      );
      final copy = FilterRule.fromJson(rule.toJson());
      expect(copy.index, 1);
      expect(copy.action, 'forward');
      expect(copy.channels, ['#a']);
      expect(copy.sender, r'^bob$');
      expect(copy.throttle, 30);
      expect(rule.copyWith(enabled: false).enabled, isFalse);
    });

    test('conditions cover every key and quoted values', () {
      var rule = const FilterRule();
      for (final token in [
        'type=advert,txt',
        'route=flood',
        'hops=[2,*]',
        'len=[*,80]',
        'snr=[*,-8.5]',
        r'path=[^]aabb[$]',
        'hsize=1,2',
        'chan=#a,#b',
        'chanhash=ab',
        'region=home',
        r'sender=^a$',
        r'text=^b$',
        'prob=50',
        'throttle=60',
        'hits=4',
        'pass=2',
        'air=90',
        'unknown=x',
      ]) {
        rule = applyCondition(rule, token);
      }
      expect(rule.types, ['advert', 'txt']);
      expect(rule.route, 'flood');
      expect(rule.hsize, [1, 2]);
      expect(rule.channels, ['#a', '#b']);
      expect(rule.hits, 4);
      expect(rule.pass, 2);
      expect(rule.air, 90);
      expect(ruleToAddCommand(const FilterRule(text: 'RX in place')),
          'filter add text="RX in place"');
      expect(parseRuleLine('not a rule'), isNull);
    });

    test('captured firmware status line parses', () {
      final status =
          FilterStatus.parse('on; rules 0/32; chans 1/32; ratelimit advert 0h; '
              'cache 0/512; limiter 0; aborted 0')!;
      expect(status.on, isTrue);
      expect(status.rules, 0);
      expect(status.maxRules, 32);
      expect(status.channels, 1);
      expect(status.cacheUsed, 0);
      expect(status.maxCache, 512);
    });

    test('status and stats lines parse', () {
      final status =
          FilterStatus.parse('on; rules 1/32; chans 2/32; ratelimit advert 0h; '
              'cache 0/512; limiter 3; aborted 1')!;
      expect(status.on, isTrue);
      expect(status.rules, 1);
      expect(status.maxRules, 32);
      expect(status.limiterDrops, 3);
      expect(status.regexAborts, 1);
      expect(FilterStatus.parse('Unknown command'), isNull);

      final stats = FilterStats.parse(
          '0: drop advert hits=5\nlimiter 2 aborted 1 saved air 120s')!;
      expect(stats.hits[0], 5);
      expect(stats.limiterDrops, 2);
    });
  });
}
