import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:mangayomi/modules/novel/widgets/ttsu_epub_reader.dart';
import 'package:mangayomi/services/mining/mining_preferences.dart';
import 'package:mangayomi/src/rust/api/epub.dart';

void main() {
  final book = EpubNovel(
    name: 'Reader fixture',
    chapters: const [],
    images: [
      EpubResource(
        name: 'OEBPS/images/cover.png',
        content: Uint8List.fromList([137, 80, 78, 71]),
      ),
    ],
    stylesheets: const [],
  );

  test('builds a selectable, self-contained DOM reader', () {
    final document = buildTtsuEpubDocument(
      html: '<p>探偵はもう、死んでいる。</p><img src="../images/cover.png"><script>bad()</script>',
      book: book,
      title: '探偵',
      backgroundColor: '#101010',
      textColor: '#f0f0f0',
      fontSize: 18,
      lineHeight: 1.8,
      padding: 24,
      textAlign: 'justify',
      initialProgress: 0.25,
      tapToScroll: true,
    );

    expect(document, contains('探偵はもう、死んでいる。'));
    expect(document, contains('data:image/png;base64,'));
    expect(document, isNot(contains('bad()')));
    expect(document, contains("call('readerDictionary'"));
    expect(document, contains('const initialProgress = 0.25'));
    expect(document, contains('margin-block-end: 0.00em !important'));
    expect(document, contains('user-select: text'));
    expect(document, contains("const lookupTrigger = \"leftClick\""));
    expect(document, contains('const additionalLeftClick = false'));
    expect(document, contains('const pointsAtActiveLookup = (x, y)'));
    expect(document, contains('activeLookup.originNode === hit.node'));
    expect(document, contains('originOffset: hit.offset'));
    expect(document, contains('lookupToken }'));
    expect(document, contains(r'\p{Radical}'));
    expect(
      RegExp(r'\\p\{Script=Hangul\}').allMatches(document).length,
      greaterThanOrEqualTo(2),
      reason: 'Hangul must be accepted by progress and dictionary scanning',
    );
    expect(document, contains('chimahonContinuousProgress'));
    expect(document, contains('jumpToChimahonProgress'));
    expect(document, contains('jumpToLogicalSpine'));
    expect(document, contains('restorePreviewPosition'));
    expect(document, contains('clearLogicalTarget'));
    expect(document, contains("querySelector('.mangatan-logical-marker')"));
    expect(document, contains('break-after: column'));
    expect(document, contains('min-height: 100vh'));
    expect(document, contains('metrics,'));
  });

  test('drops script URLs from every attribute', () {
    final document = buildTtsuEpubDocument(
      html:
          '<a href=" JaVa\tscript:bad1()">a</a>'
          '<svg><a xlink:href="javascript:bad2()"><text>b</text></a></svg>'
          '<form action="javascript:bad3()"><button formaction="vbscript:bad4">c</button></form>'
          '<a href="data:text/html,bad5">d</a>'
          '<a href="chapter2.xhtml#note">kept</a>',
      book: book,
      title: 'fixture',
      backgroundColor: '#101010',
      textColor: '#f0f0f0',
      fontSize: 18,
      lineHeight: 1.8,
      padding: 24,
      textAlign: 'left',
      initialProgress: 0,
      tapToScroll: false,
    );

    for (final payload in ['bad1', 'bad2', 'bad3', 'bad4', 'bad5']) {
      expect(document, isNot(contains(payload)));
    }
    expect(document, contains('chapter2.xhtml#note'));
  });

  test('applies configurable logical paragraph spacing', () {
    final document = buildTtsuEpubDocument(
      html: '<p>first</p><p>second</p>',
      book: book,
      title: 'fixture',
      backgroundColor: '#101010',
      textColor: '#f0f0f0',
      fontSize: 18,
      lineHeight: 1.8,
      padding: 12,
      textAlign: 'left',
      initialProgress: 0,
      tapToScroll: true,
      paragraphSpacing: 1.2,
      layout: EpubReadingLayout.verticalPaged,
    );

    expect(document, contains('margin-block-end: 1.20em !important'));
    expect(document, isNot(contains('margin: 0 0 0 1.2')));
  });

  test('positions an exact cold-open target before reporting ready', () {
    final document = buildTtsuEpubDocument(
      html: '<p>chapter</p>',
      book: book,
      title: 'fixture',
      backgroundColor: '#f4ecd8',
      textColor: '#302a24',
      fontSize: 18,
      lineHeight: 1.8,
      padding: 24,
      textAlign: 'left',
      initialProgress: 0.25,
      initialChapterIndex: 4,
      initialChapterProgress: 0.6,
      initialSpineIndex: 7,
      tapToScroll: true,
    );

    expect(document, contains('const initialChapterIndex = 4'));
    expect(document, contains('const initialChapterProgress = 0.6'));
    expect(document, contains('const initialSpineIndex = 7'));
    expect(document, contains('await jumpToLogicalSpine(initialSpineIndex)'));
    expect(
      document.indexOf('await jumpToLogicalSpine(initialSpineIndex)'),
      lessThan(document.indexOf("call('readerReady'")),
    );
    expect(
      document.indexOf('requestAnimationFrame(resolve)'),
      lessThan(document.indexOf("call('readerReady'")),
    );
    expect(
      document.indexOf(".catch((error) =>"),
      lessThan(document.indexOf("call('readerReady'")),
    );
  });

  test('dismisses an active EPUB lookup from any primary click', () {
    for (final trigger in DictionaryLookupTrigger.values) {
      final document = buildTtsuEpubDocument(
        html: '<p>辞書</p>',
        book: book,
        title: 'fixture',
        backgroundColor: '#101010',
        textColor: '#f0f0f0',
        fontSize: 18,
        lineHeight: 1.8,
        padding: 24,
        textAlign: 'left',
        initialProgress: 0,
        tapToScroll: true,
        lookupTrigger: trigger,
        additionalLeftClick: false,
      );

      expect(document, contains('const additionalLeftClick = false'));
      expect(document, contains('const dismissReaderDictionary = () =>'));
      expect(document, contains("call('readerDismissDictionary')"));
      expect(
        document,
        contains('const hadActiveLookup = activeLookup != null'),
      );
      final lookupModeIndex = document.indexOf(
        'if (leftClickLookupEnabled(event))',
      );
      final fallbackDismissalIndex = document.indexOf('if (hadActiveLookup)');
      expect(lookupModeIndex, greaterThanOrEqualTo(0));
      expect(
        lookupModeIndex,
        lessThan(fallbackDismissalIndex),
        reason:
            '${trigger.name} must allow an enabled click lookup to replace '
            'the popup before applying the anywhere-dismiss fallback',
      );
    }
  });

  test('rewrites SVG xlink image references used by fixed-layout EPUBs', () {
    final document = buildTtsuEpubDocument(
      html: '<svg xmlns="http://www.w3.org/2000/svg"><image xlink:href="../images/cover.png"/></svg>',
      book: book,
      title: 'fixture',
      backgroundColor: '#101010',
      textColor: '#f0f0f0',
      fontSize: 18,
      lineHeight: 1.8,
      padding: 24,
      textAlign: 'left',
      initialProgress: 0,
      tapToScroll: true,
      chapterHref: 'OEBPS/text/chapter.xhtml',
    );

    expect(document, contains('xlink:href="data:image/png;base64,'));
  });

  test('generates middle-click dictionary lookup handling', () {
    final document = buildTtsuEpubDocument(
      html: '<p>辞書</p>',
      book: book,
      title: 'fixture',
      backgroundColor: '#101010',
      textColor: '#f0f0f0',
      fontSize: 18,
      lineHeight: 1.8,
      padding: 24,
      textAlign: 'left',
      initialProgress: 0,
      tapToScroll: true,
      lookupTrigger: DictionaryLookupTrigger.middleClick,
    );

    expect(document, contains("const lookupTrigger = \"middleClick\""));
    expect(document, contains("document.addEventListener('pointerup'"));
    expect(document, contains("document.addEventListener('auxclick'"));
    expect(document, contains("event.button !== 1"));
    expect(document, contains('middleLookupActive = true'));
    expect(document, contains("document.addEventListener('pointercancel'"));
    expect(document, contains("middleLookupActive"));
    expect(document, contains('triggerHeldLookupAt(x, y)'));
    expect(document, contains("call('readerDismissDictionary')"));
    expect(document, contains("event.preventDefault()"));
  });

  test('bridges trackpad wheels and two-finger touch panning', () {
    final document = buildTtsuEpubDocument(
      html: '<p>scroll fixture</p>',
      book: book,
      title: 'fixture',
      backgroundColor: '#101010',
      textColor: '#f0f0f0',
      fontSize: 18,
      lineHeight: 1.8,
      padding: 12,
      textAlign: 'left',
      initialProgress: 0,
      tapToScroll: true,
    );

    expect(document, contains('event.deltaMode === 1'));
    expect(document, contains('scrollByPixels(delta)'));
    expect(document, contains('const touchCenter = (touches) =>'));
    expect(document, contains("document.addEventListener('touchstart'"));
    expect(document, contains("document.addEventListener('touchmove'"));
    expect(document, contains('if (!twoFingerPan) return'));
    expect(document, contains('event.preventDefault()'));
    final wheelAndTouchHandlers = document.substring(
      document.indexOf("document.addEventListener('wheel'"),
      document.indexOf("content.addEventListener('scroll'"),
    );
    expect(wheelAndTouchHandlers, isNot(contains("call('readerChapter'")));
  });

  test('turns one page for every unmodified wheel event', () {
    final document = buildTtsuEpubDocument(
      html: '<p>paged scroll fixture</p>',
      book: book,
      title: 'fixture',
      backgroundColor: '#101010',
      textColor: '#f0f0f0',
      fontSize: 18,
      lineHeight: 1.8,
      padding: 12,
      textAlign: 'left',
      initialProgress: 0,
      tapToScroll: true,
      layout: EpubReadingLayout.horizontalPaged,
    );

    final wheelHandler = document.substring(
      document.indexOf("document.addEventListener('wheel'"),
      document.indexOf('const touchCenter = (touches) =>'),
    );
    expect(
      wheelHandler,
      contains('if (event.ctrlKey || event.metaKey) return'),
    );
    expect(
      wheelHandler,
      contains(
        'const pageDelta = event.deltaY !== 0 ? event.deltaY : event.deltaX',
      ),
    );
    expect(wheelHandler, contains('scrollPage(pageDelta > 0 ? 1 : -1)'));
    expect(wheelHandler, isNot(contains('wheelLocked')));
    expect(wheelHandler, isNot(contains('wheelUnlockTimer')));
  });

  test('bridges back inputs from the embedded reader to Flutter', () {
    final document = buildTtsuEpubDocument(
      html: '<p>back fixture</p>',
      book: book,
      title: 'fixture',
      backgroundColor: '#101010',
      textColor: '#f0f0f0',
      fontSize: 18,
      lineHeight: 1.8,
      padding: 12,
      textAlign: 'left',
      initialProgress: 0,
      tapToScroll: true,
    );

    expect(document, contains("event.key === 'Escape'"));
    expect(document, contains("event.key === 'Backspace'"));
    expect(document, contains("event.key === 'BrowserBack'"));
    expect(document, contains('event.button === 3'));
    expect(document, contains("call('readerBack')"));
  });

  test('generates left/right-agnostic Shift dictionary lookup handling', () {
    final document = buildTtsuEpubDocument(
      html: '<p>辞書</p>',
      book: book,
      title: 'fixture',
      backgroundColor: '#101010',
      textColor: '#f0f0f0',
      fontSize: 18,
      lineHeight: 1.8,
      padding: 24,
      textAlign: 'left',
      initialProgress: 0,
      tapToScroll: true,
      lookupTrigger: DictionaryLookupTrigger.shift,
      additionalLeftClick: true,
    );

    expect(document, contains("const lookupTrigger = \"shift\""));
    expect(document, contains('const additionalLeftClick = true'));
    expect(document, contains('const leftClickLookupEnabled = (event) =>'));
    expect(document, contains("event.pointerType === 'mouse'"));
    expect(document, contains('triggerLookupAt(event.clientX, event.clientY)'));
    expect(document, contains("event.key === 'Shift'"));
    expect(document, contains('!event.repeat'));
    expect(document, contains('const setShiftLookupActive = (active) =>'));
    expect(document, contains('setShiftLookupActive(true);'));
    expect(document, contains("document.addEventListener('keyup'"));
    expect(document, contains('setShiftLookupActive(false);'));
    expect(document, contains("event.shiftKey || shiftLookupActive"));
    expect(document, contains('triggerHeldLookupAt(x, y)'));
    expect(document, contains("call('readerDismissDictionary')"));
  });

  test('does not allow EPUB markup to inject executable elements', () {
    final document = buildTtsuEpubDocument(
      html: '<iframe src="https://example.test"></iframe><p>safe</p>',
      book: book,
      title: 'fixture',
      backgroundColor: 'not-a-color',
      textColor: 'also-invalid',
      fontSize: 14,
      lineHeight: 1.5,
      padding: 12,
      textAlign: 'invalid',
      initialProgress: 4,
      tapToScroll: false,
    );

    expect(document, isNot(contains('<iframe')));
    expect(document, contains('--reader-bg: #292832'));
    expect(document, contains('text-align: left'));
    expect(document, contains('const initialProgress = 1.0'));
  });

  test(
    'keeps EPUB-relative resources and stylesheet links in a file session',
    () {
      final document = buildTtsuEpubDocument(
        html: '''
        <html><head><link rel="stylesheet" href="../css/book.css"></head>
        <body><p style="display:none">日本語</p><img src="../images/cover.png"></body></html>
      ''',
        book: EpubNovel(
          name: 'Reader fixture',
          chapters: const [],
          images: book.images,
          stylesheets: [
            EpubResource(
              name: 'OEBPS/css/book.css',
              content: Uint8List.fromList([]),
            ),
          ],
        ),
        title: 'fixture',
        backgroundColor: '#101010',
        textColor: '#f0f0f0',
        fontSize: 18,
        lineHeight: 1.8,
        padding: 24,
        textAlign: 'justify',
        initialProgress: 0,
        tapToScroll: true,
        chapterHref: 'OEBPS/text/chapter.xhtml',
        resourceUrlFor: (resource) => resource.name.endsWith('.css')
            ? '../css/book.css'
            : '../images/cover.png',
      );

      expect(document, contains('href="../css/book.css"'));
      expect(document, contains('src="../images/cover.png"'));
      expect(document, isNot(contains('data:image/png;base64,')));
      expect(document, isNot(contains('display:none')));
      expect(document, contains('const lookupAt = ('));
      expect(document, contains('existingHit = null'));
      expect(document, contains("call('readerLink', href)"));
      expect(document, contains('sentenceFor'));
    },
  );

  test('uses one selectable DOM for paged and vertical Japanese layouts', () {
    final document = buildTtsuEpubDocument(
      html: '<p>EPUB reader fixture</p>',
      book: book,
      title: 'fixture',
      backgroundColor: '#101010',
      textColor: '#f0f0f0',
      fontSize: 18,
      lineHeight: 1.8,
      padding: 24,
      textAlign: 'justify',
      initialProgress: 0.5,
      tapToScroll: true,
      layout: EpubReadingLayout.verticalPaged,
    );

    expect(document, contains('data-mangatan-reader-layout="vertical-pages"'));
    expect(document, contains('writing-mode: vertical-rl'));
    expect(document, contains('const pageMode = true'));
    expect(document, contains('const verticalWriting = true'));
    expect(document, contains('const scanLookup ='));
    expect(document, contains('fragment.querySelectorAll'));
    expect(document, contains("const axis = verticalWriting\n          ? 'y'"));
    expect(
      document,
      contains(
        'const yMax = Math.max(0, root.scrollHeight - root.clientHeight)',
      ),
    );
    expect(
      document,
      contains(
        "const pageSize = axis === 'x' ? root.clientWidth : root.clientHeight",
      ),
    );
    expect(document, contains('const calculateProgress = () =>'));
    expect(document, contains('const restoreProgress = async (value)'));
    expect(document, contains('range.getClientRects()'));
    expect(document, isNot(contains('const estimatedPages =')));
    expect(document, isNot(contains('--mangatan-page-shift')));
    expect(document, contains("document.addEventListener('wheel'"));
    expect(document, contains("event.key === 'ArrowLeft'"));
    expect(document, contains('const highlightMatch = (count, expectedToken)'));
    expect(
      document,
      contains(
        "CSS.highlights.set('hoshi-selection', new Highlight(...ranges))",
      ),
    );
    expect(document, isNot(contains('selection.addRange(range)')));
    expect(document, contains('lookupToken'));
    expect(document, contains('const clearLookup = (expectedToken)'));
    expect(document, contains("call('readerPrefetch', { text })"));
    expect(document, isNot(contains('highlightMatch(1)')));
    expect(document, contains("content.querySelectorAll('ruby')"));
    expect(document, contains('column-count: auto !important'));
    expect(document, contains('column-gap: 48.0vh !important'));
    expect(document, contains('alignToPage(context, progress * context.max)'));
    expect(document, contains('const measureLastContentPage = () =>'));
    expect(document, contains('measuredPageMax = measureLastContentPage()'));
    expect(document, contains("'img, svg, video, canvas, table, hr'"));
    expect(document, contains("content.addEventListener('scroll'"));
    expect(document, contains('if (pageMode && !verticalWriting)'));
    expect(document, isNot(contains('maxAligned')));
    expect(document, contains('background: rgba(138, 180, 248, .62)'));
    expect(
      document,
      contains('background: rgba(160, 160, 160, .4) !important'),
    );
    expect(document, contains('const classifyFullPageMedia = () =>'));
    expect(document, contains('if (!pageMode) return'));
    expect(document, contains("width >= 300 || height >= 300"));
    expect(document, contains('break-before: column !important'));
    expect(document, contains('break-after: column !important'));
    expect(
      document,
      contains("candidate.classList.add('mangatan-full-page-media')"),
    );
    expect(
      document,
      contains("wrapper.classList.add('mangatan-full-page-media-wrapper')"),
    );
    expect(
      document.indexOf('.then(() => classifyFullPageMedia())'),
      lessThan(document.indexOf('measuredPageMax = measureLastContentPage()')),
    );
  });

  test('marks standalone media wrappers without promoting inline images', () {
    final document = buildTtsuEpubDocument(
      html: '''
        <section data-mangatan-spine-index="0">
          <p id="standalone"><span class="img"><img src="data:image/png;base64,AA=="></span></p>
          <p id="inline">before <img src="data:image/png;base64,AA=="> after</p>
          before <img id="direct-inline" src="data:image/png;base64,AA=="> after
          <p id="small"><img width="96" src="data:image/png;base64,AA=="></p>
          <p id="gaiji"><img class="gaiji-line" src="data:image/png;base64,AA=="></p>
          <div id="illustration" class="illustration"><img src="data:image/png;base64,AA=="></div>
          <h1 id="heading"><img src="data:image/png;base64,AA=="></h1>
          <div id="fixed"><svg viewBox="0 0 1434 2048"><image href="data:image/png;base64,AA=="></image></svg></div>
          <p id="page-one"><img src="data:image/png;base64,AA=="></p>
          <p id="page-two"><img src="data:image/png;base64,AA=="></p>
          <div id="consecutive"><img id="first" src="data:image/png;base64,AA=="><img id="second" src="data:image/png;base64,AA=="></div>
        </section>
      ''',
      book: book,
      title: 'fixture',
      backgroundColor: '#101010',
      textColor: '#f0f0f0',
      fontSize: 18,
      lineHeight: 1.8,
      padding: 24,
      textAlign: 'left',
      initialProgress: 0,
      tapToScroll: true,
      layout: EpubReadingLayout.horizontalPaged,
    );

    final reader = html_parser
        .parse(document)
        .querySelector('#reader-content')!;
    final candidates = reader
        .querySelectorAll('[data-mangatan-full-page-candidate]')
        .map((element) => element.id)
        .toSet();
    expect(
      candidates,
      containsAll(<String>{'standalone', 'fixed', 'page-one', 'page-two'}),
    );
    expect(candidates, isNot(contains('inline')));
    expect(candidates, isNot(contains('direct-inline')));
    expect(candidates, isNot(contains('small')));
    expect(candidates, isNot(contains('gaiji')));
    expect(candidates, isNot(contains('illustration')));
    expect(candidates, isNot(contains('heading')));
    expect(candidates, isNot(contains('first')));
    expect(candidates, isNot(contains('second')));
  });

  test(
    'supports continuous vertical writing on the horizontal scroll axis',
    () {
      final document = buildTtsuEpubDocument(
        html: '<p>縦書きの連続表示</p>',
        book: book,
        title: 'fixture',
        backgroundColor: '#292832',
        textColor: '#cccccc',
        fontSize: 18,
        lineHeight: 1.8,
        padding: 12,
        textAlign: 'justify',
        initialProgress: 0.25,
        tapToScroll: true,
        layout: EpubReadingLayout.verticalContinuous,
      );

      expect(
        document,
        contains('data-mangatan-reader-layout="vertical-scroll"'),
      );
      expect(document, contains('--reader-padding: 12.0vh'));
      expect(document, contains('const pageMode = false'));
      expect(document, contains('const verticalWriting = true'));
      expect(
        document,
        contains('const continuousVertical = verticalWriting && !pageMode'),
      );
      expect(document, contains('const continuousVerticalContext = () =>'));
      expect(document, contains('content.scrollWidth - content.clientWidth'));
      expect(document, contains('overflow-x: auto !important'));
      expect(document, contains('overflow-y: hidden !important'));
    },
  );

  test('exposes every writing direction and flow combination', () {
    expect(
      EpubReadingLayout.fromAxes(vertical: false, paged: false),
      EpubReadingLayout.horizontalContinuous,
    );
    expect(
      EpubReadingLayout.fromAxes(vertical: false, paged: true),
      EpubReadingLayout.horizontalPaged,
    );
    expect(
      EpubReadingLayout.fromAxes(vertical: true, paged: true),
      EpubReadingLayout.verticalPaged,
    );
    expect(
      EpubReadingLayout.fromAxes(vertical: true, paged: false),
      EpubReadingLayout.verticalContinuous,
    );
  });

  test('writes generated reader shells as HTML beside the source XHTML', () {
    const document =
        '<html data-mangatan-reader-href="OEBPS/text/chapter.xhtml"></html>';

    expect(
      renderedEpubDocumentHref(document, 7),
      'OEBPS/text/.mangatan-reader-7.html',
    );
  });
}
