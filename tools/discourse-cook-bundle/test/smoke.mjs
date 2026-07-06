// 产物冒烟测试：node 直接 eval bundle，断言各 feature 的 cook 输出形态。
// 注意这里断言的是「客户端预览 cook」的输出（mention 是 span、upload://
// 是 transparent.png + data-orig-src），与服务端 cooked 的差异见
// 计划文档的降级表。
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const bundlePath = path.resolve(__dirname, '../../../assets/cook/discourse-cook.js');

// 用干净 vm context 模拟裸引擎（无 window/document），更接近 QuickJS/JSC
const context = vm.createContext({ console });
vm.runInContext(await readFile(bundlePath, 'utf8'), context, {
  filename: 'discourse-cook.js',
});
const cookApi = context.__fluxdoCook;
assert.ok(cookApi, '__fluxdoCook 全局未挂载');

const initData = {
  baseUri: '',
  siteSettings: {
    // markdown 引擎开关（对齐 linux.do 常规配置）
    enable_markdown_linkify: true,
    markdown_linkify_tlds: 'com|net|org|io|dev|me|do',
    enable_markdown_typographer: true,
    traditional_markdown_linebreaks: false,
    enable_rich_text_paste: true,
    max_image_width: 690,
    max_image_height: 500,
    enable_mentions: true,
    unicode_usernames: false,
    enable_emoji: true,
    emoji_set: 'twitter',
    enable_emoji_shortcuts: true,
    enable_inline_emoji_translation: false,
    emoji_deny_list: '',
    allowed_href_schemes: '',
    allowed_iframes: '',
    // 插件开关
    spoiler_enabled: true,
    poll_enabled: true,
    poll_maximum_options: 30,
    discourse_math_enabled: true,
    discourse_math_provider: 'mathjax',
    enable_markdown_footnotes: true,
    checklist_enabled: true,
    policy_enabled: true,
    discourse_local_dates_enabled: true,
    chat_enabled: true,
  },
  site: {
    censored_regexp: [{ '(密词甲|密词乙)': { case_sensitive: false } }],
    watched_words_replace: {
      '(?:\\W|^)(replaceme)(?=\\W|$)': {
        regexp: '(replaceme)',
        replacement: 'replaced',
        case_sensitive: false,
      },
    },
    watched_words_link: null,
    custom_emoji_translation: {},
    denied_emojis: [],
    markdown_additional_options: {},
    hashtag_configurations: { 'topic-composer': ['category', 'tag'] },
    hashtag_icons: { category: 'folder', tag: 'tag' },
    categories: [
      { id: 4, slug: 'develop', name: '开发调优', parent_category_id: null },
    ],
  },
  customEmoji: [
    { name: 'bili_023', url: '/uploads/default/original/bili_023.png' },
  ],
  tagNames: ['linux'],
};

assert.equal(cookApi.init(JSON.stringify(initData)), 'ok');
assert.equal(cookApi.isReady(), true);

const cases = [
  {
    name: 'heading + strong + em',
    raw: '# 标题\n\n**粗** *斜*',
    expects: ['<h1>', '标题</h1>', '<strong>粗</strong>', '<em>斜</em>'],
  },
  {
    name: 'bbcode quote → aside.quote',
    raw: '[quote="sam, post:2, topic:123"]\n引用内容\n[/quote]',
    expects: [
      '<aside class="quote no-group"',
      'data-username="sam"',
      'data-post="2"',
      'data-topic="123"',
      '<blockquote>',
      '引用内容',
    ],
  },
  {
    name: 'inline spoiler',
    raw: '前文 [spoiler]秘密[/spoiler]',
    expects: ['class="spoiler"', '秘密'],
  },
  {
    name: 'mention → span.mention（客户端预览形态）',
    raw: 'hi @sam_saffron',
    expects: ['<span class="mention">@sam_saffron</span>'],
  },
  {
    name: 'upload:// 短链 → transparent 占位 + data-orig-src',
    raw: '![截图|690x387](upload://abcDEF123.png)',
    expects: [
      'src="/images/transparent.png"',
      'data-orig-src="upload://abcDEF123.png"',
      'width="690"',
      'height="387"',
    ],
  },
  {
    name: '标准 emoji shortcode → img.emoji',
    raw: '你好 :smile:',
    expects: ['class="emoji"', '/images/emoji/twitter/smile.png', 'alt=":smile:"'],
  },
  {
    name: '自定义 emoji',
    raw: ':bili_023:',
    expects: ['emoji-custom', '/uploads/default/original/bili_023.png'],
  },
  {
    name: 'math inline + block',
    raw: '质能方程 $E=mc^2$\n\n$$\n\\int_0^1 x dx\n$$',
    expects: ['<span class="math">E=mc^2</span>', '<div class="math">'],
  },
  {
    name: 'local date bbcode',
    raw: '[date=2026-07-06 time=10:00:00 timezone="Asia/Shanghai"]',
    expects: ['discourse-local-date', 'data-date="2026-07-06"', 'data-timezone="Asia/Shanghai"'],
  },
  {
    name: 'poll bbcode',
    raw: '[poll type=regular results=always chartType=bar]\n* 选项甲\n* 选项乙\n[/poll]',
    expects: ['class="poll"', 'data-poll-name="poll"', '选项甲'],
  },
  {
    name: 'censored 词打码',
    raw: '这里有密词甲出现',
    expects: ['■■■'],
    absent: ['密词甲'],
  },
  {
    name: 'watched word replace',
    raw: 'foo replaceme bar',
    expects: ['replaced'],
    absent: ['replaceme'],
  },
  {
    name: 'GFM 表格',
    raw: '| a | b |\n| --- | --- |\n| 1 | 2 |',
    expects: ['<table>', '<th>a</th>', '<td>1</td>'],
  },
  {
    name: 'details 折叠',
    raw: '[details="展开看"]\n内容\n[/details]',
    expects: ['<details>', '<summary>', '展开看'],
  },
  {
    name: 'checklist',
    raw: '[x] 已完成\n\n[ ] 未完成',
    expects: ['chcklst-box checked', 'chcklst-box'],
  },
  {
    name: 'hashtag → 命中分类出 a.hashtag-cooked',
    raw: '讨论去 #develop 板块',
    expects: [
      'class="hashtag-cooked"',
      'href="/c/develop/4"',
      'data-type="category"',
      'data-slug="develop"',
    ],
  },
  {
    name: 'hashtag → 命中 tag',
    raw: '打上 #linux 标签',
    expects: ['class="hashtag-cooked"', 'href="/tag/linux"', 'data-type="tag"'],
  },
  {
    name: 'hashtag → 未知 slug 降级 hashtag-raw',
    raw: '未知 #nonexistent-slug 标签',
    expects: ['class="hashtag-raw"'],
  },
  {
    name: 'footnote',
    raw: '正文引用[^1]\n\n[^1]: 脚注内容',
    expects: ['class="footnote-ref"', 'class="footnotes-list"', '脚注内容'],
  },
  {
    name: 'linkify 裸链接',
    raw: '看看 https://linux.do/about 吧',
    expects: ['<a href="https://linux.do/about"'],
  },
  {
    name: 'html 注入被 sanitize',
    raw: '<script>alert(1)</script> 正常文本',
    absent: ['<script>'],
    expects: ['正常文本'],
  },
  {
    name: 'unicode emoji → img.emoji（对齐服务端,web 预览做不到）',
    raw: '你好 😀 世界',
    expects: ['/images/emoji/twitter/grinning_face.png', 'title=":grinning_face:"'],
    absent: ['😀'],
  },
  {
    name: '独行 unicode emoji 拿到 only-emoji',
    raw: '😀',
    expects: ['class="emoji only-emoji"'],
  },
  {
    name: '裸链接独行 → a.onebox 占位（未 seed）',
    raw: '看这个\n\nhttps://example.com/some-page\n\n结尾',
    expects: ['class="onebox"', 'href="https://example.com/some-page"'],
  },
  {
    name: '行内深链 → inline-onebox-loading 占位（未 seed）',
    raw: '参考 https://example.com/deep/path 这篇',
    expects: ['inline-onebox-loading'],
  },
  {
    name: 'code fence 保持原样不 cook 内部',
    raw: '```dart\nfinal a = :smile:; // @sam\n```',
    expects: ['<code class="lang-dart">', ':smile:', '@sam'],
    absent: ['class="emoji"', 'class="mention"'],
  },
];

let failed = 0;
for (const c of cases) {
  let cooked;
  try {
    cooked = cookApi.cook(c.raw);
  } catch (e) {
    failed++;
    console.error(`✗ ${c.name}\n    cook 抛错: ${e.message}`);
    continue;
  }
  const missing = (c.expects ?? []).filter((s) => !cooked.includes(s));
  const leaked = (c.absent ?? []).filter((s) => cooked.includes(s));
  if (missing.length || leaked.length) {
    failed++;
    console.error(`✗ ${c.name}`);
    for (const m of missing) {
      console.error(`    缺少: ${m}`);
    }
    for (const l of leaked) {
      console.error(`    不应出现: ${l}`);
    }
    console.error(`    实际输出: ${cooked}`);
  } else {
    console.log(`✓ ${c.name}`);
  }
}

if (failed) {
  console.error(`\n${failed}/${cases.length} 个用例失败`);
  process.exit(1);
}

// --- onebox seed 后重 cook：占位应替换成卡片/标题 ---
{
  const url = 'https://example.com/some-page';
  const cardHtml =
    '<aside class="onebox allowlistedgeneric"><article class="onebox-body"><h3><a href="https://example.com/some-page">示例标题</a></h3></article></aside>';
  cookApi.seedOnebox(url, cardHtml);
  const cooked = cookApi.cook(`看这个\n\n${url}\n\n结尾`);
  assert.ok(cooked.includes('onebox-body'), `块级 onebox seed 未生效: ${cooked}`);
  assert.ok(cooked.includes('示例标题'), `seed 的卡片内容丢失: ${cooked}`);
  console.log('✓ seedOnebox 后重 cook 输出卡片');

  const inlineUrl = 'https://example.com/deep/path';
  cookApi.seedInlineOnebox(inlineUrl, '深链页面标题', null);
  const cooked2 = cookApi.cook(`参考 ${inlineUrl} 这篇`);
  assert.ok(cooked2.includes('inline-onebox'), `inline seed 未生效: ${cooked2}`);
  assert.ok(cooked2.includes('深链页面标题'), `inline 标题未替换: ${cooked2}`);
  assert.ok(!cooked2.includes('inline-onebox-loading'), `loading 占位未消除: ${cooked2}`);
  console.log('✓ seedInlineOnebox 后重 cook 替换链接标题');
}

console.log(`\n全部 ${cases.length} 个用例 + onebox seed 通过`);
